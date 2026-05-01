-- asobi-love2d canonical smoke test.
-- Implements the 3 scenarios from sdk_demo_backend/SMOKE.md against a
-- backend at ASOBI_URL (default http://localhost:8084).
--
-- Runs as a standalone Lua script — does NOT require love.run / love.update.
-- The asobi network layer uses luasocket directly, so a plain Lua + luasocket
-- environment is sufficient. This means CI can validate the SDK end-to-end
-- without installing LÖVE.
--
-- Exit code: 0 on pass, non-zero on any failure or timeout.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local socket = require("socket")
local asobi = require("asobi")

local MATCH_MODE = "demo"
local MATCH_TIMEOUT = 10
local STATE_TIMEOUT = 3
local OVERALL_TIMEOUT = 30
local X_DELTA = 10

local function log(s) print("[smoke] " .. tostring(s)) end
local function fail(s)
	print("[smoke] FAIL: " .. tostring(s))
	os.exit(1)
end

local function parse_url(env)
	if env == nil or env == "" then return "localhost", 8084 end
	local h, p = env:match("^https?://([^:/]+):(%d+)")
	if h then return h, tonumber(p) end
	h = env:match("^https?://([^:/]+)")
	return h or "localhost", 8084
end

local host, port = parse_url(os.getenv("ASOBI_URL"))
log("Target: " .. host .. ":" .. port)

-- Wait for backend (curl-equivalent precheck).
local started = socket.gettime()
do
	local probe = require("asobi").new({host = host, port = port})
	local ok = false
	for i = 1, 60 do
		local _, err = require("asobi.http").post(probe, "/api/v1/auth/register", {})
		-- Any response that's not a connection failure means the server is up.
		-- Even a 400 from a malformed request body proves we reached the app.
		if not err or (err.status_code and err.status_code >= 100) then
			ok = true; log("Backend reachable after " .. i .. "s"); break
		end
		socket.sleep(1)
	end
	if not ok then fail("backend never came up") end
end

-- Scenario 1: register both clients.
math.randomseed(os.time())
local function rand_suffix()
	return tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9))
end

local a = asobi.new({host = host, port = port})
local b = asobi.new({host = host, port = port})

local _, err_a = asobi.auth.register(a, "smoke_a_" .. rand_suffix(), "smoke_pw_12345", "smoke-a")
if err_a then fail("register a: " .. err_a.error) end
log("Registered A: " .. tostring(a.player_id))

local _, err_b = asobi.auth.register(b, "smoke_b_" .. rand_suffix(), "smoke_pw_12345", "smoke-b")
if err_b then fail("register b: " .. err_b.error) end
log("Registered B: " .. tostring(b.player_id))

-- State for the run.
local match_a, match_b
local match_checked = false
local x_initial = nil
local input_sent = false
local passed = false

-- Wire up handlers BEFORE queueing.
local function on_match(letter, store)
	return function(payload)
		store(payload)
		if match_a and match_b and not match_checked then
			match_checked = true
			if match_a.match_id ~= match_b.match_id then
				fail("match_id mismatch: " .. tostring(match_a.match_id)
					.. " vs " .. tostring(match_b.match_id))
			end
			log("Both matched, match_id = " .. match_a.match_id)
		end
	end
end
a.realtime:on("match_matched", on_match("A", function(p) match_a = p end))
b.realtime:on("match_matched", on_match("B", function(p) match_b = p end))

a.realtime:on("match_state", function(payload)
	if not match_checked then return end
	local me = (payload.players or {})[a.player_id]
	if not me or me.x == nil then return end
	if x_initial == nil then
		x_initial = me.x
		log("First match.state: x_initial = " .. tostring(x_initial))
		log("Sending match.input {move_x=1, move_y=0}")
		a.realtime:send_match_input({move_x = 1, move_y = 0, shoot = false, aim_x = 0, aim_y = 0})
		input_sent = true
		return
	end
	if input_sent and me.x > x_initial + X_DELTA then
		log("match.state confirmed: x = " .. tostring(me.x)
			.. " (initial " .. tostring(x_initial)
			.. ", delta > " .. X_DELTA .. ")")
		passed = true
	end
end)

-- Connect both WebSockets.
local ok_a, ws_err_a = a.realtime:connect()
if not ok_a then fail("ws connect a: " .. tostring(ws_err_a)) end
local ok_b, ws_err_b = b.realtime:connect()
if not ok_b then fail("ws connect b: " .. tostring(ws_err_b)) end
log("Both WebSockets open")

-- Queue.
a.realtime:add_to_matchmaker({mode = MATCH_MODE})
b.realtime:add_to_matchmaker({mode = MATCH_MODE})
log("Both queued (mode=" .. MATCH_MODE .. ")")

-- Drive the loop until pass / fail / timeout.
local matched_at = nil
while not passed do
	a.realtime:update()
	b.realtime:update()
	socket.sleep(0.05)

	local now = socket.gettime()
	local elapsed = now - started

	if elapsed > OVERALL_TIMEOUT then
		if not match_checked then
			fail("timeout waiting for match.matched")
		elseif x_initial == nil then
			fail("timeout waiting for first match.state")
		else
			fail("timeout waiting for x to advance (x_initial=" .. tostring(x_initial) .. ")")
		end
	end

	if match_checked and matched_at == nil then matched_at = now end
	if matched_at and (now - matched_at > STATE_TIMEOUT + MATCH_TIMEOUT) then
		fail("post-match timeout (matched_at + " .. (STATE_TIMEOUT + MATCH_TIMEOUT) .. "s)")
	end
end

a.realtime:disconnect()
b.realtime:disconnect()
log("PASS")
os.exit(0)

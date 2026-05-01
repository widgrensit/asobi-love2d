-- Dispatch unit test: feeds every canonical fixture through the SDK's
-- realtime message handler and asserts the right callback fires.
--
-- Pure unit test — no network, no LÖVE. Runs in plain Lua + luasocket.
-- Catches the doc-vs-server drift class of bugs (e.g. server emits
-- match.matched but SDK only listens for matchmaker.matched) before any
-- user reports a silent failure.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local asobi = require("asobi")

local FIXTURE_DIR = "test/fixtures"

-- For each server wire `type`, the SDK callback name a user binds via
-- realtime:on(...). Mirrors SERVER_EVENTS in asobi/realtime.lua. Drift
-- between this map and the SDK is caught by the assertions below.
local EXPECTED = {
	["error"] = "error",
	["session.connected"] = "connected",
	["session.heartbeat"] = "heartbeat",
	["match.state"] = "match_state",
	["match.matched"] = "match_matched",
	["match.joined"] = "match_joined",
	["match.left"] = "match_left",
	["match.finished"] = "match_finished",
	["match.matchmaker_expired"] = "matchmaker_expired",
	["match.matchmaker_failed"] = "matchmaker_failed",
	["match.vote_start"] = "vote_start",
	["match.vote_tally"] = "vote_tally",
	["match.vote_result"] = "vote_result",
	["match.vote_vetoed"] = "vote_vetoed",
	["matchmaker.queued"] = "matchmaker_queued",
	["matchmaker.removed"] = "matchmaker_removed",
	["chat.joined"] = "chat_joined",
	["chat.left"] = "chat_left",
	["chat.message"] = "chat_message",
	["dm.sent"] = "dm_sent",
	["dm.message"] = "dm_message",
	["presence.updated"] = "presence_changed",
	["notification.new"] = "notification",
	["vote.cast_ok"] = "vote_cast_ok",
	["vote.veto_ok"] = "vote_veto_ok",
	["world.tick"] = "world_tick",
	["world.terrain"] = "world_terrain",
	["world.list"] = "world_list",
	["world.joined"] = "world_joined",
	["world.left"] = "world_left",
	["world.phase_changed"] = "phase_changed",
	["world.finished"] = "world_finished",
}

local fail_count = 0
local pass_count = 0

local function fail(msg)
	print("[dispatch] FAIL: " .. msg)
	fail_count = fail_count + 1
end

local function pass(msg)
	pass_count = pass_count + 1
	print("[dispatch] PASS: " .. msg)
end

local function list_fixtures()
	local out = {}
	local p = io.popen('ls "' .. FIXTURE_DIR .. '"')
	if not p then return out end
	for line in p:lines() do
		if line:match("%.json$") then table.insert(out, line) end
	end
	p:close()
	table.sort(out)
	return out
end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local fixtures = list_fixtures()
if #fixtures == 0 then fail("no fixtures found in " .. FIXTURE_DIR) end

local fixture_types = {}
for _, name in ipairs(fixtures) do fixture_types[name:gsub("%.json$", "")] = true end

for _, name in ipairs(fixtures) do
	local mtype = name:gsub("%.json$", "")
	if not EXPECTED[mtype] then
		fail("fixture '" .. name .. "' has no entry in EXPECTED — add a SDK callback mapping")
	end
end

for mtype, _ in pairs(EXPECTED) do
	if not fixture_types[mtype] then
		fail("EXPECTED maps '" .. mtype .. "' but no fixture exists — stale or fixture missing")
	end
end

for _, name in ipairs(fixtures) do
	local mtype = name:gsub("%.json$", "")
	local expected_cb = EXPECTED[mtype]
	if expected_cb then
		local raw = read_file(FIXTURE_DIR .. "/" .. name)
		if not raw then
			fail("could not read " .. name)
		else
			local client = asobi.new({host = "x", port = 1})
			local fired = false
			client.realtime:on(expected_cb, function(_payload) fired = true end)
			client.realtime:_handle_message(raw)
			if fired then
				pass(mtype .. " -> on(" .. expected_cb .. ")")
			else
				fail(mtype .. " did not fire on(" .. expected_cb .. ")")
			end
		end
	end
end

print(string.format("[dispatch] %d passed, %d failed (%d fixtures)",
	pass_count, fail_count, #fixtures))
if fail_count > 0 then os.exit(1) end

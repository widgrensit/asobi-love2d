-- Matchmaker unit test: covers asobi.matchmaker.add (REST) and
-- asobi.realtime:add_to_matchmaker (WebSocket) mode resolution, including
-- the positional-table guard.
--
-- A caller who writes add_to_matchmaker({"grid2"}) instead of
-- add_to_matchmaker({mode = "grid2"}) sets opts[1], not opts.mode. Both
-- functions used to silently fall through to mode = "default" with no
-- error — a real user hit exactly this on a sibling SDK and their ticket
-- queued forever against a mode that didn't exist. Both entry points must
-- now fail loud instead.
--
-- Pure unit test — no network, no LÖVE.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local http = require("asobi.http")
local matchmaker = require("asobi.matchmaker")
local realtime = require("asobi.realtime")

local fail_count = 0
local pass_count = 0

local function pass(msg)
	pass_count = pass_count + 1
	print("[matchmaker] PASS: " .. msg)
end

local function fail(msg)
	fail_count = fail_count + 1
	print("[matchmaker] FAIL: " .. msg)
end

local function check(cond, msg)
	if cond then pass(msg) else fail(msg) end
end

-- asobi.matchmaker.add (REST) --------------------------------------------

do
	local last
	http.post = function(_client, path, body)
		last = {path = path, body = body}
		return {ticket_id = "t-1"}, nil
	end

	matchmaker.add({}, "grid2")
	check(last.body.mode == "grid2", "add: bare string sets mode")

	matchmaker.add({}, {mode = "grid2", properties = {x = 1}, party = "p-1"})
	check(last.body.mode == "grid2", "add: keyed table sets mode")
	check(last.body.properties.x == 1, "add: keyed table forwards properties")
	check(last.body.party == "p-1", "add: keyed table forwards party")

	matchmaker.add({})
	check(last.body.mode == "default", "add: no args defaults to mode=default")

	matchmaker.add({}, {})
	check(last.body.mode == "default", "add: empty table defaults to mode=default")

	local ok, err = pcall(matchmaker.add, {}, {"grid2"})
	check(ok == false, "add: positional table {\"grid2\"} raises instead of defaulting")
	check(ok == false and tostring(err):find("mode", 1, true) ~= nil,
		"add: error message mentions mode")
end

-- asobi.realtime:add_to_matchmaker (WebSocket) ----------------------------

local function new_rt()
	local rt = realtime.new({})
	local sent
	rt.ws.send = function(_self, frame) sent = frame end
	return rt, function() return sent end
end

do
	local rt, last_frame = new_rt()
	rt:add_to_matchmaker("grid2")
	check(last_frame():find('"mode":"grid2"', 1, true) ~= nil,
		"add_to_matchmaker: bare string sets mode")
end

do
	local rt, last_frame = new_rt()
	rt:add_to_matchmaker({mode = "grid2", party = "p-1"})
	local frame = last_frame()
	check(frame:find('"mode":"grid2"', 1, true) ~= nil, "add_to_matchmaker: keyed table sets mode")
	check(frame:find('"party":"p-1"', 1, true) ~= nil, "add_to_matchmaker: keyed table forwards party")
end

do
	local rt, last_frame = new_rt()
	rt:add_to_matchmaker()
	check(last_frame():find('"mode":"default"', 1, true) ~= nil,
		"add_to_matchmaker: no args defaults to mode=default")
end

do
	local rt = new_rt()
	local ok, err = pcall(rt.add_to_matchmaker, rt, {"grid2"})
	check(ok == false, "add_to_matchmaker: positional table {\"grid2\"} raises instead of defaulting")
	check(ok == false and tostring(err):find("mode", 1, true) ~= nil,
		"add_to_matchmaker: error message mentions mode")
end

print(string.format("[matchmaker] %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end

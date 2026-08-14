-- Send-side unit test: asserts each realtime wrapper puts the wire `type`
-- and payload the asobi backend actually matches on onto the socket.
--
-- The dispatch test covers the receive half only. A missing sender is
-- invisible there: the SDK can route a reply it has no way to ask for,
-- which is exactly how vote.cast, chat.leave, dm.send, presence.update,
-- match.list, world.list and world.create went unreachable.
--
-- Pure unit test — no network, no LÖVE.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local realtime = require("asobi.realtime")
local json = require("asobi.json")

local fail_count = 0
local pass_count = 0

local function pass(msg)
	pass_count = pass_count + 1
	print("[send] PASS: " .. msg)
end

local function fail(msg)
	fail_count = fail_count + 1
	print("[send] FAIL: " .. msg)
end

local function check(cond, msg)
	if cond then pass(msg) else fail(msg) end
end

local function new_rt()
	local rt = realtime.new({})
	local sent
	rt.ws.send = function(_self, frame) sent = frame end
	return rt, function() return sent end
end

local function sends(msg, fn, ...)
	local rt, last_frame = new_rt()
	fn(rt, ...)
	local frame = last_frame()
	if not frame then
		fail(msg .. ": nothing was sent")
		return ""
	end
	check(frame:find('"type":"' .. msg .. '"', 1, true) ~= nil, msg .. ": sends type " .. msg)
	return frame
end

do
	local frame = sends("vote.cast", realtime.cast_vote, "v-1", "jungle")
	check(frame:find('"vote_id":"v-1"', 1, true) ~= nil, "vote.cast: sends vote_id")
	check(frame:find('"option_id":"jungle"', 1, true) ~= nil, "vote.cast: sends option_id")
end

do
	local frame = sends("vote.veto", realtime.cast_veto, "v-1")
	check(frame:find('"vote_id":"v-1"', 1, true) ~= nil, "vote.veto: sends vote_id")
end

do
	local frame = sends("chat.leave", realtime.leave_chat, "c-1")
	check(frame:find('"channel_id":"c-1"', 1, true) ~= nil, "chat.leave: sends channel_id")
end

do
	local frame = sends("dm.send", realtime.send_dm, "p-2", "hoi")
	check(frame:find('"recipient_id":"p-2"', 1, true) ~= nil, "dm.send: sends recipient_id")
	check(frame:find('"content":"hoi"', 1, true) ~= nil, "dm.send: sends content")
end

do
	local frame = sends("presence.update", realtime.update_presence, "away")
	check(frame:find('"status":"away"', 1, true) ~= nil, "presence.update: sends status")
end

do
	local frame = sends("presence.update", realtime.update_presence)
	check(frame:find('"status":"online"', 1, true) ~= nil, "presence.update: defaults to online")
end

do
	local frame = sends("match.list", realtime.list_matches, {mode = "demo", joinable = false})
	check(frame:find('"mode":"demo"', 1, true) ~= nil, "match.list: forwards the mode filter")
	check(frame:find('"joinable":false', 1, true) ~= nil,
		"match.list: forwards joinable=false, which is a filter and not its absence")
end

do
	local frame = sends("match.list", realtime.list_matches)
	check(frame:find('"payload":{}', 1, true) ~= nil, "match.list: no filters sends an empty object")
end

do
	local frame = sends("world.list", realtime.list_worlds, {has_capacity = true})
	check(frame:find('"has_capacity":true', 1, true) ~= nil, "world.list: forwards has_capacity")
end

do
	local frame = sends("world.create", realtime.create_world, "walkers")
	check(frame:find('"mode":"walkers"', 1, true) ~= nil, "world.create: sends mode")
end

-- The cid-correlated wrappers must still reach their callback rather than
-- the event map, the way find_or_create_world does.
do
	local rt = new_rt()
	local got
	rt:create_world("walkers", function(payload, _err) got = payload end)
	rt:_handle_message('{"type":"world.joined","cid":"1","payload":{"world_id":"w-1"}}')
	check(got ~= nil and got.world_id == "w-1", "world.create: reply reaches the callback by cid")
end

-- The fire-and-forget wrappers carry a cid, so their reply falls through to
-- the registered event instead.
do
	local rt = new_rt()
	local fired
	rt:on("match_list", function(payload) fired = payload end)
	rt:list_matches()
	rt:_handle_message('{"type":"match.list","cid":"1","payload":{"matches":[]}}')
	check(fired ~= nil, "match.list: reply fires on(match_list)")
end

do
	local frame = sends("match.find_or_create", realtime.find_or_create_match, "arena")
	check(frame:find('"mode":"arena"', 1, true) ~= nil, "match.find_or_create: sends mode")
	local decoded = json.decode(frame)
	local keys = 0
	for _ in pairs(decoded.payload) do keys = keys + 1 end
	check(keys == 1, "match.find_or_create: mode is the whole payload")
end

-- Its reply is match.joined, the same frame match.join answers with, so it has
-- to reach on("match_joined") rather than a cid callback.
do
	local rt = new_rt()
	local fired
	rt:on("match_joined", function(payload) fired = payload end)
	rt:find_or_create_match("arena")
	rt:_handle_message('{"type":"match.joined","cid":"1","payload":{"match_id":"m-1"}}')
	check(fired ~= nil and fired.match_id == "m-1",
		"match.find_or_create: reply fires on(match_joined)")
end

-- world.input carries an optional per-input seq for world.ack prediction. It
-- rides as a top-level sibling of payload, never nested inside it, and stays
-- numeric.
do
	local rt, last_frame = new_rt()
	rt:send_world_input({x = 1, y = 2}, 7)
	local frame = last_frame()
	check(frame ~= nil and frame:find('"type":"world.input"', 1, true) ~= nil,
		"world.input (seq): sends type world.input")
	check(frame ~= nil and frame:find('"seq":7', 1, true) ~= nil, "world.input (seq): stamps seq numerically")
	local decoded = frame and json.decode(frame)
	check(decoded ~= nil and decoded.seq == 7, "world.input (seq): seq is a top-level sibling of payload")
	check(decoded ~= nil and decoded.payload and decoded.payload.seq == nil,
		"world.input (seq): seq is never nested inside payload")
	check(decoded ~= nil and decoded.payload and decoded.payload.x == 1 and decoded.payload.y == 2,
		"world.input (seq): input reaches payload intact")
end

do
	local rt, last_frame = new_rt()
	rt:send_world_input({x = 1})
	local frame = last_frame()
	check(frame ~= nil and frame:find('"seq"', 1, true) == nil,
		"world.input (no seq): omits seq entirely when not provided")
	local decoded = frame and json.decode(frame)
	check(decoded ~= nil and decoded.seq == nil, "world.input (no seq): no top-level seq key")
	check(decoded ~= nil and decoded.payload and decoded.payload.x == 1,
		"world.input (no seq): input reaches payload")
end

print(string.format("[send] %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end

-- Entity-sync unit test: the zone-aware application of world.tick.
--
-- Pure unit test - no network, no LÖVE. Runs in plain Lua.
--
-- These cover the defect that needs NO packet loss to reproduce. A player is
-- subscribed to an interest ring of several zones at once, each an independent
-- server process, and frames from two of them have no order relative to each
-- other. A crossing emits op:"r" from the zone being left and op:"a" from the
-- zone being entered, so merging every zone into one entity table is
-- last-writer-wins - and when the remove lands last the entity is gone for the
-- life of the world, because the server will not re-add something already in
-- its own baseline.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local asobi = require("asobi")

local failures = 0
local function check(cond, msg)
	if cond then
		print("  ok  " .. msg)
	else
		print("  FAIL " .. msg)
		failures = failures + 1
	end
end

local function new_rt()
	return asobi.new({host = "x", port = 1}).realtime
end

-- Captures outgoing frames so the resync request is observable. The SDK builds
-- the frame with json.encode inside _send_fire_and_forget, so intercepting that
-- is both simpler and closer to what the caller actually does than stubbing the
-- socket.
local function capturing_rt()
	local rt = new_rt()
	rt.sent = {}
	rt._send_fire_and_forget = function(self, mtype, payload)
		self.sent[#self.sent + 1] = {type = mtype, payload = payload}
	end
	return rt
end

local function add(id, fields)
	local d = {op = "a", id = id}
	if fields then for k, v in pairs(fields) do d[k] = v end end
	return d
end
local function upd(id, fields)
	local d = {op = "u", id = id}
	for k, v in pairs(fields) do d[k] = v end
	return d
end
local function rem(id) return {op = "r", id = id} end

print("[entity_sync] interest-ring zone safety")

-- The crossing, in the order that used to lose the entity: the new zone claims
-- it, then the old zone's removal arrives late.
do
	local rt = new_rt()
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 1, tick = 1, updates = {add("p1", {x = 5})}})
	rt:_dispatch_tick({zone = {0, 1}, frame_seq = 1, tick = 1, updates = {rem("p1")}})
	check(rt.entities.p1 ~= nil, "a late remove from the zone left does not delete a crossed entity")
	check(rt.entity_zone.p1 == "1:1", "the entity stays owned by the zone that claimed it")
end

-- The same crossing the other way round, which always worked, to prove the fix
-- did not simply invert the bug.
do
	local rt = new_rt()
	rt:_dispatch_tick({zone = {0, 1}, frame_seq = 1, tick = 1, updates = {rem("p1")}})
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 1, tick = 1, updates = {add("p1", {x = 5})}})
	check(rt.entities.p1 ~= nil, "remove-then-add converges on the entity being present")
	check(rt.entity_zone.p1 == "1:1", "and owned by the zone that added it")
end

-- A stale update from the zone that no longer owns the entity is ignored, or a
-- crossing player snaps back to their old zone's last known position.
do
	local rt = new_rt()
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 1, tick = 1, updates = {add("p1", {x = 100})}})
	rt:_dispatch_tick({zone = {0, 1}, frame_seq = 1, tick = 1, updates = {upd("p1", {x = 7})}})
	check(rt.entities.p1.x == 100, "a stale update from the previous zone is ignored")
end

-- The guard must not make entities immortal: the owning zone can still remove.
do
	local rt = new_rt()
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 1, tick = 1, updates = {add("p1", {x = 5})}})
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 2, tick = 2, updates = {rem("p1")}})
	check(rt.entities.p1 == nil, "the owning zone can still remove its own entity")
	check(rt.entity_zone.p1 == nil, "and ownership is released with it")
end

print("[entity_sync] gap detection and repair")

do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 1, tick = 1, updates = {add("e1")}})
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 4, tick = 4, updates = {add("e2")}})
	check(#rt.sent == 1, "a sequence gap asks for exactly one resync")
	if #rt.sent == 1 then
		check(rt.sent[1].type == "world.resync", "the request is world.resync")
		check(rt.sent[1].payload.zone[1] == 2 and rt.sent[1].payload.zone[2] == 0,
			"and names the zone that gapped, not the whole ring")
	else
		check(false, "no resync frame to inspect")
	end
	check(rt.entities.e2 ~= nil, "the gapping frame is still applied - it is the newest news")
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 9, tick = 9, updates = {add("e3")}})
	check(#rt.sent == 1, "a second gap while a resync is outstanding does not re-ask")
end

do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 5, tick = 5, updates = {add("e1")}})
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 5, tick = 5, updates = {upd("e1", {x = 9})}})
	check(rt.entities.e1.x == nil, "a repeated frame_seq is dropped rather than re-applied")
	check(#rt.sent == 0, "and a duplicate is not mistaken for a gap")
end

-- Sequences are per zone; two zones counting independently is not a gap.
do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {0, 0}, frame_seq = 9, tick = 9, updates = {add("a1")}})
	rt:_dispatch_tick({zone = {1, 0}, frame_seq = 1, tick = 1, updates = {add("b1")}})
	rt:_dispatch_tick({zone = {1, 0}, frame_seq = 2, tick = 2, updates = {add("b2")}})
	check(#rt.sent == 0, "an unrelated zone's lower sequence is not a gap")
end

print("[entity_sync] keyframe adoption")

do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {3, 3}, frame_seq = 7, tick = 7, updates = {add("keep"), add("drop")}})
	rt:_dispatch_tick({zone = {9, 9}, frame_seq = 1, tick = 1, updates = {add("other")}})
	rt:_dispatch_tick({zone = {3, 3}, frame_seq = 2, kf = true, tick = 0, updates = {add("keep")}})
	check(rt.entities.keep ~= nil, "a keyframe keeps what it lists")
	check(rt.entities.drop == nil, "a keyframe removes what it omits, for its own zone")
	check(rt.entities.other ~= nil, "and leaves another zone's entities alone")
	check(rt.zone_seq["3:3"] == 2, "a keyframe resets the sequence even moving backwards")
end

-- A zone restart resets frame_seq while the zone's identity is unchanged, so a
-- monotonic guard here would freeze the client on pre-crash state forever.
do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {4, 4}, frame_seq = 500, tick = 500, updates = {add("stale")}})
	rt:_dispatch_tick({zone = {4, 4}, frame_seq = 1, kf = true, tick = 0, updates = {add("fresh")}})
	check(rt.entities.fresh ~= nil, "a post-restart keyframe is adopted despite a lower frame_seq")
	check(rt.entities.stale == nil, "and clears the pre-restart state it replaces")
end

do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {5, 5}, frame_seq = 1, tick = 1, updates = {add("e1")}})
	rt:_dispatch_tick({zone = {5, 5}, frame_seq = 5, tick = 5, updates = {add("e2")}})
	check(#rt.sent == 1, "first gap asks")
	rt:_dispatch_tick({zone = {5, 5}, frame_seq = 5, kf = true, tick = 0, updates = {add("e1")}})
	rt:_dispatch_tick({zone = {5, 5}, frame_seq = 20, tick = 20, updates = {add("e9")}})
	check(#rt.sent == 2, "after the keyframe lands, a later gap asks again")
end

print("[entity_sync] match.state is unchanged")

-- match.state carries no zone, so it collapses onto one key and behaves exactly
-- as it did before, and never asks for a resync having no zone to name.
do
	local rt = capturing_rt()
	rt:_dispatch_tick({tick = 1, updates = {add("m1", {x = 1})}})
	rt:_dispatch_tick({tick = 2, updates = {upd("m1", {x = 2})}})
	check(rt.entities.m1.x == 2, "match mode still applies updates in one namespace")
	rt:_dispatch_tick({tick = 3, updates = {rem("m1")}})
	check(rt.entities.m1 == nil, "and removes")
	check(#rt.sent == 0, "and never asks for a resync, having no zone to name")
end

if failures == 0 then
	print("OK: all entity-sync tests passed")
	os.exit(0)
else
	print("FAIL: " .. failures .. " test(s) failed")
	os.exit(1)
end

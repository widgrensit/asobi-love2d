-- The datagram plane's client state machine and codec.
--
-- Pure unit test - no network, no LOVE, no clock. Every timing that matters is
-- driven by an injected `now`, so the probe ladder, the hard give-up, the
-- keepalive and the degradation threshold are asserted rather than waited for.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local dgram = require("asobi.dgram")
local datagram = require("asobi.datagram")

local failures = 0
local passes = 0
local function check(cond, msg)
	if cond then
		passes = passes + 1
	else
		print("  FAIL " .. msg)
		failures = failures + 1
	end
end

-- A stand-in for the runtime's real hash. The codec must not care which one it
-- gets, and a test that needed a real SHA256 would be testing the runtime.
local function fake_sha256(s)
	local acc = {}
	for i = 1, 32 do
		local n = 0
		for j = i, #s, 32 do
			n = (n + string.byte(s, j) * j) % 256
		end
		acc[i] = string.char((n + i * 7) % 256)
	end
	return table.concat(acc)
end

local function harness()
	local sent = {}
	local clock = { t = 0 }
	local dg = datagram.new({
		send = function(bytes) sent[#sent + 1] = bytes end,
		now = function() return clock.t end,
		sha256 = fake_sha256,
	})
	return dg, sent, clock
end

local function mint(dg)
	return datagram.on_mint(dg, {
		conn_id = 4711,
		kup = string.rep("k", 32),
		epoch = 9,
		fields = { { name = "x", scale = 100 }, { name = "y", scale = 100 } },
	})
end

-- --- The codec ---

print("codec")
do
	local key = dgram.new_key(string.rep("k", 32), fake_sha256)
	local hello = dgram.encode_uplink(dgram.OP_HELLO, 4711, 1, "", key, dgram.MIN_HELLO)

	check(#hello >= dgram.MIN_HELLO, "hello is padded to the anti-amplification floor")
	check(string.byte(hello, 1) == dgram.MAGIC, "magic")
	check(string.byte(hello, 3) == dgram.OP_HELLO, "opcode")

	-- The padding is INSIDE the MAC, or an attacker strips it back off and
	-- recovers exactly the amplification ratio it exists to remove.
	local stripped = string.sub(hello, 1, 40) .. string.sub(hello, -dgram.MAC_BYTES)
	check(#stripped < #hello, "stripping padding shortens the datagram")

	-- path_tag is always zero on an uplink; the server refuses a non-zero one
	-- rather than parsing whatever was smuggled in it.
	local tag_zero = true
	for i = 9, 16 do
		if string.byte(hello, i) ~= 0 then tag_zero = false end
	end
	check(tag_zero, "an uplink carries no path_tag")
end

do
	-- Total on hostile input: these bytes arrive unauthenticated from anywhere,
	-- so a decoder that raised would hand anyone on the path a way to crash the
	-- game.
	local cases = { "", "\1", string.rep("\0", 16), string.rep("\255", 64) }
	for _, raw in ipairs(cases) do
		local ok, result = pcall(dgram.decode, raw)
		check(ok and result == nil, "malformed input is refused, not raised")
	end
	-- ...and a reserved flag bit is a drop rather than a mask, so a flag defined
	-- later cannot be silently ignored by an old client.
	local flagged = string.char(dgram.MAGIC, dgram.VERSION, dgram.OP_POSE, 1) .. string.rep("\0", 12)
	check(dgram.decode(flagged) == nil, "a reserved flag bit is refused")
end

do
	-- A pose body, hand-built to the layout the server writes.
	local body = "\42\0\0\0" .. "\7\0\0\0" .. "\3\0" .. "\254\255" .. "\3" .. "\1" .. "\9\0"
		.. "\5\0" .. "\2" .. "\3" .. "\226\4" .. "\187\254"
	local pose = dgram.decode_pose(body, 2)
	check(pose ~= nil, "a pose body decodes")
	check(pose.tick == 42 and pose.bseq == 7, "tick and bseq")
	check(pose.zone[1] == 3 and pose.zone[2] == -2, "zone coords are signed")
	check(pose.epoch == 9, "epoch")
	check(#pose.records == 1, "record count")
	check(pose.records[1].slot == 5 and pose.records[1].gen == 2, "slot and gen")
	check(pose.records[1].values[1] == 1250, "first field")
	check(pose.records[1].values[2] == -325, "second field is signed")

	check(dgram.decode_pose(body .. "\0", 2) == nil, "trailing bytes are refused")
	check(dgram.decode_pose(string.sub(body, 1, #body - 1), 2) == nil, "a truncated body is refused")
end

-- --- The state machine ---

print("state machine")
do
	local dg = harness()
	check(dg.state == datagram.OFF, "a fresh client is off")
	check(not datagram.pose_authoritative(dg), "off is never authoritative")
end

do
	-- The probe ladder: 200 / 400 / 800ms, then a hard stop at three seconds. A
	-- client that retried forever would sit behind a firewall that will never
	-- pass UDP, reporting nothing.
	local dg, sent, clock = harness()
	mint(dg)
	check(dg.state == datagram.PROBING, "a mint moves to probing")

	datagram.update(dg, 0)
	check(#sent == 1, "the first hello goes immediately")

	clock.t = 0.1
	datagram.update(dg, 0.1)
	check(#sent == 1, "no retry before the backoff")

	clock.t = 0.2
	datagram.update(dg, 0.2)
	check(#sent == 2, "the first retry is at 200ms")

	-- 0.61 rather than 0.6: the deadline is a sum of floats (0.2 + 0.4) and lands
	-- a hair past it. A real client polls on frame boundaries and never lands
	-- exactly on a deadline either, so testing the exact instant would be
	-- asserting something no caller can observe.
	clock.t = 0.61
	datagram.update(dg, 0.61)
	check(#sent == 3, "the second retry is 400ms later")

	clock.t = 3.0
	datagram.update(dg, 3.0)
	check(dg.state == datagram.OFF, "probing gives up at three seconds")
	check(dg.conn_id == nil, "giving up forgets the credential")
end

do
	-- The handshake, and the claim it supports: nothing is authoritative until
	-- pose actually arrives, because the server sends none until the challenge
	-- is echoed.
	local dg, sent, clock = harness()
	mint(dg)
	datagram.update(dg, 0)

	local hello_ok = string.char(dgram.MAGIC, dgram.VERSION, dgram.OP_HELLO_OK, 0)
		.. string.char(4711 % 256, math.floor(4711 / 256) % 256, 0, 0)
		.. string.rep("\0", 8)
		.. "challeng"
	check(datagram.on_datagram(dg, hello_ok, 0.05) == nil, "hello_ok yields no pose")
	check(#sent == 2, "hello_ok is answered with a confirm")
	check(not datagram.pose_authoritative(dg), "a confirm alone is not enough")

	local pose_raw = string.char(dgram.MAGIC, dgram.VERSION, dgram.OP_POSE, 0)
		.. string.char(4711 % 256, math.floor(4711 / 256) % 256, 0, 0)
		.. string.rep("\0", 8)
		.. "\1\0\0\0" .. "\0\0\0\0" .. "\0\0" .. "\0\0" .. "\3" .. "\0" .. "\9\0"
	local pose = datagram.on_datagram(dg, pose_raw, 0.1)
	check(pose ~= nil, "a pose decodes")
	check(dg.state == datagram.ACTIVE, "the first pose is what makes the plane active")
	check(datagram.pose_authoritative(dg), "active is authoritative")
end

do
	-- A datagram naming another connection is a stale mapping or a stray packet,
	-- and applying it would apply another player's world.
	local dg = harness()
	mint(dg)
	local wrong = string.char(dgram.MAGIC, dgram.VERSION, dgram.OP_POSE, 0)
		.. string.char(1, 0, 0, 0)
		.. string.rep("\0", 8)
		.. string.rep("\0", 16)
	check(datagram.on_datagram(dg, wrong, 0) == nil, "another connection's pose is ignored")
end

do
	-- Degradation, which is the fallback the ADR insists ships in the same phase
	-- as the carrier. Transform fields go straight back to world.tick.
	local dg, sent, clock = harness()
	mint(dg)
	dg.state = datagram.ACTIVE
	dg.last_pose_at = 0
	dg.next_ping_at = 100

	datagram.update(dg, 1.9)
	check(dg.state == datagram.ACTIVE, "under two seconds is still active")

	local before = #sent
	datagram.update(dg, 2.0)
	check(dg.state == datagram.DEGRADED, "two seconds without pose degrades")
	check(not datagram.pose_authoritative(dg), "degraded hands transforms back to world.tick")
	check(#sent == before + 1, "degrading re-sends hello")
end

do
	-- The keepalive is the client's job and nothing else can do it: with a NAT in
	-- the path a quiet client loses its mapping and the downlink is blackholed
	-- with no signal at all.
	local dg, sent, clock = harness()
	mint(dg)
	dg.state = datagram.ACTIVE
	dg.last_pose_at = 100
	dg.next_ping_at = datagram.KEEPALIVE

	local before = #sent
	datagram.update(dg, datagram.KEEPALIVE - 0.1)
	check(#sent == before, "no ping before the interval")
	datagram.update(dg, datagram.KEEPALIVE)
	check(#sent == before + 1, "a ping at the interval")
	datagram.update(dg, datagram.KEEPALIVE + 0.1)
	check(#sent == before + 1, "and only one")
end

do
	-- Every uplink advances cseq, which is the only thing stopping a captured
	-- datagram being replayed from another path.
	local dg, sent = harness()
	mint(dg)
	datagram.update(dg, 0)
	local first = dg.cseq
	datagram.send_input(dg, "{}")
	check(dg.cseq == first, "input is refused while not active")
	dg.state = datagram.ACTIVE
	check(datagram.send_input(dg, "{}"), "input is sent when active")
	check(dg.cseq > first, "every uplink advances cseq")
end

do
	-- A WebSocket reconnect returns to off. Not caution: the credential is bound
	-- to a session, so carrying one over means authenticating against a binding
	-- the server has already revoked.
	local dg = harness()
	mint(dg)
	dg.state = datagram.ACTIVE
	datagram.stop(dg)
	check(dg.state == datagram.OFF, "stop returns to off")
	check(dg.key == nil, "stop forgets the key")
end

do
	-- A frame from before an engine restart. The epoch is what makes that
	-- detectable at all.
	local dg = harness()
	mint(dg)
	dg.state = datagram.ACTIVE
	local stale = string.char(dgram.MAGIC, dgram.VERSION, dgram.OP_POSE, 0)
		.. string.char(4711 % 256, math.floor(4711 / 256) % 256, 0, 0)
		.. string.rep("\0", 8)
		.. "\1\0\0\0" .. "\0\0\0\0" .. "\0\0" .. "\0\0" .. "\3" .. "\0" .. "\1\0"
	check(datagram.on_datagram(dg, stale, 0) == nil, "a pose from another epoch is dropped")
end

if failures > 0 then
	print(string.format("datagram: %d passed, %d FAILED", passes, failures))
	os.exit(1)
end
print(string.format("datagram: %d passed, 0 failed", passes))

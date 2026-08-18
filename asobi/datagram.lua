-- The datagram plane's client state machine (asobi ADR 0012, decision 13).
--
--     off -> minting -> probing -> active -> degraded -> off
--
-- **The WebSocket carries everything in every state.** There is no state in
-- which correctness depends on this plane, which is what makes a browser's
-- permanent exclusion an asymmetry rather than a wound, and what makes an SDK
-- that never ships the carrier a legitimate end state rather than a broken one.
--
-- Everything here is a pure function of a state table plus injected `now`,
-- `send` and `sha256`, so the timings that matter - the probe ladder, the hard
-- give-up, the keepalive, the degradation threshold - are testable without a
-- socket, a clock or a server.
--
-- ## The states
--
--   off       Nothing minted. The only terminal state, and a fine place to live.
--   minting   asobi.datagram.open is in flight over the WebSocket.
--   probing   Credentials in hand, hello sent, waiting for the challenge.
--   active    Bound. Pose is arriving and transform fields come from it.
--   degraded  Bound once, but no pose for 2s. Transform fields go back to
--             world.tick and a fresh hello goes out.
--
-- ## Why probing gives up
--
-- A client that retried forever would sit behind a firewall that will never pass
-- UDP, burning a little battery on every retry and reporting nothing. Three
-- attempts over three seconds is enough for a path that works and short enough
-- that a path that does not is discovered while the player is still on the
-- loading screen.
--
-- ## Why the keepalive is the client's job
--
-- With a NAT anywhere in the path a quiet client loses its mapping and the
-- downlink is blackholed with no signal at all. Only a client-originated packet
-- recreates it, so server heartbeats cannot fix this. Ten seconds is one third
-- of the common 30s unreplied default and costs about 35 bit/s.

local dgram = require("asobi.dgram")

local M = {}

M.OFF = "off"
M.MINTING = "minting"
M.PROBING = "probing"
M.ACTIVE = "active"
M.DEGRADED = "degraded"

-- ADR 0012, decision 13. Seconds.
local PROBE_BACKOFF = { 0.2, 0.4, 0.8 }
local PROBE_GIVE_UP = 3.0
local KEEPALIVE = 10.0
local DEGRADE_AFTER = 2.0

-- Creates a fresh state machine in `off`.
--
-- `deps.send(bytes)` puts one datagram on the wire, `deps.now()` returns
-- monotonic seconds, `deps.sha256(bytes)` returns 32 raw bytes.
function M.new(deps)
	return {
		state = M.OFF,
		deps = deps,
		cseq = 0,
		conn_id = nil,
		key = nil,
		epoch = nil,
		fields = nil,
		-- Slot -> id, per zone. The pose plane carries slots and the WebSocket
		-- carries the bindings, so this is the same table asobi/wire.lua builds
		-- and it is read, never written, here.
		last_pose_at = nil,
		probe_started_at = nil,
		probe_attempt = 0,
		next_probe_at = nil,
		next_ping_at = nil,
	}
end

-- Records the mint reply and moves to `probing`.
--
-- `manifest` is the transform field list, in canonical order, exactly as the
-- server declared it. Everything the decoder needs arrives here, once, over TLS.
function M.on_mint(dg, reply)
	local conn_id = reply.conn_id
	local kup = reply.kup
	if type(conn_id) ~= "number" or type(kup) ~= "string" or #kup == 0 then
		-- A mint that does not parse is not worth probing against. Back to off,
		-- where the WebSocket carries everything as it already was.
		return M.stop(dg)
	end
	dg.conn_id = conn_id
	dg.key = dgram.new_key(kup, dg.deps.sha256)
	dg.epoch = reply.epoch
	dg.fields = reply.fields or {}
	dg.state = M.PROBING
	dg.probe_attempt = 0
	dg.probe_started_at = dg.deps.now()
	dg.next_probe_at = dg.deps.now()
	return dg
end

-- Marks the plane as being minted, so update/2 does not start a second one.
function M.begin_mint(dg)
	dg.state = M.MINTING
	return dg
end

-- Returns to `off` and forgets every credential.
--
-- Called on any WebSocket reconnect, and that is not caution: the credential is
-- bound to a session, so carrying one across a reconnect means authenticating
-- against a binding the server has already revoked.
function M.stop(dg)
	dg.state = M.OFF
	dg.conn_id = nil
	dg.key = nil
	dg.epoch = nil
	dg.last_pose_at = nil
	dg.next_probe_at = nil
	dg.next_ping_at = nil
	dg.probe_attempt = 0
	return dg
end

-- Whether transform fields should currently come from the datagram plane.
--
-- The one question the rest of the SDK asks. False in every state but `active`,
-- so world.tick's transform fields are applied unconditionally the moment the
-- plane stops delivering - which is the whole fallback, in one predicate.
function M.pose_authoritative(dg)
	return dg.state == M.ACTIVE
end

-- Drives every timer. Call once per frame with monotonic seconds.
function M.update(dg, now)
	if dg.state == M.PROBING then
		return M.update_probing(dg, now)
	elseif dg.state == M.ACTIVE or dg.state == M.DEGRADED then
		return M.update_bound(dg, now)
	end
	return dg
end

function M.update_probing(dg, now)
	if now - dg.probe_started_at >= PROBE_GIVE_UP then
		-- A path that has not worked in three seconds is a path that does not
		-- pass UDP. Stopping is the honest answer and costs nothing.
		return M.stop(dg)
	end
	if dg.next_probe_at and now >= dg.next_probe_at then
		dg.probe_attempt = dg.probe_attempt + 1
		M.send_hello(dg)
		local backoff = PROBE_BACKOFF[dg.probe_attempt] or PROBE_BACKOFF[#PROBE_BACKOFF]
		dg.next_probe_at = now + backoff
	end
	return dg
end

function M.update_bound(dg, now)
	if dg.state == M.ACTIVE and dg.last_pose_at and now - dg.last_pose_at >= DEGRADE_AFTER then
		-- Nothing has arrived for two seconds. The path may have changed under a
		-- rewriting middlebox, which the server cannot see and this client can
		-- only assert - so re-hello and go back to world.tick meanwhile.
		dg.state = M.DEGRADED
		M.send_hello(dg)
		dg.next_probe_at = now + PROBE_BACKOFF[1]
	elseif dg.state == M.DEGRADED and dg.next_probe_at and now >= dg.next_probe_at then
		M.send_hello(dg)
		dg.next_probe_at = now + PROBE_BACKOFF[#PROBE_BACKOFF]
	end
	if dg.next_ping_at and now >= dg.next_ping_at then
		M.send_ping(dg, now)
	end
	return dg
end

-- Handles one decoded datagram. Returns a pose frame for the caller to apply, or
-- nil for anything that is not one.
function M.on_datagram(dg, raw, now)
	local frame = dgram.decode(raw)
	if not frame then return nil end
	-- A datagram naming someone else is either a stale mapping or a stray
	-- packet, and applying it would be applying another player's world.
	if frame.conn_id ~= dg.conn_id then return nil end

	if frame.opcode == dgram.OP_HELLO_OK then
		M.send_confirm(dg, frame.body)
		return nil
	elseif frame.opcode == dgram.OP_PONG then
		return nil
	elseif frame.opcode == dgram.OP_POSE then
		if dg.state ~= M.ACTIVE and dg.state ~= M.DEGRADED then
			-- The first pose is what proves the binding completed: the server
			-- sends none until the challenge is echoed.
			dg.state = M.ACTIVE
			dg.next_ping_at = now + KEEPALIVE
		else
			dg.state = M.ACTIVE
		end
		dg.last_pose_at = now
		local pose = dgram.decode_pose(frame.body, #dg.fields)
		if pose and dg.epoch and pose.epoch ~= dg.epoch then
			-- A frame from before an engine restart. Dropping it rather than
			-- applying it is what the epoch is for.
			return nil
		end
		return pose
	end
	return nil
end

-- --- Uplink ---

function M.send_hello(dg)
	dg.cseq = dg.cseq + 1
	dg.deps.send(
		dgram.encode_uplink(
			dgram.OP_HELLO, dg.conn_id, dg.cseq, "", dg.key, dgram.MIN_HELLO
		)
	)
end

function M.send_confirm(dg, challenge)
	dg.cseq = dg.cseq + 1
	dg.deps.send(
		dgram.encode_uplink(dgram.OP_HELLO_CONFIRM, dg.conn_id, dg.cseq, challenge, dg.key)
	)
end

function M.send_ping(dg, now)
	dg.cseq = dg.cseq + 1
	dg.deps.send(
		dgram.encode_uplink(dgram.OP_PING, dg.conn_id, dg.cseq, string.rep("\0", 8), dg.key)
	)
	dg.next_ping_at = now + KEEPALIVE
end

-- Sends a world.input over the datagram plane.
--
-- Returns false when the plane is not active, and the caller then sends it over
-- the WebSocket exactly as before. An input must never be lost because the plane
-- was between states.
function M.send_input(dg, payload)
	if dg.state ~= M.ACTIVE then return false end
	dg.cseq = dg.cseq + 1
	dg.deps.send(dgram.encode_uplink(dgram.OP_INPUT, dg.conn_id, dg.cseq, payload, dg.key))
	return true
end

M.KEEPALIVE = KEEPALIVE
M.DEGRADE_AFTER = DEGRADE_AFTER
M.PROBE_GIVE_UP = PROBE_GIVE_UP

return M

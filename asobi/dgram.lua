-- Codec for asobi's datagram plane (ADR 0012, as re-accepted by ADR 0013).
--
-- Mirrors asobi/src/dgram/asobi_dgram.erl. Pure: no sockets, no clock, no
-- global state, so every byte-level decision here is testable with plain `lua`.
--
-- Layout, every multi-byte value LITTLE-endian - the same choice the binary
-- world.tick wire makes, and for the same reason: Godot's byte readers have no
-- big-endian counterpart, and one carrier in each byte order is a trap.
--
--   prefix(16)  Magic:8=0xA5, Version:8, Opcode:8, Flags:8,
--               ConnId:32, PathTag:64
--   uplink      prefix, CSeq:64, <body>, Mac:16
--   downlink    prefix, <body>                     (no MAC - see below)
--
--   pose body   Tick:32, BSeq:32, ZoneX:16/signed, ZoneY:16/signed,
--               FieldMask:8, Count:8, Epoch:16, Records
--   record      Slot:16, Gen:8, RMask:8, [Value:16/signed]*
--
-- The downlink carries no MAC and no encryption, and that is a real reduction
-- stated plainly rather than buried: the plane provides off-path forgery
-- resistance and no confidentiality or on-path integrity. Everything with
-- authority travels only on the TLS WebSocket. A forged pose can make this
-- client's own RENDER of other entities wrong for one interval, and nothing
-- else - it cannot create or remove an entity or touch a state field, because
-- there is nowhere in a record to say so.

local M = {}

M.MAGIC = 0xA5
M.VERSION = 1

M.OP_HELLO = 1
M.OP_HELLO_OK = 2
M.OP_HELLO_CONFIRM = 3
M.OP_BYE = 4
M.OP_PING = 5
M.OP_PONG = 6
M.OP_POSE = 7
M.OP_INPUT = 8

M.MIN_HELLO = 64
M.MAC_BYTES = 16
M.PREFIX_BYTES = 16
M.CSEQ_BYTES = 8

local byte = string.byte
local char = string.char
local sub = string.sub
local floor = math.floor

-- Arithmetic only: no `bit32`, no bitwise operators, so the same source runs on
-- LuaJIT and on the Lua 5.1 an HTML5 export uses. Same constraint as
-- asobi/device.lua and asobi/wire.lua.
local function bxor_byte(a, b)
	local r, bit = 0, 1
	for _ = 1, 8 do
		local x, y = a % 2, b % 2
		if x ~= y then r = r + bit end
		a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
	end
	return r
end

-- --- Little-endian writers and readers ---

local function u16(n)
	return char(n % 256, floor(n / 256) % 256)
end

local function u32(n)
	return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end

-- Up to 2^53, which is where the server caps every counter it writes precisely
-- so a Lua double holds it exactly.
local function u64(n)
	local out = {}
	for _ = 1, 8 do
		out[#out + 1] = char(n % 256)
		n = floor(n / 256)
	end
	return table.concat(out)
end

local function read_u16(raw, pos)
	local b1, b2 = byte(raw, pos, pos + 1)
	return b1 + b2 * 256, pos + 2
end

local function read_i16(raw, pos)
	local v, next_pos = read_u16(raw, pos)
	if v >= 32768 then v = v - 65536 end
	return v, next_pos
end

local function read_u32(raw, pos)
	local b1, b2, b3, b4 = byte(raw, pos, pos + 3)
	return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216, pos + 4
end

-- --- HMAC-SHA256, truncated to 128 bits ---

-- The padded keys are derived ONCE per session and kept, so an uplink datagram
-- costs two sha256 calls and no bit twiddling at all. Doing the padding per
-- datagram would put 1024 arithmetic XOR steps on every movement packet.
function M.new_key(kup, sha256)
	local block = 64
	if #kup > block then kup = sha256(kup) end
	local ipad, opad = {}, {}
	for i = 1, block do
		local k = i <= #kup and byte(kup, i) or 0
		ipad[i] = char(bxor_byte(k, 0x36))
		opad[i] = char(bxor_byte(k, 0x5c))
	end
	return { ipad = table.concat(ipad), opad = table.concat(opad), sha256 = sha256 }
end

function M.mac(key, message)
	local inner = key.sha256(key.ipad .. message)
	return sub(key.sha256(key.opad .. inner), 1, M.MAC_BYTES)
end

-- --- Uplink ---

-- Builds one authenticated uplink datagram.
--
-- `pad_to` exists for `hello` alone and is an anti-amplification control rather
-- than framing: the server drops a short hello BEFORE doing MAC work, so that no
-- reply can ever be larger than the request that caused it. The padding goes
-- INSIDE the MAC's coverage, or an attacker would simply strip it back off.
function M.encode_uplink(opcode, conn_id, cseq, body, key, pad_to)
	body = body or ""
	pad_to = pad_to or 0
	local floor_len = pad_to - M.PREFIX_BYTES - M.CSEQ_BYTES - M.MAC_BYTES
	if #body < floor_len then body = body .. string.rep("\0", floor_len - #body) end
	local signed = char(M.MAGIC, M.VERSION, opcode, 0)
		.. u32(conn_id)
		-- path_tag is always zero on an uplink: there is no return-path handle
		-- for a client to carry, and the server refuses a non-zero one rather
		-- than parsing whatever was smuggled in it.
		.. string.rep("\0", 8)
		.. u64(cseq)
		.. body
	return signed .. M.mac(key, signed)
end

-- --- Downlink ---

-- Decodes one datagram from the gateway, or returns nil.
--
-- Total by construction: these bytes arrive unauthenticated from anywhere, so a
-- decoder that raised would hand anyone on the path a way to crash the game.
function M.decode(raw)
	if type(raw) ~= "string" or #raw < M.PREFIX_BYTES then return nil end
	if byte(raw, 1) ~= M.MAGIC or byte(raw, 2) ~= M.VERSION then return nil end
	-- Every flag bit is reserved and must be zero. Dropping rather than masking
	-- is what stops a flag defined later being silently ignored by an old client.
	if byte(raw, 4) ~= 0 then return nil end

	local opcode = byte(raw, 3)
	local conn_id = read_u32(raw, 5)
	return { opcode = opcode, conn_id = conn_id, body = sub(raw, M.PREFIX_BYTES + 1) }
end

-- Decodes a pose body into { tick, bseq, zone, epoch, records }.
--
-- Each record is { slot, gen, values } where `values` is in manifest order,
-- carrying only the fields whose bit is set. The manifest arrived once over TLS
-- in the mint response, which is what lets this be a fixed layout rather than
-- something self-describing.
function M.decode_pose(body, field_count)
	if type(body) ~= "string" or #body < 16 then return nil end
	local tick, pos = read_u32(body, 1)
	local bseq
	bseq, pos = read_u32(body, pos)
	local zx, zy
	zx, pos = read_i16(body, pos)
	zy, pos = read_i16(body, pos)
	local fieldmask = byte(body, pos)
	local count = byte(body, pos + 1)
	pos = pos + 2
	local epoch
	epoch, pos = read_u16(body, pos)

	local records = {}
	for _ = 1, count do
		if pos + 3 > #body then return nil end
		local slot
		slot, pos = read_u16(body, pos)
		local gen = byte(body, pos)
		local rmask = byte(body, pos + 1)
		pos = pos + 2
		local values = {}
		for f = 1, field_count do
			-- floor(rmask / 2^(f-1)) % 2 is the bit test, arithmetic only.
			if floor(rmask / 2 ^ (f - 1)) % 2 == 1 then
				if pos + 1 > #body then return nil end
				values[f], pos = read_i16(body, pos)
			end
		end
		records[#records + 1] = { slot = slot, gen = gen, values = values }
	end

	if pos ~= #body + 1 then
		-- Trailing bytes mean this decoder and the frame disagree about the
		-- layout, and a half-read frame is worse than a dropped one.
		return nil
	end
	return {
		tick = tick,
		bseq = bseq,
		zone = { zx, zy },
		fieldmask = fieldmask,
		epoch = epoch,
		records = records,
	}
end

return M

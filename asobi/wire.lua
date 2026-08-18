-- Decoder for asobi's binary `world.tick` frame.
--
-- Same information as the JSON frame in about a quarter of the bytes, and the
-- decode is the part that matters here: stock Lua has no native JSON, so this
-- SDK ships a pure-Lua parser, and a 40-entity delta costs it around 440 us per
-- frame. At 20 Hz that is close to 1% of a mobile CPU doing nothing but reading
-- text. The same frame through this decoder is a byte loop over about a quarter of
-- the bytes.
--
-- Arithmetic only: no `string.unpack`, no `bit32`, no bitwise operators. LOVE 11
-- ships LuaJIT, which is Lua 5.1 with extensions and has none of them, and the same
-- code then also runs unchanged on a 5.4 build. Same constraint as asobi/device.lua.
--
-- The output is the shape realtime.lua's own normalise_delta already accepts, so
-- a decoded frame goes through exactly the same zone reconciliation, gap
-- detection and callbacks as a JSON one. Nothing downstream learns which wire
-- delivered it.
--
-- Layout, every multi-byte value LITTLE-endian (Godot's native byte readers have
-- no big-endian counterpart, so the wire follows the runtime with least room to
-- spare):
--
--   frame    Kind:8, ZX:32, ZY:32, FrameSeq:64, Kf:8, Tick:64,
--            DictLen:8, Dict, RecCount:16, Records
--   dict     for each name: Len:8, Name          (at most 32 names)
--   record   Op:8, Slot:16, Gen:8, [IdLen:8, Id]?, FieldCount:8, Fields
--   field    Type:3, Idx:5, Value                (one header byte)

local M = {}

local KIND_SEQUENCED = 1
local KIND_UNGATED = 2

-- The short op names the JSON wire uses, so a decoded record needs no
-- translation on the way into a reconciler.
local OPS = {[0] = "a", [1] = "u", [2] = "r"}

local T_F32 = 0
local T_I32 = 1
local T_TRUE = 2
local T_FALSE = 3
local T_STR = 4
local T_NULL = 5

local byte = string.byte
local sub = string.sub
local floor = math.floor

-- The header alone, before any dictionary or record.
local MIN_FRAME = 27

local function read_u8(raw, pos)
	return byte(raw, pos), pos + 1
end

local function read_u16(raw, pos)
	local b1, b2 = byte(raw, pos, pos + 1)
	return b1 + b2 * 256, pos + 2
end

local function read_i32(raw, pos)
	local b1, b2, b3, b4 = byte(raw, pos, pos + 3)
	local v = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	if v >= 2147483648 then v = v - 4294967296 end
	return v, pos + 4
end

-- 64-bit unsigned, accumulated as a double. The server caps frame_seq and tick at
-- 2^53-1 precisely so this is exact rather than approximate.
local function read_u64(raw, pos)
	local v = 0
	for i = 7, 0, -1 do
		v = v * 256 + byte(raw, pos + i)
	end
	return v, pos + 8
end

-- IEEE-754 binary32, assembled by hand. `string.unpack` would be one call and is
-- unavailable on two of this SDK's three Lua runtimes.
local function read_f32(raw, pos)
	local b1, b2, b3, b4 = byte(raw, pos, pos + 3)
	local sign = 1
	if b4 >= 128 then
		sign = -1
		b4 = b4 - 128
	end
	local exponent = b4 * 2 + floor(b3 / 128)
	local mantissa = ((b3 % 128) * 65536) + (b2 * 256) + b1
	if exponent == 0 then
		if mantissa == 0 then return sign * 0.0, pos + 4 end
		return sign * mantissa * 2 ^ -149, pos + 4
	elseif exponent == 255 then
		if mantissa == 0 then return sign * math.huge, pos + 4 end
		return 0 / 0, pos + 4
	end
	return sign * (1 + mantissa / 8388608) * 2 ^ (exponent - 127), pos + 4
end

-- Only needed by transports that lose the WebSocket opcode. asobi.websocket keeps
-- it and routes binary frames to on_binary, so this SDK never has to guess - it is
-- exported for a game supplying its own transport.
function M.is_binary_frame(raw)
	if type(raw) ~= "string" or #raw < 1 then return false end
	return byte(raw, 1) ~= 123
end

-- Slot -> entity id, one table per zone. Slot 5 in one zone has nothing to do
-- with slot 5 in another, so a single flat table would alias entities across
-- zones - the same corruption that keying entities by zone exists to prevent.
function M.new()
	return {slots = {}}
end

-- Forgets every binding, for a reconnect. Bindings are established by the adds
-- THIS connection received, so carrying them over would attach stale ids to slots
-- the server has since handed to different entities. The keyframe that follows a
-- reconnect rebuilds the table anyway.
function M.reset(state)
	state.slots = {}
end

-- Decodes one frame into the payload table realtime.lua's _dispatch_tick expects.
-- Returns nil on malformed bytes rather than raising: these come off the network,
-- and crashing a game on a truncated frame is worse than dropping it.
function M.decode(state, raw)
	if type(raw) ~= "string" or #raw < MIN_FRAME then return nil end
	local len = #raw

	local kind, pos = read_u8(raw, 1)
	if kind ~= KIND_SEQUENCED and kind ~= KIND_UNGATED then return nil end

	local zx, zy, frame_seq, kf_byte, tick
	zx, pos = read_i32(raw, pos)
	zy, pos = read_i32(raw, pos)
	frame_seq, pos = read_u64(raw, pos)
	kf_byte, pos = read_u8(raw, pos)
	tick, pos = read_u64(raw, pos)

	local dict_len
	dict_len, pos = read_u8(raw, pos)
	local names = {}
	for i = 1, dict_len do
		if pos > len then return nil end
		local name_len
		name_len, pos = read_u8(raw, pos)
		if pos + name_len - 1 > len then return nil end
		names[i] = sub(raw, pos, pos + name_len - 1)
		pos = pos + name_len
	end

	if pos + 1 > len then return nil end
	local rec_count
	rec_count, pos = read_u16(raw, pos)

	local zkey = zx .. ":" .. zy
	local table_for_zone = state.slots[zkey]
	if not table_for_zone then
		table_for_zone = {}
		state.slots[zkey] = table_for_zone
	end

	local updates = {}
	for r = 1, rec_count do
		if pos + 3 > len then return nil end
		local op_byte, slot, gen
		op_byte, pos = read_u8(raw, pos)
		slot, pos = read_u16(raw, pos)
		-- The slot's generation, advancing every time it is rebound to a different
		-- entity. Redundant on this ordered, reliable wire and carried anyway, so a
		-- client also running the datagram plane keeps ONE slot table for both.
		gen, pos = read_u8(raw, pos)
		local op = OPS[op_byte]
		if not op then return nil end

		local id
		if op == "a" then
			if pos > len then return nil end
			local id_len
			id_len, pos = read_u8(raw, pos)
			if pos + id_len - 1 > len then return nil end
			id = sub(raw, pos, pos + id_len - 1)
			pos = pos + id_len
			-- An add ESTABLISHES the binding and replaces whatever was there.
			-- Slots are reused once freed, so a stale binding surviving an add
			-- would attach the wrong entity to every later update on that slot.
			table_for_zone[slot] = id
		else
			id = table_for_zone[slot]
		end

		-- Fields go at the TOP level of the record, and `op` is the short form,
		-- so a decoded record is byte-for-byte the shape the JSON wire sends.
		-- Every SDK reconciler already reads that shape, which is what makes the
		-- binary wire invisible downstream.
		local record = {op = op, id = id, gen = gen}

		if pos > len then return nil end
		local field_count
		field_count, pos = read_u8(raw, pos)
		for _ = 1, field_count do
			if pos > len then return nil end
			local header
			header, pos = read_u8(raw, pos)
			local ftype = floor(header / 32)
			local idx = header % 32
			local key = names[idx + 1]
			if not key then return nil end
			if ftype == T_F32 then
				if pos + 3 > len then return nil end
				record[key], pos = read_f32(raw, pos)
			elseif ftype == T_I32 then
				if pos + 3 > len then return nil end
				record[key], pos = read_i32(raw, pos)
			elseif ftype == T_TRUE then
				record[key] = true
			elseif ftype == T_FALSE then
				record[key] = false
			elseif ftype == T_STR then
				if pos + 1 > len then return nil end
				local slen
				slen, pos = read_u16(raw, pos)
				if pos + slen - 1 > len then return nil end
				record[key] = sub(raw, pos, pos + slen - 1)
				pos = pos + slen
			elseif ftype == T_NULL then
				-- Lua has no way to hold a nil in a table, so a null field is
				-- absent rather than present-and-nil. Same as the JSON path,
				-- where json.decode drops it for the same reason.
				record[key] = nil
			else
				return nil
			end
		end

		-- Released only AFTER the record is built, so the frame that announces an
		-- entity's departure still carries its id.
		if op == "r" then
			table_for_zone[slot] = nil
		end

		-- `id` is nil when the slot has no binding, which means the add that would
		-- have established it was lost. The record is still reported rather than
		-- dropped: the frame genuinely says "this slot changed", and silently
		-- shortening the update list would hide the fact. The reconciler drops an
		-- id-less delta, and the frame_seq gap that caused it drives the resync
		-- that repairs the mapping.
		updates[#updates + 1] = record
	end

	if pos ~= len + 1 then
		-- Trailing bytes mean the frame and this decoder disagree about the
		-- layout, and accepting it would hand the game a half-read frame.
		return nil
	end

	local payload = {
		zone = {zx, zy},
		tick = tick,
		updates = updates,
	}
	-- A sequenced frame holds a position in the zone's stream; an ungated one does
	-- not, and says so on the text wire by having no frame_seq at all. Leave it
	-- out here too, so the gap detector treats both wires identically.
	if kind == KIND_SEQUENCED then
		payload.frame_seq = frame_seq
		payload.kf = kf_byte ~= 0
	end
	return payload
end

return M

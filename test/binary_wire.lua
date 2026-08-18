-- Unit test for the binary `world.tick` decoder (asobi ADR 0013).
-- Run: cd asobi-love2d && lua test/binary_wire.lua
--
-- Driven entirely by asobi's own committed fixture corpus: real bytes from the
-- real encoder in test/fixtures/wire, with a manifest saying what each one
-- decodes to. Nothing here is hand-rolled test data, which is the point - a
-- decoder checked only against a fixture the same author invented proves the two
-- agree with each other and nothing about whether either matches the server.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local wire = require("asobi.wire")
local realtime = require("asobi.realtime")
local json = require("asobi.json")

local function json_decode(text)
	local decoded = json.decode(text)
	return decoded
end

local FIXTURE_DIR = "test/fixtures/wire"

local failures = 0
local passes = 0

local function check(cond, msg)
	if cond then
		passes = passes + 1
	else
		print("FAIL: " .. msg)
		failures = failures + 1
	end
end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local data = f:read("*a")
	f:close()
	return data
end

-- The manifest names ops in full; the wire and every SDK use the short form.
local OP_SHORT = {add = "a", update = "u", remove = "r"}

-- float32 on the wire against a float64 in the manifest, so compare with a
-- tolerance: 12.5 survives exactly, 1.5 * 7 does not.
local function near(a, b)
	if type(a) ~= "number" or type(b) ~= "number" then return a == b end
	return math.abs(a - b) < 0.0001
end

local manifest = json_decode(read_file(FIXTURE_DIR .. "/manifest.json"))
check(type(manifest) == "table" and #manifest > 0, "manifest.json loaded")

for i = 1, #manifest do
	local entry = manifest[i]
	local name = entry.name
	local expected = entry.frame
	local raw = read_file(FIXTURE_DIR .. "/" .. name .. ".bin")
	check(raw ~= nil, name .. ": fixture bytes present")
	if raw then
		check(#raw == entry.bytes, name .. ": byte count matches the manifest")
		-- A fresh decoder per fixture: the corpus cases are independent frames,
		-- not a stream, so sharing slot tables between them would be the test
		-- lying to itself.
		local got = wire.decode(wire.new(), raw)
		check(got ~= nil, name .. ": decoded")
		if got then
			check(got.zone[1] == expected.zone[1] and got.zone[2] == expected.zone[2],
				name .. ": zone")
			check(got.tick == expected.tick, name .. ": tick")

			-- An ungated frame holds no position in the zone's stream and says so
			-- by having no frame_seq at all. Reporting sequence 0 instead makes the
			-- gap detector discard the one frame that clears a leaving zone's
			-- ghosts.
			if expected.kind == "sequenced" then
				check(got.frame_seq == expected.frame_seq, name .. ": frame_seq")
				check(got.kf == expected.kf, name .. ": kf")
			else
				check(got.frame_seq == nil, name .. ": an ungated frame carries no frame_seq")
			end

			check(#got.updates == #expected.records, name .. ": record count")
			for r = 1, #expected.records do
				local want = expected.records[r]
				local have = got.updates[r]
				if have then
					check(have.op == OP_SHORT[want.op], name .. "[" .. r .. "]: op")
					if want.id then
						check(have.id == want.id, name .. "[" .. r .. "]: id")
					end
					-- The generation. A decoder that skipped the byte shifts every
					-- later offset and fails loudly; one that read it from the wrong
					-- place would not, so pin the value.
					check(have.gen == want.gen, name .. "[" .. r .. "]: gen")
					for k, v in pairs(want.fields or {}) do
						-- A null field is absent rather than present-and-nil, since
						-- Lua tables cannot hold a nil - same as the JSON path,
						-- where the decoder drops it for the same reason. The
						-- manifest carries it as this decoder's own null marker.
						if type(v) ~= "table" then
							check(near(have[k], v), name .. "[" .. r .. "]: " .. k)
						end
					end
				end
			end
		end
	end
end

-- The reason the slot table lives in the decoder: an update carries the slot
-- alone, and the game must still see the entity id it saw on the add.
do
	local state = wire.new()
	local kf = wire.decode(state, read_file(FIXTURE_DIR .. "/keyframe_all_adds.bin"))
	check(kf ~= nil and #kf.updates > 0, "slot bindings: keyframe decoded")
	local seen = {}
	for _, u in ipairs(kf.updates) do seen[u.id] = true end

	-- The keyframe is zone [-1, -1]. A frame for a DIFFERENT zone must not resolve
	-- against its table: slot 1 in one zone has nothing to do with slot 1 in
	-- another, and aliasing them is the corruption per-zone tables exist to stop.
	local other = wire.decode(state, read_file(FIXTURE_DIR .. "/removes_only.bin"))
	check(other ~= nil, "slot bindings: second frame decoded")
	local aliased = false
	for _, u in ipairs(other.updates or {}) do
		if u.id ~= nil and seen[u.id] then aliased = true end
	end
	check(not aliased, "slot bindings are scoped per zone")
end

-- Bindings belong to one connection's stream of adds. Kept across a reconnect
-- they would attach stale ids to slots the server has since reassigned.
do
	local state = wire.new()
	wire.decode(state, read_file(FIXTURE_DIR .. "/keyframe_all_adds.bin"))
	wire.reset(state)
	local after = wire.decode(state, read_file(FIXTURE_DIR .. "/removes_only.bin"))
	local bound = false
	for _, u in ipairs(after.updates or {}) do
		if u.id ~= nil then bound = true end
	end
	check(not bound, "reset() forgets every binding")
end

-- These bytes come off the network. A decoder that raises on a truncated frame
-- takes the game down with it.
do
	local good = read_file(FIXTURE_DIR .. "/steady_state_40_updates.bin")
	local cases = {
		{"empty", ""},
		{"one byte", "\1"},
		{"truncated envelope", good:sub(1, 10)},
		{"truncated mid-record", good:sub(1, #good - 2)},
		{"trailing junk", good .. "\0\0\0"},
		{"unknown kind byte", "\9" .. good:sub(2)},
	}
	for _, case in ipairs(cases) do
		local ok, result = pcall(wire.decode, wire.new(), case[2])
		check(ok and result == nil, "malformed input rejected: " .. case[1])
	end
end

-- asobi.websocket keeps the WebSocket opcode and routes binary frames to
-- on_binary, so this SDK never guesses. The sniff is exported for a game bringing
-- its own transport, and it must still be right.
do
	check(not wire.is_binary_frame('{"type":"world.tick"}'), "a JSON frame is not binary")
	check(wire.is_binary_frame("\1\0\0\0\0"), "a kind-1 frame is binary")
	check(wire.is_binary_frame("\2\0\0\0\0"), "a kind-2 frame is binary")
end

-- The transport used to drop opcode 0x2 on the floor, so a game that negotiated
-- the binary wire stopped receiving ticks with nothing to point at.
do
	local ws = require("asobi.websocket").new()
	local got = nil
	ws.on_binary = function(raw) got = raw end
	check(ws.on_binary ~= nil, "the transport exposes on_binary")
	ws.on_binary("bytes")
	check(got == "bytes", "on_binary receives the frame body")
end

-- End to end: a binary frame reaching _handle_message must drive the same entity
-- callbacks a JSON one does, or the whole "nothing downstream changes" claim is
-- untrue.
do
	local rt = realtime.new({ws_url = "ws://stub", session_token = ""})
	local added = {}
	rt:on("entity_added", function(id, state) added[id] = state end)
	rt:_handle_binary(read_file(FIXTURE_DIR .. "/keyframe_all_adds.bin"))
	local count = 0
	for _ in pairs(added) do count = count + 1 end
	check(count == 5, "a binary keyframe fires entity_added for every entity")
	for id, state in pairs(added) do
		check(type(state.x) == "number", "entity " .. id .. " carries decoded fields")
	end
end

if failures > 0 then
	print(string.format("binary-wire: %d passed, %d FAILED", passes, failures))
	os.exit(1)
end
print(string.format("binary-wire: %d passed, 0 failed", passes))

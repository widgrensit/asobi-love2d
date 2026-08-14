-- `world.ack` is asobi core's client-side-prediction ack (core v0.84.0):
--   {"type":"world.ack","payload":{"tick":42,"seq":7}}
-- The server echoes the highest world.input `seq` it has consumed for you as
-- of `tick`. It fires on("world_ack"). An explicit dispatch case reclaims it
-- ahead of the generic world.* catch-all, which previously mis-routed the
-- brand-new frame to on("world_event") as name "ack".
--
-- Pure unit test, plain Lua:
--   lua5.4 test/world_ack.lua

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

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function new_rt()
	return asobi.new({host = "x", port = 1}).realtime
end

do
	local raw = read_file("test/fixtures/world.ack.json")
	check(raw ~= nil, "world.ack.json fixture is present")
	local rt = new_rt()
	local payload
	rt:on("world_ack", function(p) payload = p end)
	rt:_handle_message(raw)
	check(payload ~= nil, "world.ack fires on(world_ack)")
	check(payload and payload.tick == 42, "payload.tick reaches the callback")
	check(payload and payload.seq == 412, "payload.seq reaches the callback")
end

-- The explicit case must win over the generic world.* catch-all: world.ack
-- reaches on(world_ack) and never on(world_event) as name "ack".
do
	local rt = new_rt()
	local acked, strayed
	rt:on("world_ack", function(p) acked = p end)
	rt:on("world_event", function(name) strayed = name end)
	rt:_handle_message('{"type":"world.ack","payload":{"tick":9,"seq":3}}')
	check(acked ~= nil and acked.seq == 3, "world.ack routes to the typed on(world_ack)")
	check(strayed == nil, "world.ack never falls through to the generic world_event catch-all")
end

if failures > 0 then
	print("FAILED: " .. failures)
	os.exit(1)
end
print("all world-ack checks passed")

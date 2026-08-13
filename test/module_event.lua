-- `module.event` is a named push from an extension:
--   {"type":"module.event","payload":{"module":"quests","event":"quests.completed","data":{...}}}
-- The whole payload {module, event, data} is surfaced to on("module_event")
-- and the app routes on payload.event. The inner event name is data, not a
-- dispatch gate, so an unfamiliar name still surfaces rather than being
-- dropped — load-bearing for the frozen 1.0 wire.
--
-- Pure unit test, plain Lua:
--   lua5.4 test/module_event.lua

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
	local raw = read_file("test/fixtures/module.event.json")
	check(raw ~= nil, "module.event.json fixture is present")
	local rt = new_rt()
	local payload
	rt:on("module_event", function(p) payload = p end)
	rt:_handle_message(raw)
	check(payload ~= nil, "module.event fires on(module_event)")
	check(payload and payload.module == "quests", "payload.module reaches the callback")
	check(payload and payload.event == "quests.completed", "payload.event reaches the callback")
	check(payload and payload.data and payload.data.reward == 250, "payload.data reaches the callback intact")
end

-- The inner event name is data, not a dispatch gate: an extension can name an
-- event the SDK has never heard of and the frame must still surface.
do
	local rt = new_rt()
	local payload
	rt:on("module_event", function(p) payload = p end)
	rt:_handle_message(
		'{"type":"module.event","payload":{"module":"mystery","event":"mystery.happened","data":{"x":1}}}')
	check(payload ~= nil, "an unfamiliar inner event still surfaces")
	check(payload and payload.event == "mystery.happened", "the unfamiliar event name reaches the callback")
	check(payload and payload.data and payload.data.x == 1, "the unfamiliar event's data reaches the callback")
end

if failures > 0 then
	print("FAILED: " .. failures)
	os.exit(1)
end
print("all module-event checks passed")

-- realtime:on(event, cb) appends a handler; multiple handlers for one event
-- all fire, in registration order, each with the full argument list. A handler
-- that registers another mid-dispatch runs on the next dispatch, not the
-- current one (re-entrancy safety).
--
-- Pure unit test, plain Lua:
--   lua5.4 test/multi_handler.lua

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

-- Two handlers for one event both fire, in registration order, with full args.
do
	local rt = new_rt()
	local order = {}
	rt:on("game_message", function(p) order[#order + 1] = "a:" .. tostring(p.message) end)
	rt:on("game_message", function(p) order[#order + 1] = "b:" .. tostring(p.message) end)
	rt:_handle_message('{"type":"game.message","payload":{"message":"hi"}}')
	check(#order == 2, "both handlers fired")
	check(order[1] == "a:hi", "first-registered handler fires first with full args")
	check(order[2] == "b:hi", "second-registered handler fires second with full args")
end

-- Registering once still fires exactly once.
do
	local rt = new_rt()
	local count = 0
	rt:on("game_message", function() count = count + 1 end)
	rt:_handle_message('{"type":"game.message","payload":{"message":"hi"}}')
	check(count == 1, "a single registration fires exactly once")
end

-- A handler that registers another mid-dispatch does not fire it on the
-- current pass; it fires on the next one.
do
	local rt = new_rt()
	local fired_late = 0
	rt:on("game_message", function()
		rt:on("game_message", function() fired_late = fired_late + 1 end)
	end)
	rt:_handle_message('{"type":"game.message","payload":{"message":"hi"}}')
	check(fired_late == 0, "a handler registered mid-dispatch does not fire this pass")
	rt:_handle_message('{"type":"game.message","payload":{"message":"hi"}}')
	check(fired_late == 1, "it fires on the next pass")
end

if failures > 0 then
	print("FAILED: " .. failures)
	os.exit(1)
end
print("all multi-handler checks passed")

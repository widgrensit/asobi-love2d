-- `game.broadcast(name, payload)` from a Lua match or world script arrives as
-- `match.<name>` / `world.<name>`, where <name> is script-defined. There is no
-- fixture for it in the canonical corpus for that reason, so the frames are
-- built inline here.
--
-- Pure unit test, plain Lua:
--   lua5.4 test/broadcast_event.lua

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

do
	local rt = new_rt()
	local got_name, got_payload
	rt:on("match_event", function(name, payload)
		got_name, got_payload = name, payload
	end)
	rt:_handle_message('{"type":"match.players_total","payload":{"value":3}}')
	check(got_name == "players_total", "match.players_total -> match_event with the bare name")
	check(got_payload and got_payload.value == 3, "the payload reaches the callback intact")
end

do
	local rt = new_rt()
	local got_name, got_payload
	rt:on("world_event", function(name, payload)
		got_name, got_payload = name, payload
	end)
	rt:_handle_message('{"type":"world.players_total","payload":{"value":7}}')
	check(got_name == "players_total", "world.players_total -> world_event with the bare name")
	check(got_payload and got_payload.value == 7, "the payload reaches the callback intact")
end

-- A named event already has its own callback; firing the catch-all as well
-- would deliver every match.finished twice to a game bound to both.
do
	local rt = new_rt()
	local named, generic = false, false
	rt:on("match_finished", function() named = true end)
	rt:on("match_event", function() generic = true end)
	rt:_handle_message('{"type":"match.finished","payload":{"match_id":"m1"}}')
	check(named, "match.finished still fires its named callback")
	check(not generic, "a named event does not also fire match_event")
end

do
	local rt = new_rt()
	local wrong = false
	rt:on("world_event", function() wrong = true end)
	rt:_handle_message('{"type":"match.players_total","payload":{"value":1}}')
	check(not wrong, "a match.* broadcast does not fire world_event")
end

if failures > 0 then
	print("FAILED: " .. failures)
	os.exit(1)
end
print("all broadcast-event checks passed")

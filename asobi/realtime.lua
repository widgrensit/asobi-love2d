-- Realtime WebSocket layer for asobi-love2d.
-- Wraps asobi.websocket with the asobi message envelope (type/payload/cid),
-- entity-sync diff merging, and event-name -> callback dispatch.

local websocket = require("asobi.websocket")
local json = require("asobi.json")

local M = {}
M.__index = M

-- Maps server wire `type` -> SDK callback name. Must stay in sync with
-- the asobi protocol fixture corpus (see test/fixtures/) — the dispatch
-- test in test/dispatch.lua loads every fixture and asserts the
-- callback fires.
local SERVER_EVENTS = {
	["error"] = "error",
	["session.connected"] = "connected",
	["session.heartbeat"] = "heartbeat",
	["match.state"] = "match_state",
	["match.matched"] = "match_matched",
	["match.joined"] = "match_joined",
	["match.left"] = "match_left",
	["match.finished"] = "match_finished",
	-- The reply to match.list, which this SDK could send and then had no
	-- handler for: the corpus carried the fixture and nothing routed it.
	["match.list"] = "match_list",
	["match.matchmaker_expired"] = "matchmaker_expired",
	["match.matchmaker_failed"] = "matchmaker_failed",
	["match.vote_start"] = "vote_start",
	["match.vote_tally"] = "vote_tally",
	["match.vote_result"] = "vote_result",
	["match.vote_vetoed"] = "vote_vetoed",
	["matchmaker.queued"] = "matchmaker_queued",
	["matchmaker.removed"] = "matchmaker_removed",
	["chat.joined"] = "chat_joined",
	["chat.left"] = "chat_left",
	["chat.message"] = "chat_message",
	["dm.sent"] = "dm_sent",
	["dm.message"] = "dm_message",
	["presence.updated"] = "presence_changed",
	["notification.new"] = "notification",
	["game.error"] = "game_error",
	["game.message"] = "game_message",
	-- The current names for the two frames above. The server renamed them so a
	-- second scripting runtime could use them and kept the old ones as
	-- aliases; both reach the same handler, so a game need not know which name
	-- its server is on.
	["module.error"] = "game_error",
	["module.message"] = "game_message",
	-- A named push from an extension: the whole payload {module, event, data}
	-- reaches on("module_event") and the app routes on payload.event. Unlike
	-- the two frames above it has no game.* twin, and its inner event name is
	-- data rather than a dispatch gate, so it maps to a single callback.
	["module.event"] = "module_event",
	["vote.cast_ok"] = "vote_cast_ok",
	["vote.veto_ok"] = "vote_veto_ok",
	["world.tick"] = "world_tick",
	-- Core's client-side-prediction ack {tick, seq}: the highest world.input
	-- seq the server has consumed for you as of tick. The SERVER_EVENTS lookup
	-- runs before the world.* catch-all below, which would otherwise surface
	-- this as the generic world_event named "ack".
	["world.ack"] = "world_ack",
	["world.terrain"] = "world_terrain",
	["world.list"] = "world_list",
	["world.joined"] = "world_joined",
	["world.left"] = "world_left",
	["world.phase_changed"] = "phase_changed",
	["world.finished"] = "world_finished",
}

function M.new(client)
	return setmetatable({
		client = client,
		ws = websocket.new(),
		cid_counter = 0,
		pending = {},
		callbacks = {},
		entities = {},
		local_player_id = nil,
	}, M)
end

function M:on(event, callback)
	local handlers = self.callbacks[event]
	if not handlers then
		handlers = {}
		self.callbacks[event] = handlers
	end
	handlers[#handlers + 1] = callback
end

local function fire(self, event, ...)
	local handlers = self.callbacks[event]
	if not handlers then return end
	-- Snapshot the count so a handler that registers another mid-dispatch
	-- fires on the next frame, not this one.
	local n = #handlers
	for i = 1, n do
		handlers[i](...)
	end
end

function M:_handle_message(raw)
	local msg, err = json.decode(raw)
	if not msg or err then return end
	local mtype = msg.type or ""
	local payload = msg.payload or {}
	local cid = msg.cid

	if cid and self.pending[cid] then
		local cb = self.pending[cid]
		self.pending[cid] = nil
		if mtype == "rpc.error" then
			-- The shared error object: {code, message, details}. Passing only
			-- the message would throw away the code, which is the one part a
			-- caller can branch on. An empty object still gets a code, or a
			-- server defect and a domain outcome look identical.
			local err = payload.error or {}
			err.code = err.code or "internal"
			cb(nil, err)
		elseif mtype == "rpc.ok" then
			cb(payload.result or {}, nil)
		elseif mtype == "error" then
			cb(nil, payload.reason or "unknown error")
		else
			cb(payload, nil)
		end
		return
	end

	if mtype == "session.connected" and payload.player_id then
		self.local_player_id = payload.player_id
	end

	if mtype == "world.tick" or mtype == "match.state" then
		self:_dispatch_tick(payload)
	end

	if mtype == "world.joined" or mtype == "world.left" then
		self.entities = {}
	end

	local event = SERVER_EVENTS[mtype]
	if event then
		fire(self, event, payload)
		return
	end

	-- A Lua script's `game.broadcast(name, payload)` reaches the socket as
	-- `match.<name>` (or `world.<name>` from a world script), where <name> is
	-- script-defined and so can never appear in SERVER_EVENTS. Without this
	-- the frame was dropped silently.
	local name = mtype:match("^match%.(.+)$")
	if name then
		fire(self, "match_event", name, payload)
		return
	end
	name = mtype:match("^world%.(.+)$")
	if name then fire(self, "world_event", name, payload) end
end

function M:_apply_entity_update(u)
	local id = u.id
	if not id then return nil end
	local op = u.op
	if op == "a" then
		local state = {}
		for k, v in pairs(u) do
			if k ~= "op" and k ~= "id" then state[k] = v end
		end
		self.entities[id] = state
		return {kind = "added", id = id, state = state}
	elseif op == "u" then
		local existing = self.entities[id]
		if not existing then
			existing = {}
			self.entities[id] = existing
		end
		local changed = {}
		for k, v in pairs(u) do
			if k ~= "op" and k ~= "id" then
				if existing[k] ~= v then
					existing[k] = v
					changed[#changed + 1] = k
				end
			end
		end
		if #changed == 0 then return nil end
		return {kind = "updated", id = id, state = existing, changed = changed}
	elseif op == "r" then
		self.entities[id] = nil
		return {kind = "removed", id = id}
	end
	return nil
end

function M:_dispatch_tick(payload)
	local updates = payload and payload.updates or {}
	for i = 1, #updates do
		local change = self:_apply_entity_update(updates[i])
		if change then
			if change.kind == "added" then
				fire(self, "entity_added", change.id, change.state)
			elseif change.kind == "updated" then
				fire(self, "entity_updated", change.id, change.state, change.changed)
			elseif change.kind == "removed" then
				fire(self, "entity_removed", change.id)
			end
		end
	end
	fire(self, "tick", payload.tick, payload)
end

function M:connect()
	local ws = self.ws
	ws.on_message = function(msg) self:_handle_message(msg) end
	ws.on_close = function() fire(self, "disconnected", "closed") end
	ws.on_error = function(e) fire(self, "error_raw", e) end

	local ok, err = ws:connect(self.client.ws_url)
	if not ok then return false, err end
	self:_send("session.connect", {token = self.client.session_token})
	return true
end

function M:disconnect()
	self.ws:close()
end

function M:update()
	self.ws:update()
end

function M:_send(mtype, payload)
	self.cid_counter = self.cid_counter + 1
	local frame = json.encode({
		type = mtype,
		payload = payload or {},
		cid = tostring(self.cid_counter),
	})
	self.ws:send(frame)
end

function M:_send_with_callback(mtype, payload, callback)
	self.cid_counter = self.cid_counter + 1
	local cid = tostring(self.cid_counter)
	if callback then self.pending[cid] = callback end
	local frame = json.encode({type = mtype, payload = payload or {}, cid = cid})
	self.ws:send(frame)
end

--- Call an extension's RPC method.
---
---   realtime:rpc("quests.claim", {quest_key = "daily"}, function(result, err)
---     if err then
---       if err.code == "quests.already_claimed" then ... end
---     else
---       print(result.reward)
---     end
---   end)
---
--- Correlated by cid like every other request, so concurrent calls are safe
--- and may answer out of order. `params` and `result` are always tables, so
--- either can grow a field without breaking a shipped game. On failure `err`
--- is the shared error object; branch on `err.code`, never on `err.message`.
function M:rpc(method, params, callback)
	self:_send_with_callback("rpc.call", {
		protocol = 1,
		method = method,
		params = params or {},
	}, callback)
end

function M:_send_fire_and_forget(mtype, payload, seq)
	-- seq rides as a top-level sibling of payload, never nested. Absent when
	-- nil: a nil key is omitted by the table constructor.
	local frame = json.encode({type = mtype, payload = payload or {}, seq = seq})
	self.ws:send(frame)
end

-- Join a joinable match of `mode`, spawning one when none is, instead of
-- reading match.list and then racing another client to the same entry. The
-- server serializes it, so simultaneous callers converge on one match.
-- `mode` is the only key this SDK sends; every match parameter beyond it comes
-- from the mode's server-side config.
--
-- The reply is match.joined, the frame join_match already answers with, so it
-- arrives on on("match_joined") like that one rather than on a callback.
--
-- The mode needs quick_play = true, which defaults to false for match modes;
-- one that has not opted in is refused with quick_play_disabled. Note
-- quick_play is not `listed`, which is browser visibility and a separate axis.
-- Refusals include not_found, for a mode name that is not configured at all.
-- Needs an asobi server on v0.86.0 or later.
function M:find_or_create_match(mode)
	self:_send("match.find_or_create", {mode = mode})
end

function M:join_match(match_id)
	self:_send("match.join", {match_id = match_id})
end

function M:send_match_input(input)
	self:_send_fire_and_forget("match.input", input)
end

function M:leave_match()
	self:_send("match.leave", {})
end

-- Browse the match lobby. `filters` is optional and takes `mode` (string),
-- `has_capacity` (boolean) and `joinable` (boolean); the server validates
-- each and rejects the whole request with invalid_<name>_filter on a wrong
-- type. Unlike the other two, `joinable = false` is a real filter ("show me
-- the matches that have closed") rather than the absence of one. The reply
-- arrives as on("match_list").
function M:list_matches(filters)
	self:_send("match.list", filters or {})
end

function M:cast_vote(vote_id, option_id)
	self:_send("vote.cast", {vote_id = vote_id, option_id = option_id})
end

function M:cast_veto(vote_id)
	self:_send("vote.veto", {vote_id = vote_id})
end

function M:add_to_matchmaker(opts)
	local payload = {mode = "default"}
	if type(opts) == "string" then
		payload.mode = opts
	elseif type(opts) == "table" then
		-- A positional table (e.g. {"grid2"}) sets opts[1], not opts.mode. That
		-- would otherwise silently fall through to "default" with no error.
		assert(
			opts.mode ~= nil or opts[1] == nil,
			"asobi.realtime: add_to_matchmaker(opts) needs opts.mode, e.g. {mode = \"grid2\"}, not a positional {\"grid2\"}"
		)
		payload.mode = opts.mode or "default"
		if opts.properties then payload.properties = opts.properties end
		if opts.party then payload.party = opts.party end
	end
	self:_send("matchmaker.add", payload)
end

function M:remove_from_matchmaker(ticket_id)
	self:_send("matchmaker.remove", {ticket_id = ticket_id})
end

function M:join_chat(channel_id)
	self:_send("chat.join", {channel_id = channel_id})
end

function M:send_chat_message(channel_id, content)
	self:_send_fire_and_forget("chat.send", {channel_id = channel_id, content = content})
end

function M:leave_chat(channel_id)
	self:_send("chat.leave", {channel_id = channel_id})
end

function M:send_dm(recipient_id, content)
	self:_send("dm.send", {recipient_id = recipient_id, content = content})
end

function M:update_presence(status)
	self:_send("presence.update", {status = status or "online"})
end

-- Send input to your world. Pass `seq` - a per-input counter your client
-- increments - to opt into world.ack reconciliation; the server echoes the
-- highest seq it has consumed back on on("world_ack"). Kept numeric and sent
-- as a top-level sibling of payload.
function M:send_world_input(input, seq)
	self:_send_fire_and_forget("world.input", input, seq)
end

-- Browse the world lobby. `filters` takes `mode` and `has_capacity`; worlds
-- have no joinable flag and ignore that key. The reply arrives as
-- on("world_list").
function M:list_worlds(filters)
	self:_send("world.list", filters or {})
end

-- Create a fresh world instance and join it, rather than joining whichever
-- one happens to have room. Use find_or_create_world for the latter.
function M:create_world(mode, callback)
	self:_send_with_callback("world.create", {mode = mode}, callback)
end

function M:find_or_create_world(mode, callback)
	self:_send_with_callback("world.find_or_create", {mode = mode}, callback)
end

function M:join_world(world_id, callback)
	self:_send_with_callback("world.join", {world_id = world_id}, callback)
end

function M:leave_world()
	self:_send("world.leave", {})
end

return M

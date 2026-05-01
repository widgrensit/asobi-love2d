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
	["vote.cast_ok"] = "vote_cast_ok",
	["vote.veto_ok"] = "vote_veto_ok",
	["world.tick"] = "world_tick",
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
	self.callbacks[event] = callback
end

local function fire(self, event, ...)
	local cb = self.callbacks[event]
	if cb then cb(...) end
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
		if mtype == "error" then
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
	if event then fire(self, event, payload) end
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

function M:_send_fire_and_forget(mtype, payload)
	local frame = json.encode({type = mtype, payload = payload or {}})
	self.ws:send(frame)
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

function M:add_to_matchmaker(opts)
	local payload = {mode = "default"}
	if type(opts) == "string" then
		payload.mode = opts
	elseif type(opts) == "table" then
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

function M:send_world_input(input)
	self:_send_fire_and_forget("world.input", input)
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

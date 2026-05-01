-- Matchmaker REST API for asobi-love2d. Most matchmaking happens over
-- the realtime WebSocket; this module covers the REST shape for status
-- polling and ticket cancellation when a client wants HTTP fallback.

local http = require("asobi.http")

local M = {}

function M.add(client, opts)
	local body = {mode = "default"}
	if type(opts) == "string" then
		body.mode = opts
	elseif type(opts) == "table" then
		body.mode = opts.mode or "default"
		if opts.properties then body.properties = opts.properties end
		if opts.party then body.party = opts.party end
	end
	return http.post(client, "/api/v1/matchmaker", body)
end

function M.status(client, ticket_id)
	return http.get(client, "/api/v1/matchmaker/" .. ticket_id)
end

function M.cancel(client, ticket_id)
	return http.delete(client, "/api/v1/matchmaker/" .. ticket_id)
end

return M

-- asobi-love2d entry point.
--
-- Usage:
--     local asobi = require("asobi")
--     local client = asobi.new({host = "localhost", port = 8084})
--     asobi.auth.register(client, "u", "p", "u")
--     client.realtime:connect()

local M = {
	auth = require("asobi.auth"),
	matchmaker = require("asobi.matchmaker"),
	realtime_module = require("asobi.realtime"),
}

-- Construct a new client.
-- opts = {host, port = 8084, use_ssl = false}
function M.new(opts)
	opts = opts or {}
	local host = opts.host or "localhost"
	local port = opts.port or 8084
	local use_ssl = opts.use_ssl or false
	local scheme = use_ssl and "https" or "http"
	local ws_scheme = use_ssl and "wss" or "ws"

	local client = {
		host = host,
		port = port,
		use_ssl = use_ssl,
		base_url = scheme .. "://" .. host .. ":" .. tostring(port),
		ws_url = ws_scheme .. "://" .. host .. ":" .. tostring(port) .. "/ws",
		session_token = nil,
		player_id = nil,
	}
	client.realtime = M.realtime_module.new(client)
	return client
end

return M

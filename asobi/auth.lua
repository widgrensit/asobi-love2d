-- Auth API for asobi-love2d. Synchronous; returns (data, err).

local http = require("asobi.http")

local M = {}

function M.register(client, username, password, display_name)
	local data, err = http.post(client, "/api/v1/auth/register", {
		username = username,
		password = password,
		display_name = display_name or username,
	})
	if not err and data then
		client.session_token = data.session_token
		client.player_id = data.player_id
	end
	return data, err
end

function M.login(client, username, password)
	local data, err = http.post(client, "/api/v1/auth/login", {
		username = username,
		password = password,
	})
	if not err and data then
		client.session_token = data.session_token
		client.player_id = data.player_id
	end
	return data, err
end

function M.refresh(client)
	local data, err = http.post(client, "/api/v1/auth/refresh", {
		session_token = client.session_token,
	})
	if not err and data then client.session_token = data.session_token end
	return data, err
end

function M.logout(client)
	client.session_token = nil
	client.player_id = nil
end

return M

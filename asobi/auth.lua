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
		client.session_token = data.access_token
		client.refresh_token = data.refresh_token
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
		client.session_token = data.access_token
		client.refresh_token = data.refresh_token
		client.player_id = data.player_id
	end
	return data, err
end

-- Anonymous guest auth. Create-or-resume a guest identity keyed by a
-- stable device_id + a caller-supplied device_secret (base64 of >=32
-- CSPRNG bytes). No auth header. On success stores the access token as
-- the session token, exactly like login.
function M.guest(client, device_id, device_secret)
	local data, err = http.post(client, "/api/v1/auth/guest", {
		device_id = device_id,
		device_secret = device_secret,
	})
	if not err and data then
		client.session_token = data.access_token
		client.refresh_token = data.refresh_token
		client.player_id = data.player_id
	end
	return data, err
end

-- Upgrade the current guest into a full account. Authenticated with the
-- guest's current access token (sent automatically as Bearer). Replaces
-- the stored token pair with the upgraded one.
function M.upgrade_guest(client, username, password)
	local data, err = http.post(client, "/api/v1/auth/guest/upgrade", {
		username = username,
		password = password,
	})
	if not err and data then
		client.session_token = data.access_token
		client.refresh_token = data.refresh_token
		client.player_id = data.player_id
	end
	return data, err
end

function M.refresh(client)
	local data, err = http.post(client, "/api/v1/auth/refresh", {
		refresh_token = client.refresh_token,
	})
	if not err and data then
		client.session_token = data.access_token
		client.refresh_token = data.refresh_token
	end
	return data, err
end

function M.logout(client)
	client.session_token = nil
	client.refresh_token = nil
	client.player_id = nil
end

return M

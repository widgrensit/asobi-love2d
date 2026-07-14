-- Auth unit test: drives asobi.auth against a mocked HTTP layer and
-- asserts request shape + token storage + error propagation.
--
-- Pure unit test — no network, no LÖVE. The http module is captured by
-- auth.lua at require time, so mutating its `post` field intercepts every
-- call the auth functions make.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local http = require("asobi.http")
local auth = require("asobi.auth")

local fail_count = 0
local pass_count = 0

local function pass(msg)
	pass_count = pass_count + 1
	print("[auth] PASS: " .. msg)
end

local function fail(msg)
	fail_count = fail_count + 1
	print("[auth] FAIL: " .. msg)
end

local function check(cond, msg)
	if cond then pass(msg) else fail(msg) end
end

-- Records the last (path, body) and replays a canned (data, err) pair.
local last
local function mock(data, err)
	http.post = function(_client, path, body)
		last = {path = path, body = body}
		return data, err
	end
end

-- guest: request shape + tokens stored from access_token/player_id.
do
	mock({
		player_id = "p-guest-1",
		access_token = "acc-1",
		refresh_token = "ref-1",
		username = "Guest1234",
		created = true,
		guest = true,
	}, nil)
	local client = {}
	local data, err = auth.guest(client, "device-abc", "c2VjcmV0")

	check(err == nil, "guest returns no error on success")
	check(last.path == "/api/v1/auth/guest", "guest posts to /api/v1/auth/guest")
	check(last.body.device_id == "device-abc", "guest sends device_id")
	check(last.body.device_secret == "c2VjcmV0", "guest sends device_secret")
	check(client.session_token == "acc-1", "guest stores access_token as session_token")
	check(client.player_id == "p-guest-1", "guest stores player_id")
	check(data.guest == true, "guest returns decoded body")
end

-- guest: error propagates and does not clobber tokens.
do
	mock(nil, {status_code = 401, error = "invalid_device_secret"})
	local client = {session_token = "keep", player_id = "keep-id"}
	local data, err = auth.guest(client, "device-abc", "wrong")

	check(data == nil, "guest returns nil data on error")
	check(err ~= nil and err.error == "invalid_device_secret", "guest propagates error code")
	check(err.status_code == 401, "guest propagates status_code")
	check(client.session_token == "keep", "guest leaves session_token untouched on error")
	check(client.player_id == "keep-id", "guest leaves player_id untouched on error")
end

-- upgrade_guest: request shape + replaces stored tokens.
do
	mock({
		player_id = "p-guest-1",
		access_token = "acc-2",
		refresh_token = "ref-2",
		username = "realname",
		upgraded = true,
	}, nil)
	local client = {session_token = "acc-1", player_id = "p-guest-1"}
	local data, err = auth.upgrade_guest(client, "realname", "pass1234")

	check(err == nil, "upgrade_guest returns no error on success")
	check(last.path == "/api/v1/auth/guest/upgrade", "upgrade_guest posts to /api/v1/auth/guest/upgrade")
	check(last.body.username == "realname", "upgrade_guest sends username")
	check(last.body.password == "pass1234", "upgrade_guest sends password")
	check(client.session_token == "acc-2", "upgrade_guest replaces session_token")
	check(data.upgraded == true, "upgrade_guest returns decoded body")
end

-- upgrade_guest: error propagates.
do
	mock(nil, {status_code = 409, error = "username_taken"})
	local client = {session_token = "acc-1", player_id = "p-guest-1"}
	local _, err = auth.upgrade_guest(client, "taken", "pass1234")

	check(err ~= nil and err.error == "username_taken", "upgrade_guest propagates error code")
	check(client.session_token == "acc-1", "upgrade_guest leaves session_token on error")
end

print(string.format("[auth] %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end

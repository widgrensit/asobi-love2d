-- Players unit test: drives asobi.players against a mocked HTTP layer.
--
-- Pure unit test - no network, no LÖVE. The http module is captured by
-- players.lua at require time, so mutating its `post` field intercepts the
-- call, the same trick test/auth.lua uses.
--
-- What is worth pinning is not that a POST goes out: it is that the local
-- session does not survive a successful erase and does survive a refused one,
-- and that a failure arrives as a printable message plus a branchable code.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local http = require("asobi.http")
local players = require("asobi.players")

local fail_count = 0
local pass_count = 0

local function check(cond, msg)
	if cond then
		pass_count = pass_count + 1
		print("[players] PASS: " .. msg)
	else
		fail_count = fail_count + 1
		print("[players] FAIL: " .. msg)
	end
end

local function signed_in()
	return {session_token = "acc", refresh_token = "ref", player_id = "p1"}
end

local real_post = http.post

-- A guest sends no password and loses its session.
do
	local seen = {}
	http.post = function(_client, path, body)
		seen.path, seen.body = path, body
		return {deleted = true}, nil
	end
	local client = signed_in()
	local data, err = players.erase_self(client)
	check(seen.path == "/api/v1/players/me/erase", "erase targets the me path")
	check(next(seen.body) == nil, "a guest sends no password")
	check(err == nil and data.deleted == true, "the deletion is reported")
	check(client.session_token == nil, "a successful erase clears the session token")
	check(client.refresh_token == nil, "a successful erase clears the refresh token")
	check(client.player_id == nil, "a successful erase clears the player id")
end

-- An account with a password echoes it.
do
	local seen = {}
	http.post = function(_client, _path, body)
		seen.body = body
		return {deleted = true}, nil
	end
	players.erase_self(signed_in(), "secret1234")
	check(seen.body.password == "secret1234", "a password account echoes it")
end

-- A refused confirmation leaves a live account, so the session must stay.
do
	http.post = function()
		return nil, {status_code = 403, code = "player.confirmation_failed", error = "Wrong."}
	end
	local client = signed_in()
	local data, err = players.erase_self(client, "wrong")
	check(data == nil and err.code == "player.confirmation_failed", "the refusal surfaces its code")
	check(client.session_token == "acc", "a refused erase keeps the session token")
	check(client.player_id == "p1", "a refused erase keeps the player id")
end

http.post = real_post

-- The shared error object must not land in `error` as a table.
do
	local err = http.error_of(
		{error = {code = "player.not_found", message = "No player.", details = {}}}, 404
	)
	check(err.code == "player.not_found", "error object yields its code")
	check(err.error == "No player.", "error object yields its message")
	check(type(err.error) == "string", "error is printable with tostring")

	local legacy = http.error_of({error = "bad_request"}, 400)
	check(legacy.error == "bad_request", "a flat legacy body still maps")
	check(legacy.code == "", "a flat legacy body has no code")

	local bare = http.error_of(nil, 500)
	check(bare.error == "HTTP 500", "no body falls back to the status")
end

print(string.format("[players] %d passed, %d failed", pass_count, fail_count))
os.exit(fail_count > 0 and 1 or 0)

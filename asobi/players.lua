-- Player-account operations.
--
-- Named to match the same call in every other asobi SDK (`players.erase_self`)
-- rather than folded into `auth`, so the docs read the same whichever client a
-- reader arrives from.

local http = require("asobi.http")

local M = {}

-- Erase the signed-in account and everything the server holds for it - saves,
-- storage, inventory, wallets, leaderboard entries, identities. Irreversible.
--
-- `password` is required only for an account that has one. A guest or a
-- provider-only account has no credential the client can re-present, so its
-- session is the whole confirmation: pass nil.
--
-- Clears the local session on success only, deliberately unlike `auth.logout`
-- which clears unconditionally: a refused confirmation (403
-- player.confirmation_failed) or a credential change mid-flight (409) leaves a
-- live account whose session must survive. On success the server deleted the
-- token pair inside the erase transaction, so keeping it would only buy a
-- doomed refresh on the next call.
--
-- Needs a server carrying POST /api/v1/players/me/erase; older ones 404.
function M.erase_self(client, password)
	local body = {}
	if password and password ~= "" then
		body.password = password
	end
	local data, err = http.post(client, "/api/v1/players/me/erase", body)
	if not err then
		client.session_token = nil
		client.refresh_token = nil
		client.player_id = nil
	end
	return data, err
end

return M

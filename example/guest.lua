-- Guest / anonymous auth example (LÖVE).
--
-- A guest is a real player (with a persistent player_id) that needs no username
-- or password. The device holds a {device_id, device_secret} keypair; the same
-- pair resumes the same player on every launch. `guest_device` manages that
-- keypair for you (generate on first run, persist to the LÖVE save directory,
-- reuse) and signs in. Auth is synchronous - it returns (data, err).

local asobi = require("asobi")

local client

function love.load()
	client = asobi.new({ host = "localhost", port = 8084 })

	-- --- The one-call flow (recommended) --------------------------------
	-- Generates + saves the keypair on first run, reuses it after, signs in.
	local data, err = asobi.auth.guest_device(client)
	if err then
		print("guest sign-in failed: " .. tostring(err.error))
		return
	end

	-- player_id is who you are in the backend - use it for everything.
	if data.created then
		print("brand-new guest: " .. data.player_id)
		-- ... run first-time onboarding here ...
	else
		print("welcome back, guest: " .. data.player_id)
	end

	-- You now have an authenticated session. Do backend things:
	client.realtime:connect()
	client.realtime:add_to_matchmaker({ mode = "demo" })
end

function love.update(_dt)
	client.realtime:update()
end

-- --- Turning a guest into a real account --------------------------------
-- Call this (after a successful guest sign-in) when the player wants their
-- progress to survive a reinstall or move to another device. The player_id is
-- KEPT - nothing is lost; a username/password is just added to the same player.
local function upgrade_to_account(username, password)
	local data, err = asobi.auth.upgrade_guest(client, username, password)
	if err then
		print("upgrade failed: " .. tostring(err.error))
		return
	end
	print("account claimed, same player_id: " .. tostring(data.player_id))
end

-- --- Switch guest / "forget me" / delete-my-data ------------------------
-- Erase the stored keypair. The NEXT guest_device mints a brand-new guest
-- (data.created = true). This is local-only - it does not delete the server
-- account, so pair it with logout to end the current session. If the player
-- wants to KEEP the current guest, call upgrade_guest first.
local function forget_guest()
	asobi.auth.logout(client)
	asobi.device.clear() -- pass the same file/store opts you signed in with
	print("guest forgotten; next launch starts fresh")
end

-- --- Options: custom storage or a stronger RNG --------------------------
-- LÖVE ships no CSPRNG; the default secret is seeded love.math.random. For
-- production, back it with a real crypto source, and/or redirect storage.
local function init_with_options()
	client = asobi.new({ host = "localhost", port = 8084 })

	local data, err = asobi.auth.guest_device(client, {
		file = "guest_device", -- save-file name in the LÖVE save directory
		random_bytes = function(n)
			-- return exactly n cryptographically-random bytes from your source
			return my_csprng(n)
		end,
		-- store = { read = fn, write = fn, remove = fn }, -- e.g. an OS keychain
	})
	if not err then print("signed in: " .. data.player_id) end
end

-- --- Bring your own credentials -----------------------------------------
-- If you'd rather manage the keypair yourself (e.g. an OS keychain), skip the
-- helper and pass the values to guest() directly. device_secret must be
-- standard base64 of >= 32 random bytes; device_id is any stable per-install id.
local function init_manual()
	client = asobi.new({ host = "localhost", port = 8084 })

	local device_id, device_secret = load_my_own_credentials()
	local data, err = asobi.auth.guest(client, device_id, device_secret)
	if not err then print("signed in: " .. data.player_id) end
end

return {
	upgrade_to_account = upgrade_to_account,
	forget_guest = forget_guest,
	init_with_options = init_with_options,
	init_manual = init_manual,
}

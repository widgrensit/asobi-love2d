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

-- Opt-in convenience: load (or generate + persist) a device credential pair
-- and sign in as a guest in one call. Equivalent to calling M.guest with a
-- {device_id, device_secret} you manage yourself. opts is forwarded to
-- asobi.device.load_or_create (file/store/random_bytes overrides) and may be
-- omitted. Synchronous; returns (data, err) like M.guest.
--
-- Collision canary: the server sets `created` only when it actually made a new
-- player, and omits the key entirely on resume. So a BRAND-NEW local credential
-- answered without `created` means some other install already presented this
-- device_id - the RNG handed out a duplicate. The id is 16 bytes from a PRNG
-- seeded with at most ~31 bits, so duplicates are bounded by the seed space
-- rather than 2^128: this is a realistic signal, and it is the only defence
-- that works on love.js, where LÖVE exposes no CSPRNG and the seeded fallback
-- degrades to whole-second resolution.
--
-- The sign-in is left to stand - the player is authenticated, and refusing
-- would strand them - and `device_collision` is set so a game can surface it.
--
-- Erasing the credential is the destructive half, so it is gated on web. The
-- signal is "created absent", which cannot be told apart from a backend that
-- does not implement the field; against such a server every first-run player
-- would otherwise have a perfectly good credential erased on every launch. Web
-- is the only platform with the degenerate RNG, so that is where the
-- remediation is worth the ambiguity. A caller-supplied opts.device_id is
-- skipped entirely: a resume is the expected answer when the caller owns the
-- id, not evidence of a collision.
-- Retries are worth taking because the RNG is seeded once per process, not per
-- draw: clearing and re-minting advances the same stream, so N tabs that opened
-- in the same second converge on N distinct pairs after N-1 retries. A failed
-- attempt creates no server row (it resumed an existing player), so only the
-- attempt that finally succeeds costs a guest identity.
local MAX_COLLISION_RETRIES = 2

function M.guest_device(client, opts)
	local device = require("asobi.device")
	local caller_owns_id = opts ~= nil and opts.device_id ~= nil
	local data, err

	for attempt = 0, MAX_COLLISION_RETRIES do
		local device_id, device_secret, minted = device.load_or_create(opts)
		data, err = M.guest(client, device_id, device_secret)
		local collided = not err and data ~= nil and minted and not data.created and not caller_owns_id
		if not collided then
			return data, err
		end
		if attempt < MAX_COLLISION_RETRIES then
			-- Erase so the next load_or_create mints from the next draw rather
			-- than resuming the pair we just proved is someone else's.
			device.clear(opts)
		end
	end

	print(
		"[asobi] WARNING: this device_id already existed on the server, so this player is "
			.. "sharing an account with someone else, and re-minting did not escape it. "
			.. "Pass opts.random_bytes with a real random source."
	)
	if device._is_web() then
		device.clear(opts)
	end
	-- On the client, not on `data`: every SDK has a client/session object, while
	-- the auth response deserialises into a fixed typed struct in the C#, Dart
	-- and C++ SDKs that a client-side key cannot be bolted onto. Keeping the
	-- signal off the response also stops it being mistaken for a server field.
	client.device_collision = true
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

-- Revoke the tokens server-side, then clear local state. Sending the refresh
-- token kills the whole refresh family and the access token in the
-- Authorization header is revoked too, so a "logout" no longer leaves live
-- credentials behind. Unauthenticated on the server, because it accepts a
-- token that may already have expired.
--
-- The local clear happens even when the call fails: a player who asked to be
-- logged out must not be left holding tokens because the network was down.
function M.logout(client)
	local data, err
	if client.session_token or client.refresh_token then
		data, err = http.post(client, "/api/v1/auth/logout", {
			refresh_token = client.refresh_token,
		})
	end
	client.session_token = nil
	client.refresh_token = nil
	client.player_id = nil
	return data, err
end

return M

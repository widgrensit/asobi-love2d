-- Opt-in guest device-credential helper.
--
-- Guest sign-in needs a stable {device_id, device_secret} that the game
-- generates once, persists, and re-presents on every launch (same pair resumes
-- the same player). This module does that dance so a game doesn't hand-roll
-- base64 + persistence + the >=32-byte rule. Entirely optional: pass your own
-- values to asobi.auth.guest(...) if you want your own storage or key source.
--
-- device_id:     any stable, per-install id (here: base64 of 16 random bytes).
-- device_secret: standard base64 of >=32 random bytes (the server requires this
--                exact shape; anything shorter is rejected as weak_device_secret).
--
-- Entropy note: LÖVE ships no CSPRNG, so the default RNG is best-effort
-- (seeded love.math.random / math.random) - fine for a persisted guest
-- credential. For higher assurance, pass opts.random_bytes backed by a crypto
-- source (e.g. an OS keychain or a native extension).
--
-- On web (love.js) that best-effort seed is materially weaker than on desktop -
-- see the seed comment below - and there is no CSPRNG to fall back on. The
-- backstop there is the collision canary in asobi.auth.guest_device, which
-- detects a duplicate device_id from the server's own response rather than
-- trusting the RNG.

local M = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Arithmetic-only (no bitwise ops) fallback for when love.data is absent
-- (plain-Lua unit tests). Standard base64 with '=' padding, so the value
-- round-trips through the server's base64:decode.
local function arithmetic_base64(bytes)
	local out = {}
	local n = #bytes
	for i = 1, n, 3 do
		local b1 = bytes:byte(i)
		local b2 = bytes:byte(i + 1)
		local b3 = bytes:byte(i + 2)
		local n1 = math.floor(b1 / 4)
		local n2 = (b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)
		out[#out + 1] = B64:sub(n1 + 1, n1 + 1)
		out[#out + 1] = B64:sub(n2 + 1, n2 + 1)
		if b2 then
			local n3 = (b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0)
			out[#out + 1] = B64:sub(n3 + 1, n3 + 1)
		else
			out[#out + 1] = "="
		end
		if b3 then
			local n4 = b3 % 64
			out[#out + 1] = B64:sub(n4 + 1, n4 + 1)
		else
			out[#out + 1] = "="
		end
	end
	return table.concat(out)
end

-- LÖVE's love.data.encode("base64", ...) is standard RFC 4648 with '=' padding,
-- exactly what the server decodes; fall back to the arithmetic encoder outside
-- the engine.
local function base64(bytes)
	if love and love.data and love.data.encode then
		return love.data.encode("string", "base64", bytes)
	end
	return arithmetic_base64(bytes)
end

-- Fresh-allocation pointer addresses vary per process (ASLR), so hashing a few
-- of them gives cheap, dependency-free entropy that differs between two installs
-- generating in the same wall-clock second - the seed collision a plain
-- os.time() seed is vulnerable to. Still best-effort, not a CSPRNG: for
-- production, pass opts.random_bytes backed by a real crypto source.
local function ptr_entropy()
	local acc = 0
	for _ = 1, 8 do
		local p = tostring({})
		for i = 1, #p do
			acc = (acc * 31 + p:byte(i)) % 2147483647
		end
	end
	return acc
end

-- True on love.js, where the seeded fallback is much worse than on desktop:
-- ptr_entropy() is a no-op because wasm linear memory is deterministic (no
-- ASLR), and love.timer.getTime() rides performance.now(), which browsers
-- coarsen to 100us-1ms and which reads nearly the same in every tab this early
-- in startup. What survives is os.time() at whole-second resolution, so two
-- tabs opened in the same second can mint the same device_id - and that pair
-- then persists.
--
-- Detected by exclusion rather than by matching "Web". The cost is lopsided: a
-- false positive re-mints one guest identity once, while a false negative
-- leaves an install permanently sharing an account AND disarms the canary (a
-- missed invalidation means the pair resumes, so `minted` is false and the
-- check never runs). Older or re-packaged love.js builds have been reported
-- returning "Linux", and stock LÖVE answers "Unknown" for anything it does not
-- recognise, so anything that is not a known native platform is treated as web.
local NATIVE_OS = {
	Windows = true,
	["OS X"] = true,
	Linux = true,
	Android = true,
	iOS = true,
}

local function is_web()
	if not (love and love.system and love.system.getOS) then
		return false -- no LÖVE at all: unit tests, plain Lua host.
	end
	return not NATIVE_OS[love.system.getOS()]
end

-- Internal; exposed for asobi.auth's canary and the platform tests.
M._is_web = is_web

-- Emscripten backs /dev/urandom with crypto.getRandomValues, and love.js keeps
-- Lua's io library, so this may well be a real CSPRNG on web too - it is worth
-- trying before falling back to a seeded PRNG. Same call upgrades Linux and
-- macOS desktop off the seeded path entirely. Windows has no such device and
-- falls through.
local urandom_checked, urandom_ok = false, false

local function urandom_bytes(n)
	if urandom_checked and not urandom_ok then
		return nil
	end
	local ok, f = pcall(io.open, "/dev/urandom", "rb")
	if not ok or not f then
		urandom_checked, urandom_ok = true, false
		return nil
	end
	local read_ok, bytes = pcall(f.read, f, n)
	pcall(f.close, f)
	if not read_ok or type(bytes) ~= "string" or #bytes ~= n then
		urandom_checked, urandom_ok = true, false
		return nil
	end
	urandom_checked, urandom_ok = true, true
	return bytes
end

-- math.randomseed is srand((int)x) on Lua 5.1, so a seed above INT32_MAX is
-- narrowed on the way in - and under wasm that conversion saturates to a
-- constant rather than wrapping. love.math.setRandomSeed takes the full value,
-- so the seed is computed wide and narrowed only at the math.randomseed call
-- site; clamping it here too would throw away entropy on the path that was
-- never broken.
local SEED_MOD = 2147483647

local function mix(acc, value)
	return (acc * 31 + value) % SEED_MOD
end

local function compute_seed()
	local t = mix(os.time() % SEED_MOD, ptr_entropy())
	t = mix(t, math.floor((os.clock() * 1000000) % SEED_MOD))
	if love and love.timer and love.timer.getTime then
		t = mix(t, math.floor((love.timer.getTime() * 1000000) % SEED_MOD))
	end
	-- Widen again so the setRandomSeed path gets more than 31 bits.
	return t + (os.time() % 1000000) * SEED_MOD
end

local seeded = false
local function default_random_bytes(n)
	local os_bytes = urandom_bytes(n)
	if os_bytes then
		return os_bytes
	end
	local rand = (love and love.math and love.math.random) or math.random
	if not seeded then
		seeded = true
		local t = compute_seed()
		if love and love.math and love.math.setRandomSeed then
			love.math.setRandomSeed(t)
		else
			-- Narrow here, not in compute_seed: srand((int)x) saturates under wasm.
			math.randomseed(t % SEED_MOD)
		end
	end
	local out = {}
	for i = 1, n do
		out[i] = string.char(rand(0, 255))
	end
	return table.concat(out)
end

local warned_web_rng = false

-- Generate a fresh {device_id, device_secret} pair. opts.random_bytes(n) may
-- supply bytes from a stronger source; opts.device_id fixes the id explicitly.
function M.generate(opts)
	opts = opts or {}
	local rand = opts.random_bytes or default_random_bytes
	-- Fail loud here rather than as an opaque server `weak_device_secret` 4xx if
	-- a custom source under-delivers: the secret must decode to >= 32 bytes.
	local secret_bytes = rand(32)
	assert(
		type(secret_bytes) == "string" and #secret_bytes >= 32,
		"asobi.device: random_bytes(32) must return at least 32 bytes"
	)
	-- After the first draw, so urandom_ok reflects a real probe. Warn at mint
	-- time rather than only after a collision: a solo dev testing their own game
	-- never trips the guest_device canary and would otherwise ship a build that
	-- merges their players into shared accounts with no warning anywhere. Stays
	-- quiet on a love.js build that does expose /dev/urandom.
	if opts.random_bytes == nil and not urandom_ok and is_web() and not warned_web_rng then
		warned_web_rng = true
		print(
			"[asobi] WARNING: no OS random source on this platform, and the seeded fallback is "
				.. "not random enough on web - players opening the game in the same second can "
				.. "be issued the same device_id and share an account. Pass opts.random_bytes "
				.. "backed by crypto.getRandomValues."
		)
	end
	local device_id = opts.device_id or base64(rand(16))
	local device_secret = base64(secret_bytes:sub(1, 32))
	return device_id, device_secret
end

local SAVE_FILE = "guest_device"
-- Records written before the seed fix carry no version line. On web those were
-- minted from a near-constant seed, so a stored v1 pair there is very likely
-- shared with other players and must be discarded - otherwise an affected
-- install resumes the shared guest forever and the fix reaches nobody.
local SAVE_HEADER = "asobi-device-v2"

-- device_id and device_secret are standard base64 (no newline in the alphabet),
-- so a line-per-field record round-trips without escaping or a JSON dependency.
local function serialize(id, secret)
	return SAVE_HEADER .. "\n" .. id .. "\n" .. secret .. "\n"
end

-- Returns id, secret, versioned. A v1 record is two lines with no header.
local function deserialize(s)
	local header, id, secret = s:match("^([^\n]*)\n([^\n]*)\n([^\n]*)")
	if header == SAVE_HEADER then
		return id, secret, true
	end
	-- A record that starts with the header but did not match the 3-line shape is
	-- a truncated v2 write, not a v1 record. Falling through would parse the
	-- header line itself as the device_id and the id as the secret, and that
	-- garbage pair would then load cleanly on every launch.
	if s:match("^([^\n]*)") == SAVE_HEADER then
		return nil, nil, false
	end
	local v1_id, v1_secret = s:match("^([^\n]*)\n([^\n]*)")
	return v1_id, v1_secret, false
end

-- Standard base64 of >= 32 bytes is >= 44 chars from the RFC 4648 alphabet.
-- Checking the shape of what we stored makes a corrupt or truncated record
-- self-healing: it fails validation and the next launch re-mints, instead of
-- being re-presented forever as an opaque weak_device_secret 4xx.
local function well_formed_secret(secret)
	return type(secret) == "string" and #secret >= 44 and secret:match("^[A-Za-z0-9+/]+=*$") ~= nil
end

local function valid(id, secret, versioned)
	if not (type(id) == "string" and id ~= "" and well_formed_secret(secret)) then
		return false
	end
	-- Scoped to web on purpose: the weak seed is a love.js-only problem, so a
	-- desktop install's unversioned pair is fine and discarding it would log out
	-- a player who was never affected.
	if is_web() and not versioned then
		return false
	end
	return true
end

-- Storage is swappable: pass opts.store = {read, write, remove} to redirect
-- persistence (an OS keychain, an in-memory test double, ...). The default is
-- love.filesystem, scoped to the game's save directory (set via conf.lua
-- `t.identity` or love.filesystem.setIdentity). Outside LÖVE with no override
-- there is no store, and load_or_create generates an in-memory-only pair.
local function default_store()
	if not (love and love.filesystem and love.filesystem.read and love.filesystem.write) then
		return nil
	end
	return {
		read = function(name)
			return love.filesystem.read(name)
		end,
		write = function(name, data)
			return love.filesystem.write(name, data)
		end,
		remove = function(name)
			return love.filesystem.remove(name)
		end,
	}
end

local function get_store(opts)
	if opts.store ~= nil then
		return opts.store
	end
	return default_store()
end

-- Load the persisted pair, or generate + persist one on first run. Returns
-- device_id, device_secret, minted - where `minted` is true if this call
-- generated a brand-new pair rather than resuming a stored one. guest_device
-- uses that to tell a fresh credential apart from a resumed one, which is what
-- makes the collision canary possible. With no store available (no LÖVE, no
-- opts.store) it generates an in-memory pair without persisting.
function M.load_or_create(opts)
	opts = opts or {}
	local store = get_store(opts)
	if not store then
		local id, secret = M.generate(opts)
		return id, secret, true
	end
	local name = opts.file or SAVE_FILE
	local contents = store.read(name)
	if contents then
		local id, secret, versioned = deserialize(contents)
		if valid(id, secret, versioned) then
			return id, secret, false
		end
	end
	local id, secret = M.generate(opts)
	-- Best-effort: if the save fails (full disk, sandbox), the caller still gets
	-- a usable pair for this session, but warn - a lost write means a different
	-- guest next launch.
	if not store.write(name, serialize(id, secret)) then
		print("[asobi] warning: could not persist guest device credentials; a new guest may be created next launch")
	end
	return id, secret, true
end

-- Erase the stored credentials so the next load_or_create / guest_device mints
-- a brand-new guest (data.created = true). Use for "switch account", "play as
-- someone else", or a local "forget me" / delete-my-data action. This is
-- local-only: it does not delete the server account (pair it with logout to end
-- the session, or upgrade_guest first if the player wants to keep it). Pass the
-- same file/store opts you signed in with.
function M.clear(opts)
	opts = opts or {}
	local store = get_store(opts)
	if not store then
		return
	end
	store.remove(opts.file or SAVE_FILE)
end

-- Exposed for the encoder golden-vector test; internal, not part of the API.
M._base64 = base64

return M

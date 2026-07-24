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

local seeded = false
local function default_random_bytes(n)
	local rand = (love and love.math and love.math.random) or math.random
	if not seeded then
		seeded = true
		local t = (os.time() % 1000000) * 1000000 + ptr_entropy()
		if love and love.timer and love.timer.getTime then
			t = t + math.floor((love.timer.getTime() * 1000000) % 1000000)
		end
		if love and love.math and love.math.setRandomSeed then
			love.math.setRandomSeed(t)
		else
			math.randomseed(t)
		end
	end
	local out = {}
	for i = 1, n do
		out[i] = string.char(rand(0, 255))
	end
	return table.concat(out)
end

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
	local device_id = opts.device_id or base64(rand(16))
	local device_secret = base64(secret_bytes:sub(1, 32))
	return device_id, device_secret
end

local SAVE_FILE = "guest_device"

-- device_id and device_secret are standard base64 (no newline in the alphabet),
-- so a two-line record round-trips without escaping or a JSON dependency.
local function serialize(id, secret)
	return id .. "\n" .. secret .. "\n"
end

local function deserialize(s)
	local id, secret = s:match("^([^\n]*)\n([^\n]*)")
	return id, secret
end

local function valid(id, secret)
	return type(id) == "string" and id ~= "" and type(secret) == "string" and secret ~= ""
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
-- device_id, device_secret. With no store available (no LÖVE, no opts.store)
-- it generates an in-memory pair without persisting.
function M.load_or_create(opts)
	opts = opts or {}
	local store = get_store(opts)
	if not store then
		return M.generate(opts)
	end
	local name = opts.file or SAVE_FILE
	local contents = store.read(name)
	if contents then
		local id, secret = deserialize(contents)
		if valid(id, secret) then
			return id, secret
		end
	end
	local id, secret = M.generate(opts)
	-- Best-effort: if the save fails (full disk, sandbox), the caller still gets
	-- a usable pair for this session, but warn - a lost write means a different
	-- guest next launch.
	if not store.write(name, serialize(id, secret)) then
		print("[asobi] warning: could not persist guest device credentials; a new guest may be created next launch")
	end
	return id, secret
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

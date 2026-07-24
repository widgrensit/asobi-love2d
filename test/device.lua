-- Device-credential unit test: covers generation shape, persist/resume,
-- clear, and the guest_device convenience forwarding to guest.
--
-- Pure unit test — no network, no LÖVE. Storage and RNG are injected via the
-- opts object, so the whole flow runs in plain Lua. The server rejects a
-- device_secret that is not standard base64 decoding to >= 32 bytes, so the
-- decode assertion below is the contract that keeps that from regressing.

package.path = "asobi/?.lua;asobi/?/init.lua;" .. package.path

local http = require("asobi.http")
local auth = require("asobi.auth")
local device = require("asobi.device")

local fail_count = 0
local pass_count = 0

local function pass(msg)
	pass_count = pass_count + 1
	print("[device] PASS: " .. msg)
end

local function fail(msg)
	fail_count = fail_count + 1
	print("[device] FAIL: " .. msg)
end

local function check(cond, msg)
	if cond then pass(msg) else fail(msg) end
end

-- Independent standard-base64 decoder (mirrors the server's base64:decode).
-- Rejects any non-standard alphabet char, so it doubles as the "is this
-- standard base64" assertion.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local LOOKUP = {}
for i = 1, #B64 do LOOKUP[B64:sub(i, i)] = i - 1 end

local function b64decode(s)
	local body = s:gsub("=", "")
	local out = {}
	local bits, nbits = 0, 0
	for i = 1, #body do
		local v = LOOKUP[body:sub(i, i)]
		if not v then return nil, "non-standard base64 char" end
		bits = bits * 64 + v
		nbits = nbits + 6
		if nbits >= 8 then
			nbits = nbits - 8
			local shift = 2 ^ nbits
			out[#out + 1] = string.char(math.floor(bits / shift) % 256)
			bits = bits % shift
		end
	end
	return table.concat(out)
end

-- Deterministic byte source: a repeating 0..255 ramp. generate() pulls 32 for
-- the secret and 16 for the id, both fully predictable from this.
local function ramp_bytes(n)
	local out = {}
	for i = 1, n do out[i] = string.char((i - 1) % 256) end
	return table.concat(out)
end

-- In-memory store double implementing the {read, write, remove} contract.
local function memstore()
	local files = {}
	local store = {
		read = function(name) return files[name] end,
		write = function(name, data) files[name] = data return true end,
		remove = function(name) files[name] = nil return true end,
	}
	return store, files
end

-- generate: secret is standard base64 decoding to EXACTLY 32 bytes.
do
	local _, secret = device.generate({ random_bytes = ramp_bytes })
	local decoded, derr = b64decode(secret)
	check(secret:match("^[A-Za-z0-9+/=]+$") ~= nil, "secret uses only standard base64 alphabet")
	check(decoded ~= nil, "secret decodes as standard base64 (" .. tostring(derr) .. ")")
	check(decoded and #decoded == 32, "secret decodes to exactly 32 bytes (got " .. (decoded and #decoded or "nil") .. ")")
	check(decoded == ramp_bytes(32), "secret round-trips the source bytes")
end

-- generate: a short custom random source fails loud, not as an opaque 4xx.
do
	local ok = pcall(device.generate, { random_bytes = function() return "tooshort" end })
	check(ok == false, "generate asserts when random_bytes returns < 32 bytes")
end

-- load_or_create: persists on first run and resumes the SAME pair after.
do
	local store = memstore()
	local opts = { store = store, random_bytes = ramp_bytes }
	local id1, secret1 = device.load_or_create(opts)
	local id2, secret2 = device.load_or_create(opts)
	check(id1 ~= nil and secret1 ~= nil, "load_or_create returns a pair")
	check(id1 == id2 and secret1 == secret2, "load_or_create resumes the persisted pair")
end

-- clear: erases, so the next load_or_create mints a fresh pair.
do
	local store, files = memstore()
	local seq = 0
	-- Each generate call draws distinct bytes, so a re-mint differs from the first.
	local function seq_bytes(n)
		seq = seq + 1
		local out = {}
		for i = 1, n do out[i] = string.char((seq * 40 + i) % 256) end
		return table.concat(out)
	end
	local opts = { store = store, random_bytes = seq_bytes }
	local id1 = device.load_or_create(opts)
	check(next(files) ~= nil, "load_or_create wrote to the store")
	device.clear(opts)
	check(next(files) == nil, "clear erased the store")
	local id2 = device.load_or_create(opts)
	check(id1 ~= id2, "load_or_create mints a new id after clear")
end

-- guest_device: forwards the loaded creds to guest and passes (data,err) through.
do
	local store = memstore()
	local opts = { store = store, random_bytes = ramp_bytes }
	-- Pre-seed the store so we can assert guest_device resumes THESE exact creds.
	local want_id, want_secret = device.load_or_create(opts)

	local last
	http.post = function(_client, path, body)
		last = { path = path, body = body }
		return { player_id = "p-guest-1", access_token = "acc-1", refresh_token = "ref-1", guest = true }, nil
	end

	local client = {}
	local data, err = auth.guest_device(client, opts)

	check(err == nil, "guest_device returns no error on success")
	check(last.path == "/api/v1/auth/guest", "guest_device posts to /api/v1/auth/guest")
	check(last.body.device_id == want_id, "guest_device forwards the persisted device_id")
	check(last.body.device_secret == want_secret, "guest_device forwards the persisted device_secret")
	check(client.session_token == "acc-1", "guest_device stores access_token via guest()")
	check(client.player_id == "p-guest-1", "guest_device stores player_id via guest()")
	check(data ~= nil and data.guest == true, "guest_device passes the decoded body through")
end

-- guest_device: an auth error from guest() propagates unchanged.
do
	local store = memstore()
	http.post = function()
		return nil, { status_code = 403, error = "guest_auth_disabled" }
	end
	local client = {}
	local data, err = auth.guest_device(client, { store = store, random_bytes = ramp_bytes })
	check(data == nil, "guest_device returns nil data on error")
	check(err ~= nil and err.error == "guest_auth_disabled", "guest_device propagates the error code")
end

print(string.format("[device] %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end

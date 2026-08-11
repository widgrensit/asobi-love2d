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

-- --------------------------------------------------------------------
-- Web entropy regression. On love.js ptr_entropy() is a no-op (no ASLR in wasm
-- linear memory) and love.timer.getTime() is coarsened, so the seed degrades to
-- whole seconds; the math.randomseed branch additionally narrowed through
-- srand((int)x). LÖVE has no CSPRNG on web, so the real backstop is the
-- guest_device canary below.
-- --------------------------------------------------------------------

-- Stands in for love.js. Only the fields device.lua actually reads.
local function with_web_love(fn)
	local real = _G.love
	_G.love = { system = { getOS = function() return "Web" end } }
	package.loaded["asobi.device"] = nil
	local web_device = require("asobi.device")
	local ok, err = pcall(fn, web_device)
	_G.love = real
	package.loaded["asobi.device"] = nil
	device = require("asobi.device")
	if not ok then error(err, 0) end
end

-- The math.randomseed branch (no love.math) must stay inside int32, or
-- srand((int)x) narrows it and every launch draws identical bytes.
do
	-- Force the seeded path: /dev/urandom exists on the CI host, and when it does
	-- the PRNG is never reached at all.
	-- luacheck: push ignore 122
	local real_open = io.open
	io.open = function(path, mode)
		if path == "/dev/urandom" then return nil end
		return real_open(path, mode)
	end
	package.loaded["asobi.device"] = nil
	local fresh = require("asobi.device")
	local captured
	local real_seed = math.randomseed
	-- luacheck: push ignore 122
	math.randomseed = function(s) captured = s; return real_seed(s) end
	fresh.generate()
	math.randomseed = real_seed
	-- luacheck: pop
	io.open = real_open
	-- luacheck: pop
	package.loaded["asobi.device"] = nil
	device = require("asobi.device")

	check(captured ~= nil, "the seeded fallback called math.randomseed")
	check(captured ~= nil and captured == math.floor(captured), "the seed is an integer")
	check(captured ~= nil and captured >= 0 and captured <= 2147483647,
		"the seed survives srand((int)x) (got " .. tostring(captured) .. ")")
end

-- load_or_create reports whether it minted or resumed - the signal the canary
-- is built on.
do
	local store = memstore()
	local opts = { store = store, random_bytes = ramp_bytes }
	local _, _, minted1 = device.load_or_create(opts)
	local _, _, minted2 = device.load_or_create(opts)
	check(minted1 == true, "load_or_create reports minted=true on first run")
	check(minted2 == false, "load_or_create reports minted=false when resuming")
end

do
	local _, _, minted = device.load_or_create({ random_bytes = ramp_bytes })
	check(minted == true, "load_or_create reports minted=true with no store at all")
end

-- The stickiness fix: a pre-fix (unversioned) record is discarded on web so the
-- install re-mints, but kept on desktop, which was never affected.
do
	local store, files = memstore()
	-- A realistic v1 record: the secret must be well-formed base64 of >= 32
	-- bytes, or it is rejected as corrupt on every platform.
	local shared = "the-shared-id\n" .. device._base64(ramp_bytes(32)) .. "\n"

	with_web_love(function(web_device)
		files["guest_device"] = shared
		local id = web_device.load_or_create({ store = store, random_bytes = ramp_bytes })
		check(id ~= "the-shared-id", "web discards an unversioned pair and re-mints")
		check(files["guest_device"]:match("^asobi%-device%-v2\n") ~= nil,
			"the replacement record carries the version header")
	end)

	files["guest_device"] = shared
	local id = device.load_or_create({ store = store, random_bytes = ramp_bytes })
	check(id == "the-shared-id", "desktop keeps the same unversioned pair")
end

-- A corrupt or truncated record must re-mint rather than being re-presented
-- forever. The truncated-v2 shape is the dangerous one: parsed loosely, the
-- header line becomes the device_id and the id becomes the secret, and that
-- garbage pair loads cleanly on every launch while the server rejects it.
do
	local corrupt = {
		["a truncated v2 write"] = "asobi-device-v2\nsome-id",
		-- The nastiest shape: truncated after a well-formed-looking second line,
		-- so the secret-shape check passes and ONLY the header guard in
		-- deserialize stops the header string being adopted as the device_id.
		["a v2 write truncated after a valid-looking secret"] = "asobi-device-v2\n"
			.. device._base64(ramp_bytes(32)),
		["a header-only file"] = "asobi-device-v2\n",
		["a v1 record with a too-short secret"] = "an-id\nshort\n",
		["a v1 record with a non-base64 secret"] = "an-id\n" .. string.rep("!", 44) .. "\n",
		["an empty file"] = "",
		["a single line"] = "just-one-line",
	}
	for label, contents in pairs(corrupt) do
		local store, files = memstore()
		files["guest_device"] = contents
		local id, secret = device.load_or_create({ store = store, random_bytes = ramp_bytes })
		check(id ~= "asobi-device-v2", "the header line is never used as a device_id (" .. label .. ")")
		check(secret == device._base64(ramp_bytes(32)), "re-minted a fresh pair from " .. label)
		check(files["guest_device"]:match("^asobi%-device%-v2\n") ~= nil,
			"the re-mint overwrote " .. label .. " with a versioned record")
	end
end

do
	local store, files = memstore()
	with_web_love(function(web_device)
		local opts = { store = store, random_bytes = ramp_bytes }
		local id1, secret1 = web_device.load_or_create(opts)
		local id2, secret2 = web_device.load_or_create(opts)
		check(id1 == id2 and secret1 == secret2, "a versioned record resumes normally on web")
		check(files["guest_device"]:match("\n" .. id1 .. "\n") ~= nil, "the id round-trips through the record")
	end)
end

-- --------------------------------------------------------------------
-- The canary: a freshly minted credential answered with created=false is proof
-- the device_id was already taken, i.e. the RNG handed out a duplicate.
-- --------------------------------------------------------------------
do
	local store, files = memstore()
	http.post = function()
		return { player_id = "p-shared", access_token = "a", refresh_token = "r", guest = true }, nil
	end
	local client = {}
	local _, err = auth.guest_device(client, { store = store, random_bytes = ramp_bytes })

	check(err == nil, "a collision does not fail the sign-in")
	check(client.device_collision == true, "the collision is flagged on the client")
	-- Desktop keeps the credential: "created absent" is indistinguishable from a
	-- backend that never sends the field, and erasing a good pair on that
	-- ambiguity would re-mint an orphan guest on every launch.
	check(next(files) ~= nil, "off web the credential is flagged but NOT erased")
end

-- On web the ambiguity is worth it: that is the only platform where the RNG can
-- actually hand out duplicates, so the pair must not stay sticky.
do
	with_web_love(function(web_device)
		local store, files = memstore()
		http.post = function()
			return { player_id = "p-shared", access_token = "a", refresh_token = "r", guest = true }, nil
		end
		package.loaded["asobi.auth"] = nil
		local web_auth = require("asobi.auth")
		local web_client = {}
		web_auth.guest_device(web_client, { store = store, random_bytes = ramp_bytes })
		check(web_client.device_collision == true, "the collision is flagged on web too")
		check(next(files) == nil, "on web the colliding credential is erased, so it is not sticky")
		check(web_device._is_web() == true, "_is_web() detects love.js")
	end)
	package.loaded["asobi.auth"] = nil
	auth = require("asobi.auth")
end

-- The retry is the point: the RNG is seeded once per process, so re-minting
-- draws the NEXT value from the same stream rather than the same one again.
-- Tabs that opened in the same second therefore converge on distinct pairs.
do
	local store, files = memstore()
	local draw = 0
	local function stream_bytes(n)
		draw = draw + 1
		local out = {}
		for i = 1, n do out[i] = string.char((draw * 37 + i) % 256) end
		return table.concat(out)
	end

	-- The first id is already taken; anything minted after it is free.
	local taken
	http.post = function(_client, _path, body)
		taken = taken or body.device_id
		if body.device_id == taken then
			return { player_id = "p-shared", access_token = "a", refresh_token = "r", guest = true }, nil
		end
		return { player_id = "p-mine", access_token = "b", refresh_token = "r", created = true, guest = true }, nil
	end

	local client = {}
	local data, err = auth.guest_device(client, { store = store, random_bytes = stream_bytes })

	check(err == nil, "the retry path returns no error")
	check(client.device_collision == nil, "a collision resolved by retrying is not flagged")
	check(data ~= nil and data.player_id == "p-mine", "the player ends up on their OWN account")
	check(client.session_token == "b", "the client holds the retried account's token")
	check(next(files) ~= nil, "the winning credential is persisted")
end

-- Retries are bounded: a genuinely broken source must not loop forever.
do
	local store = memstore()
	local posts = 0
	http.post = function()
		posts = posts + 1
		return { player_id = "p-shared", access_token = "a", refresh_token = "r", guest = true }, nil
	end
	local client = {}
	auth.guest_device(client, { store = store, random_bytes = ramp_bytes })
	check(posts == 3, "gave up after 3 attempts (got " .. posts .. ")")
	check(client.device_collision == true, "and flagged the unresolved collision")
end

-- Web detection is by exclusion: a false negative would disarm BOTH the record
-- invalidation and the canary, so anything not a known native OS counts as web.
do
	local real = _G.love
	local function os_is(name)
		_G.love = { system = { getOS = function() return name end } }
		package.loaded["asobi.device"] = nil
		return require("asobi.device")._is_web()
	end
	check(os_is("Web") == true, "'Web' is web")
	check(os_is("Unknown") == true, "'Unknown' is treated as web, not as native")
	check(os_is("Windows") == false, "'Windows' is native")
	check(os_is("OS X") == false, "'OS X' is native")
	check(os_is("Linux") == false, "'Linux' is native")
	check(os_is("Android") == false, "'Android' is native")
	check(os_is("iOS") == false, "'iOS' is native")
	_G.love = real
	package.loaded["asobi.device"] = nil
	device = require("asobi.device")
	check(device._is_web() == false, "plain Lua with no LÖVE is not web")
end

-- An OS random source is preferred over the seeded PRNG wherever it exists.
-- Asserted by feeding /dev/urandom a known pattern and checking it comes out
-- the other end, so the PRNG cannot pass this by accident.
do
	-- luacheck: push ignore 122
	local real_open = io.open
	local asked
	io.open = function(path, mode)
		if path == "/dev/urandom" then
			asked = true
			return {
				read = function(_self, n) return string.rep("\7", n) end,
				close = function() end,
			}
		end
		return real_open(path, mode)
	end
	package.loaded["asobi.device"] = nil
	local fresh = require("asobi.device")
	local _, secret = fresh.generate()
	io.open = real_open
	-- luacheck: pop
	package.loaded["asobi.device"] = nil

	check(asked == true, "generate probed /dev/urandom")
	check(b64decode(secret) == string.rep("\7", 32),
		"the secret is the OS bytes, not PRNG output")
end

-- The love.math.setRandomSeed path must receive the WIDE seed. Clamping it to
-- int32 there (which the srand fallback needs) would throw away ~9 bits on the
-- path that was never broken - LÖVE escaped the Defold bug precisely because
-- setRandomSeed takes the full value.
do
	-- luacheck: push ignore 122
	local real_love, real_open = _G.love, io.open
	io.open = function(path, mode)
		if path == "/dev/urandom" then return nil end
		return real_open(path, mode)
	end
	local captured
	_G.love = {
		system = { getOS = function() return "Linux" end },
		math = {
			setRandomSeed = function(v) captured = v end,
			random = function(lo, hi) return math.random(lo, hi) end,
		},
	}
	package.loaded["asobi.device"] = nil
	require("asobi.device").generate()
	_G.love, io.open = real_love, real_open
	-- luacheck: pop
	package.loaded["asobi.device"] = nil
	device = require("asobi.device")

	check(captured ~= nil, "the love.math path called setRandomSeed")
	check(captured ~= nil and captured > 2147483647,
		"setRandomSeed got a seed wider than int32 (got " .. tostring(captured) .. ")")
end

-- A caller-supplied device_id is the caller's to own: resuming it is the
-- expected answer, not evidence of a collision.
do
	local store = memstore()
	http.post = function()
		return { player_id = "p-stable", access_token = "a", refresh_token = "r", guest = true }, nil
	end
	local client_o = {}
	auth.guest_device(client_o, {
		store = store, random_bytes = ramp_bytes, device_id = "my-stable-id",
	})
	check(client_o.device_collision == nil,
		"an explicit opts.device_id is never flagged as a collision")
end

-- A resumed credential answered with created=false is the NORMAL case and must
-- not trip the canary - otherwise every returning player is flagged.
do
	local store, files = memstore()
	local opts = { store = store, random_bytes = ramp_bytes }
	device.load_or_create(opts) -- pre-seed, so the next call resumes
	http.post = function()
		return { player_id = "p1", access_token = "a", refresh_token = "r", guest = true }, nil
	end
	local client_r = {}
	auth.guest_device(client_r, opts)
	check(client_r.device_collision == nil, "resuming an existing guest is not flagged")
	check(next(files) ~= nil, "a resumed credential is left in place")
end

-- A freshly minted credential answered with created=true is the normal
-- first-run case.
do
	local store, files = memstore()
	http.post = function()
		return { player_id = "p2", access_token = "a", refresh_token = "r", created = true, guest = true }, nil
	end
	local client_n = {}
	auth.guest_device(client_n, { store = store, random_bytes = ramp_bytes })
	check(client_n.device_collision == nil, "a genuinely new guest is not flagged")
	check(next(files) ~= nil, "the new credential is kept")
end

print(string.format("[device] %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end

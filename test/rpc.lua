-- The RPC seam: an extension's method, called over the same socket and
-- correlated by cid. Pure unit test - no network.
--
-- Run with:
--   lua test/rpc.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local json = require("asobi.json")
local realtime = require("asobi.realtime")

local passed, failed = 0, 0

local function pass(what)
	passed = passed + 1
	print("[rpc] PASS: " .. what)
end

local function fail(what)
	failed = failed + 1
	print("[rpc] FAIL: " .. what)
end

local function check(what, got, want)
	if got == want then pass(what) else
		fail(what .. " - got " .. tostring(got) .. ", want " .. tostring(want))
	end
end

-- Stand in for the socket: capture what would go out, so a test can reply with
-- the cid the SDK actually chose rather than one it guessed.
local function new_rt()
	local rt = realtime.new({})
	local sent = {}
	rt.ws = {send = function(_, frame) sent[#sent + 1] = json.decode(frame) end}
	return rt, sent
end

local function feed(rt, msg)
	rt:_handle_message(json.encode(msg))
end

local function read_fixture(name)
	local f = assert(io.open("test/fixtures/" .. name, "r"))
	local raw = f:read("*a")
	f:close()
	return json.decode(raw)
end

-- The envelope: `protocol` versions the payload rather than the frame type, so
-- a future version is a rejection a client can read.
do
	local rt, sent = new_rt()
	rt:rpc("quests.claim", {quest_key = "daily"}, function() end)
	check("sends rpc.call", sent[1].type, "rpc.call")
	check("versions the payload", sent[1].payload.protocol, 1)
	check("carries the method", sent[1].payload.method, "quests.claim")
	check("carries the params", sent[1].payload.params.quest_key, "daily")
	check("mints a cid", type(sent[1].cid), "string")
end

do
	local rt, sent = new_rt()
	rt:rpc("quests.list", nil, function() end)
	check("nil params is still an object", type(sent[1].payload.params), "table")
end

do
	local rt, sent = new_rt()
	local got
	rt:rpc("quests.claim", {}, function(result, err) got = {result, err} end)
	feed(rt, {type = "rpc.ok", cid = sent[1].cid, payload = {result = {reward = 100}}})
	check("rpc.ok resolves with the result", got[1].reward, 100)
	check("rpc.ok reports no error", got[2], nil)
end

-- The code is the only part of the shared error object a caller can branch on.
do
	local rt, sent = new_rt()
	local got
	rt:rpc("quests.claim", {}, function(result, err) got = {result, err} end)
	feed(rt, {
		type = "rpc.error",
		cid = sent[1].cid,
		payload = {error = {
			code = "quests.already_claimed",
			message = "This quest was already claimed.",
			details = {quest_key = "daily"},
		}},
	})
	check("rpc.error resolves with no result", got[1], nil)
	check("rpc.error carries the code", got[2].code, "quests.already_claimed")
	check("rpc.error carries the details", got[2].details.quest_key, "daily")
end

-- Otherwise a server defect and a domain outcome look identical to a caller
-- branching on `code`.
do
	local rt, sent = new_rt()
	local got
	rt:rpc("quests.claim", {}, function(_, err) got = err end)
	feed(rt, {type = "rpc.error", cid = sent[1].cid, payload = {}})
	check("an empty error object still carries a code", got.code, "internal")
end

do
	local rt, sent = new_rt()
	local first, second
	rt:rpc("quests.list", {}, function(r) first = r end)
	rt:rpc("quests.claim", {}, function(r) second = r end)
	check("two calls get different cids", sent[1].cid ~= sent[2].cid, true)
	-- Out of order: the second call answers first.
	feed(rt, {type = "rpc.ok", cid = sent[2].cid, payload = {result = {n = 2}}})
	feed(rt, {type = "rpc.ok", cid = sent[1].cid, payload = {result = {n = 1}}})
	check("the second call gets its own reply", second.n, 2)
	check("the first call gets its own reply", first.n, 1)
end

do
	local rt, sent = new_rt()
	local calls = 0
	rt:rpc("quests.list", {}, function() calls = calls + 1 end)
	local reply = {type = "rpc.ok", cid = sent[1].cid, payload = {result = {}}}
	feed(rt, reply)
	feed(rt, reply)
	check("a duplicate reply does not call back twice", calls, 1)
end

do
	local ok_fixture = read_fixture("rpc.ok.json")
	local err_fixture = read_fixture("rpc.error.json")

	local rt, sent = new_rt()
	local got
	rt:rpc("anything", {}, function(result) got = result end)
	ok_fixture.cid = sent[1].cid
	feed(rt, ok_fixture)
	check("rpc.ok.json reaches the caller", got.reward, ok_fixture.payload.result.reward)

	local rt2, sent2 = new_rt()
	local err
	rt2:rpc("anything", {}, function(_, e) err = e end)
	err_fixture.cid = sent2[1].cid
	feed(rt2, err_fixture)
	check("rpc.error.json reaches the caller", err.code, err_fixture.payload.error.code)
end

print(string.format("[rpc] %d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)

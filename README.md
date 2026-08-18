# asobi-love2d

LÖVE (love2d) client SDK for the [Asobi](https://github.com/widgrensit/asobi) game backend. Pure Lua — no LuaRocks dependencies, no compiled native modules. Works in any LÖVE 11.x project.

## Run a backend first

The SDK talks to an Asobi server. The fastest way to get one is the canonical SDK demo backend:

```bash
git clone https://github.com/widgrensit/sdk_demo_backend
cd sdk_demo_backend && docker compose up -d
```

That serves at `http://localhost:8084` (HTTP + WebSocket on `/ws`) with a 2-player `demo` mode (60-second movement-only round, 10 Hz tick rate). For the full reference game (arena shooter — boons, modifiers, voting, bots) see [`asobi_arena_lua`](https://github.com/widgrensit/asobi_arena_lua) on `:8085`.

## Installation

Drop the `asobi/` directory into your LÖVE project root, alongside `main.lua`:

```
my_game/
├── main.lua
├── conf.lua
└── asobi/
    ├── init.lua
    ├── auth.lua
    ├── device.lua
    ├── http.lua
    ├── json.lua
    ├── matchmaker.lua
    ├── realtime.lua
    └── websocket.lua
```

Take `asobi/` from a tagged release rather than `main` - `main` is unstable. See [releases](https://github.com/widgrensit/asobi-love2d/releases) for available versions.

LÖVE bundles `luasocket` so HTTP and WebSocket transport work out of the box. For HTTPS / `wss://` you need `luasec` on the path (LÖVE does not bundle it).

## Quick Start

```lua
local asobi = require("asobi")

local client
local matched = false

function love.load()
    math.randomseed(os.time())
    client = asobi.new({host = "localhost", port = 8084})

    -- Register and grab a session token (synchronous HTTP).
    local _, err = asobi.auth.register(
        client,
        "player_" .. math.random(1, 1e9),
        "pass1234",
        "demo-player"
    )
    if err then error("register failed: " .. err.error) end

    -- Wire callbacks BEFORE queueing.
    client.realtime:on("match_matched", function(payload)
        print("matched! match_id = " .. payload.match_id)
        matched = true
    end)

    client.realtime:on("match_state", function(state)
        local me = (state.players or {})[client.player_id]
        if me then
            -- Render `me.x`, `me.y` — and any other entity in state.players.
        end
    end)

    -- Connect WebSocket and queue for a match.
    assert(client.realtime:connect())
    client.realtime:add_to_matchmaker({mode = "demo"})
end

function love.update(dt)
    -- Drains incoming WebSocket frames and dispatches to your callbacks.
    client.realtime:update()

    -- Send player input (10 Hz is plenty for most games).
    if matched then
        local mx = (love.keyboard.isDown("d") and 1 or 0) - (love.keyboard.isDown("a") and 1 or 0)
        local my = (love.keyboard.isDown("s") and 1 or 0) - (love.keyboard.isDown("w") and 1 or 0)
        client.realtime:send_match_input({
            move_x = mx, move_y = my, shoot = false, aim_x = 0, aim_y = 0,
        })
    end
end

function love.quit()
    client.realtime:disconnect()
end
```

**Two players are required to match in `demo` mode** — open a second LÖVE instance (or run the smoke test) to fill the lobby.

## Threading note

LÖVE runs a single cooperative loop. `client.realtime:update()` does non-blocking I/O on the WebSocket and must be called every frame from `love.update(dt)` for callbacks to fire. HTTP calls (`asobi.auth.register`, `asobi.auth.login`) are **synchronous** and will block the frame for the duration of the request — call them at startup or on a deliberate user action, never in your main game loop.

## API surface

### `asobi.new(opts)` → client

`opts = {host, port = 8084, use_ssl = false}`. Returns a client with `auth`, `matchmaker`, and `realtime` attached.

### `asobi.auth`

Synchronous. Returns `(data, err)` — `err` is `nil` on success, or on failure
`{status_code, code, error}` where `code` is the machine-readable half to branch
on (`"player.confirmation_failed"`) and `error` is a human-readable message.

```lua
asobi.auth.register(client, username, password, display_name)
asobi.auth.login(client, username, password)
asobi.auth.guest(client, device_id, device_secret)
asobi.auth.guest_device(client, opts)   -- managed device credentials (see below)
asobi.auth.upgrade_guest(client, username, password)
asobi.auth.refresh(client)
asobi.auth.logout(client)               -- revokes the tokens server-side, then clears them locally
```

#### Guest / anonymous auth

Let a player start immediately with no sign-up. `guest` creates a new guest
identity, or resumes an existing one, keyed by a stable `device_id` plus a
`device_secret` you generate and store on the device. The secret is the base64
encoding of at least 32 CSPRNG bytes — you own generating and persisting it; the
SDK just passes it through.

```lua
-- device_id: any stable per-install id you keep (e.g. a saved UUID).
-- device_secret: base64 of >=32 random bytes, generated once and stored.
local data, err = asobi.auth.guest(client, device_id, device_secret)
if err then error("guest auth failed: " .. err.error) end
-- data.created == true on first call, absent on resume. data.guest == true.
-- The access token is now stored on the client, so realtime/HTTP calls work.

-- Later, convert the guest into a full account (keeps the same player_id):
local up, up_err = asobi.auth.upgrade_guest(client, "chosen_name", "pass1234")
if up_err then error("upgrade failed: " .. up_err.error) end
```

Both are synchronous and return `(data, err)` like the other auth calls. Common
error codes: `weak_device_secret`, `invalid_device_secret`, `guest_upgraded`,
`guest_auth_disabled` (guest); `not_an_unclaimed_guest`, `username_taken`
(upgrade).

#### Guest device (managed credentials)

Don't want to hand-roll base64, the `>=32`-byte secret rule, and persistence?
`asobi.auth.guest_device` does it for you: it generates a `{device_id,
device_secret}` pair on first run, stores it in the LÖVE save directory, reuses
it on every launch, and signs in — all in one synchronous call.

```lua
-- First run mints + saves a keypair; later runs resume the same guest.
local data, err = asobi.auth.guest_device(client)
if err then error("guest sign-in failed: " .. err.error) end
if data.created then
    -- brand-new guest — run onboarding
else
    -- returning guest
end
```

`opts` is optional and forwarded to the credential helper:

```lua
asobi.auth.guest_device(client, {
    file = "guest_device",             -- save-file name (default "guest_device")
    device_id = "my-stable-id",        -- supply your own id; the SDK still makes the secret
    random_bytes = function(n) ... end, -- return n crypto-random bytes (see note)
    store = { read = fn, write = fn, remove = fn }, -- redirect storage (e.g. keychain)
})
```

### `asobi.players`

```lua
asobi.players.erase_self(client, password)   -- password is nil for a guest
```

Erases the signed-in account and everything the server holds for it.
Irreversible. Clearing the local device credentials does **not** do this — the
account stays on the server, merely unreachable from that install.

```lua
-- Guest or provider-only account: no password to confirm with.
local _, err = asobi.players.erase_self(client)
if err then error(err.code .. ": " .. err.error) end

-- Account with a password: it must be echoed.
asobi.players.erase_self(client, "secret123")
```

A wrong password comes back as `err.code == "player.confirmation_failed"` (403)
and changes nothing. On success the local session is cleared, because the server
deleted the token pair in the same transaction; anything afterwards on that
session is a `401`, which for a retried erase means it already worked. The
device credentials are *not* cleared, so call `asobi.device.clear()` too if the
next launch should not sign straight back in as a new guest.

Needs a server carrying `POST /api/v1/players/me/erase`; older ones answer 404.

The credential helper is also usable directly as `asobi.device`:

```lua
local id, secret = asobi.device.generate(opts)        -- one fresh pair
local id, secret = asobi.device.load_or_create(opts)  -- persisted, load-or-mint
asobi.device.clear(opts)   -- forget the guest; next guest_device mints a new one
```

Use `asobi.device.clear` for "switch account" / "play as someone else" / a local
"delete my data" action. It is local-only — pair it with `asobi.auth.logout` to
end the session, or call `upgrade_guest` first if the player wants to keep the
guest. `device_secret` is standard base64 of at least 32 bytes, exactly what the
server requires.

**Entropy note:** LÖVE ships no CSPRNG, so the default secret is best-effort
(seeded `love.math.random`) — fine for a persisted guest credential on desktop.
For higher assurance, pass `opts.random_bytes` backed by a real crypto source.

The default source first tries `/dev/urandom`, which is a real CSPRNG on Linux
and macOS — and, since Emscripten backs that path with `crypto.getRandomValues`,
possibly under love.js too. Where it is unavailable (Windows, and any love.js
build without it) the seeded PRNG takes over.

**On web, verify which one you got, and pass `opts.random_bytes` if the seeded
path is in play.** The seeded fallback is much weaker in a browser than on
desktop: `ptr_entropy` depends on ASLR, which wasm linear memory does not have,
and `love.timer.getTime` rides `performance.now()`, which browsers coarsen. What
is left is `os.time()` at whole-second resolution, so two players who open the
game in the same second can be issued the same `device_id` — and end up sharing
one account. The SDK prints a warning at credential-mint time when it lands on
that path on web, so watch the console on first run.

As a backstop, `guest_device` verifies every freshly minted credential against
the server's `created` flag. A brand-new `device_id` the server says already
existed is evidence of a duplicate, so the SDK erases it and re-mints, up to
twice. That usually resolves it: the RNG is seeded once per process, so
re-minting draws the *next* value from the stream rather than the same one, and
tabs opened in the same second converge on distinct pairs. A resolved collision
is invisible to your game.

If all three attempts collide the source is genuinely broken. The SDK then warns,
sets `client.device_collision = true`, and on web erases the credential so the
install re-mints next launch rather than staying merged. Off web the flag is
raised but the credential is left alone, because "no `created` field" is also
what a backend that never sends it looks like. The sign-in still succeeds — the
player is authenticated — so treat the flag as a signal to fix your entropy
source, not as self-healing: every re-mint leaves another orphan guest on the
server, counting against its unlinked-guest cap.

The canary only runs inside `guest_device`. If you call `asobi.device.load_or_create`
and `asobi.auth.guest` yourself, you own this check.

```lua
local data, err = asobi.auth.guest_device(client)
if client.device_collision then
    -- Retries did not escape it: this player is sharing an account.
    -- Supply opts.random_bytes.
end
```

Credentials stored by v0.1.0 or earlier are discarded on web at first launch,
since they may be one of these duplicates. Desktop builds were never affected
and keep their stored pair.

If you'd rather own storage and key generation entirely, skip the helper and
pass your own values to `asobi.auth.guest(client, device_id, device_secret)` —
that primitive is unchanged.

### `asobi.matchmaker`

REST shape (most matchmaking happens over the realtime WebSocket; this is the HTTP fallback).

```lua
asobi.matchmaker.add(client, "demo")
asobi.matchmaker.add(client, {mode = "demo", properties = {...}})
asobi.matchmaker.status(client, ticket_id)
asobi.matchmaker.cancel(client, ticket_id)
```

### `client.realtime` — WebSocket

```lua
client.realtime:connect()                          -- handshake + session.connect
client.realtime:disconnect()
client.realtime:update()                           -- call every frame

client.realtime:on(event, fn)                      -- bind a callback
client.realtime:add_to_matchmaker({mode = "demo"})
client.realtime:remove_from_matchmaker(ticket_id)
client.realtime:send_match_input(input_table)
client.realtime:find_or_create_match(mode)         -- reply on("match_joined")
client.realtime:join_match(match_id)
client.realtime:leave_match()
client.realtime:list_matches({mode = "demo"})      -- reply on("match_list")
client.realtime:cast_vote(vote_id, option_id)
client.realtime:cast_veto(vote_id)
client.realtime:list_worlds({mode = "demo"})       -- reply on("world_list")
client.realtime:create_world(mode, callback)       -- always a fresh instance
client.realtime:find_or_create_world(mode, callback)
client.realtime:join_world(world_id, callback)
client.realtime:send_world_input(input_table, seq)  -- seq optional; see prediction
client.realtime:leave_world()
client.realtime:join_chat(channel)
client.realtime:send_chat_message(channel, content)
client.realtime:leave_chat(channel)
client.realtime:send_dm(recipient_id, content)
client.realtime:update_presence("online")
```

Listing filters are validated server-side: `mode` (string), `has_capacity`
(boolean) and, for matches only, `joinable` (boolean). A wrong type is rejected
with `invalid_<name>_filter` rather than silently ignored.

#### Dropping into a live match

`find_or_create_match(mode)` joins a joinable match of that mode and spawns one
when there is none. Prefer it to `list_matches` followed by `join_match` on what
you saw, which races: two clients reading the same empty listing each create a
match. The server resolves this one in a single serialized step, so simultaneous
callers converge on the same match. The reply is `match.joined`, the frame
`join_match` already answers with, so it lands on `on("match_joined")` and needs
no new handler.

```lua
client.realtime:on("match_joined", function(payload)
    print("in match " .. payload.match_id)
end)

client.realtime:find_or_create_match("arena")
```

`mode` is the only key this SDK sends; every match parameter beyond it comes
from the mode's server-side config. The mode must set `quick_play = true`, which
defaults to false for match modes, and one that has not opted in is refused with
`quick_play_disabled`. `quick_play` is not `listed`: that flag is browser
visibility, a separate axis.

Refusals arrive as `on("error")` with that `payload.reason`. They include
`not_found` (no mode of that name is configured, so a typo'd or unregistered
mode lands here first), `match_capacity_reached` (the node-wide match cap),
`wrong_mode_type` (the mode is a world mode) and `join_rate_limited` (the same
bucket as `match.join` and `world.join`).

Needs an asobi server on v0.86.0 or later.

#### Events

| Event                | Payload shape                                    |
| -------------------- | ------------------------------------------------ |
| `connected`          | `{player_id}`                                    |
| `match_matched`      | `{match_id, players}`                            |
| `match_joined`       | `{match_id, players}`                            |
| `match_state`        | `{tick, players, ...}` (game-shaped)             |
| `match_finished`     | game-shaped result                               |
| `world_joined`       | `{world_id, ...}`                                |
| `world_tick`         | `{tick, updates}` (entity diffs — auto-merged)   |
| `world_ack`          | `{tick, seq}` - high-water mark of consumed `world.input` seq |
| `entity_added`       | `(id, state)` after merge                        |
| `entity_updated`     | `(id, state, changed_fields)` after merge        |
| `entity_removed`     | `(id)` after merge                               |
| `tick`               | `(tick, raw_payload)` after entity dispatch      |
| `game_message`       | `{message}` — whatever the server's `game.send(player, x)` passed, as-is |
| `match_event`        | `(event_name, payload)` — the server's `game.broadcast(...)` from a match script |
| `world_event`        | `(event_name, payload)` — the same from a world script |
| `module_event`       | `{module, event, data}` — a named push from an extension; route on `event` |
| `error`              | `{reason, ...}`                                  |

> ⚠️ Two events look similar but mean different things:
>
> - `match_matched` — server-pushed when the matchmaker pairs you. **This is what the smoke listens for.**
> - `match_joined` — reply to a client-initiated `match.join` or `match.find_or_create`.

A Lua game script pushes to clients two ways. `game.send(player_id, message)`
targets one player and lands on `game_message`. `game.broadcast(event, payload)`
goes to everyone in the match or world; the event name is chosen by your script,
so it lands on the catch-all `match_event` (or `world_event`) with that name as
the first argument:

```lua
-- server: game.broadcast("players_total", { value = state.players_total })
client.realtime:on("match_event", function(event, payload)
    if event == "players_total" then
        print("players: " .. tostring(payload.value))
    end
end)
```

Events asobi itself broadcasts (`match.state`, `match.finished`, the
`match.vote_*` family, and so on) keep their own named callbacks above and do
not also fire `match_event`.

An installed extension pushes named events on `module_event`. The whole payload
`{module, event, data}` reaches the callback; the inner `event` name is yours to
route on, and the SDK never gates on it, so a new event name works without an
SDK update:

```lua
client.realtime:on("module_event", function(payload)
    if payload.event == "quests.completed" then
        print("quest " .. payload.data.quest_id .. " -> " .. tostring(payload.data.reward))
    end
end)
```

`on(event, fn)` registers a callback and **appends** it: bind the same event
twice and both callbacks fire, in registration order. There is no `off`.

#### Client-side prediction

Stamp a world input with your own counter and the server tells you how far it has
got, so you can move locally on the same frame and correct when the server
disagrees.

```lua
client.realtime:send_world_input({move_x = 1, move_y = 0}, 412)
```

`seq` is optional and opt-in. It rides the wire as a top-level sibling of
`payload`, never nested inside the input table:

```json
{"type":"world.input","seq":412,"payload":{"move_x":1,"move_y":0}}
```

Leave it out and the key is omitted entirely. The SDK does not generate it: the
counter is yours to own and to keep increasing.

Send at least one and the server starts replying:

```lua
client.realtime:on("world_ack", function(payload)
    -- payload.tick, payload.seq
end)
```

`payload.seq` is the highest input `seq` the server had consumed for you as of
`payload.tick`. It is a high-water mark, not a per-input receipt: several inputs
collapse into one ack, and an input your world script rejects still advances it,
so a dropped input never strands the client. The ack is addressed to you alone,
a separate frame beside the shared `world.tick` broadcast and never part of it,
and it arrives only when the mark advances, so `seq` never repeats and never
goes backwards. Never send a `seq` and you get silence, with no error.

Acks land only on broadcast ticks, one every `broadcast_interval` simulation
ticks (default 3). Set the mode's `broadcast_interval` to 1 for an ack every
tick, see [world server](https://asobi.dev/docs/world-server).

When a broadcast tick produced entity changes, the server sends `world.tick`
first and `world.ack` second. When nothing changed the ack arrives alone, with
no `world.tick` in front of it, so an ack is never a promise that a tick
preceded it. Prune and replay in the `world_ack` handler: doing either from the
`world_tick` or `tick` callback misses every tick-free ack, and replays against
a buffer nothing has pruned yet.

Keep `seq` a plain counter starting at 1. A `seq` outside the integers
`0 .. 2^53-1` is ignored, but the input is not: it is still queued and applied
to the world exactly as normal, and only its acknowledgement is skipped. The
mark stays where it was, so acks stop until a later valid seq advances it.
Nothing raises an error either way.

This SDK's JSON encoder switches to exponent form (`1e+15`) at 1e15 on a runtime
with no integer type, which LÖVE's LuaJIT is, and the server reads `1e+15` as a
float rather than an integer, so it falls outside that range. Never seed the
counter from a timestamp. `payload.tick` and `payload.seq` arrive as plain Lua
numbers and compare exactly, so no cast is needed.

Needs an asobi server on v0.84.1 or later, and asobi-love2d v0.4.0 or later.

**Reconciliation.** Increment the counter per input, buffer the input under that
`seq`, apply it to your local copy immediately, and on `world_ack` drop
everything the server has consumed and re-apply what is left on top of the
authoritative state.

That authoritative state is the SDK's merged entity store, not the `world_tick`
payload. `world.tick` carries entity diffs (`op = "a"` add, `"u"` changed fields
only, `"r"` removal). A full `op = "a"` snapshot arrives on every new
subscription to a zone, where new means you are not already one of that zone's
subscribers. Not only the first time: a zone falling out of your ring
unsubscribes you from it, so walking back until it returns subscribes you afresh
and replays the whole snapshot, and a player oscillating across a boundary
re-snapshots on every pass. Joining subscribes you to the whole ring at once, so
`world_joined` is followed by one snapshot per loaded, non-empty zone in it,
usually several frames rather than one.

A crossing delivers fresh snapshots too. Moving recomputes the ring, every
loaded zone in the band that has just entered it is subscribed, and each of
those holding entities replays a full snapshot: at the default `view_radius` of
1 an orthogonal step swaps three zones out for three in, so expect a burst of
snapshot frames on every boundary you cross. The destination zone is the one
exception, and only because at radius 1 it was already a neighbour in the old
ring, so re-affirming that held subscription sends nothing. Do not read that
single no-op as the crossing being quiet.

A zone that drops out of your ring sends `op = "r"` for each of its entities.
Subscribing to a zone that holds no entities skips the entity snapshot, but the
terrain push after it is a separate, unconditional step, so in a world with a
terrain provider that zone still delivers its chunk as `world_terrain`. The
ticks in between carry deltas.

The SDK merges all of it for you and then fires `entity_added` /
`entity_updated` / `entity_removed`, so seed your copy from `entity_added`
**and** `entity_updated`: your own entity's first diff is an add, so an
`entity_updated`-only handler stays empty and the early acks silently do
nothing. Copy the fields you reconcile out of `state`, never keep the table
itself. Both callbacks hand you the SDK's stored table for that entity: a `"u"`
diff merges into it in place, so a reference you kept changes under you, and an
`"a"` snapshot replaces the stored entry with a fresh table, so a reference you
kept silently stops updating instead.

```lua
local SPEED = 200

local seq = 0
local pending = {}                 -- unacked inputs, oldest first
local predicted = {x = 0, y = 0}   -- what you draw
local confirmed = nil              -- last server-confirmed position

local function apply(pos, input, dt)
    pos.x = pos.x + input.move_x * SPEED * dt
    pos.y = pos.y + input.move_y * SPEED * dt
end

-- Your entity's id is whatever your world script gives it, commonly your own
-- player id.
local function mine(id) return id == client.player_id end

client.realtime:on("entity_added", function(id, state)
    if mine(id) then confirmed = {x = state.x, y = state.y} end
end)

client.realtime:on("entity_updated", function(id, state)
    if mine(id) then confirmed = {x = state.x, y = state.y} end
end)

client.realtime:on("world_ack", function(payload)
    while pending[1] and pending[1].seq <= payload.seq do
        table.remove(pending, 1)
    end
    if not confirmed then return end
    predicted.x, predicted.y = confirmed.x, confirmed.y
    for i = 1, #pending do
        apply(predicted, pending[i].input, pending[i].dt)
    end
end)

function love.update(dt)
    client.realtime:update()

    local input = {
        move_x = (love.keyboard.isDown("d") and 1 or 0) - (love.keyboard.isDown("a") and 1 or 0),
        move_y = (love.keyboard.isDown("s") and 1 or 0) - (love.keyboard.isDown("w") and 1 or 0),
    }

    seq = seq + 1
    pending[#pending + 1] = {seq = seq, input = input, dt = dt}
    apply(predicted, input, dt)
    client.realtime:send_world_input(input, seq)
end
```

`pending` stays in send order, which is `seq` order, so pruning from the front is
enough. Cap `pending` - drop the oldest, or stop predicting - if it grows
without bound: that means acks have stopped arriving.

Wire-level detail is in the
[WebSocket protocol reference](https://asobi.dev/docs/protocols/websocket#client-side-prediction).

## Binary `world.tick`

Ask for the binary encoding and `world.tick` arrives as a WebSocket binary frame
in roughly a fifth of the bytes. The decode saving is the one that matters here:
LOVE has no native JSON, so this SDK ships a **pure-Lua parser**, and a 40-entity
delta costs it around 440 us per frame - at 20 Hz, close to 1% of a mobile CPU
doing nothing but reading text. The binary decoder was measured **33x faster** on
the same frame.

```lua
client.realtime.request_binary_wire = true
client.realtime:connect()
```

**Nothing else changes.** The decoder maps the wire's compact 2-byte entity slots
back to entity ids and produces the same record shape the JSON wire sends, so
`entity_added` / `entity_updated` / `entity_removed` and `tick` behave exactly as
before and every callback already written keeps working. Only `world.tick` is
affected; everything else stays JSON text on both wires.

Requires the server to have `binary_wire` switched on. If it does not, you
silently stay on text - `client.realtime.wire` reads `"json"` or `"binary"` once
`connected` has fired, so read it rather than assume. The same fallback happens
per frame for anything the server cannot encode as binary, such as an entity
field holding a table.

Arithmetic only, no `string.unpack` and no bitwise operators, so it runs on
LOVE 11's LuaJIT as well as on a 5.4 build.

## The datagram plane (optional)

Positions can travel over UDP instead of the WebSocket, so one lost packet costs
one frame of staleness rather than stalling everything behind a retransmit.

```lua
client.realtime.request_datagram = true
client.realtime:connect()
```

**Nothing else changes.** Entity callbacks fire exactly as before; the SDK merges
the two carriers for you, and `world.tick` keeps carrying entity creation,
removal and every non-transform field. Only absolute transform state travels on
the plane, and only what your server declared in its `dgram_pose` manifest.

**The WebSocket carries everything in every state.** If the server has no
gateway, if a firewall drops UDP, or if the path goes quiet for two seconds, the
SDK falls back to taking transforms from `world.tick` and keeps trying in the
background. There is no state in which your game stops working, which is why this
is safe to switch on and why a web export - where raw UDP does not exist - simply
never opens it.

What it needs from the server: `binary_wire` on, a `dgram_pose` manifest, and a
gateway reachable at the endpoint the mint hands back.
The whole story - what it carries, why losing packets is fine, the server
compose file and what happens when it does not work - is in
[the datagram plane guide](https://github.com/widgrensit/asobi/blob/main/guides/datagram-plane.md).


## Smoke test

`smoke_tests/smoke.lua` is the canonical [SMOKE.md](https://github.com/widgrensit/sdk_demo_backend/blob/main/SMOKE.md) flow against `sdk_demo_backend`. It runs as a standalone Lua script — does **not** require `love` — so CI can validate the SDK end-to-end without installing LÖVE:

```bash
# In one terminal:
cd sdk_demo_backend && docker compose up -d

# In another:
cd asobi-love2d
ASOBI_URL=http://localhost:8084 lua smoke_tests/smoke.lua
```

A passing smoke is a release prerequisite.

## Limitations

- **No HTTPS / `wss://` out of the box.** LÖVE does not bundle `luasec`. Add it to your path if you need TLS.
- **API surface is intentionally minimal for v0.x.** Worlds, leaderboards, economy, social, etc. — most protocol verbs are reachable via `client.realtime:_send(...)` directly until typed wrappers land.
- **Single-frame messages only.** No fragmented WebSocket messages, no per-message-deflate. Matches the asobi server's default frame shape.

## License

Apache-2.0

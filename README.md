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
asobi.auth.logout(client)
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

> **Entropy note:** LÖVE ships no CSPRNG, so the default secret is best-effort
> (seeded `love.math.random`) — fine for a persisted guest credential. For
> higher assurance, pass `opts.random_bytes` backed by a real crypto source.

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
client.realtime:join_match(match_id)
client.realtime:leave_match()
client.realtime:find_or_create_world(mode, callback)
client.realtime:join_world(world_id, callback)
client.realtime:send_world_input(input_table)
client.realtime:leave_world()
client.realtime:send_chat_message(channel, content)
```

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
| `entity_added`       | `(id, state)` after merge                        |
| `entity_updated`     | `(id, state, changed_fields)` after merge        |
| `entity_removed`     | `(id)` after merge                               |
| `tick`               | `(tick, raw_payload)` after entity dispatch      |
| `game_message`       | `{message}` — whatever the server's `game.send(player, x)` passed, as-is |
| `error`              | `{reason, ...}`                                  |

> ⚠️ Two events look similar but mean different things:
>
> - `match_matched` — server-pushed when the matchmaker pairs you. **This is what the smoke listens for.**
> - `match_joined` — reply to a client-initiated `match.join`.

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

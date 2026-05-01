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

Synchronous. Returns `(data, err)` — `err` is `nil` on success or `{status_code, error}` on failure.

```lua
asobi.auth.register(client, username, password, display_name)
asobi.auth.login(client, username, password)
asobi.auth.refresh(client)
asobi.auth.logout(client)
```

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

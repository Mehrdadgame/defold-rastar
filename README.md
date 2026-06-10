# defold-rastar

**Rastar Center** backend SDK for [Defold](https://defold.com) — a pure-Lua port of the
official `Rastar-Center-Unity-SDK` REST client. Login, player profile, server-side
score/high-score and leaderboards for any Defold game (desktop, mobile, HTML5).

No native extensions — only Defold's built-in `http.request` + `json`, so it works on
every Defold target including web.

> **راهنمای فارسی:** [INTEGRATION-FA.md](INTEGRATION-FA.md) — نصب، لاگین، امتیاز،
> لیدربورد، پراکسی وب و نمایش اسم‌های فارسی، قدم‌به‌قدم.

Package contents: `rastar/rastar.lua` (API client) · `rastar/farsi.lua` +
`rastar/fonts/` (optional Persian text shaping + Vazirmatn font) ·
`tools/rastar_proxy.py` (static server + same-origin API proxy for HTML5).

## Install

**Option A — Defold dependency (recommended).** Push this folder to a git host and add
the archive zip URL to your `game.project` → `project.dependencies`, e.g.

```
https://your-gitlab/defold-rastar/-/archive/main/defold-rastar-main.zip
```

then *Project ▸ Fetch Libraries*. **Option B — copy.** Copy the `rastar/` folder into
your project root. Either way:

```lua
local rastar = require "rastar.rastar"
```

## Quick start

```lua
local rastar = require "rastar.rastar"

-- 1) configure once (e.g. in your loader/controller script)
rastar.init({
    base_url = "https://rastar-center-api.rastar.ir",
    app_id   = "yourapp",
    game_id  = "your-game-uuid",   -- from the Rastar admin panel (used by score helpers)
    log      = false,              -- true = print every request (debug)
})

-- 2) frictionless login bound to a device id (creates the account on first run)
rastar.device_login(my_device_id, function(ok, data)
    if not ok then print("login failed:", data) return end

    -- 3) save the player's display name on the backend
    rastar.update_profile({ name = "Ali" }, function() end)

    -- 4) server-side score
    rastar.send_score(1234, function(ok2, usergame)
        print("server high score:", usergame.statistics.highScore)
    end)
    rastar.get_high_score(function(ok3, hs) print("best:", hs) end)
end)
```

Every callback has the same shape: `cb(ok, data_or_error_message, raw_response)`.
After a successful login the module stores the access token internally and sends
`Authorization: Bearer …` automatically.

## API

| Function | Endpoint |
|---|---|
| `init(opts)` | configure `base_url`, `app_id`, `game_id`, `timeout`, `log` |
| `device_login(device_id, cb)` | `POST /auth/device-id-login` |
| `basic_signup(phone, email, password, cb)` / `basic_login(...)` | `POST /auth/basic-signup` / `basic-login` |
| `otp_login_email(email, cb)` / `otp_login_sms(phone, cb)` / `verify_otp(code, type, method, cb)` | OTP flow |
| `refresh_token(token, cb)` / `logout(cb)` | session |
| `get_profile(cb)` / `update_profile(fields, cb)` | `GET /users/me`, `POST /users/update-profile` |
| `send_score(score, cb)` | `POST /games/{id}/send-score` |
| `get_my_game(cb)` / `get_high_score(cb)` | `GET /games/my-games/games/{id}` |
| `send_result("Win"|"Lose"|"Draw", cb)` / `increment_play_count(cb)` | game stats |
| `list_games(page, limit, cb)` | `GET /games` |
| `send_event(event_type, value, metadata, cb)` | `POST /events/send` — the leaderboard pipeline |
| `calculate_event(event_type, "count"|"sum_value"|"high_value", cb)` | `GET /events/{type}/calculate` |
| `get_event_count(event_type, cb)` | `GET /events/{type}/count` |
| `get_active_leaderboards(cb)` / `get_leaderboard_scores(id, page, limit, cb)` / `get_my_rank(id, cb)` | leaderboards |
| `is_logged_in()` / `get_token()` / `set_token(t)` / `get_cached_profile()` | helpers |

All paths are under `/api/v1/client/…` — identical to the Unity SDK, so anything that
works in Unity works here with the same app id / game id.

## HTML5 + CORS (important)

As of now the Rastar API **does not return `Access-Control-Allow-Origin`**, so browsers
block direct calls from an HTML5 build served on another origin. Two options:

1. **Ask the backend team to whitelist your game's origin** (proper production fix), or
2. **Serve the game behind a tiny same-origin reverse proxy** that forwards
   `/rastarapi/* → https://rastar-center-api.rastar.ir/*`, and configure:

```lua
local base = "https://rastar-center-api.rastar.ir"
if html5 then base = rastar.html5_origin() .. "/rastarapi" end
rastar.init({ base_url = base, ... })
```

A ready-made Python proxy (`serve_nocache.py`) ships with the Candy Guard example.
Desktop and mobile (native) builds can usually call the API directly.

**Proxy-only networks (desktop):** Defold's engine ignores the OS proxy settings, so on
machines that reach the internet only through a system proxy a direct call fails with
*"Unable to create HTTP connection … No route to host"*. Configure an automatic retry
through a local reverse proxy:

```lua
rastar.init({
    base_url = "https://rastar-center-api.rastar.ir",
    fallback_base_url = "http://localhost:8123/rastarapi",  -- tried when status == 0
    ...
})
```

## Events & leaderboards

Rastar leaderboards aggregate **events** (`eventCalculationType`: `count`, `sum_value`
or `high_value` over events of the board's `eventType`). The typical game loop:

```lua
-- on game over: log the run (feeds the leaderboard)
rastar.send_event("riddle:solved", score, { game = "mygame", score = score })

-- personal best across my own events
rastar.calculate_event("riddle:solved", "high_value", function(ok, best) ... end)

-- leaderboard screen
rastar.get_active_leaderboards(function(ok, boards) ... end)
rastar.get_leaderboard_scores(board_id, 1, 10, function(ok, items)
    -- items[i] = { rank, score, user = { userId, username, firstName, ... } }
end)
rastar.get_my_rank(board_id, function(ok, mine) ... end)
```

## Notes

- Requires Defold ≥ 1.4 (built-in `json.encode`).
- The device id should be generated once and persisted locally (`sys.save`); it is the
  account key for `device_login`.
- `get_high_score` returns `0` (success) when the player has no server record yet.

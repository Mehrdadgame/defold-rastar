--------------------------------------------------------------------------------
-- defold-rastar : Rastar Center backend SDK for Defold (Lua port of the
-- official Rastar-Center-Unity-SDK REST client).
--
-- Covers: auth (device-id / basic / otp), user profile (get/update),
-- games (send-score / my-game / high score), leaderboards (read).
--
-- Usage:
--   local rastar = require "rastar.rastar"
--   rastar.init({
--       base_url = "https://rastar-center-api.rastar.ir", -- or same-origin proxy for HTML5
--       app_id   = "yourapp",
--       game_id  = "your-game-uuid",                      -- used by score helpers
--   })
--   rastar.device_login(device_id, function(ok, data) ... end)
--   rastar.update_profile({ name = "Ali" }, cb)
--   rastar.send_score(1234, cb)
--   rastar.get_high_score(function(ok, hs) ... end)
--
-- All callbacks are: cb(ok --[[boolean]], data_or_error, raw_response_table)
-- The module keeps the access token internally after a successful login.
--
-- HTML5/CORS note: the backend must send Access-Control-Allow-Origin for your
-- game's origin, OR you serve the game behind a small same-origin reverse
-- proxy (see README). For the proxy case pass e.g.
--   base_url = rastar.html5_origin() .. "/rastarapi"
--------------------------------------------------------------------------------

local M = {}

local cfg = {
    base_url = "",
    app_id   = "",
    game_id  = nil,
    timeout  = 15,          -- seconds, per request
    log      = false,       -- print requests/responses (debug)
    -- Optional second base URL tried automatically when a request can't connect
    -- at all (status 0, e.g. "No route to host" because the machine only has
    -- internet through a system proxy that the engine doesn't use). Point it at
    -- a local reverse proxy such as http://localhost:8123/rastarapi
    fallback_base_url = nil,
}

local state = {
    access_token  = nil,
    refresh_token = nil,
    profile       = nil,    -- last fetched ProfileData
}

--------------------------------------------------------------------------------
-- internals
--------------------------------------------------------------------------------

local function log(...)
    if cfg.log then print("[rastar]", ...) end
end

-- Defold ships json.encode/decode. Fall back gracefully if encode is missing.
local function jencode(t)
    if t == nil then return nil end
    local ok, s = pcall(json.encode, t)
    if ok then return s end
    error("rastar: json.encode unavailable/failed")
end

local function jdecode(s)
    if not s or s == "" then return nil end
    local ok, t = pcall(json.decode, s)
    if ok then return t end
    return nil
end

-- extract a readable error message from a server response (mirrors ProvidersHelper)
local function extract_error(parsed, fallback)
    if type(parsed) ~= "table" then return fallback or "request failed" end
    -- nest.js style: {message=..., error=..., statusCode=...}
    if parsed.message and type(parsed.message) == "string" then
        return parsed.message
    end
    if parsed.message and type(parsed.message) == "table" then
        return table.concat(parsed.message, ", ")
    end
    -- rastar style: {code=..., meta={message=...}}
    local parts = {}
    if parsed.code then parts[#parts + 1] = tostring(parsed.code) end
    local meta = parsed.meta
    if type(meta) == "table" then
        local msg = meta.message
        if type(msg) == "table" then
            for _, m in ipairs(msg) do parts[#parts + 1] = tostring(m) end
        elseif msg ~= nil then
            parts[#parts + 1] = tostring(msg)
        end
    end
    if #parts > 0 then return table.concat(parts, ", ") end
    return fallback or "request failed"
end

--------------------------------------------------------------------------------
-- HTML5 transport: browser fetch via html5.run + Lua polling.
--
-- Defold's built-in wasm http layer was observed mis-sending Authorization on
-- some browsers: tokens it re-sends fail the server's signature check
-- ("Invalid access token!") while the IDENTICAL flow via the page's own
-- fetch/XHR succeeds 100% of the time. So on web every API call is made by the
-- browser itself; Lua polls for the result with a timer.
--------------------------------------------------------------------------------

-- percent-encode arbitrary bytes so they survive a JS string literal +
-- decodeURIComponent round-trip (UTF-8 safe)
local function jsenc(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local js_req_n = 0
local function js_fetch(url, method, headers, payload, timeout, handler)
    -- one-time bootstrap of the JS side
    pcall(html5.run, [[
        (function(){
            if (window.__rastar) return "";
            window.__rastar = { rs: {}, rq: function(id, method, url, hdrsEnc, bodyEnc){
                var o = { method: method, headers: JSON.parse(decodeURIComponent(hdrsEnc)) };
                var b = decodeURIComponent(bodyEnc);
                if (b.length > 0) o.body = b;
                fetch(url, o).then(function(r){
                    return r.text().then(function(t){
                        window.__rastar.rs[id] = JSON.stringify({ st: r.status, body: t });
                    });
                }).catch(function(e){
                    window.__rastar.rs[id] = JSON.stringify({ st: 0, body: String(e) });
                });
            }};
            return "";
        })()
    ]])
    js_req_n = js_req_n + 1
    local id = js_req_n
    local launched = pcall(html5.run, ('window.__rastar.rq(%d, "%s", decodeURIComponent("%s"), "%s", "%s"); ""')
        :format(id, method, jsenc(url), jsenc(jencode(headers)), jsenc(payload or "")))
    if not launched then
        handler({ status = 0, response = "html5.run failed" })
        return
    end
    local waited = 0
    timer.delay(0.15, true, function(_, h)
        waited = waited + 0.15
        local ok, res = pcall(html5.run,
            ('(window.__rastar && window.__rastar.rs[%d]) || ""'):format(id))
        if ok and res and res ~= "" then
            timer.cancel(h)
            pcall(html5.run, ('delete window.__rastar.rs[%d]; ""'):format(id))
            local parsed = jdecode(res)
            handler({ status = (parsed and parsed.st) or 0,
                      response = (parsed and parsed.body) or "" })
        elseif waited >= (timeout or 15) then
            timer.cancel(h)
            handler({ status = 0, response = "timeout" })
        end
    end)
end

-- core request. path is relative ("/api/v1/..."). body is a table or nil.
-- Resilience built in:
--  * status 0 (can't connect at all) -> retried once via cfg.fallback_base_url
--  * status 304 (a cache layer revalidated; body is EMPTY) -> retried once with a
--    cache-busting query param. The API sends ETags, and both Defold's own http
--    cache and browsers turn repeat GETs into conditional requests, so without
--    this the SECOND visit to any screen would fail with "HTTP 304".
local bust_n = 0
local function request(path, method, body, auth, cb, _base, _busted)
    assert(cfg.base_url ~= "", "rastar.init() not called (base_url empty)")
    local base = _base or cfg.base_url
    local url = base .. path
    -- x-app-id is only needed by the old multi-app backend; the new per-app
    -- backends (e.g. baziche) ignore it, so it is sent only when configured.
    local headers = {}
    if cfg.app_id and cfg.app_id ~= "" then headers["x-app-id"] = cfg.app_id end
    local payload = nil
    if body ~= nil then
        headers["Content-Type"] = "application/json"
        payload = jencode(body)
    end
    if auth and state.access_token then
        headers["Authorization"] = "Bearer " .. state.access_token
    end
    log(method, url, payload or "")

    local function handle_response(response)
        local parsed = jdecode(response.response)
        local status = response.status or 0
        log("->", status, response.response and response.response:sub(1, 200) or "")
        if status >= 200 and status < 300 and parsed and parsed.code == "SUCCESS" then
            if cb then cb(true, parsed.data, parsed) end
        elseif status >= 200 and status < 300 and parsed then
            -- some endpoints may not wrap in {code="SUCCESS"}; pass through
            if cb then cb(true, parsed.data or parsed, parsed) end
        elseif status == 304 and not _busted then
            -- revalidated-but-empty: force a fresh response once
            bust_n = bust_n + 1
            local sep = path:find("?", 1, true) and "&" or "?"
            log("304 -> cache-bust retry")
            request(path .. sep .. "_cb=" .. tostring(os.time()) .. tostring(bust_n),
                method, body, auth, cb, base, true)
        elseif (status == 0 or (status == 404 and parsed == nil))
            and cfg.fallback_base_url and base ~= cfg.fallback_base_url then
            -- Retry via the fallback when:
            --  * status 0  - couldn't connect at all (offline / proxy-only network), or
            --  * status 404 with a NON-JSON body - the current origin has no API
            --    proxy route at all (e.g. an HTML5 build served by the Defold
            --    editor's own static server). Real API 404s return JSON and are
            --    NOT retried.
            log("retrying via fallback:", cfg.fallback_base_url)
            request(path, method, body, auth, cb, cfg.fallback_base_url, _busted)
        else
            local err = extract_error(parsed, "HTTP " .. tostring(status))
            if status == 0 then
                err = "network unreachable (offline, DNS or CORS blocked)"
            end
            if cb then cb(false, err, parsed) end
        end
    end

    if html5 then
        -- web: the browser itself performs the request (see js_fetch above)
        js_fetch(url, method, headers, payload, cfg.timeout, handle_response)
    else
        -- ignore_cache: skip Defold's local http cache (no If-None-Match conditionals)
        http.request(url, method, function(_, _, response)
            handle_response(response)
        end, headers, payload, { timeout = cfg.timeout, ignore_cache = true })
    end
end

--------------------------------------------------------------------------------
-- config / session
--------------------------------------------------------------------------------

function M.init(options)
    assert(type(options) == "table", "rastar.init(options) expects a table")
    cfg.base_url = options.base_url or cfg.base_url
    cfg.app_id   = options.app_id or cfg.app_id
    cfg.game_id  = options.game_id or cfg.game_id
    cfg.timeout  = options.timeout or cfg.timeout
    cfg.log      = options.log or false
    cfg.fallback_base_url = options.fallback_base_url or cfg.fallback_base_url
    -- strip trailing slashes
    if cfg.base_url:sub(-1) == "/" then cfg.base_url = cfg.base_url:sub(1, -2) end
    if cfg.fallback_base_url and cfg.fallback_base_url:sub(-1) == "/" then
        cfg.fallback_base_url = cfg.fallback_base_url:sub(1, -2)
    end
end

-- Resolve the page origin on HTML5 (for same-origin proxy setups). "" elsewhere.
function M.html5_origin()
    if html5 then
        local ok, origin = pcall(html5.run, "window.location.origin")
        if ok and origin and origin ~= "" then return origin end
    end
    return ""
end

function M.is_logged_in() return state.access_token ~= nil end
function M.get_token() return state.access_token end
function M.set_token(t) state.access_token = t end
function M.get_refresh_token() return state.refresh_token end
function M.get_cached_profile() return state.profile end
function M.get_game_id() return cfg.game_id end

local function on_login(cb)
    return function(ok, data, raw)
        if ok and data and data.accessToken then
            state.access_token = data.accessToken
            state.refresh_token = data.refreshToken
        end
        if cb then cb(ok, data, raw) end
    end
end

--------------------------------------------------------------------------------
-- auth  (/api/v1/client/auth/*)
--------------------------------------------------------------------------------

-- Frictionless login bound to a device id (creates the account on first use).
function M.device_login(device_id, cb)
    request("/api/v1/client/auth/device-id-login", "POST",
        { deviceId = device_id }, false, on_login(cb))
end

function M.basic_signup(phone, email, password, cb)
    request("/api/v1/client/auth/basic-signup", "POST",
        { phoneNumber = phone, email = email, password = password }, false, on_login(cb))
end

function M.basic_login(phone, email, password, cb)
    request("/api/v1/client/auth/basic-login", "POST",
        { phoneNumber = phone, email = email, password = password }, false, on_login(cb))
end

function M.otp_login_email(email, cb)
    request("/api/v1/client/auth/otp-login", "POST", { email = email }, false, on_login(cb))
end

function M.otp_login_sms(phone, cb)
    request("/api/v1/client/auth/otp-login", "POST", { phoneNumber = phone }, false, on_login(cb))
end

-- method: "EMAIL" | "SMS", type: usually "AUTH"
function M.verify_otp(otp_code, otp_type, method, cb)
    request("/api/v1/client/auth/verify-otp", "POST",
        { otpCode = otp_code, type = otp_type or "AUTH", method = method or "SMS" }, true, on_login(cb))
end

function M.refresh_token(refresh_token, cb)
    request("/api/v1/client/auth/refresh-token", "POST",
        { refreshToken = refresh_token or state.refresh_token }, false, on_login(cb))
end

function M.logout(cb)
    request("/api/v1/client/auth/logout", "POST", nil, true, function(ok, data, raw)
        state.access_token, state.refresh_token, state.profile = nil, nil, nil
        if cb then cb(ok, data, raw) end
    end)
end

-- platform: e.g. "google" | "apple"; token: the provider's id/access token
function M.social_login(platform, token, cb)
    request("/api/v1/client/auth/social-login", "POST",
        { platform = platform, token = token }, false, on_login(cb))
end

function M.verify_magic_link(magic_token, cb)
    request("/api/v1/client/auth/verify-magic-link?token=" .. (magic_token or ""),
        "GET", nil, false, on_login(cb))
end

-- method: "EMAIL" | "SMS", type: usually "AUTH"
function M.resend_otp(otp_type, method, cb)
    request("/api/v1/client/auth/resend-otp", "POST",
        { type = otp_type or "AUTH", method = method or "SMS" }, true, cb)
end

function M.reset_password(phone, email, cb)
    request("/api/v1/client/auth/reset-password", "POST",
        { phoneNumber = phone, email = email }, false, cb)
end

function M.set_password(new_password, cb)
    request("/api/v1/client/auth/set-password", "POST",
        { newPassword = new_password }, true, on_login(cb))
end

-- send an OTP to a NEW phone/email to verify the change
function M.change_phone(new_phone, cb)
    request("/api/v1/client/auth/change-phone-email", "POST",
        { phoneNumber = new_phone }, true, cb)
end

function M.change_email(new_email, cb)
    request("/api/v1/client/auth/change-phone-email", "POST",
        { email = new_email }, true, cb)
end

--------------------------------------------------------------------------------
-- user profile  (/api/v1/client/users/*)
--------------------------------------------------------------------------------

function M.get_profile(cb)
    request("/api/v1/client/users/me", "GET", nil, true, function(ok, data, raw)
        if ok then state.profile = data end
        if cb then cb(ok, data, raw) end
    end)
end

-- fields: { username=, name=, lastName=, gender=, avatarId= } (all optional)
function M.update_profile(fields, cb)
    request("/api/v1/client/users/update-profile", "POST", fields, true, function(ok, data, raw)
        if ok then state.profile = data end
        if cb then cb(ok, data, raw) end
    end)
end

function M.search_users(query, cb)
    request("/api/v1/client/users/search?query=" .. (query or ""), "GET", nil, true, cb)
end

function M.update_password(current_password, new_password, cb)
    request("/api/v1/client/users/update-password", "POST",
        { currentPassword = current_password, newPassword = new_password }, true, cb)
end

function M.get_user_by_invite_code(invite_code, cb)
    request("/api/v1/client/users/invite-code/" .. (invite_code or ""), "GET", nil, true, cb)
end

function M.set_inviter(invite_code, cb)
    request("/api/v1/client/users/set-inviter", "POST", { inviteCode = invite_code }, true, cb)
end

function M.delete_account(cb)
    request("/api/v1/client/users/me", "DELETE", nil, true, cb)
end

--------------------------------------------------------------------------------
-- games / score  (/api/v1/client/games/*)
--------------------------------------------------------------------------------

local function need_game_id(game_id)
    local id = game_id or cfg.game_id
    assert(id, "rastar: game_id missing (pass it or set in rastar.init)")
    return id
end

function M.list_games(page, limit, cb)
    request(("/api/v1/client/games?page=%d&limit=%d"):format(page or 1, limit or 20),
        "GET", nil, true, cb)
end

-- Submit a score run. Backend keeps lastScore + highScore server-side.
function M.send_score(score, cb, game_id)
    local id = need_game_id(game_id)
    request(("/api/v1/client/games/%s/send-score"):format(id), "POST",
        { score = score }, true, cb)
end

-- result: "Win" | "Lose" | "Draw"
function M.send_result(result, cb, game_id)
    local id = need_game_id(game_id)
    request(("/api/v1/client/games/%s/send-result"):format(id), "POST",
        { state = result }, true, cb)
end

function M.increment_play_count(cb, game_id)
    local id = need_game_id(game_id)
    request(("/api/v1/client/games/%s/play"):format(id), "POST", nil, true, cb)
end

-- Full per-user game record: { statistics = { highScore, lastScore, playCount, ... }, ... }
function M.get_my_game(cb, game_id)
    local id = need_game_id(game_id)
    request(("/api/v1/client/games/my-games/games/%s"):format(id), "GET", nil, true, cb)
end

-- Convenience: cb(ok, high_score_number_or_error)
function M.get_high_score(cb, game_id)
    M.get_my_game(function(ok, data)
        if ok and data and data.statistics then
            cb(true, data.statistics.highScore or 0)
        elseif not ok and type(data) == "string" and data:find("not%s*found") then
            cb(true, 0)  -- never played yet -> no record on the server
        else
            cb(ok, ok and 0 or data)
        end
    end, game_id)
end

function M.get_game(game_id, cb)
    request("/api/v1/client/games/" .. need_game_id(game_id), "GET", nil, true, cb)
end

function M.give_game(cb, game_id)
    request(("/api/v1/client/games/%s/give"):format(need_game_id(game_id)), "POST", nil, true, cb)
end

function M.get_my_games_list(page, limit, cb)
    request(("/api/v1/client/games/my-games/list?page=%d&limit=%d"):format(page or 1, limit or 20),
        "GET", nil, true, cb)
end

function M.get_my_game_by_usergame_id(user_game_id, cb)
    request("/api/v1/client/games/my-games/" .. user_game_id, "GET", nil, true, cb)
end

-- metadata: free-form table stored on my game record
function M.update_game_metadata(metadata, cb, game_id)
    request(("/api/v1/client/games/%s/update-metadata"):format(need_game_id(game_id)),
        "PATCH", { metadata = metadata }, true, cb)
end

--------------------------------------------------------------------------------
-- events  (/api/v1/client/events/*)
-- Events are the backbone of leaderboards: a leaderboard aggregates events of
-- its eventType with eventCalculationType (count / sum_value / high_value).
--------------------------------------------------------------------------------

-- Log an event for the signed-in user. value must be a number (payload type
-- "number"); pass extra context in metadata (table); entity_id is the optional
-- event-entity guid some Unity wrappers carry — the API rejects it as a body
-- field ("property entityId should not exist"), so it is stored in metadata.
-- cb(ok, response_data)
function M.send_event(event_type, value, metadata, cb, entity_id)
    metadata = metadata or { source = sys.get_sys_info().system_name or "defold" }
    if entity_id then metadata.entityId = entity_id end
    request("/api/v1/client/events/send", "POST", {
        eventType = event_type,
        payload   = { type = "number", value = value or 1 },
        metadata  = metadata,
    }, true, cb)
end

-- Aggregate my own events server-side. calc_type: "count"|"sum_value"|"high_value"
-- cb(ok, result_number_or_error)
function M.calculate_event(event_type, calc_type, cb)
    request(("/api/v1/client/events/%s/calculate?type=%s")
        :format(event_type, calc_type or "high_value"), "GET", nil, true,
        function(ok, data)
            if ok and type(data) == "table" then
                cb(true, data.result or 0)
            else
                cb(ok, ok and 0 or data)
            end
        end)
end

-- cb(ok, count_number_or_error)
function M.get_event_count(event_type, cb)
    request(("/api/v1/client/events/%s/count"):format(event_type), "GET", nil, true,
        function(ok, data)
            if ok and type(data) == "table" then cb(true, data.count or 0)
            else cb(ok, ok and 0 or data) end
        end)
end

--------------------------------------------------------------------------------
-- leaderboards  (/api/v1/client/leaderboards/*)
-- New (baziche/FastAPI) backend: scores are registered DIRECTLY on a
-- leaderboard; the server applies the board's eventCalculationType (e.g.
-- high_value keeps each player's best). No events round-trip needed.
--------------------------------------------------------------------------------

function M.get_active_leaderboards(cb)
    request("/api/v1/client/leaderboards/active", "GET", nil, true, cb)
end

-- Look a board up by its stable key (e.g. "weekly_Leaderboard").
-- cb(ok, LeaderboardResponse{id,key,name,eventCalculationType,version,...})
function M.get_leaderboard_by_key(key, cb)
    request(("/api/v1/client/leaderboards/key/%s"):format(key), "GET", nil, true, cb)
end

-- Submit a score. The server aggregates per the board's calculation type and
-- returns my standing: cb(ok, {value=server_kept_value, rank=..., version=...})
function M.register_score(leaderboard_id, value, meta, cb)
    request(("/api/v1/client/leaderboards/%s/register-score"):format(leaderboard_id),
        "POST", { value = value, meta = meta }, true, cb)
end

-- Top entries: cb(ok, {leaderboard=..., users={ {rank,value,userId,userData={name,username,...}} }, requestedUserRank})
function M.get_leaderboard_ranks(leaderboard_id, page, limit, cb)
    request(("/api/v1/client/leaderboards/%s/ranks?page=%d&limit=%d")
        :format(leaderboard_id, page or 1, limit or 10), "GET", nil, true, cb)
end

-- Back-compat wrapper shaped like the OLD /scores endpoint: returns a flat
-- array of { rank, score, user = userData }.
function M.get_leaderboard_scores(leaderboard_id, page, limit, cb)
    M.get_leaderboard_ranks(leaderboard_id, page, limit, function(ok, data)
        if not ok or type(data) ~= "table" then cb(ok, data) return end
        local items = {}
        for i, u in ipairs(data.users or {}) do
            local ud = u.userData or {}
            ud.userId = ud.userId or u.userId
            items[i] = { rank = u.rank or i, score = u.value or 0, user = ud }
        end
        cb(true, items)
    end)
end

-- My standing on a board: cb(ok, {rank, value, userData, ...})
function M.get_my_rank(leaderboard_id, cb)
    request(("/api/v1/client/leaderboards/%s/users/rank"):format(leaderboard_id),
        "GET", nil, true, cb)
end

function M.list_leaderboards(page, limit, cb)
    request(("/api/v1/client/leaderboards/?page=%d&limit=%d"):format(page or 1, limit or 20),
        "GET", nil, true, cb)
end

function M.get_leaderboard(leaderboard_id, cb)
    request("/api/v1/client/leaderboards/" .. leaderboard_id, "GET", nil, true, cb)
end

-- the rows around ME on the board
function M.get_my_neighbours(leaderboard_id, cb)
    request(("/api/v1/client/leaderboards/%s/neighbours"):format(leaderboard_id),
        "GET", nil, true, cb)
end

function M.get_users_neighbors(leaderboard_id, cb)
    request(("/api/v1/client/leaderboards/%s/users/neighbors"):format(leaderboard_id),
        "GET", nil, true, cb)
end

-- tier: -1 = my own tier
function M.get_tier_scores(leaderboard_id, tier, page, limit, cb)
    request(("/api/v1/client/leaderboards/%s/tiers/scores?tier=%d&page=%d&limit=%d")
        :format(leaderboard_id, tier or -1, page or 1, limit or 10), "GET", nil, true, cb)
end

-- a finished season/week of the board
function M.get_leaderboard_history(leaderboard_id, version, cb)
    request(("/api/v1/client/leaderboards/%s/history/%d"):format(leaderboard_id, version),
        "GET", nil, true, cb)
end

--------------------------------------------------------------------------------
-- currencies  (/api/v1/client/currencies/*)
-- NOTE: add/use take the currency's UUID (currencyId), NOT its key — the
-- balance lookup by key returns that id, so resolve once and cache it.
--------------------------------------------------------------------------------

-- cb(ok, { value = balance, currencyId = uuid, currency = {name, key, ...} })
function M.get_currency(key, cb)
    request("/api/v1/client/currencies/" .. key, "GET", nil, true, cb)
end

function M.get_currencies(cb)
    request("/api/v1/client/currencies/all", "GET", nil, true, cb)
end

-- cb(ok, { value = new_balance, ... })
function M.add_currency(currency_id, value, cb)
    request("/api/v1/client/currencies/add", "POST",
        { currencyId = currency_id, value = value }, true, cb)
end

function M.use_currency(currency_id, value, cb)
    request("/api/v1/client/currencies/use", "POST",
        { currencyId = currency_id, value = value }, true, cb)
end

--------------------------------------------------------------------------------
-- escape hatch: call ANY backend endpoint not wrapped above.
--   rastar.request("/api/v1/client/avatars", "GET", nil, cb)
--   rastar.request("/api/v1/client/assets/sync", "POST", { ... }, cb)
-- opts: { auth = false } to skip the Authorization header (default: attach it).
-- The full client surface is listed in the backend swagger (<base_url>/docs);
-- ready-made named wrappers for many modules live in rastar/api.lua.
--------------------------------------------------------------------------------
function M.request(path, method, body, cb, opts)
    local auth = true
    if opts and opts.auth == false then auth = false end
    request(path, method or "GET", body, auth, cb)
end

return M

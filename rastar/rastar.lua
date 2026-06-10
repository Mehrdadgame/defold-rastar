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
    local headers = { ["x-app-id"] = cfg.app_id }
    local payload = nil
    if body ~= nil then
        headers["Content-Type"] = "application/json"
        payload = jencode(body)
    end
    if auth and state.access_token then
        headers["Authorization"] = "Bearer " .. state.access_token
    end
    log(method, url, payload or "")

    -- ignore_cache: skip Defold's local http cache (no If-None-Match conditionals)
    http.request(url, method, function(_, _, response)
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
    end, headers, payload, { timeout = cfg.timeout, ignore_cache = true })
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
-- leaderboards (read)  (/api/v1/client/leaderboards/*)
--------------------------------------------------------------------------------

function M.get_active_leaderboards(cb)
    request("/api/v1/client/leaderboards/active", "GET", nil, true, cb)
end

function M.get_leaderboard_scores(leaderboard_id, page, limit, cb)
    request(("/api/v1/client/leaderboards/%s/scores?page=%d&limit=%d")
        :format(leaderboard_id, page or 1, limit or 10), "GET", nil, true, cb)
end

function M.get_my_rank(leaderboard_id, cb)
    request(("/api/v1/client/leaderboards/%s/users/rank"):format(leaderboard_id),
        "GET", nil, true, cb)
end

return M

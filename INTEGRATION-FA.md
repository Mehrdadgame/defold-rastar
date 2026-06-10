# راهنمای اتصال بازی Defold به بک‌اند Rastar Center

این پکیج (`defold-rastar`) پورتِ Lua از **Rastar-Center-Unity-SDK** است: همان REST API، همان
هدرها، همان مدل داده — ولی قابل استفاده در هر بازی Defold (وب، دسکتاپ، موبایل). هیچ
native extension لازم ندارد؛ فقط `http.request` و `json` خود Defold.

## محتویات پکیج

| فایل | کاربرد |
|---|---|
| `rastar/rastar.lua` | کلاینت API: لاگین، پروفایل، امتیاز/event، لیدربورد |
| `rastar/farsi.lua` | شکل‌دهی متن فارسی/عربی برای رندر در Defold (اختیاری) |
| `rastar/fonts/persian.ttf` + `names.font` | فونت Vazirmatn با حروف فارسی (اختیاری) |
| `tools/rastar_proxy.py` | سرور استاتیک + پراکسی same-origin برای بیلد وب |

---

## ۱) نصب در یک پروژهٔ جدید

**روش الف — کپی (ساده‌ترین):** پوشهٔ `rastar/` را کنار `game.project` پروژه‌ات کپی کن. تمام.

**روش ب — Dependency رسمی Defold:** این مخزن را روی GitLab/GitHub بگذار و در
`game.project ← project ← dependencies` آدرس zip را اضافه کن، بعد *Project ▸ Fetch Libraries*:

```
https://your-git/defold-rastar/-/archive/main/defold-rastar-main.zip
```

در هر دو روش، در کد این‌طور استفاده می‌شود:

```lua
local rastar = require "rastar.rastar"
```

---

## ۲) راه‌اندازی (یک بار، اول بازی)

```lua
local rastar = require "rastar.rastar"

local BASE = "https://rastar-center-api.rastar.ir"
if html5 then
    -- وب: API هدر CORS نمی‌فرستد؛ از طریق پراکسی same-origin صدا بزن (بخش ۶)
    BASE = rastar.html5_origin() .. "/rastarapi"
end

rastar.init({
    base_url          = BASE,
    app_id            = "bitbox",                      -- اپ‌آیدی خودت
    -- دسکتاپ/ادیتور: اگر اینترنتِ سیستم فقط از پراکسی ویندوز رد می‌شود، موتور
    -- Defold آن را نمی‌بیند ("No route to host") — این آدرس به‌صورت خودکار
    -- به‌عنوان مسیر دوم امتحان می‌شود:
    fallback_base_url = "http://localhost:8123/rastarapi",
    timeout           = 15,
    log               = false,                         -- true = لاگ همهٔ درخواست‌ها
})
```

> همهٔ کال‌بک‌ها یک شکل دارند: `cb(ok, data_or_error, raw_response)`.
> بعد از لاگین موفق، توکن داخل ماژول نگه داشته می‌شود و `Authorization: Bearer`
> خودکار به همهٔ درخواست‌ها اضافه می‌شود.

---

## ۳) لاگین + اسم بازیکن

سادہ‌ترین مدل: **device-id login** (بار اول، اکانت خودکار ساخته می‌شود). device_id را
یک بار بساز و همیشه همان را بفرست (sys.save) — این کلیدِ اکانت است:

```lua
local function ensure_device_id(profile)   -- profile = جدول sys.load شدهٔ خودت
    if profile.device_id then return profile.device_id end
    math.randomseed(os.time())
    local hex = {}
    for i = 1, 32 do hex[i] = string.format("%x", math.random(0, 15)) end
    profile.device_id = "dfld-" .. table.concat(hex)
    -- sys.save(...) profile
    return profile.device_id
end

rastar.device_login(device_id, function(ok, auth)
    if not ok then print("login failed:", auth) return end
    -- ذخیرهٔ اسم نمایشی روی سرور (در لیدربورد به‌عنوان firstName دیده می‌شود)
    rastar.update_profile({ name = "Ali" }, function() end)
end)
```

روش‌های دیگر هم هست: `basic_signup/basic_login` (ایمیل/موبایل + رمز)،
`otp_login_email/otp_login_sms + verify_otp`، و `refresh_token`.

**UX پیشنهادی:** اسم را فقط بار اول بپرس؛ دفعات بعد با `device_id` و اسمِ ذخیره‌شده
بی‌صدا لاگین کن (در بازی نمونه `screens/login/login.gui_script` همین کار را می‌کند).

---

## ۴) امتیاز — معادل `SendCashAsync` یونیتی

در این بک‌اند، امتیاز از مسیر **Events** می‌رود و لیدربوردها روی همان eventها ساخته
می‌شوند:

```lua
-- پایان هر دست: امتیازِ کسب‌شده را به‌صورت «عدد» بفرست
rastar.send_event("wallet:revealed", score,
    { game = "mygame", score = score },                 -- metadata دلخواه
    function(ok, res) end,
    "87faac1a-547b-4077-8d5e-437a50eb1379")             -- entityId (اختیاری؛ در metadata می‌نشیند)

-- بهترین امتیاز شخصی (محاسبه سمت سرور روی eventهای خودت)
rastar.calculate_event("wallet:revealed", "high_value", function(ok, best) end)

-- مجموع امتیازهای شخصی
rastar.calculate_event("wallet:revealed", "sum_value", function(ok, total) end)
```

⚠️ **دو نکتهٔ حیاتی:**
1. ستون امتیازِ لیدربورد را تنظیمِ خود لیدربورد تعیین می‌کند:
   `eventCalculationType` = `count` (تعداد دفعات بازی) / `sum_value` (مجموع امتیازها) /
   `high_value` (**بیشترین امتیاز** — برای «بهترین رکورد هر بازیکن» همین را بگذار).
   این فیلد فقط از **پنل ادمین Rastar** قابل تغییر است — API کلاینت هیچ route ِ
   نوشتنی برای لیدربورد ندارد (تست شده: PATCH/PUT → 404؛ سطح `/api/v1/admin` هم
   401-محافظت‌شده است).
2. مقدار را **عدد** بفرست (این SDK همیشه `payload.type="number"` می‌فرستد). اورلود
   `score.ToString()` در یونیتی payload از نوع string می‌سازد که برای sum/high مناسب نیست —
   در یونیتی هم بهتر است اورلود float صدا زده شود.

> API فیلد `entityId` را در بدنهٔ send **قبول نمی‌کند** («property entityId should not
> exist») — این SDK آن را در `metadata.entityId` می‌گذارد.

---

## ۵) لیدربورد

```lua
-- لیست بوردهای فعال (id + key + eventType + eventCalculationType)
rastar.get_active_leaderboards(function(ok, boards) end)

-- ۱۰ نفر برتر یک بورد
rastar.get_leaderboard_scores(board_id, 1, 10, function(ok, items)
    -- items[i] = { rank, score, user = { userId, username, firstName, lastName } }
end)

-- رتبهٔ خودم
rastar.get_my_rank(board_id, function(ok, mine) end)  -- mine = { rank, score, user }
```

**نکتهٔ تساوی‌ها:** لیستِ `scores` ردیف‌ها را ترتیبی شماره می‌زند (۱،۲،۳،…) ولی
`users/rank` رتبهٔ مسابقه‌ای می‌دهد (امتیازهای مساوی رتبهٔ مشترک). اگر هر دو را نشان
می‌دهی، لیست را سمت کلاینت با همان منطق بازشماری کن تا یکدست شود (نمونهٔ کامل:
`modules/net.lua ← get_leaderboard` در بازی Candy Guard).

---

## ۶) بیلد وب (HTML5) — CORS و پراکسی

API فعلاً `Access-Control-Allow-Origin` نمی‌فرستد، پس مرورگر تماس مستقیم از دامنهٔ
دیگر را بلاک می‌کند. دو راه:

1. **(درست‌ترین)** تیم بک‌اند originِ بازی را whitelist کند → آن‌وقت `base_url` همان
   آدرس API می‌شود و پراکسی لازم نیست.
2. **پراکسی same-origin** کنار خود بازی (همین الان کار می‌کند):

```
python tools/rastar_proxy.py --dir "<پوشهٔ باندل HTML5>" --port 8123
```

این سرور هم باندل را serve می‌کند هم `‎/rastarapi/*` را به API فوروارد می‌کند — و
هدرهای کشِ مشکل‌ساز (ETag/304) را هم پاک می‌کند. در بازی فقط کافی است (بخش ۲):
`base_url = rastar.html5_origin() .. "/rastarapi"`.

برای **دسکتاپ/ادیتور** هم اگر شبکهٔ سیستم پشت پراکسی ویندوز است همین سرور را روشن
بگذار — `fallback_base_url` خودش به آن سوییچ می‌کند.

---

## ۷) نمایش اسم‌های فارسی (اختیاری)

Defold متن عربی/فارسی را شکل‌دهی نمی‌کند (حروف جدا و برعکس می‌افتند). این پکیج یک
شکل‌دهندهٔ سبک + فونت آماده دارد:

1. در فایل `.gui` صفحه، فونت را اضافه کن: name=`names`، font=`/rastar/fonts/names.font`
2. در کد:

```lua
local farsi = require "rastar.farsi"

local function set_name(node, name)
    if farsi.has_rtl(name) then
        gui.set_font(node, "names")
        gui.set_text(node, farsi.display(name))   -- شکل‌دهی + ترتیب RTL
    else
        gui.set_font(node, "ui")
        gui.set_text(node, name)
    end
end
```

---

## ۸) عیب‌یابی سریع

| علامت | علت / راه‌حل |
|---|---|
| `No route to host` در ادیتور | موتور پراکسی ویندوز را نمی‌بیند → `fallback_base_url` + روشن بودن rastar_proxy |
| بار دوم هر صفحه `HTTP 304` | حل‌شده داخل SDK (`ignore_cache` + retry با cache-bust) — SDK را آپدیت کن |
| در وب `network unreachable` | پراکسی روشن نیست یا `base_url` به `/rastarapi` اشاره نمی‌کند |
| امتیاز لیدربورد = تعداد بازی | بورد روی `count` است → در پنل `high_value` (بیشترین) یا `sum_value` (مجموع) کن (بخش ۴) |
| `property entityId should not exist` | entityId را در بدنه نفرست — این SDK خودش در metadata می‌گذارد |
| اسم بقیه خالی/«Player» | آن اکانت‌ها `update_profile` نزده‌اند؛ از سمت کلاینت قابل ساخت نیست |
| بهترین امتیازِ کاربرِ تازه | `calculate_event` صفر برمی‌گرداند — طبیعی است |

---

## ۹) مرجع کامل توابع

```
init(opts)                              -- base_url, app_id, game_id?, timeout?, log?, fallback_base_url?
html5_origin()                          -- origin صفحهٔ وب ("" در غیر html5)
is_logged_in() / get_token() / set_token(t) / get_refresh_token() / get_cached_profile()

device_login(device_id, cb)
basic_signup(phone, email, pass, cb) / basic_login(phone, email, pass, cb)
otp_login_email(email, cb) / otp_login_sms(phone, cb) / verify_otp(code, type, method, cb)
refresh_token(token, cb) / logout(cb)

get_profile(cb) / update_profile({username|name|lastName|gender|avatarId}, cb)

send_event(event_type, value, metadata, cb, entity_id)
calculate_event(event_type, "count"|"sum_value"|"high_value", cb)
get_event_count(event_type, cb)

get_active_leaderboards(cb)
get_leaderboard_scores(id, page, limit, cb)
get_my_rank(id, cb)

-- مسیر قدیمی games (اگر برای اپ‌ات game تعریف شده):
list_games(page, limit, cb) / send_score(score, cb) / get_my_game(cb) / get_high_score(cb)
send_result("Win"|"Lose"|"Draw", cb) / increment_play_count(cb)
```

## ۱۰) چک‌لیست انتشار

- [ ] `app_id` درست (و `game_id` اگر از مسیر games استفاده می‌کنی)
- [ ] eventType و entityId مطابق تعریف بک‌اندت
- [ ] لیدربورد با `eventCalculationType` درست (sum_value برای مجموع امتیاز)
- [ ] وب: یا CORS whitelist یا rastar_proxy کنار بازی
- [ ] device_id با sys.save پایدار شده (وگرنه هر بار اکانت جدید ساخته می‌شود)
- [ ] فونت names فقط در صفحه‌هایی که اسم نشان می‌دهند اضافه شده (حجم اطلس فونت)

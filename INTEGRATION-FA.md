# راهنمای اتصال بازی Defold به بک‌اند Rastar Center

> **بک‌اند فعلی (baziche):** dev = `https://baziche-api-dev.rastar.ir` (`/docs` = swagger)
> | dashboard = `https://baziche-admin-dev.rastar.ir`. originهای
> `mehrdadgame.github.io` و `localhost:8123` در CORS وایت‌لیست شده‌اند → وب مستقیم وصل می‌شود.

این پکیج (`defold-rastar`) پورتِ Lua از **Rastar-Center-Unity-SDK** است: همان REST API، همان
هدرها، همان مدل داده — ولی قابل استفاده در هر بازی Defold (وب، دسکتاپ، موبایل). هیچ
native extension لازم ندارد؛ فقط `http.request` و `json` خود Defold.

## محتویات پکیج

| فایل | کاربرد |
|---|---|
| `rastar/rastar.lua` | هستهٔ کلاینت: لاگین (همهٔ روش‌ها)، پروفایل، امتیاز، لیدربورد، events، games |
| `rastar/api.lua` | **کل سطح API** — ۲۲۳ تابع تولیدشده از swagger در ۳۴ ماژول (assets، avatars، clans، friends، shops، tasks، quiz-v2، payments، …) |
| `rastar/farsi.lua` | شکل‌دهی متن فارسی/عربی برای رندر در Defold (اختیاری) |
| `rastar/fonts/persian.ttf` + `names.font` | فونت Vazirmatn با حروف فارسی (اختیاری) |
| `tools/rastar_proxy.py` | سرور استاتیک + پراکسی same-origin برای بیلد وب |
| `tools/gen_rastar_api.py` + `openapi.json` | بازتولید `api.lua` بعد از هر آپدیت بک‌اند |

**سه سطح دسترسی به API** (از مشخص به عام):
```lua
local rastar = require "rastar.rastar"   -- ۱) توابع اصلی دست‌نویس (لاگین/امتیاز/لیدربورد...)
local api    = require "rastar.api"      -- ۲) همهٔ ماژول‌ها: api.get_friends(nil, cb) ، api.post_clans_join(clan_id, nil, cb) ...
rastar.request("/api/v1/client/...", "GET", nil, cb)  -- ۳) هر endpoint دلخواه (escape hatch)
```
وقتی بک‌اند آپدیت شد:
```bash
curl -o tools/openapi.json https://baziche-api-dev.rastar.ir/openapi.json
python tools/gen_rastar_api.py
```

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

local BASE = "https://baziche-api-dev.rastar.ir"   -- production: آدرس prod را بگذار
if html5 then
    -- وب: API هدر CORS نمی‌فرستد؛ از طریق پراکسی same-origin صدا بزن (بخش ۶)
    BASE = rastar.html5_origin() .. "/rastarapi"
end

rastar.init({
    base_url          = BASE,
    app_id            = "",   -- بک‌اند جدید (baziche) تک‌اپ است؛ x-app-id لازم ندارد
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

## ۴) امتیاز — ثبت مستقیم روی لیدربورد (بک‌اند جدید)

در بک‌اند جدید (baziche / FastAPI) امتیاز **مستقیم روی لیدربورد** ثبت می‌شود و خود
سرور بر اساس `eventCalculationType` بورد جمع می‌زند (مثلاً `high_value` = همیشه
بهترین امتیاز هر بازیکن نگه داشته می‌شود):

```lua
-- یک بار: پیدا کردن بورد با key پایدار
rastar.get_leaderboard_by_key("weekly_Leaderboard", function(ok, lb)
    -- lb.id , lb.eventCalculationType ("high_value") , lb.lifeSpanHours (168 = هفتگی)
end)

-- پایان هر دست: ثبت امتیاز؛ پاسخ، امتیازِ نگه‌داشته‌شده + رتبهٔ فعلی توست
rastar.register_score(lb.id, score, { game = "mygame" }, function(ok, res)
    -- res.value = بهترین امتیازت (سرور خودش max را نگه می‌دارد)
    -- res.rank  = رتبهٔ فعلی
end)
```

> مسیر قدیمیِ events (`send_event` / `calculate_event`) هنوز در SDK هست و روی
> بک‌اند جدید هم endpoint دارد، ولی برای امتیازِ لیدربورد دیگر لازم نیست.

## ۵) لیدربورد

```lua
-- لیست بوردهای فعال (id + key + eventType + eventCalculationType)
rastar.get_active_leaderboards(function(ok, boards) end)

-- ۱۰ نفر برتر یک بورد (endpoint جدید: /ranks)
rastar.get_leaderboard_ranks(board_id, 1, 10, function(ok, data)
    -- data.users[i] = { rank, value, userId, userData = { name, username, lastName } }
end)
-- یا با همان شکل قدیمی:
rastar.get_leaderboard_scores(board_id, 1, 10, function(ok, items)
    -- items[i] = { rank, score, user = {...} }  (سازگار با کد قدیمی)
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

✅ **بک‌اند جدید (baziche) وایت‌لیست CORS دارد** و `mehrdadgame.github.io` +
`localhost:8123` همین حالا وایت‌لیست شده‌اند → وب از این دامنه‌ها **مستقیم** وصل
می‌شود و پراکسی لازم نیست. برای هر دامنهٔ جدید فقط origin را (بدون path) به تیم
بک‌اند بده تا به `BACKEND_CORS_ORIGINS` اضافه کند. مطالب زیر برای دامنه‌های
وایت‌لیست‌نشده یا شبکه‌های پشت پراکسی است:

1. **(درست‌ترین — برای همهٔ بازی‌های وب یک بار حل می‌شود)** تیم بک‌اند CORS را کامل
   کند. وضعیت فعلی سرور: preflight پاسخ `Access-Control-Allow-Credentials/Methods/
   Headers` می‌دهد ولی **`Access-Control-Allow-Origin` ندارد** — یعنی میدل‌ور CORS فعال
   است و فقط باید originها ست شوند. متن آماده برای تیم بک‌اند:

   > روی `rastar-center-api.rastar.ir` هدر `Access-Control-Allow-Origin` را برای
   > دامنه‌های بازی‌ها (یا `origin: true` برای echo) فعال کنید — هم روی پاسخ preflight
   > (OPTIONS) هم روی پاسخ‌های واقعی. نمونهٔ NestJS/Express:
   > ```js
   > app.enableCors({
   >   origin: true,            // یا آرایهٔ دامنه‌های مجاز بازی‌ها
   >   credentials: true,
   >   methods: "GET,HEAD,PUT,PATCH,POST,DELETE,OPTIONS",
   >   allowedHeaders: "Content-Type, Authorization, x-app-id",
   > });
   > ```
   > تست صحت (باید `Access-Control-Allow-Origin` در خروجی باشد):
   > ```bash
   > curl -si https://rastar-center-api.rastar.ir/api/v1/client/leaderboards/active \
   >   -H "Origin: https://your-game-host.com" -H "x-app-id: bitbox" | grep -i access-control
   > ```

   کلاینت این پکیج از قبل آماده است: روی وب اول تماس مستقیم را امتحان می‌کند و فقط
   اگر بلاک شد سراغ پراکسی می‌رود — یعنی به‌محض فعال‌شدن CORS، همهٔ بیلدها بدون
   پراکسی و بدون rebuild کار می‌کنند.
2. **پراکسی same-origin** کنار خود بازی (همین الان کار می‌کند):

```
python tools/rastar_proxy.py --dir "<پوشهٔ باندل HTML5>" --port 8123
```

این سرور هم باندل را serve می‌کند هم `‎/rastarapi/*` را به API فوروارد می‌کند — و
هدرهای کشِ مشکل‌ساز (ETag/304) را هم پاک می‌کند. در بازی فقط کافی است (بخش ۲):
`base_url = rastar.html5_origin() .. "/rastarapi"`.

برای **دسکتاپ/ادیتور** هم اگر شبکهٔ سیستم پشت پراکسی ویندوز است همین سرور را روشن
بگذار — `fallback_base_url` خودش به آن سوییچ می‌کند.

### استقرار روی هاست دلخواه (آپلود باندل به سرور خودت)

سه راه — یکی را انتخاب کن:

1. **پراکسی پایتون روی همان سرور:** کل پوشهٔ باندل را آپلود کن و به‌جای static server
   معمولی، `rastar_proxy.py --dir <پوشه>` را اجرا کن (هم serve می‌کند هم `/rastarapi`).
2. **nginx/آپاچی داری؟** فقط این location را اضافه کن (و باندل را استاتیک serve کن):

```nginx
location /rastarapi/ {
    proxy_pass https://rastar-center-api.rastar.ir/;
    proxy_set_header Host rastar-center-api.rastar.ir;
    proxy_set_header If-None-Match "";
    proxy_set_header If-Modified-Since "";
    proxy_hide_header ETag;
    proxy_hide_header Last-Modified;
}
```

3. **پراکسی جای دیگری است؟** در `index.html` متغیر را ست کن تا بازی همان را صدا بزند:

```html
<script>window.RASTAR_API = "https://your-host/rastarapi";</script>
```

⚠️ **هشدارهای استقرار:**
- **همهٔ فایل‌های باندل را با هم** آپلود کن (index.html + dmloader + پوشهٔ archive).
  اگر فایل‌ها از دو بیلد قاطی شوند، dmloader خطای
  `file verification failed! Unexpected data size: game.projectc` می‌دهد و بازی بالا
  نمی‌آید — بعد از هر آپلود، کش CDN/مرورگر را هم پاک کن (Ctrl+Shift+R).
- خطاهای `contentscript.js` (MaxListenersExceeded، ObjectMultiplex و CSP eval) مال
  **افزونه‌های مرورگر** (مثل MetaMask) هستند، نه بازی — در حالت Incognito تست کن.

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
get_leaderboard_by_key(key, cb)                 -- بورد با key پایدار (مثل weekly_Leaderboard)
register_score(leaderboard_id, value, meta, cb) -- ثبت امتیاز؛ پاسخ: {value, rank}
get_leaderboard_ranks(id, page, limit, cb)      -- خام جدید: {leaderboard, users[]}
get_leaderboard_scores(id, page, limit, cb)     -- سازگار با شکل قدیمی
get_my_rank(id, cb)                             -- پاسخ جدید: {rank, value, userData}

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

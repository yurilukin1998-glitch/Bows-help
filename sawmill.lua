script_name('SawmillBot')
script_author('pinokio')
script_version('0.3')

--настройки
local sampev = require('samp.events')
local internal = {}
local ffi = require('ffi')
local bit = require('bit')
local _copas_ok, _copas = pcall(require, 'copas')
local _requests_ok, _requests = pcall(require, 'copas.http')

local NPC = {x = -502.9, y = -185.8}
local FOOD = {x = -551.56219, y = -183.24632}
local IFACE_LUMBER = 8
local DLG_TRAILER, DLG_SAWMILL = 27421, 26135

local running = false
local cfg = {checkTrees = true, sprint = true, jumps = true, antiStamina = false, strafe = true, autoNearestTree = false, stuckSideMeters = 3, render = true, renderPath = true, fxGround = true, avRing = true, pathHelix = true,
    autoEat = true, eatBelow = 30, eatTo = 80, useFrederico = false,
    fab = true, statsWin = true, fabX = false, fabY = false, winX = false, winY = false,
    aaReply = true, aaAI = true, aaStopDialog = false, aaStopTp = true, aaStopChat = true,
    aaQuit = false, aaResume = true, aaSound = true,
    aiEnabled = false, aiKey = '', aiEndpoint = 'https://api.openai.com/v1/chat/completions', aiModel = 'gpt-4o-mini',
    aiSystem = '', fxTrail = true, aaAlert = true, graphMode = 'line', statPeriod = 'all',
    tabSpeed = 150, pathComet = true, pathFlies = true, pathSize = 100, pathRibbon = true, leaves = true, statsX = false, statsY = false, tabAnim = true, sawdust = true, numAnim = true, toasts = true}
local stats = {session = {money = 0, carts = 0, items = {}, start = os.time()}, total = {money = 0, carts = 0, items = {}, time = 0}}
local CONFIG_ROOT = getWorkingDirectory() .. '/config'
local SCRIPT_CONFIG_DIR = CONFIG_ROOT .. '/SawmillBot'
local CFG_PATH = SCRIPT_CONFIG_DIR .. '/SawmillBot.json'
local function ensureScriptConfigDir()
    if not doesDirectoryExist(CONFIG_ROOT) then createDirectory(CONFIG_ROOT) end
    if not doesDirectoryExist(SCRIPT_CONFIG_DIR) then createDirectory(SCRIPT_CONFIG_DIR) end
end
local function migrateFile(oldPath, newPath)
    if doesFileExist(newPath) or not doesFileExist(oldPath) then return end
    local f = io.open(oldPath, 'rb')
    if not f then return end
    local data = f:read('*a'); f:close()
    local out = io.open(newPath, 'wb')
    if out then out:write(data); out:close() end
end

local function saveCfg()
    ensureScriptConfigDir()
    local f = io.open(CFG_PATH, 'w')
    if f then f:write(encodeJson({cfg = cfg, total = stats.total})); f:close() end
    pcall(internal.dayFlush)
end

local function loadCfg()
    local f = io.open(CFG_PATH, 'r')
    if not f then return end
    local ok, d = pcall(decodeJson, f:read('*a')); f:close()
    if not ok or type(d) ~= 'table' then return end
    for k, v in pairs(d.cfg or {}) do if cfg[k] ~= nil then cfg[k] = v end end
    if d.cfg and d.cfg.antiStamina == nil and d.cfg.infStamina ~= nil then
        cfg.antiStamina = d.cfg.infStamina
    end
    if type(d.total) == 'table' then stats.total = d.total; stats.total.items = stats.total.items or {} end
end

local function addStat(kind, name, n)
    for _, s in ipairs({stats.session, stats.total}) do
        if kind == 'money' then s.money = s.money + n
        elseif kind == 'cart' then s.carts = s.carts + 1
        else s.items[name] = (s.items[name] or 0) + n end
    end
    pcall(internal.dayAdd, kind, name, n)
end
local st = {saw = false, cart = false, cp = nil, game = nil, window = false, pendingDlg = nil,
    satiety = nil, hotdogPrice = nil, foodOpen = false, nextSatCheck = 0}

local DBG = getWorkingDirectory() .. '/sawbot_debug.txt'
local function dbg(text)

end
local function msg(text) sampAddChatMessage('{8FBC8F}[Лесопилка] {FFFFFF}' .. text, -1); dbg(text); pcall(internal.toast, text) end

--статистика
local DATA_DIR = SCRIPT_CONFIG_DIR .. '/data'
internal.PERIODS = {
    {'day', 'День', 1, 'За день'}, {'week', 'Неделя', 7, 'За неделю'},
    {'month', 'Месяц', 30, 'За месяц'}, {'all', 'Всё время', 0, 'За всё время'},
}
function internal.dayKey(ts) return os.date('%Y-%m-%d', ts or os.time()) end
function internal.dayPath(key) return DATA_DIR .. '/' .. key .. '/' .. key .. '.txt' end
function internal.dayNew() return {money = 0, carts = 0, time = 0, items = {}, hours = {}} end
function internal.hms(sec) sec = math.floor(sec or 0); return ('%d:%02d:%02d'):format(math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60) end
function internal.hourSlot(d, h)
    local e = d.hours[h]
    if not e then e = {money = 0, carts = 0, time = 0}; d.hours[h] = e end
    return e
end

function internal.dayRead(key)
    local f = io.open(internal.dayPath(key), 'r')
    if not f then return nil end
    local d = internal.dayNew()
    for line in f:lines() do
        local k, v = line:match('^(%w+)=(.*)$')
        if k == 'money' or k == 'carts' or k == 'time' then
            d[k] = tonumber(v) or 0
        else
            local name, cnt = line:match('^item\t(.-)\t(%d+)\r?$')
            if name then d.items[name] = tonumber(cnt) or 0 end
            local hh, hm, hc, ht = line:match('^hour\t(%d+)\t(%d+)\t(%d+)\t(%d+)')
            if hh then
                local e = internal.hourSlot(d, tonumber(hh))
                e.money, e.carts, e.time = tonumber(hm) or 0, tonumber(hc) or 0, tonumber(ht) or 0
            end
        end
    end
    f:close()
    return d
end

function internal.dayWrite(key, d)
    ensureScriptConfigDir()
    if not doesDirectoryExist(DATA_DIR) then createDirectory(DATA_DIR) end
    local dir = DATA_DIR .. '/' .. key
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    local f = io.open(internal.dayPath(key), 'w')
    if not f then return false end
    f:write('date=', key, '\n')
    f:write('money=', ('%d'):format(math.floor(d.money)), '\n')
    f:write('carts=', ('%d'):format(math.floor(d.carts)), '\n')
    f:write('time=', ('%d'):format(math.floor(d.time)), '\n')
    local names = {}
    for name in pairs(d.items) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        f:write('item\t', name, '\t', ('%d'):format(math.floor(d.items[name])), '\n')
    end
    for h = 0, 23 do
        local e = d.hours and d.hours[h]
        if e and (e.money > 0 or e.carts > 0 or e.time > 0) then
            f:write('hour\t', ('%02d'):format(h), '\t', ('%d'):format(math.floor(e.money)), '\t',
                ('%d'):format(math.floor(e.carts)), '\t', ('%d'):format(math.floor(e.time)), '\n')
        end
    end
    f:close()
    return true
end

function internal.dayRoll()
    local key = internal.dayKey()
    local t = internal.today
    if t and t.key == key then return t end
    if t and t.dirty then internal.dayWrite(t.key, t.d) end
    internal.today = {key = key, d = internal.dayRead(key) or internal.dayNew(), dirty = false}
    return internal.today
end

function internal.dayAdd(kind, name, n)
    local t = internal.dayRoll()
    local d = t.d
    local e = internal.hourSlot(d, tonumber(os.date('%H')))
    if kind == 'money' then d.money = d.money + n; e.money = e.money + n
    elseif kind == 'cart' then d.carts = d.carts + 1; e.carts = e.carts + 1
    else d.items[name] = (d.items[name] or 0) + n end
    t.dirty = true
end

function internal.dayFlush()
    local t = internal.today
    if t and t.dirty and internal.dayWrite(t.key, t.d) then t.dirty = false end
end

internal.RU_WD = {'Вс', 'Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб'}
internal.dayCache = {}

function internal.agoKey(k)
    local today = internal.dayKey()
    local c = internal.ago
    if not c or c.day ~= today then
        c = {day = today, lt = os.date('*t', os.time()), list = {}}
        internal.ago = c
    end
    local e = c.list[k]
    if not e then
        local ts = os.time({year = c.lt.year, month = c.lt.month, day = c.lt.day - k, hour = 12})
        e = {key = internal.dayKey(ts), ts = ts}
        c.list[k] = e
    end
    return e.key, e.ts
end

function internal.dayGet(key)
    local t = internal.dayRoll()
    if key == t.key then return t.d end
    local c = internal.dayCache[key]
    local now = os.clock()
    if c and (c.d or now - c.t < 30) then return c.d or nil end
    local d = internal.dayRead(key)
    internal.dayCache[key] = {d = d or false, t = now}
    return d
end

function internal.wipeDays()
    for k = 0, 400 do
        local key = internal.agoKey(k)
        os.remove(internal.dayPath(key))
        os.remove(DATA_DIR .. '/' .. key)
    end
    internal.today, internal.dayCache, internal.pc = nil, {}, nil
    internal.dayRoll()
end

function internal.periodData(mode)
    local now = os.clock()
    local todayKey = internal.dayKey()
    local pc = internal.pc
    if pc and pc.mode == mode and pc.day == todayKey and now - pc.t < 1 then return pc end

    local days = 0
    for _, o in ipairs(internal.PERIODS) do if o[1] == mode then days = o[3] end end
    local M = {mode = mode, day = todayKey, t = now, unit = 'day'}
    local function newAgg() return {money = 0, carts = 0, time = 0, items = {}} end
    local function addDay(agg, d)
        agg.money = agg.money + d.money
        agg.carts = agg.carts + d.carts
        agg.time = agg.time + d.time
        for name, c in pairs(d.items) do agg.items[name] = (agg.items[name] or 0) + c end
    end
    local tdy = internal.dayRoll().d
    local live = 0
    if running then live = math.max(0, now - (internal.tickAt or now)) end

    M.activeDays = 0
    if days == 0 then
        local tot = stats.total
        M.agg = {money = tot.money or 0, carts = tot.carts or 0, items = tot.items or {},
            time = (tot.time or 0) + (running and (os.time() - stats.session.start) or 0)}
    else
        M.agg, M.prev = newAgg(), newAgg()
        for k = 0, days - 1 do
            local d = internal.dayGet((internal.agoKey(k)))
            if d then
                addDay(M.agg, d)
                if d.money > 0 or d.carts > 0 then M.activeDays = M.activeDays + 1 end
            end
        end
        for k = days, days * 2 - 1 do
            local d = internal.dayGet((internal.agoKey(k)))
            if d then addDay(M.prev, d) end
        end
        M.agg.time = M.agg.time + live
    end

    local vals, labels, full, infos = {}, {}, {}, {}
    local function push(v, lab, fl, info)
        vals[#vals + 1] = v
        labels[#vals] = lab
        full[#vals] = fl
        infos[#vals] = info
    end
    local function dayBucket(k)
        local key, ts = internal.agoKey(k)
        local d = internal.dayGet(key)
        local wd = internal.RU_WD[(tonumber(os.date('%w', ts)) or 0) + 1]
        local short = os.date('%d.%m', ts)
        push(d and d.money or 0, short, wd .. ' ' .. short,
            d and (('%d тел.  ·  %s'):format(d.carts, internal.hms(d.time))) or 'нет данных')
    end

    if days == 1 then
        M.unit = 'hour'
        local cur = tonumber(os.date('%H')) or 0
        local first
        for h = 0, 23 do
            local e = tdy.hours[h]
            if e and (e.money > 0 or e.carts > 0) then first = h; break end
        end
        if first then
            local a = math.max(0, math.min(first, cur - 5))
            local b = math.min(23, math.max(cur, a + 5))
            for h = a, b do
                local e = tdy.hours[h]
                push(e and e.money or 0, ('%02d:00'):format(h), ('%02d:00 - %02d:00'):format(h, (h + 1) % 24),
                    e and (('%d тел.  ·  %s'):format(e.carts, internal.hms(e.time))) or 'нет данных')
            end
            M.nlive = cur - a + 1
        end
    elseif days > 1 then
        for k = days - 1, 0, -1 do dayBucket(k) end
    else
        local firstK
        for k = 119, 0, -1 do
            local d = internal.dayGet((internal.agoKey(k)))
            if d and (d.money > 0 or d.carts > 0) then
                M.activeDays = M.activeDays + 1
                if not firstK then firstK = k end
            end
        end
        if firstK then
            local k0 = math.min(math.max(firstK, 6), 59)
            for k = k0, 0, -1 do dayBucket(k) end
        else
            M.unit = 'session'
            local hist = stats.total.hist or {}
            for i = math.max(1, #hist - 11), #hist do
                local hh = hist[i]
                local ts = hh.t or os.time()
                push(tonumber(hh.money) or 0, os.date('%d.%m', ts), os.date('%d.%m %H:%M', ts),
                    'сессия  ·  ' .. internal.hms(tonumber(hh.time) or 0))
            end
            if running then
                local liveMoney = (stats.session.money or 0) - (internal.runMoney0 or 0)
                if liveMoney > 0 then push(liveMoney, 'сейчас', 'текущая сессия', 'идёт сейчас') end
            end
        end
    end
    M.values, M.labels, M.full, M.infos = vals, labels, full, infos

    local bi, bv = nil, 0
    for i, v in ipairs(vals) do if v > bv then bi, bv = i, v end end
    if bi then M.best = {i = bi, v = bv, label = labels[bi], full = full[bi]} end

    M.recent = {}
    local hist = stats.total.hist or {}
    for i = #hist, math.max(1, #hist - 4), -1 do M.recent[#M.recent + 1] = hist[i] end

    internal.pc = M
    return M
end


--касания
local memory = require('memory')
local touch_ok, touch_raw
do
    local bit = require('bit')
    local TOUCH_PAT = {0xA9BB7BFD, 0xF9000BF9, 0xA9025FF8, 0xA90357F6, 0xA9044FF4, 0x910003FD, 0x52800308,
                       false, false, 0x2A0303F3, 0x9BA82418, 0x2A0203F4, 0x2A0103F6}
    local function rd16(a) return ffi.cast('uint16_t*', a)[0] end
    local function rd32(a) return ffi.cast('uint32_t*', a)[0] end
    local function rd64(a) return tonumber(ffi.cast('uint64_t*', a)[0]) end
    local function sx(v, n) if v >= 2 ^ (n - 1) then return v - 2 ^ n end return v end
    local function readMaps()
        local f = io.open('/proc/self/maps', 'r')
        if not f then return {} end
        local t = {}
        for line in f:lines() do
            local s, e, perms, off = line:match('^(%x+)%-(%x+)%s+(%S+)%s+(%x+)')
            if s and (line:find('libag-client.so', 1, true) or line:find('libGTASA.so', 1, true)) then
                t[#t + 1] = {s = tonumber(s, 16), e = tonumber(e, 16), x = perms:sub(3, 3) == 'x', off = tonumber(off, 16)}
            end
        end
        f:close()
        return t
    end
    local function elfSym(base, name)
        local phoff, phnum, phent = rd64(base + 0x20), rd16(base + 0x38), rd16(base + 0x36)
        local dyn
        for i = 0, phnum - 1 do
            local o = base + phoff + i * phent
            if rd32(o) == 2 then dyn = base + rd64(o + 16) break end
        end
        if not dyn then return nil end
        local symtab, strtab, gh
        local o = dyn
        while true do
            local tag, val = rd64(o), rd64(o + 8)
            if tag == 0 then break end
            if val < base then val = val + base end
            if tag == 6 then symtab = val elseif tag == 5 then strtab = val elseif tag == 0x6ffffef5 then gh = val end
            o = o + 16
        end
        if not (symtab and strtab and gh) then return nil end
        local nb, symoff, bloom = rd32(gh), rd32(gh + 4), rd32(gh + 8)
        local bk = gh + 16 + bloom * 8
        local ch = bk + nb * 4
        local n = 0
        for i = 0, nb - 1 do
            local v = rd32(bk + i * 4)
            if v > n then n = v end
        end
        if n < symoff then return nil end
        while bit.band(rd32(ch + (n - symoff) * 4), 1) == 0 and n < 200000 do n = n + 1 end
        n = n + 1
        for i = 0, n - 1 do
            local so = symtab + i * 24
            local nm = rd32(so)
            if nm ~= 0 and ffi.string(ffi.cast('char*', strtab + nm)) == name then
                return base + rd64(so + 8)
            end
        end
    end
    local function followTouch(fn)
        local adr
        for i = 0, 79 do
            local w = rd32(fn + i * 4)
            if bit.band(w, 0x9F000000) == bit.tobit(0x10000000) then
                local imm = bit.bor(bit.lshift(bit.band(bit.rshift(w, 5), 0x7FFFF), 2), bit.band(bit.rshift(w, 29), 3))
                adr = fn + i * 4 + sx(imm, 21)
                break
            end
        end
        if not adr then return nil end
        for _ = 1, 4 do
            local w = rd32(adr)
            if bit.band(w, 0xFC000000) == bit.tobit(0x14000000) then adr = adr + sx(bit.band(w, 0x3FFFFFF), 26) * 4 else break end
        end
        for i = 1, 299 do
            local w = rd32(adr + i * 4)
            if bit.band(w, 0xFC000000) == bit.tobit(0x94000000) then
                local p = bit.band(rd32(adr + i * 4 - 4), 0xFFFFFC1F)
                if p == 0x1E380003 or p == 0x1E780003 then
                    return adr + i * 4 + sx(bit.band(w, 0x3FFFFFF), 26) * 4
                end
            end
        end
    end
    local function isPrologue(a)
        return bit.band(rd32(a), 0xFFC07FFF) == bit.tobit(0xA9807BFD)
    end
    local function scanPattern(maps)
        for _, m in ipairs(maps) do
            if m.x then
                local p = m.s
                while p + #TOUCH_PAT * 4 <= m.e do
                    if rd32(p) == TOUCH_PAT[1] then
                        local ok = true
                        for i = 2, #TOUCH_PAT do
                            local v = TOUCH_PAT[i]
                            if v and rd32(p + (i - 1) * 4) ~= v then ok = false break end
                        end
                        if ok then return p end
                    end
                    p = p + 4
                end
            end
        end
    end
    local function findTouch()
        local maps = readMaps()
        for _, m in ipairs(maps) do
            if m.off == 0 then
                local ok, t = pcall(function()
                    if rd32(m.s) ~= 0x464C457F then return nil end
                    local fn = elfSym(m.s, 'Java_com_arizona_game_natives_MultiTouch')
                    return fn and followTouch(fn)
                end)
                if ok and t and isPrologue(t) then return t end
            end
        end
        return scanPattern(maps)
    end
    local touch_addr = select(2, pcall(findTouch))
    touch_ok = type(touch_addr) == 'number'
    touch_raw = touch_ok and ffi.cast('void(*)(int, int, int, int)', touch_addr) or nil
end
local touch_warned = false
touch = function(a, b, c, dd)
    if not touch_ok then
        if not touch_warned then
            touch_warned = true
            pcall(sampAddChatMessage, '{FF5555}[SawBot] touch function not found (game updated) - input disabled', -1)
        end
        return
    end
    touch_raw(a, b, c, dd)
end
SW, SH = getScreenResolution()
JOY_X, JOY_Y, JOY_R = math.floor(SW * 0.156), math.floor(SH * 0.78), math.floor(SH * 0.133)

JOY_FINGER, RUN_FINGER = 0, 1
RUN_X, RUN_Y = math.floor(SW * 0.94), math.floor(SH * 0.85)
--джойстик
local sprinting = false
local joyTouchActive, runTouchActive = false, false
local joyTouchX, joyTouchY = JOY_X, JOY_Y

local function movementTouch(action, x, y)
    if x ~= nil then joyTouchX = x end
    if y ~= nil then joyTouchY = y end
    touch(JOY_FINGER, action, joyTouchX, joyTouchY)
    joyTouchActive = action ~= 1
end

local function runTouch(action)
    touch(RUN_FINGER, action, RUN_X, RUN_Y)
    runTouchActive = action ~= 1
    internal.lastRunTouchAt = os.clock()
end

local function releaseBotTouches(force)
    if force or joyTouchActive then movementTouch(1) end
    if force or runTouchActive then runTouch(1) end
    sprinting = false
end

local function sprint(on)
    if on ~= sprinting then
        sprinting = on
        runTouch(on and 0 or 1)
    elseif on and runTouchActive and os.clock() - (internal.lastRunTouchAt or 0) > 0.4 then

        runTouch(2)
    end
end

local function jump()
    if st.cart then return end
    if st.chopping and st.target then
        local px, py = getCharCoordinates(PLAYER_PED)
        if getDistanceBetweenCoords2d(px, py, st.target.cx, st.target.cy) < 8 then return end
    end
    local was = sprinting
    sprint(false)
    for _ = 1, 2 do
        runTouch(0); wait(50 + math.random(30))
        runTouch(1); wait(60 + math.random(40))
    end
    if was and running then
        wait(250)
        if running then sprint(true) end
    end
end


--камера
function internal.camHeadingRaw()
    local okC, cx, cy, cz = pcall(getActiveCameraCoordinates)
    local okP, px, py, pz = pcall(getActiveCameraPointAt)
    if not okC or not okP or type(cx) ~= 'number' or type(cy) ~= 'number'
        or type(cz) ~= 'number' or type(px) ~= 'number' or type(py) ~= 'number'
        or type(pz) ~= 'number' then
        return nil
    end

    local dx, dy, dz = px - cx, py - cy, pz - cz
    local horizontal = math.sqrt(dx * dx + dy * dy)
    local full = math.sqrt(horizontal * horizontal + dz * dz)
    if full < 0.001 or horizontal < 0.001 or horizontal / full < 0.12 then
        return nil
    end

    local heading = getHeadingFromVector2d(dx, dy)
    if type(heading) ~= 'number' or heading ~= heading then return nil end
    return heading
end

local function camHeading()
    local heading = internal.camHeadingRaw()
    if heading ~= nil then
        st.lastCamHeading = heading
        return heading
    end
    return st.lastCamHeading or 0
end

local function stick(heading, r)

    local R_MAX, RAMP_T = 1.0, 11.11
    local k, now = r or 1, os.clock()
    if not st.stickFrom or now - (st.stickAt or 0) > 0.5 then st.stickFrom = now end
    st.stickAt = now

    if k >= 1 then k = k * (1 + (R_MAX - 1) * math.min(1, (now - st.stickFrom) / RAMP_T)) end
    local a, R = math.rad(heading - (camHeading() + (st.camFix or 0))), JOY_R * k
    local sa, ca = R * math.sin(a), R * math.cos(a)

    local t = 1
    if sa > 0 and sa > JOY_X - 1 then t = math.min(t, (JOY_X - 1) / sa) end
    if sa < 0 and -sa > SW - 1 - JOY_X then t = math.min(t, (SW - 1 - JOY_X) / -sa) end
    if ca > 0 and ca > JOY_Y - 1 then t = math.min(t, (JOY_Y - 1) / ca) end
    if ca < 0 and -ca > SH - 1 - JOY_Y then t = math.min(t, (SH - 1 - JOY_Y) / -ca) end
    movementTouch(2, JOY_X - math.floor(sa * t), JOY_Y - math.floor(ca * t))
end


--координаты
local function pos() local x, y, z = getCharCoordinates(PLAYER_PED); return x, y, z end
local function dist2(x, y) local px, py = pos(); return math.sqrt((x - px) ^ 2 + (y - py) ^ 2) end

local noise = {h = 0, th = 0, next = 0}
local function humanize()
    local now = os.clock()
    if now >= noise.next then
        noise.th = (math.random() - 0.5) * 6
        noise.next = now + 0.6 + math.random() * 1.2
    end
    noise.h = noise.h + (noise.th - noise.h) * 0.05
    return noise.h
end

local CELL = 1.5
local edgeCache, edgeCacheAt = {}, 0

local function groundZ(x, y, z) return getGroundZFor3dCoord(x, y, (z or 80) + 1.2) end

local function clear(ax, ay, az, bx, by, bz)
    for _, h in ipairs({0.6, 1.3}) do
        if not isLineOfSightClear(ax, ay, az + h, bx, by, bz + h, true, false, false, true, false) then return false end
    end
    local d = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    local n, pz = math.max(1, math.floor(d)), az
    for i = 1, n do
        local z = groundZ(ax + (bx - ax) * i / n, ay + (by - ay) * i / n, pz)
        if math.abs(z - pz) > 0.9 then return false end
        pz = z
    end
    return true
end

--маршрут
local function findPath(sx, sy, sz, tx, ty, tz)
    if os.clock() - edgeCacheAt > 300 then edgeCache, edgeCacheAt = {}, os.clock() end
    local minX = math.floor((math.min(sx, tx) - 15) / CELL) * CELL
    local minY = math.floor((math.min(sy, ty) - 15) / CELL) * CELL
    local W = math.floor((math.max(sx, tx) + 15 - minX) / CELL) + 1
    local H = math.floor((math.max(sy, ty) + 15 - minY) / CELL) + 1
    local function key(i, j) return j * W + i end
    local function center(i, j) return minX + i * CELL, minY + j * CELL end
    local si, sj = math.floor((sx - minX) / CELL + 0.5), math.floor((sy - minY) / CELL + 0.5)
    local ti, tj = math.floor((tx - minX) / CELL + 0.5), math.floor((ty - minY) / CELL + 0.5)
    local zOf, g, came, open, closed = {}, {}, {}, {}, {}
    local function cz(i, j, refz)
        local k = key(i, j)
        if not zOf[k] then local x, y = center(i, j); zOf[k] = groundZ(x, y, refz or sz) end
        return zOf[k]
    end
    local function h(i, j) return math.sqrt((i - ti) ^ 2 + (j - tj) ^ 2) end
    local sk = key(si, sj)
    g[sk], open[sk] = 0, h(si, sj)
    local iter = 0
    while true do
        local bk, bf = nil, math.huge
        for k, f in pairs(open) do if f < bf then bk, bf = k, f end end
        if not bk then dbg(('path: open empty after %d, start z=%.1f'):format(iter, cz(si, sj))); return nil end
        local bi, bj = bk % W, math.floor(bk / W)
        if bi == ti and bj == tj or h(bi, bj) < 1.0 then
            local path, k = {}, bk
            while k do table.insert(path, 1, {center(k % W, math.floor(k / W))}); k = came[k] end
            return path
        end
        open[bk], closed[bk] = nil, true
        local ax, ay = center(bi, bj)
        local az = cz(bi, bj)
        for dj = -1, 1 do for di = -1, 1 do
            local ni, nj = bi + di, bj + dj
            local nk = key(ni, nj)
            if (di ~= 0 or dj ~= 0) and ni >= 0 and nj >= 0 and ni < W and nj < H and not closed[nk] then
                local bx, by = center(ni, nj)
                local bz = cz(ni, nj, az)
                local ek = ('%.1f,%.1f,%.1f,%.1f'):format(math.min(ax, bx), math.min(ay, by), math.max(ax, bx), math.max(ay, by)) .. (di * dj < 0 and 'x' or '')
                if edgeCache[ek] == nil then edgeCache[ek] = clear(ax, ay, az, bx, by, bz) end
                if edgeCache[ek] then
                    local ng = g[bk] + math.sqrt(di * di + dj * dj)
                    if not g[nk] or ng < g[nk] then g[nk], came[nk], open[nk] = ng, bk, ng + h(ni, nj) end
                end
            end
        end end
        iter = iter + 1
        if iter % 60 == 0 then wait(0) end
        if iter > 4000 then dbg('path: iteration limit'); return nil end
    end
end

local function smooth(path, sx, sy, sz, tx, ty)
    table.insert(path, 1, {sx, sy}); path[#path] = {tx, ty}
    local out, i = {}, 1
    while i < #path do
        local j = #path
        while j > i + 1 do
            local ax, ay = path[i][1], path[i][2]
            local bx, by = path[j][1], path[j][2]
            if clear(ax, ay, groundZ(ax, ay, sz), bx, by, groundZ(bx, by, sz)) then break end
            j = j - 1
        end
        table.insert(out, path[j]); i = j
    end
    for k = 1, #out - 1 do
        local p = out[k]
        local ox, oy = p[1] + (math.random() - 0.5) * 1.4, p[2] + (math.random() - 0.5) * 1.4
        local prev = out[k - 1] or {sx, sy}
        if clear(prev[1], prev[2], groundZ(prev[1], prev[2], sz), ox, oy, groundZ(ox, oy, sz)) then out[k] = {ox, oy} end
    end
    return out
end

local nav
local DIRS = {{1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1}}
local PEN = {[0] = 2.5, 1.2, 0.5, 0.15}
local trunks = {}
local treeLabels, markTrunks
local lumberBtn

--карта
local function navLoad()
    local f = io.open(SCRIPT_CONFIG_DIR .. '/navgrid.txt', 'r')
    if not f then f = io.open(getWorkingDirectory() .. '/navgrid.txt', 'r') end
    if not f then dbg('navgrid.txt нет, хожу по лучам'); return end
    local mx, my, w, h, c = f:read('*l'):match('(%S+) (%S+) (%S+) (%S+) (%S+)')
    nav = {minX = tonumber(mx), minY = tonumber(my), W = tonumber(w), H = tonumber(h), cell = tonumber(c), mask = {}, clr = {}}
    for j = 0, nav.H - 1 do
        local line = f:read('*l') or ''
        for i = 0, nav.W - 1 do
            local hx = line:sub(i * 2 + 1, i * 2 + 2)
            if hx ~= '..' and hx ~= '' then nav.mask[j * nav.W + i] = tonumber(hx, 16) end
        end
        if j % 40 == 0 then wait(0) end
    end
    f:close()
    local q, head = {}, 1
    for k, m in pairs(nav.mask) do if m ~= 255 then nav.clr[k] = 0; q[#q + 1] = k end end
    while head <= #q do
        local k = q[head]; head = head + 1
        local d = nav.clr[k]
        if d < 3 then
            local i, j = k % nav.W, math.floor(k / nav.W)
            for _, dd in ipairs(DIRS) do
                local nk = (j + dd[2]) * nav.W + i + dd[1]
                if nav.mask[nk] and not nav.clr[nk] then nav.clr[nk] = d + 1; q[#q + 1] = nk end
            end
        end
        if head % 3000 == 0 then wait(0) end
    end
    dbg('navgrid loaded')
end

local function navCell(x, y) return math.floor((x - nav.minX) / nav.cell + 0.5), math.floor((y - nav.minY) / nav.cell + 0.5) end
local function navPos(k) return nav.minX + (k % nav.W) * nav.cell, nav.minY + math.floor(k / nav.W) * nav.cell end


internal.navStepAllowed = function(i, j, di, dj, allowTarget)
    if (di == 0 and dj == 0) or math.abs(di) > 1 or math.abs(dj) > 1 then return false end
    local W, H = nav.W, nav.H
    local ni, nj = i + di, j + dj
    if i < 0 or j < 0 or i >= W or j >= H or ni < 0 or nj < 0 or ni >= W or nj >= H then return false end
    local k, nk = j * W + i, nj * W + ni
    local m1, m2 = nav.mask[k], nav.mask[nk]
    if m1 == nil or m2 == nil or m1 == 0 or m2 == 0 then return false end
    if trunks[k] == true or (trunks[nk] == true and not allowTarget) then return false end
    local dir
    for d, dd in ipairs(DIRS) do
        if dd[1] == di and dd[2] == dj then dir = d; break end
    end
    if not dir then return false end
    local rev = ((dir + 3) % 8) + 1
    if bit.band(m1, bit.lshift(1, dir - 1)) == 0 or bit.band(m2, bit.lshift(1, rev - 1)) == 0 then return false end
    if di ~= 0 and dj ~= 0 then
        local kx, ky = j * W + ni, nj * W + i
        local mx, my = nav.mask[kx], nav.mask[ky]
        if mx == nil or my == nil or mx == 0 or my == 0 or trunks[kx] == true or trunks[ky] == true then return false end
        local dxDir, dyDir = (di > 0 and 1 or 5), (dj > 0 and 3 or 7)
        local function card(a, am, b, bm, d)
            local r = ((d + 3) % 8) + 1
            return am ~= nil and bm ~= nil and am ~= 0 and bm ~= 0
                and trunks[a] ~= true and trunks[b] ~= true
                and bit.band(am, bit.lshift(1, d - 1)) ~= 0
                and bit.band(bm, bit.lshift(1, r - 1)) ~= 0
        end
        local viaX = card(k, m1, kx, mx, dxDir) and card(kx, mx, nk, m2, dyDir)
        local viaY = card(k, m1, ky, my, dyDir) and card(ky, my, nk, m2, dxDir)
        if not viaX and not viaY then return false end
    end
    return true
end

local function gridPath(sx, sy, tx, ty)
    if not nav then return end
    local W, H = nav.W, nav.H
    local si, sj = navCell(sx, sy)
    local ti, tj = navCell(tx, ty)
    local _, _, refz = pos()
    local function snap(i, j, goalX, goalY)
        local bestI, bestJ, bestD
        for dj = -2, 2 do for di = -2, 2 do
            local ci, cj = i + di, j + dj
            if ci >= 0 and cj >= 0 and ci < W and cj < H then
                local ck = cj * W + ci
                local cm = nav.mask[ck]
                if cm ~= nil and cm ~= 0 and trunks[ck] ~= true then
                    local wx, wy = navPos(ck)
                    local ok = true
                    if goalX then
                        local wz = groundZ(wx, wy, refz)
                        local gz = groundZ(goalX, goalY, wz)

                        ok = clear(wx, wy, wz, goalX, goalY, gz)
                    end
                    local dd = di * di + dj * dj
                    if ok and (not bestD or dd < bestD) then bestI, bestJ, bestD = ci, cj, dd end
                end
            end
        end end
        return bestI, bestJ
    end
    si, sj = snap(si, sj)
    ti, tj = snap(ti, tj, tx, ty)
    if not si or not ti then return end
    local sk, tk = sj * W + si, tj * W + ti
    local hk, hf, hn = {}, {}, 0
    local function push(k, f)
        hn = hn + 1; local i = hn
        while i > 1 do
            local p = math.floor(i / 2)
            if hf[p] <= f then break end
            hk[i], hf[i] = hk[p], hf[p]; i = p
        end
        hk[i], hf[i] = k, f
    end
    local function pop()
        local top = hk[1]
        local k, f = hk[hn], hf[hn]; hn = hn - 1
        local i = 1
        while true do
            local c = i * 2
            if c > hn then break end
            if c < hn and hf[c + 1] < hf[c] then c = c + 1 end
            if hf[c] >= f then break end
            hk[i], hf[i] = hk[c], hf[c]; i = c
        end
        if hn > 0 then hk[i], hf[i] = k, f end
        return top
    end
    local g, came, done = {[sk] = 0}, {}, {}
    local function h(k) return math.sqrt((k % W - ti) ^ 2 + (math.floor(k / W) - tj) ^ 2) end
    push(sk, h(sk))
    local iter = 0
    while hn > 0 do
        local k = pop()
        if k == tk then
            local path = {}
            while k do table.insert(path, 1, {navPos(k)}); k = came[k] end
            return path
        end
        if not done[k] then
            done[k] = true
            local i, j = k % W, math.floor(k / W)
            for d, dd in ipairs(DIRS) do
                local ni, nj = i + dd[1], j + dd[2]
                if ni >= 0 and nj >= 0 and ni < W and nj < H then
                    local nk = nj * W + ni
                    local tr = trunks[nk]
                    if not done[nk] and internal.navStepAllowed(i, j, dd[1], dd[2], nk == tk) then
                        local step = (dd[1] ~= 0 and dd[2] ~= 0) and 1.414 or 1
                        local ng = g[k] + step * (1 + (PEN[nav.clr[nk] or 9] or 0) + (type(tr) == 'number' and tr or 0))
                        if not g[nk] or ng < g[nk] then g[nk], came[nk] = ng, k; push(nk, ng + h(nk)) end
                    end
                end
            end
        end
        iter = iter + 1
        if iter % 2000 == 0 then wait(0) end
        if iter > 60000 then return end
    end
end

local function gridClear(ax, ay, bx, by)
    local d = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    local n = math.max(1, math.ceil(d / math.max(0.25, nav.cell * 0.4)))
    local prevI, prevJ
    for s = 0, n do
        local px, py = ax + (bx - ax) * s / n, ay + (by - ay) * s / n
        local i, j = navCell(px, py)
        if i < 0 or j < 0 or i >= nav.W or j >= nav.H then return false end
        local k = j * nav.W + i
        if nav.mask[k] == nil or nav.mask[k] == 0 or trunks[k] == true or (nav.clr[k] or 9) < 1 then return false end
        if prevI and (i ~= prevI or j ~= prevJ) then
            if not internal.navStepAllowed(prevI, prevJ, i - prevI, j - prevJ, false) then return false end
        end
        prevI, prevJ = i, j
        for _, c in ipairs(st.trunkCenters or {}) do
            if (px - c[1]) ^ 2 + (py - c[2]) ^ 2 < 2.6 * 2.6 then return false end
        end
    end
    return true
end

local function gridSmooth(path, sx, sy, tx, ty)


    local ex, ey = path[#path][1], path[#path][2]
    local ei, ej = navCell(ex, ey)
    local ti, tj = navCell(tx, ty)
    table.insert(path, 1, {sx, sy})
    if ei == ti and ej == tj and gridClear(ex, ey, tx, ty) then
        path[#path] = {tx, ty}
    elseif clear(ex, ey, groundZ(ex, ey, 80), tx, ty, groundZ(tx, ty, 80)) then


        path[#path + 1] = {tx, ty}
    end
    local out, i = {}, 1
    while i < #path do
        local j = #path
        while j > i + 1 and not gridClear(path[i][1], path[i][2], path[j][1], path[j][2]) do j = j - 1 end
        table.insert(out, path[j]); i = j
    end
    return out
end


--калибровка
function internal.wallClock()
    if getGameTimer then
        local ok, ms = pcall(getGameTimer)
        if ok and type(ms) == 'number' then return ms / 1000 end
    end
    return os.clock()
end

function internal.angDiff(a, b) return (a - b + 540) % 360 - 180 end


function SawPrepareCamera()
    local t0 = internal.wallClock()
    while running and internal.wallClock() - t0 < 20 do
        local ok, spawned = pcall(sampIsLocalPlayerSpawned)
        if (not ok or spawned) and not st.frozen then break end
        wait(200)
    end
    if not running then return false end

    if not st.camPrepared then
        movementTouch(1)
        wait(100)
        pcall(setCameraBehindPlayer)
        local stable, last, tc = 0, nil, internal.wallClock()
        while running and stable < 5 and internal.wallClock() - tc < 4.0 do
            wait(100)
            local c = internal.camHeadingRaw()
            if c ~= nil then
                if last ~= nil and math.abs(internal.angDiff(c, last)) < 0.8 then
                    stable = stable + 1
                else
                    stable = 0
                end
                last = c
            else
                stable, last = 0, nil
            end
        end
        if not running then return false end
        if stable < 5 then
            st.camPrepared = false
            msg('\xca\xe0\xec\xe5\xf0\xe0 \xe5\xf9\xb8 \xed\xe5 \xf1\xf2\xe0\xe1\xe8\xeb\xe8\xe7\xe8\xf0\xee\xe2\xe0\xeb\xe0\xf1\xfc \xef\xee\xf1\xeb\xe5 \xf1\xec\xe5\xed\xfb \xf1\xee\xf1\xf2\xee\xff\xed\xe8\xff. \xcf\xee\xe2\xf2\xee\xf0\xfe \xef\xf0\xee\xe2\xe5\xf0\xea\xf3 \xef\xe5\xf0\xe5\xe4 \xf1\xeb\xe5\xe4\xf3\xfe\xf9\xe8\xec \xec\xe0\xf0\xf8\xf0\xf3\xf2\xee\xec.')
            return false
        end
        st.camPrepared = true
        st.lastCamHeading = last
        movementTouch(0, JOY_X, JOY_Y)
        wait(80)
    end
    return true
end

internal.buildRouteSegment = function(sx, sy, sz, tx, ty, tz)
    local raw = nav and gridPath(sx, sy, tx, ty) or nil
    if raw then return gridSmooth(raw, sx, sy, tx, ty) end
    raw = clear(sx, sy, sz - 1, tx, ty, tz) and {{tx, ty}} or findPath(sx, sy, sz - 1, tx, ty, tz)
    if not raw then
        dbg(('no safe route segment to %.1f %.1f; refusing direct path'):format(tx, ty))
        return nil
    end
    return #raw > 1 and smooth(raw, sx, sy, sz - 1, tx, ty) or raw
end

--движение
local function followTo(tx, ty, accept, timeout, fixedPath, targetZ, viaPoint)
    local sx, sy, sz = pos()
    local tz = tonumber(targetZ) or groundZ(tx, ty, sz)
    st.dest = {x = tx, y = ty, gz = tz}
    local path
    local viaPassed = false
    if fixedPath then
        path = fixedPath
    elseif viaPoint then
        if nav then markTrunks(treeLabels()) end
        local firstPath = internal.buildRouteSegment(sx, sy, sz, viaPoint.x, viaPoint.y, viaPoint.z)
        if not firstPath then
            st.dest = nil
            dbg(('no safe route to pass-through point %.1f %.1f'):format(viaPoint.x, viaPoint.y))
            return false
        end
        local secondPath = internal.buildRouteSegment(viaPoint.x, viaPoint.y, viaPoint.z or tz, tx, ty, tz)
        if not secondPath then
            st.dest = nil
            dbg(('no safe route from pass-through point to %.1f %.1f'):format(tx, ty))
            return false
        end
        path = {}
        for _, point in ipairs(firstPath) do path[#path + 1] = point end
        st.passThroughIndex = #path
        for _, point in ipairs(secondPath) do
            local lastPoint = path[#path]
            if not lastPoint or (lastPoint[1] - point[1]) ^ 2 + (lastPoint[2] - point[2]) ^ 2 > 0.04 then
                path[#path + 1] = point
            end
        end
        dbg(('pass-through route via %.2f %.2f to %.2f %.2f'):format(viaPoint.x, viaPoint.y, tx, ty))
    else
        st.passThroughIndex = nil
        if nav then markTrunks(treeLabels()) end
        local t0p = os.clock()
        local raw = nav and gridPath(sx, sy, tx, ty) or nil
        if raw then
            path = gridSmooth(raw, sx, sy, tx, ty)
        else
            raw = clear(sx, sy, sz - 1, tx, ty, tz) and {{tx, ty}} or findPath(sx, sy, sz - 1, tx, ty, tz)
            if not raw then
                dbg(('no safe route to %.1f %.1f; refusing direct path'):format(tx, ty))
                st.dest = nil
                return false
            end
            path = #raw > 1 and smooth(raw, sx, sy, sz - 1, tx, ty) or raw
        end
        dbg(('path to %.1f %.1f: %s, %d pts, %.0f ms'):format(tx, ty, raw and 'grid/rays' or 'rays', raw and #raw or 0, (os.clock() - t0p) * 1000))
    end
    st.path = path
    st.heading, st.lastSteer, st.routeStart = nil, nil, os.clock()
    st.headingSeed = math.random() * 6.28


    if not joyTouchActive then movementTouch(0, JOY_X, JOY_Y) end
    st.stickAt = 0
    wait(30)
    if running and not st.cart and not st.camPrepared then
        local camReady = SawPrepareCamera()
        if camReady == false then
            movementTouch(1)
            sprint(false)
            st.path, st.dest = nil, nil
            return false
        end
    end
    local t0, idx, lastX, lastY, stuckT, side, result = os.clock(), 1, nil, nil, os.clock(), 1, nil
    local lastRouteDbg = os.clock()
    while running and result == nil do
        if st.abortLooseCartWalk and st.takingLooseCartId then
            movementTouch(1)
            sprint(false)
            st.path, st.dest, st.passThroughIndex = nil, nil, nil
            return false, 'cart_stolen'
        end
        if st.treeSeeking and internal.tryTreeTargetSwitch then
            local targetState = internal.tryTreeTargetSwitch()
            if targetState == 'switched' then
                st.treeViaPointPassed = true
                st.path, st.dest, st.passThroughIndex = nil, nil, nil

                return false, 'tree_switched'
            elseif targetState == 'blocked' then
                st.treeViaPointPassed = viaPassed or st.treeViaPointPassed
                movementTouch(1)
                sprint(false)
                st.path, st.dest, st.passThroughIndex = nil, nil, nil
                return false, 'no_free_tree'
            end
        end
        if os.clock() - lastRouteDbg >= 10 then
            dbg(('route progress: waypoint %d/%d'):format(idx, #path))
            lastRouteDbg = os.clock()
        end
        local x, y = pos()
        local last = idx == #path
        while not last do
            local wp0 = path[idx]
            local dd = math.sqrt((wp0[1] - x) ^ 2 + (wp0[2] - y) ^ 2)

            local arriveRadius = (st.passThroughIndex == idx) and 0.65 or 1.0
            if dd > arriveRadius then break end
            if st.passThroughIndex == idx then
                viaPassed = true
                st.treeViaPointPassed = true
                st.passThroughIndex = nil
            end
            idx = idx + 1
            last = idx == #path
        end
        local wp = path[idx]
        st.pathIdx = idx
        local dx, dy = wp[1] - x, wp[2] - y
        local d = math.sqrt(dx * dx + dy * dy)
        if not last and idx < #path then

        end
        if (last and d <= accept) or (last and st.chopping and st.window and d < 2.5) then result = true
        elseif os.clock() - t0 > (timeout or 90) then result = false
        else
            local nh = humanize()
            local now = os.clock()
            local weave = (cfg.strafe ~= false and d > 5 and not last) and (math.sin(now * 1.6 + (st.headingSeed or 0)) * 18) or 0
            local want = getHeadingFromVector2d(dx, dy) + (d > 4 and nh or 0) + weave
            local dt = math.min(0.1, now - (st.lastSteer or now))
            st.lastSteer = now
            st.heading = st.heading or want
            local diff = (want - st.heading + 540) % 360 - 180
            local maxStep = (sprinting and 200 or 140) * dt
            st.heading = (st.heading + math.max(-maxStep, math.min(maxStep, diff * 0.25))) % 360
            stick(st.heading)
            if cfg.antiStamina then st.runPause = false
            elseif now >= (st.runToggleAt or 0) then
                st.runPause = not st.runPause and st.runToggleAt ~= nil
                st.runToggleAt = now + (st.runPause and (2 + math.random() * 2) or (25 + math.random() * 20))
            end
            sprint(cfg.sprint and not st.runPause and not (last and d < 1.2))
            st.nextJump = st.nextJump or now + 30 + math.random() * 40
            if cfg.jumps and not st.cart and d > 12 and now >= st.nextJump and now > (st.noJumpUntil or 0)
                and now - st.routeStart > 5 and math.abs(diff) < 10 then
                st.nextJump = now + 45 + math.random() * 55
                jump()
            end
            if not lastX or st.frozen or st.window or math.sqrt((x - lastX) ^ 2 + (y - lastY) ^ 2) > 0.5 then
                lastX, lastY, stuckT = x, y, os.clock()
            end
if os.clock() - stuckT > 1.2 then
                lumberBtn(92)
                if not st.cart and d > 3 and os.clock() > (st.noJumpUntil or 0) then
                    jump()
                    st.noJumpUntil = os.clock() + 1.0
                end

                local baseH = getHeadingFromVector2d(dx, dy)
                st.sidestepMeters = math.max(1, math.min(10, tonumber(cfg.stuckSideMeters) or 3))
                local recoverySide = st.stuckSide or side
                local sideBudgetEnd = os.clock() + 1.0
                local movedAside = false


                for pass = 1, 2 do
                    local sx, sy = pos()
                    local passSeconds = math.min(0.5, 0.2 + st.sidestepMeters * 0.03)
                    local passEnd = math.min(sideBudgetEnd, os.clock() + passSeconds)
                    while running and os.clock() < passEnd do
                        local mx, my = pos()
                        if getDistanceBetweenCoords2d(sx, sy, mx, my) >= st.sidestepMeters then break end
                        stick(baseH + 90 * recoverySide)
                        wait(0)
                    end

                    local nx, ny = pos()
                    if getDistanceBetweenCoords2d(sx, sy, nx, ny) >= 0.2 then
                        movedAside = true
                        break
                    end
                    recoverySide = -recoverySide
                    if os.clock() >= sideBudgetEnd then break end
                end

                st.stuckSide = -recoverySide
                dbg(('route stuck at %.1f %.1f, quick sidestep=%s'):format(x, y, tostring(movedAside)))

                movementTouch(1)
                sprint(false)
                wait(100)
                return followTo(tx, ty, accept, (timeout or 90) - (os.clock() - t0), nil, targetZ, (not viaPassed) and viaPoint or nil)
            end

            wait(0)
        end
    end
    movementTouch(1)
    sprint(false)
    st.path = nil
    st.dest = nil
    st.passThroughIndex = nil
    return result == true
end
local walkTo = followTo

local trunkR = {}
--обход
local function trunkRadius(cx, cy, z, ax, ay)
    local key = ('%.0f,%.0f'):format(cx, cy)
    if trunkR[key] then return trunkR[key] end
    local dx, dy = ax - cx, ay - cy
    local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
    dx, dy = dx / len, dy / len
    local ox, oy, lo, hi = cx + dx * 8, cy + dy * 8, 0.3, 6.0
    for _ = 1, 8 do
        local mid = (lo + hi) / 2
        if isLineOfSightClear(ox, oy, z + 1.0, cx + dx * mid, cy + dy * mid, z + 1.0, true, false, false, true, false)
        then hi = mid else lo = mid end
    end
    trunkR[key] = hi
    return hi
end

local function orbitTo(tx, ty, cx, cy)
    local x, y, z = pos()

    local r = math.max(3.4, trunkRadius(cx, cy, z - 1, tx, ty) + 1.4)
    local a0, a1 = math.atan2(y - cy, x - cx), math.atan2(ty - cy, tx - cx)
    local d = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
    local steps = math.max(2, math.ceil(math.abs(d) / math.rad(30)))
    local path = {}
    for i = 1, steps - 1 do
        local a = a0 + d * i / steps
        local px, py
        for extra = 0, 1.8, 0.6 do
            px, py = cx + (r + extra) * math.cos(a), cy + (r + extra) * math.sin(a)
            if not nav then break end
            local ci, cj = navCell(px, py)
            local k = cj * nav.W + ci
            if nav.mask[k] and trunks[k] ~= true then break end
        end
        path[#path + 1] = {px, py}
    end
    path[#path + 1] = {tx, ty}
    return followTo(tx, ty, 0.5, 30, path)
end

--взаимодействие
local function sendUI(iface, a, b, str)
    str = str or ''
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220); raknetBitStreamWriteInt8(bs, 63); raknetBitStreamWriteInt8(bs, iface)
    raknetBitStreamWriteInt32(bs, a); raknetBitStreamWriteInt32(bs, b)
    raknetBitStreamWriteInt16(bs, #str)
    if #str > 0 then raknetBitStreamWriteString(bs, str) end
    raknetSendBitStreamEx(bs, 1, 7, 1)
    raknetDeleteBitStream(bs)
end
local function interact() sendUI(8, 7, -1) end
function lumberBtn(id, str) sendUI(IFACE_LUMBER, id, id, str) end

addEventHandler('onReceivePacket', function(id, bs)
    if id ~= 220 then return end
    local rd = raknetBitStreamGetReadOffset(bs)
    raknetBitStreamResetReadPointer(bs)
    raknetBitStreamIgnoreBits(bs, 8)
    if raknetBitStreamReadInt8(bs) == 84 then
        local iface, ev = raknetBitStreamReadInt8(bs) % 256, raknetBitStreamReadInt8(bs) % 256
        local len, flag = raknetBitStreamReadInt16(bs) % 65536, raknetBitStreamReadInt8(bs)
        if iface == 8 and ev == 104 then
            local text = flag == 1 and raknetBitStreamDecodeString(bs, 8192) or raknetBitStreamReadString(bs, len)
            local name = text:match('"name":"(.-)"')
            internal.evLog = (internal.evLog or 0) + 1
            if internal.evLog <= 15 then dbg('cef8/104: running=' .. tostring(running) .. ' ' .. text:sub(1, 240)) end
            if name and running then
                local sign, num = name:match('([%+%-]?):?CASH:([%d%.,]+)')
                if num then
                    if sign ~= '-' then addStat('money', nil, tonumber((num:gsub('[%.,]', ''))) or 0) end
                else
                    local add = tonumber(text:match('"tag":"%+(%d+)"') or '')
                    if add and text:find('"type":"outgoing"', 1, true) then
                        if name:find('[\208\209][\128-\191]') then
                            local okd, dec = pcall(function() return require('encoding').UTF8:decode(name) end)
                            if okd and type(dec) == 'string' and dec ~= '' then name = dec end
                        end
                        addStat('item', name, add)
                    end
                end
            end
        end
        if iface == 55 then
            local text = flag == 1 and raknetBitStreamDecodeString(bs, 8192) or raknetBitStreamReadString(bs, len)
            if ev == 0 and text:find('hotdog', 1, true) then st.hotdogPrice = tonumber(text:match('"price":"(%d+)"')) end
            if ev == 2 then st.satiety, st.foodOpen = tonumber(text:match('"satiety":"(%d+)"')), true end
        end
        if iface == IFACE_LUMBER and (ev == 90 or ev == 91) then
            local text = flag == 1 and raknetBitStreamDecodeString(bs, 8192) or raknetBitStreamReadString(bs, len)
            if ev == 90 then
                st.window = text == '1'
                if st.window and not st.chopping and not st.treeSeeking and not st.target then
                    lua_thread.create(function()
                        wait(200)
                        if st.window and not st.chopping and not st.treeSeeking and not st.target then
                            lumberBtn(92)
                        end
                    end)
                end
            end
            if ev == 91 then
                local n = function(k) return tonumber(text:match('"' .. k .. '":%s*"?(%-?%d+)')) end
                st.game = {start = n('start'), width = n('width'), speed = n('speed'), my = n('isMyState'),
                    cur = n('currentPosition'), stage = n('stage'), total = n('stageTotal')}
                local done = 0
                for p in text:gmatch('"currentPosition":%s*"?(%-?%d+)') do if tonumber(p) ~= -1 then done = done + 1 end end
                if st.game.stage and st.game.stage == st.game.total and done >= 2 then st.holdUntil = os.clock() + 8 end
            end
        end
    end
    raknetBitStreamSetReadOffset(bs, rd)
end)

--события
function sampev.onShowDialog(id, style, title, b1, b2, text)
    if not running then return end
    if id == DLG_TRAILER and st.pendingDlg == 'exit' then
        st.pendingDlg = nil
        lua_thread.create(function() wait(300); sampSendDialogResponse(id, 1, 0, '') end)
        return false
    end
    if st.pendingDlg == 'sat' and text:find('сытость', 1, true) then
        st.pendingDlg = nil
        st.satiety = tonumber(text:match('сытость:%s*{%x+}(%d+)')) or st.satiety
        lua_thread.create(function() wait(200); sampSendDialogResponse(id, 0, 0, '') end)
        return false
    end
    dbg(('dialog %d pending=%s'):format(id, tostring(st.pendingDlg)))
    if id == DLG_SAWMILL and st.pendingDlg == 'rent' then
        st.pendingDlg = nil
        local idx, i = nil, 0
        for line in (text .. '\n'):gmatch('(.-)\n') do
            if line:find('Взять бензопилу', 1, true) then idx = i end
            i = i + 1
        end
        if not idx and text:find('Сдать бензопилу', 1, true) then setSaw(true) end
        dbg('rent idx=' .. tostring(idx) .. ' saw=' .. tostring(st.saw))
        lua_thread.create(function()
            wait(300)
            if idx then sampSendDialogResponse(id, 1, idx, '') else sampSendDialogResponse(id, 0, 0, '') end
        end)
        return false
    end
    aaOnDialog(id, title, text)
end

function sampev.onServerMessage(color, text)
    aaOnChat(text)
    if text:find('Вы арендовали бензопилу', 1, true) then setSaw(true)
    elseif text:find('Вы получили тележку', 1, true) then
        st.cart, st.game = true, nil
        if st.target then st.lastTree = {x = st.target.cx, y = st.target.cy} end
        st.myTree = nil
    elseif text:find('Вы сдали дрова', 1, true) then
        st.cart, st.noJumpUntil = false, os.clock() + 4
        if running then addStat('cart'); saveCfg() end
    elseif text:find('Сначала отнесите тележку', 1, true) or text:find('Вы уже несете тележку', 1, true) then
        st.cart = true
    elseif text:find('Заберите тележку с дровами', 1, true) then
        st.needLooseCart = true
        if st.target then st.lastTree = st.lastTree or {x = st.target.cx, y = st.target.cy} end
    elseif text:find('уровень сытости ниже 20%', 1, true) then st.satiety = math.min(st.satiety or 19, 19)
    end
end

function sampev.onSetSpawnInfo() setSaw(false); st.cart = false end
function sampev.onSendDeathNotification() setSaw(false); st.cart = false end

function sampev.onTogglePlayerControllable(c)
    if internal.wallClock() < (st.ignoreFrozenUntil or 0) then
        st.frozen = false
    else
        st.frozen = not c
    end
end

local saveCarts
function sampev.onSetPlayerAttachedObject(pid, idx, create, d)
    local ok, res, me = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
    if ok and res and pid == me and idx == 9 then
        st.cart = create and d and d.modelId == 12199 or false
        if st.cart then st.game = nil end
        return
    end

    -- Track a cart picked up by another player.
    if not (ok and res and pid ~= me and create and d and d.modelId == 12199) then return end
    if type(sampGetCharHandleBySampPlayerId) ~= 'function' then return end

    local pedOk, found, ped = pcall(sampGetCharHandleBySampPlayerId, pid)
    if not (pedOk and found and ped) then return end
    local coordsOk, px, py = pcall(getCharCoordinates, ped)
    if not (coordsOk and px and py) then return end

    local bestId, bestDist
    for id, c in pairs(st.looseCarts) do
        local dCart = getDistanceBetweenCoords2d(px, py, c.x, c.y)
        if dCart <= 10 and (not bestDist or dCart < bestDist) then
            bestId, bestDist = id, dCart
        end
    end
    if bestId then
        st.looseCarts[bestId] = nil
        if st.takingLooseCartId == bestId then
            st.stolenLooseCartId = bestId
            st.abortLooseCartWalk = true
        end
        saveCarts()
        dbg(('loose cart %s picked up by another player'):format(tostring(bestId)))
    end
end

st.looseCarts = {}
local CARTS_PATH = SCRIPT_CONFIG_DIR .. '/SawmillBot_carts.json'
saveCarts = function()
    ensureScriptConfigDir()
    local list = {}
    for id, c in pairs(st.looseCarts) do
        list[#list + 1] = {id = id, x = c.x, y = c.y, t = c.t, treeX = c.treeX, treeY = c.treeY}
    end
    local f = io.open(CARTS_PATH, 'w')
    if f then f:write(encodeJson(list)); f:close() end
end
local SAW_PATH = SCRIPT_CONFIG_DIR .. '/SawmillBot_saw.txt'
function setSaw(v)
    ensureScriptConfigDir()
    st.saw = v
    local f = io.open(SAW_PATH, 'w')
    if f then f:write(v and tostring(getGameTimer()) or ''); f:close() end
end
local function loadSaw()
    local f = io.open(SAW_PATH, 'r')
    if not f then return end
    local t = tonumber(f:read('*a')); f:close()
    st.saw = t ~= nil and t <= getGameTimer()
end

local function loadCarts()
    local f = io.open(CARTS_PATH, 'r')
    if not f then return end
    local ok, list = pcall(decodeJson, f:read('*a')); f:close()
    for _, c in ipairs(ok and list or {}) do
        if os.time() - (c.t or 0) < 85 then
            st.looseCarts[c.id] = {x = c.x, y = c.y, t = c.t, treeX = c.treeX, treeY = c.treeY}
        end
    end
end
function sampev.onCreateObject(id, d)
    if d.modelId == 12199 and d.position and (d.attachToVehicleId or 65535) == 65535 then
        local tree
        if st.myTree and getDistanceBetweenCoords2d(st.myTree.x, st.myTree.y, d.position.x, d.position.y) < 12 then
            tree = st.myTree
        elseif st.lastTree and getDistanceBetweenCoords2d(st.lastTree.x, st.lastTree.y, d.position.x, d.position.y) < 12 then
            tree = st.lastTree
        end
        if tree then
            st.looseCarts[id] = {x = d.position.x, y = d.position.y, t = os.time(), treeX = tree.x, treeY = tree.y}
            saveCarts()
        end
    end
end
function sampev.onDestroyObject(id)
    if st.looseCarts[id] then st.looseCarts[id] = nil; saveCarts() end
end
function sampev.onSetCheckpoint(p, r) st.cp = {x = p.x, y = p.y, z = p.z} end
function sampev.onDisableCheckpoint() st.cp = nil end

local function waitFor(cond, ms)
    local t = os.clock() + ms / 1000
    while running and os.clock() < t do
        if cond() then return true end
        wait(50)
    end
    return false
end

local function exitTrailer()
    st.pendingDlg, st.tpGraceUntil = 'exit', os.clock() + 10
    interact()
    waitFor(function() local _, _, z = pos(); return z < 1000 end, 5000)
    wait(1500)
end

local function rentSaw()
    dbg(('rentSaw d=%.1f'):format(dist2(NPC.x, NPC.y)))
    if dist2(NPC.x, NPC.y) > 0.6 and not walkTo(NPC.x, NPC.y, 0.5, 60) then return end
    st.pendingDlg = 'rent'
    interact()
    if not waitFor(function() return st.saw end, 5000) then st.pendingDlg = nil; msg('пилу взять не вышло, повтор') end
end

local function myNick()
    local ok, res, id = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
    return ok and res and sampGetPlayerNickname(id) or '?'
end

--игроки
local function isPlayerNearTree(x, y)
    if not cfg.checkTrees then return false end
    if type(sampGetMaxPlayerId) ~= 'function'
        or type(sampIsPlayerConnected) ~= 'function'
        or type(sampGetCharHandleBySampPlayerId) ~= 'function'
        or type(doesCharExist) ~= 'function' then
        return false
    end

    local maxOk, maxId = pcall(sampGetMaxPlayerId)
    if not maxOk or type(maxId) ~= 'number' then return false end

    local myId
    local myOk, myFound, myPlayerId = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
    if myOk and myFound then myId = myPlayerId end

    for id = 0, maxId do
        if id ~= myId then
            local connectedOk, connected = pcall(sampIsPlayerConnected, id)
            if connectedOk and connected then
                local pedOk, found, ped = pcall(sampGetCharHandleBySampPlayerId, id)
                if pedOk and found and ped and ped ~= PLAYER_PED then
                    local existsOk, exists = pcall(doesCharExist, ped)
                    if existsOk and exists then
                        local coordsOk, px, py = pcall(getCharCoordinates, ped)
                        if coordsOk and px and py
                            and getDistanceBetweenCoords2d(x, y, px, py) <= 4.0 then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

function treeLabels()
    local list = {}
    for id = 0, 2047 do
        if sampIs3dTextDefined(id) then
            local txt, _, x, y, z = sampGet3dTextInfoById(id)
            if txt:find('Дерево', 1, true) then list[#list + 1] = {x = x, y = y, z = z, text = txt} end
        end
    end
    return list
end

function markTrunks(labels)
    if not nav then return end
    local t, centers = {}, {}
    for li, l in ipairs(labels) do
        if li % 8 == 0 then wait(0) end
        for _, o in ipairs(labels) do
            local d = getDistanceBetweenCoords2d(l.x, l.y, o.x, o.y)
            if o ~= l and d > 2 and d < 8 then
                local cx, cy = (l.x + o.x) / 2, (l.y + o.y) / 2
                centers[#centers + 1] = {cx, cy}
                local ci, cj = navCell(cx, cy)
                for dj = -4, 4 do for di = -4, 4 do
                    local k, r = (cj + dj) * nav.W + ci + di, math.sqrt(di * di + dj * dj) * nav.cell
                    if r <= 2.0 then t[k] = true
                    elseif r <= 3.5 and t[k] ~= true then t[k] = math.max(t[k] or 0, (3.5 - r) * 2.5) end
                end end
            end
        end
    end
    trunks, st.trunkCenters = t, centers
end

function internal.treeKey(cx, cy)
    return ('%.0f,%.0f'):format(cx, cy)
end

function internal.collectTreeCandidates(near, skipMark, strictNearest, excludeKey)
    local labels, nick, px, py = treeLabels(), myNick(), pos()
    if not skipMark then markTrunks(labels) end

    local byKey = {}
    for _, l in ipairs(labels) do
        if l.text:find('Доступно для рубки', 1, true)
            and (not near or getDistanceBetweenCoords2d(near.x, near.y, l.x, l.y) < 8) then
            local cx, cy, mine = l.x, l.y, false
            for _, o in ipairs(labels) do
                local d = getDistanceBetweenCoords2d(l.x, l.y, o.x, o.y)
                if o ~= l and d > 2 and d < 8 then
                    cx, cy = (l.x + o.x) / 2, (l.y + o.y) / 2
                    mine = o.text:find(nick, 1, true) ~= nil
                end
            end

            local key = internal.treeKey(cx, cy)
            if key ~= excludeKey then
                local score = getDistanceBetweenCoords2d(px, py, l.x, l.y)
                local my = st.myTree and getDistanceBetweenCoords2d(cx, cy, st.myTree.x, st.myTree.y) < 1.5
                if not strictNearest then score = score - ((mine or my) and 1000 or 0) end

                local banned = (st.blacklist or {})[key]
                if (not banned or banned <= os.clock()) and not isPlayerNearTree(cx, cy) then
                    local old = byKey[key]
                    if not old or score < old.score then
                        byKey[key] = {x = l.x, y = l.y, cx = cx, cy = cy, score = score, key = key}
                    end
                end
            end
        end
    end

    local candidates = {}
    for _, candidate in pairs(byKey) do
        candidates[#candidates + 1] = candidate
    end
    table.sort(candidates, function(a, b)
        if a.score == b.score then return a.key < b.key end
        return a.score < b.score
    end)
    return candidates
end

local function pickTree(near, skipMark, strictNearest)
    local candidates = internal.collectTreeCandidates(near, skipMark, strictNearest)
    return candidates[1]
end

internal.tryTreeTargetSwitch = function()
    if not cfg.checkTrees or not st.treeSeeking or not st.target then return 'clear' end

    local now = os.clock()
    if now < (st.treeNextPlayerCheck or 0) then return 'clear' end
    st.treeNextPlayerCheck = now + 0.25

    local current = st.target
    if not isPlayerNearTree(current.cx, current.cy) then return 'clear' end

    local key = internal.treeKey(current.cx, current.cy)
    st.blacklist = st.blacklist or {}
    local oldExpiry = st.blacklist[key] or 0
    if oldExpiry < now + 30 then st.blacklist[key] = now + 30 end


    local candidates = internal.collectTreeCandidates(nil, true, true, key)
    local backup = candidates[1]
    if backup then
        st.target = backup
        st.myTree = {x = backup.cx, y = backup.cy}
        if not st.chopping then st.nextTree = backup end
        st.treeTargetChanged = true
        st.treeSwitchImmediate = true
        st.treeNextPlayerCheck = now + 0.25
        st.treeNoBackup = false
        msg('дерево заняли, переключаюсь на запасное')
        return 'switched'
    end

    st.treeNoBackup = true
    st.treeNextPlayerCheck = now + 1.0
    msg('рядом с деревом игрок, свободных запасных деревьев пока нет')
    return 'blocked'
end

local function hit(g)
    local p = math.floor(g.start + g.width / 2 + 0.5)
    local x = math.floor((p - g.start) / g.width * 100 + 0.5)
    wait(400)
    lumberBtn(90)
    wait(math.floor(p / g.speed + 0.5) * 75)
    lumberBtn(91, p .. ', ' .. x)
end

--рубка
local function chop()
    local tree
    if st.nextTree then
        tree = st.nextTree
        st.nextTree = nil
    elseif cfg.autoNearestTree then

        tree = pickTree(nil, true, true)
    else
        tree = pickTree(st.cp)
        if not tree then tree = pickTree() end
    end
    if not tree then msg('свободных деревьев нет, повторю поиск'); wait(3000); return end
    if cfg.checkTrees and isPlayerNearTree(tree.cx, tree.cy) then
        st.blacklist = st.blacklist or {}
        local key = internal.treeKey(tree.cx, tree.cy)
        st.blacklist[key] = math.max(st.blacklist[key] or 0, os.clock() + 30)
        tree = pickTree(nil, true, true)
        if not tree then msg('выбранное дерево заняли, свободных деревьев нет'); wait(500); return end
    end
    st.target = tree
    st.myTree = {x = tree.cx, y = tree.cy}
    st.chopping = true
    st.treeSeeking = true
    st.treeNoBackup = false
    st.treeTargetChanged = false
    st.treeSwitchImmediate = false
    st.treeNextPlayerCheck = 0
    st.atSideSince = os.clock()
    local ok, err = pcall(function()
    local cx, cy = tree.cx, tree.cy
    local idle = os.clock()
    while running and not st.cart and not st.needLooseCart do
        local targetState = internal.tryTreeTargetSwitch()
        if targetState == 'switched' and st.target then
            cx, cy = st.target.cx, st.target.cy
            st.treeTargetChanged = false
            idle, st.atSideSince = os.clock(), os.clock()
        elseif targetState == 'blocked' then
            releaseBotTouches(false)
            return
        end
        if st.treeTargetChanged and st.target then
            cx, cy = st.target.cx, st.target.cy
            st.treeTargetChanged = false
        end
        local g = st.game
        if os.clock() < (st.holdUntil or 0) then
            idle = os.clock()
        elseif g and g.my == 1 and g.cur == -1 and g.start then
            st.game = nil
            hit(g)
            idle = os.clock()
        else
            local side = pickTree({x = cx, y = cy})
            local waitHere = g and g.my == 1 and g.cur == -1
            if side and dist2(side.x, side.y) > 0.8 and not waitHere then
                if st.window then lumberBtn(92); wait(500) end
                local moveOk, moveState
                if dist2(cx, cy) < 6 then
                    moveOk, moveState = orbitTo(side.x, side.y, cx, cy)
                else
                    moveOk, moveState = walkTo(side.x, side.y, 0.5, 60)
                end
                if moveState == 'tree_switched' or st.treeTargetChanged then
                    if st.target then cx, cy = st.target.cx, st.target.cy end
                    st.treeTargetChanged = false
                elseif moveState == 'no_free_tree' or st.treeNoBackup then
                    return
                else
                    pcall(setCameraBehindPlayer)
                end
                idle, st.atSideSince = os.clock(), os.clock()
            elseif side and not st.window and os.clock() - (st.atSideSince or os.clock()) > 5 then
                local px, py = pos()
                local d = math.max(0.1, getDistanceBetweenCoords2d(px, py, cx, cy))
                local _, firstState = walkTo(cx + (px - cx) / d * 5, cy + (py - cy) / d * 5, 1.0, 15)
                if firstState == 'tree_switched' or st.treeTargetChanged then
                    if st.target then cx, cy = st.target.cx, st.target.cy end
                    st.treeTargetChanged = false
                elseif firstState == 'no_free_tree' or st.treeNoBackup then
                    return
                else
                    local _, secondState = walkTo(side.x, side.y, 0.5, 20)
                    if secondState == 'tree_switched' or st.treeTargetChanged then
                        if st.target then cx, cy = st.target.cx, st.target.cy end
                        st.treeTargetChanged = false
                    elseif secondState == 'no_free_tree' or st.treeNoBackup then
                        return
                    end
                end
                st.atSideSince, idle = os.clock(), os.clock()
            end
        end
        if os.clock() - (st.chopDbgAt or 0) > 4 and os.clock() - idle > 4 then
            st.chopDbgAt = os.clock()
            for id = 0, 2047 do
                if sampIs3dTextDefined(id) then
                    local txt, _, x, y = sampGet3dTextInfoById(id)
                    if txt:find('Срублено', 1, true) and getDistanceBetweenCoords2d(x, y, cx, cy) < 4 then
                        dbg('дерево срублено без тележки, следующее'); return
                    end
                end
            end
            local sd = pickTree({x = cx, y = cy})
            dbg(('chop idle %.0fs: side=%s d=%s win=%s frozen=%s g=%s/%s/%s atSide=%.0fs'):format(os.clock() - idle,
                tostring(sd ~= nil), sd and ('%.1f'):format(dist2(sd.x, sd.y)) or '-', tostring(st.window), tostring(st.frozen),
                g and tostring(g.my) or '-', g and tostring(g.cur) or '-', g and tostring(g.stage) or '-', os.clock() - (st.atSideSince or os.clock())))
        end
        if os.clock() - idle > 30 then msg('рубка зависла, ищу дерево заново'); return end
        if st.treeSwitchImmediate then
            st.treeSwitchImmediate = false
            wait(0)
        else
            wait(100)
        end
    end
    end)
    st.chopping, st.target, st.treeSeeking = false, nil, false
    st.treeNoBackup, st.treeTargetChanged = false, false
    if not ok then dbg('chop error: ' .. tostring(err)) end
end

--еда
local function checkSatiety()
    st.pendingDlg = 'sat'
    sampSendChat('/satiety')
    waitFor(function() return st.pendingDlg ~= 'sat' end, 4000)
    st.pendingDlg = nil
    st.nextSatCheck = os.clock() + 240 + math.random(180)
end

local function eat()
    msg(('сытость %d%%, иду к ларьку'):format(st.satiety or 0))
    st.foodOpen, st.hotdogPrice = false, nil
    if not walkTo(FOOD.x, FOOD.y, 0.8, 90) then walkTo(FOOD.x, FOOD.y, 1.5, 20) end
    interact()
    wait(300)
    if not waitFor(function() return st.foodOpen end, 5000) then
        msg('меню ларька не открылось, попробую через 2 мин')
        st.eatBlockedUntil = os.clock() + 120
        return
    end
    wait(600 + math.random(500))
    while running and (st.satiety or 0) < cfg.eatTo do
        local before = st.satiety
        sendUI(55, 0, 1, '0')
        if not waitFor(function() return st.satiety ~= before end, 3000) then
            msg('хот-дог не купился, попробую через 3 мин')
            st.eatBlockedUntil = os.clock() + 180
            break
        end
        wait(700 + math.random(600))
    end
    sendUI(55, 0, 0, '')
    wait(300)
    sendUI(17, 2, -1, '')
    st.foodOpen = false


    local previousCamHeading = st.lastCamHeading or internal.camHeadingRaw()
    movementTouch(1)
    sprint(false)
    wait(500)
    pcall(setCameraBehindPlayer)
    wait(500)


    local currentCamHeading = internal.camHeadingRaw()
    if currentCamHeading ~= nil then
        st.lastCamHeading = currentCamHeading
    elseif previousCamHeading ~= nil then
        st.lastCamHeading = previousCamHeading
    end


    st.camPrepared = true
    st.camFix = 0


    st.ignoreFrozenUntil = internal.wallClock() + 3.5
    st.frozen = false
end

--тележки
local function nearestLooseCart()
    local tree = st.lastTree
    local best, bd
    for id, c in pairs(st.looseCarts) do
        if os.time() - (c.t or os.time()) > 85 then
            st.looseCarts[id] = nil
        else
            local belongsToLastTree = not tree or not c.treeX or not c.treeY
                or getDistanceBetweenCoords2d(tree.x, tree.y, c.treeX, c.treeY) < 12
            local d = dist2(c.x, c.y)
            if belongsToLastTree and d < 120 and (not bd or d < bd) then
                best, bd = {id = id, x = c.x, y = c.y, t = c.t}, d
            end
        end
    end
    if not best and st.needLooseCart and tree then
        st.blacklist = st.blacklist or {}
        st.blacklist[('%.0f,%.0f'):format(tree.x, tree.y)] = os.clock() + 600
        dbg('loose cart not tracked, blacklist tree')
    end
    if not best then st.lastTree, st.needLooseCart = nil, false end
    return best
end

local function takeLooseCart(c)
    if not c then return false end
    st.takingLooseCartId = c.id
    st.stolenLooseCartId = nil
    st.abortLooseCartWalk = false
    local function wasStolen()
        return c.id ~= nil and st.stolenLooseCartId == c.id
    end
    local function resumeTreeAfterTheft()
        if c.id then st.looseCarts[c.id] = nil end
        saveCarts()
        st.lastTree, st.needLooseCart = nil, false
        st.resumeTreeAfterStolen = true
        st.takingLooseCartId, st.stolenLooseCartId = nil, nil
        st.abortLooseCartWalk = false
        msg('\xf2\xe5\xeb\xe5\xe6\xea\xf3 \xe7\xe0\xe1\xf0\xe0\xeb \xe4\xf0\xf3\xe3\xee\xe9 \xe8\xe3\xf0\xee\xea, \xe2\xee\xe7\xe2\xf0\xe0\xf9\xe0\xfe\xf1\xfc \xea \xf0\xf3\xe1\xea\xe5')
        return false
    end

    msg('\xe7\xe0\xe1\xe8\xf0\xe0\xfe \xf2\xe5\xeb\xe5\xe6\xea\xf3 \xf3 \xe4\xe5\xf0\xe5\xe2\xe0')
    local routeOk = walkTo(c.x, c.y, 1.0, 60)
    if wasStolen() then return resumeTreeAfterTheft() end
    if not routeOk then
        st.takingLooseCartId = nil
        st.abortLooseCartWalk = false
        return false
    end

    local pickedUp = false
    for _ = 1, 3 do
        if wasStolen() then return resumeTreeAfterTheft() end
        interact()
        waitFor(function() return st.cart or wasStolen() end, 2000)
        if st.cart then
            pickedUp = true
            break
        elseif wasStolen() then
            return resumeTreeAfterTheft()
        end
        walkTo(c.x, c.y, 0.5, 5)
        if wasStolen() then return resumeTreeAfterTheft() end
    end
    st.takingLooseCartId = nil
    st.abortLooseCartWalk = false
    if pickedUp then
        if c.id and st.looseCarts[c.id] then
            st.looseCarts[c.id] = nil
            saveCarts()
        end
        st.lastTree, st.needLooseCart = nil, false
        return true
    end
    st.needLooseCart = false
    return false
end

local function deliver()
    if not waitFor(function() return st.cp ~= nil end, 5000) then return end

    local deliveryPoint = {
        x = st.cp.x,
        y = st.cp.y,
        z = st.cp.z
    }

    local delivered = walkTo(deliveryPoint.x, deliveryPoint.y, 1.0, 90)
    if not delivered then return end

    if not waitFor(function() return not st.cart end, 10000) then return end


    movementTouch(1)
    sprint(false)
    wait(500)
    pcall(setCameraBehindPlayer)
    wait(300)

    local expectedX = -557.2708740234
    local expectedY = -199.6298065186
    local expectedZLeft = 78.4769973755
    local expectedZRight = 77.531639
    local tolerance = 0.5

    local isExpectedDelivery =
        math.abs(deliveryPoint.x - expectedX) <= tolerance and
        math.abs(deliveryPoint.y - expectedY) <= tolerance and
        (math.abs(deliveryPoint.z - expectedZLeft) <= tolerance or
         math.abs(deliveryPoint.z - expectedZRight) <= tolerance)

    if not isExpectedDelivery then
        dbg(('точка сдачи другая (%.4f, %.4f, %.4f), возврат пропущен'):format(
            deliveryPoint.x, deliveryPoint.y, deliveryPoint.z))
        return
    end

    dbg('нужная точка сдачи подтверждена, строю маршрут через точку возврата')
    local returnPoint = {
        x = -555.6541748047,
        y = -192.6629943848,
        z = 78.3762359619
    }


    st.camPrepared = false
    st.camFix = 0
    st.lastCamHeading = nil
    local nextTree
    if cfg.autoNearestTree then
        nextTree = pickTree(nil, true, true)
    else
        nextTree = pickTree(st.cp)
        if not nextTree then nextTree = pickTree() end
    end
    local routeOk
    if nextTree then
        st.treeSeeking = true
        st.treeNoBackup = false
        st.treeTargetChanged = false
        st.treeNextPlayerCheck = 0
        st.treeViaPointPassed = false
        st.target = nextTree
        st.myTree = {x = nextTree.cx, y = nextTree.cy}

        local routeState
        repeat
            local routeVia = not st.treeViaPointPassed and returnPoint or nil
            routeOk, routeState = walkTo(nextTree.x, nextTree.y, 0.8, 120, nil, nil, routeVia)
            if routeState == 'tree_switched' and st.target then
                nextTree = st.target
            else
                break
            end
        until not running

        st.treeSeeking = false
        if routeOk then
            st.nextTree = nextTree
            st.target = nextTree
        else
            st.nextTree = nil
            st.target = nil
        end
        st.treeViaPointPassed = false
    else
        st.treeSeeking = false
        st.target = nil
        routeOk = walkTo(returnPoint.x, returnPoint.y, 1.0, 90, nil, returnPoint.z)
    end
    if not routeOk then st.nextTree = nil end
end

local imgui = require('mimgui')
local okFa, fa = pcall(require, 'fAwesome6_solid')
if not okFa then
    fa = setmetatable({}, { __index = function() return '' end })
end
--графика
local function ico(name)
    local ok, v = pcall(function() return rawget(fa, name) end)
    if ok and type(v) == 'string' and v ~= '' then return v end
    return ''
end
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local ImVec2, ImVec4 = imgui.ImVec2, imgui.ImVec4
local MDS = MONET_DPI_SCALE or 1
local S = math.max(1, math.min(2, select(2, getScreenResolution()) / 900))
local menuOpen = imgui.new.bool(false)
local function screenSize()
    local ok, ds = pcall(function() return imgui.GetIO().DisplaySize end)
    if ok and ds and ds.x > 100 and ds.y > 100 then return ds.x, ds.y end
    return getScreenResolution()
end
local AUTHOR, TG_CHANNEL, TG_AUTHOR = 'pinokio', 'pinokio_channel', 'oxzay'

local C = {
    WOOD = ImVec4(1.00, 0.62, 0.24, 1), WOODD = ImVec4(0.85, 0.45, 0.18, 1), GOLD = ImVec4(1.00, 0.80, 0.40, 1),
    TRACK = ImVec4(0.60, 0.40, 0.27, 1), LEAF = ImVec4(0.55, 0.85, 0.24, 1), EMBER = ImVec4(0.90, 0.11, 0.32, 1),
    GREY = ImVec4(0.40, 0.42, 0.45, 1), BADGE = ImVec4(0.10, 0.04, 0.02, 0.55), PLANK = ImVec4(0.22, 0.10, 0.05, 1),
    TEXT = ImVec4(1, 1, 1, 1), DIM = ImVec4(0.86, 0.72, 0.60, 1),
}
local function cu(v, a)
    local g = internal.fadeFn and internal.fadeFn()
    if g and g < 1 then
        return imgui.ColorConvertFloat4ToU32(ImVec4(v.x, v.y, v.z, v.w * (a or 1) * g))
    end
    return imgui.ColorConvertFloat4ToU32(a and ImVec4(v.x, v.y, v.z, v.w * a) or v)
end
local function mix(a, b, k) return ImVec4(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k, a.z + (b.z - a.z) * k, a.w + (b.w - a.w) * k) end

internal.AXE = '[axe]'
local IC = {
    tree = ico('TREE'), house = ico('HOUSE'), sliders = ico('SLIDERS'), food = ico('UTENSILS'),
    chart = ico('CHART_LINE'), info = ico('CIRCLE_INFO'), power = ico('POWER_OFF'), bars = ico('BARS'),
    xmark = ico('XMARK'), coins = ico('COINS'), clock = ico('CLOCK'), dolly = ico('DOLLY'),
    run = ico('PERSON_RUNNING'), eye = ico('EYE'), plane = ico('PAPER_PLANE'), user = ico('USER'),
    box = ico('BOX'), bolt = ico('BOLT'), hotdog = ico('HOTDOG'), trash = ico('TRASH_CAN'),
    window = ico('WINDOW_MAXIMIZE'), saw = internal.AXE, shield = ico('SHIELD'),
}

local URL_AVATAR = 'https://raw.githubusercontent.com/pinokio-67/botava/main/avatar.png'
local URL_PANEL = 'https://raw.githubusercontent.com/pinokio-67/botava/main/panel.png'
local URL_OTHER = 'https://raw.githubusercontent.com/pinokio-67/botava/main/art.png'

local TEX = {}
local textureFiles = {
    avatar = {url = URL_AVATAR, file = 'avatar.png'},
    panel = {url = URL_PANEL, file = 'panel.png'},
    art = {url = URL_OTHER, file = 'art.png'}
}
local texturesLoaded = false
local assetsDownloading = false
local assetsReady = false
local assetsLastAttempt = 0

local function assetPath(name)
    return SCRIPT_CONFIG_DIR .. '/' .. textureFiles[name].file
end

local function readBinaryFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

internal.isValidPng = function(data)
    return type(data) == 'string'
        and #data > 32
        and data:sub(1, 8) == string.char(137, 80, 78, 71, 13, 10, 26, 10)
end

internal.writeBinaryFile = function(path, data)
    local f, err = io.open(path, 'wb')
    if not f then return false, err end
    local ok, writeErr = pcall(function() f:write(data) end)
    f:close()
    if not ok then return false, writeErr end
    return true
end

internal.downloadAssetHttp = function(url)
    local chunks = {}
    local responseCode = nil
    local requestOk = false
    local requestError = nil

    if _copas_ok and _requests_ok and _copas and _requests
        and type(_copas.addthread) == 'function' then
        local done = false
        _copas.addthread(function()
            local ok, result, code = pcall(_requests.request, {
                url = url,
                method = 'GET',
                redirect = true,
                sink = function(chunk)
                    if chunk then chunks[#chunks + 1] = chunk end
                    return 1
                end,
                headers = {
                    ['user-agent'] = 'Mozilla/5.0',
                    ['accept'] = 'image/png,*/*'
                },
                timeout = {connect = 30, send = 30, receive = 60}
            })
            requestOk = ok and result ~= nil
            responseCode = tonumber(code)
            if not ok then requestError = tostring(result) end
            done = true
        end)

        local started = os.clock()
        while not done do
            if type(_copas.step) == 'function' then pcall(_copas.step, 0.05) end
            wait(0)
            if os.clock() - started > 90 then
                return nil, 'HTTP timeout'
            end
        end
    else
        local okHttps, https = pcall(require, 'ssl.https')
        local okLtn, ltn12 = pcall(require, 'ltn12')
        if not okHttps or not okLtn then
            return nil, 'нет copas.http и ssl.https/ltn12'
        end
        local ok, result, code = pcall(https.request, {
            url = url,
            method = 'GET',
            redirect = true,
            sink = ltn12.sink.table(chunks),
            headers = {['user-agent'] = 'Mozilla/5.0'}
        })
        requestOk = ok and result ~= nil
        responseCode = tonumber(code)
        if not ok then requestError = tostring(result) end
    end

    if not requestOk then return nil, requestError or ('HTTP request failed: ' .. tostring(responseCode)) end
    if responseCode ~= 200 then return nil, 'HTTP ' .. tostring(responseCode) end

    local data = table.concat(chunks)
    if not internal.isValidPng(data) then
        return nil, 'ответ сервера не является PNG (' .. tostring(#data) .. ' bytes)'
    end
    return data
end

local function downloadAsset(name)
    local item = textureFiles[name]
    local path = assetPath(name)
    local existing = readBinaryFile(path)
    if internal.isValidPng(existing) then return true end
    if existing then pcall(os.remove, path) end

    local tempPath = path .. '.download'
    pcall(os.remove, tempPath)

    if type(downloadUrlToFile) == 'function' then
        local done, success = false, false
        local started, startErr = pcall(downloadUrlToFile, item.url, tempPath, function(id, status, p1, p2)
            if status == 5 then
                dbg(('asset %s: %s/%s bytes'):format(name, tostring(p1), tostring(p2)))
            elseif status == 6 or status == 58 then
                done, success = true, true
            elseif status == -1 then
                done, success = true, false
            end
        end)
        if started then
            local t0 = os.clock()
            while not done and os.clock() - t0 < 20 do wait(50) end
            if success then
                local downloaded = readBinaryFile(tempPath)
                if internal.isValidPng(downloaded) then
                    internal.writeBinaryFile(path, downloaded)
                    pcall(os.remove, tempPath)
                    dbg('asset ' .. name .. ': downloaded by downloadUrlToFile')
                    return true
                end
            end
        else
            dbg('asset ' .. name .. ': downloadUrlToFile error: ' .. tostring(startErr))
        end
        pcall(os.remove, tempPath)
    end

    local data, err
    for attempt = 1, 3 do
        data, err = internal.downloadAssetHttp(item.url)
        if data then break end
        dbg(('asset %s: HTTP attempt %d failed: %s'):format(name, attempt, tostring(err)))
        wait(500)
    end
    if not data then
        dbg('asset ' .. name .. ': download failed: ' .. tostring(err))
        return false
    end

    local saved, saveErr = internal.writeBinaryFile(path, data)
    if not saved then
        dbg('asset ' .. name .. ': cannot save file: ' .. tostring(saveErr))
        return false
    end
    dbg(('asset %s: saved (%d bytes)'):format(name, #data))
    return true
end
local function downloadAssets()
    if assetsDownloading or assetsReady then return end
    assetsDownloading = true
    assetsLastAttempt = os.clock()
    ensureScriptConfigDir()
    local allOk = true
    for _, name in ipairs({'avatar', 'panel', 'art'}) do
        local ok = downloadAsset(name)
        if not ok then allOk = false end
        wait(100)
    end
    assetsReady = allOk
    assetsDownloading = false
    if allOk then
        dbg('all image assets ready')
    else
        dbg('some image assets are missing; will retry on next launch')
    end
end

internal.texLastTry = -100
local function loadTextures()
    if texturesLoaded then return end
    if os.clock() - internal.texLastTry < 2 then return end
    internal.texLastTry = os.clock()
    local loadedAny = false
    for _, name in ipairs({'avatar', 'panel', 'art'}) do
      if not TEX[name] then
        local path = assetPath(name)
        local data = readBinaryFile(path)
        if internal.isValidPng(data) then
            local ok, tex = pcall(imgui.CreateTextureFromFile, path)
            if ok and tex and tex ~= 0 then
                TEX[name] = tex
                loadedAny = true
            else
                dbg('texture ' .. name .. ': CreateTextureFromFile failed: ' .. tostring(tex))
            end
        end
      end
    end
    texturesLoaded = TEX.avatar ~= nil and TEX.panel ~= nil and TEX.art ~= nil
end

local F, faOK = {}, false
local function pf(f) if f then imgui.PushFont(f) end end
local function pp(f) if f then imgui.PopFont() end end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local s, c, col = imgui.GetStyle(), imgui.GetStyle().Colors, imgui.Col
    s.WindowRounding, s.ChildRounding, s.FrameRounding, s.GrabRounding = 0, 0, 12 * S, 12 * S
    s.WindowBorderSize, s.FrameBorderSize, s.WindowPadding = 0, 0, ImVec2(0, 0)
    s.FramePadding, s.ItemSpacing = ImVec2(10 * S, 6 * S), ImVec2(8 * S, 8 * S)
    s.GrabMinSize, s.ScrollbarSize, s.ScrollbarRounding = 56 * S, 15 * S, 6 * S
    c[col.WindowBg], c[col.ChildBg] = ImVec4(0, 0, 0, 0), ImVec4(0, 0, 0, 0)
    c[col.Text], c[col.TextDisabled] = C.TEXT, C.DIM
    c[col.FrameBg], c[col.FrameBgHovered], c[col.FrameBgActive] = C.TRACK, mix(C.TRACK, C.WOOD, 0.2), mix(C.TRACK, C.WOOD, 0.3)
    c[col.SliderGrab], c[col.SliderGrabActive] = C.LEAF, mix(C.LEAF, C.TEXT, 0.3)
    c[col.ScrollbarBg] = ImVec4(0.1, 0.1, 0.1, 0.8)
    c[col.ScrollbarGrab] = ImVec4(1.0, 0.55, 0.0, 0.8)
    c[col.ScrollbarGrabHovered] = ImVec4(1.0, 0.65, 0.1, 1.0)
    c[col.ScrollbarGrabActive] = ImVec4(1.0, 0.7, 0.2, 1.0)

    local io = imgui.GetIO()
    local ttf = getWorkingDirectory() .. '/lib/mimgui/trebucbd.ttf'
    if not doesFileExist(ttf) then return end
    if okFa then
        local lo, hi = 0xe005, 0xf8ff
        pcall(function()
            if type(fa.min_range) == 'number' then lo = fa.min_range end
            if type(fa.max_range) == 'number' then hi = fa.max_range end
        end)
        local fn = rawget(fa, 'get_font_data_base85')
        if type(fn) == 'function' then
            local okD, d = pcall(fn, 'solid')
            if not (okD and type(d) == 'string') then okD, d = pcall(fn) end
            if okD and type(d) == 'string' then F.faData = d end
        end
        local init = rawget(fa, 'Init')
        if not F.faData and type(init) == 'function' and debug and debug.getupvalue then
            local best
            for i = 1, 80 do
                local n, v = debug.getupvalue(init, i)
                if not n then break end
                if type(v) == 'string' and #v > 50000 and (n == 'FONT_BASE85' or not best or #v > #best) then
                    best = v
                    if n == 'FONT_BASE85' then break end
                end
            end
            F.faData = best
        end
        if F.faData then F.faRange = imgui.new.ImWchar[3](lo, hi, 0) end
    end
    local ranges = io.Fonts:GetGlyphRangesCyrillic()
    local function add(px)
        local f = io.Fonts:AddFontFromFileTTF(ttf, px, nil, ranges)
        if F.faData then
            local cfgF = imgui.ImFontConfig(); cfgF.MergeMode, cfgF.PixelSnapH = true, true
            if pcall(function() io.Fonts:AddFontFromMemoryCompressedBase85TTF(F.faData, px * 0.9, cfgF, F.faRange) end) then faOK = true end
        end
        return f
    end
    F.small, F.main, F.header, F.title = add(15 * S), add(18 * S), add(21 * S), add(34 * S)
    if F.faData then
        local function icon(px)
            local cfgF = imgui.ImFontConfig(); cfgF.PixelSnapH = true
            local f; pcall(function() f = io.Fonts:AddFontFromMemoryCompressedBase85TTF(F.faData, px, cfgF, F.faRange) end)
            return f
        end
        F.icon, F.iconBig = icon(22 * S), icon(40 * S)
    end
    if not faOK then F.icon, F.iconBig = nil, nil end
end)

internal.drawAxe = function(dl, cx, cy, size, col)
    local k = size * 0.5
    local function P(x, y) return ImVec2(cx + (x + 0.1) * k, cy + (y + 0.05) * k) end
    dl:AddLine(P(-0.55, 0.68), P(0.22, -0.62), col, math.max(2, size * 0.11))
    local blade = {{0.00, -0.50}, {0.28, -0.78}, {0.70, -0.74}, {0.78, -0.50}, {0.60, -0.10}, {0.42, -0.28}, {0.20, -0.28}}
    local c = P(0.40, -0.50)
    for i = 1, #blade do
        local a, b = blade[i], blade[i % #blade + 1]
        dl:AddTriangleFilled(c, P(a[1], a[2]), P(b[1], b[2]), col)
    end
end
local function iconAt(dl, g, x, y, w, h, col, font)
    if not faOK then return end
    font = font or F.icon
    if g == internal.AXE then
        internal.drawAxe(dl, x + w / 2, y + h / 2, (font == F.iconBig and 40 or 22) * S * 1.1, col)
        return
    end
    pf(font); local sz = imgui.CalcTextSize(g); dl:AddText(ImVec2(x + (w - sz.x) / 2, y + (h - sz.y) / 2), col, g); pp(font)
end
local function hovered(x0, y0, x1, y1)
    local m = imgui.GetIO().MousePos
    return m.x >= x0 and m.x <= x1 and m.y >= y0 and m.y <= y1
end
local function money(n)
    local s = tostring(math.floor(n)):reverse():gsub('(%d%d%d)', '%1.'):reverse()
    return '$' .. s:gsub('^%.', '')
end
local function hms(sec) return ('%d:%02d:%02d'):format(math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60) end
local function sessionTime() return running and (os.time() - stats.session.start) or (stats.session.last or 0) end
local function statusText()
    if not running then return 'остановлен' end
    if st.cart then return 'везу тележку' end
    if st.chopping then return st.window and 'пилю дерево' or 'иду к дереву' end
    if st.foodOpen then return 'ем у ларька' end
    return 'работаю'
end

internal.FX_MINT = {0.45, 1.0, 0.78}
internal.FX_GOLD = {1.0, 0.84, 0.43}
function internal.fxClamp(v, a, b) return math.max(a, math.min(b, v)) end
function internal.fxCol(c, a) return cu(ImVec4(c[1], c[2], c[3], 1), a) end

function internal.fxRing(dl, proj, x, y, z, r, col, a, th, seg)
    seg = seg or 28
    local c = internal.fxCol(col, a)
    local px, py
    for i = 0, seg do
        local ang = i / seg * 6.2831853
        local sx, sy = proj(x + math.cos(ang) * r, y + math.sin(ang) * r, z)
        if sx and px then dl:AddLine(ImVec2(px, py), ImVec2(sx, sy), c, th) end
        px, py = sx, sy
    end
end

function internal.fxRune(dl, proj, x, y, z, r, ang0, col, a)
    internal.fxRing(dl, proj, x, y, z, r, col, a, 1.6 * MDS, 32)
    internal.fxRing(dl, proj, x, y, z, r * 0.78, col, a * 0.8, 1.2 * MDS, 28)
    local c = internal.fxCol(col, a)
    for k = 0, 11 do
        local ang = ang0 + k * math.pi / 6
        local ax, ay = proj(x + math.cos(ang) * r * 0.78, y + math.sin(ang) * r * 0.78, z)
        local bx, by = proj(x + math.cos(ang) * r, y + math.sin(ang) * r, z)
        if ax and bx then dl:AddLine(ImVec2(ax, ay), ImVec2(bx, by), c, 1.5 * MDS) end
    end
    for _, sh in ipairs({{3, -ang0 * 1.3, 0.62}, {4, ang0 * 0.8, 0.5}}) do
        local n, base, rr = sh[1], sh[2], sh[3]
        local lx, ly
        for i = 0, n do
            local a2 = base + i * 2 * math.pi / n
            local sx, sy = proj(x + math.cos(a2) * r * rr, y + math.sin(a2) * r * rr, z)
            if sx and lx then dl:AddLine(ImVec2(lx, ly), ImVec2(sx, sy), c, 1.3 * MDS) end
            lx, ly = sx, sy
        end
    end
end

function internal.fxPillar(dl, proj, x, y, z, col, a, now)
    local bx, by = proj(x, y, z)
    if not bx then return end
    local H = 9
    local tx, ty = proj(x, y, z + H)
    if not tx then ty = by - 320 * MDS end
    local w = math.max(5 * MDS, math.abs(by - ty) / H * 0.30) * (1 + 0.08 * math.sin(now * 3))
    local clear = internal.fxCol(col, 0)
    local function band(hw, aBot)
        local cb = internal.fxCol(col, aBot)
        dl:AddRectFilledMultiColor(ImVec2(bx - hw, ty), ImVec2(bx + hw, by), clear, clear, cb, cb)
    end
    band(w * 1.9, a * 0.20)
    band(w * 0.65, a * 0.50)
    band(w * 0.2, a * 0.85)
    local k = (now * 0.6) % 1
    local yk = by - (by - ty) * k
    local hh = math.abs(by - ty) * 0.12
    local lo, hi = internal.fxCol(col, 0), internal.fxCol({1, 1, 1}, a * 0.7)
    local y0 = internal.fxClamp(yk - hh, math.min(ty, by), math.max(ty, by))
    local y1 = internal.fxClamp(yk + hh, math.min(ty, by), math.max(ty, by))
    dl:AddRectFilledMultiColor(ImVec2(bx - w * 0.5, y0), ImVec2(bx + w * 0.5, yk), lo, lo, hi, hi)
    dl:AddRectFilledMultiColor(ImVec2(bx - w * 0.5, yk), ImVec2(bx + w * 0.5, y1), hi, hi, lo, lo)
end

internal.fxPathHelixSafe = function(...)
    local ok, err = pcall(internal.fxPathHelix, ...)
    if not ok then internal.dbgOnce('helix error', err) end
end
internal.fxPathHelix = function(dl, proj, path, idx, px, py, pz, now)
    local gz0 = pz - 0.9
    local pts = {{px, py}}
    for i = idx or 1, #path do
        local q = path[i]
        pts[#pts + 1] = {q[1], q[2]}
    end
    local seg, total = {}, 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local ddx, ddy = b[1] - a[1], b[2] - a[2]
        local l = math.sqrt(ddx * ddx + ddy * ddy)
        if l > 0.05 then
            seg[#seg + 1] = {a = a, b = b, l = l, s = total}
            total = total + l
        end
    end
    if #seg == 0 or total < 1 then return end

    if cfg.pathComet ~= false then

        local k = (tonumber(cfg.pathSize) or 100) / 100
        local G, M = internal.FX_GOLD, internal.FX_MINT
        local lim = total
        if lim > 40 then lim = 40 end
        local function ptAt(d)
            local si = 1
            while si < #seg and seg[si].s + seg[si].l < d do si = si + 1 end
            local sg = seg[si]
            local u = (d - sg.s) / sg.l
            if u < 0 then u = 0 elseif u > 1 then u = 1 end
            return sg.a[1] + (sg.b[1] - sg.a[1]) * u, sg.a[2] + (sg.b[2] - sg.a[2]) * u
        end
        local function fadeD(d)
            local f = 1
            if d < 2 then f = d / 2 end
            local r = lim - d
            if r < 3 then f = f * (r / 3) end
            if f < 0 then f = 0 end
            return f
        end
        local function colD(d)
            local t = d / 40
            if t > 1 then t = 1 end
            return {G[1] + (M[1] - G[1]) * t, G[2] + (M[2] - G[2]) * t, G[3] + (M[3] - G[3]) * t}
        end
        local drawn = 0

        local d0 = 1.5
        while d0 < lim do
            local x, y = ptAt(d0)
            local sx, sy = proj(x, y, gz0 + 0.03)
            if sx then
                local f = fadeD(d0)
                if f > 0.03 then
                    local rr = 2.2 * MDS * k
                    dl:AddCircleFilled(ImVec2(sx, sy), rr * 2, internal.fxCol(colD(d0), f * 0.10), 10)
                    dl:AddCircleFilled(ImVec2(sx, sy), rr, internal.fxCol(colD(d0), f * 0.45), 8)
                end
            end
            d0 = d0 + 2
        end

        local lap = lim + 5
        for c = 0, 1 do
            local head = (now * 6.5 + c * lap * 0.5) % lap
            for j = 0, 25 do
                local d = head - j * 0.28
                if d > 0.4 and d < lim then
                    local x, y = ptAt(d)
                    local z = gz0 + 0.25 + 0.05 * math.sin(j + now * 3)
                    local sx, sy = proj(x, y, z)
                    local ux, uy = proj(x, y, z + 1)
                    if sx and ux then
                        local sc = sy - uy
                        if sc < 0 then sc = -sc end
                        local t = 1 - j / 26
                        local a = t * math.sqrt(t) * fadeD(d)
                        if a > 0.02 then
                            local r = sc * 0.075 * (1 - j / 34) * k
                            if r < 1.8 * MDS * k then r = 1.8 * MDS * k end
                            local col = colD(d)
                            local cc = ImVec2(sx, sy)
                            dl:AddCircleFilled(cc, r * 2.8, internal.fxCol(col, a * 0.16), 12)
                            dl:AddCircleFilled(cc, r * 1.5, internal.fxCol(col, a * 0.35), 10)
                            dl:AddCircleFilled(cc, r, internal.fxCol({1, 1, 0.92}, a * 0.95), 8)
                            drawn = drawn + 1
                        end
                    end
                end
            end
        end
        if now - (internal.helixDbgT or 0) > 5 then
            internal.helixDbgT = now
            dbg(('path v32: comet=%d segs=%d total=%.1f m size=%d%%'):format(drawn, #seg, total, math.floor(k * 100)))
        end
        return
    end

    if cfg.pathFlies ~= false then

        local SP, FMAX = 0.9, 42
        local k = (tonumber(cfg.pathSize) or 100) / 100
        local G, M = internal.FX_GOLD, internal.FX_MINT
        local drawn = 0
        local j0 = math.floor((total - FMAX) / SP)
        if j0 < 0 then j0 = 0 end
        local j1 = math.floor(total / SP)
        local si = #seg
        for j = j1, j0, -1 do
            local function rnd(n)
                local v = math.sin(j * 12.9898 + n * 78.233) * 43758.5453
                return v - math.floor(v)
            end
            local ph = rnd(4) * 6.2832
            local d = total - (j + rnd(1)) * SP
            d = d + math.sin(now * 0.7 + ph) * 0.35
            if d > 0.8 and d < total - 0.3 then
                while si > 1 and seg[si].s > d do si = si - 1 end
                while si < #seg and seg[si].s + seg[si].l < d do si = si + 1 end
                local sg = seg[si]
                local u = (d - sg.s) / sg.l
                if u < 0 then u = 0 elseif u > 1 then u = 1 end
                local dx, dy = (sg.b[1] - sg.a[1]) / sg.l, (sg.b[2] - sg.a[2]) / sg.l
                local off = (rnd(2) - 0.5) * 0.9 + math.sin(now * 0.9 + ph) * 0.18
                local x = sg.a[1] + (sg.b[1] - sg.a[1]) * u - dy * off
                local y = sg.a[2] + (sg.b[2] - sg.a[2]) * u + dx * off
                local z = gz0 + 0.25 + rnd(3) * 0.8 + math.sin(now * 1.3 + ph * 2) * 0.12
                local sx, sy = proj(x, y, z)
                local ux, uy = proj(x, y, z + 1)
                if sx and ux then
                    local sc = sy - uy
                    if sc < 0 then sc = -sc end
                    local fade = 1
                    if d < 3 then fade = d / 3 end
                    local rem = total - d
                    if rem < 2 then fade = fade * (rem / 2) end
                    if d > FMAX - 10 then fade = fade * ((FMAX - d) / 10) end
                    local tw = 0.55 + 0.45 * math.sin(now * (2.2 + rnd(5) * 2.5) + ph)
                    local a = fade * tw
                    if a > 0.03 then
                        local r = sc * 0.035 * k
                        if r < 1.4 * MDS * k then r = 1.4 * MDS * k end
                        local t = d / FMAX
                        if t > 1 then t = 1 end
                        local col = {G[1] + (M[1] - G[1]) * t, G[2] + (M[2] - G[2]) * t, G[3] + (M[3] - G[3]) * t}
                        local c = ImVec2(sx, sy)
                        dl:AddCircleFilled(c, r * 4.2, internal.fxCol(col, a * 0.10), 14)
                        dl:AddCircleFilled(c, r * 2.2, internal.fxCol(col, a * 0.28), 12)
                        dl:AddCircleFilled(c, r, internal.fxCol({1, 1, 0.9}, a * 0.95), 8)
                        drawn = drawn + 1
                    end
                end
            end
        end
        if now - (internal.helixDbgT or 0) > 5 then
            internal.helixDbgT = now
            dbg(('path v29: fireflies=%d segs=%d total=%.1f m size=%d%%'):format(drawn, #seg, total, math.floor(k * 100)))
        end
        return
    end

    local MAXD, STEP = 60, 0.55
    local lim = total
    if lim > MAXD then lim = MAXD end
    local n = math.floor(lim / STEP)
    local limD = lim
    if limD < 1 then limD = 1 end

    local cs, valid, si = {}, 0, 1
    for i = 0, n do
        local d = i * STEP
        while si < #seg and seg[si].s + seg[si].l < d do si = si + 1 end
        local sg = seg[si]
        local u = (d - sg.s) / sg.l
        if u < 0 then u = 0 elseif u > 1 then u = 1 end
        local x = sg.a[1] + (sg.b[1] - sg.a[1]) * u
        local y = sg.a[2] + (sg.b[2] - sg.a[2]) * u
        local sx, sy = proj(x, y, gz0)
        local ux, uy = proj(x, y, gz0 + 1)
        if sx and ux then
            local sc = sy - uy
            if sc < 0 then sc = -sc end
            if sc > 0.5 then cs[i + 1] = {sx, sy, sc, d}; valid = valid + 1 end
        end
    end

    local function fadeAt(d)
        local f = 1
        if d < 2.5 then f = d / 2.5 end
        local r = total - d
        if r < 2.5 then f = f * (r / 2.5) end
        r = MAXD - d
        if r < 12 then f = f * (r / 12) end
        if f < 0 then f = 0 end
        return f
    end

    local lines, fmax, fallback = 0, 0, false

    if cfg.pathRibbon ~= false then
        local G, M = internal.FX_GOLD, internal.FX_MINT
        local pulse = (now * 0.55) % 1
        local prev
        for i = 1, n + 1 do
            local c = cs[i]
            if c and prev then
                local d = c[4]
                local u = d / limD
                local col = {G[1] + (M[1] - G[1]) * u, G[2] + (M[2] - G[2]) * u, G[3] + (M[3] - G[3]) * u}
                local fade = fadeAt(d)
                if fade > fmax then fmax = fade end
                if fade > 0.02 then
                    local wpx = c[3] * 0.34
                    if wpx < 2 * MDS then wpx = 2 * MDS end
                    local a, b = ImVec2(prev[1], prev[2]), ImVec2(c[1], c[2])
                    dl:AddLine(a, b, internal.fxCol(col, fade * 0.18), wpx * 2.4)
                    dl:AddLine(a, b, internal.fxCol(col, fade * 0.85), wpx)
                    dl:AddCircleFilled(b, wpx * 1.2, internal.fxCol(col, fade * 0.18), 10)
                    dl:AddCircleFilled(b, wpx * 0.5, internal.fxCol(col, fade * 0.85), 10)
                    local k = (u - pulse + 1) % 1
                    if k < 0.12 then
                        dl:AddLine(a, b, internal.fxCol({1, 1, 1}, fade * (1 - k / 0.12) * 0.8), wpx * 0.4)
                    end
                    lines = lines + 1
                end
            end
            prev = c
        end
    else
        local R, H = 0.45, 0.6
        local gold, mint, rung = C.GOLD, ImVec4(0.43, 0.92, 0.75, 1), ImVec4(0.9, 0.86, 0.78, 1)
        local prev1, prev2, pc
        for i = 1, n + 1 do
            local c = cs[i]
            if c and pc then
                local tx, ty = c[1] - pc[1], c[2] - pc[2]
                local tl = math.sqrt(tx * tx + ty * ty)
                if tl > 0.3 then
                    tx, ty = tx / tl, ty / tl
                    local nx, ny = -ty, tx
                    local d, sc = c[4], c[3]
                    local ang = d * 1.7 - now * 4.5
                    local s1, c1 = math.sin(ang), math.cos(ang)
                    local fade = fadeAt(d)
                    if fade > fmax then fmax = fade end
                    local x1, y1 = c[1] + nx * R * sc * s1, c[2] + ny * R * sc * s1 - (H + R * 0.7 * c1) * sc
                    local x2, y2 = c[1] - nx * R * sc * s1, c[2] - ny * R * sc * s1 - (H - R * 0.7 * c1) * sc
                    local d1, d2 = (c1 + 1) / 2, (1 - c1) / 2
                    if fade > 0.02 then
                        if prev1 then
                            local a1 = (0.45 + 0.55 * d1) * fade
                            dl:AddLine(ImVec2(prev1[1], prev1[2]), ImVec2(x1, y1), cu(gold, a1 * 0.25), (4.5 + 2 * d1) * MDS)
                            dl:AddLine(ImVec2(prev1[1], prev1[2]), ImVec2(x1, y1), cu(gold, a1), (2 + 1.8 * d1) * MDS)
                            lines = lines + 1
                        end
                        if prev2 then
                            local a2 = (0.45 + 0.55 * d2) * fade
                            dl:AddLine(ImVec2(prev2[1], prev2[2]), ImVec2(x2, y2), cu(mint, a2 * 0.25), (4.5 + 2 * d2) * MDS)
                            dl:AddLine(ImVec2(prev2[1], prev2[2]), ImVec2(x2, y2), cu(mint, a2), (2 + 1.8 * d2) * MDS)
                        end
                        if i % 4 == 0 then
                            dl:AddLine(ImVec2(x1, y1), ImVec2(x2, y2), cu(rung, 0.3 * fade), 1.3 * MDS)
                        end
                    end
                    prev1, prev2 = {x1, y1}, {x2, y2}
                else
                    prev1, prev2 = nil, nil
                end
            else
                prev1, prev2 = nil, nil
            end
            pc = c
        end
    end

    if lines == 0 and valid > 1 then
        fallback = true
        local prev
        for i = 1, n + 1 do
            local c = cs[i]
            if c and prev then
                dl:AddLine(ImVec2(prev[1], prev[2]), ImVec2(c[1], c[2]), 0x506ED6FF, 7 * MDS)
                dl:AddLine(ImVec2(prev[1], prev[2]), ImVec2(c[1], c[2]), 0xE06ED6FF, 2.6 * MDS)
                dl:AddCircleFilled(ImVec2(c[1], c[2]), 2.4 * MDS, 0xF0FFFFFF, 8)
                lines = lines + 1
            end
            prev = c
        end
    end

    if now - (internal.helixDbgT or 0) > 5 then
        internal.helixDbgT = now
        dbg(('path v27: style=%s segs=%d total=%.1f m centers=%d lines=%d fmax=%.2f fallback=%s jitoff=%s'):format(
            cfg.pathRibbon ~= false and 'ribbon' or 'helix', #seg, total, valid, lines, fmax,
            tostring(fallback), tostring(internal.jitOff)))
    end
end

internal.jitOff = pcall(function() jit.off(internal.fxPathHelix, true) end)

imgui.OnFrame(function() return cfg.render and not menuOpen[0] end, function(self)
    self.HideCursor = true
    local ok, px, py, pz = pcall(getCharCoordinates, PLAYER_PED)
    if not ok then return end
    local cx, cy, cz = getActiveCameraCoordinates()
    local lx, ly, lz = getActiveCameraPointAt()
    local fx, fy, fz = lx - cx, ly - cy, lz - cz
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 0.001 then return end
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    local pj = internal.pj
    if not pj then pj = {ok = 0, behind = 0, cfail = 0, raw = '-', t = 0}; internal.pj = pj end
    local function proj(wx, wy, wz)
        local vx, vy, vz = wx - cx, wy - cy, wz - cz
        local vl = math.sqrt(vx * vx + vy * vy + vz * vz)
        if vl < 0.001 then return end
        local dot = (vx * fx + vy * fy + vz * fz) / vl
        if dot <= 0.02 then pj.behind = pj.behind + 1; return end
        local r1, r2, r3 = convert3DCoordsToScreen(wx, wy, wz)
        local sx, sy = r1, r2
        if type(r1) == 'boolean' then
            if not r1 then pj.cfail = pj.cfail + 1; pj.raw = ('false d=%.1f dot=%.2f'):format(vl, dot); return end
            sx, sy = r2, r3
        end
        if type(sx) ~= 'number' or type(sy) ~= 'number' then
            pj.cfail = pj.cfail + 1
            pj.raw = ('%s,%s d=%.1f dot=%.2f'):format(tostring(r1), tostring(r2), vl, dot)
            return
        end
        pj.ok = pj.ok + 1
        return sx, sy
    end
    local dl = imgui.GetForegroundDrawList()
    local now = os.clock()
    if st.path and now - pj.t > 5 then
        pj.t = now
        dbg(('proj: ok=%d behind=%d cfail=%d last_fail=%s | cam=%.1f,%.1f,%.1f dir=%.2f,%.2f,%.2f me=%.1f,%.1f,%.1f'):format(
            pj.ok, pj.behind, pj.cfail, pj.raw, cx, cy, cz, fx, fy, fz, px, py, pz))
        pj.ok, pj.behind, pj.cfail = 0, 0, 0
    end
    local t = st.target or st.dest
    if st.path then
        internal.dbgOnce('world path', ('build 15: pathHelix=%s renderPath=%s flies=%s pts=%d'):format(
            tostring(cfg.pathHelix), tostring(cfg.renderPath), tostring(cfg.pathFlies), #st.path))
    end
    local mx, my = proj(px, py, pz)

    for i, l in ipairs(st.nearFree or {}) do
        local isT = t and math.abs(l.x - t.x) < 0.5 and math.abs(l.y - t.y) < 0.5
        if not isT then
            local sx, sy = proj(l.x, l.y, l.gz + 0.1)
            if sx then
                dl:AddCircleFilled(ImVec2(sx, sy), 3 * MDS, cu(C.LEAF, 0.9), 12)
                dl:AddCircle(ImVec2(sx, sy), 3 * MDS, 0x60000000, 12, 1)
            end
            if cfg.fxGround then
                local u = (now * 0.9 + i * 0.37) % 1
                internal.fxRing(dl, proj, l.x, l.y, l.gz + 0.08, 0.45, internal.FX_MINT, 0.6, 2 * MDS, 24)
                internal.fxRing(dl, proj, l.x, l.y, l.gz + 0.08, 0.45 + 0.7 * u, internal.FX_MINT, 0.7 * (1 - u), 2 * MDS, 24)
            end
        end
    end

    if t and t.gz and mx then
        local tx, ty = proj(t.x, t.y, t.gz + 0.1)
        if tx then
            if cfg.pathComet ~= false or cfg.pathFlies ~= false or cfg.pathHelix ~= false then
                if not (cfg.renderPath and st.path) then
                    internal.fxPathHelixSafe(dl, proj, {{t.x, t.y, t.gz - 0.1}}, 1, px, py, pz, now, cx, cy, cz)
                end
            else
                local SEG, ax, ay = 14, mx, my
                for i = 1, SEG do
                    local k = i / SEG
                    local bx, by = mx + (tx - mx) * k, my + (ty - my) * k
                    local a = 0.22 + 0.63 * k
                    dl:AddLine(ImVec2(ax, ay), ImVec2(bx, by), cu(C.WOOD, a * 0.30), 6 * MDS)
                    dl:AddLine(ImVec2(ax, ay), ImVec2(bx, by), cu(C.WOOD, a), 2 * MDS)
                    ax, ay = bx, by
                end
                local k = (now * 0.9) % 1
                dl:AddCircleFilled(ImVec2(mx + (tx - mx) * k, my + (ty - my) * k), 3.5 * MDS, cu(ImVec4(1, 0.88, 0.6, 0.85)), 12)
            end
            dl:AddCircleFilled(ImVec2(tx, ty), 4 * MDS, 0xFFFFFFFF, 12)
            dl:AddCircleFilled(ImVec2(tx, ty), 2.5 * MDS, cu(C.WOOD), 12)
            if cfg.fxGround then
                local gz = t.gz + 0.08
                internal.fxRune(dl, proj, t.x, t.y, gz, 0.8, -now * 1.4, internal.FX_GOLD, 0.9)
                for k = 0, 1 do
                    local u = (now * 0.8 + k * 0.5) % 1
                    internal.fxRing(dl, proj, t.x, t.y, gz, 0.8 + 0.6 * u, internal.FX_GOLD, 0.8 * (1 - u), 2 * MDS, 28)
                end
                internal.fxPillar(dl, proj, t.x, t.y, gz, internal.FX_MINT, 0.9, now)
            end
            local label = ('%dm'):format(math.floor(getDistanceBetweenCoords2d(px, py, t.x, t.y) + 0.5))
            dl:AddText(ImVec2(tx + 9 * MDS + 1, ty - 18 * MDS + 1), 0xB0000000, label)
            dl:AddText(ImVec2(tx + 9 * MDS, ty - 18 * MDS), 0xF0FFFFFF, label)
        end
    end

    if cfg.renderPath and st.path then
        if cfg.pathComet ~= false or cfg.pathFlies ~= false or cfg.pathHelix ~= false then
            internal.fxPathHelixSafe(dl, proj, st.path, st.pathIdx, px, py, pz, now, cx, cy, cz)
        else
            local prev
            for i = st.pathIdx or 1, #st.path do
                local q = st.path[i]
                local sx, sy = proj(q[1], q[2], (q[3] or pz - 0.9) + 0.1)
                local p = sx and ImVec2(sx, sy)
                if p and prev then dl:AddLine(prev, p, cu(C.WOODD, 0.45), 1.5 * MDS) end
                if p then dl:AddCircleFilled(p, 2.2 * MDS, cu(C.WOODD, 0.7), 8) end
                prev = p
            end
        end
    end

    if cfg.fxTrail ~= false and running then
        local TL = 1.7
        local tr = internal.trail
        if not tr then tr = {}; internal.trail = tr end
        local lastP = tr[#tr]
        local ddx, ddy = lastP and (px - lastP.x) or 99, lastP and (py - lastP.y) or 99
        local d2 = ddx * ddx + ddy * ddy
        if d2 > 225 and lastP then
            for i = #tr, 1, -1 do tr[i] = nil end
            lastP = nil
        end
        if not lastP or d2 > 0.1225 then tr[#tr + 1] = {x = px, y = py, z = pz - 0.92, t = now} end
        while tr[1] and now - tr[1].t > TL do table.remove(tr, 1) end
        local G, M = internal.FX_GOLD, internal.FX_MINT
        local qx, qy = proj(px, py, pz - 0.92)
        local lx, ly = qx, qy
        for i = #tr, 1, -1 do
            local p = tr[i]
            local f = 1 - (now - p.t) / TL
            local sx, sy = proj(p.x, p.y, p.z)
            if sx and lx then
                local u = 1 - f
                local col = {G[1] + (M[1] - G[1]) * u, G[2] + (M[2] - G[2]) * u, G[3] + (M[3] - G[3]) * u}
                local a = f * f
                dl:AddLine(ImVec2(lx, ly), ImVec2(sx, sy), internal.fxCol(col, a * 0.22), (9 * f + 2) * MDS)
                dl:AddLine(ImVec2(lx, ly), ImVec2(sx, sy), internal.fxCol(col, a * 0.9), (3.2 * f + 0.8) * MDS)
                if i % 3 == 0 then dl:AddCircleFilled(ImVec2(sx, sy), (1.8 * f + 0.4) * MDS, internal.fxCol({1, 1, 1}, a * 0.8), 8) end
            end
            lx, ly = sx, sy
        end
    elseif internal.trail then
        internal.trail = nil
    end

    if t and mx then
        dl:AddCircleFilled(ImVec2(mx, my), 6 * MDS, 0xFFFFFFFF, 16)
        dl:AddCircleFilled(ImVec2(mx, my), 5 * MDS, cu(C.WOODD), 16)
    end
end)

local AA_RESUME_DELAY = 420

local otvet_1 = {
    "/b тута я тута", "/b да я тута", "/b ну?", "/b да щас гляну", "/b ну тут я",
    "/b я на месте", "/b а что такое", "/b да, тут я", "/b +++", "/b на месте",
    "/b тут", "/b ну блин(", "/b да,тут я", "/b опа тут, а что", "/b да слушаю, ну",
    "/b я в игре", "/b ага", "/b tyt", "/b а я не понял,что там", "/b аэф",
    "/b приветствую", "/b а что там?", "/b а что, что?", "/b да тут", "/b слушаю",
    "/b daaaa", "/b na meste", "/b ya tyt", "/b да тут я никуда", "/b ну тут, а что",
    "/b так тут я корч", "/b да я тут", "/b тута я", "/b ну да, а что", "/b тут, минуту",
    "/b ну тут, секунду", "/b да, а что", "/b да я тут просто отойд, а что",
    "/b я тут уже, что такое", "/b da tyt", "/b na meste ya", "/b im tyta",
    "/b тут я корче", "/b ну да, я тут сижу", "/b тут, что хотел", "/b да на месте, а что",
    "/b ну тут я сижу, жду", "/b ну тут я"
}
local otvet_2 = {
    "/b я не афк просто думал, не отвечал, извини",
    "/b я отходил на 15 секунд, ну",
    "/b ну я тут был всё время, ну",
    "/b связь барахлит, не сразу",
    "/b 1%, простоя лаг",
    "/b пишу с телефона, не успел",
    "/b пинг 5 тысяч у меня, и игра так лагает",
    "/b прости завис на чуть, но я тут",
    "/b 2%, да не афк я никакой",
    "/b да тут я, смотрел чуть не туда",
    "/b писал друг и я отвлёкся",
    "/b не сразу заметил сообщение",
    "/b ну прости, долго писал ответ тебе",
    "/b да смотрю видео в дургом окне",
    "/b телефон в дургой руке держал, извини",
    "/b телека на фоне был и отвлёкся",
    "/b извини, засмотрелся в окно",
    "/b ну да, чуть тупонул, бывает",
    "/b там за окном шум был и отвлёкся",
    "/b руку занёс чтобы ответить",
    "/b извини, задумался просто",
    "/b с друзьями спорил по голосу",
    "/b сушил кушать, потом писал",
    "/b телефон зазвонил и отвлёкся",
    "/b чуть не успел на самом деле"
}

local AI_CLASSIFY = 'Ты — фильтр сообщений на русском SAMP RP сервере. Тебе приходит одно сообщение от администратора из игрового чата. '
    .. 'Реши, обращается ли админ ЛИЧНО к этому игроку и требует ли это сообщение ответа. '
    .. 'Личное обращение — это когда админ проверяет именно тебя: спрашивает "ты тут?", "ответь", обращается по нику, телепортировал лично тебя, ответил лично тебе на твой вопрос. '
    .. 'Массовое объявление — это глобальные события и мероприятия (МП, рулетка, розыгрыш), реклама, премии, набор на работу, "Уважаемые игроки", объявления для всех — такие сообщения НЕ требуют ответа. '
    .. 'Ответь СТРОГО одним английским словом без знаков препинания и пояснений: YES — если это личное обращение к игроку, требующее ответа; NO — если это массовое объявление/событие и отвечать не нужно.'

local AI_SYSTEM = 'Ты — обычный живой игрок на русском SAMP RP сервере, прямо сейчас рубишь деревья на лесопилке. '
    .. 'Иногда администратор пишет тебе в чат, чтобы проверить, что ты не бот. Ответь максимально естественно, коротко и '
    .. 'по-человечески, как настоящий игрок. Пиши простым разговорным языком, маленькими буквами, обычно без точки в конце, '
    .. 'допускаются лёгкие опечатки и сленг. Не используй кавычки, не пиши пояснений — выдавай только сам текст ответа одной '
    .. 'короткой фразой до 100 символов. Если спрашивают конкретное (пример, возраст, город, что делаешь) — отвечай правдоподобно.'


ai = {
    testBusy = false, askBusy = false, modelsBusy = false,
    testOk = false, testMsg = "", testAnswer = "", testLog = {},
    askReply = "", models = {}, modelsMsg = "",
    lastAdminName = "", lastAdminMsg = "",
    enabled = false, provider = 0,
    keyClaude = "", keyOpenAI = "", keyGemini = "", keyGroq = "",
    apiKey = "", endpoint = "https://api.openai.com/v1",
    model = "", system = "",
    DEFAULT_SYSTEM  = u8(AI_SYSTEM),
    CLASSIFY_SYSTEM = u8(AI_CLASSIFY),
    DEAD_MODELS = {
        ["llama-3.1-70b-versatile"]  = true,
        ["llama-3.3-70b-versatile"]  = true,
        ["mixtral-8x7b-32768"]       = true,
        ["llama3-8b-8192"]           = true,
        ["llama3-70b-8192"]          = true,
        ["llama-3.1-8b-instant"]     = true,
        ["llama-3.3-70b-specdec"]    = true,
    },
    GROQ_MODEL = "openai/gpt-oss-120b",
}
SJ = {
    "Администратор",
    "Администратор не по делу",
    "Ответьте мне:",
}
local AA_BROADCAST = {
    "МП", "Приз", "приз", "Уважаем", "Объявлен", "объявлен",
    "розыгрыш", "рулетк", "мероприяти", "Глобальн", "глобальн",
    "/gotp", "преми", "ивент", "event", "акци", "Конкурс", "конкурс",
    "Принимаем", "набор",
}

local aa = {
    replying = false, angry = 0,
    lastTrigger = 0, stopTime = 0,
    resumeAt = 0, enabledAt = 0,
}
--оповещения
local function aaArmed() return running and os.clock() - aa.enabledAt >= 5 end
function aaStart() aa.enabledAt, aa.resumeAt = os.clock(), 0 end

local function aaMsg(t)
    sampAddChatMessage(ai.fromU8("{FF6666}[AA] {FFFFFF}" .. t), -1)
    pcall(internal.toast, '{FF6666}' .. t)
end

local function aaSound()
    if not cfg.aaSound then return end
    for _ = 1, 3 do pcall(addOneOffSound, 0, 0, 0, 1139); wait(200) end
end

function internal.aaAlert(sec)
    local now = os.clock()
    if now >= (internal.alertUntil or 0) then internal.alertT0 = now end
    internal.alertUntil = math.max(internal.alertUntil or 0, now + sec)
end

imgui.OnFrame(function() return cfg.aaAlert ~= false and os.clock() < (internal.alertUntil or 0) end, function(self)
    self.HideCursor = true
    local now = os.clock()
    local fin = math.min(1, (now - (internal.alertT0 or now)) / 0.2)
    local fout = math.min(1, (internal.alertUntil - now) / 0.8)
    local k = fin * fout
    local pulse = 0.5 + 0.5 * math.sin(now * 7)
    local a = k * (0.35 + 0.45 * pulse)
    local sw, sh = screenSize()
    local dl = imgui.GetForegroundDrawList()
    local th = 110 * S
    local red = ImVec4(1, 0.12, 0.1, 1)
    local c0, c1 = cu(red, a), cu(red, 0)
    dl:AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(sw, th), c0, c0, c1, c1)
    dl:AddRectFilledMultiColor(ImVec2(0, sh - th), ImVec2(sw, sh), c1, c1, c0, c0)
    dl:AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(th, sh), c0, c1, c1, c0)
    dl:AddRectFilledMultiColor(ImVec2(sw - th, 0), ImVec2(sw, sh), c1, c0, c0, c1)
    dl:AddRect(ImVec2(2, 2), ImVec2(sw - 2, sh - 2), cu(red, math.min(1, a * 1.6)), 0, 0, 3 * S)
    pf(F.header)
    local label = u8('АНТИ-АДМИН')
    local ts = imgui.CalcTextSize(label)
    local lx, ly = (sw - ts.x) / 2, 16 * S
    dl:AddText(ImVec2(lx + 1, ly + 1), cu(ImVec4(0, 0, 0, 1), k * 0.7), label)
    dl:AddText(ImVec2(lx, ly), cu(ImVec4(1, 0.9, 0.9, 1), k * (0.6 + 0.4 * pulse)), label)
    pp(F.header)
end)

local function aaStop(reason)
    aa.lastTrigger = os.clock()
    if not running then return end
    toggleBot()
    aaMsg("АНТИ-АДМИН: " .. reason)
    pcall(internal.aaAlert, 8)
    lua_thread.create(aaSound)
    if cfg.aaQuit then
        lua_thread.create(function() wait(2000); os.exit(1) end)
    elseif cfg.aaResume then
        aa.stopTime, aa.resumeAt = os.clock(), os.clock() + AA_RESUME_DELAY
        aaMsg("автозапуск через 7 минут, если будет тихо")
    end
end

function ai.fromU8(s)
    if not s then return s end
    local ok, r = pcall(function() return u8:decode(s) end)
    return ok and r or s
end

function ai.toU8(s)
    if not s then return s end
    local ok, r = pcall(function() return u8:encode(s) end)
    return ok and r or s
end

function ai.jsonEscape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    s = s:gsub("[%z\1-\8\11\12\14-\31]", function(c) return string.format("\\u%04x", string.byte(c)) end)
    return s
end

function ai.pickModel(m)
    if not m or m == "" or ai.DEAD_MODELS[m] then return ai.GROQ_MODEL end
    return m
end

function ai.activeKey() return ai.apiKey or "" end

function ai.save()
    cfg.aiKey      = ai.apiKey
    cfg.aiEndpoint = ai.endpoint
    cfg.aiModel    = ai.model
    cfg.aiSystem   = ai.system
    cfg.aiEnabled  = ai.enabled
    saveCfg()
end

function ai.copasRequest(fn)
    local done = { ok = false }
    if _copas_ok and _copas and _copas.addthread then
        _copas.addthread(function()
            local a,b,c,d,e = pcall(fn)
            done.ok = true
            done.res = { a, b, c, d, e }
        end)
        while not done.ok do
            if _copas.step then pcall(_copas.step, 0.05) end
            wait(0)
        end
    else
        local a,b,c,d,e = pcall(fn)
        done.res = { a, b, c, d, e }
    end
    local r = done.res
    return r[1], r[2], r[3], r[4], r[5]
end

function ai.buildPrompt(msgText, adminName)
    local head
    if adminName and adminName ~= "" then
        head = u8("Администратор ") .. ai.toU8(adminName) .. u8(" пишет мне в чат: ")
    else
        head = u8("Пишет админ мне в чат: ")
    end
    return head .. (msgText or "") .. u8("\nОтветь коротко и по-человечески, как игрок будет писать.")
end

function ai.extractAdminName(textU8)
    if not textU8 then return "" end
    local name = textU8:match("Администратор%s+([%w_%[%]%(%)]+)") or textU8:match("([%w_%[%]]+)%s+пишет")
    if name then
        local clean = name:gsub("%[%d+%]", ""):gsub("[%(%)%[%]]", "")
        if #clean >= 3 then return clean end
    end
    return ""
end

function ai.requestChat(messages, systemText, cb)
    if not systemText or systemText == "" then systemText = ai.DEFAULT_SYSTEM end
    lua_thread.create(function()
        local result = { pcall(function()
            if not _requests_ok or not _requests then
                return false, "http lib missing"
            end
            local arr = { { role = "system", content = ai.toU8(systemText) } }
            for _, m in ipairs(messages) do
                arr[#arr + 1] = {
                    role    = m.role == "assistant" and "assistant" or "user",
                    content = ai.toU8(m.text),
                }
            end
            local url = (ai.endpoint ~= "" and ai.endpoint or "https://api.openai.com/v1"):gsub("/+$", "")
            if not url:match("/chat/completions$") then
                url = url .. "/chat/completions"
            end
            local model = ai.pickModel(ai.model ~= "" and ai.model or "gpt-4o-mini")
            local body = encodeJson({
                model      = model,
                messages   = arr,
                max_tokens = 220,
                temperature = 0.8,
            })
            local resp = {}
            local r_ok, r_code, r_headers, r_status = ai.copasRequest(function()
                return _requests.request({
                    url    = url,
                    method = "POST",
                    headers = {
                        ["Content-Type"]   = "application/json",
                        ["Content-Length"] = #body,
                        Authorization      = "Bearer " .. ai.apiKey,
                    },
                    source = require("ltn12").source.string(body),
                    sink   = require("ltn12").sink.table(resp),
                    timeout = { connect = 15, send = 15, receive = 20 },
                })
            end)
            if not r_ok or r_code ~= 1 then
                return false, "net error " .. tostring(r_status or ""):sub(1, 60)
            end
            local code = r_headers or 0
            local text = table.concat(resp)
            if code ~= 200 then
                return false, "HTTP " .. tostring(code) .. ": " .. text:sub(1, 80)
            end
            local j = decodeJson(text)
            local m = j and j.choices and j.choices[1] and j.choices[1].message and j.choices[1].message.content
            if type(m) ~= "string" or m == "" then
                return false, "empty reply"
            end
            return true, m
        end) }
        if not result[1] then
            cb(false, tostring(result[2]))
            return
        end
        cb(result[2], result[3])
    end)
end

function ai.request(userText, systemText, cb)
    ai.requestChat({ { role = "user", text = userText } }, systemText, cb)
end

function ai.classifyAdmin(textCp, cb)
    if not ai.enabled or ai.activeKey() == "" then cb(nil); return end
    ai.request(textCp or "", ai.CLASSIFY_SYSTEM, function(ok, ans)
        if not ok or not ans then cb(nil); return end
        local up = tostring(ans):upper()
        if up:find("YES") then cb(true)
        elseif up:find("NO") then cb(false)
        else cb(nil) end
    end)
end

function ai.testSignal()
    if ai.testBusy then return end
    if ai.activeKey() == "" then
        ai.testOk = false; ai.testMsg = "Нет ключа"; return
    end
    ai.testBusy = true; ai.testOk = false; ai.testMsg = "Загрузка..."
    ai.request("ping", "Reply with one short word.", function(ok, ans)
        ai.testBusy = false; ai.testOk = ok
        ai.testMsg = ok and "Ключ рабочий" or (ai.fromU8("Ошибка: " .. tostring(ans):sub(1, 60)))
    end)
end

function ai.fetchModels()
    if ai.modelsBusy then return end
    if not _requests_ok or not _requests then ai.modelsMsg = "Нет requests lib"; return end
    if ai.apiKey == "" then ai.modelsMsg = "Нет ключа"; return end
    ai.modelsBusy = true; ai.modelsMsg = "Загрузка..."; ai.models = {}
    lua_thread.create(function()
        local ok = pcall(function()
            local url = ai.endpoint:gsub("/+$", ""):gsub("/chat/completions%s*$", "") .. "/models"
            local resp = {}
            local r_ok, r_code, r_headers, r_status = ai.copasRequest(function()
                return _requests.request({
                    url = url, method = "GET",
                    headers = { Authorization = "Bearer " .. ai.apiKey },
                    sink = require("ltn12").sink.table(resp),
                    timeout = { connect = 15, send = 15, receive = 15 },
                })
            end)
            if not r_ok or r_code ~= 1 then
                ai.modelsMsg = ai.fromU8("net error " .. tostring(r_status or ""):sub(1, 50)); return
            end
            if (r_headers or 0) ~= 200 then
                ai.modelsMsg = ai.fromU8("HTTP " .. tostring(r_headers or 0)); return
            end
            local j = decodeJson(table.concat(resp))
            for _, item in ipairs(j and j.data or {}) do
                local id = item.id or item.name
                if type(id) == "string" then ai.models[#ai.models + 1] = id end
            end
            table.sort(ai.models)
            ai.modelsMsg = "Найдено: " .. #ai.models
        end)
        if not ok then ai.modelsMsg = "Ошибка" end
        ai.modelsBusy = false
    end)
end

function ai.ask(textUtf8)
    if ai.askBusy then return end
    if not textUtf8 or textUtf8 == "" then ai.askReply = "Пустой вопрос"; return end
    if ai.apiKey == "" then ai.askReply = "Нет ключа"; return end
    ai.askBusy = true; ai.askReply = "..."
    ai.request(ai.buildPrompt(ai.fromU8(textUtf8), ai.lastAdminName or ""), ai.system, function(ok, ans)
        ai.askBusy = false
        if ok and ans then
            local clean = ai.fromU8(ans):gsub("[\r\n]+", " "):gsub("^[%s%p]+", ""):gsub("[%s%p]+$", "")
            if #clean > 100 then clean = clean:sub(1, 100) end
            ai.askReply = "/b " .. clean
        else
            ai.askReply = "Ошибка: " .. tostring(ans)
        end
    end)
end

local function aaIsAdminMsg(text)
    for _, w in ipairs(SJ) do if text:find(w, 1, true) then return true end end
    return false
end

local function aaQuickAnswer(q)
    if not q then return nil end
    if q:find("ты тут", 1, true) or q:find("ты тут?", 1, true)
       or q:find("ты здесь", 1, true) or q:find("ты здесь?", 1, true)
       or q:find("ответь", 1, true) or q:find("тут?", 1, true) then
        local a = { "тут", "да, тут", "да, здесь", "здесь я", "я тут", "да, тута" }
        return a[math.random(#a)]
    end
    local n1, op, n2 = q:match("(%d+)%s*([%+%-%*/])%s*(%d+)")
    if n1 and op and n2 then
        local a, b = tonumber(n1), tonumber(n2)
        local r = op=="+" and a+b or op=="-" and a-b or op=="*" and a*b or
                  (op=="/" and b~=0 and math.floor(a/b*100+0.5)/100 or nil)
        if r then return tostring(r) end
    end
    if q:find("лет", 1, true) or q:find("возраст", 1, true) then
        local a = { "19", "21", "20", "22", "23" }
        return a[math.random(#a)]
    end
    if q:find("город", 1, true) or q:find("откуда", 1, true) then
        local a = { "москва", "спб", "казань", "уфа" }
        return a[math.random(#a)]
    end
    if q:find("делаешь", 1, true) or q:find("занимаешься", 1, true) then
        local a = { "Работаю", "копки коп", "копаю", "копки шах" }
        return a[math.random(#a)]
    end
    return nil
end

local function aaLooksDirected(text)
    local u = ai.fromU8(text)
    if u:find("ответил вам", 1, true) or u:find("телепортировал вас", 1, true) then
        return true
    end
    local nick = ""
    pcall(function()
        local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if ok then nick = sampGetPlayerNickname(id) or "" end
    end)
    if nick ~= "" and #nick >= 3 and text:lower():find(nick:lower(), 1, true) then
        return true
    end
    for _, w in ipairs(AA_BROADCAST) do
        if u:find(w, 1, true) then return false end
    end
    return true
end

local function aiReplyCore(question)
    if aa.replying or aa.angry >= 2 then return end
    aa.replying = true; aa.angry = aa.angry + 1
    local adminName = ai.extractAdminName(question or "") or ""
    if ai.enabled and ai.activeKey() ~= "" and question and question ~= "" then
        ai.request(ai.buildPrompt(question, adminName), ai.system,
            function(ok, ans)
                local msg
                if ok and ans and ans ~= "" then
                    local clean = ai.fromU8(ans)
                        :gsub("[\r\n]+", " ")
                        :gsub("^[\"']+%s*", "")
                        :gsub("[\"']+%s*$", "")
                    if clean:sub(1, 3) == "/b " then clean = clean:sub(4) end
                    if #clean > 100 then clean = clean:sub(1, 100) end
                    if clean ~= "" then msg = "/b " .. clean end
                end
                if not msg then
                    local qa = aaQuickAnswer(question)
                    if qa then msg = "/b " .. qa
                    elseif aa.angry == 1 then msg = otvet_1[math.random(#otvet_1)]
                    else msg = otvet_2[math.random(#otvet_2)] end
                end
                ai.askReply = msg
                dbg("AI preview ready")
                aa.replying = false
            end)
        return
    end
    local qa = aaQuickAnswer(question)
    ai.askReply = qa and ("/b " .. qa)
             or (aa.angry == 1 and otvet_1[math.random(#otvet_1)]
                                or otvet_2[math.random(#otvet_2)])
    dbg("AI fallback preview ready")
    aa.replying = false
end

local function aaReply(question) aiReplyCore(question) end

function aaOnChat(text)
    local clean = text:gsub("{%x%x%x%x%x%x}", "")
    if aa.angry > 0 and os.clock() - aa.lastTrigger > 300 then aa.angry = 0 end
    if not aaArmed() then return end
    local cleanU8 = ai.toU8(clean)
    if not aaIsAdminMsg(cleanU8) then return end
    pcall(internal.aaAlert, 5)
    if cfg.aaStopChat and (cleanU8:find("ты тут", 1, true) or cleanU8:find("ты здесь", 1, true)) then
        aaStop("проверка в чате"); return
    end
    if not cfg.aaReply or aa.replying or aa.angry >= 2 then return end
    if ai.enabled and ai.activeKey() ~= "" then
        ai.classifyAdmin(clean, function(isPersonal)
            if isPersonal == nil then isPersonal = aaLooksDirected(cleanU8) end
            if not isPersonal then return end
            aa.lastTrigger = os.clock()
            ai.lastAdminMsg = clean
            if cfg.aaSound then lua_thread.create(aaSound) end
            aiReplyCore(clean)
        end)
    else
        if not aaLooksDirected(cleanU8) then return end
        aa.lastTrigger = os.clock()
        ai.lastAdminMsg = clean
        if cfg.aaSound then lua_thread.create(aaSound) end
        aiReplyCore(clean)
    end
end

function aaOnDialog(id, title, text)
    if not aaArmed() then return end
    if cfg.aaStopDialog then aaStop('диалог от сервера (' .. id .. ')') end
end

function sampev.onSetPlayerPos(p)
    if not (aaArmed() and cfg.aaStopTp) or os.clock() < (st.tpGraceUntil or 0) then return end
    local x, y, z = getCharCoordinates(PLAYER_PED)
    if z > 900 or p.z > 900 then return end
    if getDistanceBetweenCoords3d(x, y, z, p.x, p.y, p.z) >= 15 then aaStop('телепорт сервером') end
end

lua_thread.create(function()
    while true do
        wait(1000)
        if aa.resumeAt > 0 then
            if running then aa.resumeAt = 0
            elseif os.clock() >= aa.resumeAt then
                if aa.lastTrigger > aa.stopTime then aa.stopTime, aa.resumeAt = aa.lastTrigger, aa.lastTrigger + AA_RESUME_DELAY
                elseif sampIsDialogActive() then aa.resumeAt = os.clock() + 60
                else aa.resumeAt = 0; msg('угроза миновала - запускаюсь снова'); toggleBot() end
            end
        end
    end
end)

local aiTest = {busy = false, text = ''}
local function aiTestRun()
    if aiTest.busy then return end
    aiTest.busy, aiTest.text = true, 'жду ответ...'
    lua_thread.create(function()
        local t0 = os.clock()
        ai.request(ai.buildPrompt('ты тут? ответь', 'Test'), ai.DEFAULT_SYSTEM, function(ok, txt)
            aiTest.text = ok and (('%.1f с: %s'):format(os.clock() - t0, txt)) or ('ошибка: ' .. txt)
        end)
        aiTest.busy = false
    end)
end

local anim = {}
local dt = 0.016
local function approach(key, target, speed)
    local v = anim[key] or target
    v = v + (target - v) * (1 - math.exp(-(speed or 14) * dt))
    if math.abs(v - target) < 0.01 then v = target end
    anim[key] = v
    return v
end

function internal.wall()
    local ok, t = pcall(imgui.GetTime)
    if ok and type(t) == 'number' then return t end
    return os.clock()
end

internal.tickDt = function()
    if menuOpen[0] then return end
    local n = os.clock()
    local d = n - (internal.dtT or n)
    if d >= 0.004 then
        internal.dtT = n
        if d <= 0.1 then dt = d end
    elseif not internal.dtT then
        internal.dtT = n
    end
end

local scroll = {vel = 0, tracking = false, moved = false, startX = 0, startY = 0, lastY = 0,
    y = 0, max = 0, set = nil, dbgN = 0}
local touchLock = {on = false}

--интерфейс
local function woodPanel(dl, x0, y0, x1, y1)
    if not TEX.panel then
        dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), cu(C.PLANK), 14 * S)
        dl:AddRect(ImVec2(x0, y0), ImVec2(x1, y1), cu(C.WOOD), 14 * S, 0, 2 * S)
        return
    end
    local TW, TH, B, b = 701, 264, 26, 22 * S
    local xs, ys = {x0, x0 + b, x1 - b, x1}, {y0, y0 + b, y1 - b, y1}
    local us, vs = {0, B / TW, 1 - B / TW, 1}, {0, B / TH, 1 - B / TH, 1}
    for i = 1, 3 do for j = 1, 3 do
        dl:AddImage(TEX.panel, ImVec2(xs[i], ys[j]), ImVec2(xs[i + 1], ys[j + 1]), ImVec2(us[i], vs[j]), ImVec2(us[i + 1], vs[j + 1]))
    end end
end

local function glossy(dl, x0, y0, x1, y1, base, r, k, noBorder)
    local c = mix(base, C.TEXT, 0.12 * (k or 0))
    dl:AddRectFilled(ImVec2(x0, y0 + 3 * S), ImVec2(x1, y1 + 3 * S), cu(ImVec4(0, 0, 0, 0.35)), r)
    dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), cu(c), r)
    dl:AddRectFilled(ImVec2(x0 + 3 * S, y0 + 3 * S), ImVec2(x1 - 3 * S, y0 + (y1 - y0) * 0.46), cu(C.TEXT, 0.13), r * 0.8)
    if not noBorder then dl:AddRect(ImVec2(x0, y0), ImVec2(x1, y1), cu(mix(c, C.TEXT, 0.35), 0.8), r, 0, 1.5 * S) end
end

local function outlined(dl, x, y, col, text, font)
    pf(font)
    local ox, up, dn = 3.6 * S, 3.4 * S, 2.2 * S
    local dark = ImVec4(0.18, 0.07, 0.02, 1)
    for _, d in ipairs({{-ox, 0}, {ox, 0}, {0, -up}, {0, dn}, {-ox, -up}, {ox, -up}, {-ox, dn}, {ox, dn},
        {-ox * 0.5, -up}, {ox * 0.5, -up}, {-ox * 0.5, dn}, {ox * 0.5, dn}}) do
        dl:AddText(ImVec2(x + d[1], y + d[2]), cu(dark, 0.42), text)
    end
    dl:AddText(ImVec2(x, y + 2 * S), cu(ImVec4(0.55, 0.28, 0.08, 1), 0.7), text)
    dl:AddText(ImVec2(x, y), cu(col), text)
    pp(font)
end

local function badge(dl, x0, y0, x1, y1, r) dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), cu(C.BADGE), r or 10 * S) end

local function section(text, icon)
    imgui.Dummy(ImVec2(0, 4 * S))
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    pf(F.header)
    local th = imgui.GetTextLineHeight()
    if faOK and icon == internal.AXE then internal.drawAxe(dl, p.x + 13 * S, p.y + th / 2, 24 * S, cu(C.GOLD))
    elseif faOK and icon then dl:AddText(ImVec2(p.x, p.y), cu(C.GOLD), icon) end
    local ix = faOK and icon and 30 * S or 0
    dl:AddText(ImVec2(p.x + ix, p.y), cu(C.GOLD), u8(text:upper()))
    local tw = imgui.CalcTextSize(u8(text:upper())).x
    local w = imgui.GetContentRegionAvail().x
    dl:AddLine(ImVec2(p.x + ix + tw + 12 * S, p.y + th / 2), ImVec2(p.x + w, p.y + th / 2), cu(C.WOOD, 0.35), 1.5 * S)
    pp(F.header)
    imgui.Dummy(ImVec2(w, th + 4 * S))
end

local function toggle(label, key, hint)
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    local h, w = 30 * S, 58 * S
    local avail = imgui.GetContentRegionAvail().x
    local rowH = hint and 50 * S or 38 * S
    if imgui.InvisibleButton('##tg_' .. key, ImVec2(avail, rowH)) and not scroll.moved then cfg[key] = not cfg[key]; saveCfg() end
    local k = approach('tg_' .. key, cfg[key] and 1 or 0)
    local y = p.y + (hint and 2 * S or (rowH - h) / 2)
    dl:AddRectFilled(ImVec2(p.x, y), ImVec2(p.x + w, y + h), cu(mix(C.TRACK, C.LEAF, k)), h / 2)
    dl:AddRectFilled(ImVec2(p.x, y), ImVec2(p.x + w, y + h * 0.45), cu(C.TEXT, 0.10), h / 2)
    dl:AddRect(ImVec2(p.x, y), ImVec2(p.x + w, y + h), cu(ImVec4(0, 0, 0, 0.35)), h / 2, 0, 1.5 * S)
    local kx = p.x + h / 2 + (w - h) * k
    dl:AddCircleFilled(ImVec2(kx, y + h / 2 + 1.5 * S), h / 2 - 3 * S, cu(ImVec4(0, 0, 0, 0.3)), 24)
    dl:AddCircleFilled(ImVec2(kx, y + h / 2), h / 2 - 3 * S, cu(ImVec4(0.97, 0.95, 0.92, 1)), 24)
    pf(F.main)
    local tx = p.x + w + 16 * S
    local ts = imgui.CalcTextSize(u8(label))
    dl:AddText(ImVec2(tx, y + (h - ts.y) / 2), cu(C.TEXT), u8(label))
    pp(F.main)
    if hint then pf(F.small); dl:AddText(ImVec2(tx, y + h), cu(C.DIM), u8(hint)); pp(F.small) end
end

local function slider(label, key, lo, hi, scale, format)
    pf(F.main); imgui.TextColored(C.DIM, u8(label)); pp(F.main)
    anim['sl_' .. key] = anim['sl_' .. key] or imgui.new.int(cfg[key])
    local v = anim['sl_' .. key]
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x * (scale or 1))
    pf(F.main)
    if imgui.SliderInt('##sl_' .. key, v, lo, hi, format or '%d%%') then cfg[key] = v[0]; saveCfg() end
    if imgui.IsItemActive() then touchLock.on = true end
    pp(F.main)
end

local function bar(frac, mark, col, scale)
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    local w, h = imgui.GetContentRegionAvail().x * (scale or 1), 22 * S
    imgui.Dummy(ImVec2(w, h))
    dl:AddRectFilled(ImVec2(p.x, p.y), ImVec2(p.x + w, p.y + h), cu(C.TRACK), 4 * S)
    if frac > 0 then dl:AddRectFilled(ImVec2(p.x, p.y), ImVec2(p.x + w * math.min(1, frac), p.y + h), cu(col or C.LEAF), 4 * S) end
    dl:AddRectFilled(ImVec2(p.x, p.y), ImVec2(p.x + w, p.y + h * 0.4), cu(C.TEXT, 0.10), 4 * S)
    if mark then
        local mx = p.x + w * mark
        dl:AddRectFilled(ImVec2(mx - 1.5 * S, p.y - 3 * S), ImVec2(mx + 1.5 * S, p.y + h + 3 * S), cu(ImVec4(0.85, 0.12, 0.12, 1)))
    end
end

local function stat(icon, label, value, accent, w, h)
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    imgui.Dummy(ImVec2(w, h))
    badge(dl, p.x, p.y, p.x + w, p.y + h, 14 * S)
    iconAt(dl, icon, p.x + 10 * S, p.y, 34 * S, h, cu(accent or C.GOLD))
    local tx = p.x + (faOK and 52 * S or 14 * S)
    pf(F.small); dl:AddText(ImVec2(tx, p.y + 10 * S), cu(C.DIM), u8(label:upper())); pp(F.small)
    pf(F.header); dl:AddText(ImVec2(tx, p.y + h - 32 * S), cu(C.TEXT), u8(value)); pp(F.header)
end
local function statRow(items, h, scale)
    local avail = imgui.GetContentRegionAvail().x
    local gap = 12 * S
    local w = (avail - gap * (#items - 1)) / #items * (scale or 1)
    for i, it in ipairs(items) do
        if i > 1 then imgui.SameLine(0, gap) end
        stat(it[1], it[2], it[3], it[4], w, h or 72 * S)
    end
end

local function row(dl, x, y, w, h, icon, label, value, accent)
    iconAt(dl, icon, x, y, 28 * S, h, cu(accent or C.GOLD), F.main)
    pf(F.main)
    local v = u8(value); local vs = imgui.CalcTextSize(v)
    local lx = x + (faOK and 36 * S or 4 * S)
    local room = x + w - vs.x - 38 * S - lx
    local lab = label
    while #lab > 3 and imgui.CalcTextSize(u8(lab)).x > room do lab = lab:sub(1, -2) end
    if lab ~= label then lab = lab:gsub('%s+$', '') .. '...' end
    local ls = imgui.CalcTextSize(u8(lab))
    dl:AddText(ImVec2(lx, y + (h - ls.y) / 2), cu(C.TEXT), u8(lab))
    local vx = lx + ls.x + 14 * S
    badge(dl, vx, y + 3 * S, vx + vs.x + 28 * S, y + h - 3 * S, (h - 6 * S) / 2)
    dl:AddText(ImVec2(vx + 14 * S, y + (h - vs.y) / 2), cu(C.TEXT), v)
    pp(F.main)
end

local function linkButton(id, label, w, h, icon)
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    local clicked = imgui.InvisibleButton(id, ImVec2(w, h)) and not scroll.moved
    local k = approach('lb' .. id, imgui.IsItemHovered() and 1 or 0)
    dl:AddRectFilled(ImVec2(p.x, p.y), ImVec2(p.x + w, p.y + h), cu(mix(ImVec4(0.17, 0.48, 0.80, 1), C.TEXT, 0.1 * k), 1), 12 * S)
    pf(F.main)
    local ts = imgui.CalcTextSize(u8(label))
    local iw = faOK and 18 * S or 0
    local x0 = p.x + (w - ts.x - iw) / 2
    iconAt(dl, icon or IC.plane, x0, p.y, 14 * S, h, cu(C.TEXT))
    dl:AddText(ImVec2(x0 + iw, p.y + (h - ts.y) / 2), cu(C.TEXT), u8(label))
    pp(F.main)
    return clicked
end
local function themeBtn(id, label, w, h, base, onClick)
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    imgui.SetCursorScreenPos(p)
    local clicked = imgui.InvisibleButton(id, ImVec2(w, h)) and not scroll.moved
    local k = approach('tb' .. id, imgui.IsItemHovered() and 1 or 0)
    dl:AddRectFilled(ImVec2(p.x, p.y), ImVec2(p.x + w, p.y + h), cu(base or C.GREY, 1), 12 * S)
    pf(F.main)
    local ts = imgui.CalcTextSize(label)
    dl:AddText(ImVec2(p.x + (w - ts.x) / 2, p.y + (h - ts.y) / 2), cu(C.TEXT), label)
    pp(F.main)
    if clicked and onClick then onClick() end
    return clicked
end

local function themeSmallBtn(id, label, w, h, base)
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    imgui.SetCursorScreenPos(p)
    local clicked = imgui.InvisibleButton(id, ImVec2(w, h)) and not scroll.moved
    local k = approach('tsb' .. id, imgui.IsItemHovered() and 1 or 0)
    dl:AddRectFilled(ImVec2(p.x, p.y), ImVec2(p.x + w, p.y + h), cu(base or C.WOODD, 1), 8 * S)
    pf(F.small)
    local ts = imgui.CalcTextSize(label)
    dl:AddText(ImVec2(p.x + (w - ts.x) / 2, p.y + (h - ts.y) / 2), cu(C.TEXT), label)
    pp(F.small)
    return clicked
end

local ffi = require("ffi")

pcall(ffi.cdef, [[
    void _Z12AND_OpenLinkPKc(const char* link);
]])

local gtasa_loaded, gtasa = pcall(ffi.load, "GTASA")

local function openLink(url)
    if not gtasa_loaded or not gtasa or type(url) ~= "string" or url == "" then
        return false
    end

    local ok = pcall(function()
        gtasa._Z12AND_OpenLinkPKc(url)
    end)

    return ok
end

internal.urlEnc = function(s)
    return (tostring(s):gsub('[^%w%-_%.~]', function(c) return ('%%%02X'):format(c:byte()) end))
end

local function openTg(name, title, text)
    local url = 'https://t.me/' .. name
    local hasText = type(text) == 'string' and text ~= ''
    if hasText then
        url = url .. (url:find('?', 1, true) and '&' or '?') .. 'text=' .. internal.urlEnc(text)
    end

    local opened = openLink(url)
    local copied = false

    if type(setClipboardText) == 'function' then
        copied = pcall(setClipboardText, hasText and text or url)
    end

    if opened and copied then
        msg(hasText and 'открываю Telegram; текст сообщения скопирован, вставьте его в чат' or 'открываю Telegram; ссылка скопирована')
    elseif opened then
        msg('открываю Telegram')
    elseif copied then
        msg(hasText and 'не удалось открыть Telegram; текст сообщения скопирован' or 'не удалось открыть Telegram; ссылка скопирована')
    else
        msg('не удалось открыть Telegram и скопировать ссылку')
    end
end

--вкладки
local function tabMain()
    local s, sec = stats.session, sessionTime()
    local h = sec / 3600
    section('Состояние', IC.saw)
    statRow({
        {IC.saw, 'Статус', statusText(), running and C.LEAF or C.DIM},
        {IC.tree, 'Свободных деревьев', tostring(#(st.freeSides or {})), C.LEAF},
    })
    pf(F.main); imgui.TextColored(C.DIM, u8('Сытость: ' .. (st.satiety and (st.satiety .. '%') or '?'))); pp(F.main)
    bar((st.satiety or 0) / 100, cfg.eatBelow / 100, (st.satiety or 100) < cfg.eatBelow and C.EMBER or C.LEAF, 0.85)
    section('Эта сессия', IC.chart)
    statRow({{IC.clock, 'Время', hms(sec)}, {IC.dolly, 'Тележек', tostring(s.carts)}}, nil, 0.85)
    statRow({{IC.coins, 'Заработано', money(s.money), C.LEAF}, {IC.bolt, 'В час', h > 0.05 and money(s.money / h) or '-'}}, nil, 0.85)
end

local function tabSettings()
    toggle('Пропуск деревьев', 'checkTrees', 'пропускает деревья, рядом с которыми стоит другой игрок')
    section('Движение', IC.run)
    toggle('Бег', 'sprint', 'с передышками, с тележкой тоже')
    toggle('Прыжки как у игрока', 'jumps', 'с тележкой и у дерева - никогда')
    toggle('Анти-выносливость', 'antiStamina', 'поддерживает эффект и группу анимаций')
    toggle('Стрейф во время движения', 'strafe', 'переменное движение влево-вправо')
    slider('Дистанция бокового отхода при застревании', 'stuckSideMeters', 1, 10, 0.8, '%d m')
    toggle('Автоматический поиск ближайшего дерева', 'autoNearestTree', 'сам находит ближайшее свободное дерево и идёт к нему; после рубки ищет следующее')
    section('Работа', IC.saw)
    toggle('Аренда пилы у Фредерико', 'useFrederico', 'только если своей пилы нет')
    section('Рендер', IC.eye)
    toggle('Линии к деревьям', 'render', '10 ближайших свободных')
    toggle('Показывать маршрут', 'renderPath')
    toggle('Эффекты у деревьев', 'fxGround', 'кольца, рунный круг и световой столп над целью')
    toggle('Маршрут «двойная спираль»', 'pathHelix', 'золотая и мятная нити вместо коричневой линии (приоритетнее стрелок)')
    toggle('След за персонажем', 'fxTrail', 'светящийся хвост на земле, пока бот идёт')
    toggle('Трассер «комета»', 'pathComet', 'искра с хвостом бежит к цели; выключите, чтобы включить светлячков или ленту')
    toggle('Светлячки вместо ленты', 'pathFlies', 'работает, когда комета выключена')
    slider('Размер трассера', 'pathSize', 50, 250, 0.8)
    toggle('Лента маршрута', 'pathRibbon', 'от золотого к мятному, вместо двойной спирали')
    section('Окна', IC.window)
    toggle('Кнопка СТАРТ/СТОП', 'fab', 'на экране, двигается пальцем')
    toggle('Окно статистики', 'statsWin')
    imgui.Dummy(ImVec2(0, 6 * S))
    section('Анимация', IC.window)
    toggle('Плавные переходы вкладок', 'tabAnim')
    slider('Скорость переходов и появления вкладок', 'tabSpeed', 40, 300, 0.8)
    toggle('Опилки на фоне меню', 'sawdust')
    toggle('Листопад в меню', 'leaves', 'листья медленно падают за панелью')
    toggle('Анимация чисел и графика', 'numAnim')
    toggle('Уведомления в углу экрана', 'toasts')
    toggle('Кольцо вокруг аватара', 'avRing', 'на вкладке «Автор», тап по аватару ускоряет вращение')
end

local function tabFood()
    section('Автоеда', IC.food)
    toggle('Есть у ларька', 'autoEat', 'хот-дог по любой цене, пиццу - никогда')
    imgui.Dummy(ImVec2(0, 6 * S))
    pf(F.main); imgui.TextColored(C.DIM, u8('Сытость сейчас: ' .. (st.satiety and (st.satiety .. '%') or '?'))); pp(F.main)
    bar((st.satiety or 0) / 100, cfg.eatBelow / 100, (st.satiety or 100) < cfg.eatBelow and C.EMBER or C.LEAF, 0.8)
    imgui.Dummy(ImVec2(0, 8 * S))
    slider('Идти есть, если сытость ниже', 'eatBelow', 5, 90, 0.8)
    imgui.Dummy(ImVec2(0, 4 * S))
    slider('Есть до', 'eatTo', 20, 100, 0.8)
end

internal.statRows = function(s, sec, tag)
    local h = sec / 3600
    local function num(key, v)
        if not tag or cfg.numAnim == false then return v end
        local k = 'num:' .. tag .. key
        local ep = (tag == 'hud') and 0 or internal.numEpoch
        if anim[k .. 'e'] ~= ep then anim[k .. 'e'] = ep; anim[k] = 0 end
        return approach(k, v, 7)
    end
    local rows = {
        {IC.clock, 'Время', hms(sec)}, {IC.dolly, 'Тележек сдано', tostring(math.floor(num('c', s.carts) + 0.5))},
        {IC.coins, 'Заработано', money(num('m', s.money))}, {IC.bolt, 'В час', h > 0.05 and money(num('h', s.money / h)) or '-'},
    }
    local names = {}
    for name in pairs(s.items) do names[#names + 1] = name end
    table.sort(names)
    for _, n in ipairs(names) do rows[#rows + 1] = {IC.box, n, math.floor(num('i' .. n, s.items[n]) + 0.5) .. ' шт.', C.LEAF} end
    return rows
end
function internal.periodSwitch()
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    local w, h = imgui.GetContentRegionAvail().x - 8 * S, 34 * S
    local segW = w / #internal.PERIODS
    local cur = cfg.statPeriod or 'all'
    dl:AddRectFilled(ImVec2(p.x, p.y), ImVec2(p.x + w, p.y + h), cu(C.PLANK, 0.9), h / 2)
    for i, o in ipairs(internal.PERIODS) do
        local x0 = p.x + (i - 1) * segW
        imgui.SetCursorScreenPos(ImVec2(x0, p.y))
        local clk = imgui.InvisibleButton('##per' .. o[1], ImVec2(segW, h))
        local act = cur == o[1]
        if act then
            dl:AddRectFilled(ImVec2(x0 + 3 * S, p.y + 3 * S), ImVec2(x0 + segW - 3 * S, p.y + h - 3 * S), cu(C.GOLD, 0.9), (h - 6 * S) / 2)
        end
        pf(F.small)
        local lab = u8(o[2])
        local ts = imgui.CalcTextSize(lab)
        dl:AddText(ImVec2(x0 + (segW - ts.x) / 2, p.y + (h - ts.y) / 2), act and cu(C.PLANK) or cu(C.DIM), lab)
        pp(F.small)
        if clk and not act and not scroll.moved then
            cfg.statPeriod = o[1]
            internal.numEpoch = (internal.numEpoch or 0) + 1
            internal.pc = nil
            saveCfg()
        end
    end
    imgui.SetCursorScreenPos(ImVec2(p.x, p.y + h))
    imgui.Dummy(ImVec2(0, 8 * S))
end

function internal.vgrad(dl, x0, y0, x1, y1, col, a0, a1, steps)
    local h = y1 - y0
    if h < 1 or x1 <= x0 then return end
    steps = steps or 6
    if steps > h then steps = math.max(1, math.floor(h)) end
    local sh = h / steps
    for i = 0, steps - 1 do
        local t = (i + 0.5) / steps
        dl:AddRectFilled(ImVec2(x0, y0 + i * sh), ImVec2(x1, y0 + (i + 1) * sh), cu(col, a0 + (a1 - a0) * t))
    end
end

function internal.animNum(key, v)
    if cfg.numAnim == false then return v end
    local ep = internal.numEpoch or 0
    local k = 'sn:' .. key
    if anim[k .. 'e'] ~= ep then anim[k .. 'e'] = ep; anim[k] = 0 end
    return approach(k, v, 7)
end

function internal.short(v)
    local s
    if v >= 1000000 then
        s = ('%.1f'):format(v / 1000000):gsub('%.0$', '') .. 'M'
    elseif v >= 1000 then
        s = ('%.1f'):format(v / 1000):gsub('%.0$', '') .. 'k'
    else
        s = tostring(math.floor(v + 0.5))
    end
    return '$' .. s
end

function internal.niceMax(v)
    if v <= 0 then return 1 end
    local e = 10 ^ math.floor(math.log(v) / math.log(10) + 1e-9)
    local m = v / e
    local n = 10
    if m <= 1 then n = 1 elseif m <= 2 then n = 2 elseif m <= 2.5 then n = 2.5 elseif m <= 5 then n = 5 end
    return n * e
end

local function totalItems(items)
    local n = 0
    for _, c in pairs(items or {}) do n = n + c end
    return n
end

function internal.statHero(M)
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    local w, h = imgui.GetContentRegionAvail().x - 4 * S, 124 * S
    imgui.Dummy(ImVec2(w, h))
    badge(dl, p.x, p.y, p.x + w, p.y + h, 16 * S)
    dl:AddRectFilled(ImVec2(p.x, p.y + 16 * S), ImVec2(p.x + 4 * S, p.y + h - 16 * S), cu(C.GOLD), 2 * S)

    local when = {day = 'сегодня', week = 'за 7 дней', month = 'за 30 дней', all = 'за всё время'}
    pf(F.small)
    dl:AddText(ImVec2(p.x + 22 * S, p.y + 12 * S), cu(C.DIM), u8('Заработано ' .. (when[M.mode] or '')))
    pp(F.small)

    local val = money(internal.animNum('hero', M.agg.money))
    pf(F.title)
    local vs = imgui.CalcTextSize(val)
    dl:AddText(ImVec2(p.x + 22 * S + 1, p.y + 34 * S + 2), cu(ImVec4(0, 0, 0, 0.35)), val)
    dl:AddText(ImVec2(p.x + 22 * S, p.y + 34 * S), cu(C.GOLD), val)
    pp(F.title)

    local by = p.y + h - 36 * S
    local prevName = {day = 'вчера', week = 'прошлые 7 дней', month = 'прошлые 30 дней'}
    pf(F.small)
    if M.prev then
        local cur, pv = M.agg.money, M.prev.money
        if pv > 0 then
            local pct = math.floor((cur - pv) / pv * 100 + 0.5)
            local up = pct >= 0
            local col = up and C.LEAF or C.EMBER
            local txt = (up and '+' or '') .. tostring(pct) .. '%'
            local ts = imgui.CalcTextSize(txt)
            local cw = ts.x + 34 * S
            dl:AddRectFilled(ImVec2(p.x + 22 * S, by), ImVec2(p.x + 22 * S + cw, by + 24 * S), cu(col, 0.22), 12 * S)
            local tx, ty = p.x + 22 * S + 12 * S, by + 12 * S
            local a = 5 * S
            if up then
                dl:AddTriangleFilled(ImVec2(tx, ty + a * 0.6), ImVec2(tx + a * 2, ty + a * 0.6), ImVec2(tx + a, ty - a * 0.8), cu(col))
            else
                dl:AddTriangleFilled(ImVec2(tx, ty - a * 0.6), ImVec2(tx + a * 2, ty - a * 0.6), ImVec2(tx + a, ty + a * 0.8), cu(col))
            end
            dl:AddText(ImVec2(tx + a * 2 + 5 * S, by + (24 * S - ts.y) / 2), cu(col), txt)
            dl:AddText(ImVec2(p.x + 22 * S + cw + 10 * S, by + (24 * S - ts.y) / 2), cu(C.DIM),
                u8((prevName[M.mode] or 'раньше') .. ': ' .. money(pv)))
        else
            local ts = imgui.CalcTextSize(u8('раньше дохода не было'))
            dl:AddText(ImVec2(p.x + 22 * S, by + (24 * S - ts.y) / 2), cu(C.DIM), u8((prevName[M.mode] or 'раньше') .. ': дохода не было'))
        end
    else
        local txt = ('тележек: %d  ·  в работе: %s'):format(M.agg.carts, hms(math.floor(M.agg.time)))
        local ts = imgui.CalcTextSize(u8(txt))
        dl:AddText(ImVec2(p.x + 22 * S, by + (24 * S - ts.y) / 2), cu(C.DIM), u8(txt))
    end
    pp(F.small)

    local pts = M.values or {}
    local n = M.nlive or #pts
    if n >= 2 then
        local sx0, sx1 = p.x + w * 0.58, p.x + w - 20 * S
        local sy0, sy1 = p.y + 20 * S, p.y + h - 22 * S
        if sx1 - sx0 > 60 * S then
            local mx = 0
            for i = 1, n do if pts[i] > mx then mx = pts[i] end end
            if mx <= 0 then mx = 1 end
            local px, py
            for i = 1, n do
                local x = sx0 + (sx1 - sx0) * (i - 1) / (n - 1)
                local y = sy1 - (sy1 - sy0) * (pts[i] / mx)
                if px then
                    dl:AddLine(ImVec2(px, py), ImVec2(x, y), cu(C.GOLD, 0.25), 6 * S)
                    dl:AddLine(ImVec2(px, py), ImVec2(x, y), cu(C.GOLD), 2.2 * S)
                end
                px, py = x, y
            end
            dl:AddCircleFilled(ImVec2(px, py), 4.5 * S, cu(C.TEXT), 12)
            dl:AddCircle(ImVec2(px, py), 7 * S, cu(C.GOLD, 0.6), 16, 1.5 * S)
        end
    end
end

function internal.statTiles(M)
    local a = M.agg
    local an = internal.animNum
    local hrs = (a.time or 0) / 3600
    local perHour = hrs > 0.05 and money(an('ph', a.money / hrs)) or '-'
    local perCart = a.carts > 0 and money(an('pc', a.money / a.carts)) or '-'
    statRow({
        {IC.dolly, 'Тележек', tostring(math.floor(an('c', a.carts) + 0.5))},
        {IC.clock, 'Время работы', hms(math.floor(a.time or 0))},
    }, 66 * S)
    statRow({
        {IC.bolt, 'Доход в час', perHour, C.LEAF},
        {IC.coins, 'За тележку', perCart, C.LEAF},
    }, 66 * S)
    local best, right
    if M.best then
        local unit = M.unit == 'hour' and 'Лучший час ' or (M.unit == 'session' and 'Лучшая сессия ' or 'Лучший день ')
        best = {IC.chart, unit .. M.best.label, money(an('bs', M.best.v)), C.GOLD}
    else
        best = {IC.chart, 'Лучший отрезок', '-', C.GOLD}
    end
    if (M.mode == 'week' or M.mode == 'month') and M.activeDays > 0 then
        right = {IC.coins, 'В активный день', money(an('ad', a.money / M.activeDays)), C.LEAF}
    else
        right = {IC.dolly, 'Тележек в час', hrs > 0.05 and ('%.1f'):format(an('cph', a.carts / hrs)) or '-'}
    end
    statRow({best, right}, 66 * S)
end

internal.drawGraph = function(M)
    local pts = M.values or {}
    local n = #pts
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    local w, H = imgui.GetContentRegionAvail().x - 4 * S, 214 * S
    local hdr = 38 * S
    local titles = {hour = 'Доход по часам', day = 'Доход по дням', session = 'Доход по сессиям'}

    imgui.SetCursorScreenPos(ImVec2(p.x, p.y + hdr))
    imgui.InvisibleButton('##graph_hold', ImVec2(w, H - hdr))
    local afterGraph = imgui.GetCursorScreenPos()
    local holding = imgui.IsItemActive()
    if holding then touchLock.on = true; internal.holdNext = true end

    badge(dl, p.x, p.y, p.x + w, p.y + H, 16 * S)
    pf(F.small)
    dl:AddText(ImVec2(p.x + 16 * S, p.y + (hdr - imgui.GetTextLineHeight()) / 2 + 2 * S), cu(C.DIM), u8(titles[M.unit] or 'Доход'))
    pp(F.small)

    local bars = cfg.graphMode == 'bars'
    local sw_, sh_ = 70 * S, 24 * S
    local sx0, sy0 = p.x + w - sw_ * 2 - 12 * S, p.y + (hdr - sh_) / 2 + 2 * S
    dl:AddRectFilled(ImVec2(sx0, sy0), ImVec2(sx0 + sw_ * 2, sy0 + sh_), cu(C.PLANK, 0.9), sh_ / 2)
    for k, o in ipairs({{'line', 'Линия'}, {'bars', 'Столбцы'}}) do
        local x0 = sx0 + (k - 1) * sw_
        imgui.SetCursorScreenPos(ImVec2(x0, sy0))
        local clk = imgui.InvisibleButton('##gmode' .. k, ImVec2(sw_, sh_))
        local act = (bars and 'bars' or 'line') == o[1]
        if act then
            dl:AddRectFilled(ImVec2(x0 + 2 * S, sy0 + 2 * S), ImVec2(x0 + sw_ - 2 * S, sy0 + sh_ - 2 * S), cu(C.GOLD, 0.9), (sh_ - 4 * S) / 2)
        end
        pf(F.small)
        local lab = u8(o[2])
        local ts = imgui.CalcTextSize(lab)
        dl:AddText(ImVec2(x0 + (sw_ - ts.x) / 2, sy0 + (sh_ - ts.y) / 2), act and cu(C.PLANK) or cu(C.DIM), lab)
        pp(F.small)
        if clk and not act and not scroll.moved then
            cfg.graphMode = o[1]
            anim.graphProg = 0
            saveCfg()
        end
    end

    if n < 1 then
        pf(F.small)
        local txt = u8(M.mode == 'day' and 'Сегодня заработка ещё не было' or 'Пока нет данных, график появится после первой сданной тележки')
        local ts = imgui.CalcTextSize(txt)
        dl:AddText(ImVec2(p.x + (w - ts.x) / 2, p.y + hdr + (H - hdr - ts.y) / 2), cu(C.DIM), txt)
        pp(F.small)
        imgui.SetCursorScreenPos(afterGraph)
        return
    end

    if internal.graphEpoch ~= internal.numEpoch or not internal.graphInit then
        internal.graphEpoch, internal.graphInit = internal.numEpoch, true
        anim.graphProg = 0
    end
    local prog = 1
    if cfg.numAnim ~= false then
        prog = approach('graphProg', 1, 3.2)
    end
    if (internal.statDbgT or 0) < os.clock() - 5 then
        internal.statDbgT = os.clock()
        local pk = 0
        for i = 1, n do if pts[i] > pk then pk = pts[i] end end
        dbg(('stats v28: mode=%s unit=%s n=%d peak=%d prog=%.2f dt=%.4f'):format(tostring(M.mode), tostring(M.unit), n, pk, prog, dt))
    end

    local nl = M.nlive or n
    if nl > n then nl = n end
    local peak = 0
    for i = 1, n do if pts[i] > peak then peak = pts[i] end end
    local maxv = internal.niceMax(peak)
    local gx0, gx1 = p.x + 16 * S, p.x + w - 16 * S
    local gy0, gy1 = p.y + hdr + 16 * S, p.y + H - 26 * S

    pf(F.small)
    for k = 0, 2 do
        local yy = gy0 + (gy1 - gy0) * k / 2
        dl:AddLine(ImVec2(gx0, yy), ImVec2(gx1, yy), cu(C.WOOD, k == 2 and 0.35 or 0.16), k == 2 and 1.5 * S or 1)
        local lab = k == 0 and internal.short(maxv) or (k == 1 and internal.short(maxv / 2) or '$0')
        dl:AddText(ImVec2(gx0 + 2 * S, yy - 17 * S), cu(C.DIM, 0.75), lab)
    end
    pp(F.small)

    local slot = (gx1 - gx0) / n
    local barW = math.max(3 * S, math.min(slot * 0.62, 40 * S))
    local xy = {}
    for i = 1, n do
        local yv = gy1 - (gy1 - gy0) * pts[i] / maxv
        if bars then
            xy[i] = {gx0 + slot * (i - 0.5), yv}
        else
            xy[i] = {gx0 + (gx1 - gx0) * (n > 1 and (i - 1) / (n - 1) or 0.5), yv}
        end
    end

    pf(F.small)
    local want = n <= 8 and n or 5
    local lastX = -1e9
    for j = 0, want - 1 do
        local i = want == 1 and 1 or (1 + math.floor((n - 1) * j / (want - 1) + 0.5))
        local lab = u8(M.labels[i] or '')
        local ts = imgui.CalcTextSize(lab)
        local x = math.max(p.x + 6 * S, math.min(p.x + w - ts.x - 6 * S, xy[i][1] - ts.x / 2))
        if x > lastX + 6 * S then
            dl:AddText(ImVec2(x, gy1 + 6 * S), cu(C.DIM, 0.85), lab)
            lastX = x + ts.x
        end
    end
    pp(F.small)

    local bestI = M.best and M.best.i
    local reach = prog * (nl - 1)

    if bars then
        for i = 1, n do
            local bp = math.max(0, math.min(1, prog * 1.5 - (i - 1) / n * 0.5))
            local a = xy[i]
            local top = gy1 - (gy1 - a[2]) * bp
            if pts[i] > 0 and gy1 - top < 4 * S then top = gy1 - 4 * S end
            local isBest = (i == bestI and n > 2)
            if pts[i] > 0 then
                internal.vgrad(dl, a[1] - barW / 2, top, a[1] + barW / 2, gy1, isBest and C.GOLD or C.WOOD, 0.85, 0.2, 8)
                dl:AddRectFilled(ImVec2(a[1] - barW / 2, top), ImVec2(a[1] + barW / 2, math.min(gy1, top + 3 * S)), cu(C.GOLD), 2 * S)
                if n <= 8 and bp >= 0.99 then
                    pf(F.small)
                    local t = internal.short(pts[i])
                    local ts = imgui.CalcTextSize(t)
                    dl:AddText(ImVec2(a[1] - ts.x / 2, top - ts.y - 3 * S), cu(C.TEXT, 0.9), t)
                    pp(F.small)
                end
            else
                dl:AddRectFilled(ImVec2(a[1] - barW / 2, gy1 - 2 * S), ImVec2(a[1] + barW / 2, gy1), cu(C.TRACK, 0.8), 1 * S)
            end
        end
    elseif n == 1 then
        local ly = xy[1][2]
        local ex = gx0 + (gx1 - gx0) * prog
        internal.vgrad(dl, gx0, ly, ex, gy1, C.WOOD, 0.4, 0.04, 8)
        dl:AddLine(ImVec2(gx0, ly), ImVec2(ex, ly), cu(C.GOLD), 3 * S)
        dl:AddCircleFilled(ImVec2(ex, ly), 4.5 * S, cu(C.TEXT), 12)
    elseif nl >= 2 then

        local span = (gx1 - gx0) / (n - 1)
        local xr = gx0 + reach * span
        local stp = 4 * S
        local sx = gx0
        while sx < xr do
            local ex = math.min(sx + stp, xr)
            local f = ((sx + ex) / 2 - gx0) / span
            local i0 = math.max(0, math.min(nl - 2, math.floor(f)))
            local ya, yb = xy[i0 + 1][2], xy[i0 + 2][2]
            local yy = ya + (yb - ya) * (f - i0)
            internal.vgrad(dl, sx, yy, ex, gy1, C.WOOD, 0.42, 0.05, 5)
            sx = ex
        end
        for i = 1, nl - 1 do
            if reach > i - 1 then
                local f = math.min(1, reach - (i - 1))
                local a, b = xy[i], xy[i + 1]
                local bx, by = a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
                dl:AddLine(ImVec2(a[1], a[2]), ImVec2(bx, by), cu(C.GOLD, 0.22), 8 * S)
                dl:AddLine(ImVec2(a[1], a[2]), ImVec2(bx, by), cu(C.GOLD), 3 * S)
            end
        end
        if n <= 31 then
            for i = 1, nl do
                if reach >= i - 1 then
                    local isBest = (i == bestI)
                    dl:AddCircleFilled(ImVec2(xy[i][1], xy[i][2]), (isBest and 5 or 3.5) * S, cu(isBest and C.GOLD or C.TEXT), 12)
                    if isBest then dl:AddCircle(ImVec2(xy[i][1], xy[i][2]), 8 * S, cu(C.GOLD, 0.6), 16, 1.5 * S) end
                end
            end
        end
        if prog >= 0.99 and running then
            local pl = (os.clock() * 1.2) % 1
            dl:AddCircle(ImVec2(xy[nl][1], xy[nl][2]), (5 + 7 * pl) * S, cu(C.LEAF, 0.8 * (1 - pl)), 16, 1.5 * S)
        end
    end

    if holding and prog >= 0.99 then
        local mpos = imgui.GetMousePos()
        local ni
        if bars then
            ni = math.floor((mpos.x - gx0) / slot) + 1
        else
            ni = n > 1 and (math.floor((mpos.x - gx0) / (gx1 - gx0) * (n - 1) + 0.5) + 1) or 1
        end
        ni = math.max(1, math.min(nl, ni))
        local mx, vy = xy[ni][1], xy[ni][2]
        local v = pts[ni]
        if bars then
            dl:AddRect(ImVec2(mx - barW / 2 - 2 * S, math.min(vy, gy1 - 2 * S) - 2 * S), ImVec2(mx + barW / 2 + 2 * S, gy1), cu(C.TEXT, 0.8), 4 * S, 0, 1.5 * S)
        else
            dl:AddLine(ImVec2(mx, gy0 - 8 * S), ImVec2(mx, gy1), cu(C.TEXT, 0.5), 1.5 * S)
            dl:AddCircleFilled(ImVec2(mx, vy), 6 * S, cu(C.GOLD), 14)
            dl:AddCircle(ImVec2(mx, vy), 6 * S, cu(C.TEXT), 14, 1.5 * S)
        end
        pf(F.small)
        local l1 = u8(M.full[ni] or M.labels[ni] or '-')
        local l3 = u8(M.infos[ni] or '')
        local s1, s3 = imgui.CalcTextSize(l1), imgui.CalcTextSize(l3)
        pp(F.small)
        pf(F.main)
        local l2 = u8(money(v))
        local s2 = imgui.CalcTextSize(l2)
        pp(F.main)
        local bw2 = math.max(s1.x, s2.x, s3.x) + 22 * S
        local bh2 = s1.y + s2.y + s3.y + 18 * S
        local bx = math.max(p.x + 6 * S, math.min(p.x + w - bw2 - 6 * S, mx - bw2 / 2))
        local by = vy - bh2 - 14 * S
        if by < p.y + hdr then by = math.min(vy + 14 * S, p.y + H - bh2 - 4 * S) end
        dl:AddRectFilled(ImVec2(bx + 2 * S, by + 3 * S), ImVec2(bx + bw2 + 2 * S, by + bh2 + 3 * S), cu(ImVec4(0, 0, 0, 0.35)), 10 * S)
        dl:AddRectFilled(ImVec2(bx, by), ImVec2(bx + bw2, by + bh2), cu(C.PLANK, 0.97), 10 * S)
        dl:AddRect(ImVec2(bx, by), ImVec2(bx + bw2, by + bh2), cu(C.GOLD, 0.55), 10 * S, 0, 1.2 * S)
        pf(F.small)
        dl:AddText(ImVec2(bx + 11 * S, by + 6 * S), cu(C.DIM), l1)
        pp(F.small)
        pf(F.main)
        dl:AddText(ImVec2(bx + 11 * S, by + 8 * S + s1.y), cu(C.GOLD), l2)
        pp(F.main)
        pf(F.small)
        dl:AddText(ImVec2(bx + 11 * S, by + 10 * S + s1.y + s2.y), cu(C.DIM), l3)
        pp(F.small)
    elseif prog >= 0.99 and nl >= 1 then
        pf(F.small)
        local hint = u8('зажмите график, чтобы увидеть значение')
        local ts = imgui.CalcTextSize(hint)
        dl:AddText(ImVec2(p.x + w - ts.x - 14 * S, p.y + hdr + 2 * S), cu(C.DIM, 0.45), hint)
        pp(F.small)
    end
    imgui.SetCursorScreenPos(afterGraph)
end

function internal.statSessions(M)
    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    local w = imgui.GetContentRegionAvail().x - 4 * S
    local rh = 40 * S
    local rows = 1 + #M.recent
    local h = rows * rh + 12 * S
    imgui.Dummy(ImVec2(w, h))
    badge(dl, p.x, p.y, p.x + w, p.y + h, 14 * S)

    local s = stats.session
    local sec = sessionTime()
    local y = p.y + 6 * S
    local dotCol = running and C.LEAF or C.DIM
    local cx, cy = p.x + 24 * S, y + rh / 2
    if running then
        local pl = (os.clock() * 1.1) % 1
        dl:AddCircle(ImVec2(cx, cy), (5 + 8 * pl) * S, cu(C.LEAF, 0.6 * (1 - pl)), 16, 1.5 * S)
    end
    dl:AddCircleFilled(ImVec2(cx, cy), 5 * S, cu(dotCol), 12)
    local function line(yy, label, labCol, dur, val, valCol)
        pf(F.main)
        local ls = imgui.CalcTextSize(u8(label))
        dl:AddText(ImVec2(p.x + 42 * S, yy + (rh - ls.y) / 2), cu(labCol), u8(label))
        local vs = imgui.CalcTextSize(val)
        dl:AddText(ImVec2(p.x + w - vs.x - 16 * S, yy + (rh - vs.y) / 2), cu(valCol), val)
        pp(F.main)
        pf(F.small)
        local ds = imgui.CalcTextSize(u8(dur))
        dl:AddText(ImVec2(p.x + w * 0.52, yy + (rh - ds.y) / 2), cu(C.DIM), u8(dur))
        pp(F.small)
    end
    line(y, running and 'Идёт сейчас' or 'Эта сессия', C.TEXT,
        hms(math.floor(sec)) .. '  ·  ' .. tostring(s.carts or 0) .. ' тел.', money(internal.animNum('sess', s.money or 0)), C.LEAF)
    for i, hh in ipairs(M.recent) do
        local yy = y + i * rh
        dl:AddLine(ImVec2(p.x + 16 * S, yy), ImVec2(p.x + w - 16 * S, yy), cu(C.WOOD, 0.15), 1)
        dl:AddCircleFilled(ImVec2(cx, yy + rh / 2), 3 * S, cu(C.WOOD, 0.8), 10)
        local lab = hh.t and os.date('%d.%m  %H:%M', hh.t) or '-'
        line(yy, lab, C.DIM, hms(math.floor(tonumber(hh.time) or 0)), money(tonumber(hh.money) or 0), C.GOLD)
    end
end

local function tabStats()
    internal.periodSwitch()
    local mode = cfg.statPeriod or 'all'
    local ok, M = pcall(internal.periodData, mode)
    if not ok or type(M) ~= 'table' then
        internal.dbgOnce('stats model', M)
        pf(F.main); imgui.TextColored(C.EMBER, u8('Не удалось собрать статистику, подробности в sawbot_debug.txt')); pp(F.main)
        return
    end
    local function part(name, fn)
        local ok2, err = pcall(fn, M)
        if not ok2 then internal.dbgOnce('stats ' .. name, err) end
    end
    part('hero', internal.statHero)
    imgui.Dummy(ImVec2(0, 2 * S))
    part('tiles', internal.statTiles)
    section('График', IC.chart)
    part('graph', internal.drawGraph)
    section('Сессии', IC.clock)
    part('sessions', internal.statSessions)
    imgui.Dummy(ImVec2(0, 12 * S))

    local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
    local bw, bh = math.min(380 * S, imgui.GetContentRegionAvail().x - 4 * S), 46 * S
    local armed = internal.resetArm and os.clock() - internal.resetArm < 3
    if imgui.InvisibleButton('##reset', ImVec2(bw, bh)) and not scroll.moved then
        if armed then
            stats.total = {money = 0, carts = 0, items = {}, time = 0}
            pcall(internal.wipeDays)
            internal.resetArm, internal.pc = nil, nil
            internal.numEpoch = (internal.numEpoch or 0) + 1
            saveCfg()
        else
            internal.resetArm = os.clock()
        end
    end
    glossy(dl, p.x, p.y, p.x + bw, p.y + bh, armed and C.EMBER or C.GREY, 12 * S, imgui.IsItemHovered() and 1 or 0, true)
    iconAt(dl, IC.trash, p.x + 8 * S, p.y, 36 * S, bh, cu(C.TEXT))
    pf(F.main)
    local label = u8(armed and 'Нажмите ещё раз, чтобы сбросить' or 'Сбросить всю статистику')
    local ts = imgui.CalcTextSize(label)
    dl:AddText(ImVec2(p.x + 46 * S, p.y + (bh - ts.y) / 2), cu(C.TEXT), label)
    pp(F.main)
    pf(F.small)
    imgui.TextColored(C.DIM, u8('Сбрасывает общую статистику и данные по дням'))
    pp(F.small)
    imgui.Dummy(ImVec2(0, 10 * S))
end

local authorData = { page = 'profile', history = {
    {
        version = 'current',
        date = '16.11.2026',
        sections = {
            {
                title = 'Движение и камера',
                kind = 'changes',
                items = {
                    'Исправлен баг, из-за которого бот останавливался у конвейера и просто поворачивал камеру вместо продолжения маршрута',
                    'Убраны проверки направления движения при запуске и выполнении маршрута',
                    'Добавлено восстановление движения при застревании: бот отпускает джойстик и повторно пытается выполнить маршрут',
                    'Исправлена работа движения после случайного вмешательства в управление'
                }
            },
            {
                title = 'Деревья и тележки',
                kind = 'fixes',
                items = {
                    'Исправлена обработка второй тележки, появляющейся возле срубленного дерева',
                    'Улучшено обнаружение свободных тележек',
                    'Исправлен баг, из-за которого бот мог забыть о тележке',
                    'Добавлена обработка ситуации, когда другой игрок забирает тележку: бот забывает о ней и возвращается к запланированной работе с деревом',
                    'Исправлено переключение на запасное дерево: бот больше не должен возвращаться к координатам возле конвейера'
                }
            },
            {
                title = 'Мини-игра',
                kind = 'fixes',
                items = {
                    'Исправлен баг, из-за которого бот мог случайно закрыть мини-игру при первом подходе к дереву'
                }
            },
            {
                title = 'Конвейер',
                kind = 'fixes',
                items = {
                    'Исправлено движение после сдачи тележки на правом конвейере'
                }
            }
        },
    },
    {
        version = '0.2',
        date = '15.11.2026',
        sections = {
            {
                title = 'Движение',
                kind = 'changes',
                items = {
                    'Добавлено движение в стороны и его настройка',
                    'Добавлена настройка смещения, если бот застрял',
                    'Бот больше не ослабляет нажатие джойстика возле цели',
                    'Улучшен обход заборов и препятствий',
                    'Исправлено движение к цели'
                }
            },
            {
                title = 'Деревья',
                kind = 'changes',
                items = {
                    'Улучшен обход деревьев',
                    'Добавлена проверка занятости деревьев игроками',
                    'Добавлен поиск запасных деревьев'
                }
            },
            {
                title = 'Камера',
                kind = 'fixes',
                items = {
                    'Исправлена камера после сдачи тележки',
                    'Время ожидания снижено до 0,5 секунды'
                }
            },
            {
                title = 'Прочее',
                kind = 'fixes',
                items = {
                    'Исправлены ошибки в работе бота'
                }
            }
        }
    }
} }

authorData.historyStats = function()
    local changes, fixes = 0, 0
    for _, release in ipairs(authorData.history) do
        if release.sections then
            for _, group in ipairs(release.sections) do
                local count = #(group.items or {})
                if group.kind == 'fixes' then
                    fixes = fixes + count
                else
                    changes = changes + count
                end
            end
        else
            changes = changes + #(release.changes or {})
            fixes = fixes + #(release.fixes or {})
        end
    end
    return #authorData.history, changes, fixes
end

authorData.backButton = function()
    local w = imgui.GetContentRegionAvail().x
    if themeBtn('##author_back', ico('ARROW_LEFT') .. '  ' .. u8('Назад к автору'),
        w, 38 * S, C.WOODD, function() authorData.page = 'profile' end) then
        authorData.page = 'profile'
    end
end

authorData.tabHistory = function()
    section('История обновлений', ico('CLOCK_ROTATE_LEFT'))
    authorData.backButton()
    imgui.Dummy(ImVec2(0, 8 * S))

    for _, release in ipairs(authorData.history) do
        local p, dl = imgui.GetCursorScreenPos(), imgui.GetWindowDrawList()
        local w = imgui.GetContentRegionAvail().x
        local groups = release.sections or {
            {title = 'Изменения', items = release.changes or {}},
            {title = 'Исправления', items = release.fixes or {}}
        }
        local groupCount, itemCount = 0, 0
        for _, group in ipairs(groups) do
            local count = #(group.items or {})
            if count > 0 then
                groupCount = groupCount + 1
                itemCount = itemCount + count
            end
        end
        local h = (52 + groupCount * 25 + itemCount * 21) * S
        imgui.Dummy(ImVec2(w, h))
        dl:AddRectFilled(ImVec2(p.x, p.y), ImVec2(p.x + w, p.y + h),
            cu(C.TRACK, 0.34), 13 * S)
        dl:AddCircleFilled(ImVec2(p.x + 18 * S, p.y + 22 * S), 5 * S, cu(C.WOOD))
        pf(F.header)
        dl:AddText(ImVec2(p.x + 34 * S, p.y + 9 * S), cu(C.GOLD),
            u8('v' .. (release.version == 'current' and tostring(thisScript().version) or release.version)))
        pp(F.header)
        pf(F.small)
        local dateText = u8(release.date)
        local dateSize = imgui.CalcTextSize(dateText)
        dl:AddText(ImVec2(p.x + w - dateSize.x - 14 * S, p.y + 13 * S), cu(C.DIM), dateText)
        pp(F.small)

        local y = p.y + 40 * S
        for _, group in ipairs(groups) do
            if #(group.items or {}) > 0 then
                pf(F.main)
                dl:AddText(ImVec2(p.x + 16 * S, y), cu(C.TEXT), u8(group.title))
                pp(F.main)
                y = y + 21 * S
                pf(F.small)
                for _, item in ipairs(group.items) do
                    dl:AddCircleFilled(ImVec2(p.x + 33 * S, y + 8 * S), 2.5 * S, cu(C.WOOD))
                    dl:AddText(ImVec2(p.x + 44 * S, y), cu(C.DIM), u8(item))
                    y = y + 20 * S
                end
                pp(F.small)
                y = y + 4 * S
            end
        end
        imgui.Dummy(ImVec2(0, 8 * S))
    end
end

internal.avRing = {ang = 0, vel = 1.6, held = false}
internal.drawAvatarRing = function(dl, cx, cy, r)
    local st_ = internal.avRing
    local dt_ = math.min(0.1, math.max(0.001, tonumber(dt) or 0.016))
    local base, maxV = 1.6, 22
    internal.dbgOnce('avatar ring', 'draw ok, r=' .. tostring(r))

    pcall(function()
        local m = imgui.GetMousePos()
        local wp_, ws_ = imgui.GetWindowPos(), imgui.GetWindowSize()
        local inWin = m.x >= wp_.x and m.x <= wp_.x + ws_.x and m.y >= wp_.y and m.y <= wp_.y + ws_.y
        local dx, dy = m.x - cx, m.y - cy
        local inside = dx * dx + dy * dy <= (r + 14 * S) ^ 2
        if imgui.IsMouseClicked(0) and inside and inWin then
            st_.held = true
            st_.vel = math.min(maxV, st_.vel + 5)
            internal.dbgOnce('avatar ring press', 'press detected')
        end
        if st_.held and (not imgui.IsMouseDown(0) or scroll.moved) then st_.held = false end
    end)

    if st_.held then
        st_.vel = st_.vel + (maxV - st_.vel) * (1 - math.exp(-dt_ * 2.2))
    else
        st_.vel = base + (st_.vel - base) * math.exp(-dt_ * 1.4)
    end
    st_.ang = (st_.ang + st_.vel * dt_) % 6.2831853

    dl:AddCircle(ImVec2(cx, cy), r, cu(C.GOLD, 0.2), 64, 9 * S)
    dl:AddCircle(ImVec2(cx, cy), r, cu(C.GOLD, 0.25), 64, 1.2 * S)

    local function comet(ang, span, alphaMul, widthMul)
        local N = 48
        for i = 0, N - 1 do
            local f = i / N
            local a0 = ang - span + span * f
            local a1 = a0 + span / N * 1.15
            local col = mix(C.GOLD, ImVec4(1, 0.96, 0.78, 1), f * f)
            dl:AddLine(ImVec2(cx + math.cos(a0) * r, cy + math.sin(a0) * r),
                ImVec2(cx + math.cos(a1) * r, cy + math.sin(a1) * r),
                cu(col, (f ^ 2.2) * 0.95 * alphaMul), (1.5 + 2.7 * f) * S * widthMul)
        end
        local hx, hy = cx + math.cos(ang) * r, cy + math.sin(ang) * r
        dl:AddCircleFilled(ImVec2(hx, hy), 4.2 * S * widthMul, cu(ImVec4(1, 0.96, 0.78, 1), 0.4 * alphaMul), 16)
        dl:AddCircleFilled(ImVec2(hx, hy), 2.4 * S * widthMul, cu(ImVec4(1, 1, 0.92, 1), alphaMul), 12)
    end
    comet(st_.ang, 5.4, 1, 1)
    comet(st_.ang + 3.14159, 2.2, 0.6, 0.75)
end

internal.feedbackText = function(kind, body)
    local head, hint
    if kind == 'bug' then
        head = 'Привет, нашёл баг в твоем боте на лесопилку, вот он:'
        hint = '(что случилось и как это повторить)'
    else
        head = 'Привет, хочу предложить тебе идею для скрипта лесопилки:'
        hint = '(опиши идею и зачем она нужна)'
    end
    body = tostring(body or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local out = u8(head) .. '\n\n'
    if body ~= '' then out = out .. body else out = out .. u8(hint) end
    out = out .. '\n\n' .. u8('Версия: v' .. tostring(thisScript().version))
    if kind == 'bug' then
        out = out .. '\n\n' .. u8('Приложите файл neomloader.log (из папки log)')
    end
    return out
end

internal.drawAboutContent = function()
    local p = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()
    local avail = imgui.GetContentRegionAvail().x
    local cardW = math.max(180 * S, avail - 8 * S)
    local cardH = 142 * S

    imgui.Dummy(ImVec2(cardW, cardH))
    local x0, y0 = p.x, p.y
    local x1, y1 = x0 + cardW, y0 + cardH
    local wpos, wsz = imgui.GetWindowPos(), imgui.GetWindowSize()
    local bx0, bx1 = wpos.x, wpos.x + wsz.x
    dl:AddRectFilled(ImVec2(bx0, y0), ImVec2(bx1, y1), cu(C.BADGE))
    dl:AddRectFilled(ImVec2(bx0, y0), ImVec2(bx1, y0 + 2 * S), cu(C.GOLD, 0.9))
    dl:AddRectFilled(ImVec2(bx0, y1 - 2 * S), ImVec2(bx1, y1), cu(C.GOLD, 0.9))

    local avatarSize = 104 * S
    local avatarX = x0 + 16 * S
    local avatarY = y0 + (cardH - avatarSize) / 2

    if TEX.avatar then
        local roundedOk = pcall(function()
            dl:AddImageRounded(TEX.avatar, ImVec2(avatarX, avatarY),
                ImVec2(avatarX + avatarSize, avatarY + avatarSize), ImVec2(0, 0), ImVec2(1, 1),
                0xFFFFFFFF, avatarSize / 2)
        end)
        if not roundedOk then
            dl:AddImage(TEX.avatar, ImVec2(avatarX, avatarY), ImVec2(avatarX + avatarSize, avatarY + avatarSize))
            dl:AddCircle(ImVec2(avatarX + avatarSize / 2, avatarY + avatarSize / 2),
                avatarSize / 2, cu(C.GOLD), 48, 2 * S)
        end
    else
        dl:AddCircleFilled(ImVec2(avatarX + avatarSize / 2, avatarY + avatarSize / 2),
            avatarSize / 2, cu(C.PLANK))
        dl:AddCircle(ImVec2(avatarX + avatarSize / 2, avatarY + avatarSize / 2),
            avatarSize / 2, cu(C.GOLD), 48, 2 * S)
    end

    if cfg.avRing ~= false then
        internal.drawAvatarRing(dl, avatarX + avatarSize / 2, avatarY + avatarSize / 2, avatarSize / 2 + 6 * S)
    end

    local textX = avatarX + avatarSize + 18 * S
    pf(F.header)
    dl:AddText(ImVec2(textX, y0 + 31 * S), cu(C.GOLD), u8(AUTHOR))
    pp(F.header)
    pf(F.main)
    dl:AddText(ImVec2(textX, y0 + 61 * S), cu(C.TEXT), u8('@' .. TG_AUTHOR))
    pp(F.main)

    imgui.Dummy(ImVec2(0, 10 * S))
    local versionCount, changeCount, fixCount = authorData.historyStats()
    local gap = 8 * S

    statRow({
        {ico('CODE_BRANCH'), 'ВЕРСИЯ', 'v' .. tostring(thisScript().version), C.GOLD},
        {ico('CALENDAR_DAYS'), 'ОБНОВЛЕНО', '15.11.2026', C.GOLD}
    }, 68 * S)

    imgui.Dummy(ImVec2(0, 8 * S))
    if themeBtn('##author_history', ico('CLOCK_ROTATE_LEFT') .. '  ' ..
        u8('История обновлений'), avail, 42 * S, C.WOODD,
        function() authorData.page = 'history' end) then
        authorData.page = 'history'
    end

    imgui.Dummy(ImVec2(0, 8 * S))
    section('Статистика проекта', ico('CHART_SIMPLE'))
    statRow({
        {ico('CODE_BRANCH'), 'ВЕРСИИ', tostring(versionCount), C.GOLD},
        {ico('LIST_CHECK'), 'ИЗМЕНЕНИЯ', tostring(changeCount), C.GOLD},
        {ico('BUG'), 'ИСПРАВЛЕНИЯ', tostring(fixCount), C.GOLD}
    }, 72 * S)

    imgui.Dummy(ImVec2(0, 10 * S))
    section('Связь и поддержка', ico('COMMENTS'))
    local buttonW = (avail - gap) / 2
    local buttonH = 44 * S

    if themeBtn('##author_link', ico('USER') .. '  ' .. u8('Автор'),
        buttonW, buttonH, C.WOODD,
        function() openTg('oxzay', 'автор') end) then end

    imgui.SameLine(0, gap)

    if themeBtn('##channel_link', ico('PAPER_PLANE') .. '  ' .. u8('Telegram-канал'),
        buttonW, buttonH, C.WOODD,
        function() openTg('pinokio_channel', 'телеграм-канал') end) then end

    if themeBtn('##error_link', ico('BUG') .. '  ' .. u8('Ошибки'),
        buttonW, buttonH, C.WOODD,
        function() openTg('oxzay', 'bug', internal.feedbackText('bug', '')) end) then end

    imgui.SameLine(0, gap)

    if themeBtn('##suggest_link', ico('LIGHTBULB') .. '  ' .. u8('Предложения'),
        buttonW, buttonH, C.WOODD,
        function() openTg('oxzay', 'idea', internal.feedbackText('idea', '')) end) then end
end

internal.tabAbout = function()
    local ok, err = xpcall(function()
        if authorData.page == 'history' then
            authorData.tabHistory()
            return
        end

        section('Об авторе и поддержке', IC.user)
        loadTextures()
        internal.drawAboutContent()
    end, function(e)
        return debug.traceback(tostring(e), 2)
    end)

    if not ok then
        error('[ABOUT TRACEBACK]\n' .. tostring(err))
    end
end

local function wrapPrompt(text, width)
    local out, line = {}, ''
    for word in tostring(text or ''):gmatch('%S+') do
        if #line > 0 and #line + 1 + #word > width then
            out[#out + 1] = line; line = word
        else
            line = #line > 0 and (line .. ' ' .. word) or word
        end
    end
    if #line > 0 then out[#out + 1] = line end
    return table.concat(out, '\n')
end

local function tabAA()
    section('Стоп бота', IC.shield)
    toggle('При телепорте', 'aaStopTp', 'сервер перенёс дальше 15 м')
    toggle('При «Вы тут?» в чате', 'aaStopChat')
    toggle('При любом диалоге', 'aaStopDialog', 'кроме меню, которые бот открыл сам')

    section('Ответ админу', IC.user)
    toggle('Автоответ админу', 'aaReply', 'в /b, как живой игрок')
    toggle('Отвечать через ИИ', 'aaAI', 'иначе — готовые фразы из списка')
    toggle('Автозапуск через 7 мин', 'aaResume', 'если после стопа всё тихо')
    toggle('Выйти из игры при стопе', 'aaQuit')
    toggle('Звук тревоги', 'aaSound')
    toggle('Красная рамка при тревоге', 'aaAlert', 'пульсирует по краям экрана')

    section('Искусственный интеллект', IC.bolt)
    if not ai.enabledBuf then ai.enabledBuf = imgui.new.bool(ai.enabled) end
    ai.enabledBuf[0] = ai.enabled
    if imgui.Checkbox(u8'Включить ИИ##ai_on', ai.enabledBuf) then
        ai.enabled = ai.enabledBuf[0]
        ai.save()
    end
    imgui.Dummy(ImVec2(0, 4 * S))

    pf(F.small); imgui.TextColored(C.DIM, 'API Base URL'); pp(F.small)
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x * 0.85)
    if not AI_ep then AI_ep = imgui.new.char[512](tostring(ai.endpoint or '')) end
    if imgui.InputText('##aiendpoint', AI_ep, 512) then
        ai.endpoint = ffi.string(AI_ep):gsub('%s+$', '')
    end
    if imgui.IsItemActive() then touchLock.on = true end
    if imgui.IsItemDeactivatedAfterEdit() then ai.save() end

    pf(F.small); imgui.TextColored(C.DIM, u8'API ключ'); pp(F.small)
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x * 0.85)
    if not AI_key then AI_key = imgui.new.char[256](tostring(ai.apiKey or '')) end
    if imgui.InputText('##aikey', AI_key, 256, imgui.InputTextFlags.Password) then
        ai.apiKey = ffi.string(AI_key):gsub('%s+$', '')
    end
    if imgui.IsItemActive() then touchLock.on = true end
    if imgui.IsItemDeactivatedAfterEdit() then ai.save() end

    pf(F.small); imgui.TextColored(C.DIM, u8'Модель'); pp(F.small)
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x * 0.85)
    if not AI_model then AI_model = imgui.new.char[64](tostring(ai.model or '')) end
    if imgui.InputText('##aimodel', AI_model, 64) then
        ai.model = ffi.string(AI_model):gsub('%s+$', '')
    end
    if imgui.IsItemActive() then touchLock.on = true end
    if imgui.IsItemDeactivatedAfterEdit() then ai.save() end

    imgui.Dummy(ImVec2(0, 4 * S))

    local bw2 = (imgui.GetContentRegionAvail().x - 8 * S) / 2
    themeBtn('##ai_test', u8'Тест',   bw2, 32 * S, C.LEAF,  ai.testSignal)
    imgui.SameLine()
    themeBtn('##ai_models', u8'Модели', bw2, 32 * S, C.GOLD,  ai.fetchModels)

    if ai.testMsg ~= '' then
        local col = ai.testBusy and C.DIM or ai.testOk and ImVec4(0.45, 0.85, 0.4, 1) or C.EMBER
        imgui.TextColored(col, u8(ai.testMsg))
    end
    if ai.modelsMsg ~= '' then
        imgui.TextColored(C.DIM, u8(ai.modelsMsg))
    end

    if #ai.models > 0 then
        imgui.BeginChild('##models_list', ImVec2(0, 3 * 34 * S), true)
        local modelPos = imgui.GetWindowPos()
        local modelSize = imgui.GetWindowSize()
        ai.modelsRect = { modelPos.x, modelPos.y, modelPos.x + modelSize.x, modelPos.y + modelSize.y }
        for i, m in ipairs(ai.models) do
            if (i - 1) % 9 > 0 then imgui.SameLine(0, 6 * S) end
            local modelLabel = u8(m)
            local modelWidth = math.max(110 * S, imgui.CalcTextSize(modelLabel).x + 20 * S)
            if themeSmallBtn('##apply_m' .. i, modelLabel, modelWidth, 28 * S, C.LEAF) then
                ai.model = m
                if AI_model then ffi.copy(AI_model, m) end
                ai.save()
            end
        end
        imgui.EndChild()
    else
        ai.modelsRect = nil
    end

    imgui.Dummy(ImVec2(0, 4 * S))

    pf(F.small); imgui.TextColored(C.DIM, u8'Проверка ответа для администратора'); pp(F.small)
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x * 0.85)
    if not AI_ask then AI_ask = imgui.new.char[512]('') end
    imgui.InputText('##aiask', AI_ask, 512)
    if imgui.IsItemActive() then touchLock.on = true end
    themeBtn('##ai_ask_btn', u8'Проверить', imgui.GetContentRegionAvail().x, 30 * S, C.WOODD,
        function() ai.ask(ffi.string(AI_ask)) end)
    if ai.askReply ~= '' then imgui.TextWrapped(u8(ai.askReply)) end

    imgui.Dummy(ImVec2(0, 4 * S))

    pf(F.small); imgui.TextColored(C.DIM, u8'Системный промпт'); pp(F.small)
    if not AI_sys then AI_sys = imgui.new.char[4096](wrapPrompt(ai.system or ai.DEFAULT_SYSTEM, 220)) end
    if ffi.string(AI_sys) == '' and (ai.system or ai.DEFAULT_SYSTEM) ~= '' then ffi.copy(AI_sys, wrapPrompt(ai.system or ai.DEFAULT_SYSTEM, 210)) end
    imgui.SetNextItemWidth(-1)
    if imgui.InputTextMultiline('##aisystem', AI_sys, 4096, ImVec2(-1, 150 * S)) then
        ai.system = ffi.string(AI_sys):gsub('[\r\n]+', ' ')
    end
    if imgui.IsItemActive() then touchLock.on = true end
    if imgui.IsItemDeactivatedAfterEdit() then ai.save() end
    themeBtn('##ai_sys_reset', u8'Сбросить промпт', imgui.GetContentRegionAvail().x, 28 * S, C.EMBER,
        function()
            ai.system = ai.DEFAULT_SYSTEM
            if AI_sys then ffi.copy(AI_sys, wrapPrompt(ai.system, 210)) end
            ai.save()
        end)
end

local TABS = {
    {label = 'ГЛАВНАЯ', icon = IC.house, draw = tabMain},
    {label = 'НАСТРОЙКИ', icon = IC.sliders, draw = tabSettings},
    {label = 'ЕДА', icon = IC.food, draw = tabFood},
    {label = 'АНТИ-АДМИН', icon = IC.shield, draw = tabAA},
    {label = 'СТАТИСТИКА', icon = IC.chart, draw = tabStats},
    {label = 'АВТОР', icon = IC.info, draw = internal.tabAbout},
}
local tab, tabPrev, tabSwitchT, menuOpenT, lastFrameT = 1, 1, 0, 0, 0
local barDrag = {on = false}
local tabHeights = {}
local diag = {frame = 0, lastTouch = false, lastDown = false, lastTab = 0, lastY = -1, lastMax = -1}
local winDrag = {on = false, ox = 0, oy = 0, moved = false}

local dbgSeen = {}
internal.toasts = {}
internal.toast = function(text)
    if cfg.toasts == false then return end
    local s = tostring(text or ''):gsub('{%x%x%x%x%x%x}', '')
    if s == '' then return end
    local col = C.WOOD
    local raw = tostring(text)
    if raw:find('{FF6666}', 1, true) then col = C.EMBER
    elseif s:find('запущен', 1, true) or s:find('запускаюсь', 1, true) then col = C.LEAF end
    local list = internal.toasts
    list[#list + 1] = {text = s, col = col, t0 = os.clock()}
    while #list > 4 do table.remove(list, 1) end
end
internal.drawDust = function(dl, x0, y0, x1, y1)
    if cfg.sawdust == false then return end
    local w, h = x1 - x0, y1 - y0
    if w <= 10 or h <= 10 then return end
    local d = internal.dust
    if not d then
        d = {}
        for i = 1, 36 do
            d[i] = {x = math.random(), y = math.random(), v = 0.04 + math.random() * 0.07,
                r = 1 + math.random() * 1.8, ph = math.random() * 6.28, a = 0.25 + math.random() * 0.5}
        end
        internal.dust = d
    end
    local tnow = os.clock()
    local step = math.min(0.05, tnow - (internal.dustT or tnow))
    internal.dustT = tnow
    dl:PushClipRect(ImVec2(x0, y0), ImVec2(x1, y1), true)
    pcall(function()
        for i = 1, #d do
            local q = d[i]
            q.y = q.y + q.v * step
            if q.y > 1.02 then q.y = -0.02; q.x = math.random() end
            local px = x0 + (q.x + math.sin(tnow * 1.3 + q.ph) * 0.012) * w
            dl:AddCircleFilled(ImVec2(px, y0 + q.y * h), q.r * S, cu(C.GOLD, q.a * 0.45), 8)
        end
    end)
    dl:PopClipRect()
end
internal.drawLeaves = function(dl, x0, y0, x1, y1)
    if cfg.leaves == false then return end
    local w, h = x1 - x0, y1 - y0
    if w <= 10 or h <= 10 then return end
    local L = internal.leaves
    if not L then
        L = {}
        local pal = {ImVec4(1, 0.55, 0.18, 1), ImVec4(1, 0.78, 0.30, 1), ImVec4(0.80, 0.30, 0.14, 1),
            ImVec4(0.62, 0.80, 0.28, 1), ImVec4(0.95, 0.42, 0.20, 1)}
        for i = 1, 14 do
            L[i] = {x = math.random(), y = math.random(), v = 0.035 + math.random() * 0.05, sz = 5 + math.random() * 5,
                ph = math.random() * 6.28, sw = 0.7 + math.random() * 0.9, rot = math.random() * 6.28,
                rs = (math.random() - 0.5) * 2.2, col = pal[math.random(#pal)], a = 0.35 + math.random() * 0.3}
        end
        internal.leaves = L
    end
    local tnow = os.clock()
    local step = math.min(0.05, tnow - (internal.leafT or tnow))
    internal.leafT = tnow
    dl:PushClipRect(ImVec2(x0, y0), ImVec2(x1, y1), true)
    pcall(function()
        for i = 1, #L do
            local q = L[i]
            q.y = q.y + q.v * step
            q.rot = q.rot + q.rs * step
            if q.y > 1.05 then q.y = -0.05; q.x = math.random() end
            local cx = x0 + (q.x + math.sin(tnow * q.sw + q.ph) * 0.035) * w
            local cy = y0 + q.y * h
            local s = q.sz * S
            local ca, sa = math.cos(q.rot), math.sin(q.rot)
            local fl = 0.45 + 0.55 * math.abs(math.cos(tnow * q.sw * 1.3 + q.ph))
            local ax, ay = ca, sa
            local bx, by = -sa * fl, ca * fl
            local tip = ImVec2(cx + ax * s, cy + ay * s)
            local rt = ImVec2(cx + bx * s * 0.45, cy + by * s * 0.45)
            local base = ImVec2(cx - ax * s * 0.8, cy - ay * s * 0.8)
            local lf = ImVec2(cx - bx * s * 0.45, cy - by * s * 0.45)
            dl:AddQuadFilled(tip, rt, base, lf, cu(q.col, q.a))
            dl:AddLine(base, tip, cu(ImVec4(0.25, 0.12, 0.04, 1), q.a * 0.6), 1)
            dl:AddLine(base, ImVec2(cx - ax * s * 1.1, cy - ay * s * 1.1), cu(ImVec4(0.25, 0.12, 0.04, 1), q.a * 0.7), 1.2)
        end
    end)
    dl:PopClipRect()
end
internal.dbgOnce = function(tag, text)
    if not dbgSeen[tag] then dbgSeen[tag] = true; dbg(tag .. ': ' .. tostring(text)) end
end
internal.touchScroll = function()
    return math.max(0, tonumber(scroll.max) or 0)
end
ai.modelsScroll = { vel = 0, tracking = false, moved = false, startX = 0, startY = 0, lastY = 0 }
ai.modelsRect   = nil

--прокрутка
function touchScrollModels()
    if not ai.modelsRect then return end
    local wp, ws, mp = imgui.GetWindowPos(), imgui.GetWindowSize(), imgui.GetMousePos()
    if mp.x < wp.x or mp.x > wp.x + ws.x or mp.y < wp.y or mp.y > wp.y + ws.y then
        ai.modelsScroll.tracking = false
        return
    end
    local s = ai.modelsScroll
    if imgui.IsMouseClicked(0) and not imgui.IsAnyItemActive() then
        s.vel, s.moved = 0, false
        s.startX, s.startY, s.lastY = mp.x, mp.y, mp.y
        s.tracking = true
    end
    if s.tracking then
        if imgui.IsMouseDown(0) then
            local ady = math.abs(mp.y - s.startY)
            if not s.moved and ady > 14 * S * 0.6 and ady > math.abs(mp.x - s.startX) then
                s.moved, s.lastY = true, mp.y
            end
            if s.moved then
                local dy = mp.y - s.lastY
                imgui.SetScrollY(imgui.GetScrollY() - dy)
                s.vel = -dy
                s.lastY = mp.y
            end
        else
            s.tracking = false
        end
    elseif math.abs(s.vel) > 0.5 then
        imgui.SetScrollY(imgui.GetScrollY() + s.vel)
        s.vel = s.vel * 0.93
    else
        s.vel = 0
    end
end

local function touchScroll(u)
    if winDrag and winDrag.on then
        scroll.tracking, scroll.moved = false, false
        return
    end
    if ai.modelsRect then
        local mp = imgui.GetMousePos()
        if mp.x >= ai.modelsRect[1] and mp.x <= ai.modelsRect[3]
           and mp.y >= ai.modelsRect[2] and mp.y <= ai.modelsRect[4] then
            return
        end
    end
    if touchLock.on then scroll.tracking, scroll.moved = false, false end

    local wp, ws, mp = imgui.GetWindowPos(), imgui.GetWindowSize(), imgui.GetMousePos()

    if imgui.IsMouseClicked(0) and not touchLock.on and not imgui.IsAnyItemActive() then
        scroll.vel = 0
        scroll.moved = false
        scroll.startX, scroll.startY, scroll.lastY = mp.x, mp.y, mp.y
        scroll.tracking = mp.x >= wp.x and mp.x <= wp.x + ws.x
            and mp.y >= wp.y and mp.y <= wp.y + ws.y
    end

    if scroll.tracking then
        if imgui.IsMouseDown(0) then
            local ady = math.abs(mp.y - scroll.startY)
            if not scroll.moved and ady > u * 0.6 and ady > math.abs(mp.x - scroll.startX) then
                scroll.moved = true
                scroll.lastY = mp.y
            end
            if scroll.moved then
                local dy = mp.y - scroll.lastY
                imgui.SetScrollY(imgui.GetScrollY() - dy)
                scroll.vel = -dy
                scroll.lastY = mp.y
            end
        else
            scroll.tracking = false
        end
    elseif math.abs(scroll.vel) > 0.5 then
        imgui.SetScrollY(imgui.GetScrollY() + scroll.vel)
        scroll.vel = scroll.vel * 0.93
    else
        scroll.vel = 0
    end
end

function sawTab(i)
    i = math.floor(tonumber(i) or 1)
    if not TABS[i] then i = 1 end
    tab = i
    scroll.y, scroll.vel = 0, 0
    if not menuOpen[0] then
        menuOpen[0] = true
        cfg.winX, cfg.winY = false, false
        menuOpenT = os.clock()
        lastFrameT = menuOpenT
    end
end

internal.powerButton = function(dl, x0, y0, x1, y1, id, vertical)
    imgui.SetCursorScreenPos(ImVec2(x0, y0))
    local clicked = imgui.InvisibleButton(id, ImVec2(x1 - x0, y1 - y0))
    local k = approach('pw' .. id, imgui.IsItemHovered() and 1 or 0)
    local base = running and C.EMBER or ImVec4(0.30, 0.68, 0.16, 1)
    if running then base = mix(base, C.TEXT, 0.06 + 0.06 * math.sin(os.clock() * 3)) end
    dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), cu(base, 1), 16 * S)
    local lbl = u8(running and 'СТОП' or 'СТАРТ')
    pf(F.header); local ts = imgui.CalcTextSize(lbl); pp(F.header)
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    if vertical then
        local ih = faOK and 50 * S or 0
        local gy = cy - (ih + (faOK and 8 * S or 0) + ts.y) / 2
        if faOK then iconAt(dl, IC.power, x0, gy, x1 - x0, ih, cu(C.TEXT), F.iconBig) end
        pf(F.header); dl:AddText(ImVec2(cx - ts.x / 2, gy + ih + (faOK and 8 * S or 0)), cu(C.TEXT), lbl); pp(F.header)
    else
        local iw = faOK and 30 * S or 0
        local x = cx - (iw + ts.x) / 2
        iconAt(dl, IC.power, x, y0, 24 * S, y1 - y0, cu(C.TEXT))
        pf(F.header); dl:AddText(ImVec2(x + iw, cy - ts.y / 2), cu(C.TEXT), lbl); pp(F.header)
    end
    return clicked
end

internal.closeButton = function(dl, x0, y0, x1, y1, id)
    local mp = imgui.GetMousePos()
    local over = mp.x >= x0 and mp.x <= x1 and mp.y >= y0 and mp.y <= y1
    dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), cu(C.GREY, over and 0.9 or 0.55), 6 * S)
    if faOK then iconAt(dl, IC.xmark, x0, y0, x1 - x0, y1 - y0, cu(C.TEXT), (y1 - y0) > 50 * S and F.iconBig or F.icon)
    else
        local m = (y1 - y0) * 0.3
        dl:AddLine(ImVec2(x0 + m, y0 + m), ImVec2(x1 - m, y1 - m), cu(C.TEXT), 3 * S)
        dl:AddLine(ImVec2(x1 - m, y0 + m), ImVec2(x0 + m, y1 - m), cu(C.TEXT), 3 * S)
    end
    return over and imgui.IsMouseClicked(0)
end

--меню
local function openMenu()
    menuOpen[0] = not menuOpen[0]
    if menuOpen[0] then
        cfg.winX, cfg.winY = false, false
        menuOpenT = os.clock()
        lastFrameT = menuOpenT
    end
end

imgui.OnFrame(function() return menuOpen[0] end, function()
    pcall(loadTextures)
    local now = os.clock()
    dt = now - lastFrameT
    if dt <= 0 or dt > 0.1 then dt = 0.016 end
    lastFrameT = now
    local okIo, ioDt = pcall(function() return imgui.GetIO().DeltaTime end)
    if okIo and type(ioDt) == 'number' and ioDt > 0 and ioDt <= 0.1 then dt = ioDt end
    local wt = internal.wall()
    if wt - (internal.tmDbgT or -100) > 5 then
        internal.tmDbgT = wt
        dbg(('timing: wall+%.2f clock+%.2f dt=%.4f'):format(wt - (internal.tmW0 or wt), os.clock() - (internal.tmC0 or os.clock()), dt))
        internal.tmW0, internal.tmC0 = wt, os.clock()
    end
    internal.tabEl = (internal.tabEl or 99) + math.min(dt, 0.034)

    local sw, sh = screenSize()
    local W = math.min(940 * S, sw * 0.70)
    local H = math.min(560 * S, sh * 0.75)
    local cxw = sw / 2 - W / 2
    local cyw = sh / 2 - H / 2

    local justOpened = menuOpenT and (os.clock() - menuOpenT) < 0.25
    if justOpened and not winDrag.on then
        cfg.winX, cfg.winY = cxw, cyw
    end
    if type(cfg.winX) ~= 'number' or type(cfg.winY) ~= 'number'
        or cfg.winX ~= cfg.winX or cfg.winY ~= cfg.winY then
        cfg.winX, cfg.winY = cxw, cyw
    end
    cfg.winX = math.max(130, math.min(sw - W, cfg.winX))
    cfg.winY = math.max(80, math.min(sh - H, cfg.winY))

imgui.SetNextWindowPos(ImVec2(cfg.winX, cfg.winY), imgui.Cond.Always)
imgui.SetNextWindowSize(ImVec2(W, H), imgui.Cond.Always)


internal.applyPos = function()
    pcall(function() imgui.SetWindowPos('##sawmill_main', ImVec2(cfg.winX, cfg.winY)) end)
    pcall(function() imgui.SetWindowPosVec2(ImVec2(cfg.winX, cfg.winY)) end)
end

imgui.Begin('##sawmill_main', menuOpen,
    imgui.WindowFlags.NoResize + imgui.WindowFlags.NoTitleBar +
    imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoCollapse +
    imgui.WindowFlags.NoBackground + imgui.WindowFlags.NoMove)

    local actualSize = imgui.GetWindowSize()
    W, H = actualSize.x, actualSize.y
    local wp, dl = imgui.GetWindowPos(), imgui.GetWindowDrawList()
    local mp = imgui.GetMousePos()

    woodPanel(dl, wp.x, wp.y, wp.x + W, wp.y + H)

local io = imgui.GetIO()
local mouseDown    = io.MouseDown[0]
local mouseClicked = io.MouseClicked[0]

local txw = wp.x + 20 * S + 190 * S
local dragX0, dragY0 = wp.x + 4 * S, wp.y + 4 * S
local dragX1, dragY1 = txw, wp.y + 14 * S + 26 * S + (190 * S * 226 / 247) - 4 * S
if mp.x >= dragX0 and mp.x <= dragX1 and mp.y >= dragY0 and mp.y <= dragY1
    and mouseClicked and not winDrag.on
    and not imgui.IsAnyItemHovered() then
    winDrag.on, winDrag.moved = true, false
    winDrag.ox = mp.x - wp.x
    winDrag.oy = mp.y - wp.y
    scroll.tracking, scroll.moved = false, false
end
if winDrag.on then
    if mouseDown then
        cfg.winX = math.max(130, math.min(sw - W, mp.x - winDrag.ox))
        cfg.winY = math.max(80,  math.min(sh - H, mp.y - winDrag.oy))
        winDrag.moved = true
        internal.applyPos()
    else
        if winDrag.moved then saveCfg() end
        winDrag.on, winDrag.moved = false, false
    end
end

    local tx, tw, th = wp.x + 20 * S, 190 * S, 46 * S
    local ah = tw * 226 / 247
    pf(F.title); dl:AddText(ImVec2(tx, wp.y + 14 * S), cu(C.GOLD), u8('ЛЕСОПИЛКА')); pp(F.title)
    if TEX.art then
        dl:AddImage(TEX.art,
            ImVec2(tx, wp.y + 14 * S + 26 * S),
            ImVec2(tx + tw, wp.y + 14 * S + 26 * S + ah))
    end

    local tabsTop = wp.y + 14 * S + 26 * S + ah
    local pillY = approach('pillY', tabsTop + (tab - 1) * (th + 8 * S), 15)
    dl:AddRectFilled(ImVec2(tx, pillY), ImVec2(tx + tw, pillY + th),
        cu(mix(C.WOODD, C.WOOD, 0.3)), th / 2)
    for i, tb in ipairs(TABS) do
        local y0 = wp.y + 14 * S + 26 * S + ah + (i - 1) * (th + 8 * S)
        imgui.SetCursorScreenPos(ImVec2(tx, y0))
        local tabBtn = imgui.InvisibleButton('##tab' .. i, ImVec2(tw, th))
        if tabBtn or (imgui.IsItemHovered() and imgui.IsMouseClicked(0) and not winDrag.on) then tab = i end
        local act = tab == i
        local k = approach('tab' .. i, ((not act) and imgui.IsItemHovered()) and 0.35 or 0, 12)
        if k > 0.01 then
            dl:AddRectFilled(ImVec2(tx, y0), ImVec2(tx + tw, y0 + th),
                cu(mix(C.WOODD, C.WOOD, 0.3), k), th / 2)
        end
        local near = 1 - math.max(0, math.min(1, math.abs(pillY - y0) / (th + 8 * S)))
        local col = cu(mix(C.DIM, C.TEXT, near))
        pf(F.main); local ls = imgui.CalcTextSize(u8(tb.label)); pp(F.main)
        local iw = faOK and 30 * S or 0
        local sx = tx + 12 * S
        iconAt(dl, tb.icon, sx, y0, 22 * S, th, col)
        pf(F.main); dl:AddText(ImVec2(sx + iw, y0 + (th - ls.y) / 2), col, u8(tb.label)); pp(F.main)
    end

    local authorY = wp.y + 14 * S + 26 * S + ah + #TABS * (th + 8 * S) + 6 * S
    pf(F.small)
    dl:AddText(ImVec2(tx + 12 * S, authorY), cu(C.DIM),
        u8('v' .. thisScript().version .. '  ·  ' .. AUTHOR))
    pp(F.small)

    if tab ~= tabPrev then internal.tabFrom, tabSwitchT, tabPrev = tabPrev, internal.wall(), tab; internal.tabEl = 0; scroll.y, scroll.vel = 0, 0; internal.numEpoch = (internal.numEpoch or 0) + 1; internal.scrollReset = true end

    local contentLeft = 20 * S + tw + 22 * S + 4 * S
    local contentTop  = 6 * S
    local cx = wp.x + contentLeft
    local cy = wp.y + contentTop
    local cw = W - contentLeft - 10 * S
    local ch = H - contentTop - 6 * S

    woodPanel(dl, cx, cy, cx + cw, cy + ch)
    pcall(internal.drawDust, dl, cx, cy, cx + cw, cy + ch)
    pcall(internal.drawLeaves, dl, cx, cy, cx + cw, cy + ch)

    local childOpen = false
    local function contentBlock()
        local mp2 = imgui.GetMousePos()
        local inContent = mp2.x >= cx and mp2.x <= cx + cw
                      and mp2.y >= cy and mp2.y <= cy + ch

        imgui.SetCursorScreenPos(ImVec2(cx, cy))
        imgui.PushStyleVarFloat(imgui.StyleVar.ScrollbarSize, 0)
        local childFlags = imgui.WindowFlags.NoBackground + imgui.WindowFlags.NoScrollWithMouse
        imgui.BeginChild('##scroll_area', ImVec2(cw, ch), false, childFlags)
        childOpen = true
        scroll.inContent = inContent
        touchLock.on = internal.holdNext == true
        internal.holdNext = false
        if not winDrag.on then pcall(touchScroll, 14 * S) end
        local tabIdx, rise, wa, shiftX = tab, 0, 1, 0
        internal.fadeFn = nil
        local tsp = (tonumber(cfg.tabSpeed) or 100) / 100
        if tsp < 0.3 then tsp = 0.3 elseif tsp > 4 then tsp = 4 end
        local el = (internal.tabEl or 99) * tsp
        if cfg.tabAnim ~= false and el >= 0 and el < 0.95 then
            local tf = internal.tabFrom
            local hadOld = tf and tf ~= tab and TABS[tf]
            if hadOld and el < 0.24 then
                local k = el / 0.24
                tabIdx = tf
                wa = 1 - k * k
                shiftX = -30 * S * k
                internal.fadeFn = function() return wa end
            else
                local base = el - (hadOld and 0.24 or 0)
                local pr = math.max(0, math.min(1, base / 0.42))
                pr = pr * pr * (3 - 2 * pr)
                rise = 54 * S * (1 - pr)
                wa = math.max(0, math.min(1, base / 0.30))
                wa = wa * wa * (3 - 2 * wa)
                internal.fadeFn = function()
                    local y = 0
                    local okY, cyp = pcall(imgui.GetCursorPosY)
                    if okY and type(cyp) == 'number' then y = cyp end
                    local d = math.min(0.25, math.max(0, y) / (70 * S) * 0.035)
                    local k = math.max(0, math.min(1, (base - d) / 0.30))
                    return k * k * (3 - 2 * k)
                end
            end
        end
        if internal.scrollReset and tabIdx == tab then
            internal.scrollReset = false
            pcall(imgui.SetScrollY, 0)
            scroll.vel = 0
            if TABS[tab].draw ~= internal.tabAbout then authorData.page = 'profile' end
        end
        local pushedA = false
        if wa < 1 then pushedA = pcall(imgui.PushStyleVarFloat, imgui.StyleVar.Alpha, math.max(0.02, wa)) end
        imgui.Dummy(ImVec2(1, 12 * S + rise))
        imgui.Indent(12 * S + shiftX)
        local ok, err = pcall(TABS[tabIdx].draw)
        if pushedA then imgui.PopStyleVar() end
        internal.fadeFn = nil
        if not ok then
            dbg('tab draw error [' .. tostring(TABS[tab].label) .. ']: ' .. tostring(err))
            imgui.TextColored(C.DIM, u8('Ошибка вкладки. Подробности: sawbot_debug.txt'))
        end
        imgui.Unindent(12 * S + shiftX)
        imgui.Dummy(ImVec2(1, 12 * S))
        imgui.EndChild()
        imgui.PopStyleVar()
        childOpen = false
    end
    local okb, errb = xpcall(contentBlock, debug.traceback)
    if not okb then
        if childOpen then pcall(imgui.EndChild); childOpen = false end
        internal.dbgOnce('content block error', errb)
    end

    local cs = 30 * S
    if internal.closeButton(dl, wp.x + W - cs - 6 * S, wp.y + 6 * S,
                   wp.x + W - 6 * S, wp.y + 6 * S + cs, '##close') then
        menuOpen[0] = false
    end

    imgui.End()
end)

--сообщения
imgui.OnFrame(function() return cfg.toasts ~= false and #internal.toasts > 0 end, function(self)
    self.HideCursor = true
    local list = internal.toasts
    local nowT = os.clock()
    for i = #list, 1, -1 do
        if nowT - list[i].t0 > 4.2 then table.remove(list, i) end
    end
    if #list == 0 then return end
    local sw = screenSize()
    local tw, th, gap = 270 * S, 46 * S, 8 * S
    imgui.SetNextWindowPos(ImVec2(sw - tw - 10 * S, 10 * S), imgui.Cond.Always)
    imgui.SetNextWindowSize(ImVec2(tw + 10 * S, #list * (th + gap) + 6 * S), imgui.Cond.Always)
    imgui.Begin('##saw_toasts', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar
        + imgui.WindowFlags.NoBackground + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoBringToFrontOnFocus
        + (imgui.WindowFlags.NoInputs or 0))
    local dl, wp = imgui.GetWindowDrawList(), imgui.GetWindowPos()
    for i, ts in ipairs(list) do
        local e = nowT - ts.t0
        local pin = math.max(0, math.min(1, e / 0.35))
        pin = 1 - (1 - pin) ^ 3
        local pout = math.max(0, math.min(1, (e - 3.8) / 0.4))
        local slide = (1 - pin + pout) * (tw + 20 * S)
        local a = 1 - pout
        local x0, y0 = wp.x + slide, wp.y + (i - 1) * (th + gap)
        local x1, y1 = x0 + tw, y0 + th
        dl:AddRectFilled(ImVec2(x0, y0), ImVec2(x1, y1), cu(C.PLANK, 0.94 * a), 12 * S)
        dl:AddRect(ImVec2(x0, y0), ImVec2(x1, y1), cu(ts.col, a), 12 * S, 0, 2 * S)
        dl:AddCircleFilled(ImVec2(x0 + 20 * S, y0 + th / 2 - 2 * S), 7 * S, cu(ts.col, a), 14)
        pf(F.small)
        local txt = ts.text
        local maxW = tw - 50 * S
        while #txt > 4 and imgui.CalcTextSize(u8(txt)).x > maxW do txt = txt:sub(1, -2) end
        if txt ~= ts.text then txt = txt .. '...' end
        dl:AddText(ImVec2(x0 + 38 * S, y0 + th / 2 - 11 * S), cu(C.TEXT, a), u8(txt))
        pp(F.small)
        local left = math.max(0, 1 - e / 4.2)
        dl:AddRectFilled(ImVec2(x0 + 14 * S, y1 - 6 * S), ImVec2(x0 + 14 * S + (tw - 28 * S) * left, y1 - 4 * S), cu(ts.col, a))
    end
    imgui.End()
end)

internal.fabDrag = {on = false, pressT = 0, ox = 0, oy = 0}
imgui.OnFrame(function() return cfg.fab end, function(self)
    pcall(loadTextures)
    internal.tickDt()
    self.HideCursor = true
    local sw, sh = screenSize()
    local bw, mw, gap, bh = 190 * S, 58 * S, 8 * S, 58 * S
    local x = math.max(0, math.min(sw - bw - gap - mw, cfg.fabX or 30 * S))
    local y = math.max(0, math.min(sh - bh, cfg.fabY or sh * 0.42))
    imgui.SetNextWindowPos(ImVec2(x, y), imgui.Cond.Always)
    imgui.SetNextWindowSize(ImVec2(bw + gap + mw, bh + 6 * S), imgui.Cond.Always)
    imgui.Begin('##saw_fab', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar
        + imgui.WindowFlags.NoBackground + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoBringToFrontOnFocus)
    local dl, wp, io = imgui.GetWindowDrawList(), imgui.GetWindowPos(), imgui.GetIO()
    local mp = imgui.GetMousePos()
    local inside = mp.x >= wp.x and mp.x <= wp.x + bw + gap + mw and mp.y >= wp.y and mp.y <= wp.y + bh + 6 * S

    if imgui.IsMouseClicked(0) and inside then
        internal.fabDrag.on = false
        internal.fabDrag.pressT = os.clock()
        internal.fabDrag.ox, internal.fabDrag.oy = mp.x - wp.x, mp.y - wp.y
    end
    if imgui.IsMouseDown(0) and internal.fabDrag.pressT > 0 then
        if not internal.fabDrag.on and os.clock() - internal.fabDrag.pressT >= 2 then internal.fabDrag.on = true end
        if internal.fabDrag.on then
            cfg.fabX = math.max(0, math.min(sw - bw - gap - mw, mp.x - internal.fabDrag.ox))
            cfg.fabY = math.max(0, math.min(sh - bh - 6 * S, mp.y - internal.fabDrag.oy))
        end
    elseif internal.fabDrag.pressT > 0 then
        if internal.fabDrag.on then saveCfg() end
        internal.fabDrag.on, internal.fabDrag.pressT = false, 0
    end

    local clicked = internal.powerButton(dl, wp.x, wp.y, wp.x + bw, wp.y + bh, '##fab_go', false)
    if clicked and not internal.fabDrag.on then toggleBot() end
    local mx = wp.x + bw + gap
    imgui.SetCursorScreenPos(ImVec2(mx, wp.y))
    if imgui.InvisibleButton('##fab_menu', ImVec2(mw, bh)) and not internal.fabDrag.on then openMenu() end
    dl:AddRectFilled(ImVec2(mx, wp.y), ImVec2(mx + mw, wp.y + bh), cu(menuOpen[0] and C.WOODD or C.GREY, 1), 14 * S)
    if faOK then iconAt(dl, IC.bars, mx, wp.y, mw, bh, cu(C.TEXT))
    else for k = -1, 1 do local hy = wp.y + bh / 2 + k * 7 * S; dl:AddLine(ImVec2(mx + 16 * S, hy), ImVec2(mx + mw - 16 * S, hy), cu(C.TEXT), 3 * S) end end
    if internal.fabDrag.on then dl:AddRect(ImVec2(wp.x - 3 * S, wp.y - 3 * S), ImVec2(wp.x + bw + gap + mw + 3 * S, wp.y + bh + 9 * S), cu(C.LEAF), 18 * S, 0, 2 * S) end
    imgui.End()
end)

internal.statsOpen = imgui.new.bool(true)
imgui.OnFrame(function() return cfg.statsWin and not menuOpen[0] end, function(self)
    pcall(loadTextures)
    internal.tickDt()
    self.HideCursor = false
    local sw, sh = screenSize()
    local s, sec = stats.session, sessionTime()
    local rows = internal.statRows(s, sec, 'hud')
    local satTxt = '?'
    if st.satiety then
        local sv = cfg.numAnim == false and st.satiety or approach('hud:sat', st.satiety, 8)
        satTxt = math.floor(sv + 0.5) .. '%'
    end
    table.insert(rows, 1, {IC.hotdog, 'Сытость', satTxt})
    local rh = 34 * S
    local H = 66 * S + #rows * rh + 14 * S

    pf(F.main)
    local need = 0
    for _, r in ipairs(rows) do
        local lw = imgui.CalcTextSize(u8(r[2])).x
        local vw = imgui.CalcTextSize(u8(r[3])).x
        local w1 = (faOK and 36 * S or 4 * S) + lw + 14 * S + vw + 28 * S + 16 * S
        if w1 > need then need = w1 end
    end
    pp(F.main)
    pf(F.header)
    local tw = imgui.CalcTextSize(u8('ЛЕСОПИЛКА')).x
    pp(F.header)
    need = math.max(need + 32 * S, (faOK and 50 * S or 16 * S) + tw + 34 * S + 36 * S + 24 * S, 220 * S)
    local W = cfg.numAnim == false and need or approach('hud:w', need, 12)
    local statsX = type(cfg.statsX) == 'number' and cfg.statsX or (sw - W - 20 * S)
    local statsY = type(cfg.statsY) == 'number' and cfg.statsY or (sh * 0.22)
    imgui.SetNextWindowPos(ImVec2(statsX, statsY), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(ImVec2(W, H), imgui.Cond.Always)
    internal.statsOpen[0] = true
    imgui.Begin('##saw_stats', internal.statsOpen, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoBackground)
    local dl, wp = imgui.GetWindowDrawList(), imgui.GetWindowPos()
    woodPanel(dl, wp.x, wp.y, wp.x + W, wp.y + H)
    iconAt(dl, IC.tree, wp.x + 14 * S, wp.y + 12 * S, 30 * S, 36 * S, cu(C.GOLD))
    outlined(dl, wp.x + (faOK and 50 * S or 16 * S), wp.y + 16 * S, C.GOLD, u8('ЛЕСОПИЛКА'), F.header)
    local cs = 34 * S
    if internal.closeButton(dl, wp.x + W - cs - 12 * S, wp.y + 12 * S, wp.x + W - 12 * S, wp.y + 12 * S + cs, '##st_close') then
        cfg.statsWin = false; cfg.statsX, cfg.statsY = wp.x, wp.y; saveCfg()
    end
    local y = wp.y + 60 * S
    pf(F.small)
    local stTxt = u8(running and 'работает' or 'стоит')
    dl:AddText(ImVec2(wp.x + (faOK and 50 * S or 16 * S), wp.y + 42 * S), cu(running and C.LEAF or C.DIM), stTxt)
    pp(F.small)
    for _, r in ipairs(rows) do
        row(dl, wp.x + 16 * S, y, W - 32 * S, rh - 4 * S, r[1], r[2], r[3], r[4])
        y = y + rh
    end
    imgui.End()
end)

internal.renderFeed = function()
    while true do
        if cfg.render then
            local list, near, px, py, pz = {}, {}, pos()
            for _, l in ipairs(treeLabels()) do
                if l.text:find('Доступно для рубки', 1, true) then
                    l.d = getDistanceBetweenCoords2d(px, py, l.x, l.y)
                    list[#list + 1] = l
                end
            end
            table.sort(list, function(a, b) return a.d < b.d end)
            for i = 1, math.min(10, #list) do
                local l = list[i]
                l.gz = groundZ(l.x, l.y, l.z)
                if l.gz == 0 then l.gz = l.z - 1 end
                near[i] = l
            end
            st.freeSides, st.nearFree = list, near
            local t = st.target
            if t and not t.gz then t.gz = groundZ(t.x, t.y, pz) end
        end
        wait(1000)
    end
end

internal.loop = function()
    dbg('loop start')
--работа
    local lastLoopDbg = os.clock()
    while running do
        if os.clock() - lastLoopDbg >= 15 then
            dbg(('loop heartbeat: cart=%s saw=%s chopping=%s'):format(tostring(st.cart ~= nil), tostring(st.saw ~= nil), tostring(st.chopping)))
            lastLoopDbg = os.clock()
        end
        local _, _, z = pos()
        local between = not st.cart and not st.game
        local looseCart = nil
        if between and not st.resumeTreeAfterStolen and z <= 1000 then looseCart = nearestLooseCart() end
        if z > 1000 then exitTrailer()
        elseif st.cart then deliver()
        elseif cfg.autoEat and between and os.clock() >= st.nextSatCheck then checkSatiety()
        elseif cfg.autoEat and between and st.satiety and st.satiety < cfg.eatBelow
            and os.clock() > (st.eatBlockedUntil or 0) then eat()
        elseif between and st.resumeTreeAfterStolen then
            st.resumeTreeAfterStolen = false
            chop()
        elseif between and looseCart then takeLooseCart(looseCart)
        elseif between and st.nextTree then chop()
        elseif not st.saw and cfg.useFrederico then rentSaw()
        else chop() end
        wait(200)
    end
end

--управление
function toggleBot()
    running = not running
    if running then
        internal.runMoney0 = stats.session.money or 0
        st.camPrepared = false
        st.lastCamHeading = nil
        st.passThroughIndex, st.nextTree = nil, nil
    end
    msg(running and 'запущен' or 'остановлен')
    if running then
        aaStart()
        stats.session.start = os.time()
        lua_thread.create(function()
            local ok, err = pcall(internal.loop)
            if not ok then
                running = false
                releaseBotTouches(true)
                dbg('loop fatal: ' .. tostring(err))
                msg('{FF6666}Ошибка запуска/работы. Подробности в sawbot_debug.txt')
            end
        end)
    else
        releaseBotTouches()
        stats.session.last = os.time() - stats.session.start
        stats.total.time = (stats.total.time or 0) + stats.session.last
        local gained = (stats.session.money or 0) - (internal.runMoney0 or 0)
        if gained > 0 then
            stats.total.hist = stats.total.hist or {}
            table.insert(stats.total.hist, {money = gained, time = stats.session.last, t = os.time()})
            while #stats.total.hist > 20 do table.remove(stats.total.hist, 1) end
        end
        saveCfg()
    end
end

--запуск
function main()
    while not isSampAvailable() do wait(100) end
    ensureScriptConfigDir()
    migrateFile(getWorkingDirectory() .. '/config/SawmillBot.json', CFG_PATH)
    migrateFile(getWorkingDirectory() .. '/config/SawmillBot_carts.json', CARTS_PATH)
    migrateFile(getWorkingDirectory() .. '/config/SawmillBot_saw.txt', SAW_PATH)
    migrateFile(getWorkingDirectory() .. '/navgrid.txt', SCRIPT_CONFIG_DIR .. '/navgrid.txt')
    lua_thread.create(downloadAssets)
    lua_thread.create(function()
        while true do
            wait(5000)
            if not assetsReady and not assetsDownloading
                and os.clock() - assetsLastAttempt >= 20 then
                lua_thread.create(downloadAssets)
            end
        end
    end)
    loadCfg()
    cfg.statsWin = cfg.statsWin ~= false
    cfg.aaStopVehicle = cfg.aaStopVehicle ~= false
    cfg.aiEnabled  = cfg.aiEnabled == true
    cfg.aiKey      = cfg.aiKey or ''
    cfg.aiEndpoint = cfg.aiEndpoint or 'https://api.openai.com/v1'
    cfg.aiModel    = cfg.aiModel or ''
    cfg.aiSystem   = cfg.aiSystem or ''
    ai.enabled  = cfg.aiEnabled
    ai.apiKey   = cfg.aiKey
    ai.endpoint = cfg.aiEndpoint
    ai.model    = cfg.aiModel
    ai.system   = cfg.aiSystem ~= '' and cfg.aiSystem or ai.DEFAULT_SYSTEM
    local okP = false
    for _, o in ipairs(internal.PERIODS) do if o[1] == cfg.statPeriod then okP = true end end
    if not okP then cfg.statPeriod = 'all' end
    internal.tickAt = os.clock()
    pcall(internal.dayRoll)
    lua_thread.create(function()
        while true do
            wait(5000)
            local now = os.clock()
            local dtm = now - (internal.tickAt or now)
            internal.tickAt = now
            pcall(function()
                local t = internal.dayRoll()
                if running then
                    t.d.time = t.d.time + dtm
                    local e = internal.hourSlot(t.d, tonumber(os.date('%H')))
                    e.time = e.time + dtm
                    t.dirty = true
                end
                internal.dayFlush()
            end)
        end
    end)
    navLoad()
    loadCarts()
    loadSaw()
    lua_thread.create(internal.renderFeed)
    lua_thread.create(function()
        local lastStamina = nil
        while true do
            local enabled = cfg.antiStamina == true
            if enabled ~= lastStamina then
                lastStamina = enabled
                pcall(setPlayerNeverGetsTired, 0, enabled)
            end
            if enabled then
                pcall(setPlayerNeverGetsTired, 0, true)
                pcall(setAnimGroupForChar, PLAYER_PED, 'PLAYER')
            end
            wait(1000)
        end
    end)
    sampRegisterChatCommand('sawgo', function(arg)
        local x, y = arg:match('(%S+)%s+(%S+)')
        if not x or running then return end
        lua_thread.create(function()
            running = true
            local ok = walkTo(tonumber(x), tonumber(y), 2.0, 120)
            running = false
            dbg('sawgo ' .. arg .. ' -> ' .. tostring(ok))
        end)
    end)
    sampRegisterChatCommand('saw', openMenu)
    sampRegisterChatCommand('sawcenter', function()
        cfg.winX, cfg.winY, cfg.fabX, cfg.fabY = false, false, false, false
        saveCfg()
        msg('Позиции окон сброшены')
    end)
    sampRegisterChatCommand('sawrun', toggleBot)
    sampRegisterChatCommand('sawtab', function(a) sawTab(tonumber(a) or 1) end)
    while not sampIsLocalPlayerSpawned() do wait(500) end
    wait(5000)
    wait(-1)
end

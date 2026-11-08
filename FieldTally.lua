-- ============================================================================
-- FIELD TALLY (Cache ReQuest)
-- A small handwritten note of the quest items you still have to collect: "4/7  Small Spider Leg".
-- Only real "collect an item" objectives go on it (objective.type == "item"); kill, explore, use,
-- talk and progress-bar goals never do. Page 1 is always "Near me"; pages 2+ are one per area
-- that still has items to gather.
--
-- Saved data:
--   QRF_SavedState.fieldTally  (per character)  the tally's settings, position and size
--   CRQ_TallyKnowledge         (account-wide)   where items were looted and which mobs dropped them
-- Everything is drawn with colour textures, gradients, lines and vertex offsets: no art files.
-- ============================================================================
local ADDON_NAME, ns = ...
ns = (type(ns) == "table") and ns or {}
local CRQ = ns.CRQ or {}                 -- helpers shared by CacheReQuest.lua (see the end of that file)
local CIRCLE_MASK_TEX = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local DISPLAY_NAME = "Cache ReQuest"

local function ApplyHorizontalGradient(tex, r, g, b, leftAlpha, rightAlpha)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then
        tex:SetGradient("HORIZONTAL", CreateColor(r, g, b, leftAlpha), CreateColor(r, g, b, rightAlpha))
    else
        tex:SetColorTexture(r, g, b, leftAlpha)
    end
end

local function ApplyTwoColorVerticalGradient(tex, r1, g1, b1, a1, r2, g2, b2, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then
        tex:SetGradient("VERTICAL", CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    else
        tex:SetColorTexture(r1, g1, b1, a1)
    end
end

-- ----------------------------------------------------------------------------
-- STATE & SAVED SETTINGS
-- EDIT: the values in T.DEFAULTS are what a new character starts with (each can be changed in
-- Options > AddOns > Cache ReQuest, or with /crq).
-- ----------------------------------------------------------------------------
local T = {
    quests = {},            -- [questID] = quest record (see T.ScanQuests)
    recent = {},            -- [questID] = GetTime() when an item progressed or you targeted its mob
    prevProgress = {},      -- [progKey] = last count seen
    flashUntil = {},        -- [progKey] = GetTime() until which the row flashes
    rowPool = {},
    scroll = 0,
    reportedErrors = {},
    optionWidgets = {},
    countedCorpses = {},
}
ns.Tally = T

T.DEFAULTS = {
    show = true,                    -- the Field Tally is shown
    look = "HANDKERCHIEF",          -- "HANDKERCHIEF", "PARCHMENT" or "NATIVE" (transparent window)
    font = "QUILL",                 -- handwriting: "QUILL", "SCRAWL" or "PLAIN"
    nearRadius = 10,                -- "Near me": how close (% of the zone map) the items must be
    pageRadius = 16,                -- distance grouping: page size (% of the zone map)
    grouping = "AREA",              -- area pages by "AREA" (map areas), "ZONE" or "RADIUS" (distance)
    opts = {
        showTabs = true,                -- a page for every other area with items to gather
        pagesFollowTracker = true,      -- distance pages use the tracker's (•••) stacking radius
        autoFrontOnAreaChange = true,   -- "Near me" comes back to the front when you enter a new area
        hideWhenNothingNearby = false,  -- hide the tally when nothing near you needs gathering
        inkEffects = true,              -- glow in hunting grounds, fire when your target drops it
        mapPreview = true,              -- hovering an item shows a little map of where it's gathered
        minimapPins = true,             -- looted-here spots of the super-tracked quest on the minimap
        showRewards = true,             -- the quest's reward / currency at the right of its item line
        trackerGear = true,             -- options gear on the Objective Tracker header
    },
    -- EDIT: width / height are the default size in pixels (also what "Reset Position & Size" uses)
    frame = { width = 230, height = 175, point = "BOTTOMLEFT", relPoint = "BOTTOMLEFT", x = 36, y = 250,
              useDefaultAnchor = true },
    questAreas = {},                -- [questID] = subzone where its objectives were last worked
}

-- Current settings start as a copy of the defaults (replaced by the saved ones on load)
function T.CopyDefaults()
    local d = T.DEFAULTS
    local db = { show = d.show, look = d.look, font = d.font, nearRadius = d.nearRadius,
        pageRadius = d.pageRadius, grouping = d.grouping, opts = {}, frame = {}, questAreas = {} }
    for k, v in pairs(d.opts) do db.opts[k] = v end
    for k, v in pairs(d.frame) do db.frame[k] = v end
    return db
end
T.db = T.CopyDefaults()
T.K = { version = 1, spots = {}, droppers = {}, owners = {}, kept = {} }

local function ValidKey(list, key)
    for _, e in ipairs(list) do if e.key == key then return true end end
    return false
end

-- Reads the saved settings over the defaults, keeping only values of the right type and range
function T.LoadSaved()
    local db = T.CopyDefaults()
    local sv = (type(QRF_SavedState) == "table") and QRF_SavedState.fieldTally or nil
    if type(sv) == "table" then
        if type(sv.show) == "boolean" then db.show = sv.show end
        if ValidKey(T.P.STYLES, sv.look) then db.look = sv.look end
        if ValidKey(T.P.FONT_STYLES, sv.font) then db.font = sv.font end
        if ValidKey(T.P.GROUPINGS, sv.grouping) then db.grouping = sv.grouping end
        if type(sv.nearRadius) == "number" then db.nearRadius = math.max(1, math.min(50, math.floor(sv.nearRadius + 0.5))) end
        if type(sv.pageRadius) == "number" then db.pageRadius = math.max(1, math.min(50, math.floor(sv.pageRadius + 0.5))) end
        if type(sv.opts) == "table" then
            for k in pairs(db.opts) do
                if type(sv.opts[k]) == "boolean" then db.opts[k] = sv.opts[k] end
            end
        end
        local fr = sv.frame
        if type(fr) == "table" then
            if type(fr.width) == "number" then db.frame.width = math.max(185, math.min(520, fr.width)) end
            if type(fr.height) == "number" then db.frame.height = math.max(95, math.min(520, fr.height)) end
            if type(fr.point) == "string" then db.frame.point = fr.point end
            if type(fr.relPoint) == "string" then db.frame.relPoint = fr.relPoint end
            if type(fr.x) == "number" then db.frame.x = fr.x end
            if type(fr.y) == "number" then db.frame.y = fr.y end
            if type(fr.useDefaultAnchor) == "boolean" then db.frame.useDefaultAnchor = fr.useDefaultAnchor end
        end
        if type(sv.questAreas) == "table" then
            for k, v in pairs(sv.questAreas) do
                if type(k) == "number" and type(v) == "string" then db.questAreas[k] = v end
            end
        end
    end
    T.db = db

    local K = (type(CRQ_TallyKnowledge) == "table") and CRQ_TallyKnowledge or {}
    for _, key in ipairs({ "spots", "droppers", "owners", "kept" }) do
        if type(K[key]) ~= "table" then K[key] = {} end
    end
    K.version = 1
    CRQ_TallyKnowledge = K
    T.K = K
    T.Save()
end

-- Settings live in QRF_SavedState.fieldTally; CacheReQuest's own SaveState() never touches that key.
function T.Save()
    if type(QRF_SavedState) ~= "table" then QRF_SavedState = {} end
    QRF_SavedState.fieldTally = T.db
    CRQ_TallyKnowledge = T.K
end

-- "Name-Realm": whose quest log a piece of loot knowledge belongs to (for pruning)
function T.CharKey()
    local name = UnitName and T.Plain(UnitName("player")) or nil
    local realm = GetRealmName and T.Plain(GetRealmName()) or nil
    return (name or "?") .. "-" .. (realm or "?")
end

-- Errors in the tally's code go to the normal error handler once each, never every frame
function T.ReportError(err)
    local msg = tostring(err)
    if T.reportedErrors[msg] then return end
    T.reportedErrors[msg] = true
    local h = geterrorhandler and geterrorhandler()
    if h then h(DISPLAY_NAME .. " Field Tally: " .. msg) end
end

function T.SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then T.ReportError(err) end
    return ok
end

-- ----------------------------------------------------------------------------
-- RETAIL RESTRICTIONS (12.x "secret values")
-- In restricted content (combat in instances, arenas, ...) some unit, tooltip and loot values come
-- back as secrets: addons may not compare them, test them or use them as table keys. Everything the
-- tally reads about units, tooltips and loot goes through T.Plain, which turns a secret into nil, so
-- drop detection simply pauses there instead of erroring.
-- ----------------------------------------------------------------------------
function T.Plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- pcall a Blizzard API and return its first three results with any secrets turned into nil
function T.Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return T.Plain(a), T.Plain(b), T.Plain(c)
end

function T.UnitStr(api, unit)
    local v = T.Call(api, unit)
    return (type(v) == "string" and v ~= "") and v or nil
end

function T.UnitFlag(api, ...)
    return T.Call(api, ...) == true
end

-- Player position on the best map for where you stand (nil inside instances, where it's hidden)
function T.PlayerPos()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil, nil, nil end
    local mapID = T.Call(C_Map.GetBestMapForUnit, "player")
    if type(mapID) ~= "number" then return nil, nil, nil end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if ok and type(pos) == "table" and pos.GetXY then
        local x, y = pos:GetXY()
        x, y = T.Plain(x), T.Plain(y)
        if type(x) == "number" and type(y) == "number" and (x > 0 or y > 0) then return mapID, x, y end
    end
    return mapID, nil, nil
end

function T.MapPosToWorld(mapID, x, y)
    if not (mapID and x and y and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if ok and continentID and worldPos and worldPos.GetXY then
        local wx, wy = worldPos:GetXY()
        if wx and wy then return continentID, wx, wy end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- QUEST DATA: every quest with counted objectives, and the subset that goes on the tally
-- ----------------------------------------------------------------------------
-- Only "item" objectives belong on the tally: things that go into your bags. Everything else is a
-- goal, not loot: "monster" (kills), "object" (use / click), "event" (explore, escort, talk),
-- "reputation", "progressbar", "spell", "player", "log", ...
function T.IsCollectItemObjective(objType)
    return objType == "item"
end

-- "4/7 Small Spider Leg", "Small Spider Leg: 4/7", "Small Spider Leg (4/7)" -> "Small Spider Leg"
function T.ItemName(text)
    local s = string.gsub(tostring(text or ""), "^%s*%-+%s*", "")
    s = string.gsub(s, "^%s*%d+%s*/%s*%d+%s*", "")
    s = string.gsub(s, "%s*%(%s*%d+%s*/%s*%d+%s*%)%s*$", "")
    s = string.gsub(s, "%s*:?%s*%d+%s*/%s*%d+%s*$", "")
    s = string.gsub(s, "%s*:%s*$", "")
    return strtrim(s)
end

function T.StripTitle(title)
    if CRQ.StripLeadingLevelTag then return CRQ.StripLeadingLevelTag(title) end
    return strtrim(tostring(title or ""))
end

function T.IsReady(questID)
    if CRQ.IsQuestReadyForTurnIn then return CRQ.IsQuestReadyForTurnIn(questID) == true end
    return T.Call(C_QuestLog and C_QuestLog.ReadyForTurnIn, questID) == true
end

-- World quests, bonus objectives and other task quests count while you're in them
function T.IsActiveTask(questID)
    return T.Call(C_TaskQuest and C_TaskQuest.IsActive, questID) == true
end

function T.LevelHex(level)
    local c = GetQuestDifficultyColor and level and GetQuestDifficultyColor(level)
    if type(c) == "table" and c.r then
        return string.format("FF%02X%02X%02X", math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
    end
    return "FFFFD100"
end

-- With a CacheReQuest reward filter on, only quests that match it; with none, every quest
function T.PassesFilter(questID)
    local count = CRQ.GetActiveFilterCount and CRQ.GetActiveFilterCount() or 0
    if count == 0 or not CRQ.DoesQuestMatchFilter then return true end
    return CRQ.DoesQuestMatchFilter(questID) == true
end

function T.CompareQuests(a, b)
    if (a.header or "") ~= (b.header or "") then return (a.header or "") < (b.header or "") end
    if (a.logIndex or 0) ~= (b.logIndex or 0) then return (a.logIndex or 0) < (b.logIndex or 0) end
    return a.questID < b.questID
end

function T.ZoneNameOfMap(mapID)
    if not mapID then return nil end
    local info = T.Call(C_Map and C_Map.GetMapInfo, mapID)
    return (type(info) == "table" and info.name ~= "" and info.name) or nil
end

-- Builds one quest record. Returns nil when the quest has nothing counted.
function T.ReadQuest(questID, rawTitle, header, level, logIndex, isTask)
    local ok, objs = pcall(C_QuestLog.GetQuestObjectives, questID)
    if not ok or type(objs) ~= "table" or #objs == 0 then return nil end
    local isComplete = T.IsReady(questID)
    local now = GetTime()
    local counted, items = {}, {}
    for idx, obj in ipairs(objs) do
        local need = tonumber(obj.numRequired)
        if type(obj.text) == "string" and obj.text ~= "" and need and need >= 1 then
            local cur = tonumber(obj.numFulfilled) or 0
            local finished = (obj.finished == true) or isComplete or cur >= need
            if finished and cur < need then cur = need end
            local progKey = tostring(questID) .. "_" .. tostring(idx)
            local isItem = T.IsCollectItemObjective(obj.type)
            local prev = T.prevProgress[progKey]
            if prev ~= nil and cur > prev then
                T.flashUntil[progKey] = now + 2.0
                T.recent[questID] = now
                -- an item just went into your bags: remember where, and what you looted it from
                if isItem then T.SafeCall(T.OnItemProgress, questID, progKey) end
            end
            T.prevProgress[progKey] = cur
            local o = { index = idx, progKey = progKey, text = obj.text, itemName = T.ItemName(obj.text),
                objType = obj.type, numFulfilled = cur, numRequired = need, finished = finished, isItem = isItem }
            table.insert(counted, o)
            if isItem then table.insert(items, o) end
        end
    end
    if #counted == 0 then return nil end
    local q = {
        questID = questID, title = T.StripTitle(rawTitle or T.Call(C_QuestLog.GetTitleForQuestID, questID) or ("Quest #" .. questID)),
        header = header or "Quests", level = level, levelHex = T.LevelHex(level), logIndex = logIndex or 0,
        isTask = isTask == true, isComplete = isComplete, quantityObjectives = counted, itemObjectives = items,
    }
    if #items > 0 and CRQ.GetQuestCoordsSafe then
        local okC, mapID, x, y = pcall(CRQ.GetQuestCoordsSafe, questID)
        if okC then q.mapID, q.x, q.y = mapID, x, y end
    end
    return q
end

function T.ScanQuests()
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo and C_QuestLog.GetQuestObjectives) then return end
    local quests = {}
    local header = "Quests"
    local n = T.Call(C_QuestLog.GetNumQuestLogEntries) or 0
    for i = 1, n do
        local info = T.Call(C_QuestLog.GetInfo, i)
        if type(info) == "table" then
            if info.isHeader then
                header = info.title or header
            elseif info.questID and not quests[info.questID] then
                local qID = info.questID
                local task = info.isTask or T.IsActiveTask(qID)
                if not info.isHidden or T.IsActiveTask(qID) then
                    local h = task and (T.ZoneNameOfMap(T.Call(C_TaskQuest and C_TaskQuest.GetQuestZoneID, qID)) or header) or header
                    quests[qID] = T.ReadQuest(qID, info.title, h, info.difficultyLevel or info.level, i, task)
                end
            end
        end
    end
    -- active world quests / bonus objectives on your map that the log doesn't list
    local mapID = T.PlayerPos()
    local getTasks = C_TaskQuest and (C_TaskQuest.GetQuestsOnMap or C_TaskQuest.GetQuestsForPlayerByMapID)
    if mapID and getTasks then
        local list = T.Call(getTasks, mapID)
        for _, info in ipairs(type(list) == "table" and list or {}) do
            local qID = info.questID or info.questId
            if qID and not quests[qID] and T.IsActiveTask(qID) then
                quests[qID] = T.ReadQuest(qID, nil, T.ZoneNameOfMap(mapID) or "Bonus Objectives", nil, 900 + #list, true)
            end
        end
    end
    T.quests = quests
    T.scanned = true
    T.MarkOwners()
end

-- Coalesces bursts of quest events into one scan + redraw
function T.RequestScan(delay)
    if T.scanPending then return end
    T.scanPending = true
    local function Run()
        T.scanPending = false
        T.SafeCall(T.ScanQuests)
        T.SafeCall(T.Update)
    end
    if C_Timer and C_Timer.After then C_Timer.After(delay or 0.2, Run) else Run() end
end

-- ----------------------------------------------------------------------------
-- DRAWING & PAGES
-- EDIT: P.MAX_AREAS = how many pages at most; P.MAX_ROWS = rows drawn at once; INK colours are the
--       defaults before a look applies (the real colours of each look are in P.STYLES further down).
-- ----------------------------------------------------------------------------
local P = {
    CURRENT_KEY = "__HERE__",
    MAX_AREAS = 8,              -- "Near me" + up to 7 other-area pages
    MAX_BACK_SHEETS = 3,
    MAX_ROWS = 18,
    INK       = { 0.10, 0.13, 0.30 },
    INK_RED   = { 0.62, 0.12, 0.12 },
    INK_GREEN = { 0.16, 0.40, 0.20 },
    BACK_SLOTS = {
        { angle =  0.026, dx =  2, dy = -3 },
        { angle = -0.040, dx = -3, dy = -6 },
        { angle =  0.055, dx =  4, dy = -9 },
    },
    areas = {},
    selectedKey = "__HERE__",
    lastAreaSig = nil,
    currentGlowUntil = 0,
}
T.P = P

P.VI_TL = (Enum and Enum.VertexIndex and Enum.VertexIndex.TopLeft) or 1
P.VI_BL = (Enum and Enum.VertexIndex and Enum.VertexIndex.BottomLeft) or 2
P.VI_TR = (Enum and Enum.VertexIndex and Enum.VertexIndex.TopRight) or 3
P.VI_BR = (Enum and Enum.VertexIndex and Enum.VertexIndex.BottomRight) or 4

-- Stable pseudo-random 0..1 so edges don't shimmer while resizing
function P.Hash01(a, b, c)
    local n = (a or 0) * 127.1 + (b or 0) * 311.7 + (c or 0) * 74.7
    local s = math.sin(n) * 43758.5453
    return s - math.floor(s)
end

-- ----------------------------------------------------------------------------
-- ROUGH-CUT SHEET GEOMETRY
-- Each sheet is a body quad plus torn "deckle" strips along all four edges.
-- Vertex offsets give every strip a jagged outer edge and rotate the whole
-- sheet a few degrees (back sheets) without any custom art files.
-- ----------------------------------------------------------------------------
function P.PlaceQuad(sheet, tex, x0, y0, x1, y1, tlx, tly, blx, bly, trx, try, brx, bry)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", sheet, "CENTER", (x0 + x1) * 0.5, (y0 + y1) * 0.5)
    tex:SetSize(math.max(0.5, x1 - x0), math.max(0.5, y1 - y0))
    if tex.SetVertexOffset then
        local c, s = sheet.cosA or 1, sheet.sinA or 0
        local px, py
        px, py = x0 + (tlx or 0), y1 + (tly or 0)
        tex:SetVertexOffset(P.VI_TL, (px * c - py * s) - x0, (px * s + py * c) - y1)
        px, py = x0 + (blx or 0), y0 + (bly or 0)
        tex:SetVertexOffset(P.VI_BL, (px * c - py * s) - x0, (px * s + py * c) - y0)
        px, py = x1 + (trx or 0), y1 + (try or 0)
        tex:SetVertexOffset(P.VI_TR, (px * c - py * s) - x1, (px * s + py * c) - y1)
        px, py = x1 + (brx or 0), y0 + (bry or 0)
        tex:SetVertexOffset(P.VI_BR, (px * c - py * s) - x1, (px * s + py * c) - y0)
    end
end

function P.GetSheetSeg(sheet, layer, idx)
    local pool = sheet.segs[layer]
    local tex = pool[idx]
    if not tex then
        tex = sheet:CreateTexture(nil, "BACKGROUND", nil, (layer == 1) and 0 or 1)
        local col = (layer == 1) and sheet.opts.rim or sheet.opts.paper
        tex:SetColorTexture(col[1], col[2], col[3], col[4])
        pool[idx] = tex
    end
    tex:Show()
    return tex
end

function P.LayoutSheet(sheet, w, h, angle, dx, dy)
    w = math.floor(w + 0.5)
    h = math.floor(h + 0.5)
    angle = math.floor(angle * 2000 + 0.5) / 2000
    dx = math.floor(dx * 4 + 0.5) / 4
    dy = math.floor(dy * 4 + 0.5) / 4
    local key = w .. ":" .. h .. ":" .. angle .. ":" .. dx .. ":" .. dy
    if sheet.layoutKey == key then return end
    sheet.layoutKey = key

    local parent = sheet:GetParent()
    sheet:ClearAllPoints()
    sheet:SetPoint("TOPLEFT", parent, "TOPLEFT", dx, dy)
    sheet:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", dx, dy)
    sheet.cosA, sheet.sinA = math.cos(angle), math.sin(angle)

    local o = sheet.opts
    local PQ = P.PlaceQuad
    local inset = o.inset or 0
    local hw, hh = w * 0.5 - inset, h * 0.5 - inset

    if sheet.grain then PQ(sheet, sheet.grain, -hw, -hh, hw, hh) end
    if sheet.shadeTop then
        PQ(sheet, sheet.shadeTop, -hw, hh - 20, hw, hh)
        PQ(sheet, sheet.shadeBot, -hw, -hh, hw, -hh + 14)
        PQ(sheet, sheet.shadeL, -hw, -hh, -hw + 9, hh)
        PQ(sheet, sheet.shadeR, hw - 9, -hh, hw, hh)
    end
    if sheet.hem then P.LayoutCloth(sheet, hw, hh) end

    -- Cloth (handkerchief): rounded corners and a scalloped lace edge instead of torn paper
    if o.cloth then
        P.LayoutClothShape(sheet, hw, hh, o.cloth)
        for layer = 1, 2 do
            for _, tex in ipairs(sheet.segs[layer]) do tex:Hide() end
        end
        return
    end
    P.HideClothShape(sheet)
    PQ(sheet, sheet.body, -hw, -hh, hw, hh)

    local D = o.depth or 4
    local minD = o.minDepth or 1
    local segW = o.segW or 8
    local ovIn = o.overlap or 0.6
    local ovAlong = o.overlap and 0 or 0.35
    local hasVO = sheet.body.SetVertexOffset ~= nil
    local seed = sheet.seed
    local layers = o.rim and 2 or 1
    local counts = { 0, 0 }

    for edge = 1, 4 do
        local alongX = (edge <= 2)
        local startV = alongX and (-hw - D * 0.5) or -hh
        local endV = alongX and (hw + D * 0.5) or hh
        local n = math.max(1, math.ceil((endV - startV) / segW))
        local prevD = minD + (D - minD) * P.Hash01(seed, edge, 0)
        for k = 0, n - 1 do
            local a = startV + k * segW
            local b = math.min(endV, a + segW) + ovAlong
            local nextD = minD + (D - minD) * P.Hash01(seed, edge, k + 1)
            for li = 1, layers do
                local layer = (layers == 2) and li or 2
                local extra = (layer == 1) and 1.3 or 0          -- the rim sits 1.3px proud of the paper
                local D2, e0, e1 = D + extra, prevD + extra, nextD + extra
                counts[layer] = counts[layer] + 1
                local tex = P.GetSheetSeg(sheet, layer, counts[layer])
                if not hasVO then
                    local avg = (e0 + e1) * 0.5
                    if edge == 1 then PQ(sheet, tex, a, hh - ovIn, b, hh + avg)
                    elseif edge == 2 then PQ(sheet, tex, a, -hh - avg, b, -hh + ovIn)
                    elseif edge == 3 then PQ(sheet, tex, -hw - avg, a, -hw + ovIn, b)
                    else PQ(sheet, tex, hw - ovIn, a, hw + avg, b) end
                elseif edge == 1 then      -- top: jag the upper vertices
                    PQ(sheet, tex, a, hh - ovIn, b, hh + D2, 0, e0 - D2, 0, 0, 0, e1 - D2, 0, 0)
                elseif edge == 2 then      -- bottom: jag the lower vertices
                    PQ(sheet, tex, a, -hh - D2, b, -hh + ovIn, 0, 0, 0, D2 - e0, 0, 0, 0, D2 - e1)
                elseif edge == 3 then      -- left: jag the outer (left) vertices
                    PQ(sheet, tex, -hw - D2, a, -hw + ovIn, b, D2 - e1, 0, D2 - e0, 0, 0, 0, 0, 0)
                else                       -- right: jag the outer (right) vertices
                    PQ(sheet, tex, hw - ovIn, a, hw + D2, b, 0, 0, 0, 0, e1 - D2, 0, e0 - D2, 0)
                end
            end
            prevD = nextD
        end
    end

    for layer = 1, 2 do
        local pool = sheet.segs[layer]
        for i = counts[layer] + 1, #pool do pool[i]:Hide() end
    end
end

-- ----------------------------------------------------------------------------
-- CLOTH SHAPE (handkerchief look)
-- A rounded rectangle (two crossed rects + a disc in each corner) trimmed all round with a
-- scalloped lace edge: overlapping little discs half tucked under the cloth, each with a thread
-- outline and an embroidered eyelet, rippling slightly. Discs are round, so rotating the sheet
-- only moves their centres.
-- ----------------------------------------------------------------------------
function P.ClothTex(sheet, pool, i, sub)
    local cl = sheet.clothParts
    local list = cl[pool]
    local t = list[i]
    if not t then
        t = sheet:CreateTexture(nil, "BACKGROUND", nil, sub)
        if pool ~= "body2" then t:SetTexture(CIRCLE_MASK_TEX) end   -- a plain white disc
        list[i] = t
    end
    t:Show()
    return t
end

function P.LayoutClothShape(sheet, hw, hh, cl)
    sheet.clothParts = sheet.clothParts or { body2 = {}, corner = {}, lace = {}, thread = {}, eye = {} }
    local PQ = P.PlaceQuad
    local paper = sheet.opts.paper
    local R = math.min(cl.radius or 9, hw, hh)
    local c, s = sheet.cosA or 1, sheet.sinA or 0
    local function Disc(t, x, y, rad, col)
        t:ClearAllPoints()
        t:SetPoint("CENTER", sheet, "CENTER", x * c - y * s, x * s + y * c)
        t:SetSize(rad * 2, rad * 2)
        t:SetVertexColor(col[1], col[2], col[3], col[4])
    end

    -- the cloth itself
    PQ(sheet, sheet.body, -hw, -hh + R, hw, hh - R)
    sheet.body:Show()
    local b2 = P.ClothTex(sheet, "body2", 1, 3)
    b2:SetColorTexture(paper[1], paper[2], paper[3], paper[4])
    PQ(sheet, b2, -hw + R, -hh, hw - R, hh)
    local corners = { { hw - R, hh - R }, { -hw + R, hh - R }, { -hw + R, -hh + R }, { hw - R, -hh + R } }
    for k, cc in ipairs(corners) do
        Disc(P.ClothTex(sheet, "corner", k, 3), cc[1], cc[2], R, paper)
    end

    -- the scalloped lace trim, walked round the outline (counter-clockwise from the bottom-right)
    local counts = { lace = 0, thread = 0, eye = 0 }
    local r = cl.scallop
    if r then
        local step = cl.step or (r * 1.7)
        local ripple = cl.ripple or 0
        local seed = sheet.seed or 0
        local idx = 0
        local function Put(x, y, nx, ny)
            idx = idx + 1
            local w = ripple * math.sin(idx * 0.83 + seed) + ripple * 0.4 * math.sin(idx * 2.3 + seed * 2)
            local cx, cy = x + nx * w, y + ny * w
            if cl.thread then
                counts.thread = counts.thread + 1
                Disc(P.ClothTex(sheet, "thread", counts.thread, 0), cx, cy, r + 1.1, cl.thread)
            end
            counts.lace = counts.lace + 1
            Disc(P.ClothTex(sheet, "lace", counts.lace, 1), cx, cy, r, cl.lace or paper)
            if cl.eyelet then
                counts.eye = counts.eye + 1
                Disc(P.ClothTex(sheet, "eye", counts.eye, 2), cx + nx * r * 0.45, cy + ny * r * 0.45, 1.1, cl.eyelet)
            end
        end
        local function Edge(x0, y0, x1, y1, nx, ny)
            local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
            local n = math.max(1, math.floor(len / step + 0.5))
            for i = 0, n - 1 do
                local t = i / n
                Put(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, nx, ny)
            end
        end
        local function Arc(cx, cy, a0)
            local m = math.max(1, math.floor(R * math.pi * 0.5 / step + 0.5))
            for j = 0, m - 1 do
                local a = a0 + (j / m) * math.pi * 0.5
                local ca, sa = math.cos(a), math.sin(a)
                Put(cx + ca * R, cy + sa * R, ca, sa)
            end
        end
        local pi = math.pi
        Edge(hw, -hh + R, hw, hh - R, 1, 0)
        Arc(hw - R, hh - R, 0)
        Edge(hw - R, hh, -hw + R, hh, 0, 1)
        Arc(-hw + R, hh - R, pi * 0.5)
        Edge(-hw, hh - R, -hw, -hh + R, -1, 0)
        Arc(-hw + R, -hh + R, pi)
        Edge(-hw + R, -hh, hw - R, -hh, 0, -1)
        Arc(hw - R, -hh + R, pi * 1.5)
    end
    for pool, n in pairs(counts) do
        local list = sheet.clothParts[pool]
        for i = n + 1, #list do list[i]:Hide() end
    end
end

function P.HideClothShape(sheet)
    if not sheet.clothParts then return end
    for _, list in pairs(sheet.clothParts) do
        for _, t in ipairs(list) do t:Hide() end
    end
end

function P.CreateSheet(parent, seed, opts)
    local sheet = CreateFrame("Frame", nil, parent)
    sheet:SetAllPoints(parent)
    sheet.seed = seed
    sheet.opts = opts
    sheet.cosA, sheet.sinA = 1, 0
    sheet.segs = { {}, {} }

    sheet.body = sheet:CreateTexture(nil, "BACKGROUND", nil, 3)

    -- Paper grain and edge shading are created on every sheet that may need them, so a style
    -- change can switch them on and off without rebuilding the pile.
    if opts.decor then
        sheet.grain = sheet:CreateTexture(nil, "BACKGROUND", nil, 4)
        sheet.grain:SetTexture("Interface\\QuestFrame\\UI-QuestGreeting-TopLeft")
        -- plain parchment only: the upper part of this art is the quest frame's dark header band
        sheet.grain:SetTexCoord(0.20, 0.95, 0.45, 0.98)
        sheet.shadeTop = sheet:CreateTexture(nil, "BACKGROUND", nil, 5)
        sheet.shadeBot = sheet:CreateTexture(nil, "BACKGROUND", nil, 5)
        sheet.shadeL = sheet:CreateTexture(nil, "BACKGROUND", nil, 5)
        sheet.shadeR = sheet:CreateTexture(nil, "BACKGROUND", nil, 5)
        -- Handkerchief: a woven border (wide band + thin inner stripe), the running stitch that sews
        -- the lace on, soft creases where it was folded in four, and a couple of drape wrinkles
        sheet.hem = {}
        for k = 1, 4 do sheet.hem[k] = sheet:CreateTexture(nil, "BACKGROUND", nil, 6) end
        sheet.hem2 = {}
        for k = 1, 4 do sheet.hem2[k] = sheet:CreateTexture(nil, "BACKGROUND", nil, 6) end
        sheet.folds = {}
        for k = 1, 4 do sheet.folds[k] = sheet:CreateTexture(nil, "BACKGROUND", nil, 5) end
        sheet.drape = {}
        for k = 1, 4 do sheet.drape[k] = sheet:CreateTexture(nil, "BACKGROUND", nil, 5) end
        sheet.stitches = {}
    end

    sheet.Layout = P.LayoutSheet
    P.RestyleSheet(sheet, opts)
    return sheet
end

-- Recolours a sheet for the current style (opts = paper/rim colours + edge shape + decorations)
function P.RestyleSheet(sheet, opts)
    sheet.opts = opts
    sheet.layoutKey = nil
    local pc = opts.paper
    sheet.body:SetColorTexture(pc[1], pc[2], pc[3], pc[4])
    for layer = 1, 2 do
        local col = (layer == 1) and opts.rim or opts.paper
        for _, tex in ipairs(sheet.segs[layer]) do
            if col then tex:SetColorTexture(col[1], col[2], col[3], col[4]) end
        end
    end
    if sheet.grain then
        local g = opts.grain
        sheet.grain:SetShown(g and true or false)
        if g then sheet.grain:SetVertexColor(g[1], g[2], g[3], g[4]) end
    end
    if sheet.shadeTop then
        local s = opts.shade
        for _, t in ipairs({ sheet.shadeTop, sheet.shadeBot, sheet.shadeL, sheet.shadeR }) do t:SetShown(s and true or false) end
        sheet.shadeTop:Hide()        -- no shaded band along the top: sides and foot only
        if s then
            local r, g, b = s[1], s[2], s[3]
            ApplyTwoColorVerticalGradient(sheet.shadeTop, r * 1.2, g * 1.2, b * 1.2, 0.0, r, g, b, 0.34)
            ApplyTwoColorVerticalGradient(sheet.shadeBot, r, g, b, 0.30, r * 1.2, g * 1.2, b * 1.2, 0.0)
            ApplyHorizontalGradient(sheet.shadeL, r, g, b, 0.26, 0.0)
            ApplyHorizontalGradient(sheet.shadeR, r, g, b, 0.0, 0.26)
        end
    end
    if sheet.hem then
        local hem = opts.hem
        local on = hem and true or false
        for k = 1, 4 do
            sheet.hem[k]:SetShown(on)
            sheet.hem2[k]:SetShown(on and hem.stripe ~= nil)
            sheet.folds[k]:SetShown(on)
            sheet.drape[k]:SetShown(on)
        end
        if hem then
            for k = 1, 4 do
                sheet.hem[k]:SetColorTexture(hem.band[1], hem.band[2], hem.band[3], hem.band[4])
                if hem.stripe then sheet.hem2[k]:SetColorTexture(hem.stripe[1], hem.stripe[2], hem.stripe[3], hem.stripe[4]) end
            end
            -- creases fade out to either side: the shadowed half, then the half catching the light
            local d, l = hem.creaseDark, hem.creaseLight
            ApplyHorizontalGradient(sheet.folds[1], d[1], d[2], d[3], 0, d[4])     -- left of the vertical crease
            ApplyHorizontalGradient(sheet.folds[2], l[1], l[2], l[3], l[4], 0)     -- right of it
            ApplyTwoColorVerticalGradient(sheet.folds[3], d[1], d[2], d[3], 0, d[1], d[2], d[3], d[4])   -- below the horizontal crease
            ApplyTwoColorVerticalGradient(sheet.folds[4], l[1], l[2], l[3], l[4], l[1], l[2], l[3], 0)   -- above it
            -- drape wrinkles: same idea, softer
            ApplyHorizontalGradient(sheet.drape[1], d[1], d[2], d[3], 0, d[4] * 0.8)
            ApplyHorizontalGradient(sheet.drape[2], l[1], l[2], l[3], l[4] * 0.8, 0)
            ApplyHorizontalGradient(sheet.drape[3], d[1], d[2], d[3], 0, d[4] * 0.6)
            ApplyHorizontalGradient(sheet.drape[4], l[1], l[2], l[3], l[4] * 0.6, 0)
        end
        for _, ln in ipairs(sheet.stitches) do
            if hem then ln:SetColorTexture(hem.stitch[1], hem.stitch[2], hem.stitch[3], hem.stitch[4]) else ln:Hide() end
        end
    end
end

-- Handkerchief hem band, running stitch and fold creases. Placed with the sheet's rotation so they
-- tilt with it during a page turn.
function P.LayoutCloth(sheet, hw, hh)
    local hem = sheet.opts.hem
    if not hem then
        for _, ln in ipairs(sheet.stitches) do ln:Hide() end
        return
    end
    local PQ = P.PlaceQuad
    -- Woven border: bands on top/bottom run the full width, the side bands stop short of them, so
    -- the corners aren't doubled up
    local b0, b1 = hem.inset or 3, (hem.inset or 3) + (hem.width or 7)
    PQ(sheet, sheet.hem[1], -hw + b0, hh - b1, hw - b0, hh - b0)       -- top band
    PQ(sheet, sheet.hem[2], -hw + b0, -hh + b0, hw - b0, -hh + b1)     -- bottom band
    PQ(sheet, sheet.hem[3], -hw + b0, -hh + b1, -hw + b1, hh - b1)     -- left band
    PQ(sheet, sheet.hem[4], hw - b1, -hh + b1, hw - b0, hh - b1)       -- right band
    if hem.stripe then
        local s0 = b1 + (hem.stripeGap or 2)
        local s1 = s0 + (hem.stripeWidth or 1.2)
        PQ(sheet, sheet.hem2[1], -hw + s0, hh - s1, hw - s0, hh - s0)
        PQ(sheet, sheet.hem2[2], -hw + s0, -hh + s0, hw - s0, -hh + s1)
        PQ(sheet, sheet.hem2[3], -hw + s0, -hh + s1, -hw + s1, hh - s1)
        PQ(sheet, sheet.hem2[4], hw - s1, -hh + s1, hw - s0, hh - s1)
    end
    -- folded in four: soft creases through the middle, slightly off-centre, fading to each side
    local fx, fy = hw * 0.06, -hh * 0.08
    PQ(sheet, sheet.folds[1], fx - 7, -hh + 1, fx, hh - 1)
    PQ(sheet, sheet.folds[2], fx, -hh + 1, fx + 5, hh - 1)
    PQ(sheet, sheet.folds[3], -hw + 1, fy - 7, hw - 1, fy)
    PQ(sheet, sheet.folds[4], -hw + 1, fy, hw - 1, fy + 5)
    -- two drape wrinkles running down from the top-right
    local slant = hh * 0.35
    local yb, yt = hh * 0.05, hh - 2
    local x1, x2 = hw * 0.30, hw * 0.62
    PQ(sheet, sheet.drape[1], x1 - 9, yb, x1, yt, slant, 0, 0, 0, slant, 0, 0, 0)
    PQ(sheet, sheet.drape[2], x1, yb, x1 + 6, yt, slant, 0, 0, 0, slant, 0, 0, 0)
    PQ(sheet, sheet.drape[3], x2 - 7, yb + hh * 0.3, x2, yt, slant * 0.6, 0, 0, 0, slant * 0.6, 0, 0, 0)
    PQ(sheet, sheet.drape[4], x2, yb + hh * 0.3, x2 + 5, yt, slant * 0.6, 0, 0, 0, slant * 0.6, 0, 0, 0)

    -- running stitch that sews the lace on, just inside the cloth's edge (straight runs only:
    -- the corners are rounded)
    local s = hem.stitchInset or 1.8
    local R = (sheet.opts.cloth and sheet.opts.cloth.radius) or 0
    local dash, gap = 3, 2.5
    local c, sn = sheet.cosA or 1, sheet.sinA or 0
    local n = 0
    local function Dash(x0, y0, x1, y1)
        n = n + 1
        local ln = sheet.stitches[n]
        if not ln then
            ln = sheet:CreateLine(nil, "BACKGROUND", nil, 7)
            local st = hem.stitch
            ln:SetColorTexture(st[1], st[2], st[3], st[4])
            ln:SetThickness(1.1)
            sheet.stitches[n] = ln
        end
        ln:SetStartPoint("CENTER", sheet, x0 * c - y0 * sn, x0 * sn + y0 * c)
        ln:SetEndPoint("CENTER", sheet, x1 * c - y1 * sn, x1 * sn + y1 * c)
        ln:Show()
    end
    local x0, x1, y0, y1 = -hw + s, hw - s, -hh + s, hh - s
    local v = x0 + R
    while v + dash <= x1 - R do Dash(v, y1, v + dash, y1); Dash(v, y0, v + dash, y0); v = v + dash + gap end
    v = y0 + R
    while v + dash <= y1 - R do Dash(x0, v, x0, v + dash); Dash(x1, v, x1, v + dash); v = v + dash + gap end
    for i = n + 1, #sheet.stitches do sheet.stitches[i]:Hide() end
end

-- ----------------------------------------------------------------------------
-- POSITIONING (default: just above the chat box, left side of the screen)
-- ----------------------------------------------------------------------------
-- The pages under the top sheet hang up to ~10px below and left of the frame (plus their torn
-- edges and the drop shadow), and swing further out while a page turns. The default spot leaves
-- room for that so the pile never laps over the chat tabs.
-- EDIT: pixels to the right of / above the chat box for the default spot
P.PILE_MARGIN_X = 10
P.PILE_MARGIN_Y = 20

function P.ComputeDefaultAnchor()
    local cf = ChatFrame1
    if cf and cf.GetLeft and cf:GetLeft() and cf:GetTop() then
        local uiScale = UIParent:GetEffectiveScale() or 1
        local ratio = (cf:GetEffectiveScale() or 1) / uiScale
        local left = cf:GetLeft() * ratio
        -- +32 clears the chat tabs that sit on top of the chat frame; use the tab itself when it's taller
        local top = cf:GetTop() * ratio + 32
        local tab = _G.ChatFrame1Tab
        if tab and tab.GetTop and tab:GetTop() then
            local tabTop = tab:GetTop() * ((tab:GetEffectiveScale() or 1) / uiScale)
            if tabTop > top then top = tabTop end
        end
        return math.floor(left + P.PILE_MARGIN_X + 0.5), math.floor(top + P.PILE_MARGIN_Y + 0.5)
    end
    return 36, 250
end

function P.ApplyPosition(f)
    f:ClearAllPoints()
    f:SetSize(T.db.frame.width or 230, T.db.frame.height or 175)
    if T.db.frame.useDefaultAnchor then
        local x, y = P.ComputeDefaultAnchor()
        T.db.frame.point, T.db.frame.relPoint = "BOTTOMLEFT", "BOTTOMLEFT"
        T.db.frame.x, T.db.frame.y = x, y
    end
    f:SetPoint(T.db.frame.point or "BOTTOMLEFT", UIParent, T.db.frame.relPoint or "BOTTOMLEFT",
        T.db.frame.x or 36, T.db.frame.y or 250)
end

local function ResetShoppingListPosition()
    T.db.frame.width = 230
    T.db.frame.height = 175
    T.db.frame.useDefaultAnchor = true
    if T.frame then
        P.ApplyPosition(T.frame)
    end
    T.Save()
    if T.Update then T.Update() end
end
T.ResetShoppingListPosition = ResetShoppingListPosition

-- ----------------------------------------------------------------------------
-- INK & QUILL HELPERS
-- ----------------------------------------------------------------------------
-- Handwriting faces built into the client (no font files shipped with the addon).
-- Morpheus is the calligraphic face Blizzard uses for books & letters.
-- EDIT: item / title / small are font sizes for the list rows, the page heading and the footer.
P.FONT_STYLES = {
    { key = "QUILL",  label = "Quill script", path = "Fonts\\MORPHEUS.TTF", item = 13, title = 15, small = 11 },
    { key = "SCRAWL", label = "Rough scrawl", path = "Fonts\\SKURRI.TTF",   item = 12, title = 14, small = 10 },
    { key = "PLAIN",  label = "Plain print",  path = nil,                   item = 11, title = 12, small = 9 },
}

function P.GetFontStyle()
    for _, st in ipairs(P.FONT_STYLES) do
        if st.key == T.db.font then return st end
    end
    return P.FONT_STYLES[1]
end

function P.CycleFontStyle()
    local idx = 1
    for i, st in ipairs(P.FONT_STYLES) do
        if st.key == T.db.font then idx = i end
    end
    T.db.font = P.FONT_STYLES[(idx % #P.FONT_STYLES) + 1].key
end

-- Applies the chosen handwriting face; falls back to the standard UI font if the client can't load it
function P.SetInkFont(fs, kind, flags)
    local look = P.GetStyle()
    local st = P.GetFontStyle()
    if look.font then
        for _, f in ipairs(P.FONT_STYLES) do if f.key == look.font then st = f end end
    end
    local cacheKey = st.key .. ":" .. look.key
    if fs.inkKey == cacheKey and fs.inkKind == kind then return end
    local ok = st.path and fs:SetFont(st.path, st[kind] or st.item, flags or "")
    if not st.path or ok == false then
        fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", P.FONT_STYLES[3][kind] or 11, flags or "")
    end
    if fs.SetShadowColor then
        if look.textShadow then
            fs:SetShadowColor(0, 0, 0, 1)                 -- UI text: the usual drop shadow
            if fs.SetShadowOffset then fs:SetShadowOffset(1, -1) end
        else
            fs:SetShadowColor(0, 0, 0, 0)                 -- ink doesn't cast drop shadows
        end
    end
    fs.inkKey, fs.inkKind = cacheKey, kind
end

-- ----------------------------------------------------------------------------
-- LOOKS: handkerchief notes (default), the parchment pile, or a see-through WoW window
-- Every colour the tally draws with comes from here.
-- EDIT: colours are { red, green, blue, opacity } from 0 to 1. Per look:
--   paper = the sheet, back = the pages underneath, ink / inkRed / inkGreen = writing, counts and
--   "(turn in)", title / footer / faded = heading, footer and ticked-off items, hem = the
--   handkerchief border, cloth = its lace edge (scallop = size of each scallop), pad = space
--   between the edge and the writing, reward / rewardGold = reward amounts at the right of a line
--   (gold for money). To make a different look the default, change T.DEFAULTS.look near the top
--   of the file to that look's key.
-- ----------------------------------------------------------------------------
P.STYLES = {
    {
        key = "HANDKERCHIEF", label = "Handkerchief notes",
        paper = { 0.95, 0.93, 0.88, 0.98 }, rim = nil,
        depth = 1.6, minDepth = 0.4, segW = 4,
        -- soft cloth: rounded corners, scalloped lace with eyelets, rippling a little
        cloth = { radius = 9, scallop = 4.6, step = 7.5, ripple = 1.1,
                  lace = { 0.99, 0.98, 0.95, 0.98 }, thread = { 0.60, 0.67, 0.84, 0.95 }, eyelet = { 0.50, 0.58, 0.80, 0.70 } },
        shade = nil, grain = nil,
        hem = {
            band = { 0.42, 0.56, 0.84, 0.30 }, inset = 4, width = 4,
            stripe = { 0.32, 0.46, 0.78, 0.55 }, stripeGap = 2, stripeWidth = 1.2,
            stitch = { 0.40, 0.50, 0.75, 0.75 }, stitchInset = 1.6,
            creaseDark = { 0.36, 0.37, 0.45, 0.16 }, creaseLight = { 1, 1, 1, 0.55 },
        },
        back = { { 0.93, 0.84, 0.84, 0.98 }, { 0.86, 0.90, 0.83, 0.98 }, { 0.95, 0.91, 0.78, 0.98 } },
        backRim = nil, backDepth = 1.6, backMinDepth = 0.4, backSegW = 4,
        backThread = { 0.62, 0.54, 0.56, 0.90 },        -- the hankies underneath: same cloth, own colours
        shadowAlpha = 0.20, pile = true, cornerInset = 4,
        ink = { 0.10, 0.13, 0.30 }, inkRed = { 0.62, 0.12, 0.12 }, inkGreen = { 0.16, 0.40, 0.20 },
        title = { 0.10, 0.13, 0.30 }, faded = { 0.42, 0.44, 0.52 }, footer = { 0.30, 0.34, 0.50 },
        sub = { 0.38, 0.42, 0.58 }, close = { 0.30, 0.34, 0.52 }, gear = { 0.28, 0.33, 0.52 },
        reward = { 0.14, 0.34, 0.46 }, rewardGold = { 0.55, 0.38, 0.04 },   -- reward amounts at the right of a line
        wash = { 0.40, 0.48, 0.70, 0.06 }, washFlash = { 0.95, 0.72, 0.20, 0.45 },
        divider = { 0.35, 0.42, 0.62, 0.14 }, highlight = { 0.30, 0.40, 0.70, 0.10 },
        grip = { 0.45, 0.52, 0.72, 0.85 }, pad = 7,           -- writing kept inside the woven border
        corner = { u1 = { 0.50, 0.52, 0.60 }, u2 = { 0.86, 0.85, 0.80 }, tip = { 1.00, 0.99, 0.96 },
                   crease = { 0.78, 0.78, 0.82 }, edge = { 0.40, 0.48, 0.68, 0.75 }, cut = { 0.45, 0.55, 0.78, 0.80 },
                   shadow = { 0.10, 0.12, 0.20 } },
    },
    {
        key = "PARCHMENT", label = "Parchment",
        paper = { 0.93, 0.85, 0.67, 0.97 }, rim = { 0.40, 0.27, 0.12, 0.95 },
        depth = 4.5, minDepth = 0.8, segW = 8,
        shade = { 0.35, 0.22, 0.08 }, grain = { 1.0, 0.94, 0.80, 0.30 }, hem = nil,
        back = { { 0.84, 0.75, 0.56, 0.98 }, { 0.78, 0.69, 0.51, 0.98 }, { 0.72, 0.63, 0.46, 0.98 } },
        backRim = { 0.34, 0.22, 0.09, 0.95 }, backDepth = 4, backMinDepth = 0.8, backSegW = 11,
        shadowAlpha = 0.36, pile = true,
        ink = { 0.17, 0.10, 0.05 }, inkRed = { 0.48, 0.15, 0.06 }, inkGreen = { 0.18, 0.36, 0.13 },
        title = { 0.17, 0.10, 0.05 }, faded = { 0.38, 0.30, 0.21 }, footer = { 0.36, 0.22, 0.08 },
        sub = { 0.48, 0.35, 0.23 }, close = { 0.40, 0.25, 0.11 }, gear = { 0.42, 0.26, 0.09 },
        reward = { 0.22, 0.27, 0.36 }, rewardGold = { 0.52, 0.34, 0.02 },
        wash = { 0.55, 0.40, 0.18, 0.06 }, washFlash = { 0.95, 0.72, 0.20, 0.45 },
        divider = { 0.45, 0.32, 0.15, 0.14 }, highlight = { 0.45, 0.30, 0.08, 0.10 },
        grip = { 0.75, 0.55, 0.30, 0.85 }, pad = 0,
        corner = { u1 = { 0.42, 0.30, 0.16 }, u2 = { 0.78, 0.68, 0.50 }, tip = { 0.98, 0.92, 0.78 },
                   crease = { 0.70, 0.58, 0.38 }, edge = { 0.33, 0.21, 0.08, 0.75 }, cut = { 0.45, 0.31, 0.14, 0.70 },
                   shadow = { 0.10, 0.05, 0.01 } },
    },
    {
        key = "NATIVE", label = "Transparent window",
        paper = { 0.02, 0.02, 0.03, 0.70 }, rim = { 0.55, 0.55, 0.60, 0.85 },
        depth = 1, minDepth = 1, segW = 40,                              -- straight edges, 1px border
        shade = nil, grain = nil, hem = nil,
        back = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } },
        backRim = nil, backDepth = 1, backMinDepth = 1, backSegW = 40,
        shadowAlpha = 0, pile = false,                                   -- no paper pile: the footer shows the page
        ink = { 0.85, 0.85, 0.85 }, inkRed = { 1.00, 0.82, 0.00 }, inkGreen = { 0.25, 0.95, 0.25 },
        title = { 1.00, 0.82, 0.00 }, faded = { 0.55, 0.55, 0.55 }, footer = { 0.70, 0.70, 0.70 },
        sub = { 0.75, 0.75, 0.75 }, close = { 0.80, 0.80, 0.80 }, gear = { 0.80, 0.80, 0.80 },
        reward = { 0.00, 0.80, 1.00 }, rewardGold = { 1.00, 0.82, 0.00 },
        wash = { 1, 1, 1, 0.05 }, washFlash = { 1.0, 0.82, 0.0, 0.40 },
        divider = { 1, 1, 1, 0.08 }, highlight = { 1, 1, 1, 0.07 },
        grip = { 0.80, 0.80, 0.80, 0.85 }, pad = 0,
        textShadow = true, font = "PLAIN", name = { 0.95, 0.95, 0.95 },
        corner = { u1 = { 0.08, 0.08, 0.10 }, u2 = { 0.22, 0.22, 0.25 }, tip = { 0.50, 0.50, 0.55 },
                   crease = { 0.25, 0.25, 0.28 }, edge = { 0.60, 0.60, 0.65, 0.80 }, cut = { 0.50, 0.50, 0.55, 0.80 },
                   shadow = { 0, 0, 0 } },
    },
}

function P.GetStyle()
    for _, st in ipairs(P.STYLES) do
        if st.key == T.db.look then return st end
    end
    return P.STYLES[1]
end

function P.CycleStyle()
    local idx = 1
    for i, st in ipairs(P.STYLES) do
        if st.key == T.db.look then idx = i end
    end
    T.db.look = P.STYLES[(idx % #P.STYLES) + 1].key
end

function P.Hex(c)
    return string.format("FF%02X%02X%02X", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

-- Repaints the whole pile and its chrome for the current look
function P.ApplyStyle(f)
    f = f or T.frame
    if not f then return end
    local st = P.GetStyle()
    P.INK, P.INK_RED, P.INK_GREEN = st.ink, st.inkRed, st.inkGreen
    f.styleKey = st.key

    local cl = st.cloth
    P.RestyleSheet(f.shadowSheet, { paper = { 0, 0, 0, st.shadowAlpha or 0 }, depth = st.depth + 0.5, minDepth = 1, segW = 14, overlap = 0,
        cloth = cl and { radius = cl.radius + 1 } or nil })      -- a soft rounded shadow, no lace
    for k, sh in ipairs(f.backSheets) do
        local bp = st.back[k]
        P.RestyleSheet(sh, { paper = bp, rim = st.backRim, depth = st.backDepth, minDepth = st.backMinDepth, segW = st.backSegW,
            cloth = cl and { radius = cl.radius, scallop = cl.scallop, step = cl.step, ripple = cl.ripple,
                lace = { math.min(1, bp[1] * 1.03), math.min(1, bp[2] * 1.03), math.min(1, bp[3] * 1.03), bp[4] },
                thread = st.backThread } or nil })
    end
    P.RestyleSheet(f.topSheet, {
        paper = st.paper, rim = st.rim, depth = st.depth, minDepth = st.minDepth, segW = st.segW,
        grain = st.grain, shade = st.shade, hem = st.hem, cloth = cl,
    })
    if f.corner then
        -- on cloth the folded corner sits inside the rounded corner instead of poking past it
        local ci = st.cornerInset or 0
        f.corner:ClearAllPoints()
        f.corner:SetPoint("BOTTOMRIGHT", f.chrome, "BOTTOMRIGHT", 3 - ci, -3 + ci)
    end
    f.shadowSheet:SetShown((st.shadowAlpha or 0) > 0)

    local cc = st.close
    if f.closeBtn then f.closeBtn.txt:SetTextColor(cc[1], cc[2], cc[3]) end
    if f.optBtn then
        f.optBtn.iconColor = { st.gear[1], st.gear[2], st.gear[3] }
        T.SetGearHover(f.optBtn, false)
    end
    if f.gripTex then f.gripTex:SetVertexColor(st.grip[1], st.grip[2], st.grip[3], st.grip[4]) end

    -- keep the writing off the handkerchief's hem
    local pad = st.pad or 0
    f.pad = pad
    if f.closeBtn then
        f.closeBtn:ClearAllPoints()
        f.closeBtn:SetPoint("TOPRIGHT", f.chrome, "TOPRIGHT", -5 - pad, -5 - pad)
    end
    if f.titleFS then
        f.titleFS:ClearAllPoints()
        f.titleFS:SetPoint("TOPLEFT", f.chrome, "TOPLEFT", 10 + pad, -6 - pad)
        f.titleFS:SetPoint("RIGHT", f.optBtn, "LEFT", -4, 0)
    end
    if f.content then
        f.content:ClearAllPoints()
        f.content:SetPoint("TOPLEFT", f.chrome, "TOPLEFT", 6 + pad, -28 - pad)
        f.content:SetPoint("BOTTOMRIGHT", f.chrome, "BOTTOMRIGHT", -6 - pad, 17 + pad)
    end
    if f.footerFS then
        f.footerFS:ClearAllPoints()
        f.footerFS:SetPoint("BOTTOMLEFT", f.chrome, "BOTTOMLEFT", 22 + pad, 5 + pad)
        f.footerFS:SetPoint("BOTTOMRIGHT", f.chrome, "BOTTOMRIGHT", -30 - pad, 5 + pad)
        f.footerFS:SetTextColor(st.footer[1], st.footer[2], st.footer[3], 0.95)
    end
    if f.corner then f.corner.drawnKey = nil; P.DrawCorner(f.corner) end
    P.ApplyStackLayout(f)
end

-- A quill stroke: a crisp core line plus a wider, faint "bleed" line so the ink looks absorbed by the paper
function P.NewStroke(parent, layer, sub)
    sub = sub or 4
    return {
        bleed = parent:CreateLine(nil, layer or "OVERLAY", nil, sub - 1),
        main = parent:CreateLine(nil, layer or "OVERLAY", nil, sub),
    }
end

function P.DrawStroke(s, rel, x0, y0, x1, y1, thick, alpha, ink)
    ink = ink or P.INK
    s.main:SetStartPoint("TOPLEFT", rel, x0, y0)
    s.main:SetEndPoint("TOPLEFT", rel, x1, y1)
    s.main:SetThickness(thick)
    s.main:SetColorTexture(ink[1], ink[2], ink[3], alpha)
    s.bleed:SetStartPoint("TOPLEFT", rel, x0 + 0.4, y0 - 0.4)
    s.bleed:SetEndPoint("TOPLEFT", rel, x1 - 0.3, y1 - 0.3)
    s.bleed:SetThickness(thick + 1.0)
    s.bleed:SetColorTexture(ink[1], ink[2], ink[3], alpha * 0.25)
    s.main:Show()
    s.bleed:Show()
end

function P.HideStroke(s)
    s.main:Hide()
    s.bleed:Hide()
end

-- Greedy word wrap with a measuring FontString, so each struck-through line gets a strike of its own width
function P.WrapLines(measureFS, text, maxW)
    local lines, widths = {}, {}
    local cur, gap = "", ""
    local function Width(s)
        measureFS:SetText(s)
        return measureFS:GetStringWidth() or 0
    end
    -- keep the original spacing between words (e.g. the double space after the count)
    for word, space in string.gmatch(text, "(%S+)(%s*)") do
        local candidate = (cur == "") and word or (cur .. gap .. word)
        if cur ~= "" and Width(candidate) > maxW then
            table.insert(lines, cur)
            cur = word
        else
            cur = candidate
        end
        gap = space
    end
    if cur ~= "" then table.insert(lines, cur) end
    if #lines == 0 then lines[1] = "" end
    for i, ln in ipairs(lines) do
        widths[i] = math.min(maxW, Width(ln))
    end
    return lines, widths
end

-- ----------------------------------------------------------------------------
-- PAGES (one per area) & PAGE ORDER
-- ----------------------------------------------------------------------------
function P.GetAreaIndex(key)
    for i, a in ipairs(P.areas) do
        if a.key == key then return i end
    end
    return 1
end

function P.GetSelectedArea()
    return P.areas[P.GetAreaIndex(P.selectedKey)]
end

function P.GetNeighborArea(dir)
    local n = #P.areas
    if n < 2 then return nil end
    local i = P.GetAreaIndex(P.selectedKey)
    return P.areas[((i - 1 + (dir or 1)) % n) + 1]
end

-- ----------------------------------------------------------------------------
-- DOG-EARED PAGE CORNER (hot corner that turns to the next area's page)
-- Built from 1px scanline strips so it needs no art files or vertex offsets:
--   * the folded-over flap (upper-left triangle, paper underside, shaded toward the fold)
--   * the gap the fold leaves (lower-right triangle), showing the page underneath
-- Hovering lifts the corner further.
-- ----------------------------------------------------------------------------
P.CORNER_MAX = 34
P.CORNER_REST = 15
P.CORNER_HOVER = 30

function P.HGradient(tex, r1, g1, b1, a1, r2, g2, b2, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then
        tex:SetGradient("HORIZONTAL", CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    else
        tex:SetColorTexture((r1 + r2) * 0.5, (g1 + g2) * 0.5, (b1 + b2) * 0.5, (a1 + a2) * 0.5)
    end
end

function P.DrawCorner(c)
    local S = math.max(2, math.min(P.CORNER_MAX, c.size or P.CORNER_REST))
    local key = math.floor(S * 4 + 0.5)
    if c.drawnKey == key then return end
    c.drawnKey = key

    local ox = P.CORNER_MAX - S              -- the active corner sits in the bottom-right of the button
    local lift = (S - P.CORNER_REST) / (P.CORNER_HOVER - P.CORNER_REST)   -- 0 at rest, 1 fully lifted
    if lift < 0 then lift = 0 elseif lift > 1 then lift = 1 end
    local n = math.floor(S + 0.5)
    local cs = P.GetStyle().corner
    local u1, u2, tip, cr = cs.u1, cs.u2, cs.tip, cs.crease
    local tipK = 1 - 0.06 * lift
    for j = 1, P.CORNER_MAX do
        local under, flap = c.under[j], c.flap[j]
        if j <= n then
            local y = -(ox + j - 1)
            local cut = S - (j - 0.5)              -- where the fold line crosses this row
            if cut < 0 then cut = 0 end
            local uw = S - cut
            under:ClearAllPoints()
            under:SetPoint("TOPLEFT", c, "TOPLEFT", ox + cut, y)
            under:SetSize(math.max(0.5, uw), 1)
            -- the page beneath, darkened right under the fold where the flap shades it
            P.HGradient(under, u1[1], u1[2], u1[3], 1, u2[1], u2[2], u2[3], 1)
            under:Show()

            if cut > 0.4 then
                flap:ClearAllPoints()
                flap:SetPoint("TOPLEFT", c, "TOPLEFT", ox, y)
                flap:SetSize(cut, 1)
                -- underside of the parchment: lighter at the tip, shading into the crease
                P.HGradient(flap, tip[1] * tipK, tip[2] * tipK, tip[3] * tipK, 1,
                    cr[1] - 0.08 * lift, cr[2] - 0.08 * lift, cr[3] - 0.06 * lift, 1)
                flap:Show()
            else
                flap:Hide()
            end
        else
            under:Hide()
            flap:Hide()
        end
    end

    -- crease, cast shadow and the flap's cut edges
    c.foldShadow:SetStartPoint("TOPLEFT", c, ox + S + 1.2, -ox - 1.2)
    c.foldShadow:SetEndPoint("TOPLEFT", c, ox + 1.2, -(ox + S) - 1.2)
    c.foldShadow:SetThickness(2.5 + 2 * lift)
    c.foldShadow:SetColorTexture(cs.shadow[1], cs.shadow[2], cs.shadow[3], 0.20 + 0.15 * lift)
    c.foldEdge:SetStartPoint("TOPLEFT", c, ox + S, -ox)
    c.foldEdge:SetEndPoint("TOPLEFT", c, ox, -(ox + S))
    c.foldEdge:SetThickness(1)
    c.foldEdge:SetColorTexture(cs.edge[1], cs.edge[2], cs.edge[3], cs.edge[4])
    c.flapTop:SetStartPoint("TOPLEFT", c, ox, -ox)
    c.flapTop:SetEndPoint("TOPLEFT", c, ox + S, -ox)
    c.flapTop:SetThickness(1)
    c.flapTop:SetColorTexture(cs.cut[1], cs.cut[2], cs.cut[3], cs.cut[4])
    c.flapLeft:SetStartPoint("TOPLEFT", c, ox, -ox)
    c.flapLeft:SetEndPoint("TOPLEFT", c, ox, -(ox + S))
    c.flapLeft:SetThickness(1)
    c.flapLeft:SetColorTexture(cs.cut[1], cs.cut[2], cs.cut[3], cs.cut[4])
end

function P.CreateCorner(f, parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(P.CORNER_MAX, P.CORNER_MAX)
    c:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 3, -3)   -- also covers the torn rim at the corner
    c:SetFrameLevel((f.baseLevel or 30) + 22)
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c.size, c.target = P.CORNER_REST, P.CORNER_REST
    c.under, c.flap = {}, {}
    for j = 1, P.CORNER_MAX do
        c.under[j] = c:CreateTexture(nil, "ARTWORK", nil, 1)
        c.flap[j] = c:CreateTexture(nil, "ARTWORK", nil, 3)
    end
    c.foldShadow = c:CreateLine(nil, "ARTWORK", nil, 2)
    c.foldEdge = c:CreateLine(nil, "ARTWORK", nil, 5)
    c.flapTop = c:CreateLine(nil, "ARTWORK", nil, 4)
    c.flapLeft = c:CreateLine(nil, "ARTWORK", nil, 4)

    c:SetScript("OnEnter", function(self)
        self.target = P.CORNER_HOVER
        local nxt, prev = P.GetNeighborArea(1), P.GetNeighborArea(-1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Turn the page", 1, 0.82, 0)
        if nxt then
            GameTooltip:AddLine(string.format("Next: %s  (%d to gather)", nxt.title or "Elsewhere", nxt.remaining or 0), 0.9, 0.9, 0.9)
        end
        if prev and prev ~= nxt then
            GameTooltip:AddLine(string.format("Back: %s", prev.title or "Elsewhere"), 0.75, 0.75, 0.75)
        end
        GameTooltip:AddLine("Left-Click: next page  |  Right-Click: previous page", 0.65, 0.65, 0.65)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function(self)
        self.target = P.CORNER_REST
        GameTooltip:Hide()
    end)
    c:SetScript("OnClick", function(_, button)
        P.TurnPage((button == "RightButton") and -1 or 1)
    end)

    P.DrawCorner(c)
    return c
end

function P.UpdateCorner(f)
    if not f.corner then return end
    local multi = #P.areas > 1
    f.corner:SetShown(multi)
    if multi then P.DrawCorner(f.corner) end
end

-- ----------------------------------------------------------------------------
-- STACK LAYOUT, PAGE-TURN ANIMATION & PER-FRAME DRIVER
-- ----------------------------------------------------------------------------
function P.ApplyStackLayout(f)
    if not f.topSheet then return end
    local w, h = f:GetWidth(), f:GetHeight()
    if not w or w < 20 or not h or h < 20 then return end
    local sh = f.shuffle
    local t = sh and math.min(1, sh.t) or 0
    local dir = (sh and sh.dir) or 1
    local pulse = math.sin(math.pi * t)
    local wob = math.sin(2 * math.pi * t)

    f.shadowSheet:Layout(w, h, 0.004, 3, -4)
    local visible = f.visibleBackSheets or 0
    for k = 1, P.MAX_BACK_SHEETS do
        local s = f.backSheets[k]
        if k <= visible then
            local slot = P.BACK_SLOTS[k]
            local sign = (k % 2 == 0) and -1 or 1
            s:Show()
            s:Layout(w, h, slot.angle + wob * 0.02 * sign, slot.dx - pulse * dir * 3 * k, slot.dy)
        else
            s:Hide()
        end
    end
    -- Page turn: the top sheet is lifted by its corner and slid aside, then the next one settles in
    f.topSheet:Layout(w, h, -dir * 0.09 * pulse, dir * 38 * pulse, -10 * pulse)
    f.chrome:SetAlpha(sh and math.abs(1 - 2 * t) or 1)
end

function P.SelectArea(key, animate, dir)
    local f = T.frame
    if not f or not key then return end
    if key == P.selectedKey and not f.shuffle then return end
    if animate and f:IsShown() then
        f.shuffle = { t = 0, dur = 0.55, key = key, swapped = false, dir = dir or 1 }
    else
        P.selectedKey = key
        T.scroll = 0
        T.Update()
    end
end

function P.TurnPage(dir)
    local f = T.frame
    if not f or f.shuffle then return end
    local a = P.GetNeighborArea(dir or 1)
    if a then P.SelectArea(a.key, true, dir or 1) end
end

function P.OnUpdate(f, elapsed)
    local dt = math.min(math.max(elapsed or 0, 0.001), 0.05)

    if f.shuffle then
        local sh = f.shuffle
        sh.t = sh.t + dt / sh.dur
        if sh.t >= 0.5 and not sh.swapped then
            sh.swapped = true
            P.selectedKey = sh.key
            T.scroll = 0
            T.Update()
            if not f:IsShown() then
                f.shuffle = nil
                return
            end
        end
        if sh.t >= 1 then f.shuffle = nil end
        P.ApplyStackLayout(f)
    end

    if next(P.fxRows) then P.AnimateRowFX(GetTime()) end

    local c = f.corner
    if c and c:IsShown() then
        local d = (c.target or P.CORNER_REST) - (c.size or P.CORNER_REST)
        if math.abs(d) > 0.01 then
            if math.abs(d) < 0.25 then
                c.size = c.target
            else
                c.size = c.size + d * math.min(1, dt * 12)
            end
            P.DrawCorner(c)
        end
    end
end

-- When the player enters a new area, its page is fresh ink (red title for a few seconds) and,
-- optionally, gets turned back to the top of the pile.
function P.CheckAreaChange(f)
    local zone = (GetRealZoneText and GetRealZoneText()) or ""
    local sub = (GetSubZoneText and GetSubZoneText()) or ""
    local sig = zone .. "|" .. sub
    if P.lastAreaSig == nil then
        P.lastAreaSig = sig
        return
    end
    if sig == P.lastAreaSig then return end
    P.lastAreaSig = sig
    P.currentGlowUntil = GetTime() + 7

    if T.db.opts.autoFrontOnAreaChange and P.selectedKey ~= P.CURRENT_KEY then
        if f:IsShown() and not f.shuffle then
            f.shuffle = { t = 0, dur = 0.55, key = P.CURRENT_KEY, swapped = false, dir = -1 }
        elseif not f.shuffle then
            P.selectedKey = P.CURRENT_KEY
            T.scroll = 0
        end
    end
end

-- ----------------------------------------------------------------------------
-- CHECKLIST ROWS (hand-inked box, quill tick, per-line strike-through)
-- ----------------------------------------------------------------------------
local function AcquireShoppingListRow(idx, parent)
    local row = T.rowPool[idx]
    if row then return row end

    row = CreateFrame("Button", nil, parent)
    row:SetHeight(20)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.seed = idx * 13.7

    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(0.45, 0.30, 0.08, 0.10)

    -- Hand-drawn box: four slightly crooked quill strokes that overshoot their corners
    local box = CreateFrame("Frame", nil, row)
    box:SetSize(11, 11)
    box:SetPoint("TOPLEFT", row, "TOPLEFT", 3, -4)
    box.wash = box:CreateTexture(nil, "BACKGROUND")
    box.wash:SetAllPoints()
    box.wash:SetColorTexture(0.55, 0.40, 0.18, 0.06)

    local function J(k) return (P.Hash01(row.seed, k, 3) - 0.5) * 1.2 end
    local corners = {
        { 0 + J(1), 0 + J(2) }, { 11 + J(3), 0 + J(4) }, { 11 + J(5), -11 + J(6) }, { 0 + J(7), -11 + J(8) },
    }
    box.sides = {}
    box.corners = corners
    for k = 1, 4 do
        box.sides[k] = P.NewStroke(box, "ARTWORK", 3)
    end
    P.DrawBoxSides(box)

    -- Quill tick: heavy short down-stroke, then a long flick up and out past the box's top-right
    box.tick = { P.NewStroke(box, "OVERLAY", 5), P.NewStroke(box, "OVERLAY", 5), P.NewStroke(box, "OVERLAY", 5) }
    for _, s in ipairs(box.tick) do P.HideStroke(s) end
    row.box = box

    row.itemText = row:CreateFontString(nil, "OVERLAY")
    P.SetInkFont(row.itemText, "item")
    row.itemText:SetPoint("TOPLEFT", box, "TOPRIGHT", 6, 2)
    row.itemText:SetJustifyH("LEFT")
    row.itemText:SetJustifyV("TOP")
    row.itemText:SetWordWrap(true)
    row.itemText:SetTextColor(P.INK[1], P.INK[2], P.INK[3], 1)

    -- "(turn in)" note: separate so the strike-through never runs through it
    row.suffixText = row:CreateFontString(nil, "OVERLAY")
    P.SetInkFont(row.suffixText, "small")
    row.suffixText:SetJustifyH("LEFT")
    row.suffixText:SetTextColor(P.INK_GREEN[1], P.INK_GREEN[2], P.INK_GREEN[3], 1)
    row.suffixText:Hide()

    -- The quest's reward / currency, right-aligned on the first line (the item text wraps before it)
    row.rewardText = row:CreateFontString(nil, "OVERLAY")
    P.SetInkFont(row.rewardText, "small")
    row.rewardText:SetPoint("TOPRIGHT", row, "TOPRIGHT", -2, -3)
    row.rewardText:SetJustifyH("RIGHT")
    row.rewardText:SetWordWrap(false)
    row.rewardText:Hide()

    row.strikes = {}

    -- Faint ruled line under each entry, like a ledger
    row.divider = row:CreateTexture(nil, "BACKGROUND")
    row.divider:SetHeight(1)
    row.divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 0)
    row.divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 0)
    row.divider:SetColorTexture(0.45, 0.32, 0.15, 0.14)

    T.rowPool[idx] = row
    P.StyleRow(row)
    return row
end

-- the box's four crooked strokes, in the current ink
function P.DrawBoxSides(box)
    local corners = box.corners
    for k = 1, 4 do
        local a, b = corners[k], corners[(k % 4) + 1]
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
        local ux, uy = dx / len, dy / len
        P.DrawStroke(box.sides[k], box, a[1] - ux * 0.4, a[2] - uy * 0.4, b[1] + ux * 1.1, b[2] + uy * 1.1, 1.05, 0.72)
    end
end

-- re-inks a row after the look changes
function P.StyleRow(row)
    local st = P.GetStyle()
    if row.styleKey == st.key then return end
    row.styleKey = st.key
    local h, d = st.highlight, st.divider
    row.highlight:SetColorTexture(h[1], h[2], h[3], h[4])
    row.divider:SetColorTexture(d[1], d[2], d[3], d[4])
    P.DrawBoxSides(row.box)
    row.suffixText:SetTextColor(st.inkGreen[1], st.inkGreen[2], st.inkGreen[3], 1)
    if row.lasso then row.lassoKey = nil end
end

-- ----------------------------------------------------------------------------
-- INK EFFECTS: a warm glow when you're in an item's hunting grounds, flames when your
-- target is something that drops it, and a red ink circle round the item shown on the map
-- ----------------------------------------------------------------------------
function P.EnsureRowFX(row)
    if row.fx then return row.fx end
    local fx = { inner = {}, outer = {}, all = {} }
    -- copies of the words nudged a pixel or two in every direction under the ink: only their edges
    -- show, which reads as a halo (glow) or a licking flame.
    local function Copy(list, sub, ox, oy)
        local fs = row:CreateFontString(nil, "ARTWORK", nil, sub)
        fs:SetPoint("TOPLEFT", row.itemText, "TOPLEFT", ox, oy)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetWordWrap(true)
        fs:Hide()
        table.insert(list, fs)
        table.insert(fx.all, fs)
    end
    for k = 0, 7 do
        local a = k * math.pi / 4
        Copy(fx.inner, 2, math.cos(a) * 1.2, math.sin(a) * 1.2)
    end
    for k = 0, 3 do
        local a = math.pi / 4 + k * math.pi / 2
        Copy(fx.outer, 1, math.cos(a) * 2.4, math.sin(a) * 2.4 + 0.6)   -- a touch higher: heat rises
    end
    -- heat haze rising off the line
    fx.haze = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    fx.haze:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 16, 1)
    fx.haze:SetPoint("TOPRIGHT", row, "TOPRIGHT", -2, 2)
    fx.haze:Hide()
    fx.embers = {}
    for k = 1, 6 do
        local e = row:CreateTexture(nil, "OVERLAY", nil, 7)
        e:SetSize(2, 2)
        e:Hide()
        fx.embers[k] = e
    end
    row.fx = fx
    return fx
end

-- mode: nil (off), "glow" (hunting grounds), "fire" (your target drops it) or "smoulder" (it might)
-- key: the item's progKey (rows are pooled, so a row can show a different item after a re-render)
function P.SetRowFX(row, mode, plainText, textW, key)
    if not mode and not row.fx then return end
    local fx = P.EnsureRowFX(row)
    if not mode then
        row.fxMode, row.fxKey, row.fxSince = nil, nil, nil
        for _, fs in ipairs(fx.all) do fs:Hide() end
        fx.haze:Hide()
        for _, e in ipairs(fx.embers) do e:Hide() end
        P.fxRows[row] = nil
        return
    end
    if row.fxMode ~= mode or row.fxKey ~= key or not row.fxSince then row.fxSince = GetTime() end
    row.fxMode, row.fxKey = mode, key
    local path, size, flags = row.itemText:GetFont()
    path = path or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    size = size or 12
    for _, fs in ipairs(fx.all) do
        fs:SetFont(path, size, flags or "")
        fs:SetWidth(textW)
        fs:SetText(plainText)
        if fs.SetShadowColor then fs:SetShadowColor(0, 0, 0, 0) end
        fs:Show()
    end
    if mode == "fire" then
        ApplyTwoColorVerticalGradient(fx.haze, 1.0, 0.45, 0.05, 0.30, 1.0, 0.70, 0.10, 0.0)
        fx.haze:Show()
    else
        fx.haze:Hide()
        for _, e in ipairs(fx.embers) do e:Hide() end
    end
    row.fxTextW = textW
    P.fxRows[row] = true
end
P.fxRows = setmetatable({}, { __mode = "k" })

-- per-frame flicker / pulse for every row that has an effect on
function P.AnimateRowFX(now)
    for row in pairs(P.fxRows) do
        local fx, mode = row.fx, row.fxMode
        if not (fx and mode and row:IsShown()) then
            P.fxRows[row] = nil
        elseif mode == "glow" then
            -- slow breathing gold; brighter for the first few seconds after you walk in
            local fresh = math.max(0, 1 - (now - (row.fxSince or now)) / 4)
            local a = 0.30 + 0.22 * (0.5 + 0.5 * math.sin(now * 2.6 + (row.seed or 0))) + 0.35 * fresh
            for _, fs in ipairs(fx.outer) do fs:SetTextColor(1.0, 0.72, 0.20, a * 0.45) end
            for _, fs in ipairs(fx.inner) do fs:SetTextColor(1.0, 0.88, 0.45, a * 0.75) end
        else
            -- flames ("fire": known dropper) or a smoulder ("smoulder": only the names suggest it):
            -- two out-of-phase flickers, colour sliding between deep orange and yellow
            local heat = (mode == "fire") and 1 or 0.45
            local s = row.seed or 0
            local f1 = 0.55 + 0.25 * math.sin(now * 17 + s) + 0.20 * math.sin(now * 29 + s * 2)
            local f2 = 0.55 + 0.25 * math.sin(now * 23 + s * 3) + 0.20 * math.sin(now * 11 + s)
            local flare = heat * math.max(0, 1 - (now - (row.fxSince or now)) / 2.5)   -- big flare-up as it catches
            for i, fs in ipairs(fx.outer) do
                -- each tongue of flame flickers on its own
                local fi = 0.5 + 0.5 * math.sin(now * (13 + i * 3) + s + i)
                fs:SetTextColor(1.0, 0.28 + 0.15 * f2, 0.04, heat * math.min(1, 0.25 + 0.45 * fi * f1 + 0.25 * flare))
            end
            for _, fs in ipairs(fx.inner) do
                fs:SetTextColor(1.0, 0.62 + 0.30 * f1, 0.12 + 0.20 * f2, heat * math.min(1, 0.50 + 0.35 * f2 + 0.15 * flare))
            end
            fx.haze:SetAlpha(0.55 + 0.45 * f1)
            local w = math.max(20, math.min(row.fxTextW or 100, (row.itemText:GetStringWidth() or 100)))
            local h = row:GetHeight() or 20
            local nEmbers = (mode == "fire") and #fx.embers or 2
            for k, e in ipairs(fx.embers) do
              if k > nEmbers then
                e:Hide()
              else
                -- each ember rises from the words, drifts and fades, then is re-lit somewhere else
                local speed = 0.55 + 0.35 * P.Hash01(s, k, 1)
                local t = now * speed + P.Hash01(s, k, 2)
                local cycle = math.floor(t)
                local p = t - cycle
                local x = 18 + w * P.Hash01(s, k, cycle) + math.sin(t * 6 + k) * 2
                e:ClearAllPoints()
                e:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", x, 2 + p * (h + 6))
                e:SetColorTexture(1.0, 0.55 + 0.4 * (1 - p), 0.1, (1 - p) * 0.95 * heat)
                e:Show()
              end
            end
        end
    end
end

-- red ink circled round the box of an item whose quest you're tracking
function P.SetRowLasso(row, on)
    if not on then
        if row.lasso then for _, s in ipairs(row.lasso) do P.HideStroke(s) end end
        return
    end
    if not row.lasso then
        row.lasso = {}
        for k = 1, 9 do row.lasso[k] = P.NewStroke(row.box, "OVERLAY", 7) end
    end
    local n = #row.lasso
    local cx, cy, rx, ry = 5.5, -5.5, 9.5, 8.5
    local prevX, prevY
    for k = 0, n do
        -- a loop that doesn't quite close, overshooting where the quill started
        local a = -0.6 + (k / n) * (2 * math.pi + 0.5)
        local wob = 1 + (P.Hash01(row.seed, k, 7) - 0.5) * 0.12
        local x, y = cx + math.cos(a) * rx * wob, cy + math.sin(a) * ry * wob
        if prevX then
            P.DrawStroke(row.lasso[k], row.box, prevX, prevY, x, y, 1.2, 0.85, P.INK_RED)
        end
        prevX, prevY = x, y
    end
end

function P.ShowTick(box, seed)
    local w = (P.Hash01(seed, 9, 1) - 0.5) * 1.6
    P.DrawStroke(box.tick[1], box, 1.5, -5.0 + w * 0.3, 4.6, -9.6, 2.1, 0.93)        -- down-stroke
    P.DrawStroke(box.tick[2], box, 4.6, -9.6, 10.6 + w, 0.4, 1.6, 0.93)              -- up-stroke
    P.DrawStroke(box.tick[3], box, 10.6 + w, 0.4, 14.2 + w, 4.2, 0.8, 0.70)          -- tapering flick
end

function P.HideTick(box)
    for _, s in ipairs(box.tick) do P.HideStroke(s) end
end

function P.GetStrike(row, k)
    local s = row.strikes[k]
    if not s then
        s = P.NewStroke(row, "OVERLAY", 6)
        row.strikes[k] = s
    end
    return s
end

function P.HideStrikes(row)
    for _, s in ipairs(row.strikes) do P.HideStroke(s) end
end

-- Gear icon with a safe text fallback (no custom art files required)
function T.ApplyGearIcon(btn, r, g, b, fallbackText, fontSize)
    local atlases = { "QuestLog-icon-setting", "GM-icon-settings", "Options_Gear" }
    if C_Texture and C_Texture.GetAtlasInfo then
        for _, atlas in ipairs(atlases) do
            local ok, info = pcall(C_Texture.GetAtlasInfo, atlas)
            if ok and info then
                btn.icon = btn:CreateTexture(nil, "ARTWORK")
                btn.icon:SetAllPoints()
                btn.icon:SetAtlas(atlas)
                btn.icon:SetVertexColor(r, g, b)
                btn.iconColor = { r, g, b }
                return true
            end
        end
    end
    btn.txt = btn:CreateFontString(nil, "OVERLAY")
    btn.txt:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", fontSize or 10, "OUTLINE")
    btn.txt:SetPoint("CENTER")
    btn.txt:SetText(fallbackText)
    btn.txt:SetTextColor(r, g, b)
    btn.iconColor = { r, g, b }
    return false
end

function T.SetGearHover(btn, hovered)
    local c = btn.iconColor or { 1, 1, 1 }
    local r, g, b = c[1], c[2], c[3]
    if hovered then r, g, b = 1.0, 0.82, 0.0 end
    if btn.icon then btn.icon:SetVertexColor(r, g, b) end
    if btn.txt then btn.txt:SetTextColor(r, g, b) end
end

-- ----------------------------------------------------------------------------
-- FRAME CONSTRUCTION
-- ----------------------------------------------------------------------------
local function EnsureShoppingListFrame()
    if T.frame then return T.frame end

    local fontPath = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    local f = CreateFrame("Frame", "CRQ_FieldTally", UIParent)
    f:SetFrameStrata("MEDIUM")
    f.baseLevel = 30
    f:SetFrameLevel(f.baseLevel)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f.visibleBackSheets = 0
    T.frame = f
    P.ApplyPosition(f)

    local function SavePoint(self)
        local pt, _, relPt, xOfs, yOfs = self:GetPoint(1)
        if pt then
            T.db.frame.point = pt
            T.db.frame.relPoint = relPt or pt
            T.db.frame.x = math.floor((xOfs or 0) + 0.5)
            T.db.frame.y = math.floor((yOfs or 0) + 0.5)
            T.db.frame.useDefaultAnchor = false
        end
    end

    f:SetScript("OnDragStart", function(self)
        if not self.isResizing then
            self:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePoint(self)
        T.Save()
    end)

    -- Page pile (bottom to top): drop shadow, up to 3 pages underneath, the top page.
    -- Colours and edge shapes come from the chosen look (P.ApplyStyle at the end).
    local base = f.baseLevel
    local st = P.GetStyle()
    f.shadowSheet = P.CreateSheet(f, 11, {
        paper = { 0, 0, 0, st.shadowAlpha or 0 }, depth = 4, minDepth = 1, segW = 14, overlap = 0,
    })
    f.shadowSheet:SetFrameLevel(base + 1)

    f.backSheets = {}
    for k = 1, P.MAX_BACK_SHEETS do
        local sh = P.CreateSheet(f, 20 + k * 7, {
            paper = st.back[k], rim = st.backRim, depth = st.backDepth, minDepth = st.backMinDepth, segW = st.backSegW,
        })
        sh:SetFrameLevel(base + 5 - k)   -- back1 (closest) = base+4 ... back3 = base+2
        f.backSheets[k] = sh
    end

    f.topSheet = P.CreateSheet(f, 7, {
        paper = st.paper, rim = st.rim, depth = st.depth, minDepth = st.minDepth, segW = st.segW,
        grain = st.grain, shade = st.shade, hem = st.hem, decor = true,
    })
    f.topSheet:SetFrameLevel(base + 12)

    -- Chrome: everything written on the top page (moves & fades with it during a page turn)
    local chrome = CreateFrame("Frame", nil, f.topSheet)
    chrome:SetAllPoints(f.topSheet)
    chrome:SetFrameLevel(base + 17)
    f.chrome = chrome

    -- Close (×), inked
    local closeBtn = CreateFrame("Button", nil, chrome)
    closeBtn:SetSize(14, 14)
    closeBtn:SetPoint("TOPRIGHT", chrome, "TOPRIGHT", -5, -5)
    closeBtn:SetFrameLevel(base + 19)
    closeBtn.txt = closeBtn:CreateFontString(nil, "OVERLAY")
    closeBtn.txt:SetFont(fontPath, 13, "")
    closeBtn.txt:SetPoint("CENTER")
    closeBtn.txt:SetText("×")
    closeBtn.txt:SetTextColor(0.40, 0.25, 0.11)
    closeBtn:SetScript("OnEnter", function(self)
        self.txt:SetTextColor(P.INK_RED[1], P.INK_RED[2], P.INK_RED[3])
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Put the Field Tally away", 1, 0.82, 0)
        GameTooltip:AddLine("Bring it back with the gear on the Objective Tracker, in Options > AddOns > Cache ReQuest, or with /crq tally", 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    closeBtn:SetScript("OnLeave", function(self)
        local cc = P.GetStyle().close
        self.txt:SetTextColor(cc[1], cc[2], cc[3])
        GameTooltip:Hide()
    end)
    f.closeBtn = closeBtn
    closeBtn:SetScript("OnClick", function()
        T.db.show = false
        f:Hide()
        T.Save()
        if T.RefreshOptionsPanel then T.RefreshOptionsPanel() end
    end)

    -- Options gear -> the Cache ReQuest options panel
    local optBtn = CreateFrame("Button", nil, chrome)
    optBtn:SetSize(13, 13)
    optBtn:SetPoint("RIGHT", closeBtn, "LEFT", -3, 0)
    optBtn:SetFrameLevel(base + 19)
    if not T.ApplyGearIcon(optBtn, 0.42, 0.26, 0.09, "opt", 9) then
        optBtn:SetSize(20, 14)
    end
    optBtn:SetScript("OnEnter", function(self)
        T.SetGearHover(self, true)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Cache ReQuest Options", 1, 0.82, 0)
        GameTooltip:AddLine("Look, handwriting, tracker & map settings", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Right-Click: reset the tally's size & position", 0.65, 0.65, 0.65)
        GameTooltip:Show()
    end)
    optBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    optBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            ResetShoppingListPosition()
        elseif T.OpenOptions then
            T.OpenOptions()
        end
    end)
    optBtn:SetScript("OnLeave", function(self)
        T.SetGearHover(self, false)
        GameTooltip:Hide()
    end)
    f.optBtn = optBtn

    -- Page heading (area name) in handwriting, with a quill-ruled underline
    local titleFS = chrome:CreateFontString(nil, "OVERLAY")
    P.SetInkFont(titleFS, "title")
    titleFS:SetPoint("TOPLEFT", chrome, "TOPLEFT", 10, -6)
    titleFS:SetPoint("RIGHT", optBtn, "LEFT", -4, 0)
    titleFS:SetJustifyH("LEFT")
    titleFS:SetWordWrap(false)
    titleFS:SetTextColor(P.INK[1], P.INK[2], P.INK[3], 1)
    f.titleFS = titleFS
    f.titleRule = P.NewStroke(chrome, "ARTWORK", 4)
    f.titleRule2 = P.NewStroke(chrome, "ARTWORK", 4)

    -- Hidden measuring string for the hand-wrapped (struck-through) lines
    f.measureFS = chrome:CreateFontString(nil, "OVERLAY")
    f.measureFS:SetAlpha(0)
    f.measureFS:SetWordWrap(false)

    -- Content Container for Checklist Rows
    local content = CreateFrame("Frame", nil, chrome)
    content:SetPoint("TOPLEFT", chrome, "TOPLEFT", 6, -28)
    content:SetPoint("BOTTOMRIGHT", chrome, "BOTTOMRIGHT", -6, 17)
    content:SetFrameLevel(base + 18)
    f.content = content

    -- Footer (tally + page number), clear of the resize grip (left) and the dog-ear (right)
    local footerFS = chrome:CreateFontString(nil, "OVERLAY")
    P.SetInkFont(footerFS, "small")
    footerFS:SetPoint("BOTTOMLEFT", chrome, "BOTTOMLEFT", 22, 5)
    footerFS:SetPoint("BOTTOMRIGHT", chrome, "BOTTOMRIGHT", -30, 5)
    footerFS:SetJustifyH("LEFT")
    footerFS:SetWordWrap(false)
    footerFS:SetTextColor(0.36, 0.22, 0.08, 0.95)
    f.footerFS = footerFS

    f:SetScript("OnMouseWheel", function(_, delta)
        local total = f.totalItems or 0
        local maxScroll = math.max(0, total - 1)
        T.scroll = math.min(maxScroll, math.max(0, T.scroll - delta))
        P.Render(f)
    end)

    -- Dog-eared corner (bottom-right): the page-turn hot corner
    f.corner = P.CreateCorner(f, chrome)

    -- Resize grip (bottom-left, so the dog-ear owns the bottom-right corner)
    local resizeGrip = CreateFrame("Button", nil, chrome)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMLEFT", chrome, "BOTTOMLEFT", 1, 1)
    resizeGrip:SetFrameLevel(base + 21)
    resizeGrip:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local gripTex = resizeGrip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints()
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    gripTex:SetTexCoord(1, 0, 0, 1)         -- mirrored to point into the bottom-left corner
    gripTex:SetVertexColor(0.75, 0.55, 0.30, 0.85)
    resizeGrip.gripTex = gripTex
    f.gripTex = gripTex

    resizeGrip:SetScript("OnEnter", function(self)
        self.gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
        self.gripTex:SetTexCoord(1, 0, 0, 1)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Resize the Field Tally", 1, 0.82, 0)
        GameTooltip:AddLine("Left-Click & Drag: resize width & height", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Right-Click: reset size & position", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    resizeGrip:SetScript("OnLeave", function(self)
        self.gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        self.gripTex:SetTexCoord(1, 0, 0, 1)
        GameTooltip:Hide()
    end)

    resizeGrip:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            ResetShoppingListPosition()
            return
        end
        if button == "LeftButton" then
            f.isResizing = true
            self.gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
            self.gripTex:SetTexCoord(1, 0, 0, 1)
            local scale = f:GetEffectiveScale() or 1
            local cx, cy = GetCursorPosition()
            f.resizeStartX = cx / scale
            f.resizeStartY = cy / scale
            f.resizeStartW = f:GetWidth()
            f.resizeStartH = f:GetHeight()
            f.resizeStartRight = f:GetRight()
            f.resizeStartTop = f:GetTop()

            self:SetScript("OnUpdate", function()
                if not f.isResizing then return end
                local s = f:GetEffectiveScale() or 1
                local mx, my = GetCursorPosition()
                mx = mx / s
                my = my / s

                -- dragging the bottom-left corner: the top-right corner stays put
                local newW = math.max(185, math.min(520, f.resizeStartW - (mx - f.resizeStartX)))
                local newH = math.max(95, math.min(520, f.resizeStartH - (my - f.resizeStartY)))

                f:ClearAllPoints()
                f:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", f.resizeStartRight, f.resizeStartTop)
                f:SetSize(newW, newH)
                P.Render(f)
            end)
        end
    end)

    resizeGrip:SetScript("OnMouseUp", function(self)
        if f.isResizing then
            f.isResizing = false
            self:SetScript("OnUpdate", nil)
            self.gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
            self.gripTex:SetTexCoord(1, 0, 0, 1)
            T.db.frame.width = math.floor((f:GetWidth() or 230) + 0.5)
            T.db.frame.height = math.floor((f:GetHeight() or 175) + 0.5)
            SavePoint(f)
            T.Save()
            T.Update()
        end
    end)

    f:SetScript("OnSizeChanged", function(self)
        P.ApplyStackLayout(self)
    end)
    f:SetScript("OnHide", function(self)
        if T.HideMapPreview then T.HideMapPreview() end
        self.shuffle = nil
        self.chrome:SetAlpha(1)
        if self.corner then self.corner.size, self.corner.target = P.CORNER_REST, P.CORNER_REST end
    end)
    f:SetScript("OnUpdate", P.OnUpdate)

    P.ApplyStyle(f)
    f:Hide()
    return f
end

-- ----------------------------------------------------------------------------
-- AREA GROUPING
-- ----------------------------------------------------------------------------
-- Which item quests are "near me" (within the proximity radius, or just worked on), plus every
-- eligible item quest so the rest can be filed onto area pages.
-- Your position on your zone's map (in a cave or a city sub-map, translated up to the zone the
-- quest coordinates use), so "Near me" works as a % of the zone map everywhere
function T.PlayerZonePos()
    local mapID, x, y = T.PlayerPos()
    if not (mapID and x and y) then return mapID, x, y end
    local zone = CRQ.NormalizeToZoneMapID and CRQ.NormalizeToZoneMapID(mapID) or mapID
    if zone and zone ~= mapID then
        local zx, zy = P.TranslatePos(mapID, x, y, zone)
        if zx then return zone, zx, zy end
    end
    return mapID, x, y
end

function P.CollectQuests()
    local playerMapID, px, py = T.PlayerZonePos()
    local realZoneRaw = strtrim((GetRealZoneText and GetRealZoneText()) or "")
    local subZoneRaw  = strtrim((GetSubZoneText and GetSubZoneText()) or "")
    local realZone = string.lower(realZoneRaw)
    local subZone  = string.lower(subZoneRaw)
    local areaName = (subZoneRaw ~= "" and subZoneRaw) or (realZoneRaw ~= "" and realZoneRaw) or nil
    local nearTol = P.GetNearRadius() / 100
    local now = GetTime()

    local nearSet, eligible = {}, {}
    for qID, qData in pairs(T.quests) do
        if qData.itemObjectives and #qData.itemObjectives > 0 and T.PassesFilter(qID) then
            table.insert(eligible, qData)
            local near, learnHere = false, false

            -- 1) Distance from you to where the items are gathered (same map only)
            local comparable = playerMapID and px and py and qData.mapID == playerMapID and qData.x and qData.y
            qData.playerDist = nil
            if comparable then
                local dx, dy = px - qData.x, py - qData.y
                qData.playerDist = math.sqrt(dx * dx + dy * dy)
                if qData.playerDist <= nearTol then
                    near, learnHere = true, true
                end
            end

            -- 1b) A world quest / bonus objective is only active while you're inside its area
            if qData.isTask then near = true end

            -- 2) You just progressed it or targeted one of its mobs (last 3 minutes)
            local t = T.recent[qID]
            if t and (now - t) < 180 then
                near = true
                if (now - t) < 20 then learnHere = true end
            end

            -- 3) No usable coordinates (e.g. you're in a cave sub-map, or the client has no waypoint):
            --    fall back to wording / zone clues
            if not near and not comparable then
                local lowerHeader = string.lower(qData.header or "")
                local isSameZone = (realZone ~= "" and (lowerHeader == realZone
                    or string.find(realZone, lowerHeader, 1, true) or string.find(lowerHeader, realZone, 1, true)))
                if subZone ~= "" and string.len(subZone) >= 4 then
                    local lowerTitle = string.lower(qData.title or "")
                    local lowerObj   = string.lower(qData.objectiveText or "")
                    if string.find(lowerTitle, subZone, 1, true) or string.find(lowerObj, subZone, 1, true) then
                        near, learnHere = true, true
                    end
                end
                if not near and isSameZone and (P.GetSuperTrackedID() == qID or (not qData.x and CRQ.IsQuestWatched and CRQ.IsQuestWatched(qID))) then
                    near = true
                end
            end

            -- Remember where this quest's objectives are worked so its area page gets a real name
            if learnHere and areaName then
                T.db.questAreas[qID] = areaName
            end
            if near then nearSet[qID] = true end
        end
    end

    return nearSet, eligible, areaName or "Field Tally"
end

function P.FlattenQuests(quests)
    local items = {}
    local doneCount = 0
    for _, qData in ipairs(quests) do
        for _, obj in ipairs(qData.itemObjectives or {}) do
            if obj.finished then
                doneCount = doneCount + 1
            end
            table.insert(items, {
                qData = qData,
                questID = qData.questID,
                questTitle = qData.title,
                level = qData.level,
                levelHex = qData.levelHex,
                isQuestComplete = qData.isComplete,
                progKey = obj.progKey,
                itemName = obj.itemName,
                numFulfilled = obj.numFulfilled,
                numRequired = obj.numRequired,
                finished = obj.finished,
            })
        end
    end
    return items, doneCount
end

-- Page radius (% of the zone map): either its own setting or the tracker's (•••) stacking slider
function P.GetPageRadius()
    if T.db.opts.pagesFollowTracker then
        return CRQ.GetIncompleteRadius() or 16
    end
    return T.db.pageRadius or 16
end

P.COMPASS = {   -- 8 sectors starting east, counter-clockwise (map y grows downward)
    "Eastern", "North-eastern", "Northern", "North-western", "Western", "South-western", "Southern", "South-eastern",
}

-- "Northern Teldrassil" from where the page's quests sit on their zone map
function P.CompassName(cx, cy, zone)
    zone = zone or "the wilds"
    local dx, dy = cx - 0.5, 0.5 - cy
    if math.sqrt(dx * dx + dy * dy) < 0.13 then return "Central " .. zone end
    local ang = math.atan2(dy, dx)
    if ang < 0 then ang = ang + 2 * math.pi end
    local sector = math.floor((ang + math.pi / 8) / (math.pi / 4)) % 8 + 1
    return P.COMPASS[sector] .. " " .. zone
end

-- Leader clustering (no chaining): each quest joins the nearest page whose centre is within the
-- radius, otherwise it starts a page of its own. Single-linkage (as the tracker stacks use) would
-- chain a whole zone's worth of quests into one page.
function P.ClusterIntoPages(quests, radius)
    table.sort(quests, function(a, b)
        if a.mapID ~= b.mapID then return (a.mapID or 0) < (b.mapID or 0) end
        return a.questID < b.questID
    end)
    local pages = {}
    for _, q in ipairs(quests) do
        local best, bestD = nil, nil
        for _, pg in ipairs(pages) do
            if pg.mapID == q.mapID then
                local dx, dy = q.x - pg.cx, q.y - pg.cy
                local d = math.sqrt(dx * dx + dy * dy)
                if d <= radius and (not bestD or d < bestD) then best, bestD = pg, d end
            end
        end
        if not best then
            best = { mapID = q.mapID, cx = q.x, cy = q.y, quests = {} }
            table.insert(pages, best)
        end
        table.insert(best.quests, q)
        local n = #best.quests
        best.cx = best.cx + (q.x - best.cx) / n
        best.cy = best.cy + (q.y - best.cy) / n
    end
    return pages
end

-- Name a page: the area where its objectives were actually worked (learned as you play), else a compass
-- direction on the zone map, else the quest log header
function P.NamePage(pg)
    -- the explored map area at the page's centre is the most accurate name
    local atCentre = pg.cx and P.AreaNameAt(pg.mapID, pg.cx, pg.cy)
    if atCentre then return atCentre end
    local votes, bestName, bestN = {}, nil, 0
    for _, q in ipairs(pg.quests) do
        local nm = T.db.questAreas[q.questID]
        if nm then
            votes[nm] = (votes[nm] or 0) + 1
            if votes[nm] > bestN then bestName, bestN = nm, votes[nm] end
        end
    end
    if bestName then return bestName end
    local zone = pg.quests[1] and pg.quests[1].header
    if pg.cx then return P.CompassName(pg.cx, pg.cy, zone) end
    return zone or "Elsewhere"
end

-- "Near me" radius (% of the zone map): how close you must be to where a quest's items are gathered
function P.GetNearRadius()
    return T.db.nearRadius or 10
end

-- ----------------------------------------------------------------------------
-- AREA PAGE NAMES
-- ----------------------------------------------------------------------------
P.GROUPINGS = {
    { key = "AREA",   label = "Map areas" },   -- the explored subzone the items are in (world-map area names)
    { key = "ZONE",   label = "Zones" },       -- one page per zone
    { key = "RADIUS", label = "Distance" },    -- clusters by the Area page size slider
}

function P.GetGrouping()
    for _, g in ipairs(P.GROUPINGS) do
        if g.key == T.db.grouping then return g end
    end
    return P.GROUPINGS[1]
end

function P.CycleGrouping()
    local idx = 1
    for i, g in ipairs(P.GROUPINGS) do
        if g.key == T.db.grouping then idx = i end
    end
    T.db.grouping = P.GROUPINGS[(idx % #P.GROUPINGS) + 1].key
end

-- Subzone name at a map position, the same way the world map labels areas you have explored
P.areaNameCache = {}
function P.AreaNameAt(mapID, x, y)
    if not (mapID and x and y) then return nil end
    local key = mapID .. ":" .. math.floor(x * 250) .. ":" .. math.floor(y * 250)
    local cached = P.areaNameCache[key]
    if cached then return cached end
    local api = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredAreaIDsAtPosition
    if not (api and C_Map and C_Map.GetAreaInfo and CreateVector2D) then return nil end
    local ok, ids = pcall(api, mapID, CreateVector2D(x, y))
    if ok and type(ids) == "table" then
        for _, id in ipairs(ids) do
            local okN, name = pcall(C_Map.GetAreaInfo, id)
            if okN and type(name) == "string" and name ~= "" then
                P.areaNameCache[key] = name        -- only cache hits: unexplored spots may get explored later
                return name
            end
        end
    end
    return nil
end

function P.ZoneNameOf(q)
    if q.mapID and C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, q.mapID)
        if ok and info and info.name and info.name ~= "" then return info.name end
    end
    return q.header or "Elsewhere"
end

-- The map area a quest's items are in: explored subzone at its position > where you've worked it >
-- compass sector of its zone > quest log header
function P.AreaNameOf(q)
    if q.mapID and q.x and q.y then
        local nm = P.AreaNameAt(q.mapID, q.x, q.y)
        if nm then return nm end
    end
    local learned = T.db.questAreas[q.questID]
    if learned then return learned end
    if q.x and q.y then return P.CompassName(q.x, q.y, P.ZoneNameOf(q)) end
    return q.header or "Elsewhere"
end

function P.BuildAreas()
    local nearSet, eligible, here = P.CollectQuests()
    -- Page 1 is always "Near me": what you can gather from where you stand
    local current = { key = P.CURRENT_KEY, title = "Near me", subtitle = here, isCurrent = true, quests = {} }
    local areas = { current }

    local rest = {}
    for _, q in ipairs(eligible) do
        if nearSet[q.questID] then
            table.insert(current.quests, q)
        elseif not q.isComplete then        -- area pages only carry what still needs gathering
            table.insert(rest, q)
        end
    end

    if T.db.opts.showTabs then
        local mode = P.GetGrouping().key
        local named = {}       -- { title, quests } before merging

        if mode == "RADIUS" then
            local withCoords = {}
            for _, q in ipairs(rest) do
                if q.mapID and q.x and q.y then
                    table.insert(withCoords, q)
                else
                    table.insert(named, { title = T.db.questAreas[q.questID] or q.header or "Elsewhere", quests = { q } })
                end
            end
            for _, pg in ipairs(P.ClusterIntoPages(withCoords, P.GetPageRadius() / 100)) do
                pg.title = P.NamePage(pg)
                table.insert(named, pg)
            end
        else
            for _, q in ipairs(rest) do
                local title = (mode == "ZONE") and P.ZoneNameOf(q) or P.AreaNameOf(q)
                table.insert(named, { title = title, quests = { q } })
            end
        end

        -- One page per name, in every mode: never "Dolanaar II / III"
        local byTitle, others = {}, {}
        for _, pg in ipairs(named) do
            local k = string.lower(pg.title or "Elsewhere")
            if k == "near me" then k = "near me (area)" end
            local page = byTitle[k]
            if not page then
                page = { key = "AREA:" .. k, title = pg.title or "Elsewhere", quests = {} }
                byTitle[k] = page
                table.insert(others, page)
            end
            for _, q in ipairs(pg.quests) do table.insert(page.quests, q) end
        end

        -- Nearest page first (by its closest quest), then alphabetical
        for _, pg in ipairs(others) do
            local d = nil
            for _, q in ipairs(pg.quests) do
                if q.playerDist and (not d or q.playerDist < d) then d = q.playerDist end
            end
            pg.playerDist = d
        end
        table.sort(others, function(a, b)
            local da, db = a.playerDist or math.huge, b.playerDist or math.huge
            if da ~= db then return da < db end
            return a.title < b.title
        end)

        local maxOthers = P.MAX_AREAS - 1
        if #others > maxOthers then
            local overflow = { key = "AREA:__elsewhere", title = "Elsewhere", quests = {} }
            for i = maxOthers, #others do
                for _, q in ipairs(others[i].quests) do table.insert(overflow.quests, q) end
            end
            for i = #others, maxOthers, -1 do table.remove(others, i) end
            table.insert(others, overflow)
        end
        for _, pg in ipairs(others) do table.insert(areas, pg) end
    end

    for _, a in ipairs(areas) do
        table.sort(a.quests, T.CompareQuests)
        a.items, a.doneCount = P.FlattenQuests(a.quests)
        a.remaining = #a.items - a.doneCount
    end
    return areas
end

-- ----------------------------------------------------------------------------
-- QUEST REWARDS at the right of an item line ("[icon] 250  [icon] 12")
-- EDIT: REWARD_GAP = space (px) kept between the item text and the rewards, so a long item name
--       wraps before it reaches them; REWARD_MAX_SHARE = most of the line the rewards may take
--       (beyond that only the first reward is shown); REWARD_ICON = icon size.
-- ----------------------------------------------------------------------------
P.REWARD_GAP = 8
P.REWARD_MAX_SHARE = 0.42
P.REWARD_ICON = 12
P.GOLD_ICON = "Interface\\MoneyFrame\\UI-GoldIcon"

function P.FormatAmount(n)
    n = tonumber(n) or 0
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
    return tostring(n)
end

-- The reward text for a quest (nil when it has none): rewards matching your active reward filter
-- come first. Amounts are inked in the look's reward colours; money in its gold colour.
function P.RewardBadge(questID, st, maxParts)
    if not CRQ.GetQuestRewardsForTally then return nil end
    local ok, list = pcall(CRQ.GetQuestRewardsForTally, questID, maxParts or 2)
    if not ok or type(list) ~= "table" or #list == 0 then return nil end
    local rc, gc = st.reward or st.ink, st.rewardGold or st.inkRed
    local parts = {}
    for _, r in ipairs(list) do
        local icon = r.isGold and P.GOLD_ICON or r.icon or 134400
        local s = string.format("|T%s:%d:%d:0:0|t", tostring(icon), P.REWARD_ICON, P.REWARD_ICON)
        local showAmount = r.isGold or r.isCurrency or (tonumber(r.amount) or 1) > 1
        if showAmount then
            s = s .. string.format(" |c%s%s|r", P.Hex(r.isGold and gc or rc), P.FormatAmount(r.amount))
        end
        table.insert(parts, s)
    end
    return table.concat(parts, "  "), list
end

-- Every reward by name in the item's tooltip (the line itself only has room for icons and amounts)
function P.AddRewardTooltipLines(tt, questID)
    if not (T.db.opts.showRewards and CRQ.GetQuestRewardsForTally) then return end
    local ok, list = pcall(CRQ.GetQuestRewardsForTally, questID, 8)
    if not ok or type(list) ~= "table" or #list == 0 then return end
    tt:AddLine("Rewards:", 1, 0.82, 0)
    for _, r in ipairs(list) do
        local icon = string.format("|T%s:14:14:0:0|t ", tostring(r.isGold and P.GOLD_ICON or r.icon or 134400))
        local amount = (r.isGold or r.isCurrency or (tonumber(r.amount) or 1) > 1) and (P.FormatAmount(r.amount) .. " ") or ""
        local name = r.isGold and "Gold" or (r.name or "Reward")
        if r.isGold then tt:AddLine(icon .. amount .. name, 1.0, 0.82, 0.0)
        elseif r.isCurrency then tt:AddLine(icon .. amount .. name, 0.0, 0.80, 1.0)
        else tt:AddLine(icon .. amount .. name, 0.9, 0.9, 0.9) end
    end
end

-- Writes the rewards on the row; returns the width they take (0 when there are none)
function P.LayoutRowReward(row, entry, st, contentW, show)
    local fs = row.rewardText
    fs:Hide()
    if not show then return 0 end
    P.SetInkFont(fs, "small")
    local maxW = contentW * P.REWARD_MAX_SHARE
    for parts = 2, 1, -1 do
        local text = P.RewardBadge(entry.questID, st, parts)
        if not text then return 0 end
        fs:SetText(text)
        local rw = math.ceil(fs:GetStringWidth() or 0)
        if rw <= maxW or parts == 1 then
            fs:Show()
            return math.min(rw, maxW)
        end
    end
    return 0
end

-- ----------------------------------------------------------------------------
-- RENDER THE SELECTED SHEET
-- ----------------------------------------------------------------------------
function P.Render(f)
    local area = P.GetSelectedArea()
    if not area then return end

    local items = area.items or {}
    f.totalItems = #items
    for _, row in ipairs(T.rowPool) do
        row:Hide()
    end

    local pageIdx, pageCount = P.GetAreaIndex(area.key), #P.areas
    local pageStr = (pageCount > 1) and string.format("  ·  page %d of %d", pageIdx, pageCount) or ""
    local now = GetTime()
    local w = f:GetWidth() or 230
    local st = P.GetStyle()
    if f.styleKey ~= st.key then P.ApplyStyle(f) end
    local pad = st.pad or 0

    -- Heading: fresh red ink for a few seconds after you arrive in a new area
    P.SetInkFont(f.titleFS, "title")
    P.SetInkFont(f.footerFS, "small")
    local title = area.title or (area.isCurrent and "Field Tally" or "Elsewhere")
    if area.isCurrent and now < (P.currentGlowUntil or 0) then
        f.titleFS:SetTextColor(P.INK_RED[1], P.INK_RED[2], P.INK_RED[3], 1)
    else
        f.titleFS:SetTextColor(st.title[1], st.title[2], st.title[3], 1)
    end
    if area.isCurrent and area.subtitle and area.subtitle ~= "" then
        f.titleFS:SetText(title .. "  |c" .. P.Hex(st.sub) .. "· " .. area.subtitle .. "|r")
    else
        f.titleFS:SetText(title)
    end
    local ruleW = math.min(w - 20 - 2 * pad, math.max(60, (f.titleFS:GetStringWidth() or 80) + 22))
    P.DrawStroke(f.titleRule, f.chrome, 8 + pad, -25 - pad, 8 + pad + ruleW, -24 - pad, 1.2, 0.70)
    P.DrawStroke(f.titleRule2, f.chrome, 14 + pad, -27.5 - pad, 8 + pad + ruleW * 0.55, -27 - pad, 0.7, 0.40)

    if #items == 0 then
        local row = AcquireShoppingListRow(1, f.content)
        P.StyleRow(row)
        P.SetRowFX(row, nil)
        P.SetRowLasso(row, false)
        row.box:Hide()
        P.HideStrikes(row)
        row.suffixText:Hide()
        row.rewardText:Hide()
        P.SetInkFont(row.itemText, "item")
        row.itemText:SetWidth(math.max(120, w - 30 - 2 * pad))
        row.itemText:SetTextColor(st.faded[1], st.faded[2], st.faded[3], 1)
        row.itemText:SetText((area.isCurrent and "Nothing to gather near you." or "Nothing left to gather here.") ..
            ((pageCount > 1) and "\nTurn the page corner to see other areas." or ""))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -2)
        row:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", 0, -2)
        row:SetHeight(36)
        row:SetScript("OnClick", nil)
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
        row:Show()
        f.footerFS:SetText("nothing here" .. pageStr)
        return
    end

    if T.scroll > math.max(0, #items - 1) then
        T.scroll = math.max(0, #items - 1)
    end

    local contentW = math.max(150, w - 12 - 2 * pad)
    local contentH = math.max(55, (f:GetHeight() or 175) - 45 - 2 * pad)
    local yCursor = 0
    local shownRows = 0
    P.SetInkFont(f.measureFS, "item")
    local huntCtx = T.BuildHuntContext()
    local countHex, nameHex = P.Hex(st.inkRed), P.Hex(st.name or st.ink)
    local trackedID = P.GetSuperTrackedID()
    local rewardShown = {}      -- a quest's rewards go on its first line only (not repeated per item)

    for i = 1 + T.scroll, #items do
        if shownRows >= P.MAX_ROWS then break end
        local entry = items[i]
        local row = AcquireShoppingListRow(shownRows + 1, f.content)
        P.StyleRow(row)
        row.box:Show()
        P.SetInkFont(row.itemText, "item")
        P.SetInkFont(row.suffixText, "small")
        P.HideStrikes(row)
        row.suffixText:Hide()

        -- rewards right-aligned; the item text column stops REWARD_GAP short of them, so a long
        -- name wraps onto the next line instead of running underneath
        local showReward = T.db.opts.showRewards and not rewardShown[entry.questID]
        local rewardW = P.LayoutRowReward(row, entry, st, contentW, showReward)
        if rewardW > 0 then rewardShown[entry.questID] = true end
        local textW = math.max(70, contentW - 24 - ((rewardW > 0) and (rewardW + P.REWARD_GAP) or 0))
        row.itemText:SetWidth(textW)
        row.textW = textW

        local isFlashing = T.flashUntil[entry.progKey] and (now < T.flashUntil[entry.progKey])
        local countStr = string.format("%d/%d", entry.numFulfilled or 0, entry.numRequired or 1)
        local nameStr = entry.itemName or ""
        local strH

        local wa = st.wash
        if entry.finished then
            P.ShowTick(row.box, row.seed)
            row.box.wash:SetColorTexture(wa[1], wa[2], wa[3], wa[4])

            -- Faded ink, wrapped by hand so every line gets a strike exactly as long as its words
            local lines, widths = P.WrapLines(f.measureFS, countStr .. "  " .. nameStr, textW)
            row.itemText:SetTextColor(st.faded[1], st.faded[2], st.faded[3], 1)
            row.itemText:SetText(table.concat(lines, "\n"))
            strH = math.max(14, math.ceil(row.itemText:GetStringHeight() or 14))
            local lineH = strH / #lines
            for k, lw in ipairs(widths) do
                local tilt = (P.Hash01(row.seed, k, 5) - 0.5) * 1.8
                local y = -(k - 0.5) * lineH + 0.5
                P.DrawStroke(P.GetStrike(row, k), row.itemText, -2, y + tilt * 0.5, lw + 2, y - tilt * 0.5, 1.3, 0.82)
            end

            if entry.isQuestComplete then
                row.suffixText:SetText("(turn in)")
                local sw = row.suffixText:GetStringWidth() or 40
                local lastW = widths[#widths] or 0
                row.suffixText:ClearAllPoints()
                if lastW + 8 + sw <= textW then
                    -- same line, after the struck words
                    row.suffixText:SetPoint("TOPLEFT", row.itemText, "TOPLEFT", lastW + 8, -(#lines - 1) * lineH - 1)
                else
                    row.suffixText:SetPoint("TOPLEFT", row.itemText, "TOPLEFT", 0, -strH - 1)
                    strH = strH + math.ceil(row.suffixText:GetStringHeight() or 11) + 1
                end
                row.suffixText:Show()
            end
        else
            P.HideTick(row.box)
            if isFlashing then
                local wf = st.washFlash
                row.box.wash:SetColorTexture(wf[1], wf[2], wf[3], wf[4])   -- fresh tally mark
            else
                row.box.wash:SetColorTexture(wa[1], wa[2], wa[3], wa[4])
            end
            row.itemText:SetTextColor(P.INK[1], P.INK[2], P.INK[3], 1)
            row.itemText:SetText(string.format("|c%s%s|r  |c%s%s|r", countHex, countStr, nameHex, nameStr))
            strH = math.max(14, math.ceil(row.itemText:GetStringHeight() or 14))
        end

        -- glow in its hunting grounds, flames when your target drops it, red ink circle round the
        -- items of the quest you're tracking
        local fxMode = T.GetItemFXMode(entry, huntCtx)
        P.SetRowFX(row, fxMode, countStr .. "  " .. nameStr, textW, entry.progKey)
        P.SetRowLasso(row, trackedID ~= nil and trackedID == entry.questID)

        local rowH = strH + 7

        if (math.abs(yCursor) + rowH) > (contentH + 4) and shownRows > 0 then
            row:Hide()
            break
        end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, yCursor)
        row:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", 0, yCursor)
        row:SetHeight(rowH)

        row:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                T.OpenQuestLog(entry.questID)
            else
                -- same as clicking the quest's icon in the Objective Tracker: track it / stop tracking
                T.ToggleSuperTrack(entry.questID)
            end
        end)

        row:SetScript("OnEnter", function(self)
            P.PlaceTooltip(self)
            local lvlStr = entry.level and string.format("|c%s[%d]|r ", entry.levelHex or "FFFFD100", entry.level) or ""
            GameTooltip:AddLine(lvlStr .. "|cFFFFD100" .. (entry.questTitle or "Quest") .. "|r")
            GameTooltip:AddLine(string.format("%s: %d / %d", entry.itemName or "Objective", entry.numFulfilled or 0, entry.numRequired or 1), 0.9, 0.9, 0.9)
            if entry.isQuestComplete then
                GameTooltip:AddLine("All objectives complete — ready to turn in!", 0.25, 0.95, 0.25)
            end
            T.AddHuntTooltipLines(GameTooltip, entry)
            P.AddRewardTooltipLines(GameTooltip, entry.questID)
            local tracked = P.GetSuperTrackedID() == entry.questID
            GameTooltip:AddLine((tracked and "Left-Click: stop tracking this quest" or "Left-Click: track this quest")
                .. "  |  Right-Click: open the quest log", 0.65, 0.65, 0.65)
            GameTooltip:Show()
            local okPv, errPv = pcall(T.ShowMapPreview, entry, GameTooltip)
            if not okPv then T.HideMapPreview(); T.ReportError(errPv) end
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
            T.HideMapPreview()
        end)

        row:Show()
        yCursor = yCursor - rowH
        shownRows = shownRows + 1
    end

    local doneCount = area.doneCount or 0
    if #items > shownRows then
        f.footerFS:SetText(string.format("%d of %d gathered  ·  %d-%d shown%s",
            doneCount, #items, T.scroll + 1, T.scroll + shownRows, pageStr))
    else
        f.footerFS:SetText(string.format("%d of %d gathered%s", doneCount, #items, pageStr))
    end
end

T.Update = function()
    local f = EnsureShoppingListFrame()
    if not T.db.show then
        f:Hide()
        return
    end

    local areas = P.BuildAreas()
    P.areas = areas
    local current = areas[1]
    P.CheckAreaChange(f)

    local selected = nil
    for _, a in ipairs(areas) do
        if a.key == P.selectedKey then selected = a break end
    end
    if not selected then
        P.selectedKey = current.key
        T.scroll = 0
    end

    local anyItems = false
    for _, a in ipairs(areas) do
        if #a.items > 0 then anyItems = true break end
    end
    if not anyItems or (#current.items == 0 and (#areas == 1 or T.db.opts.hideWhenNothingNearby)) then
        f:Hide()
        return
    end

    -- one page per area: the pile under the top page shows how many other pages there are
    -- (the see-through window has no pile; its footer still reads "page n of m")
    f.visibleBackSheets = P.GetStyle().pile and math.max(0, math.min(#areas - 1, P.MAX_BACK_SHEETS)) or 0
    f:Show()
    P.Render(f)
    P.UpdateCorner(f)
    P.ApplyStackLayout(f)
end

-- ============================================================================
-- HUNTING GROUNDS
-- Where a tally item is gathered (learned from where you loot it + the quest's own objective
-- area) and which mobs drop it (learned from the loot window + unit tooltips, names as a last resort).
-- EDIT: the radii are fractions of the map's width (0.035 = 3.5%): bigger = the glow starts further out.
-- ============================================================================
P.HUNT_SPOT_RADIUS = 0.035      -- a looted-here spot counts as hunting ground within 3.5% of the map
P.HUNT_POI_RADIUS = 0.06        -- ...and so does the quest's objective area (its map POI) within 6%
P.MAX_HUNT_SPOTS = 12           -- per item; nearby loots merge into one spot

function P.Round4(v) return math.floor(v * 10000 + 0.5) / 10000 end

-- "npc:1234" from a creature GUID, so a mob is recognised whatever its name is in your language
function P.NpcKey(guid)
    if type(guid) ~= "string" then return nil end
    local kind, id = string.match(guid, "^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if (kind == "Creature" or kind == "Vehicle") and id then return "npc:" .. id end
    return nil
end

-- Position on another map (e.g. a spot looted on the zone map, shown on the continent map)
function P.TranslatePos(fromMap, x, y, toMap)
    if not (fromMap and x and y and toMap) then return nil end
    if fromMap == toMap then return x, y end
    if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
    local ok, cont, wpos = pcall(C_Map.GetWorldPosFromMapPos, fromMap, CreateVector2D(x, y))
    if not (ok and cont and wpos) then return nil end
    local ok2, _, mpos = pcall(C_Map.GetMapPosFromWorldPos, cont, wpos, toMap)
    if ok2 and mpos and mpos.GetXY then
        local mx, my = mpos:GetXY()
        if mx and my and mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then return mx, my end
    end
    return nil
end

-- An item objective just ticked up: you are standing in its hunting grounds, and whatever you just
-- looted drops it
function T.OnItemProgress(questID, progKey)
    local mapID, x, y = T.PlayerZonePos()
    if mapID and x and y then
        local list = T.K.spots[progKey]
        if not list then
            list = {}
            T.K.spots[progKey] = list
        end
        local sub = strtrim((GetSubZoneText and GetSubZoneText()) or "")
        local merged = false
        local mergeR = P.HUNT_SPOT_RADIUS * 0.6
        for _, sp in ipairs(list) do
            if sp.m == mapID then
                local dx, dy = sp.x - x, sp.y - y
                if dx * dx + dy * dy < mergeR * mergeR then
                    sp.n = math.min(50, (sp.n or 1) + 1)
                    sp.x = P.Round4(sp.x + (x - sp.x) / sp.n)
                    sp.y = P.Round4(sp.y + (y - sp.y) / sp.n)
                    if sub ~= "" then sp.a = sub end
                    merged = true
                    break
                end
            end
        end
        if not merged then
            table.insert(list, 1, { m = mapID, x = P.Round4(x), y = P.Round4(y), a = (sub ~= "") and sub or nil, n = 1 })
            while #list > P.MAX_HUNT_SPOTS do table.remove(list) end
        end
    end

    local src = T.lastLootMob
    if src and (GetTime() - src.t) < 8 and not (src.recorded and src.recorded[progKey]) then
        local d = T.DropperRecord(src.key, src.label)
        d[progKey] = (d[progKey] or 0) + 1
    end
end

-- ----------------------------------------------------------------------------
-- WHO DROPS WHAT: evidence first, guesses last
-- The game has no drop-table API, but the loot window is authoritative: every slot says which
-- corpse it came from (GetLootSourceInfo) and what the item is. Each loot records, per npc id: how many of its corpses you looted while you still needed items ("loots"),
-- and how many times each tally item was in the loot ([progKey] = hits). Hits make a mob a sure
-- dropper; many loots and no hit rule a mob out even if its name looks right.
-- ----------------------------------------------------------------------------
T.countedCorpses = {}

function T.DropperRecord(key, label)
    local d = T.K.droppers[key]
    if not d then
        d = { loots = 0 }
        T.K.droppers[key] = d
    end
    if label and label ~= "" then d.label = label end
    return d
end

-- Name of the mob behind a GUID, if known (current target, mouseover, or the last target)
function P.NameForGUID(guid)
    if not guid then return nil end
    if T.UnitStr(UnitGUID, "target") == guid then return T.UnitStr(UnitName, "target") end
    if T.UnitStr(UnitGUID, "mouseover") == guid then return T.UnitStr(UnitName, "mouseover") end
    local last = T.lastTargetMob
    if last and last.guid == guid then return last.name end
    return nil
end

-- Reads the open loot window: which corpses, and which tally items each one gave
function T.ScanLootWindow()
    local needed, anyNeeded = {}, false
    for _, q in pairs(T.quests) do
        for _, o in ipairs(q.itemObjectives or {}) do
            if not o.finished and o.itemName and o.itemName ~= "" then
                needed[string.lower(o.itemName)] = o.progKey
                anyNeeded = true
            end
        end
    end
    if not (anyNeeded and GetNumLootItems and GetLootSlotInfo and GetLootSourceInfo) then return {} end

    local found = {}           -- [progKey] = true: items seen in this loot window
    local corpses = {}         -- [guid] = npc key
    local okN, n = pcall(GetNumLootItems)
    for slot = 1, (okN and tonumber(n)) or 0 do
        local okI, _, itemName = pcall(GetLootSlotInfo, slot)
        itemName = okI and T.Plain(itemName) or nil
        local progKey = type(itemName) == "string" and needed[string.lower(itemName)]
        local src = { pcall(GetLootSourceInfo, slot) }       -- ok, guid1, qty1, guid2, qty2, ... (area loot)
        if src[1] then
            for j = 2, #src, 2 do
                local guid = T.Plain(src[j])
                local key = (type(guid) == "string") and P.NpcKey(guid) or nil
                if key then
                    corpses[guid] = key
                    if progKey then
                        local d = T.DropperRecord(key, P.NameForGUID(guid))
                        local mark = guid .. "|" .. progKey
                        if not T.countedCorpses[mark] then
                            T.countedCorpses[mark] = true
                            d[progKey] = (d[progKey] or 0) + 1
                        end
                        found[progKey] = true
                    end
                end
            end
        end
    end
    -- every corpse looted once counts as a try at each item you still needed then, whether it
    -- dropped or not (re-opening the same corpse doesn't count again)
    for guid, key in pairs(corpses) do
        if not T.countedCorpses[guid] then
            T.countedCorpses[guid] = true
            local d = T.DropperRecord(key, P.NameForGUID(guid))
            d.loots = (d.loots or 0) + 1
            d.tries = d.tries or {}
            for _, pk in pairs(needed) do d.tries[pk] = (d.tries[pk] or 0) + 1 end
        end
    end
    -- keep the session's "already counted" list short
    local c = 0
    for _ in pairs(T.countedCorpses) do c = c + 1 end
    if c > 400 then T.countedCorpses = {} end
    return found
end

-- The loot window opened: read it, and remember which mob it's from (not herbs, chests or fishing)
function T.OnLootOpened()
    T.lastLootMob = nil
    if T.UnitFlag(IsFishingLoot) then return end
    local okScan, found = pcall(T.ScanLootWindow)
    found = okScan and found or {}
    local srcGUID = T.Call(GetLootSourceInfo, 1)
    if type(srcGUID) ~= "string" then srcGUID = nil end
    if srcGUID and not P.NpcKey(srcGUID) then return end   -- a game object (herb, chest), not a mob

    local name, guid
    if T.UnitFlag(UnitExists, "target") and T.UnitFlag(UnitIsDead, "target") and not T.UnitFlag(UnitIsPlayer, "target") then
        name, guid = T.UnitStr(UnitName, "target"), T.UnitStr(UnitGUID, "target")
    end
    if srcGUID and guid ~= srcGUID then
        local last = T.lastTargetMob
        if last and last.guid == srcGUID then name, guid = last.name, last.guid else name, guid = nil, srcGUID end
    end
    local key = P.NpcKey(guid) or (name and string.lower(name))
    if key then
        -- "recorded": items the loot window already credited, so the quest-progress fallback
        -- (T.OnItemProgress) doesn't count the same drop twice
        T.lastLootMob = { key = key, label = name, t = GetTime(), recorded = found }
    end
end

P.GENERIC_WORDS = {
    small = true, large = true, piece = true, sample = true, fragment = true, shard = true, scrap = true,
    token = true, bundle = true, pouch = true, part = true, essence = true, crate = true, supply = true,
    ancient = true, elder = true, young = true, giant = true, greater = true, lesser = true, mature = true,
    the = true, with = true, from = true, some = true, intact = true, pristine = true, fresh = true, rough = true,
}

function P.NameWords(s)
    local out = {}
    for word in string.gmatch(string.lower(s or ""), "[%a']+") do
        word = string.gsub(word, "'s$", "")
        if string.len(word) > 4 and string.sub(word, -1) == "s" then word = string.sub(word, 1, -2) end
        if string.len(word) >= 4 and not P.GENERIC_WORDS[word] then out[word] = true end
    end
    return out
end

-- "Small Spider Leg" / "Webwood Spider", "Gnarlpine Fang" / "Gnarlpine Mystic": a distinctive word in common
function P.NamesShareWord(itemName, mobName)
    local a = P.NameWords(itemName)
    for w in pairs(P.NameWords(mobName)) do
        if a[w] then return true end
    end
    return false
end

-- Unit tooltip lines (lower case) from C_TooltipInfo. Retail unit tooltips list the quests a mob
-- belongs to as typed lines (quest title / objective / party member), so the second result says
-- whether this tooltip carries any quest lines at all. Secret lines (restricted content) are skipped.
function T.ReadUnitTooltip(unit)
    local lines, hasQuestLine = {}, false
    if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then return lines, false end
    local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
    if not (ok and type(data) == "table" and type(data.lines) == "table") then return lines, false end
    local LT = Enum and Enum.TooltipDataLineType
    local questTypes = {}
    if LT then
        for _, k in ipairs({ "QuestObjective", "QuestTitle", "QuestPlayer" }) do
            if LT[k] then questTypes[LT[k]] = true end
        end
    end
    for _, ln in ipairs(data.lines) do
        local txt = (type(ln) == "table") and T.Plain(ln.leftText) or nil
        if type(txt) == "string" then
            table.insert(lines, string.lower(txt))
            local ty = T.Plain(ln.type)
            if ty ~= nil and questTypes[ty] then hasQuestLine = true end
        end
    end
    return lines, hasQuestLine
end

-- EDIT: looted this many of a mob without ever getting the item = it doesn't drop it
P.RULE_OUT_LOOTS = 4

-- Which unfinished tally items could this mob drop? Returns { [progKey] = "sure" | "guess" } or nil.
--   sure:  you've looted the item from this npc before, or its tooltip names the item / the quest
--   guess: only the names look related (and nothing rules it out)
function T.FindTargetDrops(unit)
    unit = unit or "target"
    if not T.UnitFlag(UnitExists, unit) then return nil end
    if T.UnitFlag(UnitIsPlayer, unit) then return nil end
    if UnitCanAttack and not T.UnitFlag(UnitCanAttack, "player", unit) then return nil end   -- friendly NPCs don't drop loot
    local name = T.UnitStr(UnitName, unit)
    if not name then return nil end          -- unknown, or hidden from addons here
    local learnedA = T.K.droppers[P.NpcKey(T.UnitStr(UnitGUID, unit)) or ""]
    local learnedB = T.K.droppers[string.lower(name)]
    local tipLines, tipQuestLine = T.ReadUnitTooltip(unit)

    -- Does the client say this unit is part of one of your quests? (nil = unknown)
    local related
    if C_QuestLog and C_QuestLog.UnitIsRelatedToActiveQuest then
        local r = T.Call(C_QuestLog.UnitIsRelatedToActiveQuest, unit)
        if type(r) == "boolean" then related = r end
    end
    -- Does its tooltip carry any quest of yours? Once tooltips have shown quests on this client,
    -- a tooltip *without* quest lines is evidence too.
    local titles = {}
    for _, q in pairs(T.quests) do
        if q.title and q.title ~= "" then titles[string.lower(q.title)] = true end
    end
    local tipHasQuest = tipQuestLine == true
    for _, ln in ipairs(tipLines) do
        if titles[strtrim(ln)] then tipHasQuest = true break end
    end
    if tipHasQuest then T.tooltipShowsQuests = true end

    local keys, any = {}, false
    for _, q in pairs(T.quests) do
        local onlyItems = true
        for _, o in ipairs(q.quantityObjectives or {}) do
            if not o.isItem and not o.finished then onlyItems = false end
        end
        local lowerTitle = string.lower(q.title or "")
        for _, obj in ipairs(q.itemObjectives or {}) do
            if not obj.finished then
                local k = obj.progKey
                local level
                local hits = ((learnedA and learnedA[k]) or 0) + ((learnedB and learnedB[k]) or 0)
                local loots = ((learnedA and learnedA.tries and learnedA.tries[k]) or 0)
                    + ((learnedB and learnedB.tries and learnedB.tries[k]) or 0)
                if hits > 0 then
                    level = "sure"
                else
                    local lowerItem = string.lower(obj.itemName or "")
                    for _, ln in ipairs(tipLines) do
                        if (lowerItem ~= "" and string.find(ln, lowerItem, 1, true))
                            or (onlyItems and lowerTitle ~= "" and strtrim(ln) == lowerTitle) then
                            level = "sure"
                            break
                        end
                    end
                end
                if not level then
                    local ruledOut = loots >= P.RULE_OUT_LOOTS                         -- looted often, never got it
                        or related == false                                            -- client: not a quest mob
                        or (T.tooltipShowsQuests and not tipHasQuest)                -- tooltip would have said so
                    if not ruledOut and P.NamesShareWord(obj.itemName, name) then level = "guess" end
                end
                if level then
                    keys[k] = level
                    any = true
                end
            end
        end
    end
    return any and keys or nil
end

-- New target: set the tally alight for anything it may drop
function T.OnTargetChanged()
    local guid = T.UnitStr(UnitGUID, "target")
    if T.UnitFlag(UnitExists, "target") and not T.UnitFlag(UnitIsPlayer, "target") and guid then
        T.lastTargetMob = { guid = guid, name = T.UnitStr(UnitName, "target"), t = GetTime() }
    end
    local keys = T.FindTargetDrops("target")
    if not keys then
        P.fire = nil
        return
    end
    local now = GetTime()
    P.fire = { keys = keys, guid = guid, since = now }
    for k in pairs(keys) do
        local qID = tonumber(string.match(k, "^(%d+)_"))
        if qID then T.recent[qID] = now end     -- puts it on the "Near me" page
    end
    -- turn back to "Near me" so the burning line is in front of you
    local f = T.frame
    if f and f:IsShown() and P.selectedKey ~= P.CURRENT_KEY and not f.shuffle then
        f.shuffle = { t = 0, dur = 0.55, key = P.CURRENT_KEY, swapped = false, dir = -1 }
    end
end

-- Location snapshot for one render: where you are, and the quest objective areas on your map
function T.BuildHuntContext()
    local mapID, x, y = T.PlayerZonePos()
    local ctx = { mapID = mapID, x = x, y = y, pois = {},
        sub = string.lower(strtrim((GetSubZoneText and GetSubZoneText()) or "")) }
    if mapID and C_QuestLog and C_QuestLog.GetQuestsOnMap then
        local ok, list = pcall(C_QuestLog.GetQuestsOnMap, mapID)
        if ok and type(list) == "table" then
            for _, info in ipairs(list) do
                if info.questID and info.x and info.y then ctx.pois[info.questID] = { info.x, info.y } end
            end
        end
    end
    return ctx
end

function T.IsInHuntGrounds(entry, ctx)
    if not entry or not ctx then return false end
    local px, py = ctx.x, ctx.y
    local function Near(x, y, r)
        if not (x and y and px and py) then return false end
        local dx, dy = x - px, y - py
        return dx * dx + dy * dy <= r * r
    end
    for _, sp in ipairs(T.K.spots[entry.progKey] or {}) do
        if ctx.sub ~= "" and sp.a and string.lower(sp.a) == ctx.sub then return true end   -- same subzone
        if ctx.mapID then
            local sx, sy = P.TranslatePos(sp.m, sp.x, sp.y, ctx.mapID)
            if Near(sx, sy, P.HUNT_SPOT_RADIUS) then return true end
        end
    end
    local poi = ctx.pois[entry.questID]
    if poi and Near(poi[1], poi[2], P.HUNT_POI_RADIUS) then return true end
    local q = entry.qData
    if q and not q.isComplete and q.mapID and q.mapID == ctx.mapID and Near(q.x, q.y, P.HUNT_POI_RADIUS) then
        return true
    end
    return false
end

function T.GetItemFXMode(entry, ctx)
    if not T.db.opts.inkEffects or entry.finished then return nil end
    local level = P.fire and P.fire.keys[entry.progKey]
    if level == "sure" then return "fire" end           -- known to drop it: full flames
    if level then return "smoulder" end                 -- only the names suggest it: a smoulder
    if T.IsInHuntGrounds(entry, ctx) then return "glow" end
    return nil
end

-- Mobs you've looted this item from (most often first), with how many of their corpses you looted
function T.GetKnownDroppers(progKey)
    local list = {}
    for _, d in pairs(T.K.droppers) do
        if type(d) == "table" and type(d[progKey]) == "number" and d.label then
            local tries = (d.tries and d.tries[progKey]) or d.loots or 0
            table.insert(list, { name = d.label, n = d[progKey], loots = math.max(tries, d[progKey]) })
        end
    end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    return list
end

function T.AddHuntTooltipLines(tt, entry)
    local level = P.fire and P.fire.keys[entry.progKey]
    if level == "sure" and not entry.finished then
        tt:AddLine("Your target drops this!", 1.0, 0.50, 0.10)
    elseif level and not entry.finished then
        tt:AddLine("Your target might drop this (going by its name)", 1.0, 0.65, 0.30)
    elseif not entry.finished and T.IsInHuntGrounds(entry, T.BuildHuntContext()) then
        tt:AddLine("You're in its hunting grounds", 1.0, 0.85, 0.35)
    end
    local spots = T.K.spots[entry.progKey]
    if spots and #spots > 0 then
        tt:AddLine(string.format("Found it in %d spot%s so far", #spots, (#spots == 1) and "" or "s"), 0.80, 0.72, 0.50)
    end
    local droppers = T.GetKnownDroppers(entry.progKey)
    if #droppers > 0 then
        local names = {}
        for i = 1, math.min(3, #droppers) do
            local dr = droppers[i]
            names[i] = string.format("%s (%d of %d)", dr.name, dr.n, dr.loots)
        end
        tt:AddLine("Looted from: " .. table.concat(names, ", "), 0.80, 0.72, 0.50, true)
    end
end

-- Loot knowledge is shared by all your characters, so each item remembers whose quest log it's in
-- (owners). A character's quest leaving its log removes that character; an item with no owners left
-- is forgotten. If the quest was turned in (not abandoned), it's kept for P.KEEP_DONE_DAYS so an
-- alt picking the same quest up still finds the spots and droppers.
-- EDIT: days an item's knowledge is kept after the last of your characters turned its quest in
P.KEEP_DONE_DAYS = 30

-- Every item objective in this character's log belongs to this character
function T.MarkOwners()
    if not T.scanned then return end
    local me = T.CharKey()
    for _, q in pairs(T.quests) do
        for _, o in ipairs(q.itemObjectives or {}) do
            local own = T.K.owners[o.progKey]
            if not own then own = {}; T.K.owners[o.progKey] = own end
            own[me] = true
            T.K.kept[o.progKey] = nil
        end
    end
end

function T.QuestIDOf(progKey)
    return tonumber(string.match(tostring(progKey), "^(%d+)_"))
end

-- Forget spots and droppers for quests that have left the log (of every character that had them)
function T.PruneHuntData()
    if not T.scanned then return end           -- quest log not read yet: keep everything
    local me = T.CharKey()
    local live = {}
    for _, q in pairs(T.quests) do
        for _, o in ipairs(q.itemObjectives or {}) do live[o.progKey] = true end
    end
    T.MarkOwners()
    local now = (time and time()) or 0
    for pk, own in pairs(T.K.owners) do
        if own[me] and not live[pk] then
            own[me] = nil
            local qID = T.QuestIDOf(pk)
            if qID and T.Call(C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted, qID) == true then
                T.K.kept[pk] = T.K.kept[pk] or now
            end
        end
        if not next(own) then T.K.owners[pk] = nil end
    end
    local function Alive(progKey)
        if live[progKey] or T.K.owners[progKey] then return true end
        local keptAt = T.K.kept[progKey]
        if keptAt and (now - keptAt) < P.KEEP_DONE_DAYS * 86400 then return true end
        T.K.kept[progKey] = nil
        return false
    end
    for k in pairs(T.K.kept) do Alive(k) end
    for k in pairs(T.K.spots) do
        if not Alive(k) then T.K.spots[k] = nil end
    end
    for mob, d in pairs(T.K.droppers) do
        local keep = false
        if type(d) == "table" then
            for k, v in pairs(d) do
                if type(v) == "number" and string.find(tostring(k), "^%d+_%d+$") then   -- per-item hit counts only
                    if Alive(k) then keep = true else d[k] = nil end
                end
            end
            for k in pairs(d.tries or {}) do
                if Alive(k) then keep = true else d.tries[k] = nil end
            end
        end
        if not keep then T.K.droppers[mob] = nil end
    end
end

-- ----------------------------------------------------------------------------
-- CLICKING AN ITEM: track its quest exactly like clicking the quest's icon in the Objective Tracker
-- (super-track it; click again to stop). Blizzard then draws its own shaded quest area on the map
-- and its waypoint arrow, as for any super-tracked quest.
-- ----------------------------------------------------------------------------
function T.ToggleSuperTrack(questID)
    if not questID then return end
    local ST = C_SuperTrack
    if not (ST and ST.SetSuperTrackedQuestID) then return end
    if P.GetSuperTrackedID() == questID then
        pcall(ST.SetSuperTrackedQuestID, 0)
        if PlaySound and SOUNDKIT and SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_OFF then
            pcall(PlaySound, SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_OFF)
        end
    else
        pcall(ST.SetSuperTrackedQuestID, questID)
        if PlaySound and SOUNDKIT and SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_ON then
            pcall(PlaySound, SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_ON)
        end
    end
    -- SUPER_TRACKING_CHANGED redraws too; this makes the red circle appear without waiting for it
    if T.frame and T.frame:IsShown() then P.Render(T.frame) end
end

-- The map an item is gathered on: where you've looted it most, else the quest's zone, else yours
function T.GetHuntMapID(focus)
    if not focus then return nil end
    local votes, best, bestN = {}, nil, 0
    for _, sp in ipairs(T.K.spots[focus.progKey] or {}) do
        votes[sp.m] = (votes[sp.m] or 0) + (sp.n or 1)
        if votes[sp.m] > bestN then best, bestN = sp.m, votes[sp.m] end
    end
    if best then return best end
    local q = T.quests[focus.questID]
    if q and q.mapID then return q.mapID end
    return C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
end

-- A circled patch of map on the hover preview: a dashed ink ring and a small pip in the middle
-- (no fill, so the map art underneath stays visible)
function P.AcquireHuntCircle(ov, i)
    local c = ov.circles[i]
    if c then return c end
    c = CreateFrame("Frame", nil, ov)
    c.dashes = {}
    for k = 1, 20 do c.dashes[k] = c:CreateLine(nil, "OVERLAY") end
    c.pip = c:CreateTexture(nil, "OVERLAY")
    c.pip:SetTexture(CIRCLE_MASK_TEX)
    c.pip:SetPoint("CENTER")
    ov.circles[i] = c
    return c
end

function P.PlaceHuntCircle(c, canvas, x, y, radiusPx, kind)
    local W, H = canvas:GetWidth() or 0, canvas:GetHeight() or 0
    c:ClearAllPoints()
    c:SetSize(radiusPx * 2, radiusPx * 2)
    c:SetPoint("CENTER", canvas, "TOPLEFT", x * W, -y * H)
    -- spots you looted in: amber. The quest's objective area: the tally's red ink.
    local r, g, b = 1.0, 0.62, 0.10
    if kind == "poi" then r, g, b = 0.90, 0.18, 0.08 end
    local n = #c.dashes
    local thick = math.max(1.5, radiusPx * 0.035)
    for k, ln in ipairs(c.dashes) do
        local a0 = (k - 1) / n * 2 * math.pi
        local a1 = a0 + (2 * math.pi / n) * 0.55
        ln:SetStartPoint("CENTER", c, math.cos(a0) * radiusPx, math.sin(a0) * radiusPx)
        ln:SetEndPoint("CENTER", c, math.cos(a1) * radiusPx, math.sin(a1) * radiusPx)
        ln:SetThickness(thick)
        ln:SetColorTexture(r, g, b, 0.90)
        ln:Show()
    end
    local pip = math.max(4, radiusPx * 0.12)
    c.pip:SetSize(pip, pip)
    c.pip:SetVertexColor(r, g, b, 0.95)
    c:Show()
end

-- Where an item is gathered, on one map: looted-here spots (amber) + the quest's objective area (red)
function T.CollectHuntMarks(questID, progKey, mapID)
    local marks = {}
    for _, sp in ipairs(T.K.spots[progKey] or {}) do
        local x, y = P.TranslatePos(sp.m, sp.x, sp.y, mapID)
        if x then table.insert(marks, { x = x, y = y, r = P.HUNT_SPOT_RADIUS, kind = "spot", n = sp.n or 1 }) end
    end
    local poiX, poiY
    if C_QuestLog and C_QuestLog.GetQuestsOnMap then
        local ok, list = pcall(C_QuestLog.GetQuestsOnMap, mapID)
        if ok and type(list) == "table" then
            for _, info in ipairs(list) do
                if info.questID == questID and info.x and info.y then poiX, poiY = info.x, info.y end
            end
        end
    end
    if not poiX then
        local q = T.quests[questID]
        if q and q.mapID and not q.isComplete then poiX, poiY = P.TranslatePos(q.mapID, q.x, q.y, mapID) end
    end
    if poiX then table.insert(marks, { x = poiX, y = poiY, r = P.HUNT_POI_RADIUS, kind = "poi", n = 0 }) end
    return marks
end

-- ----------------------------------------------------------------------------
-- MAP PREVIEW ON HOVER
-- A little map under the item's tooltip: the zone's own map art, cropped around where the item is
-- gathered, with the quest's objective area, your looted-here spots and where you are now.
-- It is a separate frame, so it never draws on (or covers anything on) the real world map.
-- ----------------------------------------------------------------------------
-- EDIT: size of the map area in pixels (keep roughly 3:2, the shape of zone maps)
P.PREVIEW_W, P.PREVIEW_H = 220, 147

function T.EnsureMapPreview()
    if T.mapPreview then return T.mapPreview end
    local pv = CreateFrame("Frame", "CRQ_TallyMapPreview", UIParent)
    pv:SetSize(P.PREVIEW_W + 8, P.PREVIEW_H + 24)
    pv:SetFrameStrata("TOOLTIP")
    pv:SetClampedToScreen(true)
    if pv.EnableMouse then pv:EnableMouse(false) end
    local border = pv:CreateTexture(nil, "BACKGROUND", nil, 0)
    border:SetAllPoints()
    border:SetColorTexture(0.62, 0.62, 0.66, 0.95)
    local bg = pv:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    bg:SetColorTexture(0.03, 0.03, 0.05, 0.96)
    pv.title = pv:CreateFontString(nil, "OVERLAY")
    pv.title:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 11, "")
    pv.title:SetPoint("TOPLEFT", pv, "TOPLEFT", 6, -5)
    pv.title:SetPoint("RIGHT", pv, "RIGHT", -6, 0)
    pv.title:SetJustifyH("LEFT")
    pv.title:SetWordWrap(false)

    -- clipping viewport onto the (larger) map
    local sf = CreateFrame("ScrollFrame", nil, pv)
    sf:SetPoint("TOPLEFT", pv, "TOPLEFT", 4, -20)
    sf:SetSize(P.PREVIEW_W, P.PREVIEW_H)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(P.PREVIEW_W, P.PREVIEW_H)
    sf:SetScrollChild(child)
    child.circles = {}
    pv.sf, pv.child = sf, child
    pv.tiles = {}
    -- fallback when the client gives no map art: a plain parchment sketch
    pv.paper = child:CreateTexture(nil, "BACKGROUND", nil, -1)
    pv.paper:SetAllPoints(child)
    pv.paper:SetColorTexture(0.80, 0.72, 0.54, 1)

    -- Blizzard's own quest-area shape, drawn only inside this preview
    local ok, blob = pcall(CreateFrame, "QuestPOIFrame", nil, child)
    if ok and type(blob) == "table" and type(blob.DrawBlob) == "function" then
        blob:SetAllPoints(child)
        pcall(blob.SetFillTexture, blob, "Interface\\WorldMap\\UI-QuestBlob-Inside")
        pcall(blob.SetBorderTexture, blob, "Interface\\WorldMap\\UI-QuestBlob-Outside")
        pcall(blob.SetFillAlpha, blob, 128)
        pcall(blob.SetBorderAlpha, blob, 220)
        pcall(blob.SetBorderScalar, blob, 0.5)
        pv.blob = blob
    end

    -- you are here
    local you = CreateFrame("Frame", nil, child)
    you:SetSize(9, 9)
    you:SetFrameLevel(child:GetFrameLevel() + 20)
    you.ring = you:CreateTexture(nil, "ARTWORK", nil, 0)
    you.ring:SetTexture(CIRCLE_MASK_TEX)
    you.ring:SetAllPoints()
    you.ring:SetVertexColor(0, 0, 0, 0.9)
    you.dot = you:CreateTexture(nil, "ARTWORK", nil, 1)
    you.dot:SetTexture(CIRCLE_MASK_TEX)
    you.dot:SetPoint("TOPLEFT", 1.5, -1.5)
    you.dot:SetPoint("BOTTOMRIGHT", -1.5, 1.5)
    you.dot:SetVertexColor(1.0, 0.92, 0.25, 1)
    pv.you = you

    pv.note = pv:CreateFontString(nil, "OVERLAY")
    pv.note:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    pv.note:SetPoint("BOTTOM", sf, "BOTTOM", 0, 4)
    pv.note:SetTextColor(1.0, 0.75, 0.45)
    pv:Hide()
    T.mapPreview = pv
    return pv
end

-- Map art for one map: layer size, tile size and the tile files (nil if the client has none)
function P.GetMapArt(mapID)
    if not (C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures) then return nil end
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    local layer = ok and type(layers) == "table" and layers[1]
    if not (layer and layer.layerWidth and layer.tileWidth) then return nil end
    local ok2, files = pcall(C_Map.GetMapArtLayerTextures, mapID, 1)
    if not (ok2 and type(files) == "table" and #files > 0) then return nil end
    return { w = layer.layerWidth, h = layer.layerHeight, tw = layer.tileWidth, th = layer.tileHeight, files = files }
end

function T.ShowMapPreview(entry, anchor)
    if not T.db.opts.mapPreview or not entry then return end
    local mapID = T.GetHuntMapID({ questID = entry.questID, progKey = entry.progKey })
    local pv = T.EnsureMapPreview()
    if not mapID then
        pv:Hide()
        return
    end
    local PW, PH = P.PREVIEW_W, P.PREVIEW_H
    local art = P.GetMapArt(mapID)
    local LW, LH = art and art.w or 1002, art and art.h or 668
    local marks = T.CollectHuntMarks(entry.questID, entry.progKey, mapID)

    -- zoom to fit the marks with some margin (never closer than a third of the map, never past its edges)
    -- EDIT: change 0.35 below to zoom the preview in (smaller) or out (bigger)
    local minX, maxX, minY, maxY = 1, 0, 1, 0
    for _, mk in ipairs(marks) do
        minX, maxX = math.min(minX, mk.x - mk.r), math.max(maxX, mk.x + mk.r)
        minY, maxY = math.min(minY, mk.y - mk.r), math.max(maxY, mk.y + mk.r)
    end
    local scaleFit = math.max(PW / LW, PH / LH)            -- the whole map just fills the viewport
    local s = scaleFit
    local cx, cy = 0.5, 0.5
    if #marks > 0 then
        cx, cy = (minX + maxX) * 0.5, (minY + maxY) * 0.5
        local ex = math.max(1, (maxX - minX) * LW * 1.5)
        local ey = math.max(1, (maxY - minY) * LH * 1.5)
        s = math.min(PW / ex, PH / ey, PW / (0.35 * LW))     -- at least a third of the zone across: stays sharp
        s = math.max(s, scaleFit)
    end
    local CW, CH = LW * s, LH * s
    local child = pv.child
    child:SetSize(CW, CH)
    local sx = math.max(0, math.min(CW - PW, cx * CW - PW * 0.5))
    local sy = math.max(0, math.min(CH - PH, cy * CH - PH * 0.5))
    pv.sf:SetHorizontalScroll(sx)
    pv.sf:SetVerticalScroll(sy)

    -- map tiles
    local nTiles = 0
    if art then
        local cols = math.max(1, math.ceil(art.w / art.tw))
        for i, fid in ipairs(art.files) do
            local t = pv.tiles[i]
            if not t then
                t = child:CreateTexture(nil, "BACKGROUND", nil, 0)
                pv.tiles[i] = t
            end
            local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
            t:SetTexture(fid)
            t:ClearAllPoints()
            t:SetSize(art.tw * s, art.th * s)
            t:SetPoint("TOPLEFT", child, "TOPLEFT", col * art.tw * s, -row * art.th * s)
            t:Show()
            nTiles = i
        end
    end
    for i = nTiles + 1, #pv.tiles do pv.tiles[i]:Hide() end
    pv.paper:SetShown(nTiles == 0)

    -- the quest's own area outline, then the tally's rings on top
    if pv.blob then
        pcall(pv.blob.SetMapID, pv.blob, mapID)
        pcall(pv.blob.DrawNone, pv.blob)
        pcall(pv.blob.DrawBlob, pv.blob, entry.questID, true)
    end
    for i, mk in ipairs(marks) do
        local c = P.AcquireHuntCircle(child, i)
        c:SetFrameLevel(child:GetFrameLevel() + 10)          -- rings over the quest-area shape
        P.PlaceHuntCircle(c, child, mk.x, mk.y, mk.r * CW, mk.kind)
    end
    for i = #marks + 1, #child.circles do child.circles[i]:Hide() end

    local pMap, px, py = T.PlayerPos()
    local yx, yy
    if pMap and px and py then yx, yy = P.TranslatePos(pMap, px, py, mapID) end
    if yx then
        pv.you:ClearAllPoints()
        pv.you:SetPoint("CENTER", child, "TOPLEFT", yx * CW, -yy * CH)
        pv.you:Show()
    else
        pv.you:Hide()
    end

    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    pv.title:SetText("|cFFFFD100" .. ((info and info.name) or "Map") .. "|r  |cFFCCCCCC" .. (entry.itemName or "") .. "|r")
    pv.note:SetText((#marks == 0) and "no known spot yet: loot one and it's marked" or "")

    P.PlacePreview(pv, anchor or GameTooltip)
    pv:Show()
end

function T.HideMapPreview()
    if T.mapPreview then T.mapPreview:Hide() end
end

-- ----------------------------------------------------------------------------
-- KEEPING POP-UPS CLEAR: the item tooltip goes beside the tally on whichever side has room, and
-- the map preview tries a ring of spots round the tooltip and the tally and takes the one that
-- stays on screen and covers the least: the tally and tooltip first, then other visible windows.
-- ----------------------------------------------------------------------------
function P.GetSuperTrackedID()
    if C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID then
        local ok, id = pcall(C_SuperTrack.GetSuperTrackedQuestID)
        if ok then return (id and id > 0) and id or nil end
    end
    return nil
end

-- A visible frame's rectangle in UIParent units, grown by pad (nil if hidden / not laid out)
function P.ScreenRect(frame, pad)
    if type(frame) ~= "table" or not (frame.IsVisible and frame:IsVisible()) or not frame.GetRect then return nil end
    local l, b, w, h = frame:GetRect()
    if not (l and b and w and h) or w <= 0 or h <= 0 then return nil end
    local k = (frame:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    pad = pad or 0
    return { l = l * k - pad, b = b * k - pad, r = (l + w) * k + pad, t = (b + h) * k + pad }
end

function P.Overlap(a, b)
    if not (a and b) then return 0 end
    local w = math.min(a.r, b.r) - math.max(a.l, b.l)
    local h = math.min(a.t, b.t) - math.max(a.b, b.b)
    if w <= 0 or h <= 0 then return 0 end
    return w * h
end

-- Windows and HUD pieces a pop-up shouldn't sit on (whichever exist and are showing).
-- EDIT: add another addon's frame by its global name (type /fstack in game to find it).
P.AVOID_FRAMES = {
    "ObjectiveTrackerFrame", "MinimapCluster", "PlayerFrame", "TargetFrame", "FocusFrame", "BuffFrame",
    "DebuffFrame", "MainMenuBar", "MainActionBar", "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBarRight",
    "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7", "MicroMenuContainer", "MicroButtonAndBagsBar",
    "BagsBar", "StanceBar", "PetActionBar", "PartyFrame", "CompactRaidFrameContainer", "WorldMapFrame",
    "QuestFrame", "GossipFrame", "CharacterFrame", "SpellBookFrame", "PlayerSpellsFrame", "MerchantFrame",
    "ContainerFrameCombinedBags", "SettingsPanel", "DressUpFrame", "MailFrame", "EncounterJournal", "PVEFrame",
    "CollectionsJournal", "AchievementFrame", "ProfessionsFrame", "CommunitiesFrame", "GameMenuFrame", "EditModeManagerFrame",
}

function P.CollectAvoidRects()
    local list, seen = {}, {}
    local function Add(name)
        if seen[name] then return end
        seen[name] = true
        local r = P.ScreenRect(_G[name], 2)
        if r then table.insert(list, r) end
    end
    for _, name in ipairs(P.AVOID_FRAMES) do Add(name) end
    for i = 1, (tonumber(NUM_CHAT_WINDOWS) or 10) do Add("ChatFrame" .. i) end
    for i = 1, 13 do Add("ContainerFrame" .. i) end
    for _, name in ipairs(UISpecialFrames or {}) do
        if type(name) == "string" then Add(name) end
    end
    return list
end

-- The tally's footprint, including the pages fanned out underneath
function P.TallyRect()
    return P.ScreenRect(T.frame, 12)
end

-- Item tooltip beside the tally, on the side with more room, level with the row
function P.PlaceTooltip(row)
    local F = P.TallyRect()
    if not F then
        GameTooltip:SetOwner(row, "ANCHOR_LEFT")
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    local screenW = UIParent:GetWidth() or 1920
    local rowRight = (row.GetRight and row:GetRight()) or F.r
    local rowLeft = (row.GetLeft and row:GetLeft()) or F.l
    if (screenW - F.r) >= F.l then
        GameTooltip:SetPoint("TOPLEFT", row, "TOPRIGHT", (F.r - rowRight) + 4, 4)
    else
        GameTooltip:SetPoint("TOPRIGHT", row, "TOPLEFT", -(rowLeft - F.l) - 4, 4)
    end
end

function P.PlacePreview(pv, tip)
    local W, H = pv:GetWidth() or 228, pv:GetHeight() or 171
    local T = P.ScreenRect(tip, 0)
    local F = P.TallyRect()
    pv:ClearAllPoints()
    if not T and not F then
        -- nothing to measure against yet: plain under-the-tooltip spot
        pv:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", 0, -2)
        return
    end
    local SW, SH = UIParent:GetWidth() or 1920, UIParent:GetHeight() or 1080
    local others = P.CollectAvoidRects()
    local cands = {}
    local function Add(x, y) table.insert(cands, { x = x, y = y }) end
    local g = 3
    if T then
        Add(T.l, T.b - g - H)               -- under the tooltip
        Add(T.r - W, T.b - g - H)
        Add(T.l, T.t + g)                   -- over it
        Add(T.r - W, T.t + g)
        Add(T.r + g, T.t - H)               -- beside it
        Add(T.l - g - W, T.t - H)
    end
    if F then
        Add(F.r + g, F.t - H)               -- beside the tally
        Add(F.l - g - W, F.t - H)
        Add(F.r + g, F.b)
        Add(F.l - g - W, F.b)
        Add(F.l, F.t + g)                   -- over / under it
        Add(F.r - W, F.t + g)
        Add(F.l, F.b - g - H)
    end
    local best, bestScore
    local cx = T and (T.l + T.r) * 0.5 or (F.l + F.r) * 0.5
    local cy = T and (T.b + T.t) * 0.5 or (F.b + F.t) * 0.5
    for _, c in ipairs(cands) do
        -- keep it fully on screen
        local x = math.max(0, math.min(SW - W, c.x))
        local y = math.max(0, math.min(SH - H, c.y))
        local R = { l = x, b = y, r = x + W, t = y + H }
        local score = 50 * (P.Overlap(R, F) + P.Overlap(R, T))
        for _, o in ipairs(others) do score = score + P.Overlap(R, o) end
        local dx, dy = (x + W * 0.5) - cx, (y + H * 0.5) - cy
        score = score + 0.05 * math.sqrt(dx * dx + dy * dy)          -- prefer close by
        if not bestScore or score < bestScore then best, bestScore = { x = x, y = y }, score end
    end
    pv:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", best.x, best.y)
end

-- ----------------------------------------------------------------------------
-- MINIMAP PINS: amber pips where you've looted the items of the quest you're tracking.
-- Blizzard already shows the tracked quest's own area / arrow; these add the spots you've
-- actually found the items. Positions come from world coordinates, scaled by the minimap's
-- zoom (the standard yards-across-the-minimap per zoom level), and turned
-- with the player when "Rotate Minimap" is on. Out-of-range spots sit on the rim.
-- ----------------------------------------------------------------------------
P.MINIMAP_YARDS = {
    indoor = { [0] = 300, 240, 180, 120, 80, 50 },
    outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
}
P.MAX_MINIMAP_PINS = 8      -- EDIT: most pins shown at once (nearest first)

function P.AcquireMinimapPin(i)
    P.mmPins = P.mmPins or {}
    local pin = P.mmPins[i]
    if pin then return pin end
    pin = CreateFrame("Frame", nil, Minimap)
    pin:SetSize(10, 10)
    pin:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 6)
    pin.ring = pin:CreateTexture(nil, "ARTWORK", nil, 0)
    pin.ring:SetTexture(CIRCLE_MASK_TEX)
    pin.ring:SetAllPoints()
    pin.ring:SetVertexColor(0.25, 0.12, 0.02, 0.95)
    pin.dot = pin:CreateTexture(nil, "ARTWORK", nil, 1)
    pin.dot:SetTexture(CIRCLE_MASK_TEX)
    pin.dot:SetPoint("TOPLEFT", 2, -2)
    pin.dot:SetPoint("BOTTOMRIGHT", -2, 2)
    pin.dot:SetVertexColor(1.0, 0.66, 0.12, 1)
    pin:EnableMouse(true)
    pin:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.itemName or "Quest item", 1.0, 0.82, 0)
        GameTooltip:AddLine("You've found it here" .. ((self.n or 1) > 1 and string.format(" (%d times)", self.n) or ""), 0.9, 0.9, 0.9)
        if self.questTitle then GameTooltip:AddLine(self.questTitle, 0.65, 0.65, 0.65) end
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    P.mmPins[i] = pin
    return pin
end

function T.UpdateMinimapPins()
    local shown = 0
    local mm = Minimap
    local qID = P.GetSuperTrackedID()
    local q = qID and T.quests[qID]
    if mm and q and T.db.opts.minimapPins and mm.IsVisible and mm:IsVisible() then
        local pMap, px, py = T.PlayerPos()
        local pc, pwx, pwy
        if pMap and px and py then pc, pwx, pwy = T.MapPosToWorld(pMap, px, py) end
        if pc then
            local rawZoom = mm.GetZoom and mm:GetZoom()
            local zoom = tonumber(rawZoom) or 0
            local sizes = (IsIndoors and IsIndoors()) and P.MINIMAP_YARDS.indoor or P.MINIMAP_YARDS.outdoor
            local yardsAcross = sizes[zoom] or sizes[0]
            local R = (mm:GetWidth() or 140) * 0.5
            local pxPerYard = R / (yardsAcross * 0.5)
            local facing = 0
            if GetCVar and GetCVar("rotateMinimap") == "1" then
                local fc = T.Call(GetPlayerFacing)                  -- nil (or secret) inside instances
                facing = (type(fc) == "number") and fc or 0
            end
            local cosF, sinF = math.cos(facing), math.sin(facing)

            -- nearest spots first, across every unfinished item of the tracked quest
            local spots = {}
            for _, obj in ipairs(q.itemObjectives or {}) do
                if not obj.finished then
                    for _, sp in ipairs(T.K.spots[obj.progKey] or {}) do
                        local c, wx, wy = T.MapPosToWorld(sp.m, sp.x, sp.y)
                        if c and c == pc then
                            -- world X runs north, world Y runs west
                            local east, north = -(wy - pwy), (wx - pwx)
                            table.insert(spots, { east = east, north = north, d = east * east + north * north,
                                item = obj.itemName, n = sp.n })
                        end
                    end
                end
            end
            table.sort(spots, function(a, b) return a.d < b.d end)
            for _, s in ipairs(spots) do
                if shown >= P.MAX_MINIMAP_PINS then break end
                local x = (s.east * cosF + s.north * sinF) * pxPerYard
                local y = (-s.east * sinF + s.north * cosF) * pxPerYard
                local dist = math.sqrt(x * x + y * y)
                local edge = R - 6
                local onRim = dist > edge
                if onRim and dist > 0 then x, y = x / dist * edge, y / dist * edge end
                shown = shown + 1
                local pin = P.AcquireMinimapPin(shown)
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", mm, "CENTER", x, y)
                pin:SetAlpha(onRim and 0.55 or 1)
                pin.itemName, pin.n, pin.questTitle = s.item, s.n, q.title
                pin:Show()
            end
        end
    end
    for i = shown + 1, #(P.mmPins or {}) do P.mmPins[i]:Hide() end
end

-- moves with you: refreshed a few times a second while a tracked quest has known spots
function T.EnsureMinimapDriver()
    if T.mmDriver or not Minimap then return end
    local drv = CreateFrame("Frame", nil, Minimap)
    drv.acc = 0
    drv:SetScript("OnUpdate", function(self, elapsed)
        self.acc = self.acc + (elapsed or 0)
        if self.acc < 0.1 then return end
        self.acc = 0
        local ok, err = pcall(T.UpdateMinimapPins)
        if not ok then
            T.ReportError(err)
            self:SetScript("OnUpdate", nil)     -- stop after an error instead of repeating it every frame
        end
    end)
    T.mmDriver = drv
end


-- ============================================================================
-- OPTIONS (Options > AddOns > Cache ReQuest, the gear on the tally, or /crq)
-- ============================================================================
function T.RefreshOptionsPanel()
    for _, w in ipairs(T.optionWidgets) do
        if w.Refresh then w:Refresh() end
    end
end

function T.BuildOptionsPanel()
    if T.optionsPanel then return T.optionsPanel end

    local p = CreateFrame("Frame", "CRQ_OptionsPanel")
    p.name = DISPLAY_NAME
    p:Hide()
    local y = -16

    local title = p:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", p, "TOPLEFT", 16, y)
    local version = (C_AddOns and C_AddOns.GetAddOnMetadata and T.Call(C_AddOns.GetAddOnMetadata, ADDON_NAME, "Version")) or ""
    title:SetText(DISPLAY_NAME .. ((version ~= "") and (" |cFF888888v" .. version .. "|r") or ""))
    y = y - 22
    local sub = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", p, "TOPLEFT", 16, y)
    sub:SetText("The Field Tally: a handwritten note of the quest items you still have to collect.")
    y = y - 26

    local function Section(text)
        local fs = p:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        fs:SetPoint("TOPLEFT", p, "TOPLEFT", 16, y)
        fs:SetText(text)
        local line = p:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
        line:SetPoint("RIGHT", p, "RIGHT", -24, 0)
        line:SetColorTexture(0.6, 0.5, 0.2, 0.5)
        y = y - 22
    end

    local function Tip(owner, head, body, extra)
        owner:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(head, 1, 0.82, 0)
            if body then GameTooltip:AddLine(body, 0.9, 0.9, 0.9, true) end
            local e = extra and extra()
            if e and e ~= "" then GameTooltip:AddLine(e, 0.55, 0.85, 0.55, true) end
            GameTooltip:Show()
        end)
        owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local function Check(label, tip, getFn, setFn, indent)
        local cb = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", p, "TOPLEFT", indent or 20, y)
        cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 1)
        cb.label:SetText(label)
        cb:SetScript("OnClick", function(self)
            setFn(self:GetChecked() and true or false)
            T.Save()
            T.RefreshOptionsPanel()
        end)
        if tip then Tip(cb, label, tip) end
        cb.Refresh = function(self) self:SetChecked(getFn() and true or false) end
        table.insert(T.optionWidgets, cb)
        y = y - 26
        return cb
    end

    local function Button(label, width, x, onClick, refreshFn)
        local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        b:SetSize(width, 22)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", x, y)
        b:SetText(label)
        b:SetScript("OnClick", function(self)
            onClick(self)
            T.RefreshOptionsPanel()
        end)
        if refreshFn then
            b.Refresh = refreshFn
            table.insert(T.optionWidgets, b)
        end
        return b
    end

    -- 1-50% slider row: label, slider, value, hint. get() returns the value; set(v) applies it.
    local function RadiusSlider(labelText, tipBody, get, set, hintFn, enabledFn)
        local row = CreateFrame("Frame", nil, p)
        row:SetSize(440, 26)
        row:SetPoint("TOPLEFT", p, "TOPLEFT", 48, y)
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", row, "LEFT", 0, 0)
        label:SetText(labelText)
        local slider = CreateFrame("Slider", nil, row)
        slider:SetOrientation("HORIZONTAL")
        slider:SetSize(170, 16)
        slider:SetPoint("LEFT", row, "LEFT", 120, 0)
        slider:SetMinMaxValues(1, 50)
        slider:SetValueStep(1)
        if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
        slider:EnableMouseWheel(true)
        local track = slider:CreateTexture(nil, "BACKGROUND")
        track:SetHeight(6)
        track:SetPoint("LEFT", slider, "LEFT", 0, 0)
        track:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
        track:SetColorTexture(0.08, 0.08, 0.08, 0.9)
        local fill = slider:CreateTexture(nil, "ARTWORK")
        fill:SetHeight(4)
        fill:SetPoint("LEFT", slider, "LEFT", 1, 0)
        fill:SetColorTexture(1.0, 0.82, 0.0, 0.85)
        local thumb = slider:CreateTexture(nil, "OVERLAY")
        thumb:SetSize(18, 18)
        thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        slider:SetThumbTexture(thumb)
        local valText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        valText:SetPoint("LEFT", slider, "RIGHT", 10, 0)
        local hint = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("LEFT", valText, "RIGHT", 8, 0)

        local function Show(v)
            fill:SetWidth(math.max(1, (v - 1) / 49 * 168))
            valText:SetText(v .. "%")
        end
        local function Enabled() return not enabledFn or enabledFn() end
        slider:SetScript("OnValueChanged", function(self, val)
            local v = math.floor((val or 10) + 0.5)
            Show(v)
            if self.updating then return end
            if not Enabled() then self.updating = true; self:SetValue(get()); self.updating = false; return end
            if v ~= get() then set(v) end
        end)
        slider:SetScript("OnMouseWheel", function(self, delta)
            self:SetValue((self:GetValue() or get()) + delta)
        end)
        Tip(slider, labelText, tipBody, hintFn)
        row.Refresh = function()
            local v = get()
            slider.updating = true
            slider:SetValue(v)
            slider.updating = false
            Show(v)
            hint:SetText((hintFn and hintFn()) or "")
            row:SetAlpha(Enabled() and 1 or 0.45)
        end
        row.slider = slider
        table.insert(T.optionWidgets, row)
        y = y - 30
        return row
    end

    local function Redraw() T.SafeCall(T.Update) end

    Section("Field Tally")
    Check("Show the Field Tally",
        "The note listing the quest items you still have to collect.",
        function() return T.db.show end,
        function(v) T.db.show = v; Redraw() end)

    y = y - 2
    local lookBtn = Button("Look: Handkerchief notes", 210, 24, function()
        P.CycleStyle(); T.Save(); P.ApplyStyle(); Redraw()
    end, function(self) self:SetText("Look: " .. P.GetStyle().label) end)
    Tip(lookBtn, "Look of the Field Tally",
        "Handkerchief notes: written on a lace-edged handkerchief.\nParchment: a pile of torn parchment pages.\nTransparent window: a see-through panel in the standard font.")
    local fontBtn = Button("Handwriting: Quill script", 200, 244, function()
        P.CycleFontStyle(); T.Save(); Redraw()
    end, function(self)
        self:SetText("Handwriting: " .. P.GetFontStyle().label)
        self:SetAlpha(P.GetStyle().font and 0.45 or 1)     -- the transparent window always uses the UI font
    end)
    Tip(fontBtn, "Handwriting", "Quill script (Morpheus), rough scrawl (Skurri) or plain print. The transparent window always uses the standard font.")
    y = y - 32

    RadiusSlider("Near me distance",
        "Page 1 lists quest items gathered within this distance of where you're standing (as % of the zone map), plus anything you've progressed in the last 3 minutes.",
        function() return P.GetNearRadius() end,
        function(v) T.db.nearRadius = v; T.Save(); Redraw() end)

    Check("Pages for other areas",
        "Each area with items still to gather gets its own page. Click the dog-eared corner to turn to the next page (right-click to go back).",
        function() return T.db.opts.showTabs end,
        function(v) T.db.opts.showTabs = v; Redraw() end)

    local groupBtn = Button("Area pages by: Map areas", 210, 48, function()
        P.CycleGrouping(); T.scroll = 0; T.Save(); Redraw()
    end, function(self)
        self:SetText("Area pages by: " .. P.GetGrouping().label)
        self:SetAlpha(T.db.opts.showTabs and 1 or 0.45)
    end)
    Tip(groupBtn, "Area pages by",
        "Map areas: one page per explored subzone your quest items are in (the names on your world map).\nZones: one page per zone.\nDistance: quests close together share a page, sized by the Area page size slider.",
        function() return "Pages with the same name are always merged." end)
    y = y - 30

    local function DistanceMode() return T.db.opts.showTabs and P.GetGrouping().key == "RADIUS" end
    local followCb = Check("Area page size follows the tracker's (•••) stacking slider",
        "Distance grouping only. On: quests within the radius you use for (•••) stacks in the Objective Tracker share a page. Off: set the page size yourself below.",
        function() return T.db.opts.pagesFollowTracker end,
        function(v) T.db.opts.pagesFollowTracker = v; Redraw() end, 44)
    local baseRefresh = followCb.Refresh
    followCb.Refresh = function(self) baseRefresh(self); self:SetAlpha(DistanceMode() and 1 or 0.45) end

    RadiusSlider("Area page size",
        "Distance grouping only. Quests whose items lie within this distance of each other (as % of the zone map) share a page. Smaller = more, tighter pages.",
        function() return P.GetPageRadius() end,
        function(v) T.db.pageRadius = v; T.Save(); Redraw() end,
        function() return T.db.opts.pagesFollowTracker and "(set by the ••• slider)" or "" end,
        function() return DistanceMode() and not T.db.opts.pagesFollowTracker end)

    Check("Turn back to \"Near me\" when you arrive somewhere new",
        "When you enter a new area, the pile turns back to the Near me page and its heading is written in red ink for a few seconds.",
        function() return T.db.opts.autoFrontOnAreaChange end,
        function(v) T.db.opts.autoFrontOnAreaChange = v end)
    Check("Hide the tally when nothing is nearby",
        "Off: it stays up so you can leaf through other areas. On: it only appears when there's something to gather near you.",
        function() return T.db.opts.hideWhenNothingNearby end,
        function(v) T.db.opts.hideWhenNothingNearby = v; Redraw() end)
    Check("Glowing & burning ink",
        "An item's line glows gold in its hunting grounds, and catches fire while your target is a mob that drops it (a smaller smoulder when that's only a guess from the names).",
        function() return T.db.opts.inkEffects end,
        function(v) T.db.opts.inkEffects = v; Redraw() end)
    Check("Little map when you hover an item",
        "A small map beside the item's tooltip: the quest's area, the spots you've looted it in, and where you are.",
        function() return T.db.opts.mapPreview end,
        function(v) T.db.opts.mapPreview = v; if not v then T.HideMapPreview() end end)
    Check("Mark the tracked quest's item spots on the minimap",
        "Amber dots where you've looted the items of the quest you're super-tracking (click an item on the tally to track its quest). Dots out of range sit on the rim.",
        function() return T.db.opts.minimapPins end,
        function(v) T.db.opts.minimapPins = v; T.SafeCall(T.UpdateMinimapPins) end)
    Check("Show each quest's rewards beside its items",
        "The reward or currency (icon and amount) at the right of an item's line; long item names wrap before reaching it. Rewards matching your reward filter come first. Hover the item for every reward by name.",
        function() return T.db.opts.showRewards end,
        function(v) T.db.opts.showRewards = v; Redraw() end)
    Check("Options gear on the Objective Tracker",
        "A small gear beside the Filter button on the Objective Tracker header that opens these options (right-click it to show or hide the Field Tally).",
        function() return T.db.opts.trackerGear end,
        function(v) T.db.opts.trackerGear = v; T.EnsureTrackerGear(); T.UpdateTrackerGear() end)

    y = y - 6
    Button("Reset Position & Size", 170, 24, function()
        T.db.show = true
        T.ResetShoppingListPosition()
    end)
    y = y - 34

    local hint = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", p, "TOPLEFT", 20, y)
    hint:SetPoint("RIGHT", p, "RIGHT", -24, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Slash: /crq (options), /crq tally, /crq look [handkerchief|parchment|window], /crq reset, /crq debug")

    p:SetScript("OnShow", function() T.RefreshOptionsPanel() end)
    T.optionsPanel = p
    return p
end

function T.RegisterOptions()
    if T.optionsRegistered then return end
    T.optionsRegistered = true
    local p = T.BuildOptionsPanel()
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, p, DISPLAY_NAME)
        if ok and category then
            pcall(Settings.RegisterAddOnCategory, category)
            T.optionsCategory = category
        end
    end
end

-- The Settings panel can't be opened by an addon in combat: it opens once combat ends
function T.OpenOptions()
    T.RegisterOptions()
    if InCombatLockdown() then
        print("|cFFFFD100" .. DISPLAY_NAME .. ":|r options will open after combat.")
        T.afterCombat = T.afterCombat or {}
        T.afterCombat.options = true
        return
    end
    local cat = T.optionsCategory
    if cat and Settings and Settings.OpenToCategory then
        local id = (cat.GetID and cat:GetID()) or cat.ID
        if pcall(Settings.OpenToCategory, id) then return end
    end
    print("|cFFFFD100" .. DISPLAY_NAME .. ":|r open Options > AddOns > " .. DISPLAY_NAME .. ".")
end

-- ----------------------------------------------------------------------------
-- OPTIONS GEAR ON THE OBJECTIVE TRACKER: just left of Cache ReQuest's "Filter" button on the
-- tracker header (or at the header's right if that button isn't there). Not a secure frame, so it
-- can be shown and hidden at any time.
-- ----------------------------------------------------------------------------
function T.EnsureTrackerGear()
    if T.trackerGear then return T.trackerGear end
    local otf = ObjectiveTrackerFrame
    if not otf then return nil end
    local header = otf.Header or otf
    local filterBtn = _G.QRF_TrackerFilterButton
    local btn = CreateFrame("Button", "CRQ_TrackerOptionsButton", header)
    btn:SetSize(16, 16)
    btn:SetFrameLevel((header.GetFrameLevel and header:GetFrameLevel() or 1) + 10)
    if filterBtn then
        btn:SetPoint("RIGHT", filterBtn, "LEFT", -4, 0)
    else
        local minimizeBtn = header.MinimizeButton or otf.MinimizeButton
        if minimizeBtn then btn:SetPoint("RIGHT", minimizeBtn, "LEFT", -6, 0)
        else btn:SetPoint("TOPRIGHT", header, "TOPRIGHT", -28, -4) end
    end
    if not T.ApplyGearIcon(btn, 0.85, 0.75, 0.45, "opt", 9) then btn:SetSize(22, 16) end
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then T.ToggleShown() else T.OpenOptions() end
    end)
    btn:SetScript("OnEnter", function(self)
        T.SetGearHover(self, true)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(DISPLAY_NAME .. " Options", 1, 0.82, 0)
        GameTooltip:AddLine("Left-Click: Field Tally settings", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Right-Click: " .. (T.db.show and "put the Field Tally away" or "bring the Field Tally back"), 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        T.SetGearHover(self, false)
        GameTooltip:Hide()
    end)
    T.trackerGear = btn
    T.UpdateTrackerGear()
    return btn
end

function T.UpdateTrackerGear()
    if T.trackerGear then T.trackerGear:SetShown(T.db.opts.trackerGear ~= false) end
end

-- Right-click on an item: the quest's details in the quest log (after combat if you're fighting)
function T.OpenQuestLog(questID)
    if not questID then return end
    if InCombatLockdown() then
        T.afterCombat = T.afterCombat or {}
        T.afterCombat.questID = questID
        print("|cFFFFD100" .. DISPLAY_NAME .. ":|r the quest log will open after combat.")
        return
    end
    if QuestMapFrame_OpenToQuestDetails then
        T.SafeCall(QuestMapFrame_OpenToQuestDetails, questID)
    end
end

function T.ToggleShown(v)
    if v == nil then v = not T.db.show end
    T.db.show = v
    T.Save()
    T.SafeCall(T.Update)
    T.RefreshOptionsPanel()
end

-- /crq debug: every counted objective, its type, and whether it's on the tally
function T.DebugDump()
    print("|cFFFFD100" .. DISPLAY_NAME .. " Field Tally:|r counted objectives (|cFF40FF40+|r = on the tally)")
    local ids = {}
    for qID in pairs(T.quests) do table.insert(ids, qID) end
    table.sort(ids)
    local n = 0
    for _, qID in ipairs(ids) do
        local q = T.quests[qID]
        for _, o in ipairs(q.quantityObjectives or {}) do
            n = n + 1
            local onTally = o.isItem and T.PassesFilter(qID)
            local why = (o.isItem and not onTally) and "  (hidden by the reward filter)" or ""
            local spots = T.K.spots[o.progKey]
            print(string.format("  %s %s%s: %s  [type=%s] %d/%d%s%s", onTally and "|cFF40FF40+|r" or "|cFF888888-|r",
                q.title or tostring(qID), q.isTask and " (task)" or "", o.itemName or "?", tostring(o.objType or "none"),
                o.numFulfilled or 0, o.numRequired or 0,
                (spots and #spots > 0) and string.format("  (%d looted spots)", #spots) or "", why))
        end
    end
    if n == 0 then print("  (no counted objectives in your quest log)") end
    local mapID, x, y = T.PlayerZonePos()
    print(string.format("  you: map %s at %s  ·  pages: %d  ·  look: %s", tostring(mapID),
        (x and y) and string.format("%.3f, %.3f", x, y) or "?", #P.areas, P.GetStyle().label))
end

SLASH_CACHEREQUEST1 = "/crq"
SLASH_CACHEREQUEST2 = "/cacherequest"
SlashCmdList["CACHEREQUEST"] = function(msg)
    local cmd = string.lower(strtrim(msg or ""))
    if cmd == "tally" or cmd == "list" or cmd == "toggle" then
        T.ToggleShown()
    elseif cmd == "reset" or cmd == "resetpos" then
        T.db.show = true
        T.ResetShoppingListPosition()
        T.RefreshOptionsPanel()
    elseif cmd == "debug" or cmd == "items" then
        T.DebugDump()
    elseif cmd == "look" or cmd == "style" or string.find(cmd, "^look ") or string.find(cmd, "^style ") then
        local want = string.match(cmd, "^%a+%s+(%a+)")
        local alias = { handkerchief = "HANDKERCHIEF", hanky = "HANDKERCHIEF", parchment = "PARCHMENT",
            window = "NATIVE", transparent = "NATIVE", native = "NATIVE" }
        if want and alias[want] then T.db.look = alias[want] else P.CycleStyle() end
        T.Save()
        P.ApplyStyle()
        T.SafeCall(T.Update)
        T.RefreshOptionsPanel()
        print("|cFFFFD100" .. DISPLAY_NAME .. ":|r Field Tally look: " .. P.GetStyle().label)
    else
        T.OpenOptions()
    end
end

-- ============================================================================
-- EVENTS
-- ============================================================================
local loader = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "QUEST_LOG_UPDATE", "UNIT_QUEST_LOG_CHANGED",
    "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "SUPER_TRACKING_CHANGED", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
    "ZONE_CHANGED_NEW_AREA", "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_ENABLED", "LOOT_OPENED" }) do
    loader:RegisterEvent(e)
end

function T.OnEvent(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then T.LoadSaved() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not T.booted then
            T.booted = true
            T.Save()
            EnsureShoppingListFrame()
            T.RegisterOptions()
            T.EnsureMinimapDriver()
            if _G.QRF_TrackerFilterButton then T.SafeCall(T.EnsureTrackerGear) end
            -- Proximity ticker: the tally follows you as you walk (skipped in combat to keep it light;
            -- quest progress, target and loot still redraw it straight away)
            if C_Timer and C_Timer.NewTicker then
                T.ticker = C_Timer.NewTicker(1.2, function()
                    if InCombatLockdown() or not T.db.show then return end
                    T.SafeCall(T.Update)
                end)
            end
            if C_Timer and C_Timer.After then
                -- chat frames settle into their Edit Mode layout a moment after login
                C_Timer.After(1.5, function()
                    if T.db.frame.useDefaultAnchor and T.frame then P.ApplyPosition(T.frame) end
                    T.SafeCall(T.EnsureTrackerGear)     -- after Cache ReQuest has made its Filter button
                end)
                -- once the quest log has settled, forget loot knowledge of quests that have left it
                C_Timer.After(15, function() T.SafeCall(T.PruneHuntData) end)
            end
            if EventRegistry and EventRegistry.RegisterCallback then
                pcall(EventRegistry.RegisterCallback, EventRegistry, "EditMode.Exit", function()
                    if C_Timer and C_Timer.After then
                        C_Timer.After(0.3, function()
                            if T.db.frame.useDefaultAnchor and T.frame then P.ApplyPosition(T.frame) end
                        end)
                    end
                end, T)
            end
        end
        T.RequestScan(0.5)
    elseif event == "PLAYER_LOGOUT" then
        T.Save()
    elseif event == "PLAYER_REGEN_ENABLED" then
        local after = T.afterCombat
        T.afterCombat = nil
        if after and after.options then T.OpenOptions() end
        if after and after.questID then T.OpenQuestLog(after.questID) end
    elseif event == "LOOT_OPENED" then
        T.SafeCall(T.OnLootOpened)
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- targeting a mob named in an item objective puts that quest on "Near me" for a while
        local targetName = T.UnitStr(UnitName, "target")
        if targetName then
            local lowerTarget = string.lower(targetName)
            for qID, q in pairs(T.quests) do
                for _, o in ipairs(q.itemObjectives or {}) do
                    if o.itemName and string.find(string.lower(o.itemName), lowerTarget, 1, true) then
                        T.recent[qID] = GetTime()
                    end
                end
            end
        end
        local hadFire = P.fire ~= nil
        if not T.SafeCall(T.OnTargetChanged) then P.fire = nil end
        if targetName or hadFire or P.fire then T.SafeCall(T.Update) end
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "ZONE_CHANGED_NEW_AREA" then
        if event == "ZONE_CHANGED_NEW_AREA" then T.RequestScan(0.3) end
        T.SafeCall(T.Update)
    elseif event == "SUPER_TRACKING_CHANGED" then
        T.SafeCall(T.Update)
        T.SafeCall(T.UpdateMinimapPins)
    elseif event == "UNIT_QUEST_LOG_CHANGED" then
        if arg1 == "player" then T.RequestScan() end
    else
        -- QUEST_LOG_UPDATE, QUEST_ACCEPTED, QUEST_REMOVED, QUEST_TURNED_IN
        T.RequestScan()
    end
end
loader:SetScript("OnEvent", T.OnEvent)

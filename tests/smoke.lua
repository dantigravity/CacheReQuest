-- Cache ReQuest smoke test (Lua 5.1, WoW's version). Loads the addon files in TOC order against
-- tests/wowmock.lua and drives the Field Tally and the filter menu through their main paths.
--   "C:\Program Files (x86)\Lua\5.1\lua.exe" tests\smoke.lua
-- Must end with "N passed, 0 failed". Catches logic errors and crashes, not visuals.
local here = (arg[0]:match("^(.*)[/\\]") or ".")
dofile(here .. "/wowmock.lua")
local root = arg[1] or (here .. "/..")

local pass, fail = 0, 0
local function check(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. msg) end
end

-- ---------------------------------------------------------------------------
-- Load the files listed in the TOC, sharing one addon namespace like the client does
-- ---------------------------------------------------------------------------
local toc = assert(io.open(root .. "/CacheReQuest.toc", "rb"), "cannot open the TOC"):read("*a")
local files, svAccount, svChar = {}, nil, nil
for line in string.gmatch(toc, "[^\r\n]+") do
    local sv = line:match("^## SavedVariables:%s*(.-)%s*$")
    local svc = line:match("^## SavedVariablesPerCharacter:%s*(.-)%s*$")
    if sv then svAccount = sv elseif svc then svChar = svc
    elseif not line:match("^##") and line:match("%S") then table.insert(files, (line:gsub("%s+$", ""))) end
end
check(files[1] == "CacheReQuest.lua" and files[2] == "FieldTally.lua", "TOC loads CacheReQuest.lua, then FieldTally.lua")
check(svAccount == "CRQ_TallyKnowledge", "TOC declares the account-wide CRQ_TallyKnowledge")
check(svChar == "QRF_SavedState", "TOC keeps the per-character QRF_SavedState")

local ns = {}
for _, name in ipairs(files) do
    local src = assert(io.open(root .. "/" .. name, "rb"), "cannot open " .. name):read("*a")
    local chunk = assert(loadstring(src, name))
    chunk("CacheReQuest", ns)
end
local T = ns.Tally
local P = T and T.P
check(T ~= nil and P ~= nil, "Field Tally loaded into the addon namespace")
check(type(ns.CRQ) == "table" and type(ns.CRQ.GetQuestCoordsSafe) == "function" and type(ns.CRQ.DoesQuestMatchFilter) == "function"
    and ns.CRQ.GetIncompleteRadius() == 16, "CacheReQuest.lua shares its helpers (read-only)")

-- Count the main chunk's top-level locals (Lua allows 200)
local function CountTopLocals(name)
    local n = 0
    for line in io.lines(root .. "/" .. name) do
        local names = line:match("^local%s+function%s+([%w_]+)") or line:match("^local%s+([%w_,%s]+)")
        if names then for _ in names:gmatch("[%w_]+") do n = n + 1 end end
    end
    return n
end
check(CountTopLocals("FieldTally.lua") < 40, "FieldTally.lua keeps its top-level locals low (" .. CountTopLocals("FieldTally.lua") .. ")")

-- Event / frame helpers
local NewRegion, allFrames
do
    local i = 1
    while true do
        local n, v = debug.getupvalue(CreateFrame, i)
        if not n then break end
        if n == "NewRegion" then NewRegion = v end
        i = i + 1
    end
    i = 1
    while true do
        local n, v = debug.getupvalue(NewRegion, i)
        if not n then break end
        if n == "allFrames" then allFrames = v end
        i = i + 1
    end
end
local function Fire(event, ...)
    for _, fr in ipairs(allFrames) do
        if fr.__events and fr.__events[event] and fr.__scripts.OnEvent then fr.__scripts.OnEvent(fr, event, ...) end
    end
end
local function RunTimers()
    for _ = 1, 10 do
        local list = TIMERS or {}
        TIMERS = {}
        if #list == 0 then return end
        for _, t in ipairs(list) do t() end
    end
end
local function Refresh(event) Fire(event or "QUEST_LOG_UPDATE"); RunTimers() end
local function frames(n, dt)
    local f = CRQ_FieldTally
    for _ = 1, n do
        NOW = NOW + (dt or 0.016)
        local s = f:GetScript("OnUpdate")
        if f:IsShown() and s then s(f, dt or 0.016) end
    end
end
local function RowFor(itemName)
    for _, fr in ipairs(allFrames) do
        if fr.__kind == "FontString" and fr.__shown ~= false and type(fr.__text) == "string"
            and fr.__text:find(itemName, 1, true) and fr.__parent and fr.__parent.box and fr.__parent.itemText == fr
            and fr.__parent.__shown then
            return fr.__parent
        end
    end
end
local function ShownTexts()
    local out = {}
    for _, fr in ipairs(allFrames) do
        if fr.__kind == "FontString" and fr.__shown ~= false and type(fr.__text) == "string" and fr.__parent
            and fr.__parent.box and fr.__parent.__shown and fr.__parent.itemText == fr then
            table.insert(out, fr.__text)
        end
    end
    return table.concat(out, "\n")
end
local function NearIDs()
    local ids = {}
    for _, q in ipairs(P.areas[1] and P.areas[1].quests or {}) do ids[q.questID] = true end
    return ids
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
EventRegistry = { RegisterCallback = function(self, ev, fn) EDITMODE_CB = (ev == "EditMode.Exit") and fn or EDITMODE_CB end }
Fire("ADDON_LOADED", "CacheReQuest")
Fire("PLAYER_ENTERING_WORLD")
RunTimers()

local f = CRQ_FieldTally
check(f ~= nil, "tally frame exists")
check(f and f:IsShown(), "tally shown when there are items to collect nearby")
check(type(QRF_SavedState) == "table" and QRF_SavedState.fieldTally == T.db, "settings stored in QRF_SavedState.fieldTally")
check(type(CRQ_TallyKnowledge) == "table" and CRQ_TallyKnowledge.spots == T.K.spots, "loot knowledge stored in CRQ_TallyKnowledge")
check(T.db.opts.tallyLoot and T.db.opts.tallyTasks and not T.db.opts.tallySeparate, "new characters list items and tasks, together")
-- the item tests below were written for an items-only tally; the tasks block near the end switches tasks on
T.db.opts.tallyTasks = false
Refresh("ZONE_CHANGED")

-- 1) Only "collect an item" objectives
check(T.IsCollectItemObjective("item") and not T.IsCollectItemObjective("monster") and not T.IsCollectItemObjective("object")
    and not T.IsCollectItemObjective("event") and not T.IsCollectItemObjective("progressbar") and not T.IsCollectItemObjective(nil),
    "only objective.type == \"item\" goes on the tally")
check(T.ItemName("4/7 Small Spider Leg") == "Small Spider Leg" and T.ItemName("Small Spider Leg: 4/7") == "Small Spider Leg"
    and T.ItemName("Small Spider Leg (4/7)") == "Small Spider Leg", "item name parsed from retail objective text")
local texts = ShownTexts()
check(texts:find("1/7|r  |c%x%x%x%x%x%x%x%xSmall Spider Leg"), "row reads '1/7  Small Spider Leg' with the count in its own ink")
check(not texts:find("slain") and not texts:find("explored") and not texts:find("used") and not texts:find("progress"),
    "kill, explore, use and progress-bar goals are not on the tally")
check(T.quests[102] and #T.quests[102].itemObjectives == 0 and #T.quests[102].quantityObjectives == 4,
    "a kill/explore quest is counted (for /crq debug) but has no tally items")
check(T.quests[105] and T.quests[105].isTask and NearIDs()[105], "an active bonus objective (hidden task quest) is on Near me")
check(T.quests[106] == nil, "a task quest you're not in stays off")
local countHex = P.Hex(P.GetStyle().inkRed)
check(texts:find("|c" .. countHex .. "1/7|r", 1, true), "count written in the look's contrasting ink")

-- 2) Finished rows: tick, strike only across "count  name", separate "(turn in)"
local strokes = {}
local realDraw = P.DrawStroke
P.DrawStroke = function(s, rel, x0, y0, x1, y1, ...)
    table.insert(strokes, { s = s, rel = rel, x0 = x0, x1 = x1 })
    return realDraw(s, rel, x0, y0, x1, y1, ...)
end
Refresh("ZONE_CHANGED")
P.DrawStroke = realDraw
local fangRow
for _, fr in ipairs(allFrames) do
    if fr.__kind == "FontString" and fr.__shown ~= false and fr.__text == "15/15  Gnarlpine Fang"
        and fr.__parent and fr.__parent.itemText == fr then fangRow = fr end
end
check(fangRow ~= nil, "finished row text is just '15/15  Gnarlpine Fang'")
local strike
for _, st in ipairs(strokes) do if st.rel == fangRow then strike = st end end
local textW = 6 * #"15/15  Gnarlpine Fang"
check(strike and strike.x0 == -2 and strike.x1 == textW + 2, "strike spans only the count and name")
local suffixShown = false
for _, fr in ipairs(allFrames) do
    if fr.__kind == "FontString" and fr.__shown ~= false and fr.__text == "(turn in)" then suffixShown = true end
end
check(suffixShown, "'(turn in)' written separately, unstruck")
local tickDrawn = 0
for _, st in ipairs(strokes) do if st.rel and st.rel.tick then tickDrawn = tickDrawn + 1 end end
check(tickDrawn >= 3, "quill tick drawn in the box")
local lines, widths = P.WrapLines(f.measureFS, "3/3  Very Long Ancient Kaldorei Relic Fragment", 100)
local okW = #lines >= 2
for i, ln in ipairs(lines) do if widths[i] ~= math.min(100, 6 * #ln) or 6 * #ln > 100 then okW = false end end
check(okW, "wrapped finished text: one strike per line, each as wide as its words")

-- 3) A row flashes when its count goes up
QUESTS[2].objs[1].numFulfilled = 2; QUESTS[2].objs[1].text = "2/7 Small Spider Leg"
Refresh()
check(T.flashUntil["101_1"] and T.flashUntil["101_1"] > NOW, "count going up flashes the row")
check(T.recent[101] == NOW, "...and marks the quest as just progressed (Near me for 3 minutes)")

-- 4) Pages
check(P.areas[1].title == "Near me" and P.areas[1].subtitle == "Dolanaar", "page 1 is Near me with your subzone")
check(f.titleFS.__text:find("^Near me") and f.titleFS.__text:find("Dolanaar"), "heading: Near me · Dolanaar")
check(NearIDs()[101] and NearIDs()[103], "items gathered beside you are on Near me")
check(not NearIDs()[104], "a Darkshore quest isn't on Near me")
local dark
for _, a in ipairs(P.areas) do if a.title and a.title:find("Darkshore") then dark = a end end
check(dark ~= nil, "Darkshore quest gets an area page (" .. tostring(dark and dark.title) .. ")")
check(f.footerFS.__text:find("of %d+ gathered") and f.footerFS.__text:find("page 1 of " .. #P.areas),
    "footer: 'n of m gathered · page 1 of N' (" .. tostring(f.footerFS.__text) .. ")")
check(f.visibleBackSheets == math.min(#P.areas - 1, 3), "pages peek out underneath, one per other page")
T.db.nearRadius = 1
NOW = NOW + 200                                 -- "progressed in the last 3 minutes" wears off
Refresh("ZONE_CHANGED")
check(not NearIDs()[101], "smaller Near me distance drops items further away")
local on2 = false
for i = 2, #P.areas do for _, q in ipairs(P.areas[i].quests) do if q.questID == 101 then on2 = true end end end
check(on2, "an item that leaves Near me moves onto an area page")

local function Titles()
    local t = {}
    for i = 2, #P.areas do t[#t + 1] = P.areas[i].title end
    table.sort(t)
    return table.concat(t, "|")
end
C_MapExplorationInfo = { GetExploredAreaIDsAtPosition = function(mapID) return { (mapID == 62) and 2 or 1 } end }
C_Map.GetAreaInfo = function(id) return (id == 2) and "Bashal'Aran" or "Dolanaar" end
T.db.grouping = "AREA"; Refresh("ZONE_CHANGED")
check(Titles() == "Bashal'Aran|Dolanaar", "Map areas: pages named by the explored subzone (" .. Titles() .. ")")
T.db.grouping = "ZONE"; Refresh("ZONE_CHANGED")
check(Titles() == "Darkshore|Teldrassil", "Zones: one page per zone (" .. Titles() .. ")")
C_MapExplorationInfo = nil; wipe(P.areaNameCache)
T.db.questAreas[101], T.db.questAreas[104] = "Dolanaar", "Dolanaar"
T.db.grouping = "RADIUS"; Refresh("ZONE_CHANGED")
check(Titles() == "Dolanaar", "Distance: same-named pages merge, never 'Dolanaar II' (" .. Titles() .. ")")
T.db.opts.pagesFollowTracker = true
check(P.GetPageRadius() == 16, "distance pages follow the tracker's (•••) radius")
T.db.opts.pagesFollowTracker = false; T.db.pageRadius = 30
check(P.GetPageRadius() == 30, "own page size when not following the tracker")
T.db.opts.pagesFollowTracker = true
T.db.questAreas[101], T.db.questAreas[104] = nil, nil
T.db.grouping = "AREA"; T.db.nearRadius = 10
Refresh("ZONE_CHANGED")

-- 5) Dog-eared corner turns pages
local corner = f.corner
check(corner and corner:IsShown(), "dog-eared corner shown with several pages")
corner:GetScript("OnEnter")(corner); frames(30)
check(math.abs(corner.size - P.CORNER_HOVER) < 0.01, "hover lifts the corner")
corner:GetScript("OnLeave")(corner); frames(30)
check(math.abs(corner.size - P.CORNER_REST) < 0.01, "leaving lets it fall back")
local nextArea = P.GetNeighborArea(1)
corner:GetScript("OnClick")(corner, "LeftButton")
check(f.shuffle ~= nil, "left-click starts the lift-and-slide page turn")
frames(40)
check(f.shuffle == nil and P.selectedKey == nextArea.key, "next page now on top")
check(f.footerFS.__text:find("page 2 of"), "footer shows page 2")
corner:GetScript("OnClick")(corner, "RightButton"); frames(40)
check(P.selectedKey == P.CURRENT_KEY, "right-click turns back")
for _ = 1, #P.areas do corner:GetScript("OnClick")(corner, "LeftButton"); frames(40) end
check(P.selectedKey == P.CURRENT_KEY, "pages wrap around")
local grip
for _, fr in ipairs(allFrames) do if fr.gripTex and fr.__parent == f.chrome then grip = fr end end
local gpt = grip and grip:GetPoint(1)
check(gpt == "BOTTOMLEFT", "resize grip is bottom-left")
T.scroll = 0
f:GetScript("OnMouseWheel")(f, -1)
check(T.scroll == 1, "mouse wheel scrolls the list")
f:GetScript("OnMouseWheel")(f, 1)

-- 6) New area: red heading, Near me back to the front
if dark then P.SelectArea(dark.key, false) end
SUBZONE = "Ban'ethil Barrow Den"
Refresh("ZONE_CHANGED"); frames(40)
check(P.selectedKey == P.CURRENT_KEY, "entering a new area turns back to Near me")
check(P.currentGlowUntil > NOW, "heading in red ink for a few seconds")
check(P.areas[1].subtitle == "Ban'ethil Barrow Den", "heading follows the new subzone")
T.db.opts.autoFrontOnAreaChange = false
if dark then P.SelectArea(dark.key, false) end
SUBZONE = "Dolanaar"; Refresh("ZONE_CHANGED"); frames(40)
check(P.selectedKey ~= P.CURRENT_KEY, "...unless that option is off")
T.db.opts.autoFrontOnAreaChange = true
P.SelectArea(P.CURRENT_KEY, false); frames(40)

-- 7) Looted spots and droppers (start clean: section 3 already ticked one up where you stood)
T.K.spots["101_1"] = nil
UnitExists = function(u) return u == "target" and TARGET ~= nil end
UnitIsDead = function() return TARGET and TARGET.dead or false end
UnitIsPlayer = function() return false end
UnitCanAttack = function() return TARGET and TARGET.hostile ~= false end
UnitGUID = function(u) if u == "target" then return TARGET and TARGET.guid end end
UnitName = function(u) if u == "player" then return "Tester" end return TARGET and TARGET.name end
GetRealmName = function() return "Realm" end
TARGET = { name = "Gnarlpine Ambusher", guid = "Creature-0-1-2-3-1994-0000ABCD", dead = true }
Fire("LOOT_OPENED")
check(T.lastLootMob and T.lastLootMob.key == "npc:1994", "loot window remembers the dead target's npc id")
QUESTS[2].objs[1].numFulfilled = 3; QUESTS[2].objs[1].text = "3/7 Small Spider Leg"
PX, PY = 0.30, 0.30
Refresh()
local spots = T.K.spots["101_1"]
check(spots and #spots == 1 and spots[1].m == 57 and math.abs(spots[1].x - 0.30) < 1e-6 and spots[1].a == "Dolanaar",
    "item progress records the spot where you looted it")
local d1994 = T.K.droppers["npc:1994"]
check(d1994 and d1994["101_1"] == 1 and d1994.label == "Gnarlpine Ambusher", "...and the mob it came from")
check(T.K.owners["101_1"] and T.K.owners["101_1"]["Tester-Realm"], "loot knowledge knows whose quest log it belongs to")
T.lastLootMob = nil
QUESTS[2].objs[1].numFulfilled = 4; QUESTS[2].objs[1].text = "4/7 Small Spider Leg"
PX, PY = 0.305, 0.30
Refresh()
check(#T.K.spots["101_1"] == 1 and T.K.spots["101_1"][1].n == 2, "a loot next to a known spot merges into it")
GetLootSourceInfo = function() return "GameObject-0-1-2-3-4-5" end
T.OnLootOpened()
check(T.lastLootMob == nil, "a herb or chest (game object) isn't a mob")
GetLootSourceInfo = nil
TARGET = nil

-- 8) Glow in the hunting grounds
SUBZONE = "Starbreeze"; PX, PY = 0.31, 0.30
Refresh("ZONE_CHANGED"); P.SelectArea(P.CURRENT_KEY, false); frames(40)
local spiderRow = RowFor("Small Spider Leg")
check(spiderRow and spiderRow.fxMode == "glow", "line glows in its hunting grounds (" .. tostring(spiderRow and spiderRow.fxMode) .. ")")
frames(5)
check(spiderRow and spiderRow.fx.inner[1].__shown and spiderRow.fx.outer[1].__shown, "glow halo from offset copies of the text")
PX, PY = 0.90, 0.90; SUBZONE = "Rut'theran"
Refresh("ZONE_CHANGED"); frames(40)
spiderRow = RowFor("Small Spider Leg")
check(not spiderRow or spiderRow.fxMode == nil, "no glow away from its hunting grounds")
PX, PY = 0.55, 0.60; SUBZONE = "Dolanaar"; Refresh("ZONE_CHANGED"); frames(40)
check(T.IsInHuntGrounds({ progKey = "101_1", questID = 101 }, { mapID = 99, sub = "dolanaar", pois = {} }),
    "same subzone as a looted spot counts")
check(T.IsInHuntGrounds({ progKey = "x", questID = 555 }, { mapID = 57, x = 0.5, y = 0.5, sub = "", pois = { [555] = { 0.53, 0.5 } } }),
    "inside the quest's objective area counts")

-- 9) Fire / smoulder from evidence
check(P.NpcKey("Creature-0-3-0-0-1994-00001") == "npc:1994" and P.NpcKey("Player-1-0ABC") == nil, "npc id from GUIDs")
check(P.NamesShareWord("Small Spider Leg", "Webwood Spider") and not P.NamesShareWord("Small Gland", "Small Wolf"),
    "a distinctive shared word is a guess; generic words aren't")
TARGET = { name = "Webwood Spider", guid = "Creature-0-1-2-3-1986-0001" }
Refresh("PLAYER_TARGET_CHANGED"); frames(10)
spiderRow = RowFor("Small Spider Leg")
check(P.fire and P.fire.keys["101_1"] == "guess" and spiderRow and spiderRow.fxMode == "smoulder", "a name-only guess smoulders")
check(spiderRow and not spiderRow.fx.haze.__shown and spiderRow.fx.embers[1].__shown and not spiderRow.fx.embers[3].__shown,
    "smoulder: a couple of embers, no heat haze")
GetNumLootItems = function() return 2 end
GetLootSlotInfo = function(slot) if slot == 1 then return "tex", "Small Spider Leg", 1 end return "tex", "Silk Cloth", 1 end
GetLootSourceInfo = function() return "Creature-0-1-2-3-1986-0001", 1 end
TARGET.dead = true
Fire("LOOT_OPENED")
local d1986 = T.K.droppers["npc:1986"]
check(d1986 and d1986["101_1"] == 1 and d1986.loots == 1 and d1986.label == "Webwood Spider", "loot window: the item came from this npc (sure)")
Fire("LOOT_OPENED")
check(d1986["101_1"] == 1 and d1986.loots == 1, "re-opening the same corpse isn't counted twice")
TARGET = { name = "Webwood Spider", guid = "Creature-0-1-2-3-1986-0009" }
Refresh("PLAYER_TARGET_CHANGED"); frames(10)
spiderRow = RowFor("Small Spider Leg")
check(P.fire.keys["101_1"] == "sure" and spiderRow.fxMode == "fire", "a known dropper sets the line on fire")
check(spiderRow.fx.haze.__shown and spiderRow.fx.embers[6].__shown, "fire: heat haze and rising embers")
GetLootSlotInfo = function() return "tex", "Silk Cloth", 1 end
for i = 1, 4 do
    GetLootSourceInfo = function() return "Creature-0-1-2-3-2000-000" .. i, 1 end
    Fire("LOOT_OPENED")
end
TARGET = { name = "Giant Spider Matriarch", guid = "Creature-0-1-2-3-2000-0099" }
Refresh("PLAYER_TARGET_CHANGED")
check(P.fire == nil, "4 loots without the item rule the guess out")
GetNumLootItems, GetLootSlotInfo, GetLootSourceInfo = nil, nil, nil
C_QuestLog.UnitIsRelatedToActiveQuest = function() return false end
TARGET = { name = "Lurking Spider", guid = "Creature-0-1-2-3-3000-0001" }
Refresh("PLAYER_TARGET_CHANGED")
check(P.fire == nil, "UnitIsRelatedToActiveQuest false rules the guess out")
C_QuestLog.UnitIsRelatedToActiveQuest = nil
Enum.TooltipDataLineType = { QuestObjective = 8, QuestTitle = 17, QuestPlayer = 18 }
TARGET = { name = "Moonkin", guid = "Creature-0-1-2-3-7000-0003" }
C_TooltipInfo = { GetUnit = function() return { lines = { { leftText = "Moonkin", type = 2 }, { leftText = "Bashal'Aran", type = 17 },
    { leftText = " - 0/8 Grell Earring", type = 8 } } } end }
Refresh("PLAYER_TARGET_CHANGED")
check(P.fire and P.fire.keys["104_1"] == "sure", "the unit tooltip naming the item is sure")
check(T.tooltipShowsQuests, "learned that this client's unit tooltips list quests")
TARGET = { name = "Forest Spider", guid = "Creature-0-1-2-3-4000-0001" }
C_TooltipInfo = { GetUnit = function() return { lines = { { leftText = "Forest Spider", type = 2 }, { leftText = "Level 5", type = 0 } } } end }
Refresh("PLAYER_TARGET_CHANGED")
check(P.fire == nil, "tooltips list quests here and this one doesn't: no guess")
T.tooltipShowsQuests = nil
C_TooltipInfo = nil
TARGET = { name = "Webwood Spider", guid = "Creature-0-1-2-3-1986-0004", hostile = false }
Refresh("PLAYER_TARGET_CHANGED")
check(P.fire == nil, "friendly NPCs never light the tally")

-- 9b) 12.x secret values: hidden unit data pauses detection, never errors
local SECRET = setmetatable({}, { __eq = function() error("compared a secret") end,
    __index = function() error("indexed a secret") end, __tostring = function() error("printed a secret") end })
issecretvalue = function(v) return rawequal(v, SECRET) end
TARGET = { name = SECRET, guid = SECRET }
local errsBefore = #ERRORS
local reported = 0
local realReport = T.ReportError
T.ReportError = function(e) reported = reported + 1; print("REPORTED: " .. tostring(e)) end
Refresh("PLAYER_TARGET_CHANGED")
GetNumLootItems = function() return 1 end
GetLootSlotInfo = function() return "tex", SECRET, 1 end
GetLootSourceInfo = function() return SECRET, 1 end
Fire("LOOT_OPENED")
C_TooltipInfo = { GetUnit = function() return { lines = { { leftText = SECRET, type = SECRET } } } end }
TARGET = { name = "Webwood Spider", guid = SECRET }
Refresh("PLAYER_TARGET_CHANGED")
T.ReportError = realReport
check(reported == 0 and #ERRORS == errsBefore, "secret names, GUIDs, loot and tooltip lines are skipped without errors")
check(P.fire == nil or P.fire.keys["101_1"] ~= "sure", "no sure drop from hidden data")
GetNumLootItems, GetLootSlotInfo, GetLootSourceInfo, C_TooltipInfo, issecretvalue = nil, nil, nil, nil, nil
TARGET = nil
Refresh("PLAYER_TARGET_CHANGED"); frames(5)
check(P.fire == nil, "fire goes out when you drop the target")
T.db.opts.inkEffects = false; Refresh("ZONE_CHANGED")
spiderRow = RowFor("Small Spider Leg")
check(spiderRow and spiderRow.fxMode == nil, "ink effects can be switched off")
T.db.opts.inkEffects = true

-- 10) Click = super-track (like the tracker's quest icon); right-click = quest log
local stID = 0
C_SuperTrack.GetSuperTrackedQuestID = function() return stID end
C_SuperTrack.SetSuperTrackedQuestID = function(id) stID = id end
C_QuestLog.GetQuestsOnMap = function(m) if m == 57 then return { { questID = 101, x = 0.40, y = 0.40 } } end return {} end
local watchBefore = {}
for k in pairs(WATCHED) do watchBefore[k] = true end
Refresh("ZONE_CHANGED")
spiderRow = RowFor("Small Spider Leg")
spiderRow:GetScript("OnClick")(spiderRow, "LeftButton")
check(stID == 101, "click super-tracks the item's quest")
local sameWatch = true
for k in pairs(WATCHED) do if not watchBefore[k] then sameWatch = false end end
for k in pairs(watchBefore) do if not WATCHED[k] then sameWatch = false end end
check(sameWatch, "...without changing watches")
spiderRow = RowFor("Small Spider Leg")
check(spiderRow and spiderRow.lasso and spiderRow.lasso[1].main.__shown, "the tracked quest's items get a red ink circle")
spiderRow:GetScript("OnClick")(spiderRow, "LeftButton")
check(stID == 0, "click again stops tracking")
spiderRow = RowFor("Small Spider Leg")
check(spiderRow and not spiderRow.lasso[1].main.__shown, "circle gone once untracked")
local openedQuest
QuestMapFrame_OpenToQuestDetails = function(id) openedQuest = id end
spiderRow:GetScript("OnClick")(spiderRow, "RightButton")
check(openedQuest == 101, "right-click opens the quest log at the quest")
openedQuest = nil
InCombatLockdown = function() return true end
local realPrint = print
print = function() end
spiderRow:GetScript("OnClick")(spiderRow, "RightButton")
print = realPrint
check(openedQuest == nil, "in combat the quest log waits")
InCombatLockdown = function() return false end
Fire("PLAYER_REGEN_ENABLED")
check(openedQuest == 101, "...and opens when combat ends")
local addonSrc = io.open(root .. "/FieldTally.lua", "rb"):read("*a")
check(not addonSrc:find("WorldMapFrame:AddDataProvider") and not addonSrc:find("WorldMapFrame.ScrollContainer"),
    "the tally draws nothing on the world map")

-- 11) Hover: tooltip lines + map preview + placement
local ttLines = {}
local realAdd = GameTooltip.AddLine
GameTooltip.AddLine = function(self, t) table.insert(ttLines, tostring(t)) end
spiderRow:GetScript("OnEnter")(spiderRow)
GameTooltip.AddLine = realAdd
local tt = table.concat(ttLines, " | ")
check(tt:find("Recipe of the Kaldorei") and tt:find("%[7%]"), "tooltip: quest title and level")
check(tt:find("Small Spider Leg: 4 / 7"), "tooltip: 'Item: 4 / 7'")
check(tt:find("Found it in 1 spot"), "tooltip: found it in N spots")
check(tt:find("Looted from: .*Webwood Spider %(1 of 1%)"), "tooltip: looted from with counts (" .. tt .. ")")
check(tt:find("Left%-Click: track this quest") and tt:find("Right%-Click: open the quest log"), "tooltip: click hints")
local pv = T.mapPreview
check(pv and pv.__shown, "hover shows the map preview")
check(pv and pv.title.__text:find("Teldrassil") and pv.title.__text:find("Small Spider Leg"), "preview names zone and item")
local pvRings = 0
for _, c in ipairs(pv and pv.child.circles or {}) do if c.__shown then pvRings = pvRings + 1 end end
check(pvRings == 2, "preview rings the looted spot and the objective area (" .. pvRings .. ")")
check(pv and pv.you.__shown, "preview marks the player")
C_Map.GetMapArtLayers = function() return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } } end
C_Map.GetMapArtLayerTextures = function() local t = {}; for i = 1, 12 do t[i] = 10000 + i end; return t end
spiderRow:GetScript("OnEnter")(spiderRow)
local tilesShown = 0
for _, t in ipairs(pv.tiles) do if t.__shown then tilesShown = tilesShown + 1 end end
check(tilesShown == 12, "preview draws the zone's own map tiles")
check(pv.child.__w > P.PREVIEW_W and pv.child.__w <= P.PREVIEW_W / 0.35 + 1, "zoomed in, but never closer than a third of the zone")
spiderRow:GetScript("OnLeave")(spiderRow)
check(not pv.__shown, "preview hides with the tooltip")
T.db.opts.mapPreview = false
spiderRow:GetScript("OnEnter")(spiderRow)
check(not pv.__shown, "map preview can be switched off")
T.db.opts.mapPreview = true
spiderRow:GetScript("OnLeave")(spiderRow)
f.__rect = { 40, 200, 230, 175 }
GameTooltip.__rect = { 290, 300, 260, 80 }
ChatFrame1.__rect = { 40, 10, 430, 150 }
spiderRow:GetScript("OnEnter")(spiderRow)
local tpt, trel, trp = GameTooltip:GetPoint(1)
check(tpt == "TOPLEFT" and trel == spiderRow and trp == "TOPRIGHT", "tooltip opens on the roomier side of the tally")
local _, prel, _, ppx, ppy = pv:GetPoint(1)
local PR = { l = ppx, b = ppy, r = ppx + pv:GetWidth(), t = ppy + pv:GetHeight() }
check(prel == UIParent and P.Overlap(PR, P.TallyRect()) == 0 and P.Overlap(PR, P.ScreenRect(GameTooltip, 0)) == 0,
    "preview clear of the tally and tooltip")
check(P.Overlap(PR, P.ScreenRect(ChatFrame1, 0)) == 0, "preview clear of chat")
check(PR.l >= 0 and PR.b >= 0 and PR.r <= UIParent:GetWidth() and PR.t <= UIParent:GetHeight(), "preview fully on screen")
f.__rect = { 1650, 200, 230, 175 }
GameTooltip.__rect = { 1380, 300, 260, 80 }
spiderRow:GetScript("OnEnter")(spiderRow)
check(GameTooltip:GetPoint(1) == "TOPRIGHT", "tally at the right edge: tooltip opens on its left")
spiderRow:GetScript("OnLeave")(spiderRow)
f.__rect, GameTooltip.__rect, ChatFrame1.__rect = nil, nil, nil
C_Map.GetMapArtLayers, C_Map.GetMapArtLayerTextures = nil, nil

-- 12) Minimap pins
Minimap = CreateFrame("Frame", "Minimap"); Minimap.__w, Minimap.__h = 140, 140
GetCVar = function() return "0" end
stID = 101
T.UpdateMinimapPins()
check(P.mmPins and P.mmPins[1].__shown and P.mmPins[1].__alpha < 1, "a far-off spot sits on the rim")
PX, PY = 0.3030, 0.3010
T.UpdateMinimapPins()
local _, _, _, mx, my = P.mmPins[1]:GetPoint(1)
check(P.mmPins[1].__alpha == 1 and math.sqrt(mx * mx + my * my) < 64, "a nearby spot is inside the minimap")
GetCVar = function() return "1" end
GetPlayerFacing = function() return math.pi / 2 end
T.UpdateMinimapPins()
local _, _, _, rx, ry = P.mmPins[1]:GetPoint(1)
check(math.abs(math.sqrt(rx * rx + ry * ry) - math.sqrt(mx * mx + my * my)) < 0.01 and (math.abs(rx - mx) > 0.01 or math.abs(ry - my) > 0.01),
    "Rotate Minimap turns the pins around the player")
GetCVar, GetPlayerFacing = function() return "0" end, nil
local pinTip = {}
GameTooltip.AddLine = function(self, t) table.insert(pinTip, tostring(t)) end
P.mmPins[1]:GetScript("OnEnter")(P.mmPins[1])
GameTooltip.AddLine = realAdd
check(table.concat(pinTip, "|"):find("Small Spider Leg"), "hovering a pin names the item")
T.db.opts.minimapPins = false; T.UpdateMinimapPins()
check(not P.mmPins[1].__shown, "minimap pins can be switched off")
T.db.opts.minimapPins = true
stID = 0; T.UpdateMinimapPins()
check(not P.mmPins[1].__shown, "no pins without a super-tracked quest")
PX, PY = 0.55, 0.60

-- 13) Looks and handwriting
check(T.DEFAULTS.look == "RAG" and T.db.look == "RAG" and P.GetStyle().label == "Torn rag", "torn rag is the default look")
check(f.topSheet.body.__tex == P.TEXTURE_DIR .. "torn_rag", "a new character's tally starts on the torn rag")
local function CountShown(list) local n = 0; for _, t in ipairs(list or {}) do if t.__shown then n = n + 1 end end; return n end
SlashCmdList["CACHEREQUEST"]("look handkerchief"); Refresh("ZONE_CHANGED")
local cp = f.topSheet.clothParts
check(cp and CountShown(cp.corner) == 4 and CountShown(cp.lace) > 60 and CountShown(cp.eye) == CountShown(cp.lace),
    "handkerchief: rounded corners, scalloped lace with eyelets")
check(f.topSheet.hem[1].__shown and f.topSheet.hem2[1].__shown and #f.topSheet.stitches > 10 and f.topSheet.folds[1].__shown
    and f.topSheet.drape[1].__shown, "handkerchief: woven band and stripe, running stitch, creases, drape wrinkles")
check(CountShown(f.topSheet.segs[2]) == 0, "handkerchief: no torn paper edges")
P.CycleStyle(); P.ApplyStyle(); Refresh("ZONE_CHANGED")
check(T.db.look == "PARCHMENT" and f.topSheet.grain.__shown and CountShown(f.topSheet.segs[2]) > 20, "parchment: torn edges and grain")
check(P.INK[1] == 0.17, "parchment: iron-gall ink from its style table")

-- Texture looks: crumpled paper and torn rag
local root2 = root
local function FileExists(p) local fh = io.open(p, "rb"); if fh then fh:close(); return true end return false end
local function TgaHeader(p)
    local fh = io.open(p, "rb"); if not fh then return nil end
    local h = fh:read(18); local size = fh:seek("end"); fh:close()
    return { type = h:byte(3), w = h:byte(13) + 256 * h:byte(14), h = h:byte(15) + 256 * h:byte(16), bpp = h:byte(17), size = size }
end
for _, name in ipairs({ "crumpled_paper", "torn_rag" }) do
    local hd = TgaHeader(root2 .. "/textures/" .. name .. ".tga")
    check(hd and hd.type == 2 and hd.w == 512 and hd.h == 512 and hd.bpp == 32 and hd.size == 18 + 512 * 512 * 4,
        "textures/" .. name .. ".tga is a 512x512 32-bit uncompressed TGA")
end
local function CheckImageLook(key, file, pad, shadowA, inkR, corner)
    SlashCmdList["CACHEREQUEST"]("look " .. ((key == "RAG") and "rag" or "crumpled"))
    Refresh("ZONE_CHANGED")
    local st = P.GetStyle()
    local path = "Interface\\AddOns\\CacheReQuest\\textures\\" .. file
    check(T.db.look == key and st.image == path, key .. ": image path uses this addon's folder (" .. tostring(st.image) .. ")")
    check(f.topSheet.body.__tex == path and f.topSheet.body.__vc and f.topSheet.body.__vc[1] == 1, key .. ": top sheet is the image, untinted")
    check(CountShown(f.topSheet.segs[2]) == 0 and CountShown(f.topSheet.clothParts and f.topSheet.clothParts.lace) == 0 and not f.topSheet.hem[1].__shown
        and not f.topSheet.grain.__shown, key .. ": no drawn edges, lace, hem or grain on top")
    local sb = f.shadowSheet.body
    check(f.shadowSheet.__shown and sb.__tex == path and sb.__vc[1] == 0 and sb.__vc[4] == shadowA, key .. ": shadow is the same image tinted black at " .. shadowA)
    local _, _, _, sdx, sdy = f.shadowSheet:GetPoint(1)
    check(sdx == 3 and sdy == -4, key .. ": shadow offset 3px right, 4px down")
    local flips, distinct = {}, true
    for k = 1, 3 do
        local b = f.backSheets[k].body
        local key2 = table.concat(b.__tc or {}, ",")
        if flips[key2] or key2 == "0,1,0,1" then distinct = false end
        flips[key2] = true
        if b.__tex ~= path or not (b.__vc[1] < 1) then distinct = false end
    end
    check(distinct, key .. ": pages underneath are the same image, each flipped differently and darker")
    check(f.visibleBackSheets == math.min(#P.areas - 1, 3), key .. ": pages peek out underneath")
    local _, _, _, cx, cy = f.content:GetPoint(1)
    local pl, pt = P.GetPads(f)
    check(pl >= pad and pt >= pad and cx == 6 + pl and cy == -28 - pt, key .. ": writing kept inside the material (" .. pl .. "," .. pt .. ")")
    check(math.abs(P.INK[1] - inkR) < 1e-9, key .. ": ink colour from its style table")
    local cpt, crel, crp, ccx, ccy = f.corner:GetPoint(1)
    check(cpt == "BOTTOMRIGHT" and crel == f.chrome and ccx == -math.floor(f:GetWidth() * corner[1] + 0.5)
        and ccy == math.floor(f:GetHeight() * corner[2] + 0.5), key .. ": page corner on the image's own corner (" .. tostring(ccx) .. "," .. tostring(ccy) .. ")")
    f.corner.drawnKey = nil; P.DrawCorner(f.corner)
    local flapImg, flap8, underImg = false, false, false
    for j = 1, P.CORNER_MAX do
        local fl, un = f.corner.flap[j], f.corner.under[j]
        if fl.__shown and fl.__tex == path then flapImg = true; if fl.__tc and #fl.__tc == 8 then flap8 = true end end
        if un.__shown and un.__tex == path then underImg = true end
    end
    check(flapImg and flap8 and underImg, key .. ": the corner folds the material itself (mirrored flap, page beneath)")
    check(not f.corner.flapTop.__shown and not f.corner.flapLeft.__shown, key .. ": no drawn straight edges on the flap")
    f.corner:Show()                    -- the corner only shows with several pages; force it for the resize check
    f:SetSize(300, 200)
    local _, _, _, rcx, rcy = f.corner:GetPoint(1)
    check(rcx == -math.floor(300 * corner[1] + 0.5) and rcy == math.floor(200 * corner[2] + 0.5), key .. ": corner follows the image when resized")
    f:SetSize(T.db.frame.width, T.db.frame.height)
end
CheckImageLook("CRUMPLED", "crumpled_paper", 8, 0.35, 0.20, { 0.036, 0.034 })
CheckImageLook("RAG", "torn_rag", 8, 0.32, 0.15, { 0.068, 0.046 })
T.db.look = "NATIVE"; P.ApplyStyle(); Refresh("ZONE_CHANGED")
check(T.db.look == "NATIVE" and f.visibleBackSheets == 0 and not f.shadowSheet.__shown, "transparent window: no page pile")
check(f.titleFS.inkKey:find("^PLAIN:"), "transparent window uses the standard font")
check(f.topSheet.body.__tex == "color" and f.topSheet.body.__tc and table.concat(f.topSheet.body.__tc, ",") == "0,1,0,1",
    "switching away from an image look restores the plain sheet")
local cpt2, _, _, ncx, ncy = f.corner:GetPoint(1)
check(ncx == 3 and ncy == -3, "the page corner goes back to the frame's corner")
local styleKeys = {}
for _, s in ipairs(P.STYLES) do styleKeys[#styleKeys + 1] = s.key end
check(table.concat(styleKeys, ",") == "HANDKERCHIEF,PARCHMENT,CRUMPLED,RAG,STONE,BARK,LEAF,LEATHER,ARCANE,NATIVE", "ten looks, in cycle order")
SlashCmdList["CACHEREQUEST"]("look handkerchief")
check(T.db.look == "HANDKERCHIEF" and f.styleKey == "HANDKERCHIEF", "/crq look handkerchief")
local fonts = {}
for _ = 1, 4 do P.CycleFontStyle(); fonts[#fonts + 1] = T.db.font end
check(table.concat(fonts, ",") == "SCRAWL,PLAIN,BLOTTED,QUILL", "handwriting cycles quill > scrawl > plain > blotted")
check(P.FONT_STYLES[1].path == "Fonts\\MORPHEUS.TTF" and P.FONT_STYLES[2].path == "Fonts\\SKURRI.TTF", "built-in client fonts only")
-- the source names one addon folder (P.TEXTURE_DIR), and every image look points at a file that exists
local refs, s = 0, 1
while true do
    local a, b = addonSrc:find("Interface\\\\AddOns", s, true)
    if not a then break end
    refs, s = refs + 1, b + 1
end
local imagesExist = true
for _, st in ipairs(P.STYLES) do
    if st.image then
        local rel = st.image:gsub("^Interface\\AddOns\\CacheReQuest\\", ""):gsub("\\", "/")
        if not FileExists(root .. "/" .. rel .. ".tga") then imagesExist = false end
    end
end
check(refs == 1 and imagesExist and not addonSrc:find("%.blp"), "the only art files are the images in this addon's textures folder")

-- 14) Default position above the chat tabs; recomputed after Edit Mode
local pt, _, relPt, defX, defY = f:GetPoint(1)
check(pt == "BOTTOMLEFT" and relPt == "BOTTOMLEFT" and defX == 100 + P.PILE_MARGIN_X and defY == 500 + 32 + P.PILE_MARGIN_Y,
    "default spot sits above the chat tabs with room for the pile (" .. tostring(defX) .. "," .. tostring(defY) .. ")")
ChatFrame1Tab = CreateFrame("Frame", "ChatFrame1Tab"); ChatFrame1Tab:SetPoint("BOTTOMLEFT", 0, 60)
check(EDITMODE_CB ~= nil, "registered for Edit Mode exit")
EDITMODE_CB(); RunTimers()
local _, _, _, _, ey = f:GetPoint(1)
check(ey == 560 + P.PILE_MARGIN_Y, "after Edit Mode the spot is recomputed from the chat tab (" .. tostring(ey) .. ")")
ChatFrame1Tab = nil

-- 15) Reward filter
local realCount, realMatch = ns.CRQ.GetActiveFilterCount, ns.CRQ.DoesQuestMatchFilter
ns.CRQ.GetActiveFilterCount = function() return 1 end
ns.CRQ.DoesQuestMatchFilter = function(id) return id == 104 end
Refresh("ZONE_CHANGED")
check(not NearIDs()[101] and not NearIDs()[103], "with a reward filter on, only matching quests' items show")
ns.CRQ.GetActiveFilterCount, ns.CRQ.DoesQuestMatchFilter = realCount, realMatch
check(realCount() == 0, "no real reward filter is set at this point")
Refresh("ZONE_CHANGED")
check(NearIDs()[101], "with no reward filter, everything shows")

-- 16) Saved settings: defaults, validation, reload
QRF_SavedState.fieldTally = { look = "BOGUS", font = "PLAIN", nearRadius = 999, opts = { inkEffects = false, showTabs = "yes" },
    frame = { width = 5000 } }
Fire("ADDON_LOADED", "CacheReQuest")
check(T.db.look == T.DEFAULTS.look and T.db.font == "PLAIN", "unknown look falls back to the default, valid font kept")
check(T.db.nearRadius == 50 and T.db.opts.inkEffects == false and T.db.opts.showTabs == true, "out-of-range / wrong-type values fall back")
check(T.db.frame.width == 520 and T.db.frame.height == 175 and T.db.opts.minimapPins == true, "missing settings get their defaults")
check(QRF_SavedState.fieldTally == T.db, "loaded settings are what gets saved")
Fire("ADDON_LOADED", "SomeOtherAddon")
check(T.db.font == "PLAIN", "other addons' ADDON_LOADED is ignored")
T.db.font = "QUILL"; T.db.opts.inkEffects = true; T.db.nearRadius = 10
T.db.opts.tallyTasks = false            -- the reload brought back the defaults: items-only again for the tests below
check(T.K.spots["101_1"] ~= nil, "loot knowledge survives the reload")

-- 17) Pruning shared loot knowledge
T.K.spots["999_1"] = { { m = 57, x = 0.1, y = 0.1 } }
T.K.droppers["wolf"] = { ["999_1"] = 2, label = "Wolf" }
T.K.owners["999_1"] = { ["Tester-Realm"] = true }
T.K.spots["888_1"] = { { m = 57, x = 0.2, y = 0.2 } }
T.K.owners["888_1"] = { ["Alt-Realm"] = true }
T.K.spots["777_1"] = { { m = 57, x = 0.3, y = 0.3 } }
T.K.owners["777_1"] = { ["Tester-Realm"] = true }
C_QuestLog.IsQuestFlaggedCompleted = function(id) return id == 777 end
T.PruneHuntData()
check(T.K.spots["999_1"] == nil and T.K.droppers["wolf"] == nil, "abandoned quest's spots and droppers pruned")
check(T.K.spots["101_1"] ~= nil and T.K.droppers["npc:1994"] ~= nil, "live quest's knowledge kept")
check(T.K.spots["888_1"] ~= nil, "an alt's quest isn't pruned by this character")
check(T.K.spots["777_1"] ~= nil and T.K.kept["777_1"], "a turned-in quest's knowledge is kept for alts for a while")
local realTime = time
time = function() return realTime() + 31 * 86400 end
T.PruneHuntData()
time = realTime
check(T.K.spots["777_1"] == nil, "...and forgotten after " .. P.KEEP_DONE_DAYS .. " days")
C_QuestLog.IsQuestFlaggedCompleted = nil

-- 18) Options panel, gear, slash
check(SETTINGS_CAT and SETTINGS_CAT.panel == CRQ_OptionsPanel, "Settings canvas panel registered")
SlashCmdList["CACHEREQUEST"]("")
check(OPENED_SETTINGS == 99 and CRQ_OptionsPanel.__shown, "/crq opens the options")
local labels = {}
for _, w in ipairs(T.optionWidgets) do
    if w.label then labels[#labels + 1] = w.label.__text elseif w.__text then labels[#labels + 1] = w.__text end
end
local L = table.concat(labels, " | ")
for _, want in ipairs({ "Show the Field Tally", "Look:", "Handwriting:", "Pages for other areas", "Other pages by: ",
    "Turn back to", "...only when something is nearby", "Glowing & burning ink", "Little map", "minimap",
    "List quest items", "List tasks", "Tasks apart from items" }) do
    check(L:find(want, 1, true), "options include '" .. want .. "'")
end
local sliders = 0
for _, w in ipairs(T.optionWidgets) do if w.slider then sliders = sliders + 1 end end
check(sliders == 3, "options have Text size, Near me distance and cluster-size sliders")
local showCb
for _, w in ipairs(T.optionWidgets) do if w.label and w.label.__text == "Show the Field Tally" then showCb = w end end
showCb:SetChecked(false); showCb:GetScript("OnClick")(showCb)
check(T.db.show == false and not f:IsShown(), "unticking Show hides the tally")
SlashCmdList["CACHEREQUEST"]("tally")
check(T.db.show == true and f:IsShown(), "/crq tally brings it back")
check(showCb:GetChecked() == true, "options panel follows the slash command")
T.db.frame.useDefaultAnchor = false; T.db.frame.x = 999
SlashCmdList["CACHEREQUEST"]("reset")
check(T.db.frame.useDefaultAnchor == true and T.db.frame.width == 230, "/crq reset restores the default spot and size")
f.optBtn:GetScript("OnClick")(f.optBtn, "LeftButton")
check(CRQ_OptionsPanel.__shown, "the gear on the tally opens the options")
InCombatLockdown = function() return true end
OPENED_SETTINGS = nil
print = function() end
SlashCmdList["CACHEREQUEST"]("options")
print = realPrint
check(OPENED_SETTINGS == nil, "options don't open in combat")
InCombatLockdown = function() return false end
Fire("PLAYER_REGEN_ENABLED")
check(OPENED_SETTINGS == 99, "...they open when combat ends")
local printed = {}
print = function(s) table.insert(printed, tostring(s)) end
local okDbg, errDbg = pcall(SlashCmdList["CACHEREQUEST"], "debug")
print = realPrint
local dump = table.concat(printed, "\n")
check(okDbg and dump:find("%[type=monster%]") and dump:find("%[type=item%]") and dump:find("%[type=progressbar%]"),
    "/crq debug lists every counted objective with its type: " .. tostring(errDbg))
check(dump:find("|cFF40FF40%+|r Recipe of the Kaldorei: Small Spider Leg"), "/crq debug marks what's on the tally")
check(SLASH_CACHEREQUEST1 == "/crq", "slash command /crq")

-- 19) Hide when nothing is nearby
T.db.opts.hideWhenNothingNearby = true
PX, PY = 0.05, 0.95; SUBZONE = "Nowhere"; NOW = NOW + 400
for _, q in ipairs(QUESTS) do if q.questID == 105 then q.active = false end end
Refresh("QUEST_LOG_UPDATE"); Refresh("ZONE_CHANGED")
check(#P.areas[1].items == 0 and not f:IsShown(), "hides when nothing near you needs gathering")
T.db.opts.hideWhenNothingNearby = false
Refresh("ZONE_CHANGED")
check(f:IsShown() and #P.areas > 1, "...and stays up for the other pages when that option is off")

-- 20) Options gear on the Objective Tracker
local gear = CRQ_TrackerOptionsButton
check(gear ~= nil and gear.__shown, "options gear on the Objective Tracker")
local gp, grel, grp = gear:GetPoint(1)
check(gp == "RIGHT" and grel == QRF_TrackerFilterButton and grp == "LEFT", "gear sits just left of the Filter button")
check(gear:GetParent() == QRF_TrackerFilterButton:GetParent(), "gear lives on the tracker header with the Filter button")
OPENED_SETTINGS = nil
gear:GetScript("OnClick")(gear, "LeftButton")
check(OPENED_SETTINGS == 99, "clicking the gear opens the options")
gear:GetScript("OnClick")(gear, "RightButton")
check(T.db.show == false and not f:IsShown(), "right-clicking the gear puts the tally away")
gear:GetScript("OnClick")(gear, "RightButton")
check(T.db.show == true and f:IsShown(), "...and brings it back")
local gearCb
for _, w in ipairs(T.optionWidgets) do if w.label and w.label.__text == "Options gear on the Objective Tracker" then gearCb = w end end
check(gearCb ~= nil, "options have a switch for the tracker gear")
gearCb:SetChecked(false); gearCb:GetScript("OnClick")(gearCb)
check(not gear.__shown and T.db.opts.trackerGear == false, "the gear can be switched off")
gearCb:SetChecked(true); gearCb:GetScript("OnClick")(gearCb)
check(gear.__shown, "...and back on")

-- 21) Quest rewards at the right of the item line
PX, PY = 0.55, 0.60; SUBZONE = "Dolanaar"; NOW = NOW + 400
C_QuestLog.GetQuestsOnMap = nil          -- back to the waypoint coords (section 10 moved 101's objective area)
C_QuestLog.GetQuestRewardCurrencies = function(id)
    if id == 101 then return { { currencyID = 2815, name = "Resonance Crystals", texture = 5172976, totalRewardAmount = 250 } } end
    return {}
end
GetNumQuestLogRewards = function(id) return (id == 103) and 1 or 0 end
GetQuestLogRewardInfo = function() return "Fang Charm", 133434, 1, 2, true, 5555 end
QUESTS[4].objs[1].text = "15/15 Pristine Gnarlpine Fang From The Deep Barrow Den"
T.db.look = "HANDKERCHIEF"; P.ApplyStyle()      -- the reload above brought back the rag; these widths assume the hanky
Refresh("QUEST_LOG_UPDATE"); P.SelectArea(P.CURRENT_KEY, false); Refresh("ZONE_CHANGED"); frames(40)
local rl = ns.CRQ.GetQuestRewardsForTally(101)
check(rl and rl[1].name == "Resonance Crystals" and rl[1].amount == 250 and rl[1].isCurrency, "Cache ReQuest's reward scan is shared with the tally")
check(ns.CRQ.GetQuestRewardsForTally(104) == nil and P.RewardBadge(104, P.GetStyle()) == nil, "a quest without rewards gets no reward text")
local st = P.GetStyle()
local padL, _, padR = P.GetPads(f)
local contentW = math.max(150, f:GetWidth() - 12 - padL - padR)
spiderRow = RowFor("Small Spider Leg")
check(spiderRow and spiderRow.rewardText.__shown and spiderRow.rewardText.__text:find("5172976", 1, true)
    and spiderRow.rewardText.__text:find("250", 1, true), "item line shows the quest's currency icon and amount")
check(spiderRow.rewardText.__text:find("|c" .. P.Hex(st.reward), 1, true), "reward amount inked in the look's reward colour")
local rp, rrel, rrp = spiderRow.rewardText:GetPoint(1)
check(rp == "TOPRIGHT" and rrel == spiderRow and rrp == "TOPRIGHT", "rewards are aligned from the right")
local spiderRewardW = math.min(6 * #spiderRow.rewardText.__text, contentW * P.REWARD_MAX_SHARE)
check(spiderRow.textW < contentW - 24 and spiderRow.textW + 24 + P.REWARD_GAP + spiderRewardW <= contentW + 1,
    "item text column stops a buffer short of the rewards (" .. tostring(spiderRow.textW) .. ")")
local fangLine
for _, fr in ipairs(allFrames) do
    if fr.__kind == "FontString" and fr.__shown ~= false and type(fr.__text) == "string" and fr.__text:find("Pristine", 1, true)
        and fr.__parent and fr.__parent.itemText == fr then fangLine = fr end
end
local fangR = fangLine and fangLine.__parent
check(fangR and fangR.rewardText.__shown and fangR.rewardText.__text:find("133434", 1, true)
    and not fangR.rewardText.__text:find("|c", 1, true), "a single item reward shows just its icon")
check(fangLine and fangLine.__text:find("\n"), "a long item name wraps before the rewards")
local strokes2 = {}
P.DrawStroke = function(s, rel, x0, y0, x1, y1, ...)
    table.insert(strokes2, { rel = rel, x1 = x1 })
    return realDraw(s, rel, x0, y0, x1, y1, ...)
end
P.Render(f)
P.DrawStroke = realDraw
local maxX1 = 0
for _, s in ipairs(strokes2) do if s.rel == fangLine then maxX1 = math.max(maxX1, s.x1) end end
check(maxX1 > 0 and maxX1 <= fangR.textW + 2, "every strike stays left of the rewards (" .. maxX1 .. " vs " .. tostring(fangR.textW) .. ")")
local rewardTip = {}
GameTooltip.AddLine = function(self, t) table.insert(rewardTip, tostring(t)) end
spiderRow:GetScript("OnEnter")(spiderRow)
GameTooltip.AddLine = realAdd
spiderRow:GetScript("OnLeave")(spiderRow)
local rtt = table.concat(rewardTip, " | ")
check(rtt:find("Rewards:", 1, true) and rtt:find("250 Resonance Crystals", 1, true), "tooltip lists the rewards by name (" .. rtt .. ")")
P.SelectArea(P.CURRENT_KEY, false)
T.db.opts.showRewards = false; Refresh("ZONE_CHANGED")
spiderRow = RowFor("Small Spider Leg")
check(spiderRow and not spiderRow.rewardText.__shown and spiderRow.textW == contentW - 24, "rewards can be switched off (full-width text again)")
T.db.opts.showRewards = true; Refresh("ZONE_CHANGED")

-- 22) Filter menu: movable (remembered per button) and a Reset button inside it
local tbtn = QRF_TrackerFilterButton
tbtn:GetScript("OnClick")(tbtn, "LeftButton")
local menu = QRF_DropdownMenu
check(menu and menu.__shown, "tracker Filter button opens the filter menu")
local mp, mrel, mrp = menu:GetPoint(1)
check(mp == "TOPRIGHT" and mrel == tbtn and mrp == "BOTTOMRIGHT", "first time it opens under the button")
check(menu.dragHandle and menu:GetScript("OnDragStart") and menu.dragHandle:GetScript("OnDragStart"), "menu can be dragged (header or empty space)")
menu:SetPoint("TOPRIGHT", tbtn, "BOTTOMRIGHT", 37, -120)       -- where the drag left it (mock: left 137, top 380)
menu.dragHandle:GetScript("OnDragStart")(menu.dragHandle)
menu.dragHandle:GetScript("OnDragStop")(menu.dragHandle)
local savedPos = QRF_SavedState.menuPositions and QRF_SavedState.menuPositions.TRACKER
check(savedPos and savedPos.x == 137 and savedPos.y == 380, "dragged spot saved for the tracker's menu")
check(QRF_SavedState.menuPositions.QUESTLOG == nil, "the Quest Log's menu keeps its own spot")
tbtn:GetScript("OnClick")(tbtn, "LeftButton")
check(not menu.__shown, "clicking the Filter button again closes it")
tbtn:GetScript("OnClick")(tbtn, "LeftButton")
mp, mrel, mrp = menu:GetPoint(1)
local _, _, _, mx2, my2 = menu:GetPoint(1)
check(menu.__shown and mp == "TOPLEFT" and mrel == UIParent and mrp == "BOTTOMLEFT" and mx2 == 137 and my2 == 380,
    "it reopens where you dragged it")
QRF_SavedState.menuPositions = { TRACKER = { x = 50, y = 600 }, BOGUS = { x = 1 }, QUESTLOG = { x = "no" } }
Fire("ADDON_LOADED", "CacheReQuest")
menu:Hide(); tbtn:GetScript("OnClick")(tbtn, "LeftButton")
local _, _, _, lx, ly = menu:GetPoint(1)
check(lx == 50 and ly == 600, "saved menu position survives a reload (bad entries ignored)")
menu.dragHandle:GetScript("OnMouseUp")(menu.dragHandle, "RightButton")
mp, mrel = menu:GetPoint(1)
check(mp == "TOPRIGHT" and mrel == tbtn, "right-clicking the header puts it back under its button")
check(QRF_SavedState.menuPositions and QRF_SavedState.menuPositions.TRACKER == nil, "...and forgets the dragged spot")

-- Reset button inside the menu
check(menu.resetBtn and menu.resetBtn.__text == "Reset", "the menu has a Reset button")
local rp2, rrel2, rrp2 = menu.resetBtn:GetPoint(1)
check(rp2 == "RIGHT" and rrel2 == menu.doneBtn and rrp2 == "LEFT", "Reset sits beside Done")
local crystalRow
for _, fr in ipairs(allFrames) do
    if fr.__kind == "FontString" and fr.__shown ~= false and type(fr.__text) == "string" and fr.__text:find("Resonance Crystals", 1, true)
        and fr.__parent and fr.__parent.check and fr.__parent.__parent == menu then crystalRow = fr.__parent end
end
check(crystalRow ~= nil, "the menu lists the quest's currency")
crystalRow:GetScript("OnClick")(crystalRow)
check(ns.CRQ.GetActiveFilterCount() == 1, "ticking a reward sets a filter")
local enabledState
local realSetEnabled = menu.resetBtn.SetEnabled
menu.resetBtn.SetEnabled = function(self, v) enabledState = v end
menu.resetBtn:GetScript("OnClick")(menu.resetBtn)
check(ns.CRQ.GetActiveFilterCount() == 0, "Reset clears every filter")
check(enabledState == false, "Reset greys out when there's nothing left to reset")
menu.resetBtn.SetEnabled = realSetEnabled
check(menu.__shown, "the menu stays open after a reset")
menu:Hide()

-- 23) (?) / (•••) slider bar under the tracker's "Quests" header
local contents = QuestObjectiveTracker.ContentsFrame
contents.__w = 248
local blockA = CreateFrame("Frame", nil, contents); blockA.id = 101; blockA.__h = 36; blockA.__w = 248
local blockB = CreateFrame("Frame", nil, contents); blockB.id = 102; blockB.__h = 36; blockB.__w = 248
blockA.HeaderText = blockA:CreateFontString(); blockB.HeaderText = blockB:CreateFontString()
contents.GetChildren = function() return blockA, blockB end
QuestObjectiveTracker:Update()
local bar = CRQ_TrackerClusterBar
check(bar ~= nil and bar.__shown, "slider bar shown above tracked quests")
local bp, brel, brp, bx, by = bar:GetPoint(1)
check(bp == "TOPLEFT" and brel == contents and bx == -26 and by == -4, "bar lines up with the stacked cards, a gap below the header")
check(bar.__w == 242, "bar is exactly as wide as the stacked cards (" .. tostring(bar.__w) .. ")")
local L = bar.crqLayout
check(L and L.half == 121 and 20 + 4 + L.sliderW + 3 + 28 + 4 == L.half, "each control fills exactly half the bar")
check(bar.turnInSlider.__w == L.sliderW and bar.incompSlider.__w == L.sliderW, "both sliders the same width")
local _, _, _, tgx = bar.turnInToggle:GetPoint(1)
local _, _, _, igx = bar.incompToggle:GetPoint(1)
check(tgx == 0 and igx == L.half, "(?) starts the left half, (•••) starts the right half")
local tvp, tvrel, _, tvx = bar.turnInValText:GetPoint(1)
local _, _, _, ivx = bar.incompValText:GetPoint(1)
check(tvp == "RIGHT" and tvrel == bar and tvx == L.half - 4 and ivx == 242 - 4, "values right-aligned inside their half, nothing past the cards")
local fillW = bar.turnInSlider.fill.__w
check(fillW == math.floor((15 / 49) * (L.sliderW - 16) + 8 - 1 + 0.5) and fillW < L.sliderW, "gold fill ends under the thumb (" .. tostring(fillW) .. ")")
local _, _, _, _, firstY = blockA:GetPoint(1)
check(firstY == -4 - 22 - 8, "first quest starts below the bar with a gap (" .. tostring(firstY) .. ")")

-- 23b) Ported from Handkerquest 2.3: tasks and their toggles, new looks, margins that follow the window,
-- the material fold, wet ink, Blotted scrawl, text size, the one-line heading, the chat note
-- (a function of its own: the main chunk is near Lua's 200-local limit)
;(function()
    PX, PY = 0.55, 0.60; SUBZONE = "Dolanaar"; NOW = NOW + 400
    T.db.look = "RAG"; T.db.font = "QUILL"; T.db.show = true; T.db.opts.showTabs = true
    T.db.opts.hideWhenNothingNearby = false; P.ApplyStyle(); P.SelectArea(P.CURRENT_KEY, false)

    -- tasks: the kill/explore quest's goals, only because it has several
    local q102 = T.quests[102]
    check(q102 and #q102.taskObjectives == 4 and q102.taskObjectives[1].kind == "slay" and q102.taskObjectives[2].kind == "task"
        and q102.taskObjectives[2].single and not q102.taskObjectives[1].single, "a quest with several goals: a slay line and one-off steps")
    check(T.ObjectiveKind(nil, "Ambushers killed") == "slay" and T.ObjectiveKind(nil, "Skillful lad") == "task", "untyped goals: slay words, whole words only")
    T.db.opts.tallyTasks = true; Refresh("ZONE_CHANGED")
    local texts = ShownTexts()
    check(texts:find("0/6|r  |c%x+Gnarlpine Ambusher slain") and texts:find("|c%x+Cenarion Hold depths entrance explored|r"),
        "tasks on the tally: '0/6  Gnarlpine Ambusher slain' and a one-off step without a count")
    check(f.footerFS.__text:find("done"), "footer counts what's done, not just gathered (" .. tostring(f.footerFS.__text) .. ")")

    -- the three toggles beside the gear
    local qb = f.quickBtns
    check(qb and qb.items and qb.tasks and qb.separate and qb.items.__w == 16, "basket, sword and tasks-apart toggles beside the gear")
    local _, sepRel, _, sepX = qb.separate:GetPoint(1)
    check(sepRel == f.optBtn and sepX == -P.QUICK_GEAR_GAP and #qb.items.strokes == 13 and #qb.tasks.strokes == 4, "toggles spaced from the gear; basket and sword glyphs")
    check(qb.items.on and qb.tasks.on and not qb.separate.on, "full ink = on")
    qb.items:GetScript("OnClick")(qb.items)
    check(not T.db.opts.tallyLoot and not ShownTexts():find("Small Spider Leg") and f:IsShown(), "items off: tasks only, and the tally stays up")
    qb.tasks:GetScript("OnClick")(qb.tasks)
    check(T.db.opts.tallyTasks, "the last of items / tasks can't be switched off")
    qb.items:GetScript("OnClick")(qb.items)
    f:SetSize(320, 420)                      -- room for both groups on the page
    qb.separate:GetScript("OnClick")(qb.separate)
    local heads = {}
    for _, h in ipairs(f.kindHeads or {}) do if h.fs.__shown then heads[#heads + 1] = h.fs.__text end end
    check(T.db.opts.tallySeparate and table.concat(heads, ",") == "Items,Tasks", "tasks apart: Items and Tasks headings (" .. table.concat(heads, ",") .. ")")
    qb.separate:GetScript("OnClick")(qb.separate)
    check(#(f.kindHeads or {}) == 0 or not f.kindHeads[1].fs.__shown, "headings go away with tasks together")
    f:SetSize(T.db.frame.width, T.db.frame.height)

    -- new looks: images, margins that follow the window, the fold
    for _, key in ipairs({ "STONE", "BARK", "LEAF", "LEATHER", "ARCANE" }) do
        SlashCmdList["CACHEREQUEST"]("look " .. ({ STONE = "slate", BARK = "bark", LEAF = "leaf", LEATHER = "leather", ARCANE = "arcane" })[key])
        local st = P.GetStyle()
        check(T.db.look == key and f.topSheet.body.__tex == st.image and FileExists(root .. "/textures/" .. st.image:match("([%w_]+)$") .. ".tga"),
            key .. ": /crq look picks it, and its texture is in the addon")
        local pl = P.GetPads(f)
        check(pl == math.max(st.pad, math.floor(f:GetWidth() * st.inset[1] + 0.5)), key .. ": margins are a share of the window")
    end
    check(f.arcaneOn and f.arcane and f.arcane.ring.__shown and f.titleFS.halo and f.titleFS.halo[1].__shown, "arcane script: rune circle and glowing words")
    f.corner:Show(); f.corner.drawnKey = nil; P.DrawCorner(f.corner)
    check(not f.corner.under[1].__shown and f.corner.foldEdge.__shown, "arcane script: a drawn corner mark, nothing folds")
    SlashCmdList["CACHEREQUEST"]("look leather")
    f.corner:Show(); P.PlaceCorner(f); f.corner.drawnKey = nil; P.DrawCorner(f.corner)
    local NF = P.CORNER_REST + (-f.corner.offX) + f.corner.offY
    check(NF > P.CORNER_REST and f.corner.under[NF] and f.corner.under[NF].__shown and f.corner.crease[1].__shown
        and not f.corner.foldEdge.__shown, "leather: the fold reaches the image's corner and follows the hide's edge")
    SlashCmdList["CACHEREQUEST"]("look leaf")
    f.corner:Show(); P.PlaceCorner(f); f.corner.drawnKey = nil; P.DrawCorner(f.corner)
    check(f.corner.under[P.CORNER_REST].__shown and not f.corner.under[P.CORNER_REST + 1].__shown, "leaf: a dog-ear on the leaf's own corner")
    check(P.INK[1] < 0.1, "leaf: near-black ink")
    SlashCmdList["CACHEREQUEST"]("look rag")
    Refresh("ZONE_CHANGED")
    local row = RowFor("Small Spider Leg")
    check(row and row.itemText.halo and row.itemText.halo[1].__shown and P.BLEED_W == 2.2, "rag: wet ink round the words and wide bleed")

    -- Blotted scrawl: soaked-in blots from the atlas, a bolder hand, the heading's copies cut off with it
    T.db.font = "BLOTTED"; Refresh("ZONE_CHANGED")
    row = RowFor("Small Spider Leg")
    local blots = 0
    for _, d in ipairs(row and row.drops or {}) do
        if d.__shown and d.__tex == P.INK_BLOTS_TEX and d.__tc and #d.__tc == 4 then blots = blots + 1 end
    end
    check(blots >= 2 and P.INK_BLOTS_TEX == "Interface\\AddOns\\CacheReQuest\\textures\\ink_blots", "blotted scrawl: spatters of ink from the blot atlas")
    check(row.itemText.boldCopy and row.itemText.boldCopy.__shown and row.itemText.boldCopy.__points[1][4] == 0.8, "blotted scrawl: a bolder hand")
    local tb = f.titleFS.boldCopy
    check(f.titleFS.singleLine and tb and tb.__points[2] and tb.__points[2][1] == "TOPRIGHT", "the heading's copies cut off with it, never wrap under it")
    T.db.font = "QUILL"

    -- text size
    T.db.textScale = 150; Refresh("ZONE_CHANGED")
    row = RowFor("Small Spider Leg")
    local _, sz = row.itemText:GetFont()
    check(sz == math.floor(13 * 1.5 + 0.5), "text size 150%: bigger writing (" .. tostring(sz) .. ")")
    T.db.textScale = 100; Refresh("ZONE_CHANGED")

    -- every slider has a real range
    local bad, nS = 0, 0
    for _, fr in ipairs(allFrames) do
        if fr.__kind == "Slider" then
            nS = nS + 1
            if type(fr.__min) ~= "number" or type(fr.__max) ~= "number" or fr.__max <= fr.__min then bad = bad + 1 end
        end
    end
    check(nS >= 3 and bad == 0, "every slider has a min/max range (" .. nS .. " sliders, " .. bad .. " without)")

    -- switching the tally on when "...only when something is nearby" keeps it away says why in chat
    local said, realPrint = {}, print
    T.db.opts.hideWhenNothingNearby = true
    PX, PY = 0.02, 0.02; NOW = NOW + 1000
    SlashCmdList["CACHEREQUEST"]("tally")
    print = function(s) table.insert(said, tostring(s)) end
    SlashCmdList["CACHEREQUEST"]("tally")
    print = realPrint
    check(not f:IsShown() and said[1] and said[1]:find("hidden until something is nearby", 1, true), "tally switched on but nothing nearby: chat says why")
    T.db.opts.hideWhenNothingNearby = false; PX, PY = 0.55, 0.60
    SlashCmdList["CACHEREQUEST"]("tally"); SlashCmdList["CACHEREQUEST"]("tally")

    -- saved: text size clamped, never an empty tally
    QRF_SavedState.fieldTally = { textScale = 400, opts = { tallyLoot = false, tallyTasks = false } }
    Fire("ADDON_LOADED", "CacheReQuest")
    check(T.db.textScale == 150 and T.db.opts.tallyLoot == true, "saved text size clamped; items come back if both were off")
    T.db.textScale = 100
    Refresh("ZONE_CHANGED")
end)()
-- 24) Ticker keeps it current and nothing errored
check(type(TICKER) == "function", "proximity ticker running")
TICKER()
;(function()  -- (own function: the test file is near Lua's 200-locals limit) tracker stacks: a quest with an item to click (an eye, a phial...) still stacks; its item gets our own
    -- secure button left of the deck, gliding beside its own card as the deck fans out
    local C = ns.CRQ
    local IB = C.ItemBtns
    local ICON = "Interface\\Icons\\INV_Drink_06"
    local function Count() local n = 0; for _ in pairs(C.GetTrackerClusters()) do n = n + 1 end; return n end
    local function Entries()
        return {
            { questID = 103, isComplete = true, mapID = 57, x = 0.58, y = 0.62, logIdx = 4, frame = CreateFrame("Frame") },
            { questID = 101, isComplete = true, mapID = 57, x = 0.56, y = 0.61, logIdx = 2, frame = CreateFrame("Frame") },
        }
    end
    local e = Entries()
    C.BuildTrackerClustersForBlocks(e)
    check(Count() == 1 and e[1].clusterID and e[1].clusterID == e[2].clusterID, "two ready quests close together share a (?) deck")
    -- the block shows an item button but the game gives no item to put on ours: it keeps its own line
    e = Entries()
    e[1].frame.itemButton = CreateFrame("Button", nil, e[1].frame); e[1].frame.itemButton:Show()
    C.BuildTrackerClustersForBlocks(e)
    check(e[1].hasQuestItem and not e[1].clusterID and Count() == 0, "an item button we can't copy: the quest keeps its own line")
    -- the game names the item: the quest stacks and the deck carries the item
    local real = GetQuestLogSpecialItemInfo
    GetQuestLogSpecialItemInfo = function(i) if i == 4 then return "item:5185", ICON, 1, false end end
    e = Entries(); C.BuildTrackerClustersForBlocks(e)
    check(not e[1].hasQuestItem and Count() == 1, "a finished quest whose item button goes away stacks as usual")
    GetQuestLogSpecialItemInfo = function(i) if i == 4 then return "item:5185", ICON, 1, true end end
    e = Entries(); C.BuildTrackerClustersForBlocks(e)
    check(e[1].hasQuestItem and e[1].questItem and e[1].questItem.link == "item:5185" and Count() == 1,
        "a quest with an item still stacks; the deck knows its item")
    -- the button: left of the collapsed deck, beside its own card when fanned out
    local pool = C.GetDeckPool()
    local deck = CreateFrame("Frame")
    deck.cards = { CreateFrame("Button"), CreateFrame("Button") }
    deck.clusterData = { quests = e }
    deck.numActiveCards = 2
    deck.expandProgress = 0
    deck:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -30)
    deck:Show()
    table.insert(pool, deck)
    IB.Place()
    local b = IB.pool[1]
    check(b and b.__shown and b:GetAttribute("type") == "item" and b:GetAttribute("item") == "item:5185" and b.icon.__tex == ICON
        and b.questID == 103, "its item gets a secure item button (type item, the quest's item)")
    local pt = b.__points[1]
    check(pt[1] == "TOPRIGHT" and pt[2] == UIParent and pt[4] == deck:GetLeft() - 4 and pt[5] == deck:GetTop() - 4,
        "collapsed: the button sits left of the deck, level with its top (placed on screen, not anchored to the deck)")
    check(not (IB.pool[2] and IB.pool[2].__shown), "only quests with items get a button")
    local card = deck.cards[1]
    card:SetPoint("TOPLEFT", deck, "TOPLEFT", 0, -60); card:Show()
    deck.expandProgress = 1
    IB.Place()
    pt = b.__points[1]
    check(pt[4] == card:GetLeft() - 4 and pt[5] == card:GetTop() - 4, "fanned out: the button sits beside its own card")
    -- in combat it can't move: it stays put and catches up after
    local realCombat = InCombatLockdown
    InCombatLockdown = function() return true end
    deck.expandProgress = 0
    IB.Place()
    check(b.__points[1][5] == card:GetTop() - 4 and IB.dirty, "in combat the button stays where it was")
    InCombatLockdown = realCombat
    Fire("PLAYER_REGEN_ENABLED")
    check(b.__points[1][5] == deck:GetTop() - 4 and not IB.dirty, "after combat it catches up with the deck")
    -- deck gone: button gone
    deck:Hide(); IB.Place()
    check(not b.__shown, "no deck, no button")
    table.remove(pool)
    -- a client without secure buttons: the quest keeps its own tracker line (and Blizzard's button)
    IB.ok = false
    e = Entries(); C.BuildTrackerClustersForBlocks(e)
    check(e[1].hasQuestItem and not e[1].clusterID and Count() == 0, "no secure buttons: a quest with an item stays out of decks")
    IB.ok = true
    e = Entries(); e[1].isComplete = false; e[2].isComplete = false
    check(C.QuestBlockHasItemButton(e[1]) and not C.QuestBlockHasItemButton(e[2]), "an unfinished quest with an item always has its button")
    GetQuestLogSpecialItemInfo = real
end)()
check(#ERRORS == 0, "no Lua errors reported (" .. #ERRORS .. ")")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)

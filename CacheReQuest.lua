-- ============================================================================
-- ADDON CONFIGURATION (Edit display names and defaults here)
-- ============================================================================
local CONFIG = {
    ADDON_NAME           = "Cache ReQuest",
    QUESTLOG_BTN_ALL     = "Filter Rewards: All",
    TRACKER_BTN_ALL      = "Filter: All",
    HEADER_TITLE         = "Available Rewards:",
    collapseRightOffset  = -65,  -- Distance of [+] / [-] from right edge of dropdown
    dimmedPinAlpha       = 0.18, -- Opacity of non-matching map pins when in [Dim] mode
    mapIconSize          = 20,   -- Icon size (px) for World Map reward icons
    mapIconBuffer        = 6,    -- Buffer gap (px) between adjacent/colliding map icons in a line
    coalescePadding      = 10,   -- Extra pixel radius within which same-type map icons coalesce
    pinUnderOffset       = 18,   -- Vertical offset (px) placing icons below their quest pin
    logIconSize          = 14,   -- Icon size (px) for Quest Log vertical reward lines
    logIconOffsetY       = 0,    -- Fine-tune vertical icon offset (px) relative to Quest Log text
    showDefaultLogBadges = true, -- Show stacked reward lines in the unfiltered Quest Log
}
-- ============================================================================

local selectedFilters = {}
local collapsedCategories = {}
local knownRewardMeta = {}
local autoUntrack = true
local showCategories = true
local showMapBadges = true
local showMapLegend = true
local filterMapPins = true
local hideUnmatchedMapPins = false
local legendCollapsed = false

local availableRewards = {}
local dropdownDisplayList = {}
local questRewardMap = {}
local matchingQuestsList = {}
local rewardRegistry = {}
local activeZoneRewards = {}

local dropdownRowPool = {}
local customListRowPool = {}
local questLogRewardRowPool = {}
local mapMarkerPool = {}
local legendOverlayRowPool = {}

local savedWatchedQuests = nil
local isSyncingTracker = false
local preloadRefreshPending = false

local customScrollOffset = 0
local dropdownScrollOffset = 0
local dropdownSearchText = ""

local MAX_CUSTOM_ROWS = 8
local MAX_DROPDOWN_ROWS = 15

local sharedMenuFrame = nil
local questLogBar = nil
local trackerFilterBtn = nil
local mapOverlayHolder = nil
local mapLegendOverlay = nil

local CATEGORY_NAMES = {
    [1] = "Seasonal & Event",
    [2] = "Currencies",
    [3] = "Reputation & Renown",
    [4] = "Items & Caches",
    [5] = "Gear & Gold",
}

-- Priority used when choosing which reward icons to show under a map pin when no filter is active
local MAP_BADGE_CATEGORY_PRIORITY = {
    [4] = 1, -- Items & Caches first
    [1] = 2, -- Seasonal & Event second
    [2] = 3, -- Currencies third
    [3] = 4, -- Reputation & Renown fourth
    [5] = 5, -- Gear & Gold last
}

local SEASONAL_CURRENCY_IDS = {
    [241]  = true, -- Champion's Seal
    [515]  = true, -- Darkmoon Prize Ticket
    [1166] = true, -- Timewarped Badge
    [2032] = true, -- Trader's Tender
    [2588] = true, -- Riders of Azeroth Badge
    [2778] = true, -- Bronze Celebration Token
    [3100] = true, -- Bronze Celebration Token (Event)
}

local SEASONAL_ITEM_IDS = {
    [21100]  = true, -- Coin of Ancestry (Lunar Festival)
    [23247]  = true, -- Burning Blossom (Midsummer Fire Festival)
    [33226]  = true, -- Tricky Treat (Hallow's End)
    [37829]  = true, -- Brewfest Prize Token (Brewfest)
    [44791]  = true, -- Noblegarden Chocolate (Noblegarden)
    [49927]  = true, -- Love Token (Love is in the Air)
    [116415] = true, -- Shiny Pet Charm
    [211515] = true, -- Spooky Supplies
}

local SEASONAL_KEYWORDS = {
    "tricky treat", "darkmoon", "timewarped", "brewfest", "love token",
    "coin of ancestry", "burning blossom", "noblegarden", "winter veil",
    "midsummer", "hallow", "spooky", "pilgrim", "lunar festival",
    "celebration token", "anniversary", "trial of style", "trader's tender",
    "community coupon", "prize ticket", "prize token", "riders of azeroth",
    "holiday", "festival"
}

local ApplyFilterChanges
local RebuildDropdownMenu

-- Persist state to SavedVariables table so selections survive /reload
local function SaveState()
    QRF_SavedState = QRF_SavedState or {}
    QRF_SavedState.selectedFilters = selectedFilters
    QRF_SavedState.collapsedCategories = collapsedCategories
    QRF_SavedState.knownRewardMeta = knownRewardMeta
    QRF_SavedState.savedWatchedQuests = savedWatchedQuests
    QRF_SavedState.autoUntrack = autoUntrack
    QRF_SavedState.showCategories = showCategories
    QRF_SavedState.showMapBadges = showMapBadges
    QRF_SavedState.showMapLegend = showMapLegend
    QRF_SavedState.filterMapPins = filterMapPins
    QRF_SavedState.hideUnmatchedMapPins = hideUnmatchedMapPins
    QRF_SavedState.legendCollapsed = legendCollapsed
end

local function LoadState()
    if type(QRF_SavedState) == "table" then
        selectedFilters = QRF_SavedState.selectedFilters or {}
        collapsedCategories = QRF_SavedState.collapsedCategories or {}
        knownRewardMeta = QRF_SavedState.knownRewardMeta or {}
        savedWatchedQuests = QRF_SavedState.savedWatchedQuests
        if QRF_SavedState.autoUntrack ~= nil then autoUntrack = QRF_SavedState.autoUntrack end
        if QRF_SavedState.showCategories ~= nil then showCategories = QRF_SavedState.showCategories end
        if QRF_SavedState.showMapBadges ~= nil then showMapBadges = QRF_SavedState.showMapBadges end
        if QRF_SavedState.showMapLegend ~= nil then showMapLegend = QRF_SavedState.showMapLegend end
        if QRF_SavedState.filterMapPins ~= nil then filterMapPins = QRF_SavedState.filterMapPins end
        if QRF_SavedState.hideUnmatchedMapPins ~= nil then hideUnmatchedMapPins = QRF_SavedState.hideUnmatchedMapPins end
        if QRF_SavedState.legendCollapsed ~= nil then legendCollapsed = QRF_SavedState.legendCollapsed end
    end
end

-- Safe wrapper for 12.x currency & reputation reward APIs
local function GetQuestCurrencies(questID)
    if C_QuestLog and C_QuestLog.GetQuestRewardCurrencies then
        return C_QuestLog.GetQuestRewardCurrencies(questID)
    elseif C_QuestInfoSystem and C_QuestInfoSystem.GetQuestRewardCurrencies then
        return C_QuestInfoSystem.GetQuestRewardCurrencies(questID)
    end
    return nil
end

-- Safe wrapper for quest gold rewards
local function GetQuestGold(questID)
    local money = 0
    if C_QuestLog and C_QuestLog.GetRewardMoney then
        money = C_QuestLog.GetRewardMoney(questID) or 0
    elseif GetQuestLogRewardMoney then
        money = GetQuestLogRewardMoney(questID) or 0
    end
    return math.floor(money / 10000)
end

-- Count how many filters are currently checked
local function GetActiveFilterCount()
    local count = 0
    for _, isSelected in pairs(selectedFilters) do
        if isSelected then count = count + 1 end
    end
    return count
end

-- Check if a quest is currently tracked on the player's screen
local function IsQuestWatched(questID)
    if C_QuestLog and C_QuestLog.GetQuestWatchType then
        return C_QuestLog.GetQuestWatchType(questID) ~= nil
    end
    return false
end

-- Determine if an itemID is wearable gear/weapons vs a cache/token/consumable
local function IsItemEquipment(itemID)
    if not itemID or not C_Item or not C_Item.GetItemInfoInstant then return false end
    local _, _, _, itemEquipLoc, _, classID = C_Item.GetItemInfoInstant(itemID)
    if classID == 2 or classID == 4 then return true end
    if itemEquipLoc and itemEquipLoc ~= "" and itemEquipLoc ~= "INVTYPE_NON_EQUIP" and itemEquipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" then
        return true
    end
    return false
end

-- Detect if a currency or item belongs to Seasonal / Holiday / Event (Category 1)
local function IsSeasonalReward(name, currencyID, itemID)
    if currencyID and SEASONAL_CURRENCY_IDS[currencyID] then return true end
    if itemID and SEASONAL_ITEM_IDS[itemID] then return true end
    if name then
        local lowerName = string.lower(name)
        for _, kw in ipairs(SEASONAL_KEYWORDS) do
            if string.find(lowerName, kw, 1, true) then
                return true
            end
        end
    end
    return false
end

-- Detect if a currency or item grants Faction Reputation or Renown (Category 3)
local function IsReputationReward(name, currencyID)
    if currencyID and C_CurrencyInfo and C_CurrencyInfo.GetFactionGrantedByCurrency then
        local factionID = C_CurrencyInfo.GetFactionGrantedByCurrency(currencyID)
        if factionID and factionID > 0 then
            return true
        end
    end
    if name then
        local lowerName = string.lower(name)
        if string.find(lowerName, "reputation", 1, true)
            or string.find(lowerName, "renown", 1, true)
            or string.find(lowerName, "commendation", 1, true) then
            return true
        end
    end
    return false
end

-- Check if a specific quest matches at least one checked filter
local function DoesQuestMatchFilter(questID)
    local qData = questRewardMap[questID]
    if not qData then return false end
    for rID, isSelected in pairs(selectedFilters) do
        if isSelected and qData.rewards[rID] then
            return true
        end
    end
    return false
end

-- Helper to apply a left-to-right transparency gradient to a texture
local function ApplyHorizontalGradient(tex, r, g, b, leftAlpha, rightAlpha)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then
        tex:SetGradient("HORIZONTAL", CreateColor(r, g, b, leftAlpha), CreateColor(r, g, b, rightAlpha))
    else
        tex:SetColorTexture(r, g, b, leftAlpha)
    end
end

-- Formats a fallback Quest Log reward line: [Quantity] [Icon] [Currency/Reward Name]
local function FormatQuestLogRewardLine(amount, icon, name, isGold, isCurrency)
    local iconSz = CONFIG.logIconSize or 14
    local amtNum = amount or 1
    local amtFormatted = BreakUpLargeNumbers and BreakUpLargeNumbers(amtNum) or tostring(amtNum)
    local qtyColor = isGold and "|cFFFFD700" or (isCurrency and "|cFF00CCFF" or "|cFFFFFFFF")
    local nameColor = isGold and "|cFFFFD700" or "|cFFE6E6E6"
    local iconTag = "|T" .. tostring(icon or 134400) .. ":" .. iconSz .. ":" .. iconSz .. ":0:-2|t"
    return string.format("%s%s|r %s %s%s|r", qtyColor, amtFormatted, iconTag, nameColor, name or "Reward")
end

-- Creates or updates a single aligned [Quantity] [Icon] [Name] sub-line inside a Quest Log reward container
local function EnsureAlignedRewardLine(container, index)
    container.rewardLines = container.rewardLines or {}
    local line = container.rewardLines[index]
    if not line then
        line = CreateFrame("Frame", nil, container)
        line:SetHeight(16)

        line.qtyText = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        line.qtyText:SetJustifyH("LEFT")
        line.qtyText:SetWordWrap(false)

        line.icon = line:CreateTexture(nil, "ARTWORK")
        line.icon:SetSize(CONFIG.logIconSize or 14, CONFIG.logIconSize or 14)

        line.nameText = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        line.nameText:SetJustifyH("LEFT")
        line.nameText:SetWordWrap(false)

        container.rewardLines[index] = line
    end
    return line
end

-- Populates vertically stacked, center-aligned [Quantity] [Icon] [Currency Name] rows inside a container
local function LayoutAlignedRewardLines(container, qData, rewardIDList, topOffset, leftIndent)
    if container.rewardLines then
        for _, l in ipairs(container.rewardLines) do
            l:Hide()
        end
    end

    if not qData or not rewardIDList or #rewardIDList == 0 then
        return 0
    end

    local iconSz = CONFIG.logIconSize or 14
    local lineH = math.max(iconSz + 2, 16)
    local iconY = CONFIG.logIconOffsetY or 0
    local maxQtyW = 0

    -- Pass 1: Set text strings and measure the widest quantity so icons align in a straight vertical column
    for idx, rID in ipairs(rewardIDList) do
        local det = qData.details and qData.details[rID]
        local line = EnsureAlignedRewardLine(container, idx)
        line:SetHeight(lineH)
        line.icon:SetSize(iconSz, iconSz)

        local amtNum = (det and det.amount) or 1
        local amtFormatted = BreakUpLargeNumbers and BreakUpLargeNumbers(amtNum) or tostring(amtNum)
        local isGold = (rID == "GOLD")
        local isCurr = (det and det.isCurrency) == true

        local qtyColor = isGold and "|cFFFFD700" or (isCurr and "|cFF00CCFF" or "|cFFFFFFFF")
        local nameColor = isGold and "|cFFFFD700" or "|cFFE6E6E6"

        line.qtyText:SetText(qtyColor .. amtFormatted .. "|r")
        line.icon:SetTexture((det and det.icon) or 134400)
        line.nameText:SetText(nameColor .. ((det and det.name) or "Reward") .. "|r")

        local w = line.qtyText:GetStringWidth() or 12
        if w > maxQtyW then
            maxQtyW = w
        end
    end

    -- Pass 2: Anchor quantity, icon, and currency name on the exact same vertical center line
    for idx = 1, #rewardIDList do
        local line = container.rewardLines[idx]
        local yPos = -(topOffset or 0) - ((idx - 1) * lineH)

        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", container, "TOPLEFT", leftIndent or 0, yPos)
        line:SetPoint("RIGHT", container, "RIGHT", -4, 0)

        line.qtyText:ClearAllPoints()
        line.qtyText:SetPoint("LEFT", line, "LEFT", 0, 0)

        line.icon:ClearAllPoints()
        line.icon:SetPoint("LEFT", line, "LEFT", maxQtyW + 5, iconY)

        line.nameText:ClearAllPoints()
        line.nameText:SetPoint("LEFT", line.icon, "RIGHT", 5, -iconY)
        line.nameText:SetPoint("RIGHT", line, "RIGHT", 0, 0)

        line:Show()
    end

    return (#rewardIDList * lineH)
end

-- Shows tooltip for a single or coalesced World Map reward icon
local function ShowCoalescedNodeTooltip(ownerFrame, node)
    if not node or not node.quests or #node.quests == 0 then return end

    GameTooltip:SetOwner(ownerFrame, "ANCHOR_RIGHT")
    local iconTag = "|T" .. tostring(node.icon or 134400) .. ":16:16:0:0|t "

    if #node.quests == 1 then
        local qID = node.quests[1].questID
        local qData = questRewardMap[qID]
        if qData then
            GameTooltip:AddLine(qData.title or "Quest Rewards", 1, 0.82, 0, true)
            if qData.header and qData.header ~= "" then
                GameTooltip:AddLine(qData.header, 0.6, 0.6, 0.6)
            end
            GameTooltip:AddLine(" ")
            local activeCount = GetActiveFilterCount()
            for _, rID in ipairs(qData.order) do
                local info = qData.details and qData.details[rID]
                if info then
                    local rIcon = "|T" .. tostring(info.icon or 134400) .. ":15:15:0:0|t "
                    local isMatched = (activeCount > 0 and selectedFilters[rID])
                    local nameColor = isMatched and "|cFFFFD100" or "|cFFFFFFFF"
                    local amtStr = BreakUpLargeNumbers and BreakUpLargeNumbers(info.amount or 1) or tostring(info.amount or 1)
                    if rID == "GOLD" then
                        GameTooltip:AddLine("|cFFFFD700" .. amtStr .. "|r " .. rIcon .. "|cFFFFD700Gold|r")
                    else
                        GameTooltip:AddLine("|cFF00CCFF" .. amtStr .. "|r " .. rIcon .. nameColor .. (info.name or "Reward") .. "|r")
                    end
                end
            end
        end
    else
        local totalAmount = 0
        for _, qEntry in ipairs(node.quests) do
            totalAmount = totalAmount + (qEntry.amount or 1)
        end
        local totalStr = BreakUpLargeNumbers and BreakUpLargeNumbers(totalAmount) or tostring(totalAmount)
        GameTooltip:AddLine(iconTag .. (node.name or "Reward"), 1, 0.82, 0)
        GameTooltip:AddLine(string.format("%d Quests Coalesced (Total: %s) — Zoom in to separate", #node.quests, totalStr), 0.55, 0.85, 1.0)
        GameTooltip:AddLine(" ")

        for idx, qEntry in ipairs(node.quests) do
            if idx <= 10 then
                local qData = questRewardMap[qEntry.questID]
                local qTitle = (qData and qData.title) or ("Quest #" .. tostring(qEntry.questID))
                local amtStr = BreakUpLargeNumbers and BreakUpLargeNumbers(qEntry.amount or 1) or tostring(qEntry.amount or 1)
                GameTooltip:AddDoubleLine("|cFFFFFFFF" .. qTitle .. "|r", "|cFF00CCFF" .. amtStr .. "|r " .. iconTag)
            end
        end
        if #node.quests > 10 then
            GameTooltip:AddLine(string.format("...and %d more quests", #node.quests - 10), 0.6, 0.6, 0.6)
        end
    end

    GameTooltip:Show()
end

-- Enumerates all active pins on the World Map safely across 12.x templates
local function ForEachWorldMapPin(callback)
    if not WorldMapFrame then return end
    if WorldMapFrame.EnumerateAllPins then
        for pin in WorldMapFrame:EnumerateAllPins() do
            callback(pin)
        end
    elseif WorldMapFrame.pinPools then
        for _, pool in pairs(WorldMapFrame.pinPools) do
            if pool.EnumerateActive then
                for pin in pool:EnumerateActive() do
                    callback(pin)
                end
            end
        end
    end
end

-- Extracts a questID from any World Map quest/world-quest/offer pin template
local function GetPinQuestID(pin)
    if not pin then return nil end
    if type(pin.questID) == "number" and pin.questID > 0 then
        return pin.questID
    end
    if type(pin.GetQuestID) == "function" then
        local ok, qID = pcall(pin.GetQuestID, pin)
        if ok and type(qID) == "number" and qID > 0 then
            return qID
        end
    end
    if pin.questLineInfo and type(pin.questLineInfo.questID) == "number" and pin.questLineInfo.questID > 0 then
        return pin.questLineInfo.questID
    end
    if pin.info and type(pin.info.questID) == "number" and pin.info.questID > 0 then
        return pin.info.questID
    end
    return nil
end

-- Extracts normalized (0..1, 0..1) canvas coordinates for a World Map pin
local function GetPinNormalizedPosition(pin, canvas)
    if not pin then return nil, nil end
    if type(pin.GetPosition) == "function" then
        local ok, x, y = pcall(pin.GetPosition, pin)
        if ok and type(x) == "number" and type(y) == "number" and x > 0 and y > 0 then
            return x, y
        end
    end
    if type(pin.normalizedX) == "number" and type(pin.normalizedY) == "number" then
        return pin.normalizedX, pin.normalizedY
    end
    if canvas and pin.GetCenter and canvas.GetLeft and canvas.GetTop then
        local px, py = pin:GetCenter()
        local cLeft, cTop = canvas:GetLeft(), canvas:GetTop()
        local cW, cH = canvas:GetWidth(), canvas:GetHeight()
        if px and py and cLeft and cTop and cW and cH and cW > 0 and cH > 0 then
            local pScale = pin:GetEffectiveScale()
            local cScale = canvas:GetEffectiveScale()
            local normX = ((px * pScale / cScale) - cLeft) / cW
            local normY = (cTop - (py * pScale / cScale)) / cH
            if normX >= 0 and normX <= 1 and normY >= 0 and normY <= 1 then
                return normX, normY
            end
        end
    end
    return nil, nil
end

-- Resolves a quest title for either log quests, task quests, or map pins
local function ResolveQuestTitle(questID, fallbackTitle)
    if fallbackTitle and fallbackTitle ~= "" then return fallbackTitle end
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local title = C_QuestLog.GetTitleForQuestID(questID)
        if title and title ~= "" then return title end
    end
    if C_TaskQuest and C_TaskQuest.GetQuestInfoByQuestID then
        local title = C_TaskQuest.GetQuestInfoByQuestID(questID)
        if title and title ~= "" then return title end
    end
    return "Quest #" .. tostring(questID)
end

-- Registers a single reward into questRewardMap and availableRewards
local function RegisterReward(questID, title, header, rewardID, name, icon, categoryGroup, sortPriority, logLineStr, amount, isMapQuest, isCurrency)
    knownRewardMeta[rewardID] = {
        id = rewardID,
        name = name,
        icon = icon,
        categoryGroup = categoryGroup,
        sortPriority = sortPriority,
    }

    if not questRewardMap[questID] then
        questRewardMap[questID] = {
            questID = questID,
            title = title or "Unknown Quest",
            header = header or "Quests",
            isMapQuest = isMapQuest == true,
            rewards = {},
            badges = {},
            details = {},
            categories = {},
            order = {}
        }
    end
    if not questRewardMap[questID].rewards[rewardID] then
        questRewardMap[questID].rewards[rewardID] = true
        questRewardMap[questID].badges[rewardID] = logLineStr
        questRewardMap[questID].details[rewardID] = {
            id = rewardID,
            name = name,
            icon = icon,
            amount = amount or 1,
            categoryGroup = categoryGroup,
            isCurrency = isCurrency == true
        }
        questRewardMap[questID].categories[rewardID] = categoryGroup
        table.insert(questRewardMap[questID].order, rewardID)

        if not rewardRegistry[rewardID] then
            rewardRegistry[rewardID] = {
                id = rewardID,
                name = name,
                icon = icon,
                categoryGroup = categoryGroup,
                sortPriority = sortPriority,
                questCount = 0
            }
            table.insert(availableRewards, rewardRegistry[rewardID])
        end
        rewardRegistry[rewardID].questCount = rewardRegistry[rewardID].questCount + 1
    end
end

-- Scans a single questID (accepted or unaccepted map quest) for currencies, items, caches, and gold
local function ScanSingleQuestRewards(questID, qTitle, headerName, isMapQuest)
    if not questID or questRewardMap[questID] then return end

    if HaveQuestRewardData and not HaveQuestRewardData(questID) and C_TaskQuest and C_TaskQuest.RequestPreloadRewardData then
        C_TaskQuest.RequestPreloadRewardData(questID)
    end

    local resolvedTitle = ResolveQuestTitle(questID, qTitle)

    -- 1. Currencies, Seasonal Currencies & Faction Reputation
    local currencies = GetQuestCurrencies(questID)
    if currencies and #currencies > 0 then
        for _, curr in ipairs(currencies) do
            local cID = "CURR_" .. tostring(curr.currencyID or curr.name or "UNKNOWN")
            local cName = curr.name or "Currency"
            local cIcon = curr.texture or 134400
            local amt = curr.totalRewardAmount or curr.numItems or 1
            local logLine = FormatQuestLogRewardLine(amt, cIcon, cName, false, true)

            local catGroup = 2
            if IsSeasonalReward(cName, curr.currencyID, nil) then
                catGroup = 1
            elseif IsReputationReward(cName, curr.currencyID) then
                catGroup = 3
            end

            RegisterReward(questID, resolvedTitle, headerName, cID, cName, cIcon, catGroup, 1, logLine, amt, isMapQuest, true)
        end
    end

    -- 2. Guaranteed Items & Choice Items
    local function ProcessQuestItem(name, tex, numItems, itemID)
        if not itemID and not name then return end
        if IsItemEquipment(itemID) then
            local icon = tex or 132739
            local eqName = name or "Equipment & Weapons"
            local logLine = FormatQuestLogRewardLine(numItems or 1, icon, eqName, false, false)
            RegisterReward(questID, resolvedTitle, headerName, "ITEM_GEAR", "Equipment & Weapons", icon, 5, 1, logLine, numItems or 1, isMapQuest, false)
        else
            if itemID and not name and C_Item and C_Item.RequestLoadItemDataByID then
                C_Item.RequestLoadItemDataByID(itemID)
            end
            local rID = "ITEM_" .. tostring(itemID or name or "ITEM")
            local metaName = knownRewardMeta[rID] and knownRewardMeta[rID].name
            local liveName = (itemID and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or nil
            local rName = name or liveName or metaName or ("Item #" .. tostring(itemID or ""))
            local rIcon = tex or (knownRewardMeta[rID] and knownRewardMeta[rID].icon) or 134400
            local logLine = FormatQuestLogRewardLine(numItems or 1, rIcon, rName, false, false)

            local catGroup = 4
            if IsSeasonalReward(rName, nil, itemID) then
                catGroup = 1
            elseif IsReputationReward(rName, nil) then
                catGroup = 3
            end

            RegisterReward(questID, resolvedTitle, headerName, rID, rName, rIcon, catGroup, 2, logLine, numItems or 1, isMapQuest, false)
        end
    end

    local numRewards = GetNumQuestLogRewards and GetNumQuestLogRewards(questID) or 0
    for r = 1, numRewards do
        local name, tex, numItems, _, _, itemID = GetQuestLogRewardInfo(r, questID)
        ProcessQuestItem(name, tex, numItems, itemID)
    end

    local numChoices = GetNumQuestLogChoices and GetNumQuestLogChoices(questID) or 0
    for c = 1, numChoices do
        local name, tex, numItems, _, _, itemID = GetQuestLogChoiceInfo(c, questID)
        ProcessQuestItem(name, tex, numItems, itemID)
    end

    -- 3. Gold
    local gold = GetQuestGold(questID)
    if gold > 0 then
        local goldIcon = "Interface\\MoneyFrame\\UI-GoldIcon"
        local logLine = FormatQuestLogRewardLine(gold, goldIcon, "Gold", true, false)
        RegisterReward(questID, resolvedTitle, headerName, "GOLD", "Gold", goldIcon, 5, 2, logLine, gold, isMapQuest, false)
    end
end

-- Scans all accepted quests AND available quests on the currently viewed local Zone Map
local function ScanQuestLogRewards()
    wipe(availableRewards)
    wipe(questRewardMap)
    wipe(rewardRegistry)

    local currentHeader = "Quests"

    -- 1. Scan Accepted Quests in the Player's Quest Log
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    for i = 1, numEntries do
        local info = C_QuestLog.GetInfo(i)
        if info then
            if info.isHeader then
                currentHeader = info.title or "Quests"
            elseif not info.isHidden and info.questID then
                ScanSingleQuestRewards(info.questID, info.title, currentHeader, false)
            end
        end
    end

    -- 2. Scan Available Quests on the Active Zone Map
    local activeMapID = (WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame:GetMapID())
        or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))

    if activeMapID and activeMapID > 0 then
        local mapInfo = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(activeMapID)
        if not mapInfo or not mapInfo.mapType or mapInfo.mapType >= 3 then
            local mapHeader = (mapInfo and mapInfo.name) or "Current Zone"

            if C_TaskQuest and C_TaskQuest.GetQuestsForPlayerByMapID then
                local taskQuests = C_TaskQuest.GetQuestsForPlayerByMapID(activeMapID)
                if taskQuests then
                    for _, taskInfo in ipairs(taskQuests) do
                        local qID = taskInfo.questId or taskInfo.questID
                        if qID and not questRewardMap[qID] then
                            ScanSingleQuestRewards(qID, nil, mapHeader, true)
                        end
                    end
                end
            end

            if C_QuestLine and C_QuestLine.GetAvailableQuestLines then
                local questLines = C_QuestLine.GetAvailableQuestLines(activeMapID)
                if questLines then
                    for _, ql in ipairs(questLines) do
                        if ql.questID and not questRewardMap[ql.questID] then
                            ScanSingleQuestRewards(ql.questID, ql.questName, mapHeader, true)
                        end
                    end
                end
            end

            if WorldMapFrame and WorldMapFrame:IsShown() then
                ForEachWorldMapPin(function(pin)
                    local qID = GetPinQuestID(pin)
                    if qID and not questRewardMap[qID] then
                        ScanSingleQuestRewards(qID, nil, mapHeader, true)
                    end
                end)
            end
        end
    end

    -- Ensure any currently checked filter stays visible in the dropdown even if its Quest Log header is collapsed
    for id, isSelected in pairs(selectedFilters) do
        if isSelected and not rewardRegistry[id] and knownRewardMeta[id] then
            local meta = knownRewardMeta[id]
            rewardRegistry[id] = {
                id = id,
                name = meta.name or id,
                icon = meta.icon or 134400,
                categoryGroup = meta.categoryGroup or 2,
                sortPriority = meta.sortPriority or 1,
                questCount = 0
            }
            table.insert(availableRewards, rewardRegistry[id])
        end
    end

    table.sort(availableRewards, function(a, b)
        if a.categoryGroup ~= b.categoryGroup then
            return a.categoryGroup < b.categoryGroup
        end
        if a.sortPriority ~= b.sortPriority then
            return a.sortPriority < b.sortPriority
        end
        return a.name < b.name
    end)
end

-- Creates or updates the Map Legend Corner Overlay in the Top-Left of the World Map Canvas
local function UpdateMapLegendUI(zoneRewardList, isLocalZoneMap)
    if not WorldMapFrame then return end

    local scrollContainer = WorldMapFrame.ScrollContainer
    if scrollContainer and not mapLegendOverlay then
        local overlay = CreateFrame("Frame", "QRF_MapLegendOverlay", scrollContainer)
        overlay:SetPoint("TOPLEFT", scrollContainer, "TOPLEFT", 12, -12)
        overlay:SetFrameStrata("HIGH")
        overlay:SetFrameLevel(90)
        overlay:EnableMouse(true)

        overlay.bg = overlay:CreateTexture(nil, "BACKGROUND")
        overlay.bg:SetAllPoints()
        overlay.bg:SetColorTexture(0.05, 0.05, 0.07, 0.90)

        overlay.topBorder = overlay:CreateTexture(nil, "BORDER")
        overlay.topBorder:SetHeight(1)
        overlay.topBorder:SetPoint("TOPLEFT", overlay, "TOPLEFT", 0, 0)
        overlay.topBorder:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", 0, 0)
        overlay.topBorder:SetColorTexture(0.65, 0.55, 0.25, 0.85)

        overlay.bottomBorder = overlay:CreateTexture(nil, "BORDER")
        overlay.bottomBorder:SetHeight(1)
        overlay.bottomBorder:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", 0, 0)
        overlay.bottomBorder:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 0, 0)
        overlay.bottomBorder:SetColorTexture(0.45, 0.45, 0.5, 0.8)

        overlay.leftBorder = overlay:CreateTexture(nil, "BORDER")
        overlay.leftBorder:SetWidth(1)
        overlay.leftBorder:SetPoint("TOPLEFT", overlay, "TOPLEFT", 0, 0)
        overlay.leftBorder:SetPoint("BOTTOMLEFT", overlay, "BOTTOMLEFT", 0, 0)
        overlay.leftBorder:SetColorTexture(0.65, 0.55, 0.25, 0.85)

        overlay.rightBorder = overlay:CreateTexture(nil, "BORDER")
        overlay.rightBorder:SetWidth(1)
        overlay.rightBorder:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", 0, 0)
        overlay.rightBorder:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 0, 0)
        overlay.rightBorder:SetColorTexture(0.45, 0.45, 0.5, 0.8)

        overlay.headerBtn = CreateFrame("Button", nil, overlay)
        overlay.headerBtn:SetHeight(20)
        overlay.headerBtn:SetPoint("TOPLEFT", overlay, "TOPLEFT", 6, -2)
        overlay.headerBtn:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -6, -2)

        overlay.title = overlay.headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        overlay.title:SetPoint("LEFT", overlay.headerBtn, "LEFT", 2, 0)
        overlay.title:SetText("|cFFFFD100Map Rewards Legend|r")

        overlay.collapseText = overlay.headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        overlay.collapseText:SetPoint("RIGHT", overlay.headerBtn, "RIGHT", -2, 0)

        overlay.divider = overlay:CreateTexture(nil, "ARTWORK")
        overlay.divider:SetHeight(1)
        overlay.divider:SetPoint("TOPLEFT", overlay, "TOPLEFT", 6, -22)
        overlay.divider:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -6, -22)
        overlay.divider:SetColorTexture(0.45, 0.45, 0.5, 0.6)

        overlay.headerBtn:SetScript("OnClick", function()
            legendCollapsed = not legendCollapsed
            SaveState()
            UpdateMapLegendUI(activeZoneRewards, true)
        end)

        mapLegendOverlay = overlay
    end

    if mapLegendOverlay then
        mapLegendOverlay:ClearAllPoints()
        mapLegendOverlay:SetPoint("TOPLEFT", scrollContainer, "TOPLEFT", 12, -12)

        for _, row in ipairs(legendOverlayRowPool) do
            row:Hide()
        end

        if showMapLegend and isLocalZoneMap and zoneRewardList and #zoneRewardList > 0 then
            mapLegendOverlay.collapseText:SetText(legendCollapsed and "|cFFFFD100[+]|r" or "|cFFFFD100[-]|r")

            if legendCollapsed then
                mapLegendOverlay.divider:Hide()
                mapLegendOverlay:SetSize(162, 24)
            else
                mapLegendOverlay.divider:Show()
                local yOffset = -26
                local rowH = 18
                local maxW = 165
                local shownCount = math.min(#zoneRewardList, 10)

                for i = 1, shownCount do
                    local rInfo = zoneRewardList[i]
                    local row = legendOverlayRowPool[i]
                    if not row then
                        row = CreateFrame("Button", nil, mapLegendOverlay)
                        row:SetHeight(rowH)
                        row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
                        row.highlight:SetAllPoints()
                        row.highlight:SetColorTexture(0.3, 0.6, 1.0, 0.22)
                        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                        row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
                        row.text:SetJustifyH("LEFT")
                        row.text:SetWordWrap(false)
                        legendOverlayRowPool[i] = row
                    end

                    row:SetPoint("TOPLEFT", mapLegendOverlay, "TOPLEFT", 6, yOffset)
                    row:SetPoint("TOPRIGHT", mapLegendOverlay, "TOPRIGHT", -6, yOffset)

                    local isSelected = selectedFilters[rInfo.id] == true
                    local nameColor = isSelected and "|cFFFFD100" or "|cFFDDDDDD"
                    local checkMark = isSelected and "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12:0:0|t " or ""
                    local iconStr = "|T" .. tostring(rInfo.icon or 134400) .. ":15:15:0:0|t "
                    row.text:SetText(string.format("%s%s%s%s|r |cFF999999(%d)|r", checkMark, iconStr, nameColor, rInfo.name or "Reward", rInfo.count or 1))

                    local textW = (row.text:GetStringWidth() or 120) + 22
                    if textW > maxW then maxW = textW end

                    row:SetScript("OnClick", function()
                        if selectedFilters[rInfo.id] then
                            selectedFilters[rInfo.id] = nil
                        else
                            selectedFilters[rInfo.id] = true
                        end
                        ApplyFilterChanges()
                        if sharedMenuFrame and sharedMenuFrame:IsShown() then
                            RebuildDropdownMenu(sharedMenuFrame, false)
                        end
                    end)
                    row:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:AddLine(iconStr .. (rInfo.name or "Reward"), 1, 0.82, 0)
                        GameTooltip:AddLine("Click to toggle this reward filter on the map.", 0.8, 0.8, 0.8)
                        GameTooltip:Show()
                    end)
                    row:SetScript("OnLeave", function()
                        GameTooltip:Hide()
                    end)

                    row:Show()
                    yOffset = yOffset - rowH
                end

                mapLegendOverlay:SetSize(math.min(maxW, 240), math.abs(yOffset) + 6)
            end
            mapLegendOverlay:Show()
        else
            mapLegendOverlay:Hide()
        end
    end
end

-- Acquires or creates a map canvas reward icon marker
local function GetOrCreateMapMarker(index, canvas)
    local marker = mapMarkerPool[index]
    if not marker then
        marker = CreateFrame("Frame", nil, canvas)
        marker:SetSize(CONFIG.mapIconSize, CONFIG.mapIconSize)
        marker:EnableMouse(true)
        if marker.SetPassThroughButtons then
            pcall(function() marker:SetPassThroughButtons("LeftButton", "RightButton") end)
        end

        marker.icon = marker:CreateTexture(nil, "ARTWORK")
        marker.icon:SetAllPoints()

        marker.countBadge = marker:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        marker.countBadge:SetPoint("BOTTOMRIGHT", marker, "BOTTOMRIGHT", 2, -2)
        marker.countBadge:SetJustifyH("RIGHT")

        marker:SetScript("OnEnter", function(self)
            if self.nodeData then
                ShowCoalescedNodeTooltip(self, self.nodeData)
            end
        end)
        marker:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        mapMarkerPool[index] = marker
    end
    marker:SetParent(canvas)
    marker:SetFrameStrata("HIGH")
    marker:SetFrameLevel(80)
    return marker
end

-- Updates World Map quest pins with dynamic zoom-aware icon coalescing & orderly buffered line layout
local function UpdateWorldMapPins()
    for _, marker in ipairs(mapMarkerPool) do
        marker:Hide()
    end

    if not WorldMapFrame or not WorldMapFrame:IsShown() then return end

    local activeCount = GetActiveFilterCount()
    local mapID = WorldMapFrame:GetMapID()
    local mapInfo = mapID and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    local isLocalZoneMap = (not mapInfo or not mapInfo.mapType or mapInfo.mapType >= 3)
    local mapHeader = (mapInfo and mapInfo.name) or "Current Zone"
    local canvas = WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas()

    local cWidth = (canvas and canvas:GetWidth()) or 1000
    local cHeight = (canvas and canvas:GetHeight()) or 668
    local cScale = (WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.GetCanvasScale and WorldMapFrame.ScrollContainer:GetCanvasScale())
        or (canvas and canvas:GetScale()) or 1
    if cScale <= 0 then cScale = 1 end

    local nodesByReward = {}
    local zoneRewardCounts = {}
    wipe(activeZoneRewards)

    ForEachWorldMapPin(function(pin)
        local questID = GetPinQuestID(pin)
        if questID and isLocalZoneMap then
            if not questRewardMap[questID] then
                ScanSingleQuestRewards(questID, nil, mapHeader, true)
            end

            local qData = questRewardMap[questID]
            local matches = (activeCount == 0) or DoesQuestMatchFilter(questID)

            -- Track all rewards available on the current zone map for the Top-Left Map Legend Overlay
            if qData and qData.order then
                for _, rID in ipairs(qData.order) do
                    local det = qData.details and qData.details[rID]
                    if det then
                        if not zoneRewardCounts[rID] then
                            zoneRewardCounts[rID] = {
                                id = rID,
                                name = det.name,
                                icon = det.icon,
                                category = det.categoryGroup or 5,
                                count = 0
                            }
                            table.insert(activeZoneRewards, zoneRewardCounts[rID])
                        end
                        zoneRewardCounts[rID].count = zoneRewardCounts[rID].count + 1
                    end
                end
            end

            -- 1. Apply Map Pin Filtering (Dim or Hide non-matching quest pins)
            if activeCount > 0 and filterMapPins then
                if matches then
                    pin:SetAlpha(1.0)
                    if pin.qrfSuppressed then
                        pin:EnableMouse(true)
                        pin.qrfSuppressed = false
                    end
                else
                    if hideUnmatchedMapPins then
                        pin:SetAlpha(0.0)
                        pin:EnableMouse(false)
                        pin.qrfSuppressed = true
                    else
                        pin:SetAlpha(CONFIG.dimmedPinAlpha)
                        if pin.qrfSuppressed then
                            pin:EnableMouse(true)
                            pin.qrfSuppressed = false
                        end
                    end
                end
            else
                pin:SetAlpha(1.0)
                if pin.qrfSuppressed then
                    pin:EnableMouse(true)
                    pin.qrfSuppressed = false
                end
            end

            -- 2. Collect candidate icon nodes in zoomed screen-space pixels for coalescing
            if showMapBadges and canvas and qData and #qData.order > 0 and (matches or not (activeCount > 0 and filterMapPins and hideUnmatchedMapPins)) then
                local nx, ny = GetPinNormalizedPosition(pin, canvas)
                if nx and ny then
                    local visX = nx * cWidth * cScale
                    local visY = (ny * cHeight * cScale) + CONFIG.pinUnderOffset

                    local chosenRewards = {}
                    if activeCount > 0 and matches then
                        for _, rID in ipairs(qData.order) do
                            if selectedFilters[rID] and #chosenRewards < 2 then
                                table.insert(chosenRewards, rID)
                            end
                        end
                    else
                        local sortedRewards = {}
                        for _, rID in ipairs(qData.order) do
                            table.insert(sortedRewards, rID)
                        end
                        table.sort(sortedRewards, function(a, b)
                            local catA = qData.categories[a] or 5
                            local catB = qData.categories[b] or 5
                            local prioA = MAP_BADGE_CATEGORY_PRIORITY[catA] or 9
                            local prioB = MAP_BADGE_CATEGORY_PRIORITY[catB] or 9
                            if prioA ~= prioB then return prioA < prioB end
                            return tostring(a) < tostring(b)
                        end)
                        for _, rID in ipairs(sortedRewards) do
                            if #chosenRewards < 2 and (rID ~= "GOLD" or #sortedRewards == 1) then
                                table.insert(chosenRewards, rID)
                            end
                        end
                    end

                    for _, rID in ipairs(chosenRewards) do
                        local det = qData.details and qData.details[rID]
                        if det then
                            nodesByReward[rID] = nodesByReward[rID] or {}
                            table.insert(nodesByReward[rID], {
                                rID = rID,
                                name = det.name,
                                icon = det.icon,
                                category = det.categoryGroup or 5,
                                visX = visX,
                                visY = visY,
                                quests = {
                                    { questID = questID, amount = det.amount or 1 }
                                }
                            })
                        end
                    end
                end
            end
        else
            if pin.qrfSuppressed then
                pin:SetAlpha(1.0)
                pin:EnableMouse(true)
                pin.qrfSuppressed = false
            end
        end
    end)

    -- Sort activeZoneRewards for the Top-Left Map Legend Overlay
    table.sort(activeZoneRewards, function(a, b)
        local prioA = MAP_BADGE_CATEGORY_PRIORITY[a.category] or 9
        local prioB = MAP_BADGE_CATEGORY_PRIORITY[b.category] or 9
        if prioA ~= prioB then return prioA < prioB end
        return (a.name or "") < (b.name or "")
    end)

    UpdateMapLegendUI(activeZoneRewards, isLocalZoneMap)

    if not showMapBadges or not isLocalZoneMap or not canvas then return end

    -- PHASE 1: Coalesce colliding icons of the SAME reward type based on current zoom scale
    local coalesceDist = CONFIG.mapIconSize + CONFIG.coalescePadding
    local coalesceDistSq = coalesceDist * coalesceDist
    local allCoalescedNodes = {}

    for _, list in pairs(nodesByReward) do
        local merged = true
        while merged and #list > 1 do
            merged = false
            local bestI, bestJ, bestD2 = nil, nil, coalesceDistSq
            for i = 1, #list - 1 do
                for j = i + 1, #list do
                    local dx = list[i].visX - list[j].visX
                    local dy = list[i].visY - list[j].visY
                    local d2 = (dx * dx) + (dy * dy)
                    if d2 <= bestD2 then
                        bestD2 = d2
                        bestI = i
                        bestJ = j
                    end
                end
            end

            if bestI and bestJ then
                local nodeA = list[bestI]
                local nodeB = list[bestJ]
                local wA = #nodeA.quests
                local wB = #nodeB.quests
                local totalW = wA + wB

                nodeA.visX = ((nodeA.visX * wA) + (nodeB.visX * wB)) / totalW
                nodeA.visY = ((nodeA.visY * wA) + (nodeB.visY * wB)) / totalW

                local seenQ = {}
                for _, q in ipairs(nodeA.quests) do seenQ[q.questID] = true end
                for _, q in ipairs(nodeB.quests) do
                    if not seenQ[q.questID] then
                        table.insert(nodeA.quests, q)
                    end
                end

                table.remove(list, bestJ)
                merged = true
            end
        end

        for _, survivingNode in ipairs(list) do
            table.insert(allCoalescedNodes, survivingNode)
        end
    end

    -- PHASE 2: When multiple coalesced/different-type icons collide, approximate their shared center
    -- and arrange them orderly in a horizontal line with a clean buffer gap
    local stride = CONFIG.mapIconSize + CONFIG.mapIconBuffer
    local visited = {}

    for i = 1, #allCoalescedNodes do
        if not visited[i] then
            local group = { allCoalescedNodes[i] }
            visited[i] = true
            local queue = { i }

            while #queue > 0 do
                local currIdx = table.remove(queue, 1)
                local currNode = allCoalescedNodes[currIdx]
                for j = 1, #allCoalescedNodes do
                    if not visited[j] then
                        local otherNode = allCoalescedNodes[j]
                        if math.abs(currNode.visX - otherNode.visX) < stride and math.abs(currNode.visY - otherNode.visY) < stride then
                            visited[j] = true
                            table.insert(group, otherNode)
                            table.insert(queue, j)
                        end
                    end
                end
            end

            if #group == 1 then
                group[1].finalX = group[1].visX
                group[1].finalY = group[1].visY
            else
                local sumX, sumY = 0, 0
                for _, n in ipairs(group) do
                    sumX = sumX + n.visX
                    sumY = sumY + n.visY
                end
                local centerX = sumX / #group
                local centerY = sumY / #group

                table.sort(group, function(a, b)
                    local prioA = MAP_BADGE_CATEGORY_PRIORITY[a.category] or 9
                    local prioB = MAP_BADGE_CATEGORY_PRIORITY[b.category] or 9
                    if prioA ~= prioB then return prioA < prioB end
                    return tostring(a.rID) < tostring(b.rID)
                end)

                local startX = centerX - ((#group - 1) * stride * 0.5)
                for idx, n in ipairs(group) do
                    n.finalX = startX + ((idx - 1) * stride)
                    n.finalY = centerY
                end
            end
        end
    end

    -- PHASE 3: Render the coalesced & buffered icon markers onto the World Map canvas
    local invScale = 1 / cScale
    for idx, node in ipairs(allCoalescedNodes) do
        local marker = GetOrCreateMapMarker(idx, canvas)
        marker:SetScale(invScale)
        marker:ClearAllPoints()
        marker:SetPoint("CENTER", canvas, "TOPLEFT", node.finalX, -node.finalY)
        marker.icon:SetTexture(node.icon or 134400)
        marker.nodeData = node

        if #node.quests > 1 then
            marker.countBadge:SetText("|cFFFFD100" .. #node.quests .. "|r")
            marker.countBadge:Show()
        else
            marker.countBadge:SetText("")
            marker.countBadge:Hide()
        end

        marker:Show()
    end
end

-- Synchronizes the on-screen Objective Tracker based on active filters
local function SyncObjectiveTracker()
    if isSyncingTracker or not C_QuestLog then return end
    isSyncingTracker = true

    local activeCount = GetActiveFilterCount()

    if activeCount > 0 and autoUntrack then
        if not savedWatchedQuests then
            savedWatchedQuests = {}
            local numEntries = C_QuestLog.GetNumQuestLogEntries()
            for i = 1, numEntries do
                local info = C_QuestLog.GetInfo(i)
                if info and not info.isHeader and info.questID then
                    if IsQuestWatched(info.questID) then
                        savedWatchedQuests[info.questID] = true
                    end
                end
            end
        end

        local numEntries = C_QuestLog.GetNumQuestLogEntries()
        for i = 1, numEntries do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and not info.isHidden and info.questID then
                local qID = info.questID
                local matches = DoesQuestMatchFilter(qID)
                local currentlyWatched = IsQuestWatched(qID)

                if not matches and currentlyWatched then
                    C_QuestLog.RemoveQuestWatch(qID)
                elseif matches and not currentlyWatched then
                    C_QuestLog.AddQuestWatch(qID)
                end
            end
        end
    else
        if savedWatchedQuests then
            local numEntries = C_QuestLog.GetNumQuestLogEntries()
            for i = 1, numEntries do
                local info = C_QuestLog.GetInfo(i)
                if info and not info.isHeader and not info.isHidden and info.questID then
                    local qID = info.questID
                    local shouldWatch = savedWatchedQuests[qID] == true
                    local currentlyWatched = IsQuestWatched(qID)

                    if shouldWatch and not currentlyWatched then
                        C_QuestLog.AddQuestWatch(qID)
                    elseif not shouldWatch and currentlyWatched then
                        C_QuestLog.RemoveQuestWatch(qID)
                    end
                end
            end
            savedWatchedQuests = nil
        end
    end

    SaveState()
    isSyncingTracker = false
end

-- Updates button labels on both the Quest Log and the Objective Tracker banner
local function UpdateAllButtonLabels()
    local activeCount = GetActiveFilterCount()
    local hasSnapshot = (savedWatchedQuests ~= nil)

    local singleName = nil
    if activeCount == 1 then
        for id, isSelected in pairs(selectedFilters) do
            if isSelected then
                singleName = (knownRewardMeta[id] and knownRewardMeta[id].name) or "1 Selected"
                break
            end
        end
    end

    if questLogBar then
        if activeCount == 0 then
            questLogBar.dropdownBtn:SetText(CONFIG.QUESTLOG_BTN_ALL)
        elseif activeCount == 1 and singleName then
            local short = string.len(singleName) > 16 and (string.sub(singleName, 1, 14) .. "..") or singleName
            questLogBar.dropdownBtn:SetText("Filter: " .. short)
        else
            questLogBar.dropdownBtn:SetText("Rewards (" .. activeCount .. " active)")
        end

        if activeCount > 0 or hasSnapshot then
            questLogBar.resetBtn:Enable()
        else
            questLogBar.resetBtn:Disable()
        end
    end

    if trackerFilterBtn then
        if activeCount == 0 then
            trackerFilterBtn:SetText(CONFIG.TRACKER_BTN_ALL)
        elseif activeCount == 1 and singleName then
            local short = string.len(singleName) > 11 and (string.sub(singleName, 1, 9) .. "..") or singleName
            trackerFilterBtn:SetText("|cFFFFD100" .. short .. "|r")
        else
            trackerFilterBtn:SetText("|cFFFFD100Filter (" .. activeCount .. ")|r")
        end
    end
end

-- Renders the flat override list in the Quest Log with aligned [Quantity] [Icon] [Currency Name] sub-rows
local function RenderCustomFilteredList()
    if not QuestScrollFrame or not QuestScrollFrame.qrfCustomList then return end
    local listFrame = QuestScrollFrame.qrfCustomList

    wipe(matchingQuestsList)
    for questID, qData in pairs(questRewardMap) do
        if not qData.isMapQuest and DoesQuestMatchFilter(questID) then
            table.insert(matchingQuestsList, qData)
        end
    end

    table.sort(matchingQuestsList, function(a, b)
        if a.header ~= b.header then return a.header < b.header end
        return a.title < b.title
    end)

    local totalMatches = #matchingQuestsList
    listFrame.headerText:SetText(string.format("|cFFFFD100Filtered Quests (%d matching)|r", totalMatches))

    if customScrollOffset > math.max(0, totalMatches - MAX_CUSTOM_ROWS) then
        customScrollOffset = math.max(0, totalMatches - MAX_CUSTOM_ROWS)
    end

    local yCursor = -28
    local listBottomLimit = -(listFrame:GetHeight() - 24)

    for i = 1, MAX_CUSTOM_ROWS do
        local row = customListRowPool[i]
        local dataIndex = i + customScrollOffset
        local qData = matchingQuestsList[dataIndex]

        if qData and yCursor > listBottomLimit then
            local matchedRewardIDs = {}
            for _, rID in ipairs(qData.order) do
                if selectedFilters[rID] then
                    table.insert(matchedRewardIDs, rID)
                end
            end

            local watchedIcon = IsQuestWatched(qData.questID) and "|TInterface\\RaidFrame\\ReadyCheck-Ready:13:13:0:0|t " or ""
            row.titleText:SetText(watchedIcon .. "|cFFFFFFFF" .. qData.title .. "|r")
            row.zoneText:SetText("|cFF888888" .. qData.header .. "|r")
            if row.badgeText then row.badgeText:SetText("") end

            local rewardsHeight = LayoutAlignedRewardLines(row, qData, matchedRewardIDs, 33, 6)
            local dynamicHeight = math.max(44, 33 + rewardsHeight + 5)

            row:SetHeight(dynamicHeight)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 8, yCursor)
            row:SetPoint("TOPRIGHT", listFrame, "TOPRIGHT", -8, yCursor)
            yCursor = yCursor - (dynamicHeight + 2)

            row:SetScript("OnClick", function()
                if IsShiftKeyDown() then
                    if IsQuestWatched(qData.questID) then
                        C_QuestLog.RemoveQuestWatch(qData.questID)
                    else
                        C_QuestLog.AddQuestWatch(qData.questID)
                    end
                    RenderCustomFilteredList()
                else
                    if sharedMenuFrame then sharedMenuFrame:Hide() end
                    if QuestMapFrame_OpenToQuestDetails then
                        QuestMapFrame_OpenToQuestDetails(qData.questID)
                    elseif QuestMapFrame_ShowQuestDetails then
                        QuestMapFrame_ShowQuestDetails(qData.questID)
                    end
                end
            end)

            row:Show()
        else
            row:Hide()
        end
    end

    if totalMatches > MAX_CUSTOM_ROWS then
        listFrame.scrollHint:SetText(string.format("Showing %d-%d of %d (Scroll wheel for more)", customScrollOffset + 1, math.min(totalMatches, customScrollOffset + MAX_CUSTOM_ROWS), totalMatches))
        listFrame.scrollHint:Show()
    else
        listFrame.scrollHint:Hide()
    end
end

-- Acquires or creates a VerticalLayoutFrame-compatible reward row inside QuestScrollFrame.Contents
local function GetOrCreateQuestLogRewardRow(index, parentContents)
    local row = questLogRewardRowPool[index]
    if not row then
        row = CreateFrame("Frame", nil, parentContents)
        row:SetWidth(230)
        row.isQrfRewardRow = true
        row.leftPadding = 29
        row.topPadding = 2
        row.bottomPadding = 4

        questLogRewardRowPool[index] = row
    end
    row:SetParent(parentContents)
    return row
end

-- Master UI update (Injects aligned [Quantity] [Icon] [Currency Name] rows below each quest's objectives)
local function UpdateQuestLogUI()
    ScanQuestLogRewards()
    UpdateAllButtonLabels()
    UpdateWorldMapPins()

    for _, rRow in ipairs(questLogRewardRowPool) do
        rRow:Hide()
        rRow.layoutIndex = nil
    end

    if not QuestScrollFrame then return end

    local activeCount = GetActiveFilterCount()
    local customList = QuestScrollFrame.qrfCustomList

    if activeCount > 0 then
        if customList then
            RenderCustomFilteredList()
            customList:Show()
        end
    else
        if customList then
            customList:Hide()
        end

        local contents = QuestScrollFrame.Contents
        if contents and QuestScrollFrame.titleFramePool then
            local isObjective = {}
            if QuestScrollFrame.objectiveFramePool then
                for obj in QuestScrollFrame.objectiveFramePool:EnumerateActive() do
                    isObjective[obj] = true
                end
            end

            local nonObjectiveIndices = {}
            local objectiveIndices = {}
            local children = { contents:GetChildren() }
            for _, child in ipairs(children) do
                if child:IsShown() and type(child.layoutIndex) == "number" and not child.isQrfRewardRow then
                    if isObjective[child] then
                        table.insert(objectiveIndices, child.layoutIndex)
                    else
                        table.insert(nonObjectiveIndices, child.layoutIndex)
                    end
                end
            end
            table.sort(nonObjectiveIndices)
            table.sort(objectiveIndices)

            local rowPoolIdx = 0

            for button in QuestScrollFrame.titleFramePool:EnumerateActive() do
                if button then
                    if button.qrfBadge then
                        button.qrfBadge:Hide()
                    end

                    local questID = button.questID or (button.info and button.info.questID)
                    local qData = questID and questRewardMap[questID]
                    local bLayoutIdx = button.layoutIndex

                    if CONFIG.showDefaultLogBadges and questID and type(bLayoutIdx) == "number" and not (button.info and button.info.isHeader) and qData then
                        local displayRewardIDs = {}
                        for _, rID in ipairs(qData.order) do
                            if #displayRewardIDs < 4 and (rID ~= "GOLD" or #qData.order == 1) then
                                table.insert(displayRewardIDs, rID)
                            end
                        end

                        if #displayRewardIDs > 0 then
                            local nextMajorIdx = math.huge
                            for _, majorIdx in ipairs(nonObjectiveIndices) do
                                if majorIdx > bLayoutIdx then
                                    nextMajorIdx = majorIdx
                                    break
                                end
                            end

                            local lastQuestElementIdx = bLayoutIdx
                            for _, objIdx in ipairs(objectiveIndices) do
                                if objIdx > bLayoutIdx and objIdx < nextMajorIdx then
                                    if objIdx > lastQuestElementIdx then
                                        lastQuestElementIdx = objIdx
                                    end
                                end
                            end

                            rowPoolIdx = rowPoolIdx + 1
                            local rewardRow = GetOrCreateQuestLogRewardRow(rowPoolIdx, contents)
                            rewardRow.layoutIndex = lastQuestElementIdx + 0.5

                            local totalH = LayoutAlignedRewardLines(rewardRow, qData, displayRewardIDs, 0, 0)
                            rewardRow:SetHeight(math.max(16, totalH))
                            rewardRow:Show()
                        end
                    end
                    button:SetAlpha(1.0)
                end
            end

            if contents.Layout then
                contents:Layout()
            end
        end
    end
end

-- Applies filter changes and saves state
ApplyFilterChanges = function()
    customScrollOffset = 0
    ScanQuestLogRewards()
    SyncObjectiveTracker()
    UpdateQuestLogUI()
    SaveState()
end

-- Populates the categorized, collapsible multi-select dropdown menu
RebuildDropdownMenu = function(menuFrame, searchJustChanged)
    if not menuFrame then return end
    ScanQuestLogRewards()
    wipe(dropdownDisplayList)

    local query = string.lower(strtrim(dropdownSearchText or ""))
    local lastCategory = nil
    local totalMatchingRewards = 0
    local maxWidth = 270
    local categoryRewardCounts = {}

    for _, reward in ipairs(availableRewards) do
        if menuFrame.measureLabel then
            menuFrame.measureLabel:SetText(reward.name .. " (" .. reward.questCount .. ")")
            local w = menuFrame.measureLabel:GetStringWidth() + 76
            if w > maxWidth then maxWidth = w end
        end

        if query == "" or string.find(string.lower(reward.name), query, 1, true) then
            local cat = reward.categoryGroup
            categoryRewardCounts[cat] = (categoryRewardCounts[cat] or 0) + 1
            if query ~= "" and searchJustChanged and collapsedCategories[cat] then
                collapsedCategories[cat] = false
            end
        end
    end

    for _, reward in ipairs(availableRewards) do
        if query == "" or string.find(string.lower(reward.name), query, 1, true) then
            local cat = reward.categoryGroup
            if showCategories and cat ~= lastCategory then
                lastCategory = cat
                table.insert(dropdownDisplayList, {
                    isHeader = true,
                    categoryGroup = cat,
                    title = CATEGORY_NAMES[cat] or "Rewards",
                    itemCount = categoryRewardCounts[cat] or 0
                })
            end

            totalMatchingRewards = totalMatchingRewards + 1

            if not showCategories or not collapsedCategories[cat] then
                table.insert(dropdownDisplayList, {
                    isHeader = false,
                    reward = reward,
                    rewardIndex = totalMatchingRewards
                })
            end
        end
    end

    if menuFrame.groupToggleBtn then
        menuFrame.groupToggleBtn:SetText(showCategories and "Group: ON" or "Group: OFF")
    end

    for _, row in ipairs(dropdownRowPool) do
        row:Hide()
    end

    local rowHeight = 21
    local yOffset = -56
    local totalEntries = #dropdownDisplayList

    local maxScroll = math.max(0, totalEntries - MAX_DROPDOWN_ROWS)
    if dropdownScrollOffset > maxScroll then
        dropdownScrollOffset = maxScroll
    end

    if totalEntries == 0 then
        local emptyRow = dropdownRowPool[1]
        if not emptyRow then
            emptyRow = CreateFrame("Button", nil, menuFrame)
            emptyRow:SetHeight(rowHeight)
            emptyRow.check = CreateFrame("CheckButton", nil, emptyRow, "UICheckButtonTemplate")
            emptyRow.check:SetSize(20, 20)
            emptyRow.check:SetPoint("LEFT", emptyRow, "LEFT", 4, 0)
            emptyRow.label = emptyRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            emptyRow.label:SetPoint("LEFT", emptyRow.check, "RIGHT", 4, 0)
            emptyRow.rightText = emptyRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            emptyRow.rightText:SetPoint("RIGHT", emptyRow, "RIGHT", CONFIG.collapseRightOffset, 0)
            dropdownRowPool[1] = emptyRow
        end
        emptyRow:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 6, yOffset)
        emptyRow:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -6, yOffset)
        emptyRow.check:Hide()
        if emptyRow.rightText then emptyRow.rightText:SetText("") end
        if emptyRow.headerBg then emptyRow.headerBg:Hide() end
        if emptyRow.headerLine then emptyRow.headerLine:Hide() end
        emptyRow.label:ClearAllPoints()
        emptyRow.label:SetPoint("LEFT", emptyRow, "LEFT", 8, 0)
        emptyRow.label:SetText(query ~= "" and "|cFF888888No matching rewards found|r" or "|cFF888888No rewards in active quests|r")
        emptyRow:Show()
        yOffset = yOffset - rowHeight
        menuFrame.scrollInfo:Hide()
    else
        local visibleCount = math.min(totalEntries, MAX_DROPDOWN_ROWS)
        local firstVisibleRewardIdx = nil
        local lastVisibleRewardIdx = nil

        for i = 1, visibleCount do
            local entry = dropdownDisplayList[i + dropdownScrollOffset]
            local row = dropdownRowPool[i]
            if not row then
                row = CreateFrame("Button", nil, menuFrame)
                row:SetHeight(rowHeight)
                row:EnableMouseWheel(true)
                row:SetScript("OnMouseWheel", function(_, delta)
                    local mScroll = math.max(0, #dropdownDisplayList - MAX_DROPDOWN_ROWS)
                    dropdownScrollOffset = math.min(mScroll, math.max(0, dropdownScrollOffset - delta))
                    RebuildDropdownMenu(menuFrame, false)
                end)

                row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
                row.highlight:SetAllPoints()
                ApplyHorizontalGradient(row.highlight, 0.3, 0.6, 1.0, 0.28, 0.05)

                row.headerBg = row:CreateTexture(nil, "BACKGROUND")
                row.headerBg:SetAllPoints()
                ApplyHorizontalGradient(row.headerBg, 0.22, 0.18, 0.06, 0.85, 0.15)

                row.headerLine = row:CreateTexture(nil, "ARTWORK")
                row.headerLine:SetHeight(1)
                row.headerLine:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 0)
                row.headerLine:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -12, 0)
                ApplyHorizontalGradient(row.headerLine, 0.8, 0.65, 0.2, 0.8, 0.1)

                row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
                row.check:SetSize(20, 20)

                row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.label:SetJustifyH("LEFT")

                row.rightText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                row.rightText:SetPoint("RIGHT", row, "RIGHT", CONFIG.collapseRightOffset, 0)
                row.rightText:SetJustifyH("RIGHT")

                dropdownRowPool[i] = row
            end

            row:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 6, yOffset)
            row:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -6, yOffset)

            if entry.isHeader then
                row.headerBg:Show()
                row.headerLine:Show()
                row.check:Show()
                row.check:ClearAllPoints()
                row.check:SetPoint("LEFT", row, "LEFT", 2, 0)
                row.check:SetMouseClickEnabled(true)

                local allSelected = true
                local hasAny = false
                for _, r in ipairs(availableRewards) do
                    if r.categoryGroup == entry.categoryGroup and (query == "" or string.find(string.lower(r.name), query, 1, true)) then
                        hasAny = true
                        if not selectedFilters[r.id] then
                            allSelected = false
                            break
                        end
                    end
                end
                row.check:SetChecked(hasAny and allSelected)

                row.check:SetScript("OnClick", function()
                    local shouldSelectAll = not (hasAny and allSelected)
                    for _, r in ipairs(availableRewards) do
                        if r.categoryGroup == entry.categoryGroup and (query == "" or string.find(string.lower(r.name), query, 1, true)) then
                            if shouldSelectAll then
                                selectedFilters[r.id] = true
                            else
                                selectedFilters[r.id] = nil
                            end
                        end
                    end
                    ApplyFilterChanges()
                    RebuildDropdownMenu(menuFrame, false)
                end)

                local isCollapsed = collapsedCategories[entry.categoryGroup] == true
                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
                row.label:SetText("|cFFFFD100" .. entry.title .. "|r |cFFAAAAAA(" .. entry.itemCount .. ")|r")
                row.rightText:SetText(isCollapsed and "|cFFFFD100[+]|r" or "|cFFFFD100[-]|r")

                row:SetScript("OnClick", function()
                    collapsedCategories[entry.categoryGroup] = not collapsedCategories[entry.categoryGroup]
                    SaveState()
                    RebuildDropdownMenu(menuFrame, false)
                end)
            else
                local reward = entry.reward
                if not firstVisibleRewardIdx then firstVisibleRewardIdx = entry.rewardIndex end
                lastVisibleRewardIdx = entry.rewardIndex

                row.headerBg:Hide()
                row.headerLine:Hide()
                row.rightText:SetText("")

                row.check:Show()
                row.check:ClearAllPoints()
                row.check:SetPoint("LEFT", row, "LEFT", showCategories and 10 or 2, 0)
                row.check:SetMouseClickEnabled(false)
                row.check:SetScript("OnClick", nil)
                row.check:SetChecked(selectedFilters[reward.id] == true)

                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", row.check, "RIGHT", 2, 0)

                local iconStr = reward.icon and ("|T" .. reward.icon .. ":14:14:0:0|t ") or ""
                row.label:SetText(iconStr .. reward.name .. " |cFFBBBBBB(" .. reward.questCount .. ")|r")

                row:SetScript("OnClick", function()
                    if selectedFilters[reward.id] then
                        selectedFilters[reward.id] = nil
                    else
                        selectedFilters[reward.id] = true
                    end
                    ApplyFilterChanges()
                    RebuildDropdownMenu(menuFrame, false)
                end)
            end

            row:Show()
            yOffset = yOffset - rowHeight
        end

        if totalEntries > MAX_DROPDOWN_ROWS then
            menuFrame.scrollInfo:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 12, yOffset - 2)
            if firstVisibleRewardIdx and lastVisibleRewardIdx then
                menuFrame.scrollInfo:SetText(string.format(
                    "|cFFAAAAAAViewing %d-%d of %d rewards (Scroll wheel)|r",
                    firstVisibleRewardIdx,
                    lastVisibleRewardIdx,
                    totalMatchingRewards
                ))
            else
                menuFrame.scrollInfo:SetText(string.format(
                    "|cFFAAAAAA%d matching rewards (Scroll wheel)|r",
                    totalMatchingRewards
                ))
            end
            menuFrame.scrollInfo:Show()
            yOffset = yOffset - 16
        else
            menuFrame.scrollInfo:Hide()
        end
    end

    menuFrame.footerDivider:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 6, yOffset - 4)
    menuFrame.footerDivider:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -6, yOffset - 4)

    -- Row 1: Show Map reward icons (coalesced zoom-aware badges)
    local footerY = yOffset - 8
    menuFrame.mapBadgeRow:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 6, footerY)
    menuFrame.mapBadgeRow:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -8, footerY)
    menuFrame.mapBadgeRow.check:SetChecked(showMapBadges)

    -- Row 2: Show Map Legend overlay in top-left corner
    footerY = footerY - 20
    menuFrame.mapLegendRow:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 6, footerY)
    menuFrame.mapLegendRow:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -8, footerY)
    menuFrame.mapLegendRow.check:SetChecked(showMapLegend)

    -- Row 3: Filter Local Map Pins + [Dim] / [Hide] mode toggle
    footerY = footerY - 20
    menuFrame.mapFilterRow:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 6, footerY)
    menuFrame.mapFilterRow:SetPoint("RIGHT", menuFrame.mapModeBtn, "LEFT", -4, 0)
    menuFrame.mapFilterRow.check:SetChecked(filterMapPins)
    menuFrame.mapModeBtn:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -8, footerY - 2)
    menuFrame.mapModeBtn:SetText(hideUnmatchedMapPins and "Mode: Hide" or "Mode: Dim")

    -- Row 4: Auto-untrack others + Done button
    footerY = footerY - 20
    menuFrame.untrackRow:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 6, footerY)
    menuFrame.untrackRow:SetPoint("RIGHT", menuFrame.doneBtn, "LEFT", -4, 0)
    menuFrame.untrackRow.check:SetChecked(autoUntrack)
    menuFrame.doneBtn:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -8, footerY - 1)

    local finalWidth = math.min(math.max(maxWidth, 270), 305)
    menuFrame:SetSize(finalWidth, math.abs(footerY) + 30)

    if menuFrame.bgLeft then
        menuFrame.bgLeft:SetWidth(math.floor(finalWidth * 0.75))
    end
end

-- Resets all active filters and restores tracked quests & map pins
local function ResetAllFilters()
    wipe(selectedFilters)
    dropdownSearchText = ""
    if sharedMenuFrame and sharedMenuFrame.searchBox then
        sharedMenuFrame.searchBox:SetText("")
    end
    ApplyFilterChanges()
    if sharedMenuFrame and sharedMenuFrame:IsShown() then
        RebuildDropdownMenu(sharedMenuFrame, false)
    end
end

-- Toggles the shared dropdown menu anchored to whichever button was clicked (Quest Log or Objective Tracker)
local function ToggleMenuAtButton(anchorButton, alignRight)
    if not sharedMenuFrame then return end

    if sharedMenuFrame:IsShown() and sharedMenuFrame.anchorOwner == anchorButton then
        sharedMenuFrame:Hide()
        return
    end

    sharedMenuFrame.anchorOwner = anchorButton
    sharedMenuFrame:ClearAllPoints()
    if alignRight then
        sharedMenuFrame:SetPoint("TOPRIGHT", anchorButton, "BOTTOMRIGHT", 0, -2)
    else
        sharedMenuFrame:SetPoint("TOPLEFT", anchorButton, "BOTTOMLEFT", 0, -2)
    end

    dropdownScrollOffset = 0
    RebuildDropdownMenu(sharedMenuFrame, false)
    sharedMenuFrame:Show()
end

-- Builds the shared dropdown menu (usable from both Quest Log and Objective Tracker)
local function EnsureSharedMenu()
    if sharedMenuFrame then return end

    local menuFrame = CreateFrame("Frame", "QRF_DropdownMenu", UIParent)
    menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    menuFrame:SetFrameLevel(150)
    menuFrame:SetClampedToScreen(true)
    menuFrame:EnableMouse(true)
    menuFrame:EnableMouseWheel(true)
    menuFrame:Hide()
    sharedMenuFrame = menuFrame

    menuFrame.measureLabel = menuFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    menuFrame.measureLabel:Hide()

    menuFrame:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    menuFrame:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        if self.searchBox then
            self.searchBox:ClearFocus()
        end
    end)
    menuFrame:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" and self:IsShown() then
            local overQuestBtn = questLogBar and questLogBar.dropdownBtn and questLogBar.dropdownBtn:IsMouseOver()
            local overTrackerBtn = trackerFilterBtn and trackerFilterBtn:IsMouseOver()
            if not self:IsMouseOver() and not overQuestBtn and not overTrackerBtn then
                self:Hide()
            end
        end
    end)

    local bgLeft = menuFrame:CreateTexture(nil, "BACKGROUND")
    bgLeft:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 0, 0)
    bgLeft:SetPoint("BOTTOMLEFT", menuFrame, "BOTTOMLEFT", 0, 0)
    bgLeft:SetWidth(200)
    bgLeft:SetColorTexture(0.05, 0.05, 0.07, 0.97)
    menuFrame.bgLeft = bgLeft

    local bgRight = menuFrame:CreateTexture(nil, "BACKGROUND")
    bgRight:SetPoint("TOPLEFT", bgLeft, "TOPRIGHT", 0, 0)
    bgRight:SetPoint("BOTTOMRIGHT", menuFrame, "BOTTOMRIGHT", 0, 0)
    ApplyHorizontalGradient(bgRight, 0.05, 0.05, 0.07, 0.97, 0.45)
    menuFrame.bgRight = bgRight

    local topBorder = menuFrame:CreateTexture(nil, "BORDER")
    topBorder:SetHeight(1)
    topBorder:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 0, 0)
    topBorder:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", 0, 0)
    ApplyHorizontalGradient(topBorder, 0.55, 0.55, 0.6, 0.95, 0.3)

    local bottomBorder = menuFrame:CreateTexture(nil, "BORDER")
    bottomBorder:SetHeight(1)
    bottomBorder:SetPoint("BOTTOMLEFT", menuFrame, "BOTTOMLEFT", 0, 0)
    bottomBorder:SetPoint("BOTTOMRIGHT", menuFrame, "BOTTOMRIGHT", 0, 0)
    ApplyHorizontalGradient(bottomBorder, 0.55, 0.55, 0.6, 0.95, 0.3)

    local leftBorder = menuFrame:CreateTexture(nil, "BORDER")
    leftBorder:SetWidth(1)
    leftBorder:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 0, 0)
    leftBorder:SetPoint("BOTTOMLEFT", menuFrame, "BOTTOMLEFT", 0, 0)
    leftBorder:SetColorTexture(0.55, 0.55, 0.6, 0.95)

    local headerLabel = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerLabel:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 10, -8)
    headerLabel:SetText(CONFIG.HEADER_TITLE)

    local closeBtn = CreateFrame("Button", nil, menuFrame, "UIPanelCloseButton")
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        menuFrame:Hide()
    end)

    local groupToggleBtn = CreateFrame("Button", nil, menuFrame, "UIPanelButtonTemplate")
    groupToggleBtn:SetSize(74, 18)
    groupToggleBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    groupToggleBtn:SetText("Group: ON")
    groupToggleBtn:SetScript("OnClick", function()
        showCategories = not showCategories
        dropdownScrollOffset = 0
        SaveState()
        RebuildDropdownMenu(menuFrame, false)
    end)
    menuFrame.groupToggleBtn = groupToggleBtn

    local searchBox = CreateFrame("EditBox", "QRF_DropdownSearchBox", menuFrame, "SearchBoxTemplate")
    searchBox:SetHeight(20)
    searchBox:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 12, -26)
    searchBox:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -10, -26)
    searchBox:SetAutoFocus(false)

    searchBox:HookScript("OnTextChanged", function(self)
        local newText = self:GetText() or ""
        if newText ~= dropdownSearchText then
            dropdownSearchText = newText
            dropdownScrollOffset = 0
            RebuildDropdownMenu(menuFrame, true)
        end
    end)

    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        menuFrame:Hide()
    end)
    menuFrame.searchBox = searchBox

    local headerLine = menuFrame:CreateTexture(nil, "ARTWORK")
    headerLine:SetHeight(1)
    headerLine:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 6, -50)
    headerLine:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -6, -50)
    ApplyHorizontalGradient(headerLine, 0.4, 0.4, 0.45, 0.9, 0.25)

    menuFrame.scrollInfo = menuFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    menuFrame.scrollInfo:Hide()

    local footerLine = menuFrame:CreateTexture(nil, "ARTWORK")
    footerLine:SetHeight(1)
    ApplyHorizontalGradient(footerLine, 0.4, 0.4, 0.45, 0.9, 0.25)
    menuFrame.footerDivider = footerLine

    -- Footer Option 1: Show Map reward icons
    local mapBadgeRow = CreateFrame("Button", nil, menuFrame)
    mapBadgeRow:SetHeight(20)
    mapBadgeRow.check = CreateFrame("CheckButton", nil, mapBadgeRow, "UICheckButtonTemplate")
    mapBadgeRow.check:SetSize(20, 20)
    mapBadgeRow.check:SetPoint("LEFT", mapBadgeRow, "LEFT", 2, 0)
    mapBadgeRow.check:SetMouseClickEnabled(false)
    mapBadgeRow.label = mapBadgeRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mapBadgeRow.label:SetPoint("LEFT", mapBadgeRow.check, "RIGHT", 2, 0)
    mapBadgeRow.label:SetText("|cFFDDDDDDShow Map reward icons|r")
    mapBadgeRow:SetScript("OnClick", function()
        showMapBadges = not showMapBadges
        mapBadgeRow.check:SetChecked(showMapBadges)
        UpdateWorldMapPins()
        SaveState()
    end)
    menuFrame.mapBadgeRow = mapBadgeRow

    -- Footer Option 2: Show Map Legend overlay in top-left corner
    local mapLegendRow = CreateFrame("Button", nil, menuFrame)
    mapLegendRow:SetHeight(20)
    mapLegendRow.check = CreateFrame("CheckButton", nil, mapLegendRow, "UICheckButtonTemplate")
    mapLegendRow.check:SetSize(20, 20)
    mapLegendRow.check:SetPoint("LEFT", mapLegendRow, "LEFT", 2, 0)
    mapLegendRow.check:SetMouseClickEnabled(false)
    mapLegendRow.label = mapLegendRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mapLegendRow.label:SetPoint("LEFT", mapLegendRow.check, "RIGHT", 2, 0)
    mapLegendRow.label:SetText("|cFFDDDDDDShow Map Legend overlay|r")
    mapLegendRow:SetScript("OnClick", function()
        showMapLegend = not showMapLegend
        mapLegendRow.check:SetChecked(showMapLegend)
        UpdateWorldMapPins()
        SaveState()
    end)
    menuFrame.mapLegendRow = mapLegendRow

    -- Footer Option 3: Filter Local Map Pins + [Mode: Dim / Hide] button
    local mapFilterRow = CreateFrame("Button", nil, menuFrame)
    mapFilterRow:SetHeight(20)
    mapFilterRow.check = CreateFrame("CheckButton", nil, mapFilterRow, "UICheckButtonTemplate")
    mapFilterRow.check:SetSize(20, 20)
    mapFilterRow.check:SetPoint("LEFT", mapFilterRow, "LEFT", 2, 0)
    mapFilterRow.check:SetMouseClickEnabled(false)
    mapFilterRow.label = mapFilterRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mapFilterRow.label:SetPoint("LEFT", mapFilterRow.check, "RIGHT", 2, 0)
    mapFilterRow.label:SetText("|cFFDDDDDDFilter Map pins|r")
    mapFilterRow:SetScript("OnClick", function()
        filterMapPins = not filterMapPins
        mapFilterRow.check:SetChecked(filterMapPins)
        UpdateWorldMapPins()
        SaveState()
    end)
    menuFrame.mapFilterRow = mapFilterRow

    local mapModeBtn = CreateFrame("Button", nil, menuFrame, "UIPanelButtonTemplate")
    mapModeBtn:SetSize(68, 18)
    mapModeBtn:SetText(hideUnmatchedMapPins and "Mode: Hide" or "Mode: Dim")
    mapModeBtn:SetScript("OnClick", function(self)
        hideUnmatchedMapPins = not hideUnmatchedMapPins
        self:SetText(hideUnmatchedMapPins and "Mode: Hide" or "Mode: Dim")
        UpdateWorldMapPins()
        SaveState()
    end)
    menuFrame.mapModeBtn = mapModeBtn

    -- Footer Option 4: Auto-untrack others + Done button
    local doneBtn = CreateFrame("Button", nil, menuFrame, "UIPanelButtonTemplate")
    doneBtn:SetSize(52, 20)
    doneBtn:SetText("Done")
    doneBtn:SetScript("OnClick", function()
        menuFrame:Hide()
    end)
    menuFrame.doneBtn = doneBtn

    local untrackRow = CreateFrame("Button", nil, menuFrame)
    untrackRow:SetHeight(20)
    untrackRow.check = CreateFrame("CheckButton", nil, untrackRow, "UICheckButtonTemplate")
    untrackRow.check:SetSize(20, 20)
    untrackRow.check:SetPoint("LEFT", untrackRow, "LEFT", 2, 0)
    untrackRow.check:SetMouseClickEnabled(false)
    untrackRow.label = untrackRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    untrackRow.label:SetPoint("LEFT", untrackRow.check, "RIGHT", 2, 0)
    untrackRow.label:SetText("|cFFDDDDDDAuto-untrack others|r")
    untrackRow:SetScript("OnClick", function()
        autoUntrack = not autoUntrack
        untrackRow.check:SetChecked(autoUntrack)
        ApplyFilterChanges()
    end)
    menuFrame.untrackRow = untrackRow

    menuFrame:SetScript("OnMouseWheel", function(_, delta)
        local maxScroll = math.max(0, #dropdownDisplayList - MAX_DROPDOWN_ROWS)
        dropdownScrollOffset = math.min(maxScroll, math.max(0, dropdownScrollOffset - delta))
        RebuildDropdownMenu(menuFrame, false)
    end)
end

-- Creates the quick-filter button next to the "All Objectives" banner on the Objective Tracker
local function CreateObjectiveTrackerButton()
    if trackerFilterBtn or not ObjectiveTrackerFrame then return end

    local header = ObjectiveTrackerFrame.Header or ObjectiveTrackerFrame
    local minimizeBtn = (ObjectiveTrackerFrame.Header and ObjectiveTrackerFrame.Header.MinimizeButton) or ObjectiveTrackerFrame.MinimizeButton

    local btn = CreateFrame("Button", "QRF_TrackerFilterButton", header, "UIPanelButtonTemplate")
    btn:SetSize(82, 18)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    if minimizeBtn then
        btn:SetPoint("RIGHT", minimizeBtn, "LEFT", -6, 0)
    else
        btn:SetPoint("TOPRIGHT", header, "TOPRIGHT", -28, -4)
    end

    btn:SetText(CONFIG.TRACKER_BTN_ALL)

    btn:SetScript("OnClick", function(self, button)
        EnsureSharedMenu()
        if button == "RightButton" then
            ResetAllFilters()
        else
            ToggleMenuAtButton(self, true)
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(CONFIG.ADDON_NAME, 1, 0.82, 0)
        GameTooltip:AddLine("Left-Click: Filter Quest Rewards", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Right-Click: Reset All Filters", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    trackerFilterBtn = btn
    UpdateAllButtonLabels()
end

-- Creates the flat override list panel and the top dropdown bar in the Quest Log
local function CreateQuestLogUI()
    if not QuestScrollFrame or QuestScrollFrame.qrfBar then return end
    EnsureSharedMenu()

    local bar = CreateFrame("Frame", "QRF_FilterBar", QuestScrollFrame)
    bar:SetSize(245, 22)
    bar:SetPoint("BOTTOMLEFT", QuestScrollFrame, "TOPLEFT", 2, 3)

    local dropdownBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    dropdownBtn:SetSize(180, 22)
    dropdownBtn:SetPoint("LEFT", bar, "LEFT", 0, 0)
    dropdownBtn:SetText(CONFIG.QUESTLOG_BTN_ALL)
    bar.dropdownBtn = dropdownBtn

    local resetBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    resetBtn:SetSize(56, 22)
    resetBtn:SetPoint("LEFT", dropdownBtn, "RIGHT", 4, 0)
    resetBtn:SetText("Reset")
    resetBtn:Disable()
    bar.resetBtn = resetBtn

    local customList = CreateFrame("Frame", "QRF_CustomQuestList", QuestScrollFrame)
    customList:SetAllPoints(QuestScrollFrame)
    customList:SetFrameLevel(QuestScrollFrame:GetFrameLevel() + 15)
    customList:EnableMouse(true)
    customList:EnableMouseWheel(true)
    customList:Hide()

    local listBg = customList:CreateTexture(nil, "BACKGROUND")
    listBg:SetAllPoints()
    listBg:SetColorTexture(0.06, 0.06, 0.08, 0.96)

    customList.headerText = customList:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    customList.headerText:SetPoint("TOPLEFT", customList, "TOPLEFT", 10, -8)

    local subHint = customList:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subHint:SetPoint("TOPRIGHT", customList, "TOPRIGHT", -10, -10)
    subHint:SetText("Click: Details | Shift-Click: Track")

    local listDivider = customList:CreateTexture(nil, "ARTWORK")
    listDivider:SetHeight(1)
    listDivider:SetPoint("TOPLEFT", customList, "TOPLEFT", 8, -26)
    listDivider:SetPoint("TOPRIGHT", customList, "TOPRIGHT", -8, -26)
    listDivider:SetColorTexture(0.35, 0.35, 0.4, 0.8)

    for i = 1, MAX_CUSTOM_ROWS do
        local row = CreateFrame("Button", nil, customList)
        row:SetHeight(48)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0.0)

        row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
        row.highlight:SetAllPoints()
        row.highlight:SetColorTexture(0.3, 0.6, 1.0, 0.18)

        -- Line 1 (Top-Left): Quest Title
        row.titleText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.titleText:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
        row.titleText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.titleText:SetJustifyH("LEFT")
        row.titleText:SetWordWrap(false)

        -- Line 2 (Middle-Left): Zone / Campaign Description
        row.zoneText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.zoneText:SetPoint("TOPLEFT", row.titleText, "BOTTOMLEFT", 0, -2)
        row.zoneText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.zoneText:SetJustifyH("LEFT")
        row.zoneText:SetWordWrap(false)

        customListRowPool[i] = row
    end

    customList.scrollHint = customList:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    customList.scrollHint:SetPoint("BOTTOM", customList, "BOTTOM", 0, 6)

    customList:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #matchingQuestsList - MAX_CUSTOM_ROWS)
        customScrollOffset = math.min(maxOffset, math.max(0, customScrollOffset - delta))
        RenderCustomFilteredList()
    end)

    QuestScrollFrame.qrfCustomList = customList

    dropdownBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    dropdownBtn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ResetAllFilters()
        else
            ToggleMenuAtButton(self, false)
        end
    end)

    resetBtn:SetScript("OnClick", function()
        ResetAllFilters()
    end)

    QuestScrollFrame:HookScript("OnHide", function()
        if sharedMenuFrame and sharedMenuFrame.anchorOwner == dropdownBtn then
            sharedMenuFrame:Hide()
        end
    end)

    QuestScrollFrame.qrfBar = bar
    questLogBar = bar
    UpdateAllButtonLabels()
end

-- Hooks into WorldMapFrame & ScrollContainer zoom so zooming dynamically coalesces/separates icons
local function HookWorldMap()
    if not WorldMapFrame or WorldMapFrame.qrfHooked then return end
    WorldMapFrame.qrfHooked = true

    WorldMapFrame:HookScript("OnShow", function()
        UpdateQuestLogUI()
    end)

    if WorldMapFrame.OnMapChanged then
        hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
            UpdateQuestLogUI()
            if sharedMenuFrame and sharedMenuFrame:IsShown() then
                RebuildDropdownMenu(sharedMenuFrame, false)
            end
        end)
    end

    if WorldMapFrame.RefreshAllDataProviders then
        hooksecurefunc(WorldMapFrame, "RefreshAllDataProviders", function()
            UpdateWorldMapPins()
        end)
    end

    -- Monitor live canvas zoom scale changes so coalesced icons split/merge smoothly as you zoom
    if WorldMapFrame.ScrollContainer and not mapOverlayHolder then
        mapOverlayHolder = CreateFrame("Frame", nil, WorldMapFrame.ScrollContainer)
        local lastScale = 0
        local elapsedAccum = 0
        mapOverlayHolder:SetScript("OnUpdate", function(_, elapsed)
            elapsedAccum = elapsedAccum + elapsed
            if elapsedAccum < 0.05 then return end
            elapsedAccum = 0
            if WorldMapFrame:IsShown() and WorldMapFrame.ScrollContainer.GetCanvasScale then
                local curScale = WorldMapFrame.ScrollContainer:GetCanvasScale() or 1
                if math.abs(curScale - lastScale) > 0.002 then
                    lastScale = curScale
                    UpdateWorldMapPins()
                end
            end
        end)
    end
end

-- Initialize and hook into Quest Log, World Map & Objective Tracker updates
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("QUEST_LOG_UPDATE")
loader:RegisterEvent("QUEST_DATA_LOAD_RESULT")
loader:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        LoadState()
    elseif event == "PLAYER_ENTERING_WORLD" then
        CreateQuestLogUI()
        CreateObjectiveTrackerButton()
        HookWorldMap()
        if QuestLogQuests_Update then
            hooksecurefunc("QuestLogQuests_Update", UpdateQuestLogUI)
        end
        UpdateQuestLogUI()
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    elseif event == "QUEST_LOG_UPDATE" then
        if not isSyncingTracker then
            UpdateQuestLogUI()
            if sharedMenuFrame and sharedMenuFrame:IsShown() then
                RebuildDropdownMenu(sharedMenuFrame, false)
            end
        end
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        if arg2 and not preloadRefreshPending and C_Timer and C_Timer.After then
            preloadRefreshPending = true
            C_Timer.After(0.15, function()
                preloadRefreshPending = false
                if not isSyncingTracker then
                    UpdateQuestLogUI()
                    if sharedMenuFrame and sharedMenuFrame:IsShown() then
                        RebuildDropdownMenu(sharedMenuFrame, false)
                    end
                end
            end)
        end
    end
end)
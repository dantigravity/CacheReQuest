-- ============================================================================
-- ADDON CONFIGURATION (Edit display names and defaults here)
-- ============================================================================
local CONFIG = {
    ADDON_NAME          = "Cache ReQuest",
    QUESTLOG_BTN_ALL    = "Filter Rewards: All",
    TRACKER_BTN_ALL     = "Filter: All",
    HEADER_TITLE        = "Available Rewards:",
     collapseRightOffset = -65, -- Distance of [+] / [-] from right edge of dropdown
}
-- ============================================================================

local selectedFilters = {}
local collapsedCategories = {}
local knownRewardMeta = {}
local autoUntrack = true
local showCategories = true

local availableRewards = {}
local dropdownDisplayList = {}
local questRewardMap = {}
local matchingQuestsList = {}

local dropdownRowPool = {}
local customListRowPool = {}
local savedWatchedQuests = nil
local isSyncingTracker = false

local customScrollOffset = 0
local dropdownScrollOffset = 0
local dropdownSearchText = ""

local MAX_CUSTOM_ROWS = 13
local MAX_DROPDOWN_ROWS = 15

local sharedMenuFrame = nil
local questLogBar = nil
local trackerFilterBtn = nil

local CATEGORY_NAMES = {
    [1] = "Seasonal & Event",
    [2] = "Currencies",
    [3] = "Reputation & Renown",
    [4] = "Items & Caches",
    [5] = "Gear & Gold",
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

-- Persist state to SavedVariables table so selections survive /reload
local function SaveState()
    QRF_SavedState = QRF_SavedState or {}
    QRF_SavedState.selectedFilters = selectedFilters
    QRF_SavedState.collapsedCategories = collapsedCategories
    QRF_SavedState.knownRewardMeta = knownRewardMeta
    QRF_SavedState.savedWatchedQuests = savedWatchedQuests
    QRF_SavedState.autoUntrack = autoUntrack
    QRF_SavedState.showCategories = showCategories
end

local function LoadState()
    if type(QRF_SavedState) == "table" then
        selectedFilters = QRF_SavedState.selectedFilters or {}
        collapsedCategories = QRF_SavedState.collapsedCategories or {}
        knownRewardMeta = QRF_SavedState.knownRewardMeta or {}
        savedWatchedQuests = QRF_SavedState.savedWatchedQuests
        if QRF_SavedState.autoUntrack ~= nil then autoUntrack = QRF_SavedState.autoUntrack end
        if QRF_SavedState.showCategories ~= nil then showCategories = QRF_SavedState.showCategories end
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

-- Scans all accepted quests and preserves any active selections even if a header is collapsed
local function ScanQuestLogRewards()
    wipe(availableRewards)
    wipe(questRewardMap)

    local rewardRegistry = {}
    local currentHeader = "Quests"

    local function RegisterReward(questID, title, header, rewardID, name, icon, categoryGroup, sortPriority, badgeStr)
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
                rewards = {},
                badges = {},
                order = {}
            }
        end
        if not questRewardMap[questID].rewards[rewardID] then
            questRewardMap[questID].rewards[rewardID] = true
            questRewardMap[questID].badges[rewardID] = badgeStr
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

    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    for i = 1, numEntries do
        local info = C_QuestLog.GetInfo(i)
        if info then
            if info.isHeader then
                currentHeader = info.title or "Quests"
            elseif not info.isHidden and info.questID then
                local questID = info.questID
                local qTitle = info.title or "Quest"

                if HaveQuestRewardData and not HaveQuestRewardData(questID) and C_TaskQuest and C_TaskQuest.RequestPreloadRewardData then
                    C_TaskQuest.RequestPreloadRewardData(questID)
                end

                -- 1. Currencies, Seasonal Currencies & Faction Reputation
                local currencies = GetQuestCurrencies(questID)
                if currencies and #currencies > 0 then
                    for _, curr in ipairs(currencies) do
                        local cID = "CURR_" .. tostring(curr.currencyID or curr.name or "UNKNOWN")
                        local cName = curr.name or "Currency"
                        local cIcon = curr.texture or 134400
                        local amt = curr.totalRewardAmount or curr.numItems or 0
                        local badge = "|T" .. cIcon .. ":14:14:0:0|t|cFF00CCFF" .. amt .. "|r"

                        local catGroup = 2
                        if IsSeasonalReward(cName, curr.currencyID, nil) then
                            catGroup = 1
                        elseif IsReputationReward(cName, curr.currencyID) then
                            catGroup = 3
                        end

                        RegisterReward(questID, qTitle, currentHeader, cID, cName, cIcon, catGroup, 1, badge)
                    end
                end

                -- 2. Guaranteed Items & Choice Items
                local function ProcessQuestItem(name, tex, numItems, itemID)
                    if IsItemEquipment(itemID) then
                        local icon = tex or 132739
                        local badge = "|T" .. icon .. ":14:14:0:0|t"
                        RegisterReward(questID, qTitle, currentHeader, "ITEM_GEAR", "Equipment & Weapons", icon, 5, 1, badge)
                    else
                        if itemID and not name and C_Item and C_Item.RequestLoadItemDataByID then
                            C_Item.RequestLoadItemDataByID(itemID)
                        end
                        local rID = "ITEM_" .. tostring(itemID or name or "ITEM")
                        local metaName = knownRewardMeta[rID] and knownRewardMeta[rID].name
                        local rName = name or metaName or ("Item #" .. tostring(itemID or ""))
                        local rIcon = tex or (knownRewardMeta[rID] and knownRewardMeta[rID].icon) or 134400
                        local amtStr = (numItems and numItems > 1) and ("|cFFFFFFFF" .. numItems .. "|r") or ""
                        local badge = "|T" .. rIcon .. ":14:14:0:0|t" .. amtStr

                        local catGroup = 4
                        if IsSeasonalReward(rName, nil, itemID) then
                            catGroup = 1
                        elseif IsReputationReward(rName, nil) then
                            catGroup = 3
                        end

                        RegisterReward(questID, qTitle, currentHeader, rID, rName, rIcon, catGroup, 2, badge)
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
                    local badge = "|cFFFFD700" .. gold .. "g|r"
                    RegisterReward(questID, qTitle, currentHeader, "GOLD", "Gold", goldIcon, 5, 2, badge)
                end
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

    -- 1. Update Quest Log Bar
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

    -- 2. Update Objective Tracker "All Objectives" Banner Button
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

-- Renders the flat, clean override list in the Quest Log when filters are active
local function RenderCustomFilteredList()
    if not QuestScrollFrame or not QuestScrollFrame.qrfCustomList then return end
    local listFrame = QuestScrollFrame.qrfCustomList

    wipe(matchingQuestsList)
    for questID, qData in pairs(questRewardMap) do
        if DoesQuestMatchFilter(questID) then
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

    for i = 1, MAX_CUSTOM_ROWS do
        local row = customListRowPool[i]
        local dataIndex = i + customScrollOffset
        local qData = matchingQuestsList[dataIndex]

        if qData then
            local badgeParts = {}
            for _, rID in ipairs(qData.order) do
                if selectedFilters[rID] then
                    table.insert(badgeParts, qData.badges[rID])
                end
            end

            local watchedIcon = IsQuestWatched(qData.questID) and "|TInterface\\RaidFrame\\ReadyCheck-Ready:13:13:0:0|t " or ""
            row.titleText:SetText(watchedIcon .. "|cFFFFFFFF" .. qData.title .. "|r")
            row.zoneText:SetText("|cFF888888" .. qData.header .. "|r")
            row.badgeText:SetText(table.concat(badgeParts, " "))

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

-- Master UI update
local function UpdateQuestLogUI()
    ScanQuestLogRewards()
    UpdateAllButtonLabels()

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

        if QuestScrollFrame.titleFramePool then
            for button in QuestScrollFrame.titleFramePool:EnumerateActive() do
                if button then
                    if not button.qrfBadge then
                        button.qrfBadge = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                        button.qrfBadge:SetPoint("RIGHT", button, "RIGHT", -6, 0)
                        button.qrfBadge:SetJustifyH("RIGHT")
                    end

                    local questID = button.questID or (button.info and button.info.questID)
                    local qData = questID and questRewardMap[questID]

                    if questID and not (button.info and button.info.isHeader) and qData then
                        local badgeParts = {}
                        for _, rID in ipairs(qData.order) do
                            if #badgeParts < 3 and (rID ~= "GOLD" or #qData.order == 1) then
                                table.insert(badgeParts, qData.badges[rID])
                            end
                        end
                        button.qrfBadge:SetText(table.concat(badgeParts, " "))
                        button.qrfBadge:Show()
                    else
                        button.qrfBadge:SetText("")
                        button.qrfBadge:Hide()
                    end
                    button:SetAlpha(1.0)
                end
            end
        end
    end
end

-- Applies filter changes and saves state
local function ApplyFilterChanges()
    customScrollOffset = 0
    ScanQuestLogRewards()
    SyncObjectiveTracker()
    UpdateQuestLogUI()
    SaveState()
end

-- Populates the categorized, collapsible multi-select dropdown menu
local function RebuildDropdownMenu(menuFrame, searchJustChanged)
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

    menuFrame.untrackRow:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 6, yOffset - 8)
    menuFrame.untrackRow:SetPoint("RIGHT", menuFrame.doneBtn, "LEFT", -4, 0)
    menuFrame.untrackRow.check:SetChecked(autoUntrack)

    menuFrame.doneBtn:SetPoint("TOPRIGHT", menuFrame, "TOPRIGHT", -8, yOffset - 9)

    local finalWidth = math.min(math.max(maxWidth, 270), 305)
    menuFrame:SetSize(finalWidth, math.abs(yOffset) + 38)

    if menuFrame.bgLeft then
        menuFrame.bgLeft:SetWidth(math.floor(finalWidth * 0.75))
    end
end

-- Resets all active filters and restores tracked quests
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

    -- Zone 1 (Left 75%): 97% Solid dark
    local bgLeft = menuFrame:CreateTexture(nil, "BACKGROUND")
    bgLeft:SetPoint("TOPLEFT", menuFrame, "TOPLEFT", 0, 0)
    bgLeft:SetPoint("BOTTOMLEFT", menuFrame, "BOTTOMLEFT", 0, 0)
    bgLeft:SetWidth(200)
    bgLeft:SetColorTexture(0.05, 0.05, 0.07, 0.97)
    menuFrame.bgLeft = bgLeft

    -- Zone 2 (Right 25%): Smoothly fades from 97% down to 45% opacity
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

    local doneBtn = CreateFrame("Button", nil, menuFrame, "UIPanelButtonTemplate")
    doneBtn:SetSize(52, 20)
    doneBtn:SetText("Done")
    doneBtn:SetScript("OnClick", function()
        menuFrame:Hide()
    end)
    menuFrame.doneBtn = doneBtn

    local untrackRow = CreateFrame("Button", nil, menuFrame)
    untrackRow:SetHeight(22)

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
        row:SetHeight(32)
        row:SetPoint("TOPLEFT", customList, "TOPLEFT", 8, -28 - ((i - 1) * 33))
        row:SetPoint("TOPRIGHT", customList, "TOPRIGHT", -8, -28 - ((i - 1) * 33))

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0.0)

        row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
        row.highlight:SetAllPoints()
        row.highlight:SetColorTexture(0.3, 0.6, 1.0, 0.18)

        row.titleText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.titleText:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
        row.titleText:SetPoint("RIGHT", row, "RIGHT", -95, 0)
        row.titleText:SetJustifyH("LEFT")
        row.titleText:SetWordWrap(false)

        row.zoneText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.zoneText:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 4)
        row.zoneText:SetJustifyH("LEFT")

        row.badgeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.badgeText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.badgeText:SetJustifyH("RIGHT")

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

-- Initialize and hook into Quest Log & Objective Tracker updates
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("QUEST_LOG_UPDATE")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        LoadState()
    elseif event == "PLAYER_ENTERING_WORLD" then
        CreateQuestLogUI()
        CreateObjectiveTrackerButton()
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
    end
end)
-- ============================================================================
-- FIELD TALLY: "FOR ME" AND THE JOURNAL (Cache ReQuest)
-- Ported from HandkerSheaf (WoW Forever, Handkerquest v2.9.0). Loads after FieldTally.lua and adds:
--   * "For me": your own tasks at the bottom of the "Near me" page. Ticked off, a task goes to the Journal.
--   * The Journal: the last page of the pile. Notes, newest first, stamped with the realm time and the
--     place, with a search (magnifier) and a month calendar on its writing line.
--   * Two quick tabs cut from the sheet's right edge: "Near me" and "Journal".
--   * Auto notes, each its own switch in the options: level-ups (glow gold), achievements earned and
--     quests turned in (with what they gave).
--
-- Saved data (per character unless shared in the options):
--   QRF_SavedState.tallyNotes  (per character)  { tasks = {...}, journal = {...} } of this character
--   CRQ_Notes                  (account-wide)   shared lists, entries waiting for another character, and
--                                               the fold / writing mode
-- Each task / entry: text, t (server time), when ("10 Nov 21:40", realm calendar), place = { mapID, x, y,
-- zone, subzone }, owner ("Name-Realm"); auto entries also auto, autoText and what they list.
-- ============================================================================
local ADDON_NAME, ns = ...
ns = (type(ns) == "table") and ns or {}
local T = ns.Tally
if not T or not T.P then return end
local P = T.P
local DISPLAY_NAME = "Cache ReQuest"

-- Settings (T.db.opts only loads keys it knows, so the new switches go into the defaults first)
do
    local new = {
        forMe = true,               -- "For me" tasks on Near me, the Journal page and its tabs
        autoLevels = true,          -- a note when you reach a new level (glows gold)
        autoAchievements = false,   -- a note when you earn an achievement
        autoQuests = false,         -- a note when you turn in a quest, with what it gave
        shareTasks = false,         -- every character on the account sees the same tasks
        shareJournal = false,       -- one Journal for every character on the account
    }
    for k, v in pairs(new) do
        T.DEFAULTS.opts[k] = v
        if T.db and T.db.opts and T.db.opts[k] == nil then T.db.opts[k] = v end
    end
end

-- ----------------------------------------------------------------------------
-- A GOLD GLOW round a Journal entry's words (a level reached): eight soft copies of the words in gold under
-- the ink (ARTWORK, the words are OVERLAY), on every look, breathing (P.PulseGlow from the tally's OnUpdate).
-- Its own copies (fs.glow), apart from the look's wet ink / light (fs.halo). text nil = off.
-- ----------------------------------------------------------------------------
P.GLOW_COLOR = { 1.00, 0.78, 0.22 }
P.GLOW_ALPHA, P.GLOW_RADIUS, P.GLOW_SPEED = 0.55, 1.6, 1.6
P.GLOW_OFFS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 0.7, 0.7 }, { -0.7, 0.7 }, { 0.7, -0.7 }, { -0.7, -0.7 } }
P.glowing = {}                 -- the words with a glow showing
function P.SetGlow(fs, text)
    if not text or text == "" then
        if fs.glow then for _, c in ipairs(fs.glow) do c:Hide() end end
        P.glowing[fs] = nil
        return
    end
    if not fs.glow then
        fs.glow = {}
        local parent = fs:GetParent()
        for k = 1, #P.GLOW_OFFS do
            local c = parent:CreateFontString(nil, "ARTWORK", nil, 5)
            c:SetJustifyH("LEFT")
            c:SetJustifyV("TOP")
            fs.glow[k] = c
        end
    end
    local path, size, flags = fs:GetFont()
    local plain = P.PlainText(text)
    local col = P.GLOW_COLOR
    for k, c in ipairs(fs.glow) do
        c:SetFont(path or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 12, flags or "")
        if c.SetShadowColor then c:SetShadowColor(0, 0, 0, 0) end
        P.MatchCopy(c, fs, P.GLOW_OFFS[k][1] * P.GLOW_RADIUS, P.GLOW_OFFS[k][2] * P.GLOW_RADIUS)
        c:SetText(plain)
        c:SetTextColor(col[1], col[2], col[3], P.GLOW_ALPHA)
        c:Show()
    end
    P.glowing[fs] = true
end

function P.PulseGlow(now)
    local k = 0.70 + 0.30 * math.sin(now * P.GLOW_SPEED)
    local col = P.GLOW_COLOR
    for fs in pairs(P.glowing) do
        for _, c in ipairs(fs.glow or {}) do
            if c:IsShown() then c:SetTextColor(col[1], col[2], col[3], P.GLOW_ALPHA * k) end
        end
    end
end

-- Everything the tally's OnUpdate runs for these pieces (a glowing level, a note flying in, a tab sliding)
function P.AnimateJournal(f, dt)
    if next(P.glowing) then P.PulseGlow(GetTime()) end
    if f.fly then P.AnimateFly(f, dt) end
    if f.tabsMoving then P.AnimateTabs(f, dt) end
end

-- ----------------------------------------------------------------------------
-- "FOR ME": the player's own tasks, written at the bottom of the "Near me" page
-- ----------------------------------------------------------------------------
-- T.notes (tasks and journal saved per character unless shared: see T.LoadNotes):
--   tasks = { { text, t (server time), when ("10 Nov 21:40"), place = { mapID, x, y, zone, subzone },
--               owner ("Name-Realm") }, ... }   in the order written, all still to do
--   journal = { entries, see "the Journal" below }: a task ticked off becomes a "Done: ..." entry there,
--               with doneTask = the task as written (P.TickTask)
--   forMeFolded = true while the section is folded to its heading
-- Drawn like tally lines (inked box, wet ink, ink drops), from their own row pool (f.forMeRows).
T.notes = T.notes or { tasks = {}, journal = {}, forMeFolded = false, writeMode = "task" }
P.NOTE_MAX_LETTERS = 200
P.NOTE_MAX_TASKS = 200
P.FORME_GAP = 4                -- space between the quest lines and the "For me" heading
P.FORME_SHARE = 0.5            -- with quest lines on the page, "For me" keeps at most this much of it

-- One saved task / entry's fields, checked one by one
function T.LoadNoteFields(t)
    local out = {
        text = t.text, done = (t.done == true),
        t = (type(t.t) == "number") and t.t or nil,
        when = (type(t.when) == "string") and t.when or nil,
        owner = (type(t.owner) == "string") and t.owner or nil,
        auto = (t.auto == "achievement" or t.auto == "quest" or t.auto == "level") and t.auto or nil,
        autoText = (type(t.autoText) == "string") and t.autoText or nil,
    }
    if out.auto == "level" and type(t.levels) == "table" then
        out.levels = {}
        for _, l in ipairs(t.levels) do
            if type(l) == "table" and type(l.level) == "number" then table.insert(out.levels, { level = l.level }) end
        end
    end
    if out.auto == "quest" and type(t.quests) == "table" then
        local function num(v) return (type(v) == "number") and v or nil end
        local function str(v) return (type(v) == "string") and v or nil end
        out.quests = {}
        for _, q in ipairs(t.quests) do
            if type(q) == "table" and type(q.title) == "string" then
                local lq = { id = num(q.id), title = q.title, xp = num(q.xp) or 0, money = num(q.money) or 0, items = {} }
                for _, it in ipairs((type(q.items) == "table") and q.items or {}) do
                    if type(it) == "table" and type(it.name) == "string" then
                        table.insert(lq.items, { name = it.name, count = num(it.count) or 1, quality = num(it.quality), id = num(it.id), link = str(it.link) })
                    end
                end
                table.insert(out.quests, lq)
            end
        end
    end
    if out.auto and type(t.achievements) == "table" then
        out.achievements = {}
        for _, a in ipairs(t.achievements) do
            if type(a) == "table" and type(a.name) == "string" then
                table.insert(out.achievements, { id = (type(a.id) == "number") and a.id or nil, name = a.name,
                    points = (type(a.points) == "number") and a.points or 0 })
            end
        end
    end
    if type(t.place) == "table" then
        local pl = t.place
        out.place = {
            mapID = (type(pl.mapID) == "number") and pl.mapID or nil,
            x = (type(pl.x) == "number") and pl.x or nil,
            y = (type(pl.y) == "number") and pl.y or nil,
            zone = (type(pl.zone) == "string") and pl.zone or nil,
            subzone = (type(pl.subzone) == "string") and pl.subzone or nil,
        }
    end
    -- a ticked-off task's entry: the task as it was written (so it can go back to "For me")
    if type(t.doneTask) == "table" and type(t.doneTask.text) == "string" and t.doneTask.text ~= "" then
        local dt = T.LoadNoteFields(t.doneTask)
        out.doneTask = { text = dt.text, t = dt.t, when = dt.when, place = dt.place, owner = dt.owner }
    end
    return out
end

-- A task saved ticked (never written that way here, but kept loadable): into the Journal, among the entries
-- by its own time (when it was done is unknown, so its stamp is when it was written)
function T.MoveTickedToJournal(notes, task)
    local e = { text = P.DoneEntryText(task.text), t = task.t, when = task.when, place = task.place, owner = task.owner,
        doneTask = { text = task.text, t = task.t, when = task.when, place = task.place, owner = task.owner } }
    local at = #notes.journal + 1
    if task.t then
        for i, x in ipairs(notes.journal) do
            if x.t and x.t > task.t then at = i break end
        end
    end
    table.insert(notes.journal, at, e)
end

-- Where notes are saved: "For me" tasks and the Journal are each character's own
-- (QRF_SavedState.tallyNotes.tasks / .journal, the per-character saved file) unless the options share them
-- with every character on the account (opts.shareTasks / shareJournal): then the list lives in the account
-- file (CRQ_Notes.tasks / .journal). A character can't read another's file, so the account file is the only
-- place they meet:
--  * private: the account's list holds entries waiting for other characters (written while shared); each
--    character takes its own (by owner; no owner = whoever comes first), leaves the rest
--  * shared: each character pours its own file's list into the account's and keeps nothing apart
-- Switching sharing off sorts the shared list back out by owner the same way.
-- While playing, CRQ_Notes is T.notes itself (live); on logout (T.SaveNotesForLogout) each list goes where
-- it belongs, with T.notesWaiting[key] (other characters' own entries) back in the account file.
P.NOTE_LISTS = { "journal", "tasks" }        -- the Journal first: a ticked task from a save moves into it
function T.NotesShared(key)
    local o = (T.db and T.db.opts) or {}
    if key == "tasks" then return o.shareTasks == true end
    return o.shareJournal == true
end

function T.LinkSavedNotes()
    CRQ_Notes = T.notes
    if type(QRF_SavedState) ~= "table" then QRF_SavedState = {} end
    local mine = {}
    for _, key in ipairs(P.NOTE_LISTS) do
        mine[key] = T.NotesShared(key) and {} or T.notes[key]
    end
    QRF_SavedState.tallyNotes = mine
end

function T.SaveNotesForLogout()
    local n = T.notes
    local acct = { forMeFolded = n.forMeFolded, writeMode = n.writeMode }
    if type(QRF_SavedState) ~= "table" then QRF_SavedState = {} end
    local mine = {}
    for _, key in ipairs(P.NOTE_LISTS) do
        if T.NotesShared(key) then
            acct[key] = n[key]
            mine[key] = {}
        else
            acct[key] = (T.notesWaiting and T.notesWaiting[key]) or {}
            mine[key] = n[key]
        end
    end
    QRF_SavedState.tallyNotes = mine
    CRQ_Notes = acct
end

-- Saved notes, checked field by field (a broken save never stops the addon loading).
-- saved = the account's notes (CRQ_Notes), charState = this character's (QRF_SavedState.tallyNotes).
-- Called again with saved = T.notes (live) on entering the world and when a sharing switch changes.
function T.LoadNotes(saved, charState)
    local notes = { tasks = {}, journal = {}, forMeFolded = false, writeMode = "task" }
    local live = type(saved) == "table" and saved == T.notes
    if type(charState) ~= "table" then charState = {} end
    local me = T.NoteOwner()
    local waiting, sharedAt = {}, {}
    local function Valid(e) return type(e) == "table" and type(e.text) == "string" and e.text ~= "" end
    for _, key in ipairs(P.NOTE_LISTS) do
        local shared = T.NotesShared(key)
        sharedAt[key] = shared
        local max = (key == "tasks") and P.NOTE_MAX_TASKS or (P.NOTE_MAX_ENTRIES or 1000)
        local list, seen, rest = {}, {}, {}
        waiting[key] = rest
        -- mine = this character's own list (trusted as it is: a renamed character keeps its notes);
        -- pool = the account's list, sorted by owner unless shared
        local mine, pool
        if live then
            if T.notesSharedAt and T.notesSharedAt[key] then
                pool = saved[key]                     -- leaving (or still in) sharing: the shared list is the pool
            else
                mine, pool = saved[key], T.notesWaiting and T.notesWaiting[key]
            end
        else
            mine, pool = charState[key], (type(saved) == "table") and saved[key] or nil
        end
        local function Add(e, byTime)
            local k = tostring(e.t) .. "\1" .. e.text
            if seen[k] then return end                 -- never taken twice
            local x = T.LoadNoteFields(e)
            x.owner = x.owner or me
            if key == "tasks" and x.done then          -- saved ticked: into the Journal
                if #notes.journal < (P.NOTE_MAX_ENTRIES or 1000) then T.MoveTickedToJournal(notes, x) end
                seen[k] = true
                return
            end
            if #list >= max then return end
            seen[k] = true
            local at = #list + 1
            if byTime and x.t and list[#list] and list[#list].t and list[#list].t > x.t then
                for i, y in ipairs(list) do
                    if y.t and y.t > x.t then at = i break end
                end
            end
            table.insert(list, at, x)
        end
        if type(mine) == "table" then
            for _, e in ipairs(mine) do if Valid(e) then Add(e, false) end end
        end
        if type(pool) == "table" then
            for _, e in ipairs(pool) do
                if Valid(e) then
                    -- no name yet: take nothing (it all keeps waiting)
                    if shared or (me and (e.owner == me or type(e.owner) ~= "string")) then Add(e, true)
                    else table.insert(rest, e) end
                end
            end
        end
        notes[key] = list
    end
    if type(saved) == "table" then
        notes.forMeFolded = (saved.forMeFolded == true)
        if saved.writeMode == "entry" then notes.writeMode = "entry" end
    end
    T.notes = notes
    T.notesWaiting, T.notesSharedAt = waiting, sharedAt
    T.LinkSavedNotes()
end

-- A sharing switch in the options: the list moves to the account file (on) or back to each character (off)
function T.SetNotesShared(key, on)
    T.db.opts[(key == "tasks") and "shareTasks" or "shareJournal"] = on and true or false
    P.CancelForMeEdit()
    P.CancelJournalEdit()
    T.LoadNotes(T.notes, QRF_SavedState and QRF_SavedState.tallyNotes)
    P.ForMeChanged()
end

-- The notes load with the tally's settings (whether they're shared is one of them)
do
    local baseLoadSaved = T.LoadSaved
    function T.LoadSaved(...)
        baseLoadSaved(...)
        T.SafeCall(T.LoadNotes, CRQ_Notes, (type(QRF_SavedState) == "table") and QRF_SavedState.tallyNotes or nil)
    end
end

-- A character's name as written on a shared note: "Bob" on your own realm, "Bob-Realm" elsewhere
function T.OwnerName(owner)
    if type(owner) ~= "string" then return nil end
    local realm = GetRealmName and GetRealmName() or nil
    if realm and realm ~= "" then
        local name = owner:match("^(.-)%-" .. realm:gsub("%p", "%%%0") .. "$")
        if name and name ~= "" then return name end
    end
    return owner
end

-- Whose it is, when the list is shared and it isn't this character's (nil otherwise)
function T.OtherOwner(key, x)
    if not (x and T.NotesShared(key)) then return nil end
    if not x.owner or x.owner == T.NoteOwner() then return nil end
    return T.OwnerName(x.owner)
end

-- What the player typed, made safe to draw: trimmed, one line, no "|" (WoW's colour/link escapes)
function T.CleanNoteText(s)
    s = tostring(s or "")
    s = string.gsub(s, "|", "")
    s = string.gsub(s, "[\r\n\t]+", " ")
    s = string.match(s, "^%s*(.-)%s*$") or ""
    if string.len(s) > P.NOTE_MAX_LETTERS then s = string.sub(s, 1, P.NOTE_MAX_LETTERS) end
    return s
end

-- Realm date and time (the in-game calendar's clock); the PC's clock if this client can't say
P.MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
function T.NoteTime()
    local t
    if GetServerTime then
        local ok, v = pcall(GetServerTime)
        if ok and type(v) == "number" then t = v end
    end
    if not t then t = time and time() or 0 end
    local d
    if C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime then
        local ok, c = pcall(C_DateAndTime.GetCurrentCalendarTime)
        if ok and type(c) == "table" and c.month and c.monthDay then
            d = { day = c.monthDay, month = c.month, hour = c.hour or 0, min = c.minute or 0 }
        end
    end
    if not d and date then
        local ok, c = pcall(date, "*t")
        if ok and type(c) == "table" then d = { day = c.day, month = c.month, hour = c.hour, min = c.min } end
    end
    local when = d and string.format("%d %s %02d:%02d", d.day or 1, P.MONTHS[d.month or 1] or "?", d.hour or 0, d.min or 0) or nil
    return t, when
end

-- Where the player stands: map, spot and the zone / sub-zone names
function T.HerePlace()
    local place = { zone = T.Call(GetRealZoneText), subzone = T.Call(GetSubZoneText) }
    if type(place.zone) ~= "string" or place.zone == "" then place.zone = nil end
    if type(place.subzone) ~= "string" or place.subzone == "" then place.subzone = nil end
    local mapID, x, y = T.PlayerPos()
    if mapID then
        place.mapID = mapID
        if x and y then place.x, place.y = P.Round4(x), P.Round4(y) end
    end
    return place
end

function T.NoteOwner()
    local name = T.UnitStr(UnitName, "player")
    local realm = T.Call(GetRealmName)
    if not name then return nil end
    return (type(realm) == "string" and realm ~= "") and (name .. "-" .. realm) or name
end

-- Adds a task to "For me"; returns it (nil if the text was empty or the list is full)
function T.AddTask(text)
    text = T.CleanNoteText(text)
    if text == "" or #T.notes.tasks >= P.NOTE_MAX_TASKS then return nil end
    local t, when = T.NoteTime()
    local task = { text = text, done = false, t = t, when = when, place = T.HerePlace(), owner = T.NoteOwner() }
    table.insert(T.notes.tasks, task)
    return task
end

-- After any change to the tasks or notes: save and redraw
function P.ForMeChanged()
    T.Save()
    T.Update()
end

-- A task ticked off leaves "For me" and goes to the Journal: "Done: ..." stamped with the time and place it
-- was done; doneTask keeps the task as it was written (its own time and place), so it can go back.
function P.DoneEntryText(text)
    return "Done: " .. (text or "")
end

function T.CompleteTask(i)
    local task = T.notes.tasks[i]
    if not task then return nil end
    local e = T.AddEntry(P.DoneEntryText(task.text))
    if not e then return nil end
    table.remove(T.notes.tasks, i)
    e.doneTask = { text = task.text, t = task.t, when = task.when, place = task.place, owner = task.owner }
    return e
end

-- Click on a task: ticked off, it flies from its line into the Journal tab (y = the line's place on the page)
function P.TickTask(i, y)
    local e = T.CompleteTask(i)
    if not e then return end
    local f = T.frame
    if f then P.FlyToJournal(f, e.text, 20, y or (f.forMeWriteY or 0)) end
    P.ForMeChanged()
end

-- Right-click a "Done: ..." entry: not done after all, back to "For me" as it was written
function P.TaskBackFromJournal(e)
    local dt = e and e.doneTask
    if not dt or #T.notes.tasks >= P.NOTE_MAX_TASKS then return nil end
    for i, x in ipairs(T.notes.journal) do
        if x == e then table.remove(T.notes.journal, i) break end
    end
    local task = { text = dt.text, done = false, t = dt.t, when = dt.when, place = dt.place, owner = dt.owner }
    table.insert(T.notes.tasks, task)
    P.ForMeChanged()
    return task
end

function P.RubOutTask(i)
    if not T.notes.tasks[i] then return end
    table.remove(T.notes.tasks, i)
    P.ForMeChanged()
end

function P.ToggleForMeFold()
    T.notes.forMeFolded = not T.notes.forMeFolded
    P.CancelForMeEdit()
    P.ForMeChanged()
end

-- Gives a writing box the keyboard so typing never reaches the action bars: now, and again a frame later
-- (the click that opened it may still take focus away). Losing focus within P.FOCUS_GRACE seconds of
-- opening is that click, not the player clicking away: the box takes it back (P.FocusGrace).
P.FOCUS_GRACE = 0.3
function P.FocusBox(eb, stillWanted)
    if not eb then return end
    if eb.EnableKeyboard then eb:EnableKeyboard(true) end
    eb.focusAt = GetTime()
    eb:Show()
    eb:SetFocus()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if stillWanted() and eb:IsShown() and not (eb.HasFocus and eb:HasFocus()) then eb:SetFocus() end
        end)
    end
end

function P.FocusGrace(eb)
    if eb.focusAt and (GetTime() - eb.focusAt) < P.FOCUS_GRACE and eb:IsShown() then
        eb:SetFocus()
        return true
    end
    return false
end

-- Writing: P.forMeEditing = { index = n } while re-writing task n, { } while writing a new one, nil otherwise
function P.EnsureForMeEditBox(f)
    if f.forMeEdit then return f.forMeEdit end
    local eb = CreateFrame("EditBox", nil, f.content)
    P.SetInkFont(eb, "item")              -- a font first: WoW won't take text into a box without one
    eb:SetAutoFocus(false)
    eb:EnableMouse(true)
    eb:SetScript("OnMouseDown", function(self) self:SetFocus() end)   -- click into it: the keyboard is its again
    eb:SetMultiLine(false)
    eb:SetMaxLetters(P.NOTE_MAX_LETTERS)
    eb:SetHeight(18)
    eb:SetFrameLevel((f.baseLevel or 30) + 24)
    eb:SetJustifyH("LEFT")
    eb.wash = eb:CreateTexture(nil, "BACKGROUND")
    eb.wash:SetPoint("TOPLEFT", eb, "TOPLEFT", -3, 1)
    eb.wash:SetPoint("BOTTOMRIGHT", eb, "BOTTOMRIGHT", 3, -1)
    eb:SetScript("OnEnterPressed", function() P.CommitForMeEdit() end)
    eb:SetScript("OnEscapePressed", function() P.CancelForMeEdit() end)
    -- clicking away keeps what was written (the redraw waits a frame: the click that took the focus
    -- away may be on another line)
    eb:SetScript("OnEditFocusLost", function(self)
        local wl = f.forMeWrite
        if wl and wl.mode and wl.mode.IsMouseOver and wl.mode:IsMouseOver() then return end   -- switching task / note
        if P.forMeEditing and P.FocusGrace(self) then return end
        if P.forMeEditing then P.CommitForMeEdit(true) end
    end)
    -- hidden with the tally (put away, page turned): never keep the keyboard
    eb:SetScript("OnHide", function(self) if self.HasFocus and self:HasFocus() then self:ClearFocus() end end)
    eb:Hide()
    f.forMeEdit = eb
    return eb
end

function P.BeginForMeEdit(index)
    local f = T.frame
    if not f then return end
    if P.journalEditing then P.CommitJournalEdit() end
    local eb = P.EnsureForMeEditBox(f)
    local task = index and T.notes.tasks[index]
    P.SetInkFont(eb, "item")
    eb:SetText(task and task.text or "")
    P.forMeEditing = { index = task and index or nil }
    P.Render(f)
    P.FocusBox(eb, function() return P.forMeEditing ~= nil end)
    if eb.HighlightText and task then eb:HighlightText() end
end

-- Enter (or clicking away): keep what was written. Re-writing a task to nothing rubs it out.
function P.CommitForMeEdit(deferRedraw)
    local editing = P.forMeEditing
    if not editing then return end
    P.forMeEditing = nil                       -- first, so ClearFocus's focus-lost doesn't commit twice
    local f = T.frame
    local eb = f and f.forMeEdit
    local text = T.CleanNoteText(eb and eb:GetText() or "")
    if eb then eb:ClearFocus(); eb:Hide() end
    if editing.index then
        local task = T.notes.tasks[editing.index]
        if task then
            if text == "" then table.remove(T.notes.tasks, editing.index) else task.text = text end
        end
    elseif P.WriteMode() == "entry" then
        local e = T.AddEntry(text)
        if e and f then P.FlyToJournal(f, e.text, 20, (f.forMeWriteY or 0) - 2) end
    else
        T.AddTask(text)
    end
    if deferRedraw and C_Timer and C_Timer.After then
        T.Save()
        C_Timer.After(0, function() T.SafeCall(T.Update) end)
    else
        P.ForMeChanged()
    end
end

-- "add a task" / "write a note" on the front page: start writing that kind
function P.StartWriting(kind)
    T.notes.writeMode = (kind == "entry") and "entry" or "task"
    T.Save()
    P.BeginForMeEdit(nil)
end

-- The switch's tooltip: what the writing line makes now
function P.ModeTooltip(b)
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    if P.WriteMode() == "entry" then
        GameTooltip:AddLine("Writing: a note", 1, 0.82, 0)
        GameTooltip:AddLine("Stamped with the time and place, then kept in your Journal (the quill tab on the right).", 0.9, 0.9, 0.9, true)
    else
        GameTooltip:AddLine("Writing: a task", 1, 0.82, 0)
        GameTooltip:AddLine("Stays here in For me until you tick it off; then it goes to your Journal, stamped with the time.", 0.9, 0.9, 0.9, true)
    end
    GameTooltip:AddLine("Click: make it " .. ((P.WriteMode() == "entry") and "a task" or "a note"), 0.65, 0.65, 0.65)
    GameTooltip:Show()
end

-- Where a task is in the list now (rows remember their task, not a position that can shift)
function P.TaskIndex(task)
    for i, t in ipairs(T.notes.tasks) do
        if t == task then return i end
    end
    return nil
end

function P.CancelForMeEdit()
    if not P.forMeEditing then return end
    P.forMeEditing = nil
    local f = T.frame
    local eb = f and f.forMeEdit
    if eb then eb:ClearFocus(); eb:Hide() end
    if f and f:IsShown() then P.Render(f) end
end

-- Height of one written line in the list's handwriting (f.measureFS never wraps)
function P.LineHeight(f)
    P.SetInkFont(f.measureFS, "item")
    f.measureFS:SetText("Ag")
    return math.max(12, math.ceil(f.measureFS:GetStringHeight() or 12))
end

function P.TaskRowHeight(f, task, textW, lineH)
    local lines = P.WrapLines(f.measureFS, task.text, textW)
    return math.max(14, math.ceil(#lines * lineH)) + 7
end

-- How much of the page "For me" wants: its heading, then (unfolded) every task and the writing line
function P.ForMeWantedHeight(f, contentW)
    local h = P.FORME_GAP + P.ForMeHeadHeight(f)
    if T.notes.forMeFolded then return h end
    local textW = math.max(110, contentW - 24)
    local lineH = P.LineHeight(f)
    for _, task in ipairs(T.notes.tasks) do h = h + P.TaskRowHeight(f, task, textW, lineH) end
    return h + math.max(14, lineH) + 7
end

-- Space kept free under the quest lines for "For me": all it wants, but with quest lines on the page at
-- most P.FORME_SHARE of it (never less than its heading and writing line)
function P.ForMeReserve(f, contentW, contentH, hasQuestLines)
    if not T.db.opts.forMe then return 0 end
    local want = P.ForMeWantedHeight(f, contentW)
    if not hasQuestLines then return want end
    local least = P.FORME_GAP + P.ForMeHeadHeight(f) + (T.notes.forMeFolded and 0 or (math.max(14, P.LineHeight(f)) + 7))
    return math.min(want, math.max(least, contentH * P.FORME_SHARE))
end

function P.HideForMe(f)
    for _, row in ipairs(f.forMeRows or {}) do row:Hide() end
    if f.forMeHead then f.forMeHead:Hide() end
    if f.forMeWrite then f.forMeWrite:Hide() end
    if f.forMeNote then f.forMeNote:Hide() end
    if f.forMeEdit then
        if P.forMeEditing then P.CommitForMeEdit() end
        f.forMeEdit:Hide()
    end
end

-- Height of the "For me" heading: written like the page's own heading ("Near me"), so in its size of
-- writing, plus its double quill underline. Leaves f.measureFS back in the list's writing.
function P.ForMeHeadHeight(f)
    P.SetInkFont(f.measureFS, "title")
    f.measureFS:SetText("For me")
    local h = math.max(14, math.ceil(f.measureFS:GetStringHeight() or 14))
    P.SetInkFont(f.measureFS, "item")
    return h + 11
end

-- The "For me" heading, written exactly like the page's heading ("Near me"): the heading's writing and
-- ink (gilded first letter on vellum, wet ink / glow), and the same double quill underline sized to the
-- words. A note after it in the sub-heading ink, as "· Dolanaar" is: "· 3" folded, "· +2" when older
-- tasks don't fit. Click folds it.
function P.DrawForMeHeading(f, y, w, st, hiddenCount)
    local h = f.forMeHead
    if not h then
        h = CreateFrame("Button", nil, f.content)
        h:RegisterForClicks("LeftButtonUp")
        h.fs = h:CreateFontString(nil, "OVERLAY")
        h.fs:SetJustifyH("LEFT")
        h.fs:SetWordWrap(false)
        if h.fs.SetMaxLines then h.fs:SetMaxLines(1) end
        h.fs.singleLine = true          -- its bold pass / wet-ink copies cut off with it, never wrap under it
        h.fs:SetPoint("TOPLEFT", h, "TOPLEFT", 4, -2)
        h.fs:SetPoint("RIGHT", h, "RIGHT", -2, 0)
        h.rule = P.NewStroke(h, "ARTWORK", 4)
        h.rule2 = P.NewStroke(h, "ARTWORK", 4)
        h:SetScript("OnClick", function() P.ToggleForMeFold() end)
        h:SetScript("OnEnter", function(self)
            P.PlaceTooltip(self)
            GameTooltip:AddLine("For me", 1, 0.82, 0)
            GameTooltip:AddLine(T.NotesShared("tasks") and "Your own tasks, shared by every character on this account."
                or "This character's own tasks, kept between logins.", 0.9, 0.9, 0.9, true)
            if (self.hiddenCount or 0) > 0 then
                GameTooltip:AddLine(string.format("%d older task%s don't fit: make the tally taller to see them.", self.hiddenCount, self.hiddenCount == 1 and "" or "s"), 0.9, 0.75, 0.4, true)
            end
            GameTooltip:AddLine("Ticked off, a task goes to your Journal, stamped with the time.", 0.9, 0.9, 0.9, true)
            GameTooltip:AddLine(T.notes.forMeFolded and "Left-Click: open" or "Left-Click: fold away", 0.65, 0.65, 0.65)
            GameTooltip:Show()
        end)
        h:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.forMeHead = h
    end
    h.hiddenCount = hiddenCount
    P.SetInkFont(h.fs, "title")
    h.fs:SetTextColor(st.title[1], st.title[2], st.title[3], 1)
    local title = "For me"
    if st.initial then                       -- illuminated: the first letter in gold, as on the page heading
        title = "|c" .. P.Hex(st.initial) .. "F|r" .. "or me"
    end
    local n = #T.notes.tasks
    local note
    if T.notes.forMeFolded then
        if n > 0 then note = tostring(n) end
    elseif (hiddenCount or 0) > 0 then
        note = "+" .. hiddenCount
    end
    if note then title = title .. "  |c" .. P.Hex(st.sub or st.faded) .. "· " .. note .. "|r" end
    h.fs:SetText(title)
    P.SetHalo(h.fs, h.fs:GetText(), st.title)
    local headH = P.ForMeHeadHeight(f)
    h:SetHeight(headH)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, y)
    h:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", 0, y)
    -- the page heading's double underline, as long as the words (+22), under the writing
    local ruleW = math.min(w - 4, math.max(60, (h.fs:GetStringWidth() or 60) + 22))
    local ry = -(headH - 7)
    P.DrawStroke(h.rule, h, 2, ry, 2 + ruleW, ry + 1, 1.2, 0.70)
    P.DrawStroke(h.rule2, h, 8, ry - 2.5, 2 + ruleW * 0.55, ry - 2, 0.7, 0.40)
    h:Show()
end

-- One task, inked like a tally line (an empty box, full ink). Never drawn ticked: a task ticked off goes
-- to the Journal (P.TickTask).
function P.InkTaskRow(f, row, task, textW, st)
    P.StyleRow(row)
    P.SetRowFX(row, nil)
    P.SetRowLasso(row, false)
    row.box:Show()
    row.suffixText:Hide()
    if row.rewardText then row.rewardText:Hide() end
    P.HideStrikes(row)
    P.SetInkFont(row.itemText, "item")
    row.itemText:SetWidth(textW)
    local wa = st.wash
    row.box.wash:SetColorTexture(wa[1], wa[2], wa[3], wa[4])
    P.HideTick(row.box)
    local nameInk = st.name or st.ink
    row.itemText:SetTextColor(nameInk[1], nameInk[2], nameInk[3], 1)
    row.itemText:SetText(task.text)
    local strH = math.max(14, math.ceil(row.itemText:GetStringHeight() or 14))
    local ink = P.INK
    P.SetHalo(row.itemText, row.itemText:GetText(), ink)
    if P.EffectiveFont().drops then
        local lines, widths = P.WrapLines(f.measureFS, task.text, textW)
        P.SetInkDrops(row, { key = "forme" .. tostring(task.t or 0) .. task.text, lastW = widths[#widths] or 0,
            textH = strH, lines = #lines, textW = textW, ink = ink })
    else
        P.SetInkDrops(row, nil)
    end
    return strH + 7
end

function P.TaskTooltip(row, task)
    P.PlaceTooltip(row)
    GameTooltip:AddLine("To do", 1, 0.82, 0)
    GameTooltip:AddLine(task.text, 0.95, 0.95, 0.95, true)
    local pl = task.place
    local where = pl and (pl.subzone or pl.zone)
    if task.when or where then
        GameTooltip:AddLine("Written " .. (task.when or "") .. ((task.when and where) and " · " or "") .. (where or ""), 0.7, 0.7, 0.7)
    end
    local by = T.OtherOwner("tasks", task)        -- shared tasks: who wrote it
    if by then GameTooltip:AddLine("Written by " .. by, 0.7, 0.7, 0.7) end
    GameTooltip:AddLine("Left-Click: done (it goes to your Journal)  |  Right-Click: re-write", 0.65, 0.65, 0.65, true)
    GameTooltip:AddLine("Shift-Click: rub it out", 0.65, 0.65, 0.65)
    GameTooltip:Show()
end

-- The "For me" section, from y (<= 0, under the quest lines) to the bottom of the page. Only on "Near me".
function P.RenderForMe(f, area, y, contentW, contentH)
    if not (area and area.isCurrent and T.db.opts.forMe) then P.HideForMe(f) return end
    local st = P.GetStyle()
    f.forMeRows = f.forMeRows or {}
    for _, row in ipairs(f.forMeRows) do row:Hide() end
    local tasks = T.notes.tasks
    local editing = P.forMeEditing
    local eb = f.forMeEdit
    local textW = math.max(110, contentW - 24)
    local lineH = P.LineHeight(f)
    local writeH = math.max(14, lineH) + 7

    -- The section stands on the bottom of the page and grows upward a line at a time: the writing line
    -- at the very bottom, the tasks above it (in the order written), its heading on top. y is where the
    -- quest lines end; the section never rises above it. Tasks that don't fit: the newest stay, so the one
    -- just written is always in sight; the heading counts the older ones.
    local folded = T.notes.forMeFolded
    local room = contentH - math.abs(y)
    local headH = P.ForMeHeadHeight(f)
    local used = P.FORME_GAP + headH + (folded and 0 or writeH)
    local first = #tasks + 1
    if not folded then
        for i = #tasks, 1, -1 do
            local need = P.TaskRowHeight(f, tasks[i], textW, lineH)
            if used + need > room + 4 then break end
            used = used + need
            first = i
        end
    end
    y = math.min(y, -(contentH - used)) - P.FORME_GAP
    local headY = y
    y = y - headH

    if folded then
        P.DrawForMeHeading(f, headY, contentW, st, 0)
        if f.forMeWrite then f.forMeWrite:Hide() end
        if f.forMeNote then f.forMeNote:Hide() end
        if eb then eb:Hide() end
        return
    end

    local editRow = nil
    for i = first, #tasks do
        local task = tasks[i]
        local row = P.AcquireRow(i - first + 1, f.content, f.forMeRows)
        local rowH = P.InkTaskRow(f, row, task, textW, st)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", 0, y)
        row:SetHeight(rowH)
        row.taskY = y - 2
        row:SetScript("OnClick", function(_, button)
            local idx = P.TaskIndex(task)
            if not idx then return end
            if button == "RightButton" then
                P.BeginForMeEdit(idx)
            elseif IsShiftKeyDown and IsShiftKeyDown() then
                P.RubOutTask(idx)
            else
                P.TickTask(idx, row.taskY)
            end
        end)
        row:SetScript("OnEnter", function(self) P.TaskTooltip(self, task) end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        if editing and editing.index == i then
            -- being re-written: the box shows the words instead
            row.itemText:SetText("")
            P.SetHalo(row.itemText, "", P.INK)
            P.HideStrikes(row)
            P.SetInkDrops(row, nil)
            editRow = row
        end
        row:Show()
        y = y - rowH
    end
    P.DrawForMeHeading(f, headY, contentW, st, first - 1)

    -- the writing line: "+ add a task" in faded ink; click to write. The button is only as wide as its
    -- words: the rest of the bottom row, and the dog-ear in its corner, stay free for turning the page.
    local wl = f.forMeWrite
    if not wl then
        wl = CreateFrame("Button", nil, f.content)
        wl:RegisterForClicks("LeftButtonUp")
        wl.highlight = wl:CreateTexture(nil, "HIGHLIGHT")
        wl.highlight:SetAllPoints()
        -- the switch in front: a box (task) or a quill (entry); click to change what you're writing
        wl.mode = CreateFrame("Button", nil, wl)
        wl.mode:SetSize(15, 15)
        wl.mode:SetPoint("TOPLEFT", wl, "TOPLEFT", 2, -1)
        wl.mode:SetFrameLevel((f.baseLevel or 30) + 25)
        wl.mode:SetScript("OnClick", function(self)
            if not P.forMeEditing then P.StartWriting("task") return end      -- not typing: same as the line
            T.notes.writeMode = (P.WriteMode() == "entry") and "task" or "entry"
            T.Save()
            P.Render(f)
            P.ModeTooltip(self)
            if P.forMeEditing and f.forMeEdit then P.FocusBox(f.forMeEdit, function() return P.forMeEditing ~= nil end) end  -- keep writing
        end)
        wl.mode:SetScript("OnEnter", function(self)
            self.hover = true
            P.DrawWriteGlyph(self, self.glyphKind or "task", true)
            if P.forMeEditing then P.ModeTooltip(self) else wl:GetScript("OnEnter")(wl) end
        end)
        wl.mode:SetScript("OnLeave", function(self) self.hover = false; P.DrawWriteGlyph(self, self.glyphKind or "task", false); GameTooltip:Hide() end)
        wl.fs = wl:CreateFontString(nil, "OVERLAY")
        wl.fs:SetPoint("TOPLEFT", wl, "TOPLEFT", 20, -2)
        wl.fs:SetJustifyH("LEFT")
        wl.fs:SetWordWrap(false)
        wl:SetScript("OnClick", function() P.StartWriting("task") end)
        wl:SetScript("OnEnter", function(self)
            P.PlaceTooltip(self)
            GameTooltip:AddLine("Add a task", 1, 0.82, 0)
            GameTooltip:AddLine("Stays here in For me until you tick it off; then it goes to your Journal, stamped with the time.", 0.9, 0.9, 0.9, true)
            GameTooltip:AddLine("Enter: keep it  |  Escape: never mind  |  Also: /crq task <what to do>", 0.65, 0.65, 0.65, true)
            GameTooltip:Show()
        end)
        wl:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.forMeWrite = wl
    end
    -- "[quill] write a note": a note is stamped and goes to the Journal (the last page)
    local nl = f.forMeNote
    if not nl then
        nl = CreateFrame("Button", nil, f.content)
        nl:RegisterForClicks("LeftButtonUp")
        nl.highlight = nl:CreateTexture(nil, "HIGHLIGHT")
        nl.highlight:SetAllPoints()
        nl.glyph = CreateFrame("Frame", nil, nl)
        nl.glyph:SetSize(15, 15)
        nl.glyph:SetPoint("TOPLEFT", nl, "TOPLEFT", 2, -1)
        nl.fs = nl:CreateFontString(nil, "OVERLAY")
        nl.fs:SetPoint("TOPLEFT", nl, "TOPLEFT", 20, -2)
        nl.fs:SetJustifyH("LEFT")
        nl.fs:SetWordWrap(false)
        nl:SetScript("OnClick", function() P.StartWriting("entry") end)
        nl:SetScript("OnEnter", function(self)
            P.DrawWriteGlyph(self.glyph, "entry", true)
            P.PlaceTooltip(self)
            GameTooltip:AddLine("Write a note", 1, 0.82, 0)
            GameTooltip:AddLine("Stamped with the time and where you are, then kept in your Journal (the quill tab on the right).", 0.9, 0.9, 0.9, true)
            GameTooltip:AddLine("Enter: keep it  |  Escape: never mind  |  Also: /crq note <text>", 0.65, 0.65, 0.65, true)
            GameTooltip:Show()
        end)
        nl:SetScript("OnLeave", function(self) P.DrawWriteGlyph(self.glyph, "entry", false); GameTooltip:Hide() end)
        f.forMeNote = nl
    end
    local hl = st.highlight
    wl.highlight:SetColorTexture(hl[1], hl[2], hl[3], hl[4])
    nl.highlight:SetColorTexture(hl[1], hl[2], hl[3], hl[4])
    P.SetInkFont(wl.fs, "item")
    P.SetInkFont(nl.fs, "item")
    wl.fs:SetTextColor(st.faded[1], st.faded[2], st.faded[3], 1)
    nl.fs:SetTextColor(st.faded[1], st.faded[2], st.faded[3], 1)
    local writingNew = editing and not editing.index
    f.forMeWriteY = y
    local room = textW - P.CORNER_MAX          -- both choices stay clear of the dog-ear
    wl:ClearAllPoints()
    wl:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, y)
    wl:SetHeight(writeH)
    if writingNew then
        -- typing: the glyph in front says (and switches) what this becomes; the choices step aside
        P.DrawWriteGlyph(wl.mode, P.WriteMode(), wl.mode.hover)
        wl.fs:SetText("")
        wl.fs:SetWidth(1)
        wl:SetWidth(20)
        nl:Hide()
    else
        -- two choices side by side, each only as wide as its words; shorter words when the page is narrow
        P.DrawWriteGlyph(wl.mode, "task", wl.mode.hover)
        P.DrawWriteGlyph(nl.glyph, "entry", false)
        local GAP = 10
        local labels = { { "add a task...", "write a note..." }, { "a task", "a note" }, { "task", "note" } }
        local w1, w2
        for _, pair in ipairs(labels) do
            wl.fs:SetText(pair[1]); nl.fs:SetText(pair[2])
            w1 = math.ceil(wl.fs:GetStringWidth() or 0)
            w2 = math.ceil(nl.fs:GetStringWidth() or 0)
            if (20 + w1 + 6) + GAP + (20 + w2 + 6) <= room then break end
        end
        wl.fs:SetWidth(math.max(1, w1))
        nl.fs:SetWidth(math.max(1, w2))
        wl:SetWidth(20 + w1 + 6)
        nl:ClearAllPoints()
        nl:SetPoint("TOPLEFT", f.content, "TOPLEFT", 20 + w1 + 6 + GAP, y)
        nl:SetWidth(20 + w2 + 6)
        nl:SetHeight(writeH)
        nl:Show()
    end
    wl:Show()

    -- the writing box, over the line being written
    if editing then
        eb = P.EnsureForMeEditBox(f)
        P.SetInkFont(eb, "item")
        eb:SetTextColor(P.INK[1], P.INK[2], P.INK[3], 1)
        eb.wash:SetColorTexture(hl[1], hl[2], hl[3], (hl[4] or 0.1) * 1.5)
        eb:ClearAllPoints()
        local anchor = editRow and editRow.itemText or wl.fs
        eb:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 2)
        eb:SetWidth(math.max(60, textW - P.CORNER_MAX))     -- clear of the dog-ear (at its biggest)
        eb:SetHeight(math.max(16, lineH + 4))
        eb:Show()
    elseif eb then
        eb:Hide()
    end
end

-- ----------------------------------------------------------------------------
-- JOURNAL: longer entries, newest first, on the last page of the pile
-- ----------------------------------------------------------------------------
-- T.notes.journal = { { text, t, when, place, owner }, ... } in the order written (drawn newest first).
-- Written from the "For me" line ("write a note..."), or on the Journal page itself. The page is reached
-- with its quill tab, the dog-ear or /crq journal. Not an area page: never merged, never counted in
-- P.MAX_AREAS.
P.JOURNAL_KEY = "JOURNAL"
P.ENTRY_MAX_LETTERS = 2000
P.NOTE_MAX_ENTRIES = 1000
P.JOURNAL_EDIT_LINES = 4          -- the writing box is at least this many lines tall
P.FLY_DUR = 0.7                   -- a note written in "For me" flies off to the Journal tab this long

-- Writing glyphs (inked strokes like the item / task toggles): a box = a task, a quill = an entry
P.WRITE_GLYPHS = {
    task = {       -- an empty hand-inked box, like a task line's
        { 2, -2.5, 11.5, -2, 1.05 }, { 11.5, -2, 11.8, -11.5, 1.05 }, { 11.8, -11.5, 2.2, -11.8, 1.05 }, { 2.2, -11.8, 2, -2.5, 1.05 },
    },
    done = {       -- the box ticked: after a "Done: ..." entry's stamp (a task ticked off in "For me")
        { 2, -2.5, 11.5, -2, 1.05 }, { 11.5, -2, 11.8, -11.5, 1.05 }, { 11.8, -11.5, 2.2, -11.8, 1.05 }, { 2.2, -11.8, 2, -2.5, 1.05 },
        { 3.8, -7.2, 6.4, -10.2, 1.3 }, { 6.4, -10.2, 13.8, -0.6, 1.2 },
    },
    entry = {      -- a quill: shaft from the nib (bottom-left) up to the right, vanes along it
        { 1.5, -13.5, 12.5, -2, 1.1 },                                     -- shaft
        { 5.5, -9.2, 7.8, -4.5, 0.8 }, { 7.8, -4.5, 12.5, -2, 0.8 },        -- upper vane
        { 5.5, -9.2, 10.4, -7.6, 0.8 }, { 10.4, -7.6, 12.5, -2, 0.8 },      -- lower vane
        { 1.5, -13.5, 2.6, -11.2, 1.6 },                                    -- nib
    },
}

do
    local pts, star = {}, {}
    for k = 0, 4 do
        local ang = math.rad(90 + 72 * k)
        pts[k + 1] = { 6.5 + 4.6 * math.cos(ang), -6.5 + 4.6 * math.sin(ang) }
    end
    for k = 0, 4 do
        local p, q = pts[k + 1], pts[(k + 2) % 5 + 1]
        star[k + 1] = { p[1], p[2], q[1], q[2], 0.8 }
    end
    P.WRITE_GLYPHS.auto = star      -- after an auto entry's stamp: written by the addon, not by you
    -- the Journal's search: a magnifier (a loop of 8 strokes and a thick handle)
    local mag = {}
    for k = 0, 7 do
        local a, b = math.rad(45 * k + 10), math.rad(45 * (k + 1) + 10)
        mag[k + 1] = { 5.8 + 3.9 * math.cos(a), -5.8 + 3.9 * math.sin(a), 5.8 + 3.9 * math.cos(b), -5.8 + 3.9 * math.sin(b), 0.95 }
    end
    mag[9] = { 8.8, -8.8, 12.8, -12.8, 1.7 }
    P.WRITE_GLYPHS.search = mag
end
-- the Journal's calendar: a page with two rings, a band along the top, day marks
P.WRITE_GLYPHS.calendar = {
    { 1.8, -3, 12.2, -3, 1 }, { 12.2, -3, 12.2, -12.6, 1 }, { 12.2, -12.6, 1.8, -12.6, 1 }, { 1.8, -12.6, 1.8, -3, 1 },
    { 1.8, -5.9, 12.2, -5.9, 0.9 },
    { 4.6, -1.2, 4.6, -4.4, 1.3 }, { 9.4, -1.2, 9.4, -4.4, 1.3 },
    { 3.9, -8.4, 5.2, -8.4, 1.4 }, { 6.4, -8.4, 7.7, -8.4, 1.4 }, { 8.9, -8.4, 10.2, -8.4, 1.4 },
    { 3.9, -10.7, 5.2, -10.7, 1.4 }, { 6.4, -10.7, 7.7, -10.7, 1.4 },
}
P.WRITE_GLYPHS.prev = { { 8.5, -3, 4.5, -7, 1.2 }, { 4.5, -7, 8.5, -11, 1.2 } }       -- the month before: <
P.WRITE_GLYPHS.next = { { 5.5, -3, 9.5, -7, 1.2 }, { 9.5, -7, 5.5, -11, 1.2 } }       -- the month after: >

-- What the player wrote for an entry: several lines allowed, no "|" (colour / link escapes)
function T.CleanEntryText(s)
    s = tostring(s or "")
    s = string.gsub(s, "|", "")
    s = string.gsub(s, "\r", "")
    s = string.gsub(s, "\t", " ")
    s = string.gsub(s, "\n[ ]*\n[%s]*\n", "\n\n")          -- at most one blank line in a row
    s = string.match(s, "^%s*(.-)%s*$") or ""
    if string.len(s) > P.ENTRY_MAX_LETTERS then s = string.sub(s, 1, P.ENTRY_MAX_LETTERS) end
    return s
end

function T.AddEntry(text)
    text = T.CleanEntryText(text)
    if text == "" then return nil end
    local journal = T.notes.journal
    while #journal >= P.NOTE_MAX_ENTRIES do table.remove(journal, 1) end    -- the oldest makes room
    local t, when = T.NoteTime()
    local e = { text = text, t = t, when = when, place = T.HerePlace(), owner = T.NoteOwner() }
    table.insert(journal, e)
    return e
end

-- ---- auto entries: the Journal writes some things down by itself (each its own switch in the options) ----
-- An auto entry has auto = its kind ("achievement" / "quest" / "level") and is drawn in faded ink with a
-- small inked star after its stamp, so the player's own writing stands out (a level reached: full ink,
-- glowing gold). Ones of a kind within P.AUTO_MERGE seconds in the same place share an entry ("Earned 3
-- achievements: ..."), unless the player has re-written it (autoText).
P.AUTO_MERGE = 300

-- Only offered when this client has achievements (the event was registered: see EVENTS below)
function T.AchievementsSupported()
    return T.achievementEvent == true and type(GetAchievementInfo) == "function"
end

function T.AchievementInfo(id)
    if type(GetAchievementInfo) ~= "function" or type(id) ~= "number" then return nil end
    -- id, name, points, completed, month, day, year, description, flags, icon, rewardText, isGuild
    local ok, _, name, points, _, _, _, _, description, _, _, _, isGuild = pcall(GetAchievementInfo, id)
    if not ok or type(name) ~= "string" or name == "" then return nil end
    return { name = T.CleanName(name), points = tonumber(points) or 0,
        description = (type(description) == "string" and description ~= "") and description or nil, isGuild = isGuild and true or false }
end

function P.AchievementText(list)
    local pts = 0
    for _, a in ipairs(list) do pts = pts + (a.points or 0) end
    local ptsStr = (pts > 0) and string.format(" (%d point%s)", pts, (pts == 1) and "" or "s") or ""
    if #list == 1 then return "Earned the achievement \"" .. list[1].name .. "\"" .. ptsStr .. "." end
    local names = {}
    for i, a in ipairs(list) do names[i] = "\"" .. a.name .. "\"" end
    local lastName = table.remove(names)
    return string.format("Earned %d achievements: %s and %s%s.", #list, table.concat(names, ", "), lastName, ptsStr)
end

-- The last entry, if a new auto entry of this kind should join it: written by the addon within
-- P.AUTO_MERGE seconds, in the same place, and not re-written by the player since
function P.AutoMergeTarget(kind, listKey)
    local journal = T.notes.journal
    local last = journal[#journal]
    if not (last and last.auto == kind and last[listKey] and last.text == last.autoText and last.t) then return nil end
    local t = T.NoteTime()
    if t - last.t > P.AUTO_MERGE then return nil end
    local here = T.HerePlace()
    if P.EntryPlaceName(last) ~= (here.subzone or here.zone) then return nil end
    return last
end

-- Write one thing down (it goes in entry[listKey]); textFn(list) words the entry, sameFn spots a repeat
function P.WriteAuto(kind, listKey, thing, textFn, sameFn)
    local e = P.AutoMergeTarget(kind, listKey)
    if e then
        for _, x in ipairs(e[listKey]) do if sameFn(x, thing) then return e end end    -- told twice
        table.insert(e[listKey], thing)
        e.text = T.CleanEntryText(textFn(e[listKey]))
        e.autoText = e.text
    else
        e = T.AddEntry(textFn({ thing }))
        if not e then return nil end
        e.auto, e[listKey], e.autoText = kind, { thing }, e.text
    end
    T.Save()
    T.SafeCall(T.Update)
    P.TugJournalTab()
    return e
end

-- A name from the game, safe to write: colour codes off, then no "|" at all
function T.CleanName(s)
    s = T.Plain(s)
    if type(s) ~= "string" then return "" end
    s = string.gsub(string.gsub(s, "|c%x%x%x%x%x%x%x%x", ""), "|r", "")
    return T.CleanNoteText(s)
end

function T.OnAchievementEarned(id)
    if not (T.db.opts.forMe and T.db.opts.autoAchievements) then return nil end
    local info = T.AchievementInfo(tonumber(id))
    if not info or info.isGuild then return nil end            -- the guild's achievement isn't yours to write down
    return P.WriteAuto("achievement", "achievements", { id = tonumber(id), name = info.name, points = info.points },
        P.AchievementText, function(a, b) return a.id == b.id end)
end

-- ---- level ups: "Reached level 12.", glowing gold in the Journal (P.SetGlow) ----------------------------
-- Several within P.AUTO_MERGE in one place share an entry: "Reached levels 11 and 12."
function P.LevelText(list)
    if #list == 1 then return "Reached level " .. list[1].level .. "." end
    local n = {}
    for i, l in ipairs(list) do n[i] = tostring(l.level) end
    local last = table.remove(n)
    return "Reached levels " .. table.concat(n, ", ") .. " and " .. last .. "."
end

function T.OnLevelUp(level)
    if not (T.db.opts.forMe and T.db.opts.autoLevels) then return nil end
    level = tonumber(level)
    if not level or level < 2 then return nil end
    return P.WriteAuto("level", "levels", { level = level }, P.LevelText, function(a, b) return a.level == b.level end)
end

-- ---- quests turned in, and what they gave ----------------------------------------------------------
-- The reward panel is read as it opens (QUEST_COMPLETE): the items always given and the ones to choose
-- from; the one taken comes from GetQuestReward(choice) (hooked). QUEST_TURNED_IN then brings the xp and
-- money. A quest that completes itself (no reward panel: a world quest, a bonus objective) is written with
-- its xp and money only, but only if it was in your quest log (retail also "turns in" hidden tracking
-- quests, which aren't worth a note).
P.TURN_IN_WAIT = 15         -- seconds a reward panel read without a quest ID stays good for

function P.RewardItem(kind, i)
    local ok, name, _, count, quality, _, itemID = pcall(GetQuestItemInfo, kind, i)
    name = ok and T.CleanName(name) or ""
    if name == "" then return nil end
    local link
    if GetQuestItemLink then
        local okL, l = pcall(GetQuestItemLink, kind, i)
        l = okL and T.Plain(l) or nil
        if type(l) == "string" and l ~= "" then link = l end
    end
    return { name = name, count = tonumber(T.Plain(count)) or 1, quality = tonumber(T.Plain(quality)), id = tonumber(T.Plain(itemID)), link = link }
end

function T.OnQuestComplete()
    P.questTurnIn = nil
    if type(GetQuestItemInfo) ~= "function" then return end
    local qid = T.Call(GetQuestID)
    local title = T.Call(GetTitleText)
    local snap = { questID = (type(qid) == "number" and qid > 0) and qid or nil,
        title = T.CleanName(title), items = {}, choices = {}, at = GetTime and GetTime() or 0 }
    local nR = T.Call(GetNumQuestRewards)
    for i = 1, (tonumber(nR) or 0) do
        local it = P.RewardItem("reward", i)
        if it then table.insert(snap.items, it) end
    end
    snap.numChoices = tonumber(T.Call(GetNumQuestChoices)) or 0
    for i = 1, snap.numChoices do snap.choices[i] = P.RewardItem("choice", i) or false end
    P.questTurnIn = snap
end

function T.OnQuestRewardChosen(choice)
    if P.questTurnIn then P.questTurnIn.choice = tonumber(choice) end
end

function P.MoneyText(c)
    c = math.floor(tonumber(c) or 0)
    local parts = {}
    local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if k > 0 then parts[#parts + 1] = k .. "c" end
    return table.concat(parts, " ")
end

function P.JoinAnd(list)
    if #list == 0 then return "" end
    if #list == 1 then return list[1] end
    return table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end

function P.RewardText(q)
    local parts = {}
    for _, it in ipairs(q.items or {}) do
        parts[#parts + 1] = ((it.count or 1) > 1) and (it.count .. " " .. it.name) or it.name
    end
    if (q.xp or 0) > 0 then parts[#parts + 1] = q.xp .. " xp" end
    if (q.money or 0) > 0 then parts[#parts + 1] = P.MoneyText(q.money) end
    return P.JoinAnd(parts)
end

function P.QuestText(list)
    if #list == 1 then
        local q, r = list[1], P.RewardText(list[1])
        return "Turned in \"" .. q.title .. "\"" .. ((r ~= "") and (" and received " .. r) or "") .. "."
    end
    local lines = { "Turned in " .. #list .. " quests:" }
    for _, q in ipairs(list) do
        local r = P.RewardText(q)
        lines[#lines + 1] = "\"" .. q.title .. "\"" .. ((r ~= "") and (": " .. r) or "") .. "."
    end
    return table.concat(lines, "\n")
end

-- A quest turned in without a reward panel and not on the tally: still in your quest log, or a world quest
function P.QuestWasReal(questID)
    if not (questID and C_QuestLog) then return false end
    local idx = C_QuestLog.GetLogIndexForQuestID and T.Call(C_QuestLog.GetLogIndexForQuestID, questID)
    if type(idx) == "number" and idx > 0 then return true end
    return (C_QuestLog.IsWorldQuest and T.Call(C_QuestLog.IsWorldQuest, questID)) == true
end

function T.OnQuestTurnedIn(questID, xp, money)
    local snap = P.questTurnIn
    P.questTurnIn = nil
    if not (T.db.opts.forMe and T.db.opts.autoQuests) then return nil end
    questID = tonumber(questID)
    if snap then      -- the reward panel read for this very quest (or, without IDs, just now)
        local same
        if snap.questID and questID then same = (snap.questID == questID)
        else same = ((GetTime and GetTime() or 0) - (snap.at or 0)) <= P.TURN_IN_WAIT end
        if not same then snap = nil end
    end
    local known = questID and T.quests[questID]
    if not snap and not known and not P.QuestWasReal(questID) then return nil end   -- a hidden tracking quest
    local title = snap and snap.title or ""
    if title == "" and known then title = T.CleanName(known.title) end
    if title == "" and questID and C_QuestLog and C_QuestLog.GetTitleForQuestID then
        title = T.CleanName(T.Call(C_QuestLog.GetTitleForQuestID, questID))
    end
    if title == "" then return nil end
    local q = { id = questID, title = title, xp = tonumber(xp) or 0, money = tonumber(money) or 0, items = {} }
    if snap then
        for _, it in ipairs(snap.items) do table.insert(q.items, it) end
        local c = snap.choice
        if (not c or c < 1) and snap.numChoices == 1 then c = 1 end      -- one to choose: it's given
        local pick = c and snap.choices[c]
        if pick then table.insert(q.items, pick) end
    end
    return P.WriteAuto("quest", "quests", q, P.QuestText, function(a, b) return a.id ~= nil and a.id == b.id end)
end

function P.EntryPlaceName(e)
    local pl = e and e.place
    return pl and (pl.subzone or pl.zone) or nil
end

function P.EntryStamp(e)
    local where = P.EntryPlaceName(e)
    local s = (e.when and where) and (e.when .. "  ·  " .. where) or (e.when or where or "")
    local by = T.OtherOwner("journal", e)          -- a shared Journal: whose note it is
    if by then s = (s ~= "") and (s .. "  ·  " .. by) or by end
    return s
end

function P.WriteMode()
    return (T.notes.writeMode == "entry") and "entry" or "task"
end

function P.IsWriting()
    return (P.forMeEditing or P.journalEditing or P.journalSearching) and true or false
end

-- The Journal's page in the pile (P.areas): always the last one while "For me" is on
function P.JournalArea()
    return { key = P.JOURNAL_KEY, title = "Journal", isJournal = true, items = {}, quests = {}, subtitle = P.JournalSubtitle() }
end

-- The entries shown: newest first; only those written in P.journalFilter's place, on P.journalDay and
-- with P.journalSearch's words, when they're picked
function P.JournalList()
    local list = {}
    local journal = T.notes.journal
    local terms = P.SearchTerms(P.journalSearch)
    local day = P.journalDay
    local dayKey = day and P.DayKey(day.y, day.m, day.d)
    for i = #journal, 1, -1 do
        local e = journal[i]
        if (not P.journalFilter or P.EntryPlaceName(e) == P.journalFilter) and P.EntryMatches(e, terms)
            and (not dayKey or P.DayKey(P.EntryDay(e)) == dayKey) then
            table.insert(list, e)
        end
    end
    return list
end

-- Opens the tally on the Journal page (/crq journal)
function P.OpenJournal()
    if not T.db.opts.forMe then
        print("|cFFFFD100" .. DISPLAY_NAME .. ":|r the Journal comes with \"For me\": switch it on in the options.")
        return
    end
    P.selectedKey = P.JOURNAL_KEY
    T.scroll = 0
    if T.db.show then T.Update() else P.TurnTallyOn() end
    T.Save()
end

function P.ToggleJournalFilter(e)
    local name = P.EntryPlaceName(e)
    if P.journalFilter or not name then P.journalFilter = nil else P.journalFilter = name end
    T.scroll = 0
    T.Update()
end

function P.RubOutEntry(e)
    for i, x in ipairs(T.notes.journal) do
        if x == e then table.remove(T.notes.journal, i) break end
    end
    P.ForMeChanged()
end

-- ---- finding notes again: a search and a calendar --------------------------------------------------
-- Two inked glyphs at the right end of the Journal's writing line: a magnifier and a calendar.
-- P.journalSearch = the words looked for (every word must be in the note, its stamp or what it lists;
-- the words are marked in red ink), P.journalDay = { y, m, d } (only that day's notes),
-- P.journalCalendar = { y, m } while a month is open on the page. They and the place filter
-- (P.journalFilter) all apply together; the heading and footer say which.
P.JOURNAL_TOOL = 14               -- the glyphs' size
P.JOURNAL_TOOL_GAP = 5
P.MONTH_NAMES = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December" }
P.DAY_NAMES = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
P.MONTH_INDEX = {}
for i, m in ipairs(P.MONTHS) do P.MONTH_INDEX[m] = i end

function P.SearchTerms(q)
    local terms = {}
    for w in string.gmatch(string.lower(q or ""), "%S+") do terms[#terms + 1] = w end
    return terms
end

-- Everything a note can be found by: its words, stamp, place, writer and what an auto entry lists
function P.EntryHaystack(e)
    local parts = { e.text or "", e.when or "" }
    local pl = e.place
    if pl then parts[#parts + 1] = pl.subzone or ""; parts[#parts + 1] = pl.zone or "" end
    if e.owner then parts[#parts + 1] = e.owner end
    for _, a in ipairs(e.achievements or {}) do parts[#parts + 1] = a.name or "" end
    for _, q in ipairs(e.quests or {}) do
        parts[#parts + 1] = q.title or ""
        for _, it in ipairs(q.items or {}) do parts[#parts + 1] = it.name or "" end
    end
    for _, l in ipairs(e.levels or {}) do parts[#parts + 1] = "level " .. tostring(l.level) end
    if e.doneTask then parts[#parts + 1] = e.doneTask.text or "" end
    return string.lower(table.concat(parts, "\n"))
end

function P.EntryMatches(e, terms)
    if not terms or #terms == 0 then return true end
    local hay = P.EntryHaystack(e)
    for _, w in ipairs(terms) do
        if not string.find(hay, w, 1, true) then return false end
    end
    return true
end

-- The words looked for, marked in hex ink (overlapping finds merged; no codes inside codes)
function P.MarkMatches(text, terms, hex)
    if not text or text == "" or not terms or #terms == 0 then return text end
    local low = string.lower(text)
    local spans = {}
    for _, w in ipairs(terms) do
        local s = 1
        while true do
            local a, b = string.find(low, w, s, true)
            if not a then break end
            spans[#spans + 1] = { a, b }
            s = b + 1
        end
    end
    if #spans == 0 then return text end
    table.sort(spans, function(x, y) return x[1] < y[1] end)
    local merged = { spans[1] }
    for i = 2, #spans do
        local last, sp = merged[#merged], spans[i]
        if sp[1] <= last[2] + 1 then
            if sp[2] > last[2] then last[2] = sp[2] end
        else
            merged[#merged + 1] = { sp[1], sp[2] }
        end
    end
    local out, pos = {}, 1
    for _, sp in ipairs(merged) do
        out[#out + 1] = string.sub(text, pos, sp[1] - 1)
        out[#out + 1] = "|c" .. hex .. string.sub(text, sp[1], sp[2]) .. "|r"
        pos = sp[2] + 1
    end
    out[#out + 1] = string.sub(text, pos)
    return table.concat(out)
end

-- Dates: the stamp's day and month (the realm calendar), the year from the note's server time
function P.DateTable(t)
    local fn = date or (os and os.date)
    if not (fn and t) then return nil end
    local ok, c = pcall(fn, "*t", t)
    return (ok and type(c) == "table") and c or nil
end

function P.Today()
    if C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime then
        local ok, c = pcall(C_DateAndTime.GetCurrentCalendarTime)
        if ok and type(c) == "table" and c.year and c.month and c.monthDay then
            return { y = c.year, m = c.month, d = c.monthDay }
        end
    end
    local c = P.DateTable((time and time()) or (os and os.time and os.time()))
    if c then return { y = c.year, m = c.month, d = c.day } end
    return { y = 2026, m = 1, d = 1 }
end

function P.EntryDay(e)
    local c = P.DateTable(e.t)
    local d, mon
    if e.when then d, mon = string.match(e.when, "^(%d+) (%a+)") end
    local m = mon and P.MONTH_INDEX[mon]
    d = tonumber(d)
    if m and d then
        local y = c and c.year or P.Today().y
        if c and m == 12 and c.month == 1 then y = y - 1 end          -- the realm's New Year's Eve, the PC's New Year
        if c and m == 1 and c.month == 12 then y = y + 1 end
        return y, m, d
    end
    if c then return c.year, c.month, c.day end
    return nil
end

function P.DayKey(y, m, d) return (y or 0) * 10000 + (m or 0) * 100 + (d or 0) end

function P.DaysInMonth(y, m)
    local n = ({ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[m] or 30
    if m == 2 and ((y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0) then n = 29 end
    return n
end

function P.Weekday(y, m, d)           -- 1 = Sunday ... 7 = Saturday (Sakamoto)
    local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
    if m < 3 then y = y - 1 end
    return (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + t[m] + d) % 7 + 1
end

function P.FirstWeekday()             -- the game's calendar setting (1 = weeks start on Sunday, 2 = Monday)
    local w = tonumber(CALENDAR_FIRST_WEEKDAY)
    return (w and w >= 1 and w <= 7) and math.floor(w) or 1
end

function P.DayLabel(day)
    if not day then return "" end
    local s = day.d .. " " .. (P.MONTHS[day.m] or "?")
    if day.y ~= P.Today().y then s = s .. " " .. day.y end
    return s
end

-- What's picked, for the heading ("Goldshire · 10 Nov · "wolf"") and the footer (" in ... on ... with ...")
function P.JournalSubtitle()
    local parts = {}
    if P.journalFilter then parts[#parts + 1] = P.journalFilter end
    if P.journalDay then parts[#parts + 1] = P.DayLabel(P.journalDay) end
    if P.journalSearch then parts[#parts + 1] = "\"" .. P.journalSearch .. "\"" end
    return (#parts > 0) and table.concat(parts, " · ") or nil
end

function P.JournalFilterWords()
    local s = ""
    if P.journalFilter then s = s .. " in " .. P.journalFilter end
    if P.journalDay then s = s .. " on " .. P.DayLabel(P.journalDay) end
    if P.journalSearch then s = s .. " with \"" .. P.journalSearch .. "\"" end
    return s
end

-- A filter changed: back to the top, heading re-written, page redrawn (without re-reading the quests)
function P.JournalRefresh()
    T.scroll = 0
    for _, a in ipairs(P.areas or {}) do
        if a.isJournal then a.subtitle = P.JournalSubtitle() end
    end
    local f = T.frame
    if f and f:IsShown() then P.Render(f) end
end

-- One of the Journal's glyph buttons (magnifier, calendar, the month's < >)
function P.NewJournalTool(parent, kind, onClick, tipFn)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(P.JOURNAL_TOOL, P.JOURNAL_TOOL)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.kind = kind
    b:SetScript("OnClick", function(self, button) onClick(self, button) end)
    b:SetScript("OnEnter", function(self)
        self.hover = true
        P.DrawWriteGlyph(self, self.kind, true, self.on)
        if tipFn then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            tipFn(self)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.hover = false
        P.DrawWriteGlyph(self, self.kind, false, self.on)
        GameTooltip:Hide()
    end)
    return b
end

function P.EnsureJournalTools(f)
    if f.journalTools then return f.journalTools end
    local t = {}
    t.search = P.NewJournalTool(f.content, "search", function(_, button)
        if button == "RightButton" then P.ClearJournalSearch() return end
        if P.journalSearching then P.CloseJournalSearch() else P.OpenJournalSearch() end
    end, function()
        if P.journalSearch then
            GameTooltip:AddLine("Showing notes with \"" .. P.journalSearch .. "\"", 1, 0.82, 0)
            GameTooltip:AddLine("Click: change the words  |  Right-Click: every note again", 0.65, 0.65, 0.65, true)
        else
            GameTooltip:AddLine("Search the Journal", 1, 0.82, 0)
            GameTooltip:AddLine("Type a word or two: only notes with all of them stay, the words marked in red. Looks in the notes, their stamps (date, place) and what an auto note lists (quests, items, achievements).", 0.9, 0.9, 0.9, true)
            GameTooltip:AddLine("Enter: keep it  |  Escape: stop searching", 0.65, 0.65, 0.65)
        end
    end)
    t.calendar = P.NewJournalTool(f.content, "calendar", function(_, button)
        if button == "RightButton" then
            P.journalDay, P.journalCalendar = nil, nil
            P.JournalRefresh()
            return
        end
        P.ToggleJournalCalendar()
    end, function()
        if P.journalDay then
            GameTooltip:AddLine("Showing notes from " .. P.DayLabel(P.journalDay), 1, 0.82, 0)
            GameTooltip:AddLine("Click: the calendar  |  Right-Click: every day again", 0.65, 0.65, 0.65, true)
        else
            GameTooltip:AddLine(P.journalCalendar and "Close the calendar" or "Calendar", 1, 0.82, 0)
            GameTooltip:AddLine("A month on the page: the days you wrote on are circled. Click one to see what you wrote that day.", 0.9, 0.9, 0.9, true)
        end
    end)
    f.journalTools = t
    return t
end

-- ---- the search line: one box where "write a note..." was, filtering as you type ----------------
function P.EnsureJournalSearchBox(f)
    if f.journalSearchBox then return f.journalSearchBox end
    local eb = CreateFrame("EditBox", nil, f.content)
    P.SetInkFont(eb, "item")              -- a font first: WoW won't take text into a box without one
    eb:SetAutoFocus(false)
    eb:EnableMouse(true)
    eb:SetScript("OnMouseDown", function(self) self:SetFocus() end)
    eb:SetMultiLine(false)
    eb:SetMaxLetters(60)
    eb:SetFrameLevel((f.baseLevel or 30) + 24)
    eb:SetJustifyH("LEFT")
    eb.wash = eb:CreateTexture(nil, "BACKGROUND")
    eb.wash:SetPoint("TOPLEFT", eb, "TOPLEFT", -3, 1)
    eb.wash:SetPoint("BOTTOMRIGHT", eb, "BOTTOMRIGHT", 3, -1)
    eb.glyph = CreateFrame("Frame", nil, f.content)
    eb.glyph:SetSize(14, 14)
    eb:SetScript("OnTextChanged", function(self)
        if not P.journalSearching then return end
        local q = T.CleanNoteText(self:GetText() or "")
        q = (q ~= "") and q or nil
        if q ~= P.journalSearch then
            P.journalSearch = q
            P.JournalRefresh()
        end
    end)
    eb:SetScript("OnEnterPressed", function() P.CloseJournalSearch() end)
    eb:SetScript("OnEscapePressed", function() P.ClearJournalSearch() end)
    eb:SetScript("OnEditFocusLost", function(self)
        if P.journalSearching and P.FocusGrace(self) then return end
        if P.journalSearching then P.CloseJournalSearch(true) end
    end)
    eb:SetScript("OnHide", function(self) if self.HasFocus and self:HasFocus() then self:ClearFocus() end end)
    eb:Hide()
    eb.glyph:Hide()
    f.journalSearchBox = eb
    return eb
end

function P.OpenJournalSearch()
    local f = T.frame
    if not f then return end
    if P.journalEditing then P.CommitJournalEdit() end
    P.journalCalendar = nil
    local eb = P.EnsureJournalSearchBox(f)
    P.SetInkFont(eb, "item")
    eb:SetText(P.journalSearch or "")
    P.journalSearching = true
    P.JournalRefresh()
    P.FocusBox(eb, function() return P.journalSearching end)
end

-- Enter / clicking away: the box closes, the search stays (the magnifier in full ink says so)
function P.CloseJournalSearch(deferRedraw)
    if not P.journalSearching then return end
    P.journalSearching = nil
    local f = T.frame
    local eb = f and f.journalSearchBox
    if eb then eb:ClearFocus(); eb:Hide(); eb.glyph:Hide() end
    if deferRedraw and C_Timer and C_Timer.After then
        C_Timer.After(0, function() P.JournalRefresh() end)
    else
        P.JournalRefresh()
    end
end

-- Escape / right-click on the magnifier: every note again
function P.ClearJournalSearch()
    P.journalSearch = nil
    if P.journalSearching then P.CloseJournalSearch() else P.JournalRefresh() end
end

-- ---- the calendar: a month written on the page ------------------------------------------------
function P.ToggleJournalCalendar()
    if P.journalCalendar then
        P.journalCalendar = nil
    else
        if P.journalSearching then P.CloseJournalSearch() end
        if P.journalEditing then P.CommitJournalEdit() end
        local d = P.journalDay or P.Today()
        P.journalCalendar = { y = d.y, m = d.m }
    end
    P.JournalRefresh()
end

function P.ShiftCalendar(step)
    local c = P.journalCalendar
    if not c then return end
    local m = c.m + step
    c.y = c.y + math.floor((m - 1) / 12)
    c.m = (m - 1) % 12 + 1
    P.JournalRefresh()
end

-- The notes of each day in a month that pass the other filters (place, search): { [d] = { e, ... } }
function P.NotesByDay(y, m)
    local days, terms = {}, P.SearchTerms(P.journalSearch)
    local journal = T.notes.journal
    for i = #journal, 1, -1 do
        local e = journal[i]
        if (not P.journalFilter or P.EntryPlaceName(e) == P.journalFilter) and P.EntryMatches(e, terms) then
            local ey, em, ed = P.EntryDay(e)
            if ey == y and em == m and ed then
                days[ed] = days[ed] or {}
                table.insert(days[ed], e)
            end
        end
    end
    return days
end

function P.PickJournalDay(day)
    local cur = P.journalDay
    if cur and cur.y == day.y and cur.m == day.m and cur.d == day.d then
        P.journalDay = nil                                   -- the circled day again: every day
    else
        P.journalDay = { y = day.y, m = day.m, d = day.d }
    end
    P.journalCalendar = nil
    P.JournalRefresh()
end

-- The calendar's "today": browsing another month = back to this one; on this month already = straight
-- to today's notes (picked, never un-picked, by this button)
function P.CalendarToday()
    local t = P.Today()
    local cal = P.journalCalendar
    if cal and (cal.y ~= t.y or cal.m ~= t.m) then
        cal.y, cal.m = t.y, t.m
    else
        P.journalDay = { y = t.y, m = t.m, d = t.d }
        P.journalCalendar = nil
    end
    P.JournalRefresh()
end

-- "today" in the sub ink with a quill underline; red on hover
function P.DrawTodayButton(b)
    local st = P.GetStyle()
    local ink = b.hover and P.INK_RED or (st.sub or st.faded)
    b.fs:SetTextColor(ink[1], ink[2], ink[3], 1)
    local w = math.ceil(b.fs:GetStringWidth() or 24)
    local x0 = ((b:GetWidth() or (w + 6)) - w) / 2
    local y = -(P.JOURNAL_TOOL + 1)
    P.DrawStroke(b.underline, b, x0, y + 0.3, x0 + w, y - 0.2, 0.9, b.hover and 0.9 or 0.5, ink)
end

function P.EnsureJournalCalendar(f)
    if f.journalCal then return f.journalCal end
    local c = CreateFrame("Frame", nil, f.content)
    c.title = c:CreateFontString(nil, "OVERLAY")
    c.title:SetJustifyH("CENTER")
    c.title:SetWordWrap(false)
    c.prev = P.NewJournalTool(c, "prev", function() P.ShiftCalendar(-1) end,
        function() GameTooltip:AddLine("Month before", 1, 0.82, 0) end)
    c.next = P.NewJournalTool(c, "next", function() P.ShiftCalendar(1) end,
        function() GameTooltip:AddLine("Month after", 1, 0.82, 0) end)
    -- "today": back to this month; on this month already, today's notes
    local tb = CreateFrame("Button", nil, c)
    tb:RegisterForClicks("LeftButtonUp")
    tb.fs = tb:CreateFontString(nil, "OVERLAY")
    tb.fs:SetPoint("CENTER", tb, "CENTER", 0, 0)
    tb.fs:SetWordWrap(false)
    tb.underline = P.NewStroke(tb, "ARTWORK", 4)
    tb:SetScript("OnClick", function() P.CalendarToday() end)
    tb:SetScript("OnEnter", function(self)
        self.hover = true
        P.DrawTodayButton(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local t = P.Today()
        local cal = P.journalCalendar
        GameTooltip:AddLine("Today: " .. P.DAY_NAMES[P.Weekday(t.y, t.m, t.d)] .. " " .. t.d .. " " .. P.MONTH_NAMES[t.m], 1, 0.82, 0)
        if cal and (cal.y ~= t.y or cal.m ~= t.m) then
            GameTooltip:AddLine("Click: back to this month", 0.65, 0.65, 0.65)
        else
            GameTooltip:AddLine("Click: today's notes", 0.65, 0.65, 0.65)
        end
        GameTooltip:Show()
    end)
    tb:SetScript("OnLeave", function(self)
        self.hover = false
        P.DrawTodayButton(self)
        GameTooltip:Hide()
    end)
    c.todayBtn = tb
    c.wd = {}
    for i = 1, 7 do
        c.wd[i] = c:CreateFontString(nil, "OVERLAY")
        c.wd[i]:SetJustifyH("CENTER")
    end
    c.cells = {}
    c:Hide()
    f.journalCal = c
    return c
end

function P.CalendarCell(c, k)
    local b = c.cells[k]
    if b then return b end
    b = CreateFrame("Button", nil, c)
    b:RegisterForClicks("LeftButtonUp")
    b.fs = b:CreateFontString(nil, "OVERLAY")
    b.fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.fs:SetJustifyH("CENTER")
    b.ring = {}
    b:SetScript("OnClick", function(self) if self.notes then P.PickJournalDay(self.day) end end)
    b:SetScript("OnEnter", function(self)
        if not self.notes then return end
        P.PlaceTooltip(self)
        local d = self.day
        GameTooltip:AddLine(P.DAY_NAMES[P.Weekday(d.y, d.m, d.d)] .. " " .. d.d .. " " .. P.MONTH_NAMES[d.m] .. " " .. d.y, 1, 0.82, 0)
        local n = #self.notes
        GameTooltip:AddLine((n == 1) and "1 note" or (n .. " notes"), 0.7, 0.7, 0.7)
        for i = 1, math.min(3, n) do
            local s = string.gsub(self.notes[i].text or "", "\n", " ")
            if string.len(s) > 48 then s = string.sub(s, 1, 46) .. "..." end
            GameTooltip:AddLine(s, 0.9, 0.9, 0.9)
        end
        if n > 3 then GameTooltip:AddLine("and " .. (n - 3) .. " more", 0.7, 0.7, 0.7) end
        local cur = P.journalDay
        local picked = cur and cur.y == d.y and cur.m == d.m and cur.d == d.d
        GameTooltip:AddLine(picked and "Click: every day again" or "Click: only this day's notes", 0.65, 0.65, 0.65)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c.cells[k] = b
    return b
end

-- A day you wrote on, circled by hand (an open loop that overshoots, like a quick pen ring)
P.RING_SEGS = 9
function P.DrawDayRing(b, w, h, seed, ink, alpha)
    local cx, cy = w / 2, -h / 2
    local rx, ry = math.min(w / 2 - 1, h * 0.85 + 2), h / 2 - 0.5     -- short rows: an oval, not a flat dash
    local a0 = P.Hash01(seed, 1, 3) * math.pi * 2
    local sweep = math.pi * 2 + 0.35
    local px, py
    for k = 0, P.RING_SEGS do
        local a = a0 + sweep * k / P.RING_SEGS
        local wob = 1 + (P.Hash01(seed, k, 9) - 0.5) * 0.12
        local x, y = cx + math.cos(a) * rx * wob, cy + math.sin(a) * ry * wob
        if k > 0 then
            b.ring[k] = b.ring[k] or P.NewStroke(b, "ARTWORK", 4)
            P.DrawStroke(b.ring[k], b, px, py, x, y, 1.0, alpha, ink)
        end
        px, py = x, y
    end
end

function P.HideDayRing(b)
    for _, s in ipairs(b.ring) do P.HideStroke(s) end
end

-- The month on the page: "< November 2026 >" on the writing line's row (left of the magnifier and
-- calendar), the weekdays' letters (left out when the page is short), the days. Small pages squeeze the
-- day rows down to P.CAL_MIN_ROW.
P.CAL_MIN_ROW = 8
P.CAL_WD_H = 11
function P.RenderJournalCalendar(f, rowH, contentW, contentH, st, pageStr)
    local c = P.EnsureJournalCalendar(f)
    local cal = P.journalCalendar
    local y, m = cal.y, cal.m
    local notes = P.NotesByDay(y, m)
    local today, picked = P.Today(), P.journalDay
    local first = P.FirstWeekday()
    local lead = (P.Weekday(y, m, 1) - first) % 7          -- empty cells before the 1st
    local nDays = P.DaysInMonth(y, m)
    local weeks = math.ceil((lead + nDays) / 7)
    local cellW = math.floor(math.min(26, (contentW - 8) / 7))
    local headH = rowH
    local room = contentH - headH - 2
    local wdH = ((room - P.CAL_WD_H) / weeks >= 10) and P.CAL_WD_H or 0
    local cellH = math.floor(math.max(P.CAL_MIN_ROW, math.min(P.LineHeight(f) + 2, (room - wdH) / weeks)))
    local gridW = cellW * 7
    local x0 = math.max(0, math.floor((contentW - gridW) / 2))
    c.gridX, c.cellW, c.cellH = x0, cellW, cellH
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, 0)
    c:SetSize(contentW, headH + wdH + weeks * cellH)
    -- heading: < Month Year >
    local toolY = -math.floor((rowH - P.JOURNAL_TOOL) / 2)
    c.prev:ClearAllPoints()
    c.prev:SetPoint("TOPLEFT", c, "TOPLEFT", 2, toolY)
    P.SetInkFont(c.title, "item")
    c.title:SetTextColor(st.title[1], st.title[2], st.title[3], 1)
    -- "today" on the right, just left of the magnifier and calendar glyphs
    local tb = c.todayBtn
    P.SetInkFont(tb.fs, "small")
    tb.fs:SetText("today")
    local todayW = math.ceil(tb.fs:GetStringWidth() or 26) + 6
    tb:SetSize(todayW, P.JOURNAL_TOOL + 2)
    tb:ClearAllPoints()
    tb:SetPoint("TOPRIGHT", c, "TOPRIGHT", -(2 * P.JOURNAL_TOOL + P.JOURNAL_TOOL_GAP + 10), toolY + 1)
    P.DrawTodayButton(tb)
    tb:Show()
    -- the month's name: in full, or short ("Nov 2026") when that would run into "today"
    local nameRoom = contentW - (2 * P.JOURNAL_TOOL + P.JOURNAL_TOOL_GAP + 10) - todayW - 6 - (2 + P.JOURNAL_TOOL + 3) - (3 + P.JOURNAL_TOOL)
    c.title:SetText(P.MONTH_NAMES[m] .. " " .. y)
    if (c.title:GetStringWidth() or 0) > nameRoom then c.title:SetText(P.MONTHS[m] .. " " .. y) end
    c.title:ClearAllPoints()
    c.title:SetPoint("LEFT", c.prev, "RIGHT", 3, 0)
    c.next:ClearAllPoints()
    c.next:SetPoint("LEFT", c.title, "RIGHT", 3, 0)
    P.DrawWriteGlyph(c.prev, "prev", c.prev.hover)
    P.DrawWriteGlyph(c.next, "next", c.next.hover)
    -- the weekdays' first letters
    local sub = st.sub or st.faded
    for i = 1, 7 do
        local fs = c.wd[i]
        P.SetInkFont(fs, "small")
        fs:SetTextColor(sub[1], sub[2], sub[3], 1)
        fs:SetText(string.sub(P.DAY_NAMES[(first + i - 2) % 7 + 1], 1, 1))
        fs:ClearAllPoints()
        fs:SetPoint("TOP", c, "TOPLEFT", x0 + (i - 0.5) * cellW, -headH)
        fs:SetShown(wdH > 0)
    end
    -- the days: yours circled in ink (red for the one picked), today in red ink, the rest faded
    local used, written, count = 0, 0, 0
    for d = 1, nDays do
        local k = lead + d
        local col, row = (k - 1) % 7, math.floor((k - 1) / 7)
        local b = P.CalendarCell(c, d)
        used = d
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", c, "TOPLEFT", x0 + col * cellW, -(headH + wdH + row * cellH))
        b:SetSize(cellW, cellH)
        b.day = { y = y, m = m, d = d }
        b.notes = notes[d]
        P.SetInkFont(b.fs, "small")
        local isToday = today.y == y and today.m == m and today.d == d
        local isPicked = picked and picked.y == y and picked.m == m and picked.d == d
        local ink = b.notes and (st.name or st.ink) or st.faded
        if isToday then ink = P.INK_RED end
        b.fs:SetTextColor(ink[1], ink[2], ink[3], b.notes and 1 or 0.75)
        b.fs:SetText(tostring(d))
        if b.notes then
            written = written + 1
            count = count + #b.notes
            P.DrawDayRing(b, cellW, cellH, P.DayKey(y, m, d), isPicked and P.INK_RED or P.INK, isPicked and 1 or 0.8)
            b:EnableMouse(true)
        else
            P.HideDayRing(b)
            b:EnableMouse(false)
        end
        b:Show()
    end
    for k = used + 1, #c.cells do c.cells[k]:Hide() end
    c:Show()
    local s = (written == 0) and ("nothing written in " .. P.MONTH_NAMES[m])
        or (((count == 1) and "1 note" or (count .. " notes")) .. " on " .. ((written == 1) and "1 day" or (written .. " days")))
    f.footerFS:SetText(s .. P.JournalFilterWords() .. (pageStr or ""))
end

-- The writing glyph (box / quill), drawn in faded ink; hover = red ink like the toggles; on = full ink
-- (the Journal's magnifier / calendar while their filter is on)
function P.DrawWriteGlyph(b, kind, hover, on)
    local glyph = P.WRITE_GLYPHS[kind]
    b.strokes = b.strokes or {}
    local st = P.GetStyle()
    local ink = hover and P.INK_RED or (on and P.INK or (st.faded or P.INK))
    local alpha = hover and 0.95 or (on and 1 or 0.85)
    for i = 1, math.max(#glyph, #b.strokes) do
        local g = glyph[i]
        if g then
            b.strokes[i] = b.strokes[i] or P.NewStroke(b, "OVERLAY", 4)
            P.DrawStroke(b.strokes[i], b, g[1], g[2], g[3], g[4], (on and 1.25 or 1.1) * (g[5] or 1), alpha, ink)
        elseif b.strokes[i] then
            P.HideStroke(b.strokes[i])
        end
    end
    b.glyphKind = kind
end

-- ---- writing an entry: one multi-line box, over the line being written ----------------------------
-- P.journalEditing = { entry = e } while re-writing entry e, { } while writing a new one, nil otherwise
function P.EnsureJournalEditBox(f)
    if f.journalEdit then return f.journalEdit end
    local eb = CreateFrame("EditBox", nil, f.content)
    P.SetInkFont(eb, "item")              -- a font first: WoW won't take text into a box without one
    eb:SetAutoFocus(false)
    eb:EnableMouse(true)
    eb:SetScript("OnMouseDown", function(self) self:SetFocus() end)   -- click into it: the keyboard is its again
    eb:SetMultiLine(true)
    eb:SetMaxLetters(P.ENTRY_MAX_LETTERS)
    eb:SetFrameLevel((f.baseLevel or 30) + 24)
    eb:SetJustifyH("LEFT")
    eb.wash = eb:CreateTexture(nil, "BACKGROUND")
    eb.wash:SetPoint("TOPLEFT", eb, "TOPLEFT", -3, 2)
    eb.wash:SetPoint("BOTTOMRIGHT", eb, "BOTTOMRIGHT", 3, -2)
    -- Enter keeps the entry; Shift-Enter starts a new line. (Whether the client already put a line break
    -- in for Enter differs between boxes, so look at what's before the cursor rather than guess.)
    eb:SetScript("OnEnterPressed", function(self)
        local txt = self:GetText() or ""
        local pos = self.GetCursorPosition and self:GetCursorPosition()
        local brokeLine = type(pos) == "number" and pos > 0 and string.sub(txt, pos, pos) == "\n"
        if IsShiftKeyDown and IsShiftKeyDown() then
            if not brokeLine and self.Insert then self:Insert("\n") end
            return
        end
        if brokeLine then self:SetText(string.sub(txt, 1, pos - 1) .. string.sub(txt, pos + 1)) end
        P.CommitJournalEdit()
    end)
    eb:SetScript("OnEscapePressed", function() P.CancelJournalEdit() end)
    eb:SetScript("OnEditFocusLost", function(self)
        if P.journalEditing and P.FocusGrace(self) then return end
        if P.journalEditing then P.CommitJournalEdit(true) end
    end)
    eb:SetScript("OnHide", function(self) if self.HasFocus and self:HasFocus() then self:ClearFocus() end end)
    eb:Hide()
    f.journalEdit = eb
    return eb
end

function P.BeginJournalEdit(e)
    local f = T.frame
    if not f then return end
    if P.forMeEditing then P.CommitForMeEdit() end
    if P.journalSearching then P.CloseJournalSearch() end
    P.journalCalendar = nil
    local eb = P.EnsureJournalEditBox(f)
    P.SetInkFont(eb, "item")
    eb:SetText(e and e.text or "")
    P.journalEditing = { entry = e }
    P.Render(f)
    P.FocusBox(eb, function() return P.journalEditing ~= nil end)
end

function P.CommitJournalEdit(deferRedraw)
    local editing = P.journalEditing
    if not editing then return end
    P.journalEditing = nil
    local f = T.frame
    local eb = f and f.journalEdit
    local text = T.CleanEntryText(eb and eb:GetText() or "")
    if eb then eb:ClearFocus(); eb:Hide() end
    if editing.entry then
        if text == "" then
            for i, x in ipairs(T.notes.journal) do
                if x == editing.entry then table.remove(T.notes.journal, i) break end
            end
        else
            editing.entry.text = text
        end
    else
        T.AddEntry(text)
    end
    if deferRedraw and C_Timer and C_Timer.After then
        T.Save()
        C_Timer.After(0, function() T.SafeCall(T.Update) end)
    else
        P.ForMeChanged()
    end
end

function P.CancelJournalEdit()
    if not P.journalEditing then return end
    P.journalEditing = nil
    local f = T.frame
    local eb = f and f.journalEdit
    if eb then eb:ClearFocus(); eb:Hide() end
    if f and f:IsShown() then P.Render(f) end
end

-- ---- a note written in "For me" flies off to the Journal tab -----------------------------------------
function P.FlyToJournal(f, text, x, y)
    if not (f and f.content and f:IsShown()) then return end
    local fs = f.flyFS
    if not fs then
        fs = f.content:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        f.flyFS = fs
    end
    P.SetInkFont(fs, "item")
    fs:SetTextColor(P.INK[1], P.INK[2], P.INK[3], 1)
    local s = text or ""
    if string.len(s) > 32 then s = string.sub(s, 1, 30) .. "..." end
    fs:SetText(s)
    fs:SetAlpha(1)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", f.content, "TOPLEFT", x or 20, y or 0)
    fs:Show()
    f.fly = { t = 0, x0 = x or 20, y0 = y or 0 }
end

-- Something just went into the Journal: its tab gives a little tug (no tabs: the corner flicks)
function P.TugJournalTab(f)
    f = f or T.frame
    if not (f and f:IsShown()) then return end
    local tab = f.tabs and f.tabs.journal
    if tab and tab:IsShown() then
        tab.slide = P.TAB_HOVER * 2
        P.SlideTab(tab, 0)
    else
        local c = f.corner
        if c and c:IsShown() then
            c.size = (c.target or P.CORNER_REST) + 10
            c.target = c.target or P.CORNER_REST
            P.DrawCorner(c)
        end
    end
end

function P.AnimateFly(f, dt)
    local fl = f.fly
    if not fl then return end
    fl.t = fl.t + dt / P.FLY_DUR
    local fs = f.flyFS
    local w = f.content:GetWidth() or 200
    local h = f.content:GetHeight() or 120
    local x1, y1 = math.max(fl.x0, w - 40), -(h - 4)
    local tab = f.tabs and f.tabs.journal
    if tab and tab:IsShown() and tab.edgeX then
        -- the content's top-left sits at (6 + padL, 28 + padT) on the chrome (P.LayoutPads)
        x1 = tab.edgeX - (6 + (f.padL or 0)) - 30
        y1 = -(tab.y + 4 - (28 + (f.padT or 0)))
    end
    if fl.t >= 1 then
        f.fly = nil
        fs:Hide()
        P.TugJournalTab(f)                        -- the note lands in the Journal tab
        return
    end
    local e = fl.t * fl.t * (3 - 2 * fl.t)       -- ease in and out
    local lift = math.sin(math.pi * fl.t) * 10   -- a small arc, as if picked up
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", f.content, "TOPLEFT", fl.x0 + (x1 - fl.x0) * e, fl.y0 + (y1 - fl.y0) * e + lift)
    fs:SetAlpha(1 - e * 0.85)
end

-- ---- the Journal page ----------------------------------------------------------------------------
function P.HideJournal(f)
    for _, row in ipairs(f.journalRows or {}) do row:Hide() end
    if f.journalWrite then f.journalWrite:Hide() end
    if f.journalTools then f.journalTools.search:Hide(); f.journalTools.calendar:Hide() end
    if f.journalCal then f.journalCal:Hide() end
    P.journalCalendar = nil                         -- the search and the day picked stay
    if f.journalSearchBox then
        P.journalSearching = nil
        f.journalSearchBox:ClearFocus()
        f.journalSearchBox:Hide()
        f.journalSearchBox.glyph:Hide()
    end
    if f.journalEdit then
        if P.journalEditing then P.CommitJournalEdit() end
        f.journalEdit:Hide()
    end
end

function P.AcquireJournalRow(f, k)
    f.journalRows = f.journalRows or {}
    local row = f.journalRows[k]
    if row then return row end
    row = CreateFrame("Button", nil, f.content)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.stamp = row:CreateFontString(nil, "OVERLAY")
    row.stamp:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -2)
    row.stamp:SetJustifyH("LEFT")
    row.stamp:SetWordWrap(false)
    row.text = row:CreateFontString(nil, "OVERLAY")
    row.text:SetJustifyH("LEFT")
    row.text:SetJustifyV("TOP")
    row.text:SetWordWrap(true)
    row.divider = row:CreateTexture(nil, "BACKGROUND")
    row.divider:SetHeight(1)
    row.divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 0)
    row.divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 0)
    -- the place in the stamp: click it to see only what was written there
    row.stampBtn = CreateFrame("Button", nil, row)
    row.stampBtn:SetPoint("TOPLEFT", row.stamp, "TOPLEFT", 0, 1)
    row.stampBtn:SetScript("OnClick", function(self) if self.entry then P.ToggleJournalFilter(self.entry) end end)
    row.stampBtn:SetScript("OnEnter", function(self)
        local name = self.entry and P.EntryPlaceName(self.entry)
        if not name then return end
        P.PlaceTooltip(self)
        if P.journalFilter then
            GameTooltip:AddLine("Showing what you wrote in " .. P.journalFilter, 1, 0.82, 0)
            GameTooltip:AddLine("Click: show every entry again", 0.65, 0.65, 0.65)
        else
            GameTooltip:AddLine("Written in " .. name, 1, 0.82, 0)
            GameTooltip:AddLine("Click: show only what you wrote here", 0.65, 0.65, 0.65)
        end
        GameTooltip:Show()
    end)
    row.stampBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.journalRows[k] = row
    return row
end

function P.EntryTooltip(row, e)
    P.PlaceTooltip(row)
    GameTooltip:AddLine(P.EntryStamp(e) ~= "" and P.EntryStamp(e) or "Note", 1, 0.82, 0)
    local pl = e.place
    if pl and pl.subzone and pl.zone and pl.subzone ~= pl.zone then GameTooltip:AddLine(pl.zone, 0.7, 0.7, 0.7) end
    if e.auto == "quest" then
        GameTooltip:AddLine("Written in for you when you turned it in", 0.55, 0.85, 0.55)
        for _, q in ipairs(e.quests or {}) do
            GameTooltip:AddLine(q.title, 1, 1, 1)
            for _, it in ipairs(q.items or {}) do
                local qc = it.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[it.quality]
                local r, g, b = 0.9, 0.9, 0.9
                if qc then r, g, b = qc.r or r, qc.g or g, qc.b or b end
                GameTooltip:AddLine("   " .. (((it.count or 1) > 1) and (it.count .. " ") or "") .. it.name, r, g, b)
            end
            local extra = {}
            if (q.xp or 0) > 0 then extra[#extra + 1] = q.xp .. " xp" end
            if (q.money or 0) > 0 then extra[#extra + 1] = P.MoneyText(q.money) end
            if #extra > 0 then GameTooltip:AddLine("   " .. table.concat(extra, ", "), 0.8, 0.8, 0.8) end
        end
    end
    if e.auto == "level" then
        GameTooltip:AddLine("Written in for you when you levelled up", 0.55, 0.85, 0.55)
        for _, l in ipairs(e.levels or {}) do GameTooltip:AddLine("Level " .. l.level, 1, 0.82, 0.3) end
    end
    if e.auto == "achievement" then
        GameTooltip:AddLine("Written in for you when you earned it", 0.55, 0.85, 0.55)
        for _, a in ipairs(e.achievements or {}) do
            local info = a.id and T.AchievementInfo(a.id)
            GameTooltip:AddLine(a.name .. (((a.points or 0) > 0) and ("  (" .. a.points .. ")") or ""), 1, 1, 1)
            if info and info.description then GameTooltip:AddLine(info.description, 0.8, 0.8, 0.8, true) end
        end
    end
    local dt = e.doneTask
    if dt then
        GameTooltip:AddLine("A task from For me, ticked off", 0.55, 0.85, 0.55)
        local where = dt.place and (dt.place.subzone or dt.place.zone)
        if dt.when or where then
            GameTooltip:AddLine("Written " .. (dt.when or "") .. ((dt.when and where) and " · " or "") .. (where or ""), 0.7, 0.7, 0.7)
        end
    end
    GameTooltip:AddLine("Click: write more  |  Shift-Click: rub it out", 0.65, 0.65, 0.65)
    if dt then GameTooltip:AddLine("Right-Click: not done after all (back to For me)", 0.65, 0.65, 0.65) end
    GameTooltip:Show()
end

-- The journal's own writing line: a quill and "write a note...", only as wide as its words
function P.EnsureJournalWriteLine(f)
    local wl = f.journalWrite
    if wl then return wl end
    wl = CreateFrame("Button", nil, f.content)
    wl:RegisterForClicks("LeftButtonUp")
    wl.highlight = wl:CreateTexture(nil, "HIGHLIGHT")
    wl.highlight:SetAllPoints()
    wl.glyph = CreateFrame("Frame", nil, wl)
    wl.glyph:SetSize(14, 14)
    wl.glyph:SetPoint("TOPLEFT", wl, "TOPLEFT", 3, -2)
    wl.fs = wl:CreateFontString(nil, "OVERLAY")
    wl.fs:SetPoint("TOPLEFT", wl, "TOPLEFT", 20, -2)
    wl.fs:SetJustifyH("LEFT")
    wl.fs:SetWordWrap(false)
    wl:SetScript("OnClick", function() P.BeginJournalEdit(nil) end)
    wl:SetScript("OnEnter", function(self)
        P.DrawWriteGlyph(self.glyph, "entry", true)
        P.PlaceTooltip(self)
        GameTooltip:AddLine("Write a note", 1, 0.82, 0)
        GameTooltip:AddLine("Stamped with the time and where you are.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("Enter: keep it  |  Shift-Enter: new line  |  Escape: never mind", 0.65, 0.65, 0.65)
        GameTooltip:Show()
    end)
    wl:SetScript("OnLeave", function(self) P.DrawWriteGlyph(self.glyph, "entry", false); GameTooltip:Hide() end)
    f.journalWrite = wl
    return wl
end

function P.RenderJournal(f, area, contentW, contentH, pageStr)
    P.HideForMe(f)
    P.HideKindHeadings(f, 1)
    local st = P.GetStyle()
    local textW = math.max(110, contentW - 8)
    local lineH = P.LineHeight(f)
    local writeH = math.max(14, lineH) + 7
    local editH = lineH * P.JOURNAL_EDIT_LINES + 6
    local editing = P.journalEditing
    local hl = st.highlight
    local list = P.JournalList()
    f.totalItems = #list
    if T.scroll > math.max(0, #list - 1) then T.scroll = math.max(0, #list - 1) end
    for _, row in ipairs(f.journalRows or {}) do row:Hide() end

    -- the writing line on top (newest first: a new entry goes in right under it)
    local wl = P.EnsureJournalWriteLine(f)
    wl.highlight:SetColorTexture(hl[1], hl[2], hl[3], hl[4])
    P.DrawWriteGlyph(wl.glyph, "entry", false)
    P.SetInkFont(wl.fs, "item")
    wl.fs:SetTextColor(st.faded[1], st.faded[2], st.faded[3], 1)
    local writingNew = editing and not editing.entry
    wl.fs:SetText(writingNew and "" or ((#T.notes.journal == 0) and "write your first note..." or "write a note..."))
    local toolsW = 2 * P.JOURNAL_TOOL + P.JOURNAL_TOOL_GAP + 8        -- the magnifier and calendar on the right
    local wordsW = math.min(textW - P.CORNER_MAX, contentW - toolsW - 26, math.ceil(wl.fs:GetStringWidth() or 0))
    wl.fs:SetWidth(math.max(1, wordsW))
    wl:ClearAllPoints()
    wl:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, 0)
    wl:SetWidth(20 + math.max(1, wordsW) + 6)
    wl:SetHeight(writeH)
    wl:SetShown(not P.journalSearching and not P.journalCalendar)   -- the month's name takes the row
    local y = writingNew and -(editH + 6) or -writeH

    -- the magnifier and the calendar at the row's right end (full ink while their filter is on)
    local tools = P.EnsureJournalTools(f)
    local toolY = -math.floor((writeH - P.JOURNAL_TOOL) / 2)
    tools.calendar:ClearAllPoints()
    tools.calendar:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", -2, toolY)
    tools.search:ClearAllPoints()
    tools.search:SetPoint("TOPRIGHT", tools.calendar, "TOPLEFT", -P.JOURNAL_TOOL_GAP, 0)
    tools.search.on = (P.journalSearch or P.journalSearching) and true or false
    tools.calendar.on = (P.journalDay or P.journalCalendar) and true or false
    P.DrawWriteGlyph(tools.search, "search", tools.search.hover, tools.search.on)
    P.DrawWriteGlyph(tools.calendar, "calendar", tools.calendar.hover, tools.calendar.on)
    tools.search:Show()
    tools.calendar:Show()

    -- searching: the box where "write a note..." was, a magnifier in front
    local sb = f.journalSearchBox
    if P.journalSearching then
        sb = P.EnsureJournalSearchBox(f)
        P.SetInkFont(sb, "item")
        sb:SetTextColor(P.INK[1], P.INK[2], P.INK[3], 1)
        sb.wash:SetColorTexture(hl[1], hl[2], hl[3], (hl[4] or 0.1) * 1.5)
        sb.glyph:ClearAllPoints()
        sb.glyph:SetPoint("TOPLEFT", f.content, "TOPLEFT", 3, -2)
        P.DrawWriteGlyph(sb.glyph, "search", false, true)
        sb.glyph:Show()
        sb:ClearAllPoints()
        sb:SetPoint("TOPLEFT", f.content, "TOPLEFT", 20, -1)
        sb:SetWidth(math.max(40, contentW - toolsW - 26))
        sb:SetHeight(writeH - 2)
        sb:Show()
    elseif sb then
        sb:Hide()
        sb.glyph:Hide()
    end

    -- the calendar: a month on the page instead of the notes
    if P.journalCalendar then
        P.RenderJournalCalendar(f, writeH, contentW, contentH, st, pageStr)
        if f.journalEdit then f.journalEdit:Hide() end
        return
    elseif f.journalCal then
        f.journalCal:Hide()
    end
    local terms = P.SearchTerms(P.journalSearch)
    local markHex = P.Hex(P.INK_RED)

    if #list == 0 then
        local row = P.AcquireJournalRow(f, 1)
        row.stamp:SetText("")
        row.stampBtn:Hide()
        if row.mark then row.mark:Hide() end
        P.SetInkFont(row.text, "item")
        row.text:SetWidth(textW)
        row.text:ClearAllPoints()
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
        row.text:SetTextColor(st.faded[1], st.faded[2], st.faded[3], 1)
        local words = P.JournalFilterWords()
        row.text:SetText((words ~= "") and ("Nothing written" .. words .. ".")
            or "Your journal is empty. Write a note here, or with \"write a note\" under For me.")
        P.SetHalo(row.text, row.text:GetText(), st.faded)
        P.SetGlow(row.text, nil)
        row.divider:Hide()
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, y - 4)
        row:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", 0, y - 4)
        row:SetHeight(math.max(30, math.ceil(row.text:GetStringHeight() or 24) + 8))
        row:SetScript("OnClick", nil)
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
        row:Show()
    end

    local shown, editRowText = 0, nil
    for k = 1 + T.scroll, #list do
        local e = list[k]
        local row = P.AcquireJournalRow(f, shown + 1)
        P.SetInkFont(row.stamp, "small")
        local sc = st.sub or st.faded
        row.stamp:SetTextColor(sc[1], sc[2], sc[3], 1)
        row.stamp:SetText(P.EntryStamp(e))
        local stampH = math.max(10, math.ceil(row.stamp:GetStringHeight() or 10))
        row.stampBtn.entry = e
        row.stampBtn:SetSize(math.max(10, math.ceil(row.stamp:GetStringWidth() or 10)), stampH + 2)
        row.stampBtn:SetShown(P.EntryPlaceName(e) ~= nil)
        local markKind = (e.auto and "auto") or (e.doneTask and "done") or nil
        if markKind then
            -- written by the addon: a small inked star after the stamp; a task ticked off: a ticked box
            if not row.mark then
                row.mark = CreateFrame("Frame", nil, row)
                row.mark:SetSize(14, 14)
            end
            row.mark:ClearAllPoints()
            row.mark:SetPoint("TOPLEFT", row, "TOPLEFT", 4 + math.ceil(row.stamp:GetStringWidth() or 0) + 5, 0)
            P.DrawWriteGlyph(row.mark, markKind, false)
            row.mark:Show()
        elseif row.mark then
            row.mark:Hide()
        end
        P.SetInkFont(row.text, "item")
        row.text:SetWidth(textW)
        row.text:ClearAllPoints()
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -(stampH + 4))
        -- auto entries in faded ink, so yours stand out; a level reached is a milestone: full ink, glowing gold
        local levelUp = e.auto == "level"
        local faded = e.auto and not levelUp
        local ink = faded and st.faded or (st.name or st.ink)
        row.text:SetTextColor(ink[1], ink[2], ink[3], 1)
        local beingEdited = editing and editing.entry == e
        row.text:SetText(beingEdited and "" or P.MarkMatches(e.text, terms, markHex))   -- the words looked for, in red
        P.SetHalo(row.text, beingEdited and "" or e.text, faded and st.faded or P.INK)
        P.SetGlow(row.text, (levelUp and not beingEdited) and e.text or nil)
        local textH = beingEdited and editH or math.max(14, math.ceil(row.text:GetStringHeight() or 14))
        local rowH = stampH + textH + 10
        if shown > 0 and math.abs(y) + rowH > contentH + 4 then
            P.SetGlow(row.text, nil)
            break
        end
        row.highlight:SetColorTexture(hl[1], hl[2], hl[3], hl[4])
        local d = st.divider
        row.divider:SetColorTexture(d[1], d[2], d[3], d[4])
        row.divider:Show()
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", 0, y)
        row:SetHeight(rowH)
        row:SetScript("OnClick", function(_, button)
            if IsShiftKeyDown and IsShiftKeyDown() and button == "LeftButton" then P.RubOutEntry(e)
            elseif button == "RightButton" and e.doneTask then P.TaskBackFromJournal(e)
            else P.BeginJournalEdit(e) end
        end)
        row:SetScript("OnEnter", function(self) P.EntryTooltip(self, e) end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:Show()
        if beingEdited then editRowText = row.text end
        y = y - rowH
        shown = shown + 1
    end

    -- the writing box: under the writing line (a new entry) or in place of the entry being re-written
    local eb = f.journalEdit
    if editing then
        eb = P.EnsureJournalEditBox(f)
        P.SetInkFont(eb, "item")
        eb:SetTextColor(P.INK[1], P.INK[2], P.INK[3], 1)
        eb.wash:SetColorTexture(hl[1], hl[2], hl[3], (hl[4] or 0.1) * 1.5)
        eb:ClearAllPoints()
        if editRowText then
            eb:SetPoint("TOPLEFT", editRowText, "TOPLEFT", 0, 0)
        else
            eb:SetPoint("TOPLEFT", f.content, "TOPLEFT", 20, 0)          -- where "write a note..." was
        end
        eb:SetWidth(math.max(60, textW - P.CORNER_MAX))
        eb:SetHeight(editH)
        eb:Show()
    elseif eb then
        eb:Hide()
    end

    local n = #list
    local count = (n == 1) and "1 note" or (n .. " notes")
    count = count .. P.JournalFilterWords()
    if n > shown and n > 0 then
        count = count .. string.format("  ·  %d-%d shown", T.scroll + 1, T.scroll + shown)
    end
    f.footerFS:SetText(count .. (pageStr or ""))
end

-- ----------------------------------------------------------------------------
-- TABS: the two quick tabs, cut from the sheet itself
-- ----------------------------------------------------------------------------
-- Two index tabs sticking out of the sheet's right edge below the close button: "Near me" (an inked
-- compass) above "Journal" (an inked quill). Each is a strip of the look's own sheet image tucked behind
-- the top sheet, so only the part past the edge shows, and its outer end is the material's real edge
-- (torn threads, the leaf's curve, the slate's rim) moved out: always the very same material. Drawn looks
-- use their paper colour. The open page's tab sticks out further; hovering slides a tab out a little.
-- Click = turn to that page; on it already = back where you were. Shown while "For me" is on.
P.TAB_H = 24                  -- each tab's height
P.TAB_OUT = 18                -- how far a tab sticks out past the edge (the open page's: + P.TAB_OPEN)
P.TAB_OPEN, P.TAB_HOVER = 4, 3
P.TAB_TUCK = 22               -- how far it reaches in under the top sheet
P.TAB_GAP = 5
P.TAB_GLYPHS = {
    near = {       -- a compass rose: the four points and a diamond (y down = negative, as the toggles)
        { 7.5, -0.5, 7.5, -14.5, 0.9 }, { 0.5, -7.5, 14.5, -7.5, 0.9 },
        { 7.5, -3.0, 10.5, -7.5, 1.15 }, { 10.5, -7.5, 7.5, -12.0, 1.15 }, { 7.5, -12.0, 4.5, -7.5, 1.15 }, { 4.5, -7.5, 7.5, -3.0, 1.15 },
    },
    journal = P.WRITE_GLYPHS.entry,     -- the quill
}
-- Where each sheet image's material ends (Handkerquest's tools\TexGen.cs EdgeProfile; the images in
-- textures\ are the same files): b = fraction of the height up from the image's bottom at x = 0, 0.05 .. 1;
-- r = fraction of the width in from its right at y = 0, 0.05 .. 1. Values near 1 = no material there.
P.SHEET_EDGES = {
    CRUMPLED = { b = { 0.998, 0.027, 0.031, 0.031, 0.027, 0.031, 0.029, 0.035, 0.039, 0.039, 0.037, 0.041, 0.041, 0.041, 0.037, 0.039, 0.037, 0.033, 0.029, 0.031, 0.998 }, r = { 0.998, 0.045, 0.045, 0.039, 0.035, 0.033, 0.035, 0.039, 0.043, 0.041, 0.045, 0.045, 0.045, 0.045, 0.041, 0.039, 0.041, 0.037, 0.033, 0.027, 0.998 } },
    RAG = { b = { 0.998, 0.059, 0.041, 0.043, 0.043, 0.043, 0.043, 0.045, 0.045, 0.045, 0.045, 0.043, 0.045, 0.045, 0.047, 0.045, 0.045, 0.045, 0.043, 0.102, 0.998 }, r = { 0.998, 0.150, 0.068, 0.078, 0.080, 0.084, 0.063, 0.076, 0.059, 0.045, 0.035, 0.043, 0.043, 0.053, 0.049, 0.057, 0.061, 0.061, 0.051, 0.063, 0.998 } },
    STONE = { b = { 0.998, 0.320, 0.225, 0.172, 0.129, 0.109, 0.088, 0.070, 0.070, 0.070, 0.072, 0.066, 0.063, 0.064, 0.064, 0.064, 0.082, 0.117, 0.178, 0.285, 0.998 }, r = { 0.998, 0.277, 0.168, 0.109, 0.070, 0.053, 0.039, 0.037, 0.039, 0.041, 0.027, 0.031, 0.035, 0.041, 0.047, 0.064, 0.088, 0.121, 0.168, 0.998, 0.998 } },
    BARK = { b = { 0.998, 0.400, 0.217, 0.178, 0.143, 0.117, 0.119, 0.125, 0.131, 0.105, 0.094, 0.098, 0.090, 0.086, 0.094, 0.111, 0.139, 0.201, 0.311, 0.352, 0.998 }, r = { 0.998, 0.998, 0.365, 0.156, 0.098, 0.096, 0.100, 0.051, 0.063, 0.053, 0.029, 0.074, 0.068, 0.053, 0.113, 0.139, 0.146, 0.182, 0.271, 0.998, 0.998 } },
    LEAF = { b = { 0.998, 0.332, 0.215, 0.154, 0.111, 0.082, 0.057, 0.043, 0.029, 0.033, 0.037, 0.047, 0.066, 0.094, 0.123, 0.178, 0.248, 0.316, 0.385, 0.465, 0.998 }, r = { 0.998, 0.998, 0.471, 0.340, 0.277, 0.230, 0.182, 0.141, 0.100, 0.064, 0.029, 0.061, 0.092, 0.125, 0.160, 0.199, 0.234, 0.273, 0.330, 0.439, 0.998 } },
    LEATHER = { b = { 0.998, 0.119, 0.078, 0.061, 0.059, 0.063, 0.063, 0.070, 0.082, 0.088, 0.094, 0.102, 0.119, 0.127, 0.119, 0.109, 0.113, 0.127, 0.150, 0.764, 0.998 }, r = { 0.998, 0.783, 0.096, 0.059, 0.051, 0.057, 0.072, 0.088, 0.086, 0.072, 0.072, 0.070, 0.082, 0.072, 0.064, 0.064, 0.064, 0.100, 0.441, 0.998, 0.998 } },
    MARBLE = { b = { 0.998, 0.998, 0.045, 0.047, 0.047, 0.045, 0.045, 0.045, 0.045, 0.045, 0.045, 0.045, 0.045, 0.045, 0.045, 0.047, 0.045, 0.047, 0.045, 0.998, 0.998 }, r = { 0.998, 0.451, 0.277, 0.195, 0.141, 0.098, 0.064, 0.066, 0.064, 0.066, 0.064, 0.070, 0.064, 0.064, 0.066, 0.066, 0.064, 0.064, 0.064, 0.066, 0.998 } },
    GILDED = { b = { 0.998, 0.998, 0.066, 0.061, 0.063, 0.063, 0.063, 0.063, 0.063, 0.061, 0.061, 0.061, 0.057, 0.059, 0.059, 0.061, 0.061, 0.059, 0.063, 0.998, 0.998 }, r = { 0.998, 0.998, 0.068, 0.063, 0.063, 0.061, 0.063, 0.063, 0.061, 0.061, 0.061, 0.059, 0.061, 0.063, 0.063, 0.061, 0.059, 0.059, 0.063, 0.998, 0.998 } },
    VELLUM = { b = { 0.998, 0.086, 0.049, 0.049, 0.049, 0.051, 0.051, 0.051, 0.051, 0.051, 0.053, 0.053, 0.053, 0.053, 0.053, 0.053, 0.053, 0.051, 0.051, 0.242, 0.998 }, r = { 0.998, 0.051, 0.051, 0.051, 0.051, 0.051, 0.053, 0.055, 0.053, 0.051, 0.053, 0.053, 0.051, 0.049, 0.051, 0.051, 0.053, 0.053, 0.053, 0.055, 0.998 } },
}

-- The material's edge at frac (0-1) along a profile, from the nearest measured samples that have material
function P.EdgeAt(list, frac)
    local n = #list - 1
    local pos = math.max(0, math.min(1, frac)) * n
    local i0 = math.floor(pos)
    local function ok(i) local v = list[i + 1]; return v and v < 0.9 and v or nil end
    local a, b = ok(i0), ok(math.min(n, i0 + 1))
    if a and b then local t = pos - i0; return a * (1 - t) + b * t end
    if a or b then return a or b end
    for d = 1, n do
        local v = ok(i0 - d) or ok(i0 + d)
        if v then return v end
    end
    return 0.02
end

function P.TabsShown()
    return T.db.opts.forMe and true or false
end

function P.TabPageKey(kind)
    return (kind == "near") and P.CURRENT_KEY or P.JOURNAL_KEY
end

function P.EnsureTab(f, kind)
    f.tabs = f.tabs or {}
    local tab = f.tabs[kind]
    if tab then return tab end
    tab = CreateFrame("Button", nil, f)
    tab:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    tab:SetFrameLevel((f.baseLevel or 30) + 11)       -- above the pages underneath, under the top sheet
    tab.kind = kind
    tab.tex = tab:CreateTexture(nil, "BACKGROUND")
    tab.tex:SetAllPoints()
    tab.glyph = CreateFrame("Frame", nil, tab)
    tab.glyph:SetSize(12, 12)
    tab.strokes = {}
    tab.slide, tab.slideTo = 0, 0
    tab:SetScript("OnEnter", function(self)
        self.hover = true
        P.SlideTab(self, P.TAB_HOVER)
        P.DrawTabGlyph(self)
        P.TabTooltip(self)
    end)
    tab:SetScript("OnLeave", function(self)
        self.hover = false
        P.SlideTab(self, 0)
        P.DrawTabGlyph(self)
        GameTooltip:Hide()
    end)
    tab:SetScript("OnClick", function(self) P.TabClick(self.kind) end)
    f.tabs[kind] = tab
    return tab
end

function P.SlideTab(tab, to)
    tab.slideTo = to
    local f = T.frame
    if f then f.tabsMoving = true end
end

-- The tab's glyph in the ink (red while hovered, like the toggles), faded on a tab that isn't open
function P.DrawTabGlyph(tab)
    local glyph = P.TAB_GLYPHS[tab.kind]
    local st = P.GetStyle()
    local open = tab.open
    local ink = tab.hover and P.INK_RED or (open and P.INK or (st.faded or P.INK))
    local alpha = (open or tab.hover) and 0.95 or 0.70
    for i, g in ipairs(glyph) do
        tab.strokes[i] = tab.strokes[i] or P.NewStroke(tab.glyph, "OVERLAY", 4)
        P.DrawStroke(tab.strokes[i], tab.glyph, g[1] * 12 / 15, g[2] * 12 / 15, g[3] * 12 / 15, g[4] * 12 / 15,
            1.1 * (g[5] or 1), alpha, ink)
    end
end

function P.TabTooltip(tab)
    GameTooltip:SetOwner(tab, "ANCHOR_RIGHT")
    if tab.kind == "near" then
        GameTooltip:AddLine("Near me", 1, 0.82, 0)
        GameTooltip:AddLine("What to gather and do around you, and your For me tasks.", 0.9, 0.9, 0.9, true)
    else
        local n = #T.notes.journal
        GameTooltip:AddLine("Journal  ·  " .. ((n == 1) and "1 note" or (n .. " notes")), 1, 0.82, 0)
        GameTooltip:AddLine("Your notes, newest first, stamped with when and where.", 0.9, 0.9, 0.9, true)
    end
    local back = tab.open and P.tabBack and P.TabBackArea()
    if back then
        GameTooltip:AddLine("Click: back to " .. (back.title or "the last page"), 0.65, 0.65, 0.65)
    elseif not tab.open then
        GameTooltip:AddLine("Click: turn to it", 0.65, 0.65, 0.65)
    end
    GameTooltip:Show()
end

function P.TabBackArea()
    for _, a in ipairs(P.areas or {}) do
        if a.key == P.tabBack then return a end
    end
    return nil
end

-- Click: turn to the tab's page; on it already = back where you were before the tab took you there
function P.TabClick(kind)
    local target = P.TabPageKey(kind)
    if P.selectedKey == target then
        local back = P.tabBack and P.TabBackArea()
        if not back then return end
        P.tabBack = nil
        P.SelectArea(back.key, true, (kind == "near") and 1 or -1)
        return
    end
    P.tabBack = P.selectedKey
    P.SelectArea(target, true, (kind == "near") and -1 or 1)
end

-- Places both tabs for the current look, window size and open page (every redraw; cheap)
function P.LayoutTabs(f)
    if not f.topSheet then return end
    if not P.TabsShown() then
        for _, tab in pairs(f.tabs or {}) do tab:Hide() end
        return
    end
    local st = P.GetStyle()
    local w, h = f:GetWidth() or 230, f:GetHeight() or 175
    local _, t, r = P.GetPads(f)
    local edges = P.SHEET_EDGES[st.key]
    local y = t + 24                                   -- the first tab: just below the close button
    for _, kind in ipairs({ "near", "journal" }) do
        local tab = P.EnsureTab(f, kind)
        tab.open = (P.selectedKey == P.TabPageKey(kind))
        local midY = y + P.TAB_H / 2
        local edgeX
        if edges then edgeX = w * (1 - P.EdgeAt(edges.r, midY / h))
        elseif st.arcane then edgeX = w - r * 0.5
        else edgeX = w - 2 end
        tab.edgeX, tab.y = edgeX, y
        local out = P.TAB_OUT + (tab.open and P.TAB_OPEN or 0)
        tab.out = out
        local width = P.TAB_TUCK + out
        if st.image then
            -- a strip of the sheet's own image ending just past its edge, moved out by `out`: its end is
            -- the material's real edge, the rest is tucked under the top sheet
            local margin = 4
            local u0 = math.max(0, (edgeX - (width - out) - margin + 0) / w)
            local u1 = math.min(1, (edgeX + margin) / w)
            local v0, v1 = y / h, (y + P.TAB_H) / h
            tab.tex:SetTexture(st.image)
            tab.tex:SetTexCoord(u0, u1, v0, v1)
            tab.tex:SetVertexColor(1, 1, 1, 1)
            if tab.tex.SetBlendMode then tab.tex:SetBlendMode(st.arcane and "ADD" or "BLEND") end
            width = (u1 - u0) * w
            tab.x0 = u0 * w + out
        else
            -- drawn looks: the paper's own colour
            local pc = st.paper or { 0.9, 0.85, 0.7, 1 }
            tab.tex:SetColorTexture(pc[1], pc[2], pc[3], math.max(0.6, pc[4] or 1))
            tab.x0 = edgeX - P.TAB_TUCK
            width = P.TAB_TUCK + out
        end
        tab.width = width
        -- a tab that isn't open sits a shade back, like a page underneath
        if not tab.open then
            if st.image then tab.tex:SetVertexColor(0.86, 0.86, 0.86, 1) else tab.tex:SetAlpha(0.9) end
        else
            tab.tex:SetAlpha(1)
        end
        P.PlaceTab(tab)
        -- only the part sticking out takes the mouse (the tucked part is under the sheet)
        if tab.SetHitRectInsets then tab:SetHitRectInsets(math.max(0, edgeX - tab.x0 + 1), 0, 0, 0) end
        tab.glyph:ClearAllPoints()
        tab.glyph:SetPoint("CENTER", tab, "LEFT", (edgeX - tab.x0) + out / 2 + 1, 0)
        P.DrawTabGlyph(tab)
        tab:Show()
        y = y + P.TAB_H + P.TAB_GAP
    end
end

function P.PlaceTab(tab)
    local f = T.frame
    tab:ClearAllPoints()
    tab:SetPoint("TOPLEFT", f, "TOPLEFT", tab.x0 + (tab.slide or 0), -tab.y)
    tab:SetSize(tab.width, P.TAB_H)
end

-- Per frame while a tab slides out (hover) or back
function P.AnimateTabs(f, dt)
    local moving = false
    for _, tab in pairs(f.tabs or {}) do
        local d = (tab.slideTo or 0) - (tab.slide or 0)
        if math.abs(d) > 0.05 then
            tab.slide = tab.slide + d * math.min(1, dt * 14)
            moving = true
        else
            tab.slide = tab.slideTo or 0
        end
        if tab:IsShown() and tab.x0 then P.PlaceTab(tab) end
    end
    f.tabsMoving = moving
end

-- ----------------------------------------------------------------------------
-- OPTIONS: the "For Me & Journal" section of the options panel (called from T.BuildOptionsPanel with its
-- Section / Check helpers). Auto notes and the two sharing switches sit two to a row, greyed while "For
-- me" is off; achievements / quests only where the client has them.
-- ----------------------------------------------------------------------------
function T.BuildJournalOptions(ui)
    ui.Section("For Me & Journal")
    ui.Check("\"For me\": your own tasks, and the Journal",
        "Write yourself tasks at the bottom of the Near me page (click \"add a task\", or /crq task <what to do>). Tick one off and it goes to your Journal, stamped with the time and place. The Journal is the last page of the pile (the quill tab on the tally's right edge, or /crq journal). While this is on, the tally stays up whenever it's switched on, even with no quests. Off: the page is all quest lines again and the tally puts itself away when there's nothing to list (your tasks and Journal are kept).",
        function() return T.db.opts.forMe end,
        function(v)
            T.db.opts.forMe = v
            P.CancelForMeEdit()
            P.CancelJournalEdit()
            if not v and P.selectedKey == P.JOURNAL_KEY then P.selectedKey = P.CURRENT_KEY end
            P.OnTallyChoiceChanged()
            if T.db.show and not v then P.TurnTallyOn() end    -- says so in chat if this just put it away
        end)
    local autos = {
        { key = "levelCheck", label = "...note level-ups", opt = "autoLevels",
          tip = "When you reach a new level, a note goes in your Journal by itself: the level, the time and where you were. It glows gold, so your milestones stand out." },
    }
    if T.AchievementsSupported() then
        table.insert(autos, { key = "achievementCheck", label = "...note achievements you earn", opt = "autoAchievements",
          tip = "When you earn an achievement, a note goes in your Journal by itself: its name and points, the time and where you were. Several earned within a few minutes in one place share a note. Guild achievements are left out. Written in faded ink with a small star, so your own notes stand out." })
    end
    if T.questTurnInEvent then
        table.insert(autos, { key = "questCheck", label = "...note quests you turn in", opt = "autoQuests",
          tip = "When you turn in a quest, a note goes in your Journal by itself: the quest, what it gave you (the items, the one you chose, xp and money), the time and where you were. World quests and bonus objectives are noted with their xp and money. Several turned in within a few minutes in one place share a note. Written in faded ink with a small star, so your own notes stand out." })
    end
    local checks = {}
    local function Pair(list)
        for i = 1, #list, 2 do
            local a, b = list[i], list[i + 1]
            local rowY = ui.GetY()
            local left = ui.Check(a.label, a.tip, a.get, a.set, 44)
            checks[#checks + 1] = left
            T[a.key] = left
            if b then
                ui.SetY(rowY)
                local right = ui.Check(b.label, b.tip, b.get, b.set, 300)
                checks[#checks + 1] = right
                T[b.key] = right
            end
        end
    end
    for _, a in ipairs(autos) do
        local opt = a.opt
        a.get = function() return T.db.opts[opt] end
        a.set = function(v) T.db.opts[opt] = v end
    end
    Pair(autos)
    Pair({
        { key = "shareTasksCheck", label = "...share tasks with all characters",
          tip = "Off: each character has its own \"For me\" tasks. On: every character on this account sees and ticks off the same tasks (each shows who wrote it). Switching off gives each character back the tasks it wrote; ones written by a character you haven't logged into since wait until you do.",
          get = function() return T.db.opts.shareTasks end, set = function(v) T.SetNotesShared("tasks", v) end },
        { key = "shareJournalCheck", label = "...share the Journal with all characters",
          tip = "Off: each character keeps its own Journal. On: one Journal for every character on this account, notes from all of them by time, each stamped with who wrote it. A character's own notes join it the next time you log into that character. Switching off gives each character back the notes it wrote.",
          get = function() return T.db.opts.shareJournal end, set = function(v) T.SetNotesShared("journal", v) end },
    })
    for _, cb in ipairs(checks) do
        local base = cb.Refresh
        cb.Refresh = function(self)
            base(self)
            self:SetAlpha(T.db.opts.forMe and 1 or 0.45)     -- all part of "For me"
        end
    end
end

-- ----------------------------------------------------------------------------
-- BETA FEEDBACK: a link for this download only (a new GitHub issue, already titled with the beta's
-- version), at the top of the options panel and in /crq feedback.
-- EDIT: change T.BETA_VERSION with each beta; set it to nil for a full release (the box then links to the
-- issues page as a whole).
-- ----------------------------------------------------------------------------
T.BETA_VERSION = "1.5.0-beta1"
T.ISSUES_URL = "https://github.com/Dantigravity/CacheReQuest/issues"
function T.FeedbackURL()
    if not T.BETA_VERSION then return T.ISSUES_URL end
    return T.ISSUES_URL .. "/new?title=" .. T.BETA_VERSION .. "%20feedback%3A%20"
end

-- Addons can't open a browser, so the link sits in a read-only box, selected on click for Ctrl+C. Typing
-- can't change it (any edit puts the link back). Returns the height it took.
function T.BuildFeedbackRow(p, y)
    local url = T.FeedbackURL()
    local label = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", p, "TOPLEFT", 16, y - 4)
    label:SetText(T.BETA_VERSION and ("|cFFFF9933Beta " .. T.BETA_VERSION .. "|r: comments, bugs?") or "Bugs, ideas, requests:")
    local fb = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    fb:SetSize(360, 20)
    fb:SetPoint("LEFT", label, "RIGHT", 10, 0)
    fb:SetAutoFocus(false)
    fb:SetText(url)
    if fb.SetCursorPosition then fb:SetCursorPosition(0) end
    fb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    fb:SetScript("OnMouseUp", function(self) self:SetFocus(); self:HighlightText() end)
    fb:SetScript("OnTextChanged", function(self, userInput)
        if userInput and self:GetText() ~= url then
            self:SetText(url); self:HighlightText()
        end
    end)
    fb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    fb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    fb:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0); if self.SetCursorPosition then self:SetCursorPosition(0) end end)
    fb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(T.BETA_VERSION and ("Feedback on beta " .. T.BETA_VERSION) or "Feedback", 1, 0.82, 0)
        GameTooltip:AddLine("Click, then Ctrl+C to copy the link and paste it in your browser. It opens a new issue for this " ..
            "download, already titled: say what you tried (the Journal, For me tasks, the tabs, the notes for level-ups, " ..
            "achievements or quests) and what happened.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    fb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    T.feedbackBox = fb
    return 28
end

-- ----------------------------------------------------------------------------
-- SLASH: /crq journal, /crq note <text>, /crq task <text>, /crq feedback (everything else goes on to /crq
-- as before)
-- ----------------------------------------------------------------------------
function T.JournalSlash(msg)
    local raw = strtrim and strtrim(msg or "") or (msg or "")
    local cmd = string.lower(raw)
    if cmd == "journal" or cmd == "diary" then
        P.OpenJournal()
        return true
    elseif cmd == "feedback" or cmd == "bug" or cmd == "bugs" or cmd == "issue" or cmd == "issues" then
        print("|cFFFFD100" .. DISPLAY_NAME .. ":|r " .. (T.BETA_VERSION and ("comments on beta " .. T.BETA_VERSION .. ": ") or "bugs, ideas and requests: ")
            .. T.FeedbackURL() .. "  (copy it from the box at the top of /crq options)")
        return true
    elseif cmd == "note" or cmd == "entry" or string.find(cmd, "^note%s") or string.find(cmd, "^entry%s") then
        local text = string.match(raw, "^%S+%s+(.+)$")         -- as typed (not lower-cased)
        local e = text and T.AddEntry(text)
        if e then
            P.ForMeChanged()
            print("|cFFFFD100" .. DISPLAY_NAME .. ":|r written in your Journal (" .. P.EntryStamp(e) .. ").")
        else
            print("|cFFFFD100" .. DISPLAY_NAME .. ":|r /crq note <text> writes a note in your Journal; /crq journal opens it.")
        end
        return true
    elseif cmd == "task" or string.find(cmd, "^task%s") then
        local text = string.match(raw, "^%S+%s+(.+)$")
        local task = text and T.AddTask(text)
        if task then
            P.ForMeChanged()
            print("|cFFFFD100" .. DISPLAY_NAME .. ":|r added to For me: " .. task.text ..
                (T.db.show and "" or "  (the tally is put away: /crq tally)") ..
                (T.db.opts.forMe and "" or "  (\"For me\" is off in the options)"))
        else
            print("|cFFFFD100" .. DISPLAY_NAME .. ":|r /crq task <what to do> adds a task to For me.")
        end
        return true
    end
    return false
end

do
    local baseSlash = SlashCmdList and SlashCmdList["CACHEREQUEST"]
    if baseSlash then
        SlashCmdList["CACHEREQUEST"] = function(msg)
            local ok, handled = pcall(T.JournalSlash, msg)
            if not ok then T.ReportError(handled) return end
            if not handled then baseSlash(msg) end
        end
    end
end

-- ----------------------------------------------------------------------------
-- EVENTS
-- ----------------------------------------------------------------------------
local events = CreateFrame("Frame")
T.journalEvents = events

-- Events this client may not have (an unknown event can't be registered): true if it took
function T.TryRegister(frame, event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        local ok, v = pcall(C_EventUtils.IsEventValid, event)
        if not (ok and v) then return false end
    end
    return pcall(frame.RegisterEvent, frame, event) and true or false
end

events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
T.TryRegister(events, "PLAYER_LEVEL_UP")
-- Achievements: only on a client that has them
T.achievementEvent = (type(GetAchievementInfo) == "function") and T.TryRegister(events, "ACHIEVEMENT_EARNED") or false
-- Quests turned in: the reward panel is read as it opens, the reward taken is seen through GetQuestReward
T.questTurnInEvent = T.TryRegister(events, "QUEST_TURNED_IN")
if T.questTurnInEvent then
    T.TryRegister(events, "QUEST_COMPLETE")
    if type(GetQuestReward) == "function" and hooksecurefunc then
        pcall(hooksecurefunc, "GetQuestReward", function(choice) pcall(T.OnQuestRewardChosen, choice) end)
    end
end

function T.OnJournalEvent(self, event, arg1, arg2, arg3)
    if event == "PLAYER_ENTERING_WORLD" then
        -- the character's name is sure by now: take its own notes waiting in the account file (once)
        if not T.notesEnteredWorld then
            T.notesEnteredWorld = true
            T.SafeCall(T.LoadNotes, T.notes, (type(QRF_SavedState) == "table") and QRF_SavedState.tallyNotes or nil)
        end
    elseif event == "PLAYER_LOGOUT" then              -- also on /reload: just before the saved files are written
        T.SafeCall(T.SaveNotesForLogout)
    elseif event == "ACHIEVEMENT_EARNED" then
        T.SafeCall(T.OnAchievementEarned, arg1)
    elseif event == "PLAYER_LEVEL_UP" then
        T.SafeCall(T.OnLevelUp, arg1)
    elseif event == "QUEST_COMPLETE" then
        T.SafeCall(T.OnQuestComplete)
    elseif event == "QUEST_TURNED_IN" then
        T.SafeCall(T.OnQuestTurnedIn, arg1, arg2, arg3)
    end
end
events:SetScript("OnEvent", T.OnJournalEvent)

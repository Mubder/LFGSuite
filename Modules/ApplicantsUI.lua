-- LFG Suite - Modules/ApplicantsUI.lua
-- Applicant log window: port of LFGAlert/LogFrame.lua (MIT, proven on
-- Midnight 12.x) onto the LFG Suite Applicants namespace (NS.A / db.applicants).
-- Scrollable sortable log, resizable persistent window, class icons, new-row
-- flash, lifecycle status icons, right-click whisper/invite/decline.
-- ID-based LFG actions are gated to the current listing session: Blizzard
-- reuses applicantIDs across delist/relist cycles.

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local A = NS.A
local Util = NS.Util
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end
local function DB() return A.db() end

local ClassColorize = Util.ClassColorize
local ShortName = Util.ShortName

local ROW_HEIGHT = 22
local ROW_GAP = 6
local ACTW = 72
local DEFAULT_W, DEFAULT_H = 860, 480
local MIN_W, MIN_H, MAX_W, MAX_H = 680, 320, 1400, 1000
local NAME_ICON_W = 18
local MAX_ROWS = 60
local SCROLL_ZONE = 30
local FLASH_WINDOW = 8

local logFrame, listArea, searchBox, countLabel, scrollBar
local filterButton, classBtn, keyBtn, resetFiltersBtn
local scrollOffset = 0
local updatingBar = false
local rows = {}
local view = {}
local headerWidgets = {}
local sortKey, sortDir = "time", "desc"
local selectedEntry
local lastN = 0
local refreshQueued = false
local uiReady = false

local RenderRows, ScrollBy, RefreshNow

local function TimeStr(t)
  if not t then return "--:--" end
  return date("%H:%M:%S", t)
end

-- ---------------------------------------------------------------------------
-- Table columns (one definition drives header, sorting and every row)
-- ---------------------------------------------------------------------------

local COLS = {
  { key = "time",   label = l("col_time", "Time"),       width = 56,  justify = "LEFT",  sort = true },
  { key = "name",   label = l("col_name2", "Applicant"), width = 112, justify = "LEFT",  sort = true },
  { key = "role",   label = l("col_role", "Role"),       width = 58,  justify = "LEFT" },
  { key = "spec",   label = l("col_spec", "Class/Spec"), width = 92,  justify = "LEFT" },
  { key = "run",    label = l("col_run", "Key"),         width = 58,  justify = "LEFT",  sort = true },
  { key = "ilvl",   label = l("col_ilvl", "iLvl"),       width = 46,  justify = "RIGHT", sort = true },
  { key = "score",  label = l("col_score", "M+ Score"),  width = 52,  justify = "RIGHT", sort = true },
  { key = "status", label = l("col_status", "Status"),   width = 112, justify = "LEFT",  sort = true },
  { key = "note",   label = l("col_note", "Notes"),      width = 0,   justify = "LEFT" },
}

local STATUS_ICON_FILES = {
  "Interface\\Icons\\INV_Misc_Bell_01",          -- queued
  "Interface\\RaidFrame\\ReadyCheck-Waiting",    -- invited
  "Interface\\RaidFrame\\ReadyCheck-Ready",      -- accepted
  "Interface\\RaidFrame\\ReadyCheck-NotReady",   -- declined / left
}
local STATUS_ICON_SIZE = 14
local STATUS_ICON_GAP = 5

local function Trunc(s, n)
  if not s or s == "" then return "" end
  if #s <= n then return s end
  local cut = s:sub(1, n - 1)
  cut = cut:gsub("[\194-\244][\128-\191]*$", "")
  return cut .. "…"
end

-- ---------------------------------------------------------------------------
-- Filter + search
-- ---------------------------------------------------------------------------

A.logFilter = A.logFilter or { status = "ALL", query = "" }
A.logFilter.class = A.logFilter.class or "ALL"
A.logFilter.minKey = A.logFilter.minKey or 0

local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT",
  "SHAMAN", "MAGE", "WARLOCK", "MONK", "DRUID", "DEMONHUNTER", "EVOKER" }

local function ClassLabel(classFile)
  if classFile == "ALL" then return l("all_classes", "All Classes") end
  local loc = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]
  return ClassColorize(classFile, loc or (classFile or "?"):lower():gsub("^%l", string.upper))
end

local KEY_OPTIONS = { 0, 2, 4, 6, 8, 10, 12, 15, 20 }

local function KeyLabel(minKey)
  if not minKey or minKey <= 0 then return l("filter_all", "All") end
  return l("key_label_fmt", "+%d+"):format(minKey)
end

function A.SetLogClassFilter(class)
  local c = (class or "ALL"):upper():gsub("%s+", "")
  if c ~= "ALL" and not (RAID_CLASS_COLORS and RAID_CLASS_COLORS[c]) then c = "ALL" end
  A.logFilter.class = c
  if A.RefreshLogUI then A.RefreshLogUI(true) end
  return c
end

function A.SetLogMinKey(n)
  n = math.max(0, math.floor(tonumber(n) or 0))
  A.logFilter.minKey = n
  if A.RefreshLogUI then A.RefreshLogUI(true) end
  return n
end

local FILTER_OPTIONS = {
  { key = "ALL",      label = l("filter_all", "All") },
  { key = "QUEUED",   label = l("filter_queued", "Queued") },
  { key = "INVITED",  label = l("filter_invited", "Invited") },
  { key = "ACCEPTED", label = l("filter_accepted", "Accepted") },
  { key = "DECLINED", label = l("filter_declined", "Declined") },
  { key = "GONE",     label = l("filter_gone", "Cancelled / Timeout") },
}

local DECLINED_SET = {
  declined = true, declined_full = true, declined_delisted = true,
  invitedeclined = true, failed = true,
}

local function FilterKeyForStatus(status)
  if status == "applied" then return "QUEUED" end
  if status == "invited" then return "INVITED" end
  if status == "inviteaccepted" then return "ACCEPTED" end
  if DECLINED_SET[status] then return "DECLINED" end
  if status == "cancelled" or status == "timedout" then return "GONE" end
  return "OTHER"
end

local function FilterLabel(key)
  for _, o in ipairs(FILTER_OPTIONS) do
    if o.key == key then return o.label end
  end
  return key or l("filter_all", "All")
end

function A.SetLogFilter(status)
  local s = (status or "ALL"):upper()
  if s == "QUEUE" then s = "QUEUED" end
  local valid = false
  for _, o in ipairs(FILTER_OPTIONS) do
    if o.key == s then valid = true break end
  end
  A.logFilter.status = valid and s or "ALL"
  if A.RefreshLogUI then A.RefreshLogUI(true) end
  return A.logFilter.status
end

function A.SetLogSearch(q)
  A.logFilter.query = (q or ""):lower()
  if A.RefreshLogUI then A.RefreshLogUI(true) end
end

function A.ResetLogFilters()
  A.logFilter.status = "ALL"
  A.logFilter.class = "ALL"
  A.logFilter.minKey = 0
  A.logFilter.query = ""
  if searchBox then searchBox:SetText("") end
  if A.RefreshLogUI then A.RefreshLogUI(true) end
end

local function EntryMatches(entry)
  local f = A.logFilter
  if entry.separator then
    return f.status == "ALL" and (f.class or "ALL") == "ALL"
      and (f.minKey or 0) <= 0 and (f.query == nil or f.query == "")
  end
  if f.status ~= "ALL" and FilterKeyForStatus(entry.status) ~= f.status then
    return false
  end
  local cf = f.class or "ALL"
  if cf ~= "ALL" then
    local m0 = entry.members and entry.members[1]
    if not (m0 and m0.class == cf) then return false end
  end
  local mk = f.minKey or 0
  if mk > 0 and not (entry.key and entry.key >= mk) then
    return false
  end
  local q = f.query
  if q and q ~= "" then
    local m = entry.members and entry.members[1]
    local hay = {}
    if m then
      hay[#hay + 1] = m.name or ""
      hay[#hay + 1] = m.specName or ""
      hay[#hay + 1] = m.class or ""
      hay[#hay + 1] = m.localizedClass or ""
      local _, rolePlain = A.RoleTag(A.ResolveRole(m))
      hay[#hay + 1] = rolePlain or ""
      hay[#hay + 1] = A.ResolveRole(m) or ""
    end
    hay[#hay + 1] = entry.comment or ""
    hay[#hay + 1] = entry.status or ""
    hay[#hay + 1] = entry.dungeon or ""
    hay[#hay + 1] = entry.dungeonFull or ""
    hay[#hay + 1] = select(1, A.StatusLabel(entry.status)) or ""
    local blob = table.concat(hay, " "):lower()
    if not blob:find(q, 1, true) then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Sorting
-- ---------------------------------------------------------------------------

local SORT_VALUE = {
  time   = function(e) return e.t or 0 end,
  name   = function(e)
    local m = e.members and e.members[1]
    return (m and m.name or ""):lower()
  end,
  run    = function(e) return e.key or 0 end,
  ilvl   = function(e)
    local m = e.members and e.members[1]
    return (m and m.itemLevel) or 0
  end,
  score  = function(e)
    local m = e.members and e.members[1]
    return (m and A.EffectiveScore(m)) or 0
  end,
  status = function(e) return select(1, A.StatusLabel(e.status)) end,
}

local function ToggleSort(key)
  if not SORT_VALUE[key] then return end
  if sortKey == key then
    sortDir = (sortDir == "asc") and "desc" or "asc"
  else
    sortKey = key
    sortDir = (key == "name" or key == "status") and "asc" or "desc"
  end
  selectedEntry = nil
  if A.RefreshLogUI then A.RefreshLogUI(true) end
end

local function BuildView()
  wipe(view)
  local log = (DB() and DB().log) or {}
  if sortKey == "time" then
    if sortDir == "desc" then
      for i = #log, 1, -1 do
        local e = log[i]
        if EntryMatches(e) then view[#view + 1] = e end
      end
    else
      for i = 1, #log do
        local e = log[i]
        if EntryMatches(e) then view[#view + 1] = e end
      end
    end
  else
    for _, e in ipairs(log) do
      if EntryMatches(e) and not e.separator then view[#view + 1] = e end
    end
    local vf = SORT_VALUE[sortKey]
    table.sort(view, function(a, b)
      local va, vb = vf(a), vf(b)
      if va == vb then return (a.t or 0) > (b.t or 0) end
      if sortDir == "asc" then return va < vb end
      return va > vb
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Session guard for ID-based LFG actions
-- ---------------------------------------------------------------------------

local function RowLFGActionsAllowed(entry)
  return entry ~= nil and not entry.separator
    and entry.applicantID and entry.applicantID ~= 0
    and entry.session ~= nil
    and A.CurrentListingSession ~= nil
    and entry.session == A.CurrentListingSession()
end

-- ---------------------------------------------------------------------------
-- Context menu
-- ---------------------------------------------------------------------------

local function ShowRowMenu(anchor, entry)
  if not entry or entry.separator or not entry.members or not entry.members[1] then return end
  local mem = entry.members[1]
  local fullName = mem.name
  local applicantID = entry.applicantID

  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchor, function(_, root)
      root:CreateTitle(ShortName(fullName))
      root:CreateButton(l("m_whisper", "Whisper"), function()
        A.Whisper(fullName)
      end)
      root:CreateButton(l("m_invite_name", "Invite to group (by name)"), function()
        A.InviteByName(fullName)
      end)
      if RowLFGActionsAllowed(entry) then
        root:CreateButton(l("m_accept", "Accept applicant (LFG invite)"), function()
          A.InviteApplicantByID(applicantID)
        end)
        root:CreateButton(l("m_decline", "Decline applicant"), function()
          A.DeclineApplicantByID(applicantID)
        end)
      end
      root:CreateDivider()
      root:CreateButton(l("m_copy_name", "Copy name"), function()
        local eb = ChatEdit_ChooseBoxForSend()
        if eb then
          eb:Show()
          eb:SetText(fullName)
          eb:HighlightText()
        end
      end)
    end)
    return
  end

  if not LFGSuiteApplicantsDropMenu then
    CreateFrame("Frame", "LFGSuiteApplicantsDropMenu", UIParent, "UIDropDownMenuTemplate")
  end
  local menu = {
    { text = ShortName(fullName), isTitle = true, notCheckable = true },
    { text = l("m_whisper", "Whisper"), notCheckable = true, func = function() A.Whisper(fullName) end },
    { text = l("m_invite_name", "Invite to group (by name)"), notCheckable = true, func = function()
        A.InviteByName(fullName)
      end },
  }
  if RowLFGActionsAllowed(entry) then
    menu[#menu + 1] = { text = l("m_decline", "Decline applicant"), notCheckable = true,
      func = function() A.DeclineApplicantByID(applicantID) end }
  end
  EasyMenu(menu, LFGSuiteApplicantsDropMenu, "cursor", 0, 0, "MENU")
end

-- ---------------------------------------------------------------------------
-- Class icon
-- ---------------------------------------------------------------------------

local function SetClassIcon(tex, classFile)
  if not tex then return end
  if not classFile or classFile == "" then tex:SetTexture(nil) return end
  if C_Texture and C_Texture.GetClassNameIconAtlas then
    local ok, atlas = pcall(C_Texture.GetClassNameIconAtlas, classFile)
    if ok and atlas then
      local okS = pcall(tex.SetAtlas, tex, atlas)
      if okS then return end
    end
  end
  pcall(tex.SetAtlas, tex, "ClassIcon-" .. classFile .. "-Circle")
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

local function MakeRow(i)
  local b = CreateFrame("Button", nil, listArea)
  b:SetHeight(ROW_HEIGHT)
  b:SetPoint("TOPLEFT", listArea, "TOPLEFT", 4, -(i - 1) * ROW_HEIGHT - 4)
  b:SetPoint("TOPRIGHT", listArea, "TOPRIGHT", -(SCROLL_ZONE + 4), -(i - 1) * ROW_HEIGHT - 4)

  local stripe = b:CreateTexture(nil, "BACKGROUND")
  stripe:SetAllPoints()
  stripe:SetColorTexture(0.5, 0.38, 0.12, 0.2)
  b.stripe = stripe

  local selTex = b:CreateTexture(nil, "ARTWORK")
  selTex:SetAllPoints()
  selTex:SetColorTexture(1, 0.82, 0, 0.15)
  selTex:Hide()
  b.selTex = selTex

  local accent = b:CreateTexture(nil, "OVERLAY")
  accent:SetSize(3, ROW_HEIGHT - 6)
  accent:SetPoint("LEFT", b, "LEFT", 0, 0)
  accent:SetColorTexture(1, 0.82, 0, 0.95)
  accent:Hide()
  b.accent = accent

  local flash = b:CreateTexture(nil, "ARTWORK")
  flash:SetAllPoints()
  flash:SetColorTexture(1, 0.82, 0, 0.20)
  flash:Hide()
  local ag = flash:CreateAnimationGroup()
  local alpha = ag:CreateAnimation("Alpha")
  alpha:SetFromAlpha(1)
  alpha:SetToAlpha(0)
  alpha:SetDuration(0.8)
  alpha:SetSmoothing("OUT")
  b.flash = flash
  b.flashAnim = ag

  b.icon = b:CreateTexture(nil, "OVERLAY")
  b.icon:SetSize(14, 14)

  b.cols = {}
  local x = 2
  local statusX = nil
  for _, c in ipairs(COLS) do
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH(c.justify)
    fs:SetWordWrap(false)
    if c.key == "note" then
      fs:SetPoint("LEFT", b, "LEFT", x, 0)
      fs:SetPoint("RIGHT", b, "RIGHT", -(2 + ACTW + ROW_GAP), 0)
    elseif c.key == "name" then
      b.icon:SetPoint("LEFT", b, "LEFT", x + 1, 1)
      fs:SetPoint("LEFT", b, "LEFT", x + NAME_ICON_W, 0)
      fs:SetWidth(c.width)
      x = x + c.width + NAME_ICON_W + ROW_GAP
    else
      if c.key == "status" then statusX = x end
      fs:SetPoint("LEFT", b, "LEFT", x, 0)
      fs:SetWidth(c.width)
      x = x + c.width + ROW_GAP
    end
    b.cols[c.key] = fs
  end

  if statusX then
    b.statusIcons = {}
    for i, texPath in ipairs(STATUS_ICON_FILES) do
      local ic = b:CreateTexture(nil, "OVERLAY")
      ic:SetSize(STATUS_ICON_SIZE, STATUS_ICON_SIZE)
      ic:SetPoint("TOPLEFT", b, "TOPLEFT", statusX + (i - 1) * (STATUS_ICON_SIZE + STATUS_ICON_GAP), -4)
      ic:SetTexture(texPath)
      ic:SetDesaturated(true)
      ic:SetAlpha(0.3)
      ic:Hide()
      b.statusIcons[i] = ic
    end
  end

  b.act = {}
  local actDefs = {
    { icon = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up", tip = l("act_whisper", "Whisper") },
    { icon = "Interface\\RaidFrame\\ReadyCheck-Ready", tip = l("act_invite", "Invite to group") },
    { icon = "Interface\\RaidFrame\\ReadyCheck-NotReady", tip = l("act_decline", "Decline applicant") },
  }
  for i, a in ipairs(actDefs) do
    local ab = CreateFrame("Button", nil, b)
    ab:SetSize(20, 20)
    ab:SetPoint("RIGHT", b, "RIGHT", -2 - (3 - i) * 24, 0)
    ab:SetNormalTexture(a.icon)
    ab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    ab:SetScript("OnClick", function()
      local e = b.entry
      if not e or e.separator or not e.members or not e.members[1] then return end
      local fullName, applicantID = e.members[1].name, e.applicantID
      if i == 1 then
        A.Whisper(fullName)
      elseif i == 2 then
        if RowLFGActionsAllowed(e) then A.InviteApplicantByID(applicantID) end
        A.InviteByName(fullName)
      elseif RowLFGActionsAllowed(e) then
        A.DeclineApplicantByID(applicantID)
      end
    end)
    ab:SetScript("OnEnter", function(self)
      local e = b.entry
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if e and not e.separator and e.members and e.members[1] then
        GameTooltip:SetText(a.tip .. ": " .. ShortName(e.members[1].name), 1, 1, 1)
      else
        GameTooltip:SetText(a.tip, 1, 1, 1)
      end
      GameTooltip:Show()
    end)
    ab:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.act[i] = ab
  end

  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(self, button)
    if button == "RightButton" and self.entry then
      ShowRowMenu(self, self.entry)
    elseif self.entry and not self.entry.separator then
      selectedEntry = (selectedEntry == self.entry) and nil or self.entry
      RenderRows()
    end
  end)
  b:SetScript("OnMouseWheel", function(_, delta) ScrollBy(delta) end)
  b:SetScript("OnEnter", function(self)
    if not self.entry then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local e = self.entry
    if e.separator then
      GameTooltip:SetText(e.separator)
      GameTooltip:Show()
      return
    end
    local m = e.members and e.members[1]
    if not m then return end
    GameTooltip:SetText(ShortName(m.name), 1, 1, 1)
    if m.class then
      local line = (m.specName and (m.specName .. " ") or "") .. (m.class or "")
      GameTooltip:AddLine(line, 1, 0.82, 0)
    end
    local roleTag = A.RoleTag(A.ResolveRole(m))
    GameTooltip:AddDoubleLine(l("tt_role", "Role"), roleTag, 1, 1, 1, 1, 1, 1)
    if e.dungeon or e.key then
      local runLine = (e.key and ("+" .. e.key .. " ") or "") .. (e.dungeonFull or e.dungeon or "")
      if e.keySource == "keystone" then runLine = runLine .. "|cffaaaaaa" .. l("tt_yourkey", " (your key)") .. "|r" end
      GameTooltip:AddDoubleLine(l("tt_run", "Run"), runLine, 1, 1, 1, 1, 0.82, 0)
    end
    if e.listingTitle and e.listingTitle ~= "" then
      GameTooltip:AddDoubleLine(l("tt_listing", "Listing"), e.listingTitle, 1, 1, 1, 0.8, 0.8, 0.8)
    end
    GameTooltip:AddDoubleLine(l("tt_ilvl", "Item level"), tostring(m.itemLevel or "-"), 1, 1, 1, 1, 1, 1)
    local blizz = (m.dungeonScore and m.dungeonScore > 0) and tostring(m.dungeonScore) or "-"
    local rio = (m.rioScore and m.rioScore > 0) and tostring(m.rioScore) or "-"
    GameTooltip:AddDoubleLine(l("tt_blizz", "M+ rating (Blizzard)"), blizz, 1, 1, 1, 1, 1, 1)
    local rioSuffix = _G.RaiderIO and "" or l("tt_rio_install", " (install Raider.IO)")
    GameTooltip:AddDoubleLine(l("tt_rio", "RIO score") .. rioSuffix, rio, 1, 1, 1, 1, 1, 1)
    if (e.numMembers or 1) > 1 and e.members then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(l("tt_group_fmt", "Group application (%d):"):format(e.numMembers), 0.9, 0.9, 0.9)
      for i = 2, math.min(#e.members, 8) do
        local o = e.members[i]
        local oScore = (o.rioScore and o.rioScore > 0) and o.rioScore or (o.dungeonScore or "-")
        GameTooltip:AddDoubleLine(ShortName(o.name),
          (o.specName or o.class or "") .. "  ilvl " .. tostring(o.itemLevel or "-") .. "  M+ " .. tostring(oScore),
          1, 1, 1, 0.9, 0.9, 0.9)
      end
    end
    if e.comment and e.comment ~= "" then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("\"" .. e.comment .. "\"", 0.7, 0.9, 1, true)
    end
    if e.autoDeclined then
      local reason = e.declineReason or l("auto_label", "Auto")
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(l("tt_auto_declined", "Auto-declined (%s)"):format(reason), 1, 0.4, 0.35)
    end
    if e.history and #e.history > 1 then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(l("tt_history", "History"), 0.9, 0.9, 0.9)
      for hi = math.max(1, #e.history - 5), #e.history do
        local hh = e.history[hi]
        local hlabel = select(1, A.StatusLabel(hh.status)) or tostring(hh.status)
        GameTooltip:AddDoubleLine(TimeStr(hh.t), hlabel, 0.7, 0.7, 0.7, 0.85, 0.85, 0.85)
      end
    end
    local label = select(1, A.StatusLabel(e.status)) or tostring(e.status)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(l("tt_status_fmt", "Status: %s"):format(label), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(string.format("%s > %s > %s  •  X %s / %s",
      l("tt_icon_queued", "Queued"), l("tt_icon_invited", "Invited"), l("tt_icon_accepted", "Accepted"),
      l("tt_icon_declined", "Declined"), l("tt_icon_left", "Left / expired")), 0.6, 0.6, 0.6)
    GameTooltip:AddLine(l("tt_rc_hint", "Right-click: whisper / invite / decline"), 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function StatusTint(status)
  if status == "inviteaccepted" then return 0.15, 0.6, 0.2 end
  if status == "invited" then return 0.1, 0.45, 0.16 end
  if status == "applied" then return 0.5, 0.38, 0.12 end
  if status == "cancelled" or status == "timedout" then return 0.35, 0.35, 0.35 end
  return 0.55, 0.12, 0.12
end

local function EntryColumns(entry)
  if entry.separator then return nil end
  local m = entry.members and entry.members[1]
  local cols = {}
  cols.time = TimeStr(entry.t)
  cols.status = ""
  if entry.key and entry.dungeon then
    cols.run = "|cffffd100+" .. tostring(entry.key) .. " " .. Trunc(entry.dungeon, 5) .. "|r"
  elseif entry.key then
    cols.run = "|cffffd100+" .. tostring(entry.key) .. "|r"
  elseif entry.dungeon then
    cols.run = Trunc(entry.dungeon, 7)
  else
    cols.run = "-"
  end
  if not m then
    cols.name, cols.role, cols.spec, cols.ilvl, cols.score, cols.note = "?", "-", "-", "-", "-", ""
    return cols
  end
  local star = ""
  local ilvlTxt, scoreTxt
  local db = DB()
  if db and ((db.minIlvl or 0) > 0 or (db.minScore or 0) > 0) then
    local meetsIlvl, meetsScore, ma = A.MeetsThresholds(m)
    local meetsAll = ma and true or false
    local ilvlNum = (m.itemLevel and m.itemLevel > 0) and math.floor(m.itemLevel) or nil
    local scoreNum = A.EffectiveScore(m)
    if ilvlNum then
      ilvlTxt = (meetsIlvl and "|cff33cc33" or "|cffff5555") .. tostring(ilvlNum) .. "|r"
    else
      ilvlTxt = "-"
    end
    if scoreNum and scoreNum > 0 then
      scoreTxt = (meetsScore and "|cff33cc33" or "|cffff5555") .. tostring(math.floor(scoreNum)) .. "|r"
    else
      scoreTxt = "-"
    end
    if meetsAll then star = "|cffffd100* |r" end
  else
    ilvlTxt = (m.itemLevel and m.itemLevel > 0) and tostring(math.floor(m.itemLevel)) or "-"
    local scoreNum = (m.rioScore and m.rioScore > 0) and m.rioScore or (m.dungeonScore or 0)
    scoreTxt = (scoreNum and scoreNum > 0) and tostring(math.floor(scoreNum)) or "-"
  end
  local nameTxt = star .. ClassColorize(m.class, Trunc(ShortName(m.name), 18))
  if (entry.numMembers or 1) > 1 then
    nameTxt = nameTxt .. " |cffaaaaaa+" .. ((entry.numMembers or 1) - 1) .. "|r"
  end
  cols.name = nameTxt
  cols.role = A.RoleTag(A.ResolveRole(m))
  cols.spec = Trunc(m.specName or m.localizedClass or m.class or "-", 14)
  cols.ilvl = ilvlTxt
  cols.score = scoreTxt
  cols.note = (entry.comment and entry.comment ~= "") and ("|cff88bbff" .. Trunc(entry.comment, 40) .. "|r") or ""
  return cols
end

-- ---------------------------------------------------------------------------
-- Render loop
-- ---------------------------------------------------------------------------

local function StyleStatusIcons(row, entry)
  if not row.statusIcons then return end
  if not entry or entry.separator then
    for _, ic in ipairs(row.statusIcons) do ic:Hide() end
    return
  end
  local st = entry.status
  local invitedDone = (st == "invited" or st == "inviteaccepted" or st == "invitedeclined")
  local acceptedDone = (st == "inviteaccepted")
  local endedKind = "none"
  if DECLINED_SET[st] then
    endedKind = "declined"
  elseif st == "cancelled" or st == "timedout" then
    endedKind = "gone"
  end
  for idx, ic in ipairs(row.statusIcons) do
    ic:Show()
    ic:SetVertexColor(1, 1, 1)
    ic:SetDesaturated(false)
    ic:SetAlpha(1)
    if idx == 1 then
      -- queued: always reached for a real entry
    elseif idx == 2 and not invitedDone or idx == 3 and not acceptedDone then
      ic:SetDesaturated(true)
      ic:SetAlpha(0.30)
    elseif idx == 4 then
      if endedKind == "none" then
        ic:SetDesaturated(true)
        ic:SetAlpha(0.30)
      elseif endedKind == "gone" then
        ic:SetDesaturated(true)
        ic:SetVertexColor(0.72, 0.72, 0.85)
        ic:SetAlpha(0.85)
      end
    end
  end
end

local function RenderRow(row, entry, i)
  if not entry then
    row:Hide()
    row.entry = nil
    return
  end
  row:Show()
  row.entry = entry
  local tr, tg, tb, ta = 0.2, 0.2, 0.2, 0.12
  if not entry.separator then
    tr, tg, tb = StatusTint(entry.status)
    ta = (i and i % 2 == 0) and 0.13 or 0.24
  end
  row.stripe:SetColorTexture(tr, tg, tb, ta)
  local m0 = (not entry.separator) and entry.members and entry.members[1] or nil
  SetClassIcon(row.icon, m0 and m0.class or nil)
  StyleStatusIcons(row, entry)
  row.act[1]:SetShown(not entry.separator)
  row.act[2]:SetShown(not entry.separator)
  row.act[3]:SetShown(RowLFGActionsAllowed(entry))
  local sel = (entry == selectedEntry)
  if sel then
    row.selTex:Show()
    if row.accent then row.accent:Show() end
  else
    row.selTex:Hide()
    if row.accent then row.accent:Hide() end
  end
  if not entry.separator and entry.status == "applied" and (time() - (entry.t or 0)) <= FLASH_WINDOW then
    row.flash:Show()
    if not row.flashAnim:IsPlaying() then row.flashAnim:Play() end
  else
    row.flashAnim:Stop()
    row.flash:Hide()
  end
  if entry.separator then
    for _, c in ipairs(COLS) do
      row.cols[c.key]:SetText(c.key == "name" and entry.separator or "")
    end
  else
    local okR, vals = pcall(EntryColumns, entry)
    if okR and vals then
      for _, c in ipairs(COLS) do
        row.cols[c.key]:SetText(vals[c.key] or "")
      end
    else
      A._lastRenderError = tostring(vals)
      for _, c in ipairs(COLS) do
        row.cols[c.key]:SetText(c.key == "name" and "|cffff5555Render error — /lfgs version|r" or "")
      end
    end
  end
end

local function VisibleRowCount()
  if not listArea then return 1 end
  local h = (listArea:GetHeight() or 0) - 8
  local visible = math.floor(h / ROW_HEIGHT + 0.5)
  if visible < 1 then visible = 1 end
  if visible > MAX_ROWS then visible = MAX_ROWS end
  return visible
end

RenderRows = function()
  if not listArea then return end
  local n = #view
  local visible = VisibleRowCount()
  local maxOff = math.max(0, n - visible)
  if scrollOffset > maxOff then scrollOffset = maxOff end
  if scrollOffset < 0 then scrollOffset = 0 end
  if scrollBar then
    updatingBar = true
    scrollBar:SetMinMaxValues(0, maxOff * ROW_HEIGHT)
    scrollBar:SetValue(scrollOffset * ROW_HEIGHT)
    updatingBar = false
    scrollBar:SetShown(n > visible)
  end
  for i = 1, visible do
    local row = rows[i]
    if not row then
      local okR, r = pcall(MakeRow, i)
      if okR and r then
        row = r
        rows[i] = row
        A._rowsBuilt = (A._rowsBuilt or 0) + 1
      else
        A._rowBuildError = "row " .. i .. ": " .. tostring(r)
        return
      end
    end
    RenderRow(row, view[scrollOffset + i], i)
  end
  for i = visible + 1, #rows do
    rows[i]:Hide()
    rows[i].entry = nil
  end
  if n == 0 then
    local r = rows[1]
    if r then
      local log = DB() and DB().log or {}
      local hint = (#log == 0) and l("empty_none", "No applicants logged yet — new queues will appear here")
        or l("empty_filtered", "No match — set Filter: All and clear the search box")
      r:Show()
      r.entry = nil
      for _, c in ipairs(COLS) do
        r.cols[c.key]:SetText(c.key == "name" and ("|cffaaaaaa" .. hint .. "|r") or "")
      end
      r.icon:SetTexture(nil)
      r.selTex:Hide()
      if r.accent then r.accent:Hide() end
      if r.statusIcons then
        for _, ic in ipairs(r.statusIcons) do ic:Hide() end
      end
      r.flash:Hide()
      r.act[1]:Hide()
      r.act[2]:Hide()
      r.act[3]:Hide()
    end
  end
end

ScrollBy = function(delta)
  scrollOffset = scrollOffset + delta * 3
  RenderRows()
end

-- ---------------------------------------------------------------------------
-- Filter/menu button labels
-- ---------------------------------------------------------------------------

local function SetButtonLabel(btn, text)
  if not btn then return end
  if btn.Text then btn.Text:SetText(text) else btn:SetText(text) end
end

local function RefreshFilterButtons()
  SetButtonLabel(filterButton, l("fmt_status_btn", "Status: %s"):format(FilterLabel(A.logFilter.status)))
  local cf = A.logFilter.class or "ALL"
  local classLabel = cf == "ALL" and l("filter_all", "All")
    or ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cf]) or cf)
  SetButtonLabel(classBtn, l("fmt_class_btn", "Class: %s"):format(classLabel))
  SetButtonLabel(keyBtn, l("fmt_key_btn", "Key: %s"):format(KeyLabel(A.logFilter.minKey)))
  if resetFiltersBtn then
    local active = A.logFilter.status ~= "ALL" or (A.logFilter.class or "ALL") ~= "ALL"
      or (A.logFilter.minKey or 0) > 0 or (A.logFilter.query ~= nil and A.logFilter.query ~= "")
    resetFiltersBtn:SetShown(active)
  end
end

local function RefreshHeaderWidgets()
  for key, w in pairs(headerWidgets) do
    if SORT_VALUE[key] and w then
      local arrow = ""
      if sortKey == key then
        arrow = (sortDir == "asc") and " ^" or " v"
      end
      w:SetText(w.label .. arrow)
    end
  end
end

local function ShowClassMenu(anchor)
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchor, function(_, root)
      root:CreateTitle(l("class_filter_title", "Filter by class"))
      root:CreateCheckbox(l("all_classes", "All Classes"),
        function() return (A.logFilter.class or "ALL") == "ALL" end,
        function() A.SetLogClassFilter("ALL") end)
      for _, classFile in ipairs(CLASS_ORDER) do
        local cf = classFile
        root:CreateCheckbox(ClassLabel(cf),
          function() return A.logFilter.class == cf end,
          function() A.SetLogClassFilter(cf) end)
      end
    end)
    return
  end
  if not LFGSuiteApplicantsClassMenu then
    CreateFrame("Frame", "LFGSuiteApplicantsClassMenu", UIParent, "UIDropDownMenuTemplate")
  end
  local menu = { { text = l("class_filter_title", "Filter by class"), isTitle = true, notCheckable = true },
    { text = l("all_classes", "All Classes"), checked = (A.logFilter.class or "ALL") == "ALL",
      func = function() A.SetLogClassFilter("ALL") end } }
  for _, classFile in ipairs(CLASS_ORDER) do
    local cf = classFile
    menu[#menu + 1] = { text = ClassLabel(cf), checked = A.logFilter.class == cf, notCheckable = false,
      func = function() A.SetLogClassFilter(cf) end }
  end
  EasyMenu(menu, LFGSuiteApplicantsClassMenu, "cursor", 0, 0, "MENU")
end

local function ShowKeyMenu(anchor)
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchor, function(_, root)
      root:CreateTitle(l("key_filter_title", "Minimum key level"))
      for _, kv in ipairs(KEY_OPTIONS) do
        local label = kv == 0 and l("all_keys", "All Keys") or l("min_key_fmt", "Minimum +%d"):format(kv)
        root:CreateCheckbox(label,
          function() return (A.logFilter.minKey or 0) == kv end,
          function() A.SetLogMinKey(kv) end)
      end
    end)
    return
  end
  if not LFGSuiteApplicantsKeyMenu then
    CreateFrame("Frame", "LFGSuiteApplicantsKeyMenu", UIParent, "UIDropDownMenuTemplate")
  end
  local menu = { { text = l("key_filter_title", "Minimum key level"), isTitle = true, notCheckable = true } }
  for _, kv in ipairs(KEY_OPTIONS) do
    local label = kv == 0 and l("all_keys", "All Keys") or l("min_key_fmt", "Minimum +%d"):format(kv)
    menu[#menu + 1] = { text = label, checked = (A.logFilter.minKey or 0) == kv, notCheckable = false,
      func = function() A.SetLogMinKey(kv) end }
  end
  EasyMenu(menu, LFGSuiteApplicantsKeyMenu, "cursor", 0, 0, "MENU")
end

local function ShowFilterMenu(anchor)
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchor, function(_, root)
      root:CreateTitle(l("status_filter_title", "Filter by status"))
      for _, o in ipairs(FILTER_OPTIONS) do
        root:CreateCheckbox(o.label, function() return A.logFilter.status == o.key end, function()
          A.SetLogFilter(o.key)
        end)
      end
    end)
    return
  end
  if not LFGSuiteApplicantsFilterMenu then
    CreateFrame("Frame", "LFGSuiteApplicantsFilterMenu", UIParent, "UIDropDownMenuTemplate")
  end
  local menu = { { text = l("status_filter_title", "Filter by status"), isTitle = true, notCheckable = true } }
  for _, o in ipairs(FILTER_OPTIONS) do
    menu[#menu + 1] = { text = o.label, checked = A.logFilter.status == o.key, notCheckable = false,
      func = function() A.SetLogFilter(o.key) end }
  end
  EasyMenu(menu, LFGSuiteApplicantsFilterMenu, "cursor", 0, 0, "MENU")
end

-- ---------------------------------------------------------------------------
-- Full refresh
-- ---------------------------------------------------------------------------

RefreshNow = function()
  if not (logFrame and listArea) then return end
  BuildView()
  local n = #view
  local db = DB()
  local log = (db and db.log) or {}
  if countLabel then
    local total = #log
    local suffix = ""
    if A.logFilter.status ~= "ALL" then suffix = suffix .. "  •  " .. FilterLabel(A.logFilter.status) end
    if (A.logFilter.class or "ALL") ~= "ALL" then
      local cf = A.logFilter.class
      suffix = suffix .. "  •  " .. ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cf]) or cf)
    end
    if (A.logFilter.minKey or 0) > 0 then suffix = suffix .. "  •  " .. KeyLabel(A.logFilter.minKey) end
    if A.logFilter.query ~= "" then suffix = suffix .. "  •  \"" .. A.logFilter.query .. "\"" end
    if db and ((db.minIlvl or 0) > 0 or (db.minScore or 0) > 0) then
      suffix = suffix .. string.format("  •  * %s / %s",
        (db.minIlvl or 0) > 0 and tostring(db.minIlvl) or "-",
        (db.minScore or 0) > 0 and tostring(db.minScore) or "-")
    end
    countLabel:SetText(l("entries_fmt", "%d of %d entries"):format(n, total) .. suffix)
  end
  RefreshFilterButtons()
  RefreshHeaderWidgets()
  if n > lastN and scrollOffset <= 2 then
    scrollOffset = 0
  elseif n < lastN then
    scrollOffset = 0
  end
  lastN = n
  RenderRows()
end

function A.RefreshLogUI(force)
  if not logFrame then return end
  if force then
    refreshQueued = false
    RefreshNow()
    return
  end
  if refreshQueued then return end
  refreshQueued = true
  C_Timer.After(0.1, function()
    refreshQueued = false
    if logFrame then RefreshNow() end
  end)
end

function A.GetLogUIState()
  local vis = 0
  for _, r in ipairs(rows) do
    if r:IsShown() then vis = vis + 1 end
  end
  return {
    built = logFrame ~= nil,
    shown = logFrame and logFrame:IsShown() or false,
    visibleRows = vis,
    scrollOffset = scrollOffset or 0,
  }
end

function A.ToggleLogUI(force)
  if not logFrame then A.BuildLogUI() end
  if not logFrame then return end
  if force == true then
    logFrame:Show()
  elseif force == false then
    logFrame:Hide()
  else
    if logFrame:IsShown() then logFrame:Hide() else logFrame:Show() end
  end
  A.RefreshLogUI(true)
end

-- ---------------------------------------------------------------------------
-- Window position / size / scale persistence
-- ---------------------------------------------------------------------------

local function DBUI()
  local db = DB()
  db.ui = db.ui or {}
  return db.ui
end

local function SaveUIPos()
  if not (logFrame and uiReady) then return end
  local x, y = logFrame:GetCenter()
  local ui = DBUI()
  ui.x, ui.y = x, y
end

local function SaveUISize()
  if not (logFrame and uiReady) then return end
  local ui = DBUI()
  ui.w, ui.h = logFrame:GetSize()
end

function A.SetUIScale(v)
  v = math.min(1.5, math.max(0.6, tonumber(v) or 1))
  local ui = DBUI()
  ui.scale = v
  if logFrame then logFrame:SetScale(v) end
end

function A.ResetUI()
  local db = DB()
  if db then db.ui = nil end
  if logFrame then
    logFrame:ClearAllPoints()
    logFrame:SetPoint("CENTER")
    logFrame:SetSize(DEFAULT_W, DEFAULT_H)
    logFrame:SetScale(1)
    A.RefreshLogUI(true)
  end
end

-- ---------------------------------------------------------------------------
-- Window construction
-- ---------------------------------------------------------------------------

function A.BuildLogUI()
  if logFrame then return end

  local bgTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil
  logFrame = CreateFrame("Frame", "LFGSuiteApplicantsFrame", UIParent, bgTemplate)
  A._logFrame = logFrame
  A._bgMode = "none"
  if logFrame.SetBackdrop then
    logFrame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    logFrame:SetBackdropColor(0.04, 0.06, 0.12, 0.96)
    logFrame:SetBackdropBorderColor(0.85, 0.68, 0.3, 1)
    A._bgMode = "backdrop"
  end
  local okBG, bgInfo = pcall(logFrame.GetBackdrop, logFrame)
  if not (okBG and bgInfo) then
    A._bgMode = "manual"
    local bg = logFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(0.04, 0.06, 0.12, 0.96)
    bg:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 6, -6)
    bg:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -6, 6)
    local function EdgeTex()
      local t = logFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
      t:SetColorTexture(0.85, 0.68, 0.30, 1)
      return t
    end
    local eT = EdgeTex(); eT:SetHeight(2)
    eT:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 4, -4)
    eT:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -4, -4)
    local eB = EdgeTex(); eB:SetHeight(2)
    eB:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", 4, 4)
    eB:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -4, 4)
    local eL = EdgeTex(); eL:SetWidth(2)
    eL:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 4, -4)
    eL:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", 4, 4)
    local eR = EdgeTex(); eR:SetWidth(2)
    eR:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -4, -4)
    eR:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -4, 4)
  end
  logFrame:Hide()

  local bell = logFrame:CreateTexture(nil, "OVERLAY")
  bell:SetSize(26, 26)
  bell:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 16, -10)
  bell:SetTexture("Interface\\Icons\\INV_Misc_Bell_01")

  local title = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("LEFT", bell, "RIGHT", 8, 0)
  title:SetText(l("log_title2", "Applicants") .. "  |cff999999(b" .. tostring(NS.BUILD) .. ")|r")
  title:SetTextColor(1, 0.82, 0)

  local close = CreateFrame("Button", nil, logFrame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -4, -4)

  local ui = (DB() and DB().ui) or {}
  local w = tonumber(ui.w) or DEFAULT_W
  local h = tonumber(ui.h) or DEFAULT_H
  w = math.min(MAX_W, math.max(MIN_W, w))
  h = math.min(MAX_H, math.max(MIN_H, h))
  logFrame:SetSize(w, h)
  logFrame:SetScale(math.min(1.5, math.max(0.6, tonumber(ui.scale) or 1)))
  if tonumber(ui.x) and tonumber(ui.y) then
    logFrame:SetPoint("CENTER", UIParent, "CENTER", ui.x, ui.y)
  else
    logFrame:SetPoint("CENTER")
  end
  logFrame:EnableMouse(true)
  logFrame:SetMovable(true)
  logFrame:SetResizable(true)
  if logFrame.SetMinResize then logFrame:SetMinResize(MIN_W, MIN_H) end
  if logFrame.SetMaxResize then logFrame:SetMaxResize(MAX_W, MAX_H) end
  logFrame:SetClampedToScreen(true)
  logFrame:SetFrameStrata("HIGH")
  tinsert(UISpecialFrames, "LFGSuiteApplicantsFrame")

  local dragArea = CreateFrame("Frame", nil, logFrame)
  dragArea:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 8, -6)
  dragArea:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -44, -6)
  dragArea:SetHeight(36)
  dragArea:EnableMouse(true)
  dragArea:RegisterForDrag("LeftButton")
  dragArea:SetScript("OnDragStart", function() logFrame:StartMoving() end)
  dragArea:SetScript("OnDragStop", function()
    logFrame:StopMovingOrSizing()
    SaveUIPos()
  end)
  dragArea:SetScript("OnHide", function()
    pcall(logFrame.StopMovingOrSizing, logFrame)
    SaveUIPos()
  end)

  local resizer = CreateFrame("Button", nil, logFrame)
  resizer:SetSize(16, 16)
  resizer:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -5, 5)
  resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-Size-BigRight")
  resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-Size-BigRight", "ADD")
  resizer:SetShown(logFrame.StartSizing ~= nil)
  resizer:SetScript("OnMouseDown", function()
    if logFrame.StartSizing then logFrame:StartSizing("BOTTOMRIGHT") end
  end)
  resizer:SetScript("OnMouseUp", function()
    logFrame:StopMovingOrSizing()
    SaveUISize()
  end)

  searchBox = CreateFrame("EditBox", nil, logFrame, "SearchBoxTemplate")
  searchBox:SetSize(160, 22)
  searchBox:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 14, -64)
  searchBox:SetAutoFocus(false)
  searchBox:SetMaxLetters(60)
  searchBox:SetScript("OnTextChanged", function(self)
    A.logFilter.query = (self:GetText() or ""):lower()
    A.RefreshLogUI(true)
  end)
  searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  searchBox:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)
  if searchBox.Instructions then
    searchBox.Instructions:SetText(l("search_hint", "Search..."))
  end

  local function DropLabel(text, x, w)
    local fs = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", logFrame, "TOPLEFT", x, -75)
    fs:SetWidth(w)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    fs:SetTextColor(1, 0.82, 0)
  end

  DropLabel(l("f_status", "Status:") .. " ", 184, 42)
  filterButton = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  filterButton:SetSize(100, 22)
  filterButton:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 228, -64)
  filterButton:SetText(l("fmt_status_btn", "Status: %s"):format(l("filter_all", "All")))
  filterButton:SetScript("OnClick", function(self) ShowFilterMenu(self) end)

  DropLabel(l("f_class", "Class:") .. " ", 336, 38)
  classBtn = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  classBtn:SetSize(110, 22)
  classBtn:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 376, -64)
  classBtn:SetText(l("fmt_class_btn", "Class: %s"):format(l("filter_all", "All")))
  classBtn:SetScript("OnClick", function(self) ShowClassMenu(self) end)

  DropLabel(l("f_key", "Key:") .. " ", 494, 30)
  keyBtn = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  keyBtn:SetSize(80, 22)
  keyBtn:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 526, -64)
  keyBtn:SetText(l("fmt_key_btn", "Key: %s"):format(l("filter_all", "All")))
  keyBtn:SetScript("OnClick", function(self) ShowKeyMenu(self) end)

  local headerFrame = CreateFrame("Frame", nil, logFrame)
  headerFrame:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 12, -90)
  headerFrame:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -12, -90)
  headerFrame:SetHeight(16)
  do
    local x = 4 + 2
    for _, c in ipairs(COLS) do
      local widget
      if c.sort then
        local btn = CreateFrame("Button", nil, headerFrame)
        btn:SetNormalFontObject("GameFontNormalSmall")
        btn:SetHighlightFontObject("GameFontHighlightSmall")
        btn:SetText(c.label)
        local fs = btn:GetFontString()
        if fs then
          fs:SetJustifyH(c.justify)
          fs:SetWordWrap(false)
        end
        btn.label = c.label
        btn.colKey = c.key
        btn:SetScript("OnClick", function() ToggleSort(c.key) end)
        widget = btn
      else
        local fs = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetJustifyH(c.justify)
        fs:SetWordWrap(false)
        fs:SetTextColor(1, 0.82, 0)
        fs:SetText(c.label)
        widget = fs
      end
      if c.key == "note" then
        widget:SetPoint("LEFT", headerFrame, "LEFT", x, 0)
        widget:SetPoint("RIGHT", headerFrame, "RIGHT", -2, 0)
      elseif c.key == "name" then
        widget:SetPoint("LEFT", headerFrame, "LEFT", x + NAME_ICON_W, 0)
        widget:SetWidth(c.width)
        x = x + c.width + NAME_ICON_W + ROW_GAP
      else
        widget:SetPoint("LEFT", headerFrame, "LEFT", x, 0)
        widget:SetWidth(c.width)
        x = x + c.width + ROW_GAP
      end
      headerWidgets[c.key] = widget
    end
  end

  local band = logFrame:CreateTexture(nil, "BACKGROUND")
  band:SetColorTexture(0, 0, 0, 0.38)
  band:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 10, -84)
  band:SetPoint("BOTTOMRIGHT", logFrame, "TOPRIGHT", -10, -110)
  local bandEdge = logFrame:CreateTexture(nil, "BACKGROUND")
  bandEdge:SetColorTexture(0.85, 0.68, 0.30, 0.85)
  bandEdge:SetHeight(1)
  bandEdge:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 10, -110)
  bandEdge:SetPoint("TOPRIGHT", logFrame, "TOPRIGHT", -10, -110)

  listArea = CreateFrame("Frame", nil, logFrame)
  listArea:SetPoint("TOPLEFT", logFrame, "TOPLEFT", 12, -114)
  listArea:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -12, 34)
  listArea:EnableMouse(true)
  listArea:SetScript("OnMouseWheel", function(_, delta) ScrollBy(delta) end)

  local function GoldHairline()
    local t = listArea:CreateTexture(nil, "BACKGROUND")
    t:SetColorTexture(0.85, 0.68, 0.30, 0.85)
    return t
  end
  local hTop = GoldHairline()
  hTop:SetHeight(1)
  hTop:SetPoint("TOPLEFT", listArea, "TOPLEFT", -3, 3)
  hTop:SetPoint("TOPRIGHT", listArea, "TOPRIGHT", 3, 3)
  local hBot = GoldHairline()
  hBot:SetHeight(1)
  hBot:SetPoint("BOTTOMLEFT", listArea, "BOTTOMLEFT", -3, -3)
  hBot:SetPoint("BOTTOMRIGHT", listArea, "BOTTOMRIGHT", 3, -3)
  local hLeft = GoldHairline()
  hLeft:SetWidth(1)
  hLeft:SetPoint("TOPLEFT", listArea, "TOPLEFT", -3, 3)
  hLeft:SetPoint("BOTTOMLEFT", listArea, "BOTTOMLEFT", -3, -3)
  local hRight = GoldHairline()
  hRight:SetWidth(1)
  hRight:SetPoint("TOPRIGHT", listArea, "TOPRIGHT", 3, 3)
  hRight:SetPoint("BOTTOMRIGHT", listArea, "BOTTOMRIGHT", 3, -3)

  local footLine = logFrame:CreateTexture(nil, "BACKGROUND")
  footLine:SetColorTexture(0.85, 0.68, 0.30, 0.55)
  footLine:SetHeight(1)
  footLine:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", 16, 33)
  footLine:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -16, 33)

  scrollBar = CreateFrame("Slider", "LFGSuiteApplicantsScrollBar", listArea)
  scrollBar:SetOrientation("VERTICAL")
  scrollBar:SetWidth(12)
  scrollBar:SetPoint("TOPRIGHT", listArea, "TOPRIGHT", -4, -8)
  scrollBar:SetPoint("BOTTOMRIGHT", listArea, "BOTTOMRIGHT", -4, 8)
  scrollBar:SetMinMaxValues(0, 0)
  scrollBar:SetValue(0)
  do
    local track = scrollBar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(0, 0, 0, 0.35)
    local thumb = scrollBar:CreateTexture(nil, "ARTWORK")
    thumb:SetSize(10, 36)
    thumb:SetColorTexture(0.85, 0.68, 0.30, 0.9)
    scrollBar:SetThumbTexture(thumb)
  end
  scrollBar:SetScript("OnValueChanged", function(_, v)
    if updatingBar then return end
    scrollOffset = math.floor(v / ROW_HEIGHT + 0.5)
    RenderRows()
  end)
  scrollBar:Hide()

  resetFiltersBtn = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  resetFiltersBtn:SetSize(110, 22)
  resetFiltersBtn:SetPoint("BOTTOMLEFT", logFrame, "BOTTOMLEFT", 14, 10)
  resetFiltersBtn:SetText(l("btn_reset_filters", "Reset Filters"))
  resetFiltersBtn:SetScript("OnClick", function() A.ResetLogFilters() end)
  resetFiltersBtn:Hide()

  local test = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  test:SetSize(80, 22)
  test:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -110, 10)
  test:SetText(l("btn_test_sound", "Test sound"))
  test:SetScript("OnClick", function() A.PlayAlertSound() end)

  local clear = CreateFrame("Button", nil, logFrame, "UIPanelButtonTemplate")
  clear:SetSize(90, 22)
  clear:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -14, 10)
  clear:SetText(l("btn_clear_log", "Clear Log"))
  if clear.Text then clear.Text:SetTextColor(1, 0.4, 0.35) end
  clear:SetScript("OnClick", function() A.ClearLog() end)

  countLabel = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  countLabel:SetPoint("BOTTOMRIGHT", logFrame, "BOTTOMRIGHT", -16, 36)
  countLabel:SetJustifyH("RIGHT")
  countLabel:SetTextColor(0.8, 0.8, 0.8)

  local hint = logFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hint:SetPoint("BOTTOM", logFrame, "BOTTOM", 0, 1)
  hint:SetText(l("footer_hint", "Left-click: select  •  Right-click: whisper / invite / decline  •  "
    .. "Scroll: browse  •  Click a column header to sort"))
  hint:SetTextColor(0.55, 0.55, 0.55)

  logFrame:HookScript("OnSizeChanged", function()
    if not uiReady then return end
    SaveUISize()
    A.RefreshLogUI(true)
  end)

  A._rowsBuilt, A._rowBuildError = 0, nil
  uiReady = true
  logFrame:Hide()
  A.RefreshLogUI(true)
end

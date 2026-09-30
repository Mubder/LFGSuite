-- LFG Suite - Modules/Queue.lua
-- PHASE 1. Absorbs: BetterBlizzQueue, IFTL "What did I queue for",
-- MythicPlusCount (auto queue accept, default OFF).
--
-- Feature checklist:
--   [x] Queue elapsed timer (LFD/LFR via GetLFGMode, battlegrounds via
--       GetBattlefieldTimeWaited), small movable frame
--   [x] Sound + optional taskbar flash when a queue pops
--       (LFG_PROPOSAL_SHOW / battleground confirm)
--   [x] "What did I queue for" banner: on joining a premade group
--       (LFG_LIST_APPLICATION_STATUS_UPDATED inviteaccepted + group-form
--       fallback) shows group name + description/comment + leader; dungeon
--       pops show the dungeon name + description. Stays 2 minutes
--       (/lfgs-configurable), with a destination card (dungeon name +
--       countdown, click to dismiss)
--   [x] Auto-accept queue pops (DEFAULT OFF)
--   [x] Estimated queue times: last 20 observed join->pop durations per
--       category; the timer shows "~avg" while queued
--   [x] Role-check popup QoL: pre-ticks remembered roles on the LFD
--       role-check dialog

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local Util = NS.Util
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

local QUEUE_DEFAULTS = {
  popSound = true,
  popSoundID = 8959,
  flash = true,
  banner = true,
  bannerSeconds = 120,
  showTimer = true,
  autoAccept = false, -- deliberately OFF by default
  history = {}, -- [category] = { observed join->pop seconds, last 20 }
}

local function MDB() return NS.EnsureModuleDB("queue", QUEUE_DEFAULTS) end

local LFG_CATS = {
  { "LE_LFG_CATEGORY_LFD", "Dungeon" },
  { "LE_LFG_CATEGORY_LFR", "Raid Finder" },
  { "LE_LFG_CATEGORY_FLEXRAID", "Flex Raid" },
}

local qStart, qLabel -- own-clock queue state (GetTime based)
local bgWait, bgLabel -- battleground wait (seconds)
local wasInGroup

-- ---------------------------------------------------------------------------
-- Banner
-- ---------------------------------------------------------------------------

local bannerFrame

local function BuildBanner()
  if bannerFrame then return end
  bannerFrame = CreateFrame("Frame", "LFGSuiteBanner", UIParent, "BackdropTemplate")
  bannerFrame:SetSize(560, 68)
  bannerFrame:SetPoint("TOP", UIParent, "TOP", 0, -140)
  bannerFrame:SetFrameStrata("HIGH")
  bannerFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  bannerFrame.title = bannerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  bannerFrame.title:SetPoint("TOP", bannerFrame, "TOP", 0, -10)
  bannerFrame.sub = bannerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  bannerFrame.sub:SetPoint("TOP", bannerFrame.title, "BOTTOM", 0, -4)
  bannerFrame.sub:SetWidth(520)
  bannerFrame:EnableMouse(true)
  bannerFrame:SetMovable(true)
  bannerFrame:SetClampedToScreen(true)
  bannerFrame:RegisterForDrag("LeftButton")
  -- Drag moves the banner; a click (press+release without dragging) closes it.
  bannerFrame:SetScript("OnMouseDown", function(self) self._lfgsDragged = nil end)
  bannerFrame:SetScript("OnDragStart", function(self)
    self._lfgsDragged = true
    self:StartMoving()
  end)
  bannerFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  bannerFrame:SetScript("OnMouseUp", function(self)
    if self._lfgsDragged then return end
    self:Hide()
  end)
  bannerFrame:Hide()
end

local bannerTimer
local destCard, destTicker

-- m:ss (defined here: the destination card runs before the timer-frame
-- section below declares its own FormatElapsed).
local function CardTime(secs)
  secs = math.floor(secs or 0)
  return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- Small themed card under the banner: where you are heading, for how long
-- the banner will stay. Click to dismiss both.
local function EnsureDestCard()
  if destCard then return destCard end
  destCard = CreateFrame("Frame", "LFGSuiteDestCard", UIParent)
  destCard:SetSize(300, 64)
  destCard:SetFrameStrata("HIGH")
  destCard:EnableMouse(true)
  destCard:SetScript("OnMouseUp", function(self)
    if bannerFrame then bannerFrame:Hide() end
    self:Hide()
  end)
  if NS.Theme and NS.Theme.Apply then NS.Theme.Apply(destCard) end
  destCard.caption = destCard:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  destCard.caption:SetPoint("TOPLEFT", destCard, "TOPLEFT", 0, -6)
  destCard.caption:SetWidth(300)
  destCard.caption:SetJustifyH("CENTER")
  destCard.caption:SetText("|cffffd100" .. l("dest_card", "Destination") .. "|r")
  destCard.name = destCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  destCard.name:SetPoint("TOPLEFT", destCard, "TOPLEFT", 10, -28)
  destCard.name:SetWidth(280)
  destCard.name:SetJustifyH("CENTER")
  destCard.sub = destCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  destCard.sub:SetPoint("TOPLEFT", destCard, "TOPLEFT", 10, -48)
  destCard.sub:SetWidth(280)
  destCard.sub:SetJustifyH("CENTER")
  destCard.count = destCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  destCard.count:SetPoint("TOPRIGHT", destCard, "TOPRIGHT", -8, -6)
  destCard:Hide()
  return destCard
end

local function ShowDestCard(name, sub, secs)
  if MDB().destCard == false then return end
  if not (name and name ~= "") then return end
  local card = EnsureDestCard()
  if not card then return end
  card.name:SetText(name)
  card.sub:SetText(sub and Util.Trunc(sub, 60) or "")
  card:ClearAllPoints()
  card:SetPoint("TOP", UIParent, "TOP", 0, bannerFrame and -214 or -140)
  card:Show()
  if destTicker then destTicker:Cancel() end
  local left = secs or 120
  card.count:SetText(CardTime(left))
  destTicker = C_Timer.NewTicker(1, function()
    left = left - 1
    if left <= 0 or not card:IsShown() then
      if destTicker then destTicker:Cancel() end
      destTicker = nil
      card:Hide()
      return
    end
    card.count:SetText(CardTime(left))
  end)
end

function NS.ShowBanner(title, sub, dest)
  local db = MDB()
  if db.banner == false then return end
  BuildBanner()
  if not bannerFrame then return end
  bannerFrame.title:SetText("|cffffd100" .. tostring(title) .. "|r")
  bannerFrame.sub:SetText(tostring(sub or ""))
  bannerFrame:SetAlpha(1)
  bannerFrame:Show()
  ShowDestCard(dest or sub, sub, tonumber(db.bannerSeconds) or 120)
  if bannerTimer then bannerTimer:Cancel() end
  local secs = tonumber(db.bannerSeconds) or 120
  bannerTimer = C_Timer.NewTimer(secs, function()
    if bannerFrame and bannerFrame:IsShown() then
      bannerFrame:Hide()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Pop alerts
-- ---------------------------------------------------------------------------

local function QueuePop(title, sub)
  local db = MDB()
  if db.popSound ~= false then
    pcall(PlaySound, tonumber(db.popSoundID) or 8959, "Master")
  end
  if db.flash ~= false and FlashClientIcon then
    pcall(FlashClientIcon)
  end
  -- sub doubles as the destination for the popup card.
  NS.ShowBanner(title, sub, sub)
end

-- ---------------------------------------------------------------------------
-- Queue state / timer frame
-- ---------------------------------------------------------------------------

local function EvaluateLFG()
  for _, c in ipairs(LFG_CATS) do
    local cat = _G[c[1]]
    if cat then
      local ok, mode = pcall(GetLFGMode, cat)
      if ok and mode == "queued" then
        return c[2]
      end
    end
  end
end

local function EvaluateBattlefield()
  for i = 1, 3 do
    local ok, status, mapName = pcall(GetBattlefieldStatus, i)
    if ok and status == "queued" and mapName and mapName ~= "" then
      local okW, waited = pcall(GetBattlefieldTimeWaited, i)
      if okW and type(waited) == "number" then
        -- Some clients report ms; anything absurd is treated as ms.
        if waited > 2592000 then waited = waited / 1000 end
        return waited, mapName
      end
      return nil, mapName
    end
  end
end

local timerFrame

local function FormatElapsed(secs)
  secs = math.floor(secs or 0)
  return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- ---------------------------------------------------------------------------
-- Queue-time history -> "how long will this take" estimates
-- ---------------------------------------------------------------------------

local function RecordQueueTime(cat, secs)
  if not (type(cat) == "string" and type(secs) == "number" and secs > 5 and secs < 86400) then return end
  local db = MDB()
  db.history = db.history or {}
  local h = db.history[cat] or {}
  h[#h + 1] = math.floor(secs)
  while #h > 20 do table.remove(h, 1) end
  db.history[cat] = h
end

local function AverageQueueTime(cat)
  local h = cat and MDB().history and MDB().history[cat]
  if type(h) ~= "table" or #h == 0 then return nil end
  local sum = 0
  for _, v in ipairs(h) do sum = sum + (tonumber(v) or 0) end
  if sum <= 0 then return nil end
  return sum / #h
end

local function EstimateSuffix(cat)
  local avg = AverageQueueTime(cat)
  if not avg then return "" end
  return "  |cff888888~" .. FormatElapsed(avg) .. "|r"
end

local function UpdateTimer()
  if not timerFrame then return end
  local db = MDB()
  local text
  if qStart then
    text = string.format("|cffffd100%s|r %s", l("timer_queue", "Queue:"), FormatElapsed(GetTime() - qStart))
    if qLabel then text = text .. "  |cffcccccc" .. qLabel .. "|r" end
    text = text .. EstimateSuffix(qLabel)
  elseif bgWait then
    text = string.format("|cffffd100%s|r %s", l("timer_bg", "BG queue:"), FormatElapsed(bgWait))
    if bgLabel then text = text .. "  |cffcccccc" .. bgLabel .. "|r" end
    text = text .. EstimateSuffix("BG")
  end
  if text and db.showTimer ~= false then
    timerFrame.text:SetText(text)
    timerFrame:Show()
  else
    timerFrame:Hide()
  end
end

local function BuildTimer()
  if timerFrame then return end
  timerFrame = CreateFrame("Frame", "LFGSuiteQueueTimer", UIParent, "BackdropTemplate")
  timerFrame:SetSize(220, 24)
  timerFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -320, -12)
  timerFrame:SetFrameStrata("HIGH")
  timerFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 12, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  timerFrame.text = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  timerFrame.text:SetPoint("CENTER")
  timerFrame:SetMovable(true)
  timerFrame:EnableMouse(true)
  timerFrame:RegisterForDrag("LeftButton")
  timerFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  timerFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  timerFrame:SetScript("OnUpdate", function()
    -- Cheap throttle: the frame only exists while queued.
    if (GetTime() - (timerFrame._t or 0)) < 0.5 then return end
    timerFrame._t = GetTime()
    UpdateTimer()
  end)
  timerFrame:Hide()
end

local function EvaluateQueue()
  local lfgLabel = EvaluateLFG()
  if lfgLabel then
    if not qStart then qStart = GetTime() end
    qLabel = lfgLabel
  else
    qStart, qLabel = nil, nil
  end
  bgWait, bgLabel = EvaluateBattlefield()
  UpdateTimer()
end

-- Queue-state poller: this client generation has no usable queue-status
-- event (UPDATE_STATUS is not registrable), so probe the queue APIs once a
-- second from an always-alive frame. The probes are pcall pairs - cheap.
local pollFrame
local function EnsurePoller()
  if pollFrame then return end
  pollFrame = CreateFrame("Frame")
  pollFrame:SetScript("OnUpdate", function(self)
    if (GetTime() - (self._t or 0)) < 1 then return end
    self._t = GetTime()
    local ok, err = pcall(EvaluateQueue)
    if not ok and NS.ModuleError then NS.ModuleError({ key = "queue" }, err) end
  end)
end

-- ---------------------------------------------------------------------------
-- Joined-group detection (premade side)
-- ---------------------------------------------------------------------------

local function BannerSubtitle(app)
  local sub = app.name or "?"
  if app.comment and app.comment ~= "" then
    sub = sub .. "\n|cffcccccc" .. Util.Trunc(app.comment, 80) .. "|r"
  end
  if app.leader and app.leader ~= "" then
    sub = sub .. "\n|cffcccccc" .. string.format(l("leader_fmt", "leader: %s"),
      Util.ShortName(app.leader)) .. "|r"
  end
  return sub
end

local function BannerForApplication(resultID)
  local app = NS.AppliedListings and NS.AppliedListings[resultID]
  if app and not app.announced then
    app.announced = true
    NS.ShowBanner(l("banner_joined", "Joined group"), BannerSubtitle(app), app.name)
    return true
  end
  return false
end

local function BannerForRecentApplication()
  -- Group formed but no application-status event: banner the most recent
  -- unannounced application from the last 3 minutes.
  local best, bestT = nil, 0
  for _, app in pairs(NS.AppliedListings or {}) do
    if not app.announced and app.t and (time() - app.t) < 180 and app.t > bestT then
      best, bestT = app, app.t
    end
  end
  if best then
    best.announced = true
    NS.ShowBanner(l("banner_joined", "Joined group"), BannerSubtitle(best), best.name)
  end
end

-- ---------------------------------------------------------------------------
-- Role-check popup QoL: pre-tick remembered roles (captured by the Browser
-- module on every signup) when the LFD role-check dialog opens. Field names
-- probed defensively - a Blizzard rename means "no pre-tick", never an error.
-- ---------------------------------------------------------------------------

local roleCheckHooked = false
local function InitRoleCheckHook()
  if roleCheckHooked then return end
  if type(LFDRoleCheckPopup) ~= "table" or type(LFDRoleCheckPopup.HookScript) ~= "function" then return end
  local ok = pcall(LFDRoleCheckPopup.HookScript, LFDRoleCheckPopup, "OnShow", function(self)
    pcall(function()
      local bdb = NS.db and NS.db.browser
      local roles = (bdb and bdb.rememberRoles ~= false) and bdb.roles or nil
      if not roles or not (roles.tank or roles.healer or roles.dps) then return end
      local boxes = {
        { self.RoleCheckButton1 and self.RoleCheckButton1.checkButton, roles.tank },
        { self.RoleCheckButton2 and self.RoleCheckButton2.checkButton, roles.healer },
        { self.RoleCheckButton3 and self.RoleCheckButton3.checkButton, roles.dps },
      }
      for _, s in ipairs(boxes) do
        if s[1] and s[1].SetChecked then s[1]:SetChecked(s[2] and true or false) end
      end
    end)
  end)
  if ok then roleCheckHooked = true end
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {
  key = "queue",
  label = "Queue & Pop",
  desc = "Queue timer, pop sound/flash, joined-group banner, auto-accept (off)",
  phase = 1,
  status = "alpha",
  defaultEnabled = true,
  events = {
    "LFG_QUEUE_STATUS_UPDATE", "LFG_PROPOSAL_SHOW", "UPDATE_BATTLEFIELD_STATUS",
    "LFG_LIST_APPLICATION_STATUS_UPDATED", "GROUP_ROSTER_UPDATE",
  },
  OnLoad = function()
    MDB()
    wasInGroup = IsInGroup and IsInGroup() or false
    BuildTimer()
    EnsurePoller()
  end,
  OnEnable = function()
    MDB()
    wasInGroup = IsInGroup and IsInGroup() or false
    BuildTimer()
    EnsurePoller()
    EvaluateQueue()
  end,
  OnDisable = function()
    if timerFrame then timerFrame:Hide() end
    if bannerFrame then bannerFrame:Hide() end
  end,
  OnEvent = function(_, event, ...)
    local arg1 = ...
    InitRoleCheckHook() -- LFD UI is load-on-demand; cheap + idempotent
    if event == "LFG_QUEUE_STATUS_UPDATE" then
      -- The real queue-status event on Midnight (UPDATE_STATUS is gone).
      EvaluateQueue()
    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
      -- Battleground "confirm" = queue popped.
      local ok, status, mapName = pcall(GetBattlefieldStatus, arg1 or 1)
      if ok and status == "confirm" then
        if bgWait then RecordQueueTime("BG", bgWait) end
        QueuePop(l("banner_bg_ready", "Battleground ready"), mapName or "")
      end
      EvaluateQueue()
    elseif event == "LFG_PROPOSAL_SHOW" then
      if qStart and qLabel then RecordQueueTime(qLabel, GetTime() - qStart) end
      local okP, p = pcall(GetLFGProposal)
      local name = (okP and type(p) == "table" and p.name) or nil
      -- Dungeon description for the banner card (LFGGetDungeonInfo shapes
      -- vary; every field probed, missing text just falls back to the name).
      local desc
      if okP and type(p) == "table" and p.id and LFGGetDungeonInfo then
        local okD, di = pcall(LFGGetDungeonInfo, p.id)
        if okD and type(di) == "table" then
          desc = di.description or di.desc or di.shortDescription or di.recap
        end
      end
      local sub = name or l("banner_pop_dungeon", "Your dungeon group is ready")
      if desc and desc ~= "" then
        sub = sub .. "\n|cffcccccc" .. Util.Trunc(desc, 90) .. "|r"
      end
      QueuePop(l("banner_pop", "Queue popped"), sub)
      local db = MDB()
      if db.autoAccept and not (InCombatLockdown and InCombatLockdown()) and AcceptProposal then
        C_Timer.After(1, function() pcall(AcceptProposal) end)
      end
    elseif event == "LFG_LIST_APPLICATION_STATUS_UPDATED" then
      -- (searchResultID, newStatus, oldStatus)
      local newStatus = select(2, ...)
      if newStatus == "inviteaccepted" and arg1 then
        BannerForApplication(arg1)
      end
    elseif event == "GROUP_ROSTER_UPDATE" then
      local inGroup = IsInGroup and IsInGroup() or false
      if inGroup and not wasInGroup then
        BannerForRecentApplication()
      end
      wasInGroup = inGroup
      EvaluateQueue()
    end
  end,
  OnOptions = function(ctx)
    ctx.AddCB(l("opt_popsound", "Play sound when a queue pops"),
      function() return MDB().popSound ~= false end,
      function(v) MDB().popSound = v end)
    ctx.AddCB(l("opt_flash", "Flash taskbar when a queue pops"),
      function() return MDB().flash ~= false end,
      function(v) MDB().flash = v end)
    ctx.AddCB(l("opt_banner", "Show 'what did I queue for' banner"),
      function() return MDB().banner ~= false end,
      function(v) MDB().banner = v end)
    ctx.AddCB(l("opt_destcard", "Show the destination card with the banner (dungeon name + description)"),
      function() return MDB().destCard ~= false end,
      function(v) MDB().destCard = v end)
    ctx.AddCB(l("opt_showtimer", "Show queue timer frame while queued"),
      function() return MDB().showTimer ~= false end,
      function(v) MDB().showTimer = v; UpdateTimer() end)
    ctx.AddCB(l("opt_autoaccept", "Auto-accept queue pops (use with care)"),
      function() return MDB().autoAccept == true end,
      function(v) MDB().autoAccept = v end)
  end,
}
NS.RegisterModule(M)

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.banner = function()
  NS.ShowBanner(l("banner_test", "Banner test"), l("banner_test_sub", "This is how the joined-group banner looks."))
end

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
--       fallback) shows group name/leader; dungeon pops show the dungeon
--   [x] Auto-accept queue pops (DEFAULT OFF)
--   [ ] Estimated queue times from history (BetterBlizzQueue deep stats)
--   [ ] Role popup QoL on the LFD role-select dialog

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
  bannerFrame:SetScript("OnMouseUp", function() bannerFrame:Hide() end)
  bannerFrame:Hide()
end

local bannerTimer
function NS.ShowBanner(title, sub)
  local db = MDB()
  if db.banner == false then return end
  BuildBanner()
  if not bannerFrame then return end
  bannerFrame.title:SetText("|cffffd100" .. tostring(title) .. "|r")
  bannerFrame.sub:SetText(tostring(sub or ""))
  bannerFrame:SetAlpha(1)
  bannerFrame:Show()
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
  NS.ShowBanner(title, sub)
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

local function UpdateTimer()
  if not timerFrame then return end
  local db = MDB()
  local text
  if qStart then
    text = string.format("|cffffd100%s|r %s", l("timer_queue", "Queue:"), FormatElapsed(GetTime() - qStart))
    if qLabel then text = text .. "  |cffcccccc" .. qLabel .. "|r" end
  elseif bgWait then
    text = string.format("|cffffd100%s|r %s", l("timer_bg", "BG queue:"), FormatElapsed(bgWait))
    if bgLabel then text = text .. "  |cffcccccc" .. bgLabel .. "|r" end
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

-- ---------------------------------------------------------------------------
-- Joined-group detection (premade side)
-- ---------------------------------------------------------------------------

local function BannerForApplication(resultID)
  local app = NS.AppliedListings and NS.AppliedListings[resultID]
  if app and not app.announced then
    app.announced = true
    local sub = app.name or "?"
    if app.leader and app.leader ~= "" then
      sub = sub .. "  |cffcccccc" .. string.format(l("leader_fmt", "leader: %s"), Util.ShortName(app.leader)) .. "|r"
    end
    NS.ShowBanner(l("banner_joined", "Joined group"), sub)
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
    local sub = best.name or "?"
    if best.leader and best.leader ~= "" then
      sub = sub .. "  |cffcccccc" .. string.format(l("leader_fmt", "leader: %s"), Util.ShortName(best.leader)) .. "|r"
    end
    NS.ShowBanner(l("banner_joined", "Joined group"), sub)
  end
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
    "UPDATE_STATUS", "LFG_PROPOSAL_SHOW", "UPDATE_BATTLEFIELD_STATUS",
    "LFG_LIST_APPLICATION_STATUS_UPDATED", "GROUP_ROSTER_UPDATE",
  },
  OnLoad = function()
    MDB()
    wasInGroup = IsInGroup and IsInGroup() or false
    BuildTimer()
  end,
  OnEnable = function()
    MDB()
    wasInGroup = IsInGroup and IsInGroup() or false
    BuildTimer()
    EvaluateQueue()
  end,
  OnDisable = function()
    if timerFrame then timerFrame:Hide() end
    if bannerFrame then bannerFrame:Hide() end
  end,
  OnEvent = function(_, event, ...)
    local arg1 = ...
    if event == "UPDATE_STATUS" or event == "UPDATE_BATTLEFIELD_STATUS" then
      -- Battleground "confirm" = queue popped.
      if event == "UPDATE_BATTLEFIELD_STATUS" then
        local ok, status, mapName = pcall(GetBattlefieldStatus, arg1 or 1)
        if ok and status == "confirm" then
          QueuePop(l("banner_bg_ready", "Battleground ready"), mapName or "")
        end
      end
      EvaluateQueue()
    elseif event == "LFG_PROPOSAL_SHOW" then
      local okP, p = pcall(GetLFGProposal)
      local name = (okP and type(p) == "table" and p.name) or nil
      QueuePop(l("banner_pop", "Queue popped"), name or l("banner_pop_dungeon", "Your dungeon group is ready"))
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

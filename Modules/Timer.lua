-- LFG Suite - Modules/Timer.lua
-- PHASE 3. Absorbs: WarpDeplete (MIT - feature-equivalent reimplementation),
-- Mythic Plus Tweaks ("always show affixes").
--
-- Feature checklist:
--   [x] Timer frame: remaining time counting down (overtime counts up, red)
--   [x] +2 / +3 cutoff markers on the progress bar (C_ChallengeMode.GetPowerLevels
--       when available, 60%/100% fallback), colored time state
--   [x] Dungeon name + key level + weekly affixes line (NS.Affixes)
--   [x] Death counter (+5s penalty note; C_ChallengeMode.GetDeathCount)
--   [x] Personal bests per dungeon+level (db.pbs, shared with RunSummary)
--   [x] Movable frame: /lfgs timer unlock|lock, demo: /lfgs timer demo
--   [ ] Objective (boss) par times
--   [ ] Pull count prediction
--   [ ] Full styling options (fonts/textures/layout presets)

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local Util = NS.Util
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

local TIMER_DEFAULTS = {
  locked = true,
  x = nil, y = nil, scale = 1,
  showAffixes = true,
  showDeaths = true,
  showPB = true,
  pbs = {}, -- ["mapID:level"] = { time = bestSeconds, t = stamp }
}

local function MDB() return NS.EnsureModuleDB("timer", TIMER_DEFAULTS) end

-- ---------------------------------------------------------------------------
-- Personal bests (shared store; RunSummary consumes it too)
-- ---------------------------------------------------------------------------

NS.PB = NS.PB or {}

function NS.PB.Get(mapID, level)
  local pbs = MDB().pbs or {}
  return pbs[tostring(mapID) .. ":" .. tostring(level)]
end

function NS.PB.Update(mapID, level, seconds, onTime)
  if not (mapID and level and seconds and onTime) then return nil end
  local db = MDB()
  db.pbs = db.pbs or {}
  local key = tostring(mapID) .. ":" .. tostring(level)
  local prev = db.pbs[key]
  if not prev or seconds < prev.time then
    db.pbs[key] = { time = seconds, t = time() }
    return true, prev and prev.time or nil
  end
  return false, prev.time
end

function NS.PB.Format(seconds)
  if not seconds or seconds <= 0 then return nil end
  return string.format("%d:%05.2f", math.floor(seconds / 60), seconds % 60)
end

-- ---------------------------------------------------------------------------
-- Run state
-- ---------------------------------------------------------------------------

local state = {
  active = false, demo = false,
  mapID = nil, level = nil, name = nil,
  startT = nil, timeLimit = nil, t2 = nil, t3 = nil, -- t2 = timed cutoff, t3 = 3-chest
  deaths = 0,
}

local function ProbeInt(fn, ...)
  if not fn then return nil end
  local ok, v = pcall(fn, ...)
  if ok and type(v) == "number" and v > 0 then return v end
  return nil
end

-- Upgrade-time thresholds: prefer GetPowerLevels, fall back to 60%/100% of limit.
local function ComputeCutoffs(mapID, timeLimit)
  if not timeLimit then return nil, nil end
  if C_ChallengeMode and C_ChallengeMode.GetPowerLevels then
    local ok, levels = pcall(C_ChallengeMode.GetPowerLevels, mapID)
    if ok and type(levels) == "table" and #levels >= 2 then
      local t3, t2 = levels[1], levels[2]
      if type(t3) == "number" and type(t2) == "number" and t2 > t3 and t2 <= timeLimit then
        return t3, t2
      end
    end
  end
  return timeLimit * 0.6, timeLimit
end

local function ReadRunState()
  if not C_ChallengeMode then return end
  state.mapID = ProbeInt(C_ChallengeMode.GetActiveChallengeMapID)
  if not state.mapID then return end
  state.name = Util.GetChallengeMapName(state.mapID)
  if C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
    local ok, _, _, timeLimit = pcall(C_ChallengeMode.GetMapUIInfo, state.mapID)
    if ok and type(timeLimit) == "number" and timeLimit > 0 then
      state.timeLimit = timeLimit
    end
  end
  state.t3, state.t2 = ComputeCutoffs(state.mapID, state.timeLimit)
  -- Key level: probe the keystone info APIs of this client generation.
  state.level = nil
  for _, fn in ipairs({ "GetActiveKeystoneInfo", "GetActiveLevel" }) do
    local f = C_ChallengeMode[fn]
    if type(f) == "function" then
      local ok, lvl = pcall(f)
      if ok and type(lvl) == "number" and lvl > 0 then
        state.level = lvl
        break
      end
    end
  end
  state.deaths = ProbeInt(C_ChallengeMode.GetDeathCount) or 0
end

local function BeginRun()
  ReadRunState()
  if not state.mapID then return end
  state.active = true
  state.startT = GetTime()
  NS.Affixes.Refresh()
  NS.RefreshTimerUI()
end

local function EndRun()
  state.active = false
  state.demo = false
  NS.RefreshTimerUI()
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local frame

local function FmtRemaining(secs)
  secs = math.max(0, secs)
  return string.format("%d:%02d", math.floor(secs / 60), math.floor(secs % 60))
end

local function TimeColor(fraction)
  -- fraction = remaining / limit: green with buffer, yellow tight, red over.
  if fraction >= 0.25 then return 0.2, 1, 0.4 end
  if fraction >= 0.05 then return 1, 0.85, 0.2 end
  return 1, 0.25, 0.25
end

function NS.RefreshTimerUI()
  if not frame then return end
  local db = MDB()
  local inCM = state.active or state.demo
  frame:SetShown(inCM)
  if not inCM then return end

  local title = state.name or "?"
  if state.level then title = "+" .. state.level .. " " .. title end
  frame.title:SetText("|cffffd100" .. title .. "|r")

  local elapsed = state.startT and (GetTime() - state.startT) or 0
  local remaining = state.timeLimit and (state.timeLimit - elapsed) or 0
  local frac = state.timeLimit and (remaining / state.timeLimit) or 0
  if remaining >= 0 then
    local r, g, b = TimeColor(frac)
    frame.time:SetText(string.format("|cff%02x%02x%02x%s|r",
      math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5),
      FmtRemaining(remaining)))
    if state.timeLimit and frame.bar then
      frame.bar:SetValue(math.min(1, elapsed / state.timeLimit))
    end
  else
    frame.time:SetText("|cffff4040" .. l("time_overtime", "+") .. FmtRemaining(-remaining) .. "|r")
    if frame.bar then frame.bar:SetValue(1) end
  end

  local meta = {}
  if db.showDeaths ~= false then
    meta[#meta + 1] = string.format("|cffee6666%s: %d|r", l("deaths", "Deaths"), state.deaths or 0)
  end
  if db.showPB ~= false and state.mapID and state.level then
    local pb = NS.PB.Get(state.mapID, state.level)
    local pbTxt = pb and NS.PB.Format(pb.time) or "-"
    meta[#meta + 1] = "|cffaaaaaa" .. l("pb", "PB") .. ": " .. pbTxt .. "|r"
  end
  frame.meta:SetText(table.concat(meta, "   "))

  if db.showAffixes ~= false then
    local aff = NS.Affixes.Summary()
    frame.affixes:SetText(aff and ("|cffbbbbbb" .. aff .. "|r") or "")
    frame.affixes:Show()
  else
    frame.affixes:Hide()
  end
end

local function BuildUI()
  if frame then return end
  frame = CreateFrame("Frame", "LFGSuiteMPlusTimer", UIParent, "BackdropTemplate")
  frame:SetSize(320, 84)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -220)
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local x, y = self:GetCenter()
    local db = MDB()
    db.x, db.y = x, y
  end)
  frame:SetScript("OnUpdate", function()
    if not (state.active or state.demo) then return end
    if (GetTime() - (frame._t or 0)) < 0.25 then return end
    frame._t = GetTime()
    NS.RefreshTimerUI()
  end)
  frame:Hide()

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.title:SetPoint("TOP", frame, "TOP", 0, -6)

  frame.time = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  frame.time:SetPoint("CENTER", frame, "CENTER", 0, 6)

  frame.bar = CreateFrame("StatusBar", nil, frame, "BackdropTemplate")
  frame.bar:SetSize(300, 10)
  frame.bar:SetPoint("BOTTOM", frame, "BOTTOM", 0, 24)
  frame.bar:SetMinMaxValues(0, 1)
  frame.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  frame.bar:SetStatusBarColor(0.85, 0.68, 0.3)
  if frame.bar.SetBackdrop then
    frame.bar:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
  end
  -- +3 / +2 cutoff markers (60% / 100% fallback positions, rebuilt on refresh).
  frame.markT3 = frame.bar:CreateTexture(nil, "OVERLAY")
  frame.markT3:SetColorTexture(1, 1, 1, 0.8)
  frame.markT3:SetSize(2, 10)
  frame.markT2 = frame.bar:CreateTexture(nil, "OVERLAY")
  frame.markT2:SetColorTexture(1, 1, 1, 0.8)
  frame.markT2:SetSize(2, 10)

  frame.meta = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.meta:SetPoint("BOTTOM", frame, "BOTTOM", 0, 8)

  frame.affixes = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.affixes:SetPoint("BOTTOM", frame, "BOTTOM", 0, -6)
  frame.affixes:SetWidth(310)

  local db = MDB()
  frame:SetScale(db.scale or 1)
  if db.x and db.y then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)
  end
end

local function RepaintMarkers()
  if not (frame and state.timeLimit and state.t2 and state.t3) then return end
  local w = frame.bar:GetWidth() or 300
  frame.markT3:SetPoint("LEFT", frame.bar, "LEFT", (state.t3 / state.timeLimit) * w - 1, 0)
  frame.markT2:SetPoint("LEFT", frame.bar, "LEFT", (state.t2 / state.timeLimit) * w - 1, 0)
  frame.markT2:Show()
  frame.markT3:Show()
end

-- ---------------------------------------------------------------------------
-- Demo mode
-- ---------------------------------------------------------------------------

local function StartDemo()
  state.demo = true
  state.active = false
  state.mapID = state.mapID or 501
  state.name = Util.GetChallengeMapName(state.mapID) or "Demo Dungeon"
  state.level = state.level or 7
  state.timeLimit = 35 * 60
  state.t3, state.t2 = ComputeCutoffs(state.mapID, state.timeLimit)
  state.deaths = 1
  state.startT = GetTime() - (state.timeLimit * 0.45)
  BuildUI()
  RepaintMarkers()
  NS.RefreshTimerUI()
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {
  key = "timer",
  label = "M+ Timer",
  desc = "Run timer with +2/+3 cutoffs, deaths, affixes, personal bests",
  phase = 3,
  status = "alpha",
  defaultEnabled = true,
  events = {
    "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_RESET",
    "CHALLENGE_MODE_DEATH_COUNT_UPDATED", "PLAYER_ENTERING_WORLD",
  },
  OnLoad = function()
    MDB()
    BuildUI()
  end,
  OnEnable = function()
    MDB()
    BuildUI()
  end,
  OnDisable = function()
    state.active = false
    state.demo = false
    if frame then frame:Hide() end
  end,
  OnEvent = function(_, event)
    if event == "CHALLENGE_MODE_START" then
      BeginRun()
      RepaintMarkers()
    elseif event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" then
      -- Keep the final state visible briefly; RunSummary takes over on completion.
      if event == "CHALLENGE_MODE_RESET" then EndRun() end
    elseif event == "CHALLENGE_MODE_DEATH_COUNT_UPDATED" then
      state.deaths = ProbeInt(C_ChallengeMode.GetDeathCount) or (state.deaths or 0)
      NS.RefreshTimerUI()
    elseif event == "PLAYER_ENTERING_WORLD" then
      -- Reload inside an active run: rebuild state from the APIs.
      C_Timer.After(2, function()
        if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
          local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
          if ok and mapID then
            ReadRunState()
            if state.startT == nil and state.timeLimit then
              state.startT = GetTime() -- best effort after reload
            end
            state.active = true
            BuildUI()
            RepaintMarkers()
            NS.RefreshTimerUI()
          end
        end
      end)
    end
  end,
  OnOptions = function(ctx)
    ctx.AddCB(l("opt_t_affixes", "Show weekly affixes on the timer"),
      function() return MDB().showAffixes ~= false end,
      function(v) MDB().showAffixes = v; NS.RefreshTimerUI() end)
    ctx.AddCB(l("opt_t_deaths", "Show death counter"),
      function() return MDB().showDeaths ~= false end,
      function(v) MDB().showDeaths = v; NS.RefreshTimerUI() end)
    ctx.AddCB(l("opt_t_pb", "Show personal best"),
      function() return MDB().showPB ~= false end,
      function(v) MDB().showPB = v; NS.RefreshTimerUI() end)
  end,
}
NS.RegisterModule(M)

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.timer = function(rest)
  if rest == "unlock" then
    MDB().locked = false
    BuildUI()
    frame:SetAlpha(0.6)
    frame:EnableMouse(true)
    NS.Print(l("timer_unlocked", "Timer unlocked - drag it, then /lfgs timer lock."))
  elseif rest == "lock" then
    MDB().locked = true
    if frame then frame:SetAlpha(1) end
    NS.Print(l("timer_locked", "Timer locked."))
  elseif rest == "demo" then
    if state.demo then
      state.demo = false
      NS.RefreshTimerUI()
      NS.Print("Timer demo OFF.")
    else
      StartDemo()
      NS.Print("Timer demo ON (/lfgs timer demo to disable).")
    end
  elseif rest == "reset" then
    EndRun()
  else
    NS.Print("/lfgs timer unlock|lock|demo|reset")
  end
end

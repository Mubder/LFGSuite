-- LFG Suite - Modules/Forces.lua
-- PHASE 3. Absorbs: MythicPlusCount - Midnight (ARR - feature-inspired only).
--
-- Feature checklist:
--   [x] Forces progress bar: total % from the scenario criteria system
--       (SCENARIO_CRITERIA_UPDATE probe - no-op silently if Blizzard moved it),
--       in-pull highlight, gold at 100%
--   [x] Per-mob enemy forces % on unit tooltips (from the teachable DB)
--   [x] Teach mode: /lfgs forces teach <count> with a mob targeted;
--        /lfgs forces mobs lists what you taught for this dungeon
--   [x] Starter data: ships empty; the community teaches it (MPC model).
--        Later releases can bundle a mined table for current-season dungeons.
--   [ ] Per-mob % ON nameplates (Blizzard/Plater/ElvUI/KUI) - tooltip only for now
--   [ ] Pull counter (sum of in-combat mobs)
--
-- DB shape: db.forces.counts[mapID][npcID] = count (whole-percent points).

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

local FORCES_DEFAULTS = {
  locked = true,
  x = nil, y = nil,
  showBar = true,
  showTooltips = true,
  counts = {}, -- [tostring(mapID)] = { [npcID] = count }
}

local function MDB() return NS.EnsureModuleDB("forces", FORCES_DEFAULTS) end

local state = { active = false, mapID = nil, qty = 0, total = nil }

-- ---------------------------------------------------------------------------
-- Live forces % via the scenario criteria system
-- ---------------------------------------------------------------------------

-- C_Scenario shapes differ across clients; probe until one yields a criteria
-- that looks like enemy forces (huge total, not a boss kill).
local function ProbeForcesCriteria()
  if not C_Scenario then return nil, nil end
  local okStep, _, _, numCriteria = pcall(C_Scenario.GetStepInfo)
  if not (okStep and type(numCriteria) == "number" and numCriteria > 0) then return nil, nil end
  for i = 1, numCriteria do
    local okC, criteriaString, criteriaType, completed, quantity, totalQuantity =
      pcall(C_Scenario.GetCriteriaInfo, i)
    if okC and type(totalQuantity) == "number" and totalQuantity >= 100 and totalQuantity <= 600 then
      return quantity or 0, totalQuantity
    end
  end
  return nil, nil
end

local function RefreshForces()
  local qty, total = ProbeForcesCriteria()
  if total then
    state.qty, state.total = qty, total
  end
  NS.RefreshForcesUI()
end

-- ---------------------------------------------------------------------------
-- Per-mob tooltips (teachable DB)
-- ---------------------------------------------------------------------------

local function NpcIDFromGUID(guid)
  if type(guid) ~= "string" then return nil end
  if not guid:find("^Creature-") then return nil end
  local npcID = select(6, strsplit("-", guid))
  return tonumber(npcID)
end

local function MobCount(npcID)
  if not (npcID and state.mapID) then return nil end
  local mapCounts = MDB().counts[tostring(state.mapID)]
  local v = mapCounts and mapCounts[tostring(npcID)]
  return tonumber(v)
end

local tooltipHooked = false

local function InitTooltipHook()
  if tooltipHooked then return end
  if not (TooltipDataProcessor and Enum and Enum.TooltipDataType) then return end
  local ok = pcall(TooltipDataProcessor.AddTooltipPostProcessor, Enum.TooltipDataType.Unit, function(tooltip)
    local db = MDB()
    if db.showTooltips == false or not state.active then return end
    local okU, unit = pcall(tooltip.GetUnit, tooltip)
    if not (okU and unit) then return end
    local guid = UnitGUID(unit)
    local npcID = NpcIDFromGUID(guid)
    local count = npcID and MobCount(npcID)
    if count and count > 0 then
      pcall(tooltip.AddLine, tooltip, string.format("|cffffd100%s: +%d%%|r",
        l("forces_label", "Enemy Forces"), count))
    end
  end)
  tooltipHooked = ok
end

-- ---------------------------------------------------------------------------
-- UI: progress bar
-- ---------------------------------------------------------------------------

local frame

function NS.RefreshForcesUI()
  if not frame then return end
  local db = MDB()
  local show = state.active and db.showBar ~= false and state.total ~= nil
  frame:SetShown(show)
  if not show then return end
  local pct = math.min(100, (state.qty / state.total) * 100)
  frame.bar:SetValue(pct / 100)
  local r, g, b = 0.85, 0.68, 0.3
  if pct >= 100 then
    r, g, b = 0.3, 1, 0.4
  elseif state.inCombat then
    r, g, b = 1, 0.85, 0.2
  end
  frame.bar:SetStatusBarColor(r, g, b)
  frame.text:SetText(string.format("%s: %.1f%%  |cff888888(%d / %d)|r",
    l("forces_label", "Enemy Forces"), pct, state.qty, state.total))
end

local function BuildUI()
  if frame then return end
  frame = CreateFrame("Frame", "LFGSuiteForcesBar", UIParent, "BackdropTemplate")
  frame:SetSize(300, 30)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -300)
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
  frame:Hide()

  frame.bar = CreateFrame("StatusBar", nil, frame, "BackdropTemplate")
  frame.bar:SetPoint("TOP", frame, "TOP", 0, -4)
  frame.bar:SetSize(296, 12)
  frame.bar:SetMinMaxValues(0, 1)
  frame.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  frame.bar:SetStatusBarColor(0.85, 0.68, 0.3)
  if frame.bar.SetBackdrop then
    frame.bar:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
  end

  frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.text:SetPoint("TOP", frame.bar, "BOTTOM", 0, -2)

  local db = MDB()
  if db.x and db.y then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)
  end
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {
  key = "forces",
  label = "Enemy Forces",
  desc = "Forces progress bar + per-mob % on tooltips (teach it: /lfgs forces teach)",
  phase = 3,
  status = "alpha",
  defaultEnabled = true,
  events = {
    "CHALLENGE_MODE_START", "SCENARIO_CRITERIA_UPDATE", "CHALLENGE_MODE_COMPLETED",
    "CHALLENGE_MODE_RESET", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
  },
  OnLoad = function()
    MDB()
    BuildUI()
    InitTooltipHook()
  end,
  OnEnable = function()
    MDB()
    BuildUI()
    InitTooltipHook()
  end,
  OnDisable = function()
    state.active = false
    if frame then frame:Hide() end
  end,
  OnEvent = function(_, event)
    if event == "CHALLENGE_MODE_START" then
      state.active = true
      state.qty, state.total = 0, nil
      if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
        local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
        if ok and mapID then state.mapID = mapID end
      end
      C_Timer.After(1, RefreshForces)
    elseif event == "SCENARIO_CRITERIA_UPDATE" then
      if state.active then RefreshForces() end
    elseif event == "PLAYER_REGEN_DISABLED" then
      state.inCombat = true
      NS.RefreshForcesUI()
    elseif event == "PLAYER_REGEN_ENABLED" then
      state.inCombat = false
      NS.RefreshForcesUI()
    elseif event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" then
      state.active = false
      if frame then frame:Hide() end
    elseif event == "PLAYER_ENTERING_WORLD" then
      C_Timer.After(2, function()
        if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
          local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
          if ok and mapID then
            state.active = true
            state.mapID = mapID
            RefreshForces()
          end
        end
      end)
    end
  end,
  OnOptions = function(ctx)
    ctx.AddCB(l("opt_f_bar", "Show enemy forces progress bar in M+"),
      function() return MDB().showBar ~= false end,
      function(v) MDB().showBar = v; NS.RefreshForcesUI() end)
    ctx.AddCB(l("opt_f_tt", "Show per-mob forces % on tooltips (taught mobs only)"),
      function() return MDB().showTooltips ~= false end,
      function(v) MDB().showTooltips = v end)
  end,
}
NS.RegisterModule(M)

-- ---------------------------------------------------------------------------
-- Teach / inspect slash
-- ---------------------------------------------------------------------------

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.forces = function(rest)
  local cmd, arg = rest:match("^(%S*)%s*(.-)$")
  if cmd == "teach" then
    if not state.mapID then
      NS.Print(l("teach_nomap", "Start a Mythic+ dungeon first (need the dungeon context)."))
      return
    end
    local guid = UnitGUID("target")
    local npcID = NpcIDFromGUID(guid)
    if not npcID then
      NS.Print(l("teach_notarget", "Target the mob first, then: /lfgs forces teach <count>"))
      return
    end
    local count = tonumber(arg)
    if not count or count <= 0 or count > 30 then
      NS.Print(l("teach_badcount", "Give a count between 1 and 30, e.g. /lfgs forces teach 8"))
      return
    end
    local db = MDB()
    local key = tostring(state.mapID)
    db.counts[key] = db.counts[key] or {}
    db.counts[key][tostring(npcID)] = count
    local name = UnitName("target") or "?"
    NS.Print(string.format(l("teach_done_fmt", "Taught %s (npc %d) = +%d%% for this dungeon."),
      tostring(name), npcID, count))
  elseif cmd == "mobs" then
    if not state.mapID then
      NS.Print(l("teach_nomap", "Start a Mythic+ dungeon first (need the dungeon context)."))
      return
    end
    local mapCounts = MDB().counts[tostring(state.mapID)] or {}
    local n = 0
    for _ in pairs(mapCounts) do n = n + 1 end
    NS.Print(string.format(l("mobs_list_fmt", "Taught mobs for this dungeon: %d (see tooltip: hover a mob)"), n))
    for npcID, count in pairs(mapCounts) do
      print(string.format("   npc %s: +%d%%", tostring(npcID), count))
    end
  elseif cmd == "reset" then
    if state.mapID then
      MDB().counts[tostring(state.mapID)] = {}
      NS.Print("Taught data for this dungeon cleared.")
    end
  else
    NS.Print("/lfgs forces teach <count> - teach the targeted mob's forces value")
    NS.Print("/lfgs forces mobs - list taught mobs for this dungeon")
    NS.Print("/lfgs forces reset - clear taught data for this dungeon")
  end
end

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
--   [x] Borderless panel (text on shadow, no backdrop/border), /lfgs timer scale
--   [x] Stats row: elapsed / personal best / timer limit
--   [x] Pace row: "+3 in X" / next-boss par / "+2 in Y" (grays out when missed)
--   [x] Boss rows: name + killed <timestamp> / not done (scenario probe)
--   [x] Deaths: total (+5s each) + per-player grid (names in class colors,
--       counts beneath) tracked via combat-log UNIT_DIED
--   [ ] Pull count prediction (needs the Forces module's teachable data)
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
  objTotal = nil, objDone = nil, -- boss criteria (scenario probe)
  objs = nil, -- [{ name, done, killT }] from the scenario probe; killT = elapsed secs
}

local runSerial = 0 -- identifies the current run; lets the post-completion
                    -- hide timer tell "same run still idling" from "new run"

-- Per-player death tracking (session scope). The total stays authoritative
-- via C_ChallengeMode.GetDeathCount; this grid is rebuilt each run.
local partyRoster = {} -- [{ name = shortName, class = classFileName }]
local pdeaths = {}     -- [shortName] = count

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

local function BuildPartyRoster()
  wipe(partyRoster)
  wipe(pdeaths)
  local n = GetNumGroupMembers and GetNumGroupMembers() or 0
  n = math.min(tonumber(n) or 0, 5) -- M+ party
  if n == 0 then
    local _, class = UnitClass("player")
    partyRoster[1] = { name = UnitName("player") or "?", class = class }
    return
  end
  for i = 1, n do
    local okN, name, _, _, _, _, class = pcall(GetRaidRosterInfo, i)
    if okN and name then
      partyRoster[#partyRoster + 1] = { name = Util.ShortName(name), class = class }
    end
  end
end

-- Combat-log death attribution: count UNIT_DIED events whose victim is a
-- player. Names are matched loosely (short name) - realm edges don't matter
-- inside an M+ party.
local function TrackDeathCLEU()
  if not state.active then return end
  if not CombatLogGetCurrentEventInfo then return end
  local ok, _, subevent, _, _, _, _, _, destGUID, destName =
    pcall(CombatLogGetCurrentEventInfo)
  if not ok or subevent ~= "UNIT_DIED" then return end
  if not (type(destGUID) == "string" and destGUID:find("^Player-")) then return end
  local short = type(destName) == "string" and Util.ShortName(destName) or nil
  if not short then return end
  pdeaths[short] = (pdeaths[short] or 0) + 1
  NS.RefreshTimerUI()
end

-- Boss objective count/progress via the scenario criteria system. Boss
-- criteria have totalQuantity 1 (enemy-forces criteria are the huge totals -
-- see the Forces module's probe). Shape differences across clients are
-- absorbed by the pcall pairs + sane-range check.
local function ProbeObjectives()
  if not (C_Scenario and C_Scenario.GetStepInfo and C_Scenario.GetCriteriaInfo) then return end
  local okS, _, _, numCriteria = pcall(C_Scenario.GetStepInfo)
  if not (okS and type(numCriteria) == "number" and numCriteria > 0) then return end
  local objs, done = {}, 0
  for i = 1, math.min(numCriteria, 64) do
    local okC, criteriaString, _, completed, _, totalQty = pcall(C_Scenario.GetCriteriaInfo, i)
    if okC and type(totalQty) == "number" and totalQty == 1
      and type(criteriaString) == "string" and criteriaString ~= "" then
      objs[#objs + 1] = { name = criteriaString, done = completed == true, killT = nil }
      if completed == true then done = done + 1 end
    end
  end
  if #objs == 0 or #objs > 12 then return end
  -- Carry kill stamps from the previous probe; stamp newly-killed bosses now.
  local elapsed = state.startT and (GetTime() - state.startT) or nil
  for idx, o in ipairs(objs) do
    local prev = state.objs and state.objs[idx] or nil
    if prev then
      o.killT = prev.killT
      if o.done and not prev.done and elapsed then o.killT = elapsed end
    elseif o.done and elapsed then
      o.killT = elapsed -- first probe saw it already dead (mid-run reload)
    end
  end
  state.objs = objs
  state.objTotal, state.objDone = #objs, done
end

local function BeginRun()
  ReadRunState()
  if not state.mapID then return end
  state.active = true
  state.demo = false
  state.objTotal, state.objDone, state.objs = nil, nil, nil
  BuildPartyRoster()
  runSerial = runSerial + 1
  state.startT = GetTime()
  NS.Affixes.Refresh()
  ProbeObjectives() -- bosses may already be listed; refreshed on criteria events
  NS.RefreshTimerUI()
end

local function EndRun()
  state.active = false
  state.demo = false
  state.objTotal, state.objDone = nil, nil
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

-- Bar fill by pace: chasing +3 (cyan), +2 (green), timer (gold), overtime
-- (red + flash via the theme bar's pulse).
local function BarColor(elapsed)
  if state.t3 and elapsed < state.t3 then return 0.26, 0.85, 1 end
  if state.t2 and elapsed < state.t2 then return 0.3, 0.95, 0.45 end
  if state.timeLimit and elapsed < state.timeLimit then return 0.98, 0.75, 0.25 end
  return 1, 0.25, 0.25
end

-- Layout is TOP-anchored with fixed Y offsets; the deaths block repositions
-- under however many boss rows are shown, and the frame height follows.
-- Y_TITLE sits inside the theme's 24px header strip (the grab affordance).
local Y_TITLE, Y_TIME, Y_STATS, Y_BAR, Y_PACE, Y_FORCES, Y_BOSSES = 6, 26, 52, 66, 84, 100, 118
local BOSS_ROW_H, MAX_BOSS_ROWS, GRID_COLS = 14, 8, 5
local FRAME_W, MARGIN, COL_W = 340, 10, 64

local function Place(fs, x, y)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
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
  else
    frame.time:SetText("|cffff4040" .. l("time_overtime", "+") .. FmtRemaining(-remaining) .. "|r")
  end
  if frame.bar and state.timeLimit then
    frame.bar:Set(math.min(1, elapsed / state.timeLimit), BarColor(elapsed))
    frame.bar:SetPulse(remaining < 0)
  end

  -- Stats row: elapsed left, personal best center, timer limit right.
  frame.elapsed:SetText("|cffffffff" .. FmtRemaining(elapsed) .. "|r |cff888888"
    .. l("elapsed", "elapsed") .. "|r")
  frame.limit:SetText("|cff888888" .. l("max", "max") .. "|r |cffffffff"
    .. FmtRemaining(state.timeLimit or 0) .. "|r")
  if db.showPB ~= false and state.mapID and state.level then
    local pb = NS.PB.Get(state.mapID, state.level)
    frame.pb:SetText("|cffaaaaaa" .. l("pb", "PB") .. " "
      .. (pb and NS.PB.Format(pb.time) or "-") .. "|r")
    frame.pb:Show()
  else
    frame.pb:Hide()
  end

  -- Pace row: +3 left, next-boss par center, +2 right. Each grays out when
  -- missed; par is a proportional split of the timer across bosses until
  -- per-dungeon data exists.
  if state.t3 then
    local left = state.t3 - elapsed
    frame.plus3:SetText((left >= 0)
      and ("|cff43d9ff" .. string.format(l("in_fmt", "+%s in %s"), "3", FmtRemaining(left)) .. "|r")
      or ("|cff777777" .. string.format(l("missed_fmt", "+%s --"), "3") .. "|r"))
  end
  if state.t2 then
    local left = state.t2 - elapsed
    frame.plus2:SetText((left >= 0)
      and ("|cff43ff43" .. string.format(l("in_fmt", "+%s in %s"), "2", FmtRemaining(left)) .. "|r")
      or ("|cff777777" .. string.format(l("missed_fmt", "+%s --"), "2") .. "|r"))
  end
  if state.objTotal and state.objTotal > 0 then
    local nextN = math.min((state.objDone or 0) + 1, state.objTotal)
    local par = state.timeLimit * (nextN / state.objTotal)
    local col = (elapsed <= par) and "|cff43d9ff" or "|cff777777"
    frame.bossPar:SetText(col
      .. string.format(l("boss_par_fmt", "Boss %d/%d par %s"), nextN, state.objTotal,
        FmtRemaining(par)) .. "|r")
  else
    frame.bossPar:SetText("")
  end

  -- Forces % (live from the Forces module): current + what remains to pull.
  local fi = NS.ForcesInfo and NS.ForcesInfo()
  if fi then
    Place(frame.forces, 0, Y_FORCES)
    frame.forces:SetText(string.format("%s |cffffd100%.1f%%|r  |cff888888- %.1f%% %s|r",
      l("forces_label", "Enemy Forces"), fi.pct, fi.remains, l("remains", "remains")))
    frame.forces:Show()
  else
    frame.forces:Hide()
  end

  -- Boss rows: name left, status right (kill stamp when we saw it happen).
  local shown = 0
  for i = 1, MAX_BOSS_ROWS do
    local row = frame.bossRows[i]
    local o = state.objs and state.objs[i] or nil
    if o then
      shown = i
      if o.done then
        local stamp = o.killT and (" " .. FmtRemaining(o.killT)) or ""
        row.name:SetText("|cff43ff43" .. o.name .. "|r")
        row.status:SetText("|cff43ff43" .. l("killed", "killed") .. stamp .. "|r")
      else
        row.name:SetText("|cffffffff" .. o.name .. "|r")
        row.status:SetText("|cff777777" .. l("not_done", "not done") .. "|r")
      end
      row.name:Show()
      row.status:Show()
    else
      row.name:Hide()
      row.status:Hide()
    end
  end

  -- Deaths block: total + penalty line, then the per-player grid (names in
  -- class colors, one per column; each player's death count right beneath).
  local deathsY = Y_BOSSES + shown * BOSS_ROW_H + 6
  local showDeaths = db.showDeaths ~= false
  local lastY = deathsY
  if showDeaths then
    local total = state.deaths or 0
    if total == 0 then
      for _, c in pairs(pdeaths) do total = total + c end
    end
    Place(frame.deaths, 0, deathsY)
    frame.deaths:SetText(string.format("%s |cffee6666%d|r |cff999999(+%ds)|r",
      l("deaths", "Deaths"), total, total * 5))
    frame.deaths:Show()
    lastY = deathsY + 16
    local cols = math.min(#partyRoster, GRID_COLS)
    for i = 1, GRID_COLS do
      local mName, mCount = frame.gridNames[i], frame.gridCounts[i]
      local m = partyRoster[i]
      if m and i <= cols then
        mName:SetText(Util.ClassColorize(m.class, Util.Trunc(m.name, 8)))
        local n = pdeaths[m.name] or 0
        mCount:SetText(n > 0 and ("|cffee6666×" .. n .. "|r") or "|cff7777770|r")
        Place(mName, MARGIN + (i - 1) * COL_W, lastY)
        Place(mCount, MARGIN + (i - 1) * COL_W, lastY + 13)
        mName:Show()
        mCount:Show()
      else
        mName:Hide()
        mCount:Hide()
      end
    end
    lastY = lastY + 28
  else
    frame.deaths:Hide()
    for i = 1, GRID_COLS do
      frame.gridNames[i]:Hide()
      frame.gridCounts[i]:Hide()
    end
  end

  if db.showAffixes ~= false then
    local aff = NS.Affixes.Summary()
    Place(frame.affixes, 0, lastY)
    frame.affixes:SetText(aff and ("|cffbbbbbb" .. aff .. "|r") or "")
    frame.affixes:Show()
    lastY = lastY + 14
  else
    frame.affixes:Hide()
  end
  frame:SetHeight(lastY + 8)
end

-- Lock is a visual cue now: dragging lives in the theme's header strip
-- (always available); unlock simply highlights the strip for a moment.
local function ApplyLock()
  if not frame then return end
  local t = frame._lfgsTheme
  if not t then return end
  local unlocked = MDB().locked == false
  t.accent:SetAlpha(unlocked and 1 or 0.55)
  t.header:SetAlpha(unlocked and 1 or 0.8)
end

local function BuildUI()
  if frame then return end
  frame = CreateFrame("Frame", "LFGSuiteMPlusTimer", UIParent)
  frame:SetSize(FRAME_W, 180)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -200)
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:EnableMouse(false) -- body stays click-through; drag via header strip
  frame:SetScript("OnUpdate", function()
    if not (state.active or state.demo) then return end
    if (GetTime() - (frame._t or 0)) < 0.25 then return end
    frame._t = GetTime()
    NS.RefreshTimerUI()
  end)
  frame:Hide()

  -- Shared theme: transparent block background + always-draggable header.
  if NS.Theme and NS.Theme.Apply then
    NS.Theme.Apply(frame, function(f)
      local x, y = f:GetCenter()
      local db = MDB()
      db.x, db.y = x, y
    end)
  end

  -- Borderless design: text floats on a soft shadow instead of a panel.
  local function FS(template)
    local fs = frame:CreateFontString(nil, "OVERLAY", template)
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    return fs
  end

  frame.title = FS("GameFontNormalSmall")
  Place(frame.title, 0, Y_TITLE)
  frame.title:SetWidth(FRAME_W)
  frame.title:SetJustifyH("CENTER")

  frame.time = FS("GameFontNormalLarge")
  Place(frame.time, 0, Y_TIME)
  frame.time:SetWidth(FRAME_W)
  frame.time:SetJustifyH("CENTER")

  frame.elapsed = FS("GameFontHighlightSmall")
  Place(frame.elapsed, MARGIN, Y_STATS)
  frame.elapsed:SetJustifyH("LEFT")

  frame.pb = FS("GameFontHighlightSmall")
  Place(frame.pb, 0, Y_STATS)
  frame.pb:SetWidth(FRAME_W)
  frame.pb:SetJustifyH("CENTER")

  frame.limit = FS("GameFontHighlightSmall")
  Place(frame.limit, FRAME_W - MARGIN - 90, Y_STATS)
  frame.limit:SetJustifyH("RIGHT")

  -- Progress bar: theme bar (gradient fill colored by pace, flash on
  -- overtime) + cutoff tick marks.
  frame.bar = NS.Theme and NS.Theme.CreateBar
    and NS.Theme.CreateBar(frame, FRAME_W - MARGIN * 2, 12) or nil
  if frame.bar then
    frame.bar:SetPoint("TOPLEFT", frame, "TOPLEFT", MARGIN, -Y_BAR)
  end
  if frame.bar then
    frame.markT3 = frame.bar:CreateTexture(nil, "OVERLAY")
    frame.markT3:SetColorTexture(1, 1, 1, 0.8)
    frame.markT3:SetSize(2, 12)
    frame.markT2 = frame.bar:CreateTexture(nil, "OVERLAY")
    frame.markT2:SetColorTexture(1, 1, 1, 0.8)
    frame.markT2:SetSize(2, 12)
  end

  frame.plus3 = FS("GameFontHighlightSmall")
  Place(frame.plus3, MARGIN, Y_PACE)
  frame.plus3:SetJustifyH("LEFT")

  frame.bossPar = FS("GameFontHighlightSmall")
  Place(frame.bossPar, 0, Y_PACE)
  frame.bossPar:SetWidth(FRAME_W)
  frame.bossPar:SetJustifyH("CENTER")

  frame.plus2 = FS("GameFontHighlightSmall")
  Place(frame.plus2, FRAME_W - MARGIN - 90, Y_PACE)
  frame.plus2:SetJustifyH("RIGHT")

  -- Enemy forces % (fed by the Forces module once a run is live).
  frame.forces = FS("GameFontHighlightSmall")
  Place(frame.forces, 0, Y_FORCES)
  frame.forces:SetWidth(FRAME_W)
  frame.forces:SetJustifyH("CENTER")

  frame.bossRows = {}
  for i = 1, MAX_BOSS_ROWS do
    local y = Y_BOSSES + (i - 1) * BOSS_ROW_H
    local row = {}
    row.name = FS("GameFontHighlightSmall")
    Place(row.name, MARGIN, y)
    row.name:SetJustifyH("LEFT")
    row.status = FS("GameFontHighlightSmall")
    Place(row.status, FRAME_W - MARGIN - 110, y)
    row.status:SetWidth(110)
    row.status:SetJustifyH("RIGHT")
    frame.bossRows[i] = row
  end

  frame.deaths = FS("GameFontHighlightSmall")
  frame.deaths:SetWidth(FRAME_W)
  frame.deaths:SetJustifyH("CENTER")

  frame.gridNames, frame.gridCounts = {}, {}
  for i = 1, GRID_COLS do
    local mName = FS("GameFontHighlightSmall")
    mName:SetWidth(COL_W)
    mName:SetJustifyH("CENTER")
    local mCount = FS("GameFontHighlightSmall")
    mCount:SetWidth(COL_W)
    mCount:SetJustifyH("CENTER")
    frame.gridNames[i] = mName
    frame.gridCounts[i] = mCount
  end

  frame.affixes = FS("GameFontHighlightSmall")
  frame.affixes:SetWidth(FRAME_W)
  frame.affixes:SetJustifyH("CENTER")

  local db = MDB()
  frame:SetScale(db.scale or 1)
  if db.x and db.y then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)
  end
  ApplyLock()
end

local function RepaintMarkers()
  if not (frame and frame.bar and frame.markT3 and state.timeLimit and state.t2 and state.t3) then return end
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
  state.name = "Demo Dungeon"
  state.level = state.level or 7
  state.timeLimit = 35 * 60
  state.t3, state.t2 = ComputeCutoffs(state.mapID, state.timeLimit)
  state.startT = GetTime() - (state.timeLimit * 0.45)
  -- Fabricated boss progress (2/5 killed, stamps within the 15:45 elapsed).
  state.objs = {
    { name = "Test Boss Name 1", done = true, killT = 420 },
    { name = "Test Boss Name 2", done = true, killT = 840 },
    { name = "Test Boss Name 3", done = false, killT = nil },
    { name = "Test Boss Name 4", done = false, killT = nil },
    { name = "Test Boss Name 5", done = false, killT = nil },
  }
  state.objTotal, state.objDone = #state.objs, 2
  -- Fabricated party + per-player deaths (matches the image-2 style demo).
  local _, myClass = UnitClass("player")
  wipe(partyRoster)
  wipe(pdeaths)
  partyRoster[1] = { name = UnitName("player") or "You", class = myClass }
  partyRoster[2] = { name = "Alerion", class = "MAGE" }
  partyRoster[3] = { name = "Hearse", class = "WARRIOR" }
  partyRoster[4] = { name = "Dionis", class = "PRIEST" }
  partyRoster[5] = { name = "Frifti", class = "DRUID" }
  pdeaths["Alerion"] = 2
  pdeaths["Hearse"] = 1
  pdeaths["Dionis"] = 1
  state.deaths = 4
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
    "CHALLENGE_MODE_DEATH_COUNT_UPDATED", "SCENARIO_CRITERIA_UPDATE",
    "COMBAT_LOG_EVENT_UNTRUSTED", "PLAYER_ENTERING_WORLD",
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
    elseif event == "CHALLENGE_MODE_COMPLETED" then
      -- Keep the final state visible while the Run Summary shows; then hide
      -- unless a new run started in the meantime (runSerial detects that).
      local serial = runSerial
      C_Timer.After(10, function()
        if runSerial == serial then EndRun() end
      end)
    elseif event == "CHALLENGE_MODE_RESET" then
      EndRun()
    elseif event == "CHALLENGE_MODE_DEATH_COUNT_UPDATED" then
      state.deaths = ProbeInt(C_ChallengeMode.GetDeathCount) or (state.deaths or 0)
      NS.RefreshTimerUI()
    elseif event == "SCENARIO_CRITERIA_UPDATE" then
      if state.active then
        ProbeObjectives()
        NS.RefreshTimerUI()
      end
    elseif event == "COMBAT_LOG_EVENT_UNTRUSTED" then
      TrackDeathCLEU()
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
            return
          end
        end
        -- Zoned out of the dungeon with the timer still up: take it down.
        if state.active then EndRun() end
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
    ApplyLock()
    NS.Print(l("timer_unlocked", "Header strip highlighted - drag the timer by its header (always draggable)."))
  elseif rest == "lock" then
    MDB().locked = true
    ApplyLock()
    NS.Print(l("timer_locked", "Timer locked (header stays draggable)."))
  elseif rest:match("^scale") then
    local v = tonumber(rest:match("^scale%s+(%S+)$"))
    if v and v >= 0.5 and v <= 2 then
      local db = MDB()
      db.scale = v
      if frame then frame:SetScale(v) end
      NS.Print(string.format(l("timer_scale_fmt", "Timer scale set to %.2f."), v))
    else
      NS.Print(l("timer_scale_usage", "Usage: /lfgs timer scale <0.5-2>"))
    end
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
    NS.Print("/lfgs timer unlock|lock|scale <0.5-2>|demo|reset")
  end
end

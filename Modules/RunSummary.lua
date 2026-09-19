-- LFG Suite - Modules/RunSummary.lua
-- PHASE 3. Absorbs: Details! Damage Meter Mythic+ (lightweight replacement,
-- no Details dependency; no damage meters by design).
--
-- Feature checklist:
--   [x] End-of-run panel: dungeon + level, final time vs +2/+3 cutoffs,
--       upgrade result, deaths (+5s penalty note)
--   [x] M+ rating change when Blizzard reports it (old -> new overall score)
--   [x] Personal best comparison + new-PB flag (NS.PB store from Timer)
--   [x] Party roster line (names, class colors, roles)
--   [x] Auto-show once, dismiss by click, /lfgs summary reopens while the
--       data lasts; NO damage/healing breakdown (Details' job)
--   [ ] Forces completion time + timeline (needs Forces history tracking)

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local Util = NS.Util
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

local SUMMARY_DEFAULTS = {
  autoShow = true,
  hideAfter = 45,
}

local function MDB() return NS.EnsureModuleDB("runsummary", SUMMARY_DEFAULTS) end

local lastRun -- session: the last completion snapshot for /lfgs summary
local frame
local sawStart = false -- true once CHALLENGE_MODE_START fired this session

-- ---------------------------------------------------------------------------
-- Completion info probe: the API name/shape differs across client
-- generations, so try both and every plausible field name.
-- ---------------------------------------------------------------------------

local function ReadCompletionInfo()
  if not C_ChallengeMode then return nil end
  local info
  for _, fn in ipairs({ "GetChallengeCompletionInfo", "GetCompletionInfo" }) do
    local f = C_ChallengeMode[fn]
    if type(f) == "function" then
      local ok, res = pcall(f)
      if ok and type(res) == "table" then
        info = res
        break
      end
    end
  end
  if type(info) ~= "table" then return nil end
  local mapID = info.mapChallengeModeID or info.mapID or info.challengeMapID
  local level = info.level or info.keystoneLevel
  local timeSec = info.time
  -- Reject stale/empty structs: Blizzard can return a zeroed table when no
  -- run just finished (this produced the "? +0 DEPLETED / Time: -" popup).
  -- Types alone are not enough; values must be sane.
  if not (type(mapID) == "number" and mapID > 0
    and type(level) == "number" and level >= 2
    and type(timeSec) == "number" and timeSec > 0) then
    return nil
  end
  local mapName = Util.GetChallengeMapName(mapID) or "?"
  local timeLimit
  if C_ChallengeMode.GetMapUIInfo then
    local ok, _, _, tl = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
    if ok and type(tl) == "number" and tl > 0 then timeLimit = tl end
  end
  local deaths = 0
  if C_ChallengeMode.GetDeathCount then
    local okD, d = pcall(C_ChallengeMode.GetDeathCount)
    if okD and type(d) == "number" and d >= 0 then deaths = math.floor(d) end
  end
  return {
    mapID = mapID, level = level, time = timeSec,
    onTime = info.onTime == true,
    upgrade = type(info.keystoneUpgradeLevels) == "number" and info.keystoneUpgradeLevels or 0,
    practice = info.practiceRun == true,
    oldScore = type(info.oldOverallDungeonScore) == "number" and info.oldOverallDungeonScore or nil,
    newScore = type(info.newOverallDungeonScore) == "number" and info.newOverallDungeonScore or nil,
    mapName = mapName, timeLimit = timeLimit,
    deaths = deaths,
  }
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

local function FmtTime(secs)
  if not secs or secs <= 0 then return "-" end
  return string.format("%d:%05.2f", math.floor(secs / 60), secs % 60)
end

local function PartyLine()
  if not (IsInGroup and IsInGroup()) then
    return Util.ClassColorize(select(2, UnitClass("player")), UnitName("player") or "?")
  end
  local parts = {}
  local n = GetNumGroupMembers and GetNumGroupMembers() or 1
  for i = 1, n do
    local name, _, _, _, _, classFileName = GetRaidRosterInfo(i)
    if name then
      local short = Util.ShortName(name)
      parts[#parts + 1] = Util.ClassColorize(classFileName, short)
    end
  end
  if #parts == 0 then
    parts[1] = Util.ClassColorize(select(2, UnitClass("player")), UnitName("player") or "?")
  end
  return table.concat(parts, "  ")
end

local hideTimer

local function ShowPanel(run)
  local db = MDB()
  if not db.autoShow and not run.forceShow then return end
  if not frame then
    frame = CreateFrame("Frame", "LFGSuiteSummary", UIParent, "BackdropTemplate")
    frame:SetSize(460, 210)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -170)
    frame:SetFrameStrata("HIGH")
    frame:EnableMouse(true)
    frame:SetScript("OnMouseUp", function() frame:Hide() end)
    frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    frame:SetBackdropColor(0.04, 0.06, 0.12, 0.96)
    frame:SetBackdropBorderColor(0.85, 0.68, 0.3, 1)
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -14)
    frame.result = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.result:SetPoint("TOP", frame.title, "BOTTOM", 0, -8)
    frame.details = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.details:SetPoint("TOP", frame.result, "BOTTOM", 0, -10)
    frame.details:SetWidth(420)
    frame.party = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.party:SetPoint("BOTTOM", frame, "BOTTOM", 0, 16)
    frame.party:SetWidth(420)
    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.hint:SetPoint("BOTTOM", frame, "BOTTOM", 0, 2)
    frame.hint:SetTextColor(0.5, 0.5, 0.5)
    frame.hint:SetText(l("sum_hint", "Click to close  •  /lfgs summary to reopen"))
    frame:Hide()
  end

  frame.title:SetText(string.format("|cffffd100%s +%d|r", run.mapName, run.level))

  local resultTxt, r, g, b
  if run.practice then
    resultTxt, r, g, b = l("sum_practice", "PRACTICE RUN"), 0.7, 0.7, 0.7
  elseif run.onTime then
    resultTxt = string.format(l("sum_timed_fmt", "TIMED  +%d"), run.upgrade > 0 and run.upgrade or 1)
    r, g, b = 0.2, 1, 0.4
  else
    resultTxt, r, g, b = l("sum_depleted", "DEPLETED"), 1, 0.3, 0.3
  end
  frame.result:SetText(resultTxt)
  frame.result:SetTextColor(r, g, b)

  local lines = {}
  lines[#lines + 1] = string.format("%s: |cffffffff%s|r", l("sum_time", "Time"), FmtTime(run.time))
  if run.timeLimit then
    lines[#lines + 1] = string.format("   |cff999999(+2 %s / +3 %s)|r",
      FmtTime(run.timeLimit), FmtTime(run.timeLimit * 0.6))
  end
  if run.deaths and run.deaths > 0 then
    lines[#lines + 1] = string.format("   %s: |cffee6666%d|r (|cff999999-5s each|r)",
      l("deaths", "Deaths"), run.deaths)
  end
  if run.oldScore and run.newScore and run.newScore > run.oldScore then
    lines[#lines + 1] = string.format("%s: |cff55ff55%d → %d (+%d)|r", l("sum_rating", "Rating"),
      run.oldScore, run.newScore, run.newScore - run.oldScore)
  end
  local pb = NS.PB.Get(run.mapID, run.level)
  local isPB, updated = NS.PB.Update(run.mapID, run.level, run.time, run.onTime and not run.practice)
  if pb and pb.time then
    local delta = run.time - pb.time
    local deltaTxt = (delta <= 0) and string.format("|cff55ff55-%s|r", FmtTime(-delta))
      or string.format("|cffff6666+%s|r", FmtTime(delta))
    lines[#lines + 1] = string.format("%s: %s %s", l("pb", "PB"), NS.PB.Format(pb.time), deltaTxt)
  end
  if isPB then
    lines[#lines + 1] = "|cffffd100★ " .. l("sum_newpb", "NEW PERSONAL BEST") .. "|r"
  elseif updated then
    lines[#lines + 1] = string.format("   |cff999999(best was %s)|r", NS.PB.Format(updated))
  end
  frame.details:SetText(table.concat(lines, "\n"))
  frame.party:SetText(PartyLine())

  frame:SetAlpha(1)
  frame:Show()
  if hideTimer then hideTimer:Cancel() end
  hideTimer = C_Timer.NewTimer(MDB().hideAfter or 45, function()
    if frame and frame:IsShown() then frame:Hide() end
  end)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {
  key = "runsummary",
  label = "Run Summary",
  desc = "End-of-run panel: time, upgrade result, rating, deaths, personal best",
  phase = 3,
  status = "alpha",
  defaultEnabled = true,
  events = { "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_RESET", "PLAYER_ENTERING_WORLD" },
  OnLoad = function() MDB() end,
  OnEnable = function() MDB() end,
  OnDisable = function()
    if frame then frame:Hide() end
  end,
  OnEvent = function(_, event)
    if event == "CHALLENGE_MODE_START" then
      sawStart = true
      return
    elseif event == "CHALLENGE_MODE_RESET" then
      sawStart = false
      return
    elseif event == "PLAYER_ENTERING_WORLD" then
      -- Reload inside an active run: re-arm so the legit completion still
      -- shows. Otherwise a stale COMPLETED keeps us disarmed (no popup).
      C_Timer.After(2, function()
        if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
          local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
          sawStart = ok and type(mapID) == "number" and mapID > 0 or false
        else
          sawStart = false
        end
      end)
      return
    elseif event ~= "CHALLENGE_MODE_COMPLETED" then
      return
    end
    if not sawStart then return end
    sawStart = false -- consume once; a stale duplicate COMPLETED can't re-pop
    -- Give Blizzard a moment to settle the completion data, then snapshot.
    C_Timer.After(1, function()
      local run = ReadCompletionInfo()
      if run then
        lastRun = run
        ShowPanel(run)
      end
    end)
  end,
  OnOptions = function(ctx)
    ctx.AddCB(l("opt_rs_show", "Show the run summary panel when a keystone run ends"),
      function() return MDB().autoShow ~= false end,
      function(v) MDB().autoShow = v end)
  end,
}
NS.RegisterModule(M)

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.summary = function()
  local run = lastRun
  if not run then
    NS.Print(l("sum_none", "No completed run this session."))
    return
  end
  run.forceShow = true
  ShowPanel(run)
end

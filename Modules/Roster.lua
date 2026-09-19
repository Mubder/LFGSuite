-- LFG Suite - Modules/Roster.lua
-- PHASE 4. Absorbs: AlterEgo (ARR - feature-inspired only),
-- Astral Keys (weekly vault/cache tracking).
--
-- Feature checklist:
--   [x] Alt registry: every character records class, level, avg ilvl, M+ rating,
--       owned keystone, Great Vault progress and raid lockouts on login/logout
--       (SavedVariables are account-wide, so the roster aggregates all alts)
--   [x] Roster window: sortable account-wide table (rating/ilvl/key/vault/age),
--       class-colored, weekly affixes line on top (/lfgs roster)
--   [x] Great Vault: per-char unlocked/total slots + login notification when
--       rewards are waiting (C_WeeklyRewards probes)
--   [x] Raid lockout overview (mouse over a row: locked instances + reset time)
--   [x] Optional instance-reset announcement to party (default OFF)
--   [ ] Seasonal currencies (needs verified Midnight currency IDs)
--   [ ] Equipment inspection across alts
--   [ ] Click-to-teleport (needs the dungeon teleport spell table)

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local Util = NS.Util
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

local ROSTER_DEFAULTS = {
  announceResets = false,
  vaultNotify = true,
  chars = {}, -- [fullName] = { class, level, ilvl, rating, key, vault, lockouts, t }
}

local function MDB() return NS.EnsureModuleDB("roster", ROSTER_DEFAULTS) end

local ROWS_VISIBLE, ROW_H = 10, 20

local function MyFullName()
  return (UnitName("player") or "?") .. "-" .. GetRealmName()
end

-- ---------------------------------------------------------------------------
-- Character snapshot
-- ---------------------------------------------------------------------------

local function Probe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, ...)
  if ok and v ~= nil then return v end
  return nil
end

local function VaultState()
  if not (C_WeeklyRewards and C_WeeklyRewards.GetActivities) then return nil end
  local ok, acts = pcall(C_WeeklyRewards.GetActivities)
  if not (ok and type(acts) == "table") then return nil end
  local unlocked, total = 0, 0
  for _, a in ipairs(acts) do
    if type(a) == "table" then
      total = total + 1
      if type(a.threshold) == "number" and type(a.progress) == "number"
        and a.progress >= a.threshold and a.threshold > 0 then
        unlocked = unlocked + 1
      end
    end
  end
  return unlocked, total
end

local function LockoutList()
  if not (GetNumSavedInstances and GetSavedInstanceInfo) then return nil end
  local okN, n = pcall(GetNumSavedInstances)
  if not (okN and type(n) == "number") then return nil end
  local out = {}
  for i = 1, n do
    -- returns: name, lockoutId, resets, difficulty, locked, extended, ...,
    -- difficultyName (10th)
    local okI, name, _, resets, _, locked, _, _, _, diffName = pcall(GetSavedInstanceInfo, i)
    if okI and name and locked then
      out[#out + 1] = { name = name, difficulty = diffName, resets = resets }
    end
  end
  return out
end

local function SnapshotChar()
  local db = MDB()
  local _, class = UnitClass("player")
  local avgEquipped, avgTotal
  if GetAverageItemLevel then
    local ok, e, t = pcall(GetAverageItemLevel)
    if ok then avgEquipped, avgTotal = e, t end
  end
  local key
  if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel then
    local okL, lvl = pcall(C_MythicPlus.GetOwnedKeystoneLevel)
    local okM, mapID = pcall(C_MythicPlus.GetOwnedKeystoneChallengeMapID)
    if okL and okM and lvl and mapID and lvl >= 2 then
      key = { level = lvl, mapID = mapID, name = Util.GetChallengeMapName(mapID) or "?" }
    end
  end
  local vaultU, vaultT = VaultState()
  db.chars[MyFullName()] = {
    class = class,
    level = UnitLevel and UnitLevel("player") or nil,
    ilvl = math.floor((avgEquipped or avgTotal or 0) + 0.5),
    rating = Probe(C_MythicPlus and C_MythicPlus.GetOverallDungeonScore) or 0,
    key = key,
    vault = vaultU and { unlocked = vaultU, total = vaultT } or nil,
    lockouts = LockoutList(),
    t = time(),
  }
end

-- ---------------------------------------------------------------------------
-- Roster window
-- ---------------------------------------------------------------------------

local frame, scroll
local rows = {}
local sortCycle = { "rating", "name", "ilvl", "key", "vault", "seen" }

local function BuildRows()
  local db = MDB()
  local out = {}
  for name, e in pairs(db.chars or {}) do
    if type(e) == "table" then
      out[#out + 1] = { name = name, class = e.class, ilvl = e.ilvl or 0,
        rating = e.rating or 0, key = e.key, vault = e.vault,
        lockouts = e.lockouts, t = e.t or 0 }
    end
  end
  local mode = db.sort or "rating"
  if mode == "name" then
    table.sort(out, function(a, b) return a.name < b.name end)
  elseif mode == "ilvl" then
    table.sort(out, function(a, b) return a.ilvl > b.ilvl end)
  elseif mode == "key" then
    table.sort(out, function(a, b)
      local ka, kb = (a.key and a.key.level or 0), (b.key and b.key.level or 0)
      if ka ~= kb then return ka > kb end
      return a.rating > b.rating
    end)
  elseif mode == "vault" then
    table.sort(out, function(a, b)
      local va, vb = (a.vault and a.vault.unlocked or -1), (b.vault and b.vault.unlocked or -1)
      if va ~= vb then return va > vb end
      return a.rating > b.rating
    end)
  elseif mode == "seen" then
    table.sort(out, function(a, b) return a.t > b.t end)
  else -- rating
    table.sort(out, function(a, b)
      if a.rating ~= b.rating then return a.rating > b.rating end
      return a.name < b.name
    end)
  end
  return out
end

function NS.RefreshRosterUI()
  if not frame then return end
  local aff = NS.Affixes.Summary()
  frame.affixLine:SetText(aff and ("|cffffd100" .. l("affixes_lbl", "Affixes: ") .. "|r" .. aff) or "")
  local data = BuildRows()
  FauxScrollFrame_Update(scroll, #data, ROWS_VISIBLE, ROW_H)
  local offset = FauxScrollFrame_GetOffset(scroll)
  for i = 1, ROWS_VISIBLE do
    local row = rows[i]
    local e = data[offset + i]
    if e then
      row.name:SetText(Util.ClassColorize(e.class, Util.ShortName(e.name)))
      row.ilvl:SetText(e.ilvl > 0 and tostring(e.ilvl) or "-")
      row.rating:SetText(e.rating > 0 and tostring(e.rating) or "-")
      if e.key then
        local ab = Util.AbbrevDungeonName(e.key.name) or e.key.name or "?"
        row.key:SetText(string.format("|cffffd100+%d %s|r", e.key.level, ab))
      else
        row.key:SetText("|cff888888-|r")
      end
      row.vault:SetText(e.vault and string.format("%d/%d", e.vault.unlocked, e.vault.total) or "-")
      row.seen:SetText("|cff888888" .. (Util.FormatAge(time() - e.t) or "?") .. "|r")
      row.entry = e
      row:Show()
    else
      row.entry = nil
      row:Hide()
    end
  end
end

local function BuildUI()
  if frame then return end
  frame = CreateFrame("Frame", "LFGSuiteRosterFrame", UIParent, "BackdropTemplate")
  frame:SetSize(520, 396)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:SetFrameStrata("HIGH")
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  frame:Hide()

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", frame, "TOP", 0, -10)
  title:SetText("|cffffd100" .. l("roster_title", "Alt Roster") .. "|r")

  local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  close:SetSize(24, 20)
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
  close:SetText("X")
  close:SetScript("OnClick", function() frame:Hide() end)

  frame.affixLine = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.affixLine:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -38)
  frame.affixLine:SetWidth(488)
  frame.affixLine:SetJustifyH("LEFT")

  local hy = -58
  local function Header(text, x, w)
    local h = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetPoint("TOPLEFT", frame, "TOPLEFT", x, hy)
    h:SetWidth(w)
    h:SetJustifyH("LEFT")
    h:SetText("|cffffd100" .. text .. "|r")
  end
  Header(l("col_name", "Name"), 16, 150)
  Header(l("col_ilvl", "iLvl"), 170, 40)
  Header(l("col_score", "Rating"), 214, 46)
  Header(l("col_key", "Key"), 264, 76)
  Header("Vault", 344, 46)
  Header(l("col_seen", "Seen"), 394, 60)

  scroll = CreateFrame("ScrollFrame", "LFGSuiteRosterScroll", frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, hy - 6)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 42)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, NS.RefreshRosterUI)
  end)

  for i = 1, ROWS_VISIBLE do
    local row = CreateFrame("Frame", nil, frame)
    row:SetSize(484, ROW_H)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, hy - 8 - (i - 1) * ROW_H)
    row:EnableMouse(true)
    if i % 2 == 0 then
      local zebra = row:CreateTexture(nil, "BACKGROUND")
      zebra:SetAllPoints()
      zebra:SetColorTexture(0.15, 0.15, 0.15, 0.35)
    end
    local function Col(x, w)
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("TOPLEFT", row, "TOPLEFT", x, 0)
      fs:SetWidth(w)
      fs:SetJustifyH("LEFT")
      return fs
    end
    row.name = Col(0, 150)
    row.ilvl = Col(154, 40)
    row.rating = Col(198, 46)
    row.key = Col(248, 76)
    row.vault = Col(328, 46)
    row.seen = Col(378, 60)
    row:SetScript("OnEnter", function(self)
      local e = self.entry
      if not e then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(Util.ClassColorize(e.class, e.name), 1, 1, 1)
      if e.key then
        GameTooltip:AddDoubleLine(l("col_key", "Key"),
          string.format("+%d %s", e.key.level, e.key.name or "?"), 1, 1, 1, 1, 0.82, 0)
      end
      if e.vault then
        GameTooltip:AddDoubleLine("Great Vault",
          string.format("%d / %d unlocked", e.vault.unlocked, e.vault.total), 1, 1, 1, 1, 1, 1)
      end
      if e.lockouts and #e.lockouts > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(l("roster_lockouts", "Raid lockouts"), 0.9, 0.9, 0.9)
        for _, lo in ipairs(e.lockouts) do
          local reset = lo.resets and Util.FormatAge(lo.resets) or "?"
          GameTooltip:AddDoubleLine(lo.name .. (lo.difficulty and (" (" .. lo.difficulty .. ")") or ""),
            reset, 0.85, 0.85, 0.85, 0.7, 0.7, 0.7)
        end
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = row
  end

  local sortBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  sortBtn:SetSize(170, 22)
  sortBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 10)
  local function PaintSort()
    sortBtn:SetText(l("sort_fmt", "Sort: %s"):format(MDB().sort or "rating"))
  end
  sortBtn:SetScript("OnClick", function()
    local db = MDB()
    local cur = db.sort or "rating"
    local nxt = "rating"
    for i, m in ipairs(sortCycle) do
      if m == cur then nxt = sortCycle[(i % #sortCycle) + 1] break end
    end
    db.sort = nxt
    PaintSort()
    NS.RefreshRosterUI()
  end)
  PaintSort()

  local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 14)
  hint:SetText("|cff888888" .. l("roster_hint", "Hover a character for vault + lockouts") .. "|r")
end

function NS.ToggleRosterWindow(state)
  BuildUI()
  if not frame then return end
  if state == nil then state = not frame:IsShown() end
  if state then
    NS.Affixes.Refresh()
    SnapshotChar()
    NS.RefreshRosterUI()
  end
  frame:SetShown(state)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {
  key = "roster",
  label = "Alt Roster",
  desc = "Account-wide alts: rating, ilvl, keys, vault, lockouts (/lfgs roster)",
  phase = 4,
  status = "alpha",
  defaultEnabled = true,
  events = {
    "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "INSTANCE_RESET",
    "CHALLENGE_MODE_COMPLETED",
  },
  OnLoad = function() MDB() end,
  OnEnable = function() MDB() end,
  OnEvent = function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
      C_Timer.After(5, function()
        SnapshotChar()
        NS.RefreshRosterUI()
        local db = MDB()
        if db.vaultNotify ~= false and C_WeeklyRewards and C_WeeklyRewards.HasAvailableRewards then
          local ok, has = pcall(C_WeeklyRewards.HasAvailableRewards)
          if ok and has then
            NS.Print("|cffffd100" .. l("vault_ready", "Great Vault: rewards are waiting for you!") .. "|r")
          end
        end
      end)
    elseif event == "PLAYER_LOGOUT" then
      SnapshotChar()
    elseif event == "CHALLENGE_MODE_COMPLETED" then
      C_Timer.After(3, function()
        SnapshotChar()
        NS.RefreshRosterUI()
      end)
    elseif event == "INSTANCE_RESET" then
      if MDB().announceResets and IsInGroup and IsInGroup() then
        local zone = IsInInstance() and GetRealZoneText() or nil
        if zone then
          pcall(SendChatMessage, "[LFG Suite] " .. l("reset_announce", "Instance reset") .. ": " .. zone,
            IsInRaid and IsInRaid() and "RAID" or "PARTY")
        end
      end
    end
  end,
  OnOptions = function(ctx)
    ctx.AddCB(l("opt_r_vault", "Notify when Great Vault has rewards on login"),
      function() return MDB().vaultNotify ~= false end,
      function(v) MDB().vaultNotify = v end)
    ctx.AddCB(l("opt_r_reset", "Announce instance resets to the group"),
      function() return MDB().announceResets == true end,
      function(v) MDB().announceResets = v end)
  end,
}
NS.RegisterModule(M)

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.roster = function() NS.ToggleRosterWindow() end

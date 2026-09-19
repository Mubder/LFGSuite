-- LFG Suite - Modules/Browser.lua
-- PHASE 1. Absorbs: Premade Sort, Premade Groups Filter (basic tags for now),
-- Premade Regions (phase 2), LFG Inspect (browse side, phase 2),
-- Mythic Plus Tweaks (LFG leader score tag).
--
-- Feature checklist:
--   [x] Listing age tag per row ("2m") - hidden if Premade Sort is loaded
--   [x] Key level tag parsed from listing title ("+7")
--   [x] Leader M+ score tag (leaderOverallDungeonScore when Blizzard provides it)
--   [x] Double-click a listing to sign up with remembered roles
--   [x] Role memory: captured from every signup via ApplyToGroup hook
--       (works for our double-click AND Blizzard's own signup dialog)
--   [x] Refresh: /lfgs refresh + keybind (Bindings.xml)
--   [ ] Sort listings by age (deferred: ScrollBox reordering is fragile)
--   [ ] Region tags (Premade Regions) - phase 2
--   [ ] Filter panel + expression language - phase 2
--   [ ] Listing tooltip enrichment (members/comp/ignore) - phase 2
--   [ ] Role pre-selection on Blizzard's signup dialog (needs dialog internals)

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local Util = NS.Util
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

BINDING_HEADER_LFGSUITE = "LFG Suite"
BINDING_NAME_LFGSUITE_BROWSEREFRESH = "Refresh Group Finder search"

local BROWSER_DEFAULTS = {
  tags = true,
  doubleClick = true,
  rememberRoles = true,
  roles = nil, -- { tank, healer, dps } captured on signup
}

local function MDB() return NS.EnsureModuleDB("browser", BROWSER_DEFAULTS) end

local function IsAddonLoaded(name)
  if not (C_AddOns and C_AddOns.IsAddOnLoaded) then return false end
  local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, name)
  return ok and loaded or false
end

-- ---------------------------------------------------------------------------
-- Listing data helpers
-- ---------------------------------------------------------------------------

-- Leader overall M+ score, defending against field renames across patches.
local function GetLeaderScore(info)
  if type(info) ~= "table" then return nil end
  local s = info.leaderOverallDungeonScore
  if type(s) == "number" and s > 0 then return s end
  local d = info.leaderDungeonScore
  if type(d) == "table" and type(d.score) == "number" and d.score > 0 then return d.score end
  return nil
end

local function RowTag(info)
  local db = MDB()
  if db.tags == false then return nil end
  local parts = {}
  -- Deference: Premade Sort already draws listing age.
  if not IsAddonLoaded("Premade Sort") and type(info.age) == "number" then
    local age = Util.FormatAge(info.age)
    if age then parts[#parts + 1] = "|cffa0a0a0" .. age .. "|r" end
  end
  local title = Util.CleanKString((info.name or "") .. " " .. (info.comment or ""))
  local keyLevel = Util.ParseKeyLevel(title)
  if keyLevel then parts[#parts + 1] = "|cffffd100+" .. keyLevel .. "|r" end
  local score = GetLeaderScore(info)
  if score then parts[#parts + 1] = "|cff55ff55" .. tostring(math.floor(score)) .. "|r" end
  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Row decoration
-- ---------------------------------------------------------------------------

local function CollectSearchButtons(out)
  -- Strategy A: modern ScrollBox frames.
  local okA, frames = pcall(function()
    local sb = LFGListFrame.SearchPanel.ScrollBox
    return sb:GetFrames()
  end)
  if okA and type(frames) == "table" then
    for _, f in ipairs(frames) do out[#out + 1] = f end
    if #out > 0 then return end
  end
  -- Strategy B: legacy globally-named entry buttons.
  for i = 1, 24 do
    local b = _G["LFGListSearchEntry" .. i]
    if b then out[#out + 1] = b end
  end
end

function NS.BrowserSignup(resultID)
  if not (C_LFGList and C_LFGList.ApplyToGroup) then
    NS.Print(l("signup_unavailable", "Cannot sign up automatically on this client."))
    return
  end
  local db = MDB()
  local roles = (db.rememberRoles and db.roles) or { tank = false, healer = false, dps = true }
  if not (roles.tank or roles.healer or roles.dps) then roles.dps = true end
  local ok = pcall(C_LFGList.ApplyToGroup, resultID, "", roles.tank, roles.healer, roles.dps)
  if ok then
    local okI, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    info = (okI and type(info) == "table") and info or {}
    NS.AppliedListings[resultID] = {
      name = Util.CleanKString(info.name or "?"),
      comment = Util.CleanKString(info.comment or ""),
      leader = info.leaderName,
      t = time(),
    }
    NS.Print(string.format(l("signed_up_fmt", "Signed up: %s"), NS.AppliedListings[resultID].name))
  end
end

local function DecorateRows()
  if not (LFGListFrame and LFGListFrame.SearchPanel) then return end
  if not (C_LFGList and C_LFGList.GetSearchResultInfo) then return end
  local buttons = {}
  CollectSearchButtons(buttons)
  for _, b in ipairs(buttons) do
    local resultID = b.resultID
    if resultID then
      local okI, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
      if okI and type(info) == "table" then
        local tag = RowTag(info)
        if tag then
          if not b._lfgsTag then
            local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("RIGHT", b, "RIGHT", -96, 0)
            b._lfgsTag = fs
          end
          b._lfgsTag:SetText(tag)
          b._lfgsTag:Show()
        elseif b._lfgsTag then
          b._lfgsTag:Hide()
        end
      end
    end
    -- Double-click signup (own timestamp detection; no click re-registration).
    if MDB().doubleClick ~= false and not b._lfgsDC then
      b._lfgsDC = true
      b:HookScript("OnMouseUp", function(self, mouseBtn)
        if mouseBtn ~= "LeftButton" then return end
        local db = MDB()
        if db.doubleClick == false then return end
        local now = GetTime()
        if self._lfgsLastClick and (now - self._lfgsLastClick) < 0.35 then
          self._lfgsLastClick = nil
          if self.resultID then
            NS.BrowserSignup(self.resultID)
          end
        else
          self._lfgsLastClick = now
        end
      end)
    end
  end
end

local decoratePending
local function ScheduleDecorate()
  if decoratePending then return end
  decoratePending = true
  C_Timer.After(0.15, function()
    decoratePending = false
    DecorateRows()
  end)
end

-- ---------------------------------------------------------------------------
-- Role memory: capture every signup (ours AND Blizzard's dialog path)
-- ---------------------------------------------------------------------------

local function InstallApplyHook()
  if not (C_LFGList and C_LFGList.ApplyToGroup) then return end
  local ok = pcall(hooksecurefunc, C_LFGList, "ApplyToGroup", function(resultID, _, tank, healer, dps)
    local db = MDB()
    if db.rememberRoles ~= false then
      db.roles = { tank = tank and true or false, healer = healer and true or false, dps = dps and true or false }
    end
    local okI, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if okI and type(info) == "table" then
      NS.AppliedListings[resultID] = {
        name = Util.CleanKString(info.name or "?"),
        comment = Util.CleanKString(info.comment or ""),
        leader = info.leaderName,
        t = time(),
      }
    end
  end)
  if not ok and NS.ModuleError then
    NS.ModuleError({ key = "browser" }, "ApplyToGroup hook failed")
  end
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

function NS.BrowserRefresh()
  local panel = LFGListFrame and LFGListFrame.SearchPanel
  if not panel then
    NS.Print(l("refresh_nopanel", "Open the Group Finder (Premade Groups) first."))
    return
  end
  for _, name in ipairs({ "RefreshButton", "SearchButton" }) do
    local btn = panel[name]
    if btn and btn.IsShown and btn:IsShown() and btn.Click then
      pcall(btn.Click, btn)
      NS.Print(l("refresh_done", "Group Finder search refreshed."))
      return
    end
  end
  NS.Print(l("refresh_nosearch", "Start a search first - no refresh button visible."))
end

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.refresh = function() NS.BrowserRefresh() end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {
  key = "browser",
  label = "Group Browser",
  desc = "Listing age/score/key tags, double-click signup, role memory, refresh",
  phase = 1,
  status = "alpha",
  defaultEnabled = true,
  events = { "LFG_LIST_SEARCH_RESULTS_UPDATED" },
  OnLoad = function()
    MDB()
    InstallApplyHook()
  end,
  OnEnable = function()
    MDB()
    InstallApplyHook()
  end,
  OnEvent = function()
    ScheduleDecorate()
  end,
  OnOptions = function(ctx)
    ctx.AddCB(l("opt_tags", "Show age / key level / leader score tags on listings"),
      function() return MDB().tags ~= false end,
      function(v) MDB().tags = v end)
    ctx.AddCB(l("opt_dblclick", "Double-click a listing to sign up"),
      function() return MDB().doubleClick ~= false end,
      function(v) MDB().doubleClick = v end)
    ctx.AddCB(l("opt_roles", "Remember my selected roles for signups"),
      function() return MDB().rememberRoles ~= false end,
      function(v) MDB().rememberRoles = v end)
  end,
}
NS.RegisterModule(M)

-- LFG Suite - Modules/Browser.lua
-- PHASE 1. Absorbs: Premade Sort, Premade Groups Filter (basic tags for now),
-- Premade Regions (phase 2), LFG Inspect (browse side, phase 2),
-- Mythic Plus Tweaks (LFG leader score tag).
--
-- Feature checklist:
--   [x] Listing age tag per row ("2m") - hidden if Premade Sort is loaded
--   [x] Key level tag parsed from listing title ("+7") - only when Midnight's
--       kstring wrapping leaves the title readable (degrades silently)
--   [x] Leader realm tag from partyGUID (the practical "region" info; hidden
--       when the leader is on your own realm)
--   [x] Leader M+ score tag (leaderOverallDungeonScore, Blizzard rarity color)
--   [x] Tag on the row's playstyle line (3rd line) - clear of the title,
--       dungeon name and the 125px class/role icon block; realms truncated
--   [x] Double-click a listing to sign up with remembered roles
--   [x] Role memory: captured from every signup via ApplyToGroup hook
--       (works for our double-click AND Blizzard's own signup dialog)
--   [x] Refresh: /lfgs refresh + keybind (Bindings.xml)
--   [x] Resilience: ScrollBox/row-field probes across client generations,
--       per-row pcall guards, /lfgs browse diagnostics
--   NOTE on events: the Group Finder fires LFG_LIST_SEARCH_RESULTS_RECEIVED
--   (each search completes), LFG_LIST_SEARCH_RESULT_UPDATED (one result
--   changed, payload = searchResultID) and LFG_LIST_UPDATE_SEARCH_RESULTS.
--   There is NO LFG_LIST_SEARCH_RESULTS_UPDATED event - registering it fails
--   silently (unknown event) and the module never decorated anything.
--   [ ] Sort listings by age (deferred: ScrollBox reordering is fragile)
--   [x] Leader realm tag shipped above (Premade Regions' core value); full
--       datacenter-region mapping stays phase 2
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
  local function num(v)
    if type(v) == "number" and v > 0 then return math.floor(v) end
    return nil
  end
  local hit = num(info.leaderOverallDungeonScore)
    or num(info.leaderScore)
    or num(info.leaderMythicPlusScore)
  if hit then return hit end
  local d = info.leaderDungeonScore
  if type(d) == "table" then hit = num(d.score) end
  if hit then return hit end
  -- Some clients nest leader data one level down.
  local li = info.leaderInfo
  if type(li) == "table" then
    hit = num(li.overallDungeonScore) or num(li.dungeonScore) or num(li.score)
    if hit then return hit end
  end
  return nil
end

-- Listing age in seconds: field name moved across patches, and some clients
-- only expose a creation timestamp.
local function GetListingAge(info)
  if type(info) ~= "table" then return nil end
  if type(info.age) == "number" and info.age >= 0 then return info.age end
  if type(info.listingAge) == "number" and info.listingAge >= 0 then return info.listingAge end
  if type(info.creationTime) == "number" and info.creationTime > 0 then
    local age = time() - info.creationTime
    if age >= 0 then return age end
  end
  return nil
end

-- Leader's realm (the practical "region" info: within a region the Group
-- Finder is region-wide, so what distinguishes listings is which realm the
-- leader is from). Midnight wraps player names in unreadable kstrings, but
-- the partyGUID stays readable: GetPlayerInfoByGUID yields the plain realm.
local function GetLeaderRealm(info)
  if type(info) ~= "table" then return nil end
  if type(info.partyGUID) == "string" and GetPlayerInfoByGUID then
    local ok, _, _, _, _, _, _, realm = pcall(GetPlayerInfoByGUID, info.partyGUID)
    if ok and type(realm) == "string" and realm ~= "" then return realm end
  end
  local ln = Util.CleanKString(info.leaderName or "")
  local realm = ln:match("-(.+)$")
  if realm and realm ~= "" then return realm end
  return nil
end

-- Same rarity coloring Blizzard uses in the listing tooltip.
local function ColorScore(score)
  if C_ChallengeMode and C_ChallengeMode.GetDungeonScoreRarityColor then
    local ok, c = pcall(C_ChallengeMode.GetDungeonScoreRarityColor, score)
    if ok and type(c) == "table" then
      if c.WrapTextInColorCode then return c:WrapTextInColorCode(tostring(score)) end
      if type(c.colorStr) == "string" then return "|c" .. c.colorStr .. tostring(score) .. "|r" end
    end
  end
  return "|cff55ff55" .. tostring(score) .. "|r"
end

local function RowTag(info)
  local db = MDB()
  if db.tags == false then return nil end
  local parts = {}
  -- Deference: Premade Sort already draws listing age.
  if not (IsAddonLoaded("Premade Sort") or IsAddonLoaded("PremadeSort")) then
    local age = GetListingAge(info)
    if age then
      local ageTxt = Util.FormatAge(age)
      if ageTxt then parts[#parts + 1] = "|cffa0a0a0" .. ageTxt .. "|r" end
    end
  end
  local title = Util.CleanKString((info.name or "") .. " " .. (info.comment or ""))
  local keyLevel = Util.ParseKeyLevel(title)
  if keyLevel then parts[#parts + 1] = "|cffffd100+" .. keyLevel .. "|r" end
  local myRealm = (GetRealmName() or ""):gsub("%s", "")
  local realm = GetLeaderRealm(info)
  if realm then realm = Util.Trunc(realm:gsub("%s", ""), 10) end
  if realm and realm ~= "" and realm:lower() ~= myRealm:lower() then
    parts[#parts + 1] = "|cff9ec1e8" .. realm .. "|r"
  end
  local score = GetLeaderScore(info)
  if score then parts[#parts + 1] = ColorScore(score) end
  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Row decoration
-- ---------------------------------------------------------------------------

-- Debug state surfaced by /lfgs browse (see bottom of file).
NS._browserDebug = NS._browserDebug or {
  lastEvent = nil, strategy = nil, frames = 0, withID = 0, tagged = 0, errors = 0,
}

-- Result ID, defending against Blizzard renames: the row button held
-- .resultID for years, but newer ScrollBox rows may expose it under a
-- different key or via GetData().
local function GetResultID(b)
  if type(b) ~= "table" then return nil end
  for _, k in ipairs({ "resultID", "listingID", "searchResultID" }) do
    local v = b[k]
    if type(v) == "number" and v > 0 then return v end
  end
  if type(b.GetResultID) == "function" then
    local ok, v = pcall(b.GetResultID, b)
    if ok and type(v) == "number" and v > 0 then return v end
  end
  -- ScrollBox rows carry their data via GetElementData(); for search results
  -- the element is { resultID = <id> }.
  for _, getter in ipairs({ "GetElementData", "GetData" }) do
    if type(b[getter]) == "function" then
      local ok, d = pcall(b[getter], b)
      if ok and type(d) == "table" then
        for _, k in ipairs({ "resultID", "listingID", "searchResultID", "id", "ID" }) do
          local v = d[k]
          if type(v) == "number" and v > 0 then return v end
        end
      elseif ok and type(d) == "number" and d > 0 then
        return d
      end
    end
  end
  return nil
end

local function PushFramesFromScrollBox(sb, out)
  if type(sb) ~= "table" then return 0 end
  local before = #out
  -- New ScrollBox API.
  if type(sb.GetFrames) == "function" then
    local ok, frames = pcall(sb.GetFrames, sb)
    if ok and type(frames) == "table" then
      for _, f in ipairs(frames) do out[#out + 1] = f end
    end
  end
  if #out > before then return #out - before end
  if type(sb.EnumerateFrames) == "function" then
    -- Forward the full iterator triple: pcall swallows the extra returns,
    -- and a bare `for f in iter` passes nil state -> "bad argument #2".
    local ok, iter, state, control = pcall(sb.EnumerateFrames, sb)
    if ok and type(iter) == "function" then
      for f in iter, state, control do out[#out + 1] = f end
    end
  end
  if #out > before then return #out - before end
  -- Last resort: raw children that look like rows.
  if type(sb.GetChildren) == "function" then
    local ok, a, b, c, d, e = pcall(sb.GetChildren, sb)
    if ok then
      for _, child in ipairs({ a, b, c, d, e }) do
        if type(child) == "table" and type(child.HookScript) == "function"
          and (GetResultID(child) or type(child.GetData) == "function") then
          out[#out + 1] = child
        end
      end
    end
  end
  return #out - before
end

local function FindScrollBox()
  local panel = LFGListFrame and LFGListFrame.SearchPanel
  if type(panel) ~= "table" then
    if GroupFinderFrame and GroupFinderFrame.SearchPanel then
      panel = GroupFinderFrame.SearchPanel
    end
  end
  if type(panel) ~= "table" then return nil, nil end
  return panel.ScrollBox or panel.scrollBox or panel.Scrollbox, panel
end

local function CollectSearchButtons(out)
  local dbg = NS._browserDebug
  -- Strategy A: modern ScrollBox frames (both casings / both parents).
  local sb = FindScrollBox()
  if sb then
    local n = PushFramesFromScrollBox(sb, out)
    if n > 0 then dbg.strategy = "scrollbox" return end
  end
  -- Strategy B: legacy globally-named entry buttons.
  for i = 1, 40 do
    local b = _G["LFGListSearchEntry" .. i]
    if b then out[#out + 1] = b end
  end
  if #out > 0 then dbg.strategy = "legacy" return end
  -- Strategy C: any child of the search panel that looks like a row.
  local _, panel = FindScrollBox()
  if panel and type(panel.GetChildren) == "function" then
    local ok, a, b, c, d, e, f, g, h = pcall(panel.GetChildren, panel)
    if ok then
      for _, child in ipairs({ a, b, c, d, e, f, g, h }) do
        if type(child) == "table" and type(child.HookScript) == "function"
          and (GetResultID(child) or type(child.GetData) == "function") then
          out[#out + 1] = child
        end
      end
    end
    if #out > 0 then dbg.strategy = "children" return end
  end
  dbg.strategy = "none"
end

function NS.BrowserSignup(resultID)
  if not (C_LFGList and C_LFGList.ApplyToGroup) then
    NS.Print(l("signup_unavailable", "Cannot sign up automatically on this client."))
    return
  end
  local db = MDB()
  local roles = (db.rememberRoles and db.roles) or { tank = false, healer = false, dps = true }
  if not (roles.tank or roles.healer or roles.dps) then roles.dps = true end
  -- NOTE: no comment arg on this client generation: (resultID, tank, healer, dps).
  local ok = pcall(C_LFGList.ApplyToGroup, resultID, roles.tank, roles.healer, roles.dps)
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

-- Decorates one row. Returns "tagged", "id" (had a resultID), "err" or nil so
-- the batch pass and /lfgs browse diagnostics can count outcomes.
local function DecorateRow(b)
  if type(b) ~= "table" then return nil end
  if not (C_LFGList and C_LFGList.GetSearchResultInfo) then return nil end
  local okRow, resultID = pcall(GetResultID, b)
  if not okRow then resultID = nil end
  if not resultID then return nil end
  local okI, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
  if not (okI and type(info) == "table") then return "err" end
  local okTag, tag = pcall(RowTag, info)
  if not okTag then tag = nil end
  if tag then
    if not b._lfgsTag then
      local okF, fs = pcall(b.CreateFontString, b, nil, "OVERLAY", "GameFontHighlightSmall")
      if okF and fs then
        -- The row's third line (Playstyle: "Relaxed/Competitive", usually
        -- short or empty) is the only reliably free space - the title and
        -- activity lines span the middle, and the class/role icon block
        -- alone is 125px wide. Sit the tag right after the playstyle text.
        local anchored = false
        if b.Playstyle then
          anchored = pcall(fs.SetPoint, fs, "LEFT", b.Playstyle, "RIGHT", 10, 0)
        end
        if not anchored and b.DataDisplay then
          anchored = pcall(fs.SetPoint, fs, "RIGHT", b.DataDisplay, "LEFT", -8, 0)
        end
        if not anchored then
          pcall(fs.SetPoint, fs, "BOTTOMLEFT", b, "BOTTOMLEFT", 10, 6)
        end
        pcall(fs.SetJustifyH, fs, "LEFT")
        b._lfgsTag = fs
      end
    end
    if b._lfgsTag then
      pcall(b._lfgsTag.SetText, b._lfgsTag, tag)
      pcall(b._lfgsTag.Show, b._lfgsTag)
    end
    return "tagged"
  end
  if b._lfgsTag then pcall(b._lfgsTag.Hide, b._lfgsTag) end
  return "id"
end

local function InstallDoubleClick(b)
  if b._lfgsDC or type(b.HookScript) ~= "function" then return end
  b._lfgsDC = true
  pcall(b.HookScript, b, "OnMouseUp", function(self, mouseBtn)
    if mouseBtn ~= "LeftButton" then return end
    local db = MDB()
    if db.doubleClick == false then return end
    local now = GetTime()
    if self._lfgsLastClick and (now - self._lfgsLastClick) < 0.35 then
      self._lfgsLastClick = nil
      local rid = GetResultID(self)
      if rid then
        NS.BrowserSignup(rid)
      end
    else
      self._lfgsLastClick = now
    end
  end)
end

local function DecorateRows()
  local dbg = NS._browserDebug
  if not (LFGListFrame and LFGListFrame.SearchPanel or GroupFinderFrame and GroupFinderFrame.SearchPanel) then return end
  if not (C_LFGList and C_LFGList.GetSearchResultInfo) then return end
  local buttons = {}
  CollectSearchButtons(buttons)
  dbg.frames = #buttons
  local withID, tagged, errors = 0, 0, 0
  for _, b in ipairs(buttons) do
    local res = DecorateRow(b)
    if res == "tagged" or res == "id" then withID = withID + 1 end
    if res == "tagged" then tagged = tagged + 1 end
    if res == "err" then errors = errors + 1 end
    -- Double-click signup (own timestamp detection; no click re-registration).
    if MDB().doubleClick ~= false then
      InstallDoubleClick(b)
    end
  end
  dbg.withID, dbg.tagged, dbg.errors = withID, tagged, errors
end

local decoratePending
local function ScheduleDecorate()
  if decoratePending then return end
  decoratePending = true
  C_Timer.After(0.15, function()
    decoratePending = false
    -- The bus pcall only covers OnEvent (which merely schedules); guard the
    -- deferred pass too so a row-probing bug degrades quietly.
    local ok, err = pcall(DecorateRows)
    if not ok and NS.ModuleError then NS.ModuleError({ key = "browser" }, err) end
  end)
end

-- ---------------------------------------------------------------------------
-- Role memory: capture every signup (ours AND Blizzard's dialog path)
-- ---------------------------------------------------------------------------

local function InstallApplyHook()
  if not (C_LFGList and C_LFGList.ApplyToGroup) then return end
  -- NOTE: (resultID, tank, healer, dps) on this client generation.
  local ok = pcall(hooksecurefunc, C_LFGList, "ApplyToGroup", function(resultID, tank, healer, dps)
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
-- Lazy hooks: Blizzard's Group Finder is load-on-demand, so at our
-- ADDON_LOADED / PLAYER_ENTERING_WORLD the frames do not exist yet. Every
-- relevant event (and /lfgs browse) re-runs EnsureHooks; once the Blizzard
-- addon is in, we hook its OnShow AND the global row updater - the ScrollBox
-- pools and reuses row buttons while scrolling, so the updater hook is what
-- keeps each row's tag correct.
-- ---------------------------------------------------------------------------

local hooksInstalled = false
local rowHookInstalled = false

local function InstallRowUpdateHook()
  if rowHookInstalled then return true end
  if type(LFGListSearchEntry_Update) ~= "function" then return false end
  local ok = pcall(hooksecurefunc, "LFGListSearchEntry_Update", function(b)
    -- pcall: an error inside a secure hook would otherwise surface inside
    -- Blizzard's own row updater.
    local okR, err = pcall(function()
      DecorateRow(b)
      if MDB().doubleClick ~= false then
        InstallDoubleClick(b)
      end
    end)
    if not okR and NS.ModuleError then NS.ModuleError({ key = "browser" }, err) end
  end)
  if ok then
    rowHookInstalled = true
    NS._browserDebug.rowHook = true
  end
  return ok
end

local function EnsureHooks()
  InstallRowUpdateHook()
  if hooksInstalled then return end
  local lfg = LFGListFrame or GroupFinderFrame
  if type(lfg) ~= "table" or type(lfg.HookScript) ~= "function" then return end
  local ok = pcall(lfg.HookScript, lfg, "OnShow", function() ScheduleDecorate() end)
  if ok then hooksInstalled = true end
end

-- /lfgs browse — one-line diagnostics + full breakdown. Run it with the
-- Group Finder open and paste the output when tags don't show.
NS.SlashHandlers.browse = function()
  EnsureHooks()
  ScheduleDecorate()
  C_Timer.After(0.4, function()
    local dbg = NS._browserDebug or {}
    local db = MDB()
    NS.Print(string.format("browser: module %s, tags %s, dblclick %s",
      NS.IsModuleEnabled("browser") and "ON" or "OFF",
      db.tags ~= false and "ON" or "OFF",
      db.doubleClick ~= false and "ON" or "OFF"))
    print(string.format("  event=%s strategy=%s rowHook=%s frames=%s withID=%s tagged=%s errors=%s",
      tostring(dbg.lastEvent), tostring(dbg.strategy), tostring(dbg.rowHook and "yes" or "no"),
      tostring(dbg.frames), tostring(dbg.withID),
      tostring(dbg.tagged), tostring(dbg.errors)))
    if (dbg.frames or 0) == 0 then
      print("  no rows found — open Premade Groups and run a search first")
    elseif (dbg.withID or 0) == 0 then
      print("  rows found but no result IDs — Blizzard renamed the row field again")
    elseif (dbg.tagged or 0) == 0 then
      print("  rows readable but no tags — listing fields (age/score) renamed or tags off")
    end
  end)
end

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
  events = {
    -- Real Group Finder events (see header note): RECEIVED fires for every
    -- completed search, RESULT_UPDATED for single-listing changes,
    -- UPDATE_SEARCH_RESULTS when Blizzard reshuffles the result list.
    "LFG_LIST_SEARCH_RESULTS_RECEIVED", "LFG_LIST_SEARCH_RESULT_UPDATED",
    "LFG_LIST_UPDATE_SEARCH_RESULTS", "PLAYER_ENTERING_WORLD",
  },
  OnLoad = function()
    MDB()
    InstallApplyHook()
    EnsureHooks()
  end,
  OnEnable = function()
    MDB()
    InstallApplyHook()
    EnsureHooks()
  end,
  OnEvent = function(_, event)
    NS._browserDebug.lastEvent = event
    -- Cheap + idempotent: the Group Finder UI is load-on-demand, so the
    -- hooks usually only become installable after the first event.
    EnsureHooks()
    if event == "PLAYER_ENTERING_WORLD" then
      return
    end
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

-- LFG Suite - Modules/Browser.lua
-- PHASE 1. Absorbs: Premade Sort, Premade Groups Filter (basic tags for now),
-- Premade Regions (phase 2), LFG Inspect (browse side, phase 2),
-- Mythic Plus Tweaks (LFG leader score tag).
--
-- Feature checklist:
--   [x] Listing age tag per row ("2m") top-right - hidden if Premade Sort
--       is loaded; key level + leader realm on the left, leader M+ score
--       on the right (Blizzard rarity color) - LFG Inspect-style layout
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
--   [x] Filter card (/lfgs filters): bound to the Group Finder window
--       (child of PVEFrame - moves and hides with it, re-opens with the
--       browser while filters are on). Key-level checkbox row +2..+10,
--       max age, min leader score, hide full M+ groups, "still needs"
--       T/H/D composition chips, min members, min ilvl requirement -
--       themed. Non-destructive filtering (dim + block double-click); the
--       PGF-style expression language stays deliberately unbuilt (simple
--       controls; GPL source not read)
--   [x] Listing group-inspect tooltip (LFG Inspect-style): member names,
--       ignored-player warnings, armor-type distribution, leader score;
--       Shift-only or always (option)
--   [x] Listing tooltip enrichment (members / avg ilvl / leader score)
--   [x] Role pre-selection on Blizzard's signup dialog (remembered roles)

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
  inspectShiftOnly = false, -- group-inspect tooltip shows on plain hover
  -- Listing filters (panel: /lfgs filters, bound to the Group Finder
  -- window). Non-destructive: filtered rows are dimmed, never removed from
  -- Blizzard's list (ScrollBox reordering stays off limits).
  filters = {
    enabled = false,
    levels = {},     -- [level] = true: keep ONLY these key levels (none = all)
    maxAgeMin = 0,   -- minutes; 0 = off
    minScore = 0,    -- leader M+ score; unknown score stays
    hideFull = false,
    needs = { tank = false, healer = false, dps = false }, -- group still LACKS role
    minMembers = 0,  -- at least N members; 0 = off
    minReqIlvl = 0,  -- listing requires ilvl >= N; 0 = off (unknown stays)
    activities = {}, -- [activityID] = true: keep only these dungeons (none = all)
    cardHidden = nil, -- user closed the filter card on purpose
  },
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

-- LFG Inspect-style row layout: listing age top-right, key level + leader
-- realm on the left, leader score on the right (before the icon block).
local function RowTagAge(info)
  if MDB().tags == false then return nil end
  -- Deference: Premade Sort already draws listing age.
  if IsAddonLoaded("Premade Sort") or IsAddonLoaded("PremadeSort") then return nil end
  local age = GetListingAge(info)
  if not age then return nil end
  local ageTxt = Util.FormatAge(age)
  if ageTxt then return "|cffa0a0a0" .. ageTxt .. "|r" end
  return nil
end

local function RowTagLeft(info)
  if MDB().tags == false then return nil end
  local parts = {}
  local title = Util.CleanKString((info.name or "") .. " " .. (info.comment or ""))
  local keyLevel = Util.ParseKeyLevel(title)
  if keyLevel then parts[#parts + 1] = "|cffffd100+" .. keyLevel .. "|r" end
  local myRealm = (GetRealmName() or ""):gsub("%s", "")
  local realm = GetLeaderRealm(info)
  if realm then realm = Util.Trunc(realm:gsub("%s", ""), 10) end
  if realm and realm ~= "" and realm:lower() ~= myRealm:lower() then
    parts[#parts + 1] = "|cff9ec1e8" .. realm .. "|r"
  end
  if #parts == 0 then return nil end
  return table.concat(parts, " ")
end

local function RowTagScore(info)
  if MDB().tags == false then return nil end
  local score = GetLeaderScore(info)
  if score then return ColorScore(score) end
  return nil
end

-- ---------------------------------------------------------------------------
-- Filters (non-destructive: dim + block double-click; never reorder/hide
-- Blizzard's rows, never drop listings we cannot read)
-- ---------------------------------------------------------------------------

local function FiltersEnabled()
  local f = MDB().filters
  return type(f) == "table" and f.enabled == true
end

-- true = listing fails the active filters.
local function RowFilteredOut(info)
  if not FiltersEnabled() then return false end
  local f = MDB().filters
  local title = Util.CleanKString((info.name or "") .. " " .. (info.comment or ""))
  local lvl = Util.ParseKeyLevel(title)
  -- Level whitelist ("difficulty"): ticked levels keep, unticked drop.
  -- Listings without a parseable level always stay (never hide unreadable).
  local levels = f.levels or {}
  local anyLevel = false
  for _ in pairs(levels) do anyLevel = true break end
  if anyLevel and lvl and not levels[lvl] then return true end
  if (f.maxAgeMin or 0) > 0 then
    local age = GetListingAge(info)
    if age and age > f.maxAgeMin * 60 then return true end
  end
  if (f.minScore or 0) > 0 then
    local score = GetLeaderScore(info)
    -- Unknown leader score: keep.
    if score and score < f.minScore then return true end
  end
  if f.hideFull then
    local nm = info.numMembers or info.memberCount
    -- Only fully-booked M+-style groups (5/5 with a key level in the title).
    if lvl and type(nm) == "number" and nm >= 5 then return true end
  end
  -- Composition: "still needs role X" (memberCounts missing = keep).
  local needs = f.needs or {}
  local mc = info.memberCounts
  if (needs.tank or needs.healer or needs.dps) and type(mc) == "table" then
    local t = mc.TANK or mc.tank or 0
    local h = mc.HEALER or mc.healer or 0
    local d = mc.DAMAGER or mc.DAMAGER or mc.dps or 0
    if needs.tank and t > 0 then return true end
    if needs.healer and h > 0 then return true end
    if needs.dps and d > 0 then return true end
  end
  if (f.minMembers or 0) > 0 then
    local nm = info.numMembers or info.memberCount or 0
    if nm < f.minMembers then return true end
  end
  if (f.minReqIlvl or 0) > 0 then
    local req = info.requiredItemLevel or info.iLvl or info.requiredILvl
    -- Unknown requirement: keep.
    if type(req) == "number" and req > 0 and req < f.minReqIlvl then return true end
  end
  -- Dungeon whitelist: ticked activities keep; unknown activity stays.
  local acts = f.activities or {}
  local anyAct = false
  for _ in pairs(acts) do anyAct = true break end
  if anyAct then
    local aid = info.activityID
    if (not aid) and type(info.activityIDs) == "table" then aid = info.activityIDs[1] end
    if aid and not acts[aid] then return true end
  end
  return false
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
-- Tag slot helper: creates the row's fontstring once, anchored per slot.
--   left  = after the playstyle text (3rd line's free space)
--   right = just left of the class/role icon block (DataDisplay)
--   top   = the row's top-right corner (listing age)
local function TagSlot(b, slot)
  local key = "_lfgsTag_" .. slot
  if b[key] then return b[key] end
  local okF, fs = pcall(b.CreateFontString, b, nil, "OVERLAY", "GameFontHighlightSmall")
  if not (okF and fs) then return nil end
  if slot == "top" then
    pcall(fs.SetPoint, fs, "TOPRIGHT", b, "TOPRIGHT", -4, -3)
    pcall(fs.SetJustifyH, fs, "RIGHT")
  elseif slot == "right" then
    -- Bottom-right corner: the dungeon-name line owns the middle, and the
    -- icon block's left edge varies with group size, so the corner is the
    -- only reliably free right-side spot.
    pcall(fs.SetPoint, fs, "BOTTOMRIGHT", b, "BOTTOMRIGHT", -6, 4)
    pcall(fs.SetJustifyH, fs, "RIGHT")
  else
    local anchored = false
    if b.Playstyle then
      anchored = pcall(fs.SetPoint, fs, "LEFT", b.Playstyle, "RIGHT", 10, 0)
    end
    if not anchored then
      pcall(fs.SetPoint, fs, "BOTTOMLEFT", b, "BOTTOMLEFT", 10, 6)
    end
    pcall(fs.SetJustifyH, fs, "LEFT")
  end
  b[key] = fs
  return fs
end

local function DecorateRow(b)
  if type(b) ~= "table" then return nil end
  if not (C_LFGList and C_LFGList.GetSearchResultInfo) then return nil end
  local okRow, resultID = pcall(GetResultID, b)
  if not okRow then resultID = nil end
  if not resultID then return nil end
  local okI, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
  if not (okI and type(info) == "table") then return "err" end
  -- Filtered rows: dim so the list stays intact but noise reads at a glance.
  local filtered = RowFilteredOut(info)
  b._lfgsFiltered = filtered or nil
  pcall(b.SetAlpha, b, filtered and 0.15 or 1)
  local any = false
  local slots = {
    { key = "top", producer = RowTagAge },
    { key = "left", producer = RowTagLeft },
    { key = "right", producer = RowTagScore },
  }
  for _, s in ipairs(slots) do
    local okTag, text = pcall(s.producer, info)
    if not okTag then text = nil end
    local fs = TagSlot(b, s.key)
    if fs then
      if text then
        pcall(fs.SetText, fs, text)
        pcall(fs.Show, fs)
        any = true
      else
        pcall(fs.Hide, fs)
      end
    end
  end
  return any and "tagged" or "id"
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
      if self._lfgsFiltered then
        NS.Print(l("signup_filtered", "That listing is filtered out - adjust /lfgs filters to sign up."))
        return
      end
      local rid = GetResultID(self)
      if rid then
        NS.BrowserSignup(rid)
      end
    else
      self._lfgsLastClick = now
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Filter panel (own frame, shared theme: translucent block + draggable
-- header). /lfgs filters toggles it; it docks next to the Group Finder.
-- ---------------------------------------------------------------------------

local filterFrame

local ScheduleDecorate -- forward-declared: defined near DecorateRows below

local ApplyFiltersToList -- forward-declared: defined after DecorateRows

local SORT_MODES = { "blizzard", "new", "old", "key" }
local SORT_LABEL = {
  blizzard = "Blizzard", new = "Newest", old = "Oldest", key = "Key level",
}

-- The edit boxes and checkboxes poke a re-decorate; guard it like the
-- deferred pass (errors degrade to a chat line, never a UI break).
local function ScheduleDecorateSafe()
  local ok, err = pcall(ScheduleDecorate)
  if not ok and NS.ModuleError then NS.ModuleError({ key = "browser" }, err) end
end

local function UpdateFilterStatus(shown, filtered)
  NS._browserDebug.filtered = filtered
  if not (filterFrame and filterFrame.status) then return end
  if not FiltersEnabled() then
    filterFrame.status:SetText("|cff888888" .. l("filters_off", "filters off") .. "|r")
  elseif (NS._browserDebug.frames or 0) == 0 then
    filterFrame.status:SetText("|cff888888"
      .. l("filters_nosearch", "open the Group Finder and run a search") .. "|r")
  else
    filterFrame.status:SetText(string.format(
      "|cff43d9ff%d|r %s  •  |cff888888%d %s|r",
      shown - filtered, l("shown", "shown"), filtered, l("filtered", "filtered")))
  end
end

local function FilterCheckbox(parent, globalName, label, x, y, get, set)
  local cb = CreateFrame("CheckButton", globalName, parent, "InterfaceOptionsCheckButtonTemplate")
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  if cb.Text then cb.Text:SetText(label) end
  if cb.Text then cb.Text:SetWidth(190) cb.Text:SetJustifyH("LEFT") end
  cb:SetChecked(get())
  cb:SetScript("OnClick", function(self) set(self:GetChecked()) end)
  return cb
end

local function FilterNumBox(parent, label, x, y, w, get, set)
  local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  lbl:SetWidth(120)
  lbl:SetJustifyH("LEFT")
  lbl:SetText("|cffffd100" .. label .. "|r")
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
  box:SetSize(w or 56, 20)
  box:SetAutoFocus(false)
  box:SetNumeric(true)
  box:SetMaxLetters(4)
  box:SetNumber(get())
  local function commit()
    local v = tonumber(box:GetText()) or 0
    set(math.max(0, math.floor(v)))
    UpdateFilterStatus(0, 0)
    ScheduleDecorateSafe()
  end
  box:SetScript("OnEnterPressed", function(self) commit() self:ClearFocus() end)
  box:SetScript("OnEscapePressed", function(self) self:SetNumber(get()) self:ClearFocus() end)
  box:SetScript("OnEditFocusLost", function(self) commit() end)
  return box
end

-- Segmented key-level toggles ("difficulty" as checkboxes): +2..+10 mini
-- buttons; any ticked = whitelist, none = no level filtering.
local function LevelButton(parent, lvl, x, y)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(22, 18)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  t:SetAllPoints()
  t:SetJustifyH("CENTER")
  function b:Paint()
    local on = MDB().filters.levels and MDB().filters.levels[lvl]
    bg:SetColorTexture(on and 0.55 or 0.08, on and 0.42 or 0.11, on and 0.12 or 0.18, on and 0.95 or 0.75)
    t:SetText(on and ("|cffffd100" .. lvl .. "|r") or ("|cffbbbbbb" .. lvl .. "|r"))
  end
  b:SetScript("OnClick", function(self)
    local f = MDB().filters
    f.levels = f.levels or {}
    f.levels[lvl] = (not f.levels[lvl]) or nil
    self:Paint()
    ApplyFiltersToList()
  end)
  b:Paint()
  return b
end

-- "Still needs" role chips (T/H/D): ticked = the group must still LACK it.
local function RoleChip(parent, role, label, x, y)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(34, 18)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  t:SetAllPoints()
  t:SetJustifyH("CENTER")
  function b:Paint()
    local needs = MDB().filters.needs or {}
    local on = needs[role]
    bg:SetColorTexture(on and 0.55 or 0.08, on and 0.42 or 0.11, on and 0.12 or 0.18, on and 0.95 or 0.75)
    t:SetText(on and ("|cffffd100" .. label .. "|r") or ("|cffbbbbbb" .. label .. "|r"))
  end
  b:SetScript("OnClick", function(self)
    local f = MDB().filters
    f.needs = f.needs or {}
    f.needs[role] = (not f.needs[role]) or nil
    self:Paint()
    ApplyFiltersToList()
  end)
  b:Paint()
  return b
end

local sessionManualDock = false

-- Dock-aware placement: other cards attached to the browser's right side
-- (Raider.IO's panel, etc.) occupy the first dock slot(s); we slot in AFTER
-- the rightmost one instead of overlapping. Scans the Group Finder's own
-- children and top-level frames docked to its right edge. Manual dragging
-- disables auto-docking for the session.
local function RelayoutCard()
  if not (filterFrame and PVEFrame) then return end
  if sessionManualDock then return end
  pcall(function()
    local pr, pt = PVEFrame:GetRight(), PVEFrame:GetTop()
    if not (pr and pt) then return
    end
    local rightmost = pr
    local function consider(f)
      if not f or f == filterFrame or f == PVEFrame then return end
      if not (f.IsShown and f:IsShown()) then return end
      if not (f.GetLeft and f.GetTop and f.GetWidth) then return end
      local lf, tf, wf = f:GetLeft(), f:GetTop(), f:GetWidth()
      if not (lf and tf and wf) then return end
      -- A docked card: starts at/after the browser's right edge, sits in
      -- the top band, panel-sized (not the whole screen).
      if wf > 40 and wf < 700 and lf >= pr - 24 and tf > pt - 140 then
        local r = lf + wf
        if r > rightmost then rightmost = r end
      end
    end
    local function scanChildren(fr)
      if not (fr and fr.GetChildren) then return end
      local okP, packed = pcall(function(...) return { ... } end, fr:GetChildren())
      if not (okP and type(packed) == "table") then return end
      -- Modern clients return a single table of children; older return
      -- each child separately. Handle both shapes.
      if type(packed[1]) == "table" and packed[2] == nil and packed[1][1] and packed[1][1].IsShown then
        for _, ch in ipairs(packed[1]) do consider(ch) end
      else
        for _, ch in ipairs(packed) do if type(ch) == "table" then consider(ch) end end
      end
    end
    scanChildren(PVEFrame)
    scanChildren(UIParent)
    filterFrame:ClearAllPoints()
    filterFrame:SetPoint("TOPLEFT", PVEFrame, "TOPRIGHT", rightmost - pr + 8, 0)
  end)
end

local function BuildFilterPanel()
  if filterFrame then return end
  if not PVEFrame then return end -- binds to the Group Finder window
  filterFrame = CreateFrame("Frame", "LFGSuiteBrowserFilters", PVEFrame)
  filterFrame:SetSize(248, 392)
  -- Stick to the Group Finder: parenting makes it move + hide together.
  filterFrame:SetPoint("TOPLEFT", PVEFrame, "TOPRIGHT", 8, 0)
  filterFrame:SetFrameStrata("HIGH")
  filterFrame:SetFrameLevel((PVEFrame:GetFrameLevel() or 50) + 30)
  filterFrame:SetMovable(true)
  filterFrame:EnableMouse(false) -- body click-through; drag via header
  if NS.Theme and NS.Theme.Apply then
    -- onMove doubles as the "user took over placement" signal: manual
    -- drags stop the auto-docking for this session.
    NS.Theme.Apply(filterFrame, function() sessionManualDock = true end)
  end

  local title = filterFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", 0, -6)
  title:SetWidth(248)
  title:SetJustifyH("CENTER")
  title:SetText("|cffffd100" .. l("filters_title", "Listing filters") .. "|r")

  local function F() return MDB().filters end
  local y = -34
  FilterCheckbox(filterFrame, "LFGSFilterEnable", l("filters_enable", "Enable filters"),
    16, y, function() return F().enabled == true end,
    function(v) F().enabled = v ApplyFiltersToList() end)
  y = y - 30
  filterFrame.sortBtn = CreateFrame("Button", nil, filterFrame, "UIPanelButtonTemplate")
  filterFrame.sortBtn:SetSize(216, 22)
  filterFrame.sortBtn:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", 16, y)
  local function PaintSortMode()
    local mode = MDB().sortMode or "blizzard"
    filterFrame.sortBtn:SetText(l("sort_mode_fmt", "Sort: %s"):format(SORT_LABEL[mode] or mode))
  end
  filterFrame.sortBtn:SetScript("OnClick", function()
    local db = MDB()
    local cur = db.sortMode or "blizzard"
    local nxt = "blizzard"
    for i, m in ipairs(SORT_MODES) do
      if m == cur then nxt = SORT_MODES[(i % #SORT_MODES) + 1] break end
    end
    db.sortMode = nxt
    PaintSortMode()
    ApplyFiltersToList()
  end)
  PaintSortMode()
  y = y - 30
  -- Dungeon selection: activities seen in the CURRENT search, multi-select
  -- via a dropdown (the card stays compact).
  filterFrame.dungeonBtn = CreateFrame("Button", nil, filterFrame, "UIPanelButtonTemplate")
  filterFrame.dungeonBtn:SetSize(216, 22)
  filterFrame.dungeonBtn:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", 16, y)
  local function PaintDungeonBtn()
    local acts = MDB().filters.activities or {}
    local n = 0
    for _ in pairs(acts) do n = n + 1 end
    filterFrame.dungeonBtn:SetText(n > 0
      and l("filters_dungeons_fmt", "Dungeons: %d picked"):format(n)
      or l("filters_dungeons_all", "Dungeons: All"))
  end
  local function HarvestActivities()
    -- Unique activities from the live search (verified shape: total, list).
    local out, seen = {}, {}
    local ids = nil
    if C_LFGList.GetSearchResults then
      local okR, list = pcall(C_LFGList.GetSearchResults)
      if okR and type(list) == "table" then ids = list
      elseif okR and type(list) == "number" then
        local okR2, _, list2 = pcall(C_LFGList.GetSearchResults)
        if okR2 and type(list2) == "table" then ids = list2 end
      end
    end
    for _, rid in ipairs(ids or {}) do
      local okI, info = pcall(C_LFGList.GetSearchResultInfo, rid)
      if okI and type(info) == "table" then
        local aid = info.activityID
        if (not aid) and type(info.activityIDs) == "table" then aid = info.activityIDs[1] end
        if aid and not seen[aid] then
          seen[aid] = true
          local name = tostring(aid)
          if C_LFGList.GetActivityInfoTable then
            local okA, ai = pcall(C_LFGList.GetActivityInfoTable, aid)
            if okA and type(ai) == "table" then
              name = ai.shortName or ai.fullName or name
            end
          end
          out[#out + 1] = { id = aid, name = name }
        end
      end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end
  filterFrame.dungeonBtn:SetScript("OnClick", function(self)
    local list = HarvestActivities()
    if #list == 0 then
      NS.Print(l("filters_dungeons_none", "No dungeons in the current search - run a search first."))
      return
    end
    if MenuUtil and MenuUtil.CreateContextMenu then
      MenuUtil.CreateContextMenu(self, function(_, root)
        root:CreateTitle(l("filters_dungeons", "Dungeons"))
        local okCB = pcall(function()
          root:CreateCheckbox(l("filters_dungeons_all", "All (clear selection)"),
            function() return false end,
            function()
              MDB().filters.activities = {}
              PaintDungeonBtn()
              ApplyFiltersToList()
            end)
        end)
        for _, act in ipairs(list) do
          pcall(function()
            root:CreateCheckbox(act.name,
              function() return (MDB().filters.activities or {})[act.id] == true end,
              function()
                local f = MDB().filters
                f.activities = f.activities or {}
                f.activities[act.id] = (not f.activities[act.id]) or nil
                PaintDungeonBtn()
                ApplyFiltersToList()
              end)
          end)
        end
      end)
    else
      -- Pre-MenuUtil fallback: cycle is pointless for 8 dungeons; just clear.
      MDB().filters.activities = {}
      PaintDungeonBtn()
      ApplyFiltersToList()
    end
  end)
  PaintDungeonBtn()
  y = y - 28
  local kl = filterFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  kl:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", 16, y)
  kl:SetJustifyH("LEFT")
  kl:SetText("|cffffd100" .. l("filters_keylevels", "Key levels") .. "|r  "
    .. "|cff888888" .. l("filters_levelhint", "(none = all)") .. "|r")
  y = y - 18
  for i = 2, 10 do
    LevelButton(filterFrame, i, 16 + (i - 2) * 25, y)
  end
  y = y - 26
  local nl = filterFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  nl:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", 16, y)
  nl:SetJustifyH("LEFT")
  nl:SetText("|cffffd100" .. l("filters_needs", "Still needs") .. "|r  |cff888888"
    .. l("filters_needshint", "(tick = must lack)") .. "|r")
  y = y - 18
  RoleChip(filterFrame, "tank", "T", 16, y)
  RoleChip(filterFrame, "healer", "H", 56, y)
  RoleChip(filterFrame, "dps", "D", 96, y)
  y = y - 26
  FilterNumBox(filterFrame, l("filters_maxage", "Max age (min)"), 16, y, 56,
    function() return F().maxAgeMin or 0 end, function(v) F().maxAgeMin = v end)
  y = y - 30
  FilterNumBox(filterFrame, l("filters_minscore", "Min leader score"), 16, y, 56,
    function() return F().minScore or 0 end, function(v) F().minScore = v end)
  y = y - 30
  FilterNumBox(filterFrame, l("filters_minmembers", "Min members"), 16, y, 56,
    function() return F().minMembers or 0 end, function(v) F().minMembers = v end)
  y = y - 30
  FilterNumBox(filterFrame, l("filters_minreqilvl", "Min ilvl req"), 16, y, 56,
    function() return F().minReqIlvl or 0 end, function(v) F().minReqIlvl = v end)
  y = y - 32
  FilterCheckbox(filterFrame, "LFGSFilterHideFull", l("filters_hidefull", "Hide full M+ groups (5/5)"),
    16, y, function() return F().hideFull == true end,
    function(v) F().hideFull = v ApplyFiltersToList() end)
  y = y - 26
  filterFrame.status = filterFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  filterFrame.status:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", 16, y)
  filterFrame.status:SetWidth(216)
  filterFrame.status:SetJustifyH("LEFT")

  UpdateFilterStatus(0, 0)
  RelayoutCard()
  -- Keep the dock slot current (other cards may attach later, e.g. the
  -- Raider.IO panel appearing after ours). Cheap scan, 1s cadence.
  filterFrame:SetScript("OnUpdate", function(self)
    if (GetTime() - (self._dockT or 0)) < 1 then return end
    self._dockT = GetTime()
    RelayoutCard()
  end)
end

-- Filters toggle checkbox on Blizzard's search panel (next to the category
-- label, where PGF puts its own toggle - the proven free spot).
local filtersButton
local function EnsureFiltersButton()
  if filtersButton then return end
  if not (LFGListFrame and LFGListFrame.SearchPanel) then return end
  local panel = LFGListFrame.SearchPanel
  local b = CreateFrame("CheckButton", "LFGSuiteFiltersButton", panel, "UICheckButtonTemplate")
  b:SetSize(26, 26)
  b:SetHitRectInsets(-2, -40, -2, -2)
  if b.Text then
    b.Text:SetText("|cffffd100" .. l("filters_btn", "Filters") .. "|r")
    b.Text:SetFontObject("GameFontHighlight")
    b.Text:SetWidth(60)
  end
  if panel.CategoryName then
    b:SetPoint("LEFT", panel.CategoryName, "RIGHT", -8, 0)
  else
    b:SetPoint("TOPLEFT", panel, "TOPLEFT", 40, 2)
  end
  b:SetChecked(not (MDB().filters.cardHidden == true))
  b:SetScript("OnClick", function(self)
    NS.ToggleBrowserFilters(self:GetChecked())
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("LFG Suite")
    GameTooltip:AddLine(l("filters_btn_tip", "Toggle the listing filter card."), 1, 1, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  filtersButton = b
end

function NS.ToggleBrowserFilters(state)
  -- The panel is a child of the Group Finder window; it only exists while
  -- that UI is loaded.
  if not PVEFrame then
    NS.Print(l("filters_nogf", "Open the Group Finder (Premade Groups) first."))
    return
  end
  BuildFilterPanel()
  if not filterFrame then return end
  if state == nil then state = not filterFrame:IsShown() end
  -- Remember the choice so re-opening the browser restores it.
  MDB().filters.cardHidden = (not state) or nil
  if state then ScheduleDecorateSafe() end
  filterFrame:SetShown(state)
  if state then RelayoutCard() end
  if filtersButton then filtersButton:SetChecked(state) end
end

NS.SlashHandlers.filters = function()
  NS.ToggleBrowserFilters()
end

-- ---------------------------------------------------------------------------
-- True results filtering + sorting: stash Blizzard's fresh results table
-- (post-hook on UpdateResultList), then swap SearchPanel.results with a
-- filtered/sorted copy and re-render via UpdateResults. Off = restore the
-- full list. Rows actually leave the list - no dimming.
-- ---------------------------------------------------------------------------

local fullResults = nil
local resultsHookInstalled = false

function ApplyFiltersToList()
  if not (LFGListFrame and LFGListFrame.SearchPanel) then return end
  if not fullResults then return end
  if type(LFGListSearchPanel_UpdateResults) ~= "function" then return end
  local panel = LFGListFrame.SearchPanel

  local out = {}
  if FiltersEnabled() then
    for _, resultID in ipairs(fullResults) do
      local okI, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
      -- Unreadable results always stay (never hide what we cannot parse).
      if not (okI and type(info) == "table") or not RowFilteredOut(info) then
        out[#out + 1] = resultID
      end
    end
  else
    for _, rid in ipairs(fullResults) do out[#out + 1] = rid end
  end

  -- Sorting (precompute keys; the comparator must not call APIs).
  local mode = MDB().sortMode or "blizzard"
  if mode ~= "blizzard" then
    local keyed = {}
    for _, rid in ipairs(out) do
      local age, level = 0, 0
      local okI, info = pcall(C_LFGList.GetSearchResultInfo, rid)
      if okI and type(info) == "table" then
        age = tonumber(info.age) or 0
        level = Util.ParseKeyLevel(Util.CleanKString((info.name or "") .. " " .. (info.comment or ""))) or 0
      end
      keyed[#keyed + 1] = { rid = rid, age = age, level = level }
    end
    if mode == "new" then
      table.sort(keyed, function(a, b)
        if a.age ~= b.age then return a.age < b.age end
        return a.rid < b.rid
      end)
    elseif mode == "old" then
      table.sort(keyed, function(a, b)
        if a.age ~= b.age then return a.age > b.age end
        return a.rid < b.rid
      end)
    else -- key
      table.sort(keyed, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return a.age < b.age
      end)
    end
    for i, k in ipairs(keyed) do out[i] = k.rid end
  end

  panel.results = out
  local apps = (type(panel.applications) == "table") and #panel.applications or 0
  panel.totalResults = #out + apps
  pcall(LFGListSearchPanel_UpdateResults, panel)
  UpdateFilterStatus(#out, #fullResults - #out)
  ScheduleDecorateSafe()
end

local function InstallResultsHook()
  if resultsHookInstalled then return true end
  if type(LFGListSearchPanel_UpdateResultList) ~= "function" then return false end
  local ok = pcall(hooksecurefunc, "LFGListSearchPanel_UpdateResultList", function(panelSelf)
    pcall(function()
      if type(panelSelf.results) == "table" then
        local copy = {}
        for _, rid in ipairs(panelSelf.results) do copy[#copy + 1] = rid end
        fullResults = copy
      end
      ApplyFiltersToList()
    end)
  end)
  if ok then resultsHookInstalled = true end
  return ok
end

local function DecorateRows()
  local dbg = NS._browserDebug
  if not (LFGListFrame and LFGListFrame.SearchPanel or GroupFinderFrame and GroupFinderFrame.SearchPanel) then return end
  if not (C_LFGList and C_LFGList.GetSearchResultInfo) then return end
  local buttons = {}
  CollectSearchButtons(buttons)
  dbg.frames = #buttons
  local withID, tagged, errors, filtered = 0, 0, 0, 0
  for _, b in ipairs(buttons) do
    local res = DecorateRow(b)
    if res == "tagged" or res == "id" then withID = withID + 1 end
    if res == "tagged" then tagged = tagged + 1 end
    if res == "err" then errors = errors + 1 end
    if b._lfgsFiltered then filtered = filtered + 1 end
    -- Double-click signup (own timestamp detection; no click re-registration).
    if MDB().doubleClick ~= false then
      InstallDoubleClick(b)
    end
  end
  dbg.withID, dbg.tagged, dbg.errors = withID, tagged, errors
  UpdateFilterStatus(withID, filtered)
end

local decoratePending
function ScheduleDecorate()
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

-- Listing tooltip enrichment: after Blizzard fills its tooltip, append a
-- group-inspect block (LFG Inspect-style): member names, armor-type
-- distribution (loot competition), ignored-player warnings, leader score.
-- Post-hook only - never touches how the tooltip is built.
local ARMOR_OF_CLASS = {
  MAGE = "cloth", PRIEST = "cloth", WARLOCK = "cloth",
  ROGUE = "leather", MONK = "leather", DRUID = "leather", DEMONHUNTER = "leather",
  HUNTER = "mail", SHAMAN = "mail", EVOKER = "mail",
  WARRIOR = "plate", PALADIN = "plate", DEATHKNIGHT = "plate",
}
local ARMOR_COLOR = {
  cloth = "|cffeeeeee", leather = "|cff55cc55",
  mail = "|cff55aaff", plate = "|cffffcc55",
}
local ARMOR_ORDER = { "plate", "mail", "leather", "cloth" }

-- Group-inspect tooltip block (LFG Inspect-inspired, our implementation):
-- hooking the tooltip BUILDER (LFGListUtil_SetSearchEntryTooltip) - the
-- OnEnter hook never fires reliably because rows share Blizzard handlers.
-- Adds: listing age, dungeon member roster (name/class/role/spec), raid
-- comp by role (Shift for raids unless set to always), armor distribution
-- with your own armor highlighted, ignore-list warnings, leader score.
local tooltipHookInstalled = false
local currentTooltip, currentResultID

local function BuildInspectBlock(tooltip, resultID)
  if not (tooltip and tooltip.AddLine) then return end
  if not (C_LFGList and C_LFGList.GetSearchResultInfo) then return end
  local okI, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
  if not (okI and type(info) == "table") then return end

  if info.age and type(info.age) == "number" then
    local m, s = math.floor(info.age / 60), math.floor(info.age % 60)
    tooltip:AddLine(" ")
    tooltip:AddLine(l("tt_listed_fmt", "Listed %dm %02ds ago"):format(m, s), 0.8, 0.8, 0.8)
  end

  -- Activity: raid vs dungeon decides roster vs comp.
  local activityID = info.activityID
  if (not activityID) and type(info.activityIDs) == "table" then
    activityID = info.activityIDs[1]
  end
  local isRaid
  if activityID and C_LFGList.GetActivityInfoTable then
    local okA, ai = pcall(C_LFGList.GetActivityInfoTable, activityID)
    if okA and type(ai) == "table" then
      isRaid = ai.isCurrentRaidActivity == true
    end
  end

  -- Ignore list (built per tooltip; cheap: usually tiny).
  local ignoredSet = {}
  if C_FriendList and C_FriendList.GetNumIgnores and C_FriendList.GetIgnoreName then
    local okN, n = pcall(C_FriendList.GetNumIgnores)
    if okN and type(n) == "number" then
      for i = 1, math.min(n, 100) do
        local okG, full = pcall(C_FriendList.GetIgnoreName, i)
        if okG and type(full) == "string" then
          ignoredSet[(full:match("^[^%-]+") or full):lower()] = true
        end
      end
    end
  end

  local nm = info.numMembers or info.memberCount or 0

  if isRaid then
    -- Raid comp: role-grouped class counts from Blizzard's member data.
    local counts
    if C_LFGList.GetSearchResultMemberCounts then
      local okC, c = pcall(C_LFGList.GetSearchResultMemberCounts, resultID)
      if okC and type(c) == "table" then counts = c end
    end
    local byRole = counts and counts.classesByRole
    if type(byRole) == "table" then
      local db = MDB()
      if db.inspectShiftOnly == true and not IsShiftKeyDown() then
        tooltip:AddLine(" ")
        tooltip:AddLine(l("tt_shift_hint", "<Hold Shift for group composition>"), 0.6, 0.6, 0.6)
      else
        tooltip:AddLine(" ")
        for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
          local roleClasses = byRole[role]
          if type(roleClasses) == "table" then
            local parts = {}
            for className, n2 in pairs(roleClasses) do
              if type(n2) == "number" and n2 > 0 then
                parts[#parts + 1] = Util.ClassColorize(className, className) .. (n2 > 1 and (" x" .. n2) or "")
              end
            end
            if #parts > 0 then
              table.sort(parts)
              tooltip:AddDoubleLine(role, table.concat(parts, "  "), 0.9, 0.9, 0.9, 1, 1, 1)
            end
          end
        end
        -- Armor counts, own armor highlighted.
        local armor = {}
        for className, n2 in pairs(counts) do
          if type(n2) == "number" and not tostring(className):find("REMAINING") then
            local a = ARMOR_OF_CLASS[className]
            if a then armor[a] = (armor[a] or 0) + n2 end
          end
        end
        local myArmor = ARMOR_OF_CLASS[select(2, UnitClass("player")) or ""]
        local bits = {}
        for _, a in ipairs(ARMOR_ORDER) do
          if armor[a] then
            local col = (a == myArmor) and "|cff33ff33" or (ARMOR_COLOR[a] or "")
            bits[#bits + 1] = col .. armor[a] .. " " .. a .. "|r"
          end
        end
        if #bits > 0 then
          tooltip:AddDoubleLine(l("tt_armor", "Armor"), table.concat(bits, "  "), 0.8, 0.85, 1, 1, 1, 1)
        end
      end
    end
  else
    -- Dungeon: full roster - name (class color, leader starred) + spec + role.
    local members = {}
    local getPlayerInfo = C_LFGList and C_LFGList.GetSearchResultPlayerInfo
    if type(getPlayerInfo) == "function" then
      for i = 1, math.min(nm, 40) do
        local okM, pi = pcall(getPlayerInfo, resultID, i)
        if okM and type(pi) == "table" then
          local mname = pi.name or pi.fullName
          if type(mname) == "string" and mname ~= "" then
            members[#members + 1] = {
              name = mname, class = pi.classFilename, role = pi.assignedRole,
              spec = pi.specName, leader = pi.isLeader == true,
            }
          end
        end
      end
    end
    if #members > 0 then
      local ROLE_TXT = {
        TANK = "|cff55aaff" .. l("role_tank", "Tank") .. "|r",
        HEALER = "|cff55ff55" .. l("role_heal", "Heal") .. "|r",
        DAMAGER = "|cffffcc55" .. l("role_dps", "DPS") .. "|r",
      }
      tooltip:AddLine(" ")
      for _, m in ipairs(members) do
        local who = Util.ClassColorize(m.class, Util.ShortName(m.name))
        if m.leader then who = "|cffffd100*|r" .. who end
        if ignoredSet[m.name:lower()] then
          who = who .. "  |cffff4444" .. l("tt_ignored_short", "IGNORED") .. "|r"
        end
        local detail = {}
        if m.spec and m.spec ~= "" then detail[#detail + 1] = m.spec end
        if m.role then detail[#detail + 1] = ROLE_TXT[m.role] or m.role end
        if #detail > 0 then
          who = who .. " |cff888888(|r" .. table.concat(detail, " ") .. "|cff888888)|r"
        end
        tooltip:AddLine(who, 1, 1, 1, true)
      end
      local sc = GetLeaderScore(info)
      if sc then
        tooltip:AddDoubleLine(l("score_lbl", "score"), ColorScore(sc), 0.8, 0.85, 1, 1, 1, 1)
      end
    end
  end
  tooltip:Show()
end

local function InstallTooltipHook()
  if tooltipHookInstalled then return true end
  if type(LFGListUtil_SetSearchEntryTooltip) ~= "function" then return false end
  local ok = pcall(hooksecurefunc, "LFGListUtil_SetSearchEntryTooltip", function(tooltip, resultID)
    if not resultID or not tooltip:IsVisible() then
      currentTooltip, currentResultID = nil, nil
      return
    end
    currentTooltip, currentResultID = tooltip, resultID
    local okB, errB = pcall(BuildInspectBlock, tooltip, resultID)
    if not okB and NS.ModuleError then NS.ModuleError({ key = "browser" }, errB) end
  end)
  if ok then
    tooltipHookInstalled = true
    -- Shift toggles the raid comp: rebuild the tooltip so the block swaps.
    local f = CreateFrame("Frame")
    pcall(f.RegisterEvent, f, "MODIFIER_STATE_CHANGED")
    f:SetScript("OnEvent", function(_, _, key, state)
      if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
      if currentTooltip and currentResultID and currentTooltip:IsVisible() then
        local owner = currentTooltip:GetOwner()
        if owner and owner.resultID == currentResultID then
          currentTooltip:ClearLines()
          pcall(LFGListUtil_SetSearchEntryTooltip, currentTooltip, currentResultID)
        else
          currentTooltip, currentResultID = nil, nil
        end
      end
    end)
  end
  return ok
end

-- Role pre-select on Blizzard's signup dialog: when it opens for a listing,
-- tick the roles we remembered from previous signups. Checkbox field names
-- probed defensively - a rename means "no pre-select", never an error.
local dialogHookInstalled = false
local function InstallDialogHook()
  if dialogHookInstalled then return true end
  local hooked = false
  for _, fnName in ipairs({ "LFGListApplicationDialog_Show", "LFGListApplicationPopup_Show" }) do
    if type(_G[fnName]) == "function" then
      local ok = pcall(hooksecurefunc, fnName, function(self)
        pcall(function()
          local db = MDB()
          local roles = (db.rememberRoles ~= false) and db.roles or nil
          if not roles or not (roles.tank or roles.healer or roles.dps) then return end
          local sets = {
            { self.TankCheckBox, roles.tank },
            { self.HealerCheckBox or self.HealerCheckButton, roles.healer },
            { self.DamageCheckBox or self.DpsCheckBox or self.DpsCheckButton, roles.dps },
          }
          for _, s in ipairs(sets) do
            if s[1] and s[1].SetChecked then s[1]:SetChecked(s[2] and true or false) end
          end
        end)
      end)
      if ok then hooked = true end
    end
  end
  dialogHookInstalled = hooked
  return hooked
end

local function EnsureHooks()
  InstallRowUpdateHook()
  InstallTooltipHook()
  InstallDialogHook()
  InstallResultsHook()
  if hooksInstalled then return end
  local lfg = LFGListFrame or GroupFinderFrame
  if type(lfg) ~= "table" or type(lfg.HookScript) ~= "function" then return end
  local ok = pcall(lfg.HookScript, lfg, "OnShow", function()
    -- The Group Finder UI just loaded: now the row/tooltip hooks can grab
    -- Blizzard's globals (they do not exist before this).
    EnsureHooks()
    ScheduleDecorate()
    -- Filter card + toggle button come up with the browser unless the user
    -- closed the card on purpose.
    EnsureFiltersButton()
    if MDB().filters.cardHidden ~= true then
      NS.ToggleBrowserFilters(true)
    end
  end)
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
    local db = MDB()
    -- One-time migration: the inspect block shipped Shift-only, but plain
    -- hover is the expected (LFG Inspect) behavior - flip stored defaults.
    if db._inspectHoverV2 ~= true then
      db._inspectHoverV2 = true
      if db.inspectShiftOnly == true then db.inspectShiftOnly = false end
    end
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
    ctx.AddCB(l("opt_inspectshift", "Listing group details (members/armor) only while holding Shift"),
      function() return MDB().inspectShiftOnly ~= false end,
      function(v) MDB().inspectShiftOnly = v end)
  end,
}
NS.RegisterModule(M)

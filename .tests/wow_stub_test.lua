-- WoW environment stub harness: loads the addon files in .toc order and
-- drives the browser decoration chain end-to-end.
-- Run: lua .tests/wow_stub_test.lua   (from the repo root)

local function assertEq(actual, expected, label)
  if actual ~= expected then
    error(("FAIL %s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)), 0)
  end
end

-- ---------------------------------------------------------------------------
-- WoW API stubs
-- ---------------------------------------------------------------------------

local timers = {}
C_Timer = {
  After = function(delay, fn) timers[#timers + 1] = fn end,
  NewTimer = function(_, fn)
    local t = { fn = fn }
    function t:Cancel() end
    return t
  end,
}
local function flushTimers()
  local n = #timers
  for i = 1, n do timers[i]() end
  for i = n, 1, -1 do timers[i] = nil end
end

-- Callable stub table: any property is another callable stub; any call is a
-- no-op returning nil. Covers the Blizzard widget surface we touch.
local stubMT
stubMT = {
  __call = function() return setmetatable({}, stubMT) end,
  __index = function(t, k)
    local v = setmetatable({}, stubMT)
    rawset(t, k, v)
    return v
  end,
}
local function stub() return setmetatable({}, stubMT) end

local created = {}
CreateFrame = function(kind, name, parent, template)
  local f = stub()
  if name then created[name] = f end
  return f
end

-- Font strings record their text so we can assert on rendered tags.
local fontStrings = {}
local realCreateFrame = CreateFrame
CreateFrame = function(kind, name, parent, template)
  local f = realCreateFrame(kind, name, parent, template)
  f.CreateFontString = function()
    local fs = stub()
    rawset(fs, "text", false)
    fs.SetText = function(_, txt) rawset(fs, "text", tostring(txt)) end
    fontStrings[#fontStrings + 1] = fs
    return fs
  end
  return f
end

hooksecurefunc = function(target, name, fn)
  if type(target) == "table" then
    local orig = target[name]
    target[name] = function(...)
      local r = { orig and orig(...) }
      fn(...)
      return table.unpack(r)
    end
  end
  -- global-name hooks: no-op in the harness (nothing calls the originals)
  return true
end

function print(...) _G.__printed = _G.__printed or {}; _G.__printed[#_G.__printed + 1] = table.concat({ ... }, " ") end
function wipe(t) for k in pairs(t) do t[k] = nil end end
function tinsert(t, v) t[#t + 1] = v end
function strtrim(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
function strsplit(sep, s, n)
  local out = {}
  local init = 1
  while true do
    local a, b = s:find(sep, init, true)
    if not a or (n and #out == n - 1) then out[#out + 1] = s:sub(init) break end
    out[#out + 1] = s:sub(init, a - 1)
    init = b + 1
  end
  return table.unpack(out)
end

SLASH_LFGSUITE1 = nil
SlashCmdList = {}
UISpecialFrames = {}
Settings = { RegisterCanvasLayoutCategory = function() return stub() end, RegisterAddOnCategory = function() end }
Minimap = stub()
GameTooltip = stub()
UIParent = stub()
RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { WrapTextInColorCode = function(_, t) return t end } end })
GetRealmName = function() return "TestRealm" end
UnitName = function(unit) return unit == "player" and "Tester" or nil end
UnitClass = function() return "MAGE", "MAGE" end
GetTime = function() return os.clock() end
time = os.time
date = os.date
math.random = math.random

C_AddOns = { IsAddOnLoaded = function() return false end, GetAddOnMetadata = function() return "0.1.5" end }
C_ChatInfo = { RegisterAddonMessagePrefix = function() end, SendAddonMessage = function() end }
C_ChallengeMode = {
  GetDeathCount = function() return 0 end,
  GetMapUIInfo = function() return "Dungeon", nil, nil, 1800 end,
  GetDungeonScoreRarityColor = function()
    return { r = 1, g = 0.5, b = 0.1, colorStr = "ffff8033",
      WrapTextInColorCode = function(_, t) return "|cff" .. "ff8033" .. t .. "|r" end }
  end,
}
C_MythicPlus = {
  GetCurrentAffixes = function() return { { id = 9, name = "Tyrannical", description = "" } } end,
  GetOwnedKeystoneLevel = function() return 7 end,
  GetOwnedKeystoneChallengeMapID = function() return 501 end,
}
C_Container = { GetContainerNumSlots = function() return 0 end }
C_Texture = {}
TooltipDataProcessor = nil

local SEARCH_INFO = {
  [42] = {
    name = "|Ku5|kM+ 7 Mechagon|Ku5|k", comment = "fast run", leaderName = "Leader-TestRealm",
    partyGUID = "Player-9999-ABCDEF",
    age = 120, leaderOverallDungeonScore = 2513.4,
  },
  [43] = {
    name = "Freehold boosting", comment = "", leaderName = "Friend-TestRealm",
    partyGUID = "Player-9999-FFFFFF",
    age = 45, leaderOverallDungeonScore = 1800,
  },
}
C_LFGList = {
  GetSearchResultInfo = function(id) return SEARCH_INFO[id] end,
  HasSearchResultInfo = function(id) return SEARCH_INFO[id] ~= nil end,
  GetApplicationInfo = function() return nil, "none" end,
  ApplyToGroup = function() end,
}
-- Realm per GUID: row 42 leader is cross-realm (long name -> truncated),
-- row 43 is ours.
GetPlayerInfoByGUID = function(guid)
  if guid == "Player-9999-FFFFFF" then return "Druid", "DRUID", 3, 3, 2, "Friend", "TestRealm" end
  return "Mage", "MAGE", 2, 2, 2, "Leader", "Twisting Nether"
end

-- ---------------------------------------------------------------------------
-- Load the addon in .toc order
-- ---------------------------------------------------------------------------

local files = {
  "Locales/enUS.lua", "Core.lua", "Services.lua",
  "Modules/Keystones.lua", "Modules/Browser.lua", "Modules/Queue.lua",
  "Modules/Applicants.lua", "Modules/ApplicantsUI.lua", "Modules/Timer.lua",
  "Modules/Forces.lua", "Modules/RunSummary.lua", "Modules/Loot.lua",
  "Modules/Roster.lua", "Options.lua",
}
for _, f in ipairs(files) do
  local chunk, err = loadfile(f)
  if not chunk then error("cannot load " .. f .. ": " .. tostring(err), 0) end
  chunk("LFGSuite")
end

local NS = LFGSuite
assertEq(#NS.Modules, 9, "module count")
assertEq(NS.BUILD, 7, "build number")

-- Boot via ADDON_LOADED
LFGSuiteDB = nil
local eventHandler
local ef = created[""] -- Core's bus frame is anonymous
-- Core stored its handler via SetScript on its frame; grab from any stub that got one.
-- Simpler: dispatch through our own capture below.
local busFrame = {}
busFrame.RegisterEvent = function() return true end
busFrame.UnregisterEvent = function() return true end
busFrame.SetScript = function(_, handler) eventHandler = handler end
busFrame.HookScript = function() return true end

-- Re-dispatch boot through the module table instead: find browser def.
local browserDef
for _, def in ipairs(NS.Modules) do
  if def.key == "browser" then browserDef = def end
end
assert(browserDef, "browser module registered")

-- Expected events: the three REAL Group Finder events, plural-UPDATED gone.
local evs = {}
for _, e in ipairs(browserDef.events) do evs[e] = true end
assert(evs["LFG_LIST_SEARCH_RESULTS_RECEIVED"], "browser listens to RESULTS_RECEIVED")
assert(evs["LFG_LIST_SEARCH_RESULT_UPDATED"], "browser listens to RESULT_UPDATED")
assert(evs["LFG_LIST_UPDATE_SEARCH_RESULTS"], "browser listens to UPDATE_SEARCH_RESULTS")
assert(not evs["LFG_LIST_SEARCH_RESULTS_UPDATED"], "bogus plural UPDATED event removed")

-- Manual boot: DB + seeds + OnLoads (mirrors Core.Boot without the UI frame).
do
  LFGSuiteDB = { modules = {}, enabled = true, showMinimapButton = false }
  NS.db = LFGSuiteDB
  for _, def in ipairs(NS.Modules) do
    if NS.db.modules[def.key] == nil then
      NS.db.modules[def.key] = { enabled = def.defaultEnabled }
    end
    if def.OnLoad then
      local ok, err = pcall(def.OnLoad, def)
      if not ok then error("OnLoad " .. def.key .. ": " .. tostring(err), 0) end
    end
  end
end

-- Fake Group Finder state: panel + ScrollBox with two visible rows. Rows are
-- PLAIN tables (unset fields read as nil, like a real widget).
local function makeRow(resultID)
  -- Playstyle/DataDisplay: template children the tag anchors against.
  local row = { resultID = resultID, DataDisplay = {}, Playstyle = {} }
  function row.CreateFontString()
    local fs -- pre-declare so the closures below capture THIS local
    fs = {
      -- Record SetPoint args so the harness can assert the anchor target.
      SetPoint = function(_, point, relFrame, relPoint)
        fs.anchor = { point = point, relFrame = relFrame, relPoint = relPoint }
      end,
      SetJustifyH = function(_, j) fs.justify = j end,
      Show = function() end,
      Hide = function() end,
    }
    fs.SetText = function(_, txt) fs.text = tostring(txt) end
    fontStrings[#fontStrings + 1] = fs
    return fs
  end
  function row.HookScript() return true end
  return row
end
local row = makeRow(42)
local row2 = makeRow(43)
local scrollBox = { GetFrames = function() return { row, row2 } end }
local searchPanel = { ScrollBox = scrollBox }
_G.LFGListFrame = { SearchPanel = searchPanel }

-- Simulate the real event reaching the module's OnEvent.
local ok, err = pcall(browserDef.OnEvent, browserDef, "LFG_LIST_SEARCH_RESULTS_RECEIVED")
assert(ok, "OnEvent ran: " .. tostring(err))
assertEq(NS._browserDebug.lastEvent, "LFG_LIST_SEARCH_RESULTS_RECEIVED", "lastEvent recorded")

flushTimers() -- run the deferred DecorateRows

local dbg = NS._browserDebug
assertEq(dbg.strategy, "scrollbox", "row collection strategy")
assertEq(dbg.frames, 2, "rows found")
assertEq(dbg.withID, 2, "rows had result IDs")
assertEq(dbg.tagged, 2, "rows got tagged")

local tagText, tagText2, tagFS
for _, fs in ipairs(fontStrings) do
  if type(fs.text) == "string" then print("FS: [" .. fs.text .. "]") end
  if type(fs.text) == "string" and fs.text:find("2513", 1, true) then tagText, tagFS = fs.text, fs end
  if type(fs.text) == "string" and fs.text:find("1800", 1, true) then tagText2 = fs.text end
end
assert(tagText, "row 42 tag rendered")
assert(tagText:find("2m", 1, true), "age tag present")
assert(tagText:find("%+7"), "key level tag present")
assert(tagText:find("TwistingN", 1, true), "cross-realm leader realm tag present")
assert(not tagText:find("TwistingNether"), "long realm truncated")
assert(not tagText:find("|K"), "kstring stripped from tag")
assert(tagText:find("ff8033", 1, true), "score uses rarity color")
assert(tagText2, "row 43 tag rendered")
assert(tagText2:find("45s", 1, true), "row 43 age tag present")
assert(not tagText2:find("TestRealm", 1, true), "own-realm leader realm suppressed")
assertEq(tagFS.anchor.point, "LEFT", "tag LEFT anchor")
assertEq(tagFS.anchor.relFrame, row.Playstyle, "tag anchored after Playstyle text")
assertEq(tagFS.anchor.relPoint, "RIGHT", "tag anchored to Playstyle RIGHT")
assertEq(tagFS.justify, "LEFT", "tag left-justified")

-- The harness replaces print(); replay the captured lines to stdout.
print("ALL CHECKS PASSED")
print("tag text: " .. tostring(tagText))
local captured = _G.__printed or {}
print = function(...) io.write(table.concat({ ... }, " "), "\n") end
for _, line in ipairs(captured) do print(line) end

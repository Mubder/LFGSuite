-- LFG Suite - Services.lua
-- Shared services consumed by every module:
--   NS.Util    parsing/format helpers (ported know-how from LFGAlert, MIT)
--   NS.Affixes weekly M+ affix rotation
--   NS.Comms   "LFGS" keystone-sync protocol (own v1; interop listeners later)
-- Loaded after Core.lua, before Modules/ (see .toc).

local ADDON_NAME = ...
LFGSuite = LFGSuite or {}
local NS = LFGSuite

-- Where the Browser module records listings we applied to; the Queue module
-- reads them for the "what did I queue for" banner. Shared, session-only.
NS.AppliedListings = NS.AppliedListings or {}

-- ---------------------------------------------------------------------------
-- Util
-- ---------------------------------------------------------------------------

local Util = NS.Util or {}

function Util.ClassColorize(classFileName, text)
  if classFileName and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFileName] then
    local c = RAID_CLASS_COLORS[classFileName]
    if c.WrapTextInColorCode then
      return c:WrapTextInColorCode(text)
    elseif c.colorStr then
      return "|c" .. c.colorStr .. text .. "|r"
    end
  end
  return text
end

function Util.ShortName(fullName)
  if not fullName then return "?" end
  local bare = strsplit("-", fullName, 2)
  return bare or fullName
end

-- "+7" / "M+7" / "7+" style key level from listing titles. Range 2..40.
function Util.ParseKeyLevel(text)
  if not text or text == "" then return nil end
  local patterns = { "%+(%d+)", "[Mm]%+%s*(%d+)", "[Mm]%s+(%d+)", "(%d+)%s*%+" }
  for _, pat in ipairs(patterns) do
    local n = tonumber(text:match(pat))
    if n and n >= 2 and n <= 40 then return n end
  end
  return nil
end

-- First-letter abbreviation: "Altar of Fangs" -> "AOF", "Freehold" -> "FRE".
function Util.AbbrevDungeonName(name)
  if not name or name == "" then return nil end
  local base = name:gsub("%s*%([^%)]*%)%s*", ""):gsub("^%s*[Tt]he%s+", "")
  local words = {}
  for w in base:gmatch("[%a]+") do words[#words + 1] = w end
  if #words == 0 then return nil end
  if #words == 1 then
    return words[1]:sub(1, 3):upper()
  end
  local ab = ""
  for _, w in ipairs(words) do ab = ab .. w:sub(1, 1):upper() end
  return ab ~= "" and ab or nil
end

-- Midnight wraps listing/applicant text in kstrings ("|Ku5|k") addons cannot
-- read. Strip them before parsing or displaying.
function Util.CleanKString(s)
  if type(s) ~= "string" then return s end
  local cleaned = s:gsub("|K.-|k", "")
  if cleaned:match("^%s*$") then return "" end
  return cleaned
end

-- Dungeon name for a challenge (keystone) mapID; returns which lookup worked.
function Util.GetChallengeMapName(mapID)
  if not mapID or not C_ChallengeMode then return nil end
  for _, fn in ipairs({ "GetMapInfo", "GetMapUIInfo" }) do
    local f = C_ChallengeMode[fn]
    if type(f) == "function" then
      local ok, name = pcall(f, mapID)
      if ok and type(name) == "string" and name ~= "" then return name, fn end
    end
  end
  return nil
end

-- "45s" / "3m" / "2h 05m" / "4d" from seconds.
function Util.FormatAge(seconds)
  if type(seconds) ~= "number" or seconds < 0 then return nil end
  if seconds < 60 then return string.format("%ds", seconds) end
  if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
  if seconds < 86400 then
    local h, m = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
    return string.format("%dh %02dm", h, m)
  end
  return string.format("%dd", math.floor(seconds / 86400))
end

NS.Util = Util

-- ---------------------------------------------------------------------------
-- Affixes (weekly rotation)
-- ---------------------------------------------------------------------------

local Affixes = NS.Affixes or { list = {} }

function Affixes.Refresh()
  if not (C_MythicPlus and C_MythicPlus.GetCurrentAffixes) then return end
  local ok, affixes = pcall(C_MythicPlus.GetCurrentAffixes)
  if ok and type(affixes) == "table" then
    local t = {}
    for _, a in ipairs(affixes) do
      if type(a) == "table" and a.id then
        t[#t + 1] = { id = a.id, name = a.name, desc = a.description }
      end
    end
    Affixes.list = t
  end
end

function Affixes.Summary()
  local names = {}
  for _, a in ipairs(Affixes.list) do
    if a.name and a.name ~= "" then names[#names + 1] = a.name end
  end
  if #names == 0 then return nil end
  return table.concat(names, " • ")
end

NS.Affixes = Affixes

-- ---------------------------------------------------------------------------
-- Comms - "LFGS" keystone sync protocol v1
--   K1:<level>:<mapID>:<class>   broadcast own keystone (PARTY/RAID/GUILD)
--   KR                           please re-broadcast (PARTY/RAID/GUILD)
-- Handlers are installed by the Keystones module (NS.OnKeystoneBroadcast /
-- NS.OnKeystoneRequest) so the service stays data-only.
-- ---------------------------------------------------------------------------

local Comms = NS.Comms or {}
Comms.PREFIX = "LFGS"

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
  pcall(C_ChatInfo.RegisterAddonMessagePrefix, Comms.PREFIX)
end

local function NormalizeSender(sender)
  if not sender or sender == "" then return nil end
  if sender:find("-", 1, true) then return sender end
  return sender .. "-" .. GetRealmName()
end

function Comms.SendKeystone(channel, level, mapID, class)
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
  local msg = string.format("K1:%d:%d:%s", tonumber(level) or 0, tonumber(mapID) or 0, class or "")
  pcall(C_ChatInfo.SendAddonMessage, Comms.PREFIX, msg, channel)
end

function Comms.SendRequest(channel)
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
  pcall(C_ChatInfo.SendAddonMessage, Comms.PREFIX, "KR", channel)
end

-- Route a CHAT_MSG_ADDON. Returns true when the message was ours.
function Comms.OnMessage(prefix, msg, channel, sender)
  if prefix ~= Comms.PREFIX then return false end
  sender = NormalizeSender(sender)
  if not sender then return false end
  channel = (channel == "RAID") and "RAID" or (channel == "GUILD" and "GUILD" or "PARTY")
  if type(msg) == "string" and msg == "KR" then
    if NS.OnKeystoneRequest then
      local ok, err = pcall(NS.OnKeystoneRequest, channel, sender)
      if not ok and NS.ModuleError then NS.ModuleError({ key = "comms" }, err) end
    end
    return true
  end
  local lvlStr, mapStr, class = msg:match("^K1:(%d+):(%d+):(%a*)")
  local level, mapID = tonumber(lvlStr), tonumber(mapStr)
  if level and mapID and level >= 2 and level <= 40 then
    if NS.OnKeystoneBroadcast then
      local ok, err = pcall(NS.OnKeystoneBroadcast, channel, sender, level, mapID, class ~= "" and class or nil)
      if not ok and NS.ModuleError then NS.ModuleError({ key = "comms" }, err) end
    end
    return true
  end
  return false
end

NS.Comms = Comms

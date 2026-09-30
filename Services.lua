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

-- UTF-8 safe truncation with ellipsis: "Twisting Nether" -> "Twisting N…".
function Util.Trunc(s, n)
  if not s or s == "" or #s <= n then return s end
  local cut = s:sub(1, n - 1)
  cut = cut:gsub("[\194-\244][\128-\191]*$", "") -- don't cut mid multi-byte char
  return cut .. "…"
end

-- Dungeon name for a challenge (keystone) mapID; returns which lookup worked.
-- Results are cached per session: callers (keystone window refresh on every
-- comms message, roster, timer) resolve the same handful of mapIDs over and
-- over, and each lookup is a protected pcall pair. Names never change at
-- runtime, so the cache needs no invalidation.
local mapNameCache = {}
function Util.GetChallengeMapName(mapID)
  if not mapID or not C_ChallengeMode then return nil end
  local cached = mapNameCache[mapID]
  if cached ~= nil then
    if cached == false then return nil end
    return cached[1], cached[2]
  end
  for _, fn in ipairs({ "GetMapInfo", "GetMapUIInfo" }) do
    local f = C_ChallengeMode[fn]
    if type(f) == "function" then
      local ok, name = pcall(f, mapID)
      if ok and type(name) == "string" and name ~= "" then
        mapNameCache[mapID] = { name, fn }
        return name, fn
      end
    end
  end
  mapNameCache[mapID] = false
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

-- ---------------------------------------------------------------------------
-- Theme - the shared look for module windows (pilot: Timer). Every module
-- window gets: a light transparent block background, a slightly stronger
-- grabbable header strip, and custom gradient bars. Opacity is one account
-- wide setting (settings panel slider or /lfgs theme bg <0-100>).
-- ---------------------------------------------------------------------------

local Theme = NS.Theme or { frames = {} }
NS.Theme = Theme

local L = NS.L or {}
local function tl(key, fallback) return L[key] or fallback end

local function ThemeDB()
  NS.db = NS.db or {}
  if type(NS.db.theme) ~= "table" then NS.db.theme = {} end
  if NS.db.theme.bgOpacity == nil then NS.db.theme.bgOpacity = 0.35 end
  return NS.db.theme
end

-- Repaint one themed frame at the current opacity.
function Theme.Paint(frame)
  local t = frame and frame._lfgsTheme
  if not t then return end
  local op = ThemeDB().bgOpacity
  t.bg:SetColorTexture(0.05, 0.07, 0.12, op)
  t.header:SetColorTexture(0.10, 0.15, 0.24, math.min(0.9, op + 0.20))
end

-- Attach block background + header strip to a frame (idempotent). The
-- header strip is the grab affordance: it is ALWAYS draggable (onMove, if
-- given, runs after a drag to persist the position); the frame body stays
-- click-through so stray clicks mid-run neither move the window nor get
-- swallowed.
function Theme.Apply(frame, onMove)
  if not frame then return nil end
  if not frame._lfgsTheme then
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetDrawLayer("BACKGROUND", -8)
    local header = frame:CreateTexture(nil, "BACKGROUND")
    header:SetHeight(24)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT")
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT")
    header:SetDrawLayer("BACKGROUND", -7)
    local accent = frame:CreateTexture(nil, "BACKGROUND")
    accent:SetHeight(1)
    accent:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    accent:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
    accent:SetColorTexture(0.85, 0.68, 0.3, 0.55)
    accent:SetDrawLayer("BACKGROUND", -6)
    local drag = CreateFrame("Frame", nil, frame)
    drag:SetHeight(24)
    drag:SetPoint("TOPLEFT", frame, "TOPLEFT")
    drag:SetPoint("TOPRIGHT", frame, "TOPRIGHT")
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function()
      if frame.IsMovable and frame:IsMovable() then frame:StartMoving() end
    end)
    drag:SetScript("OnDragStop", function()
      frame:StopMovingOrSizing()
      if type(onMove) == "function" then pcall(onMove, frame) end
    end)
    frame._lfgsTheme = { bg = bg, header = header, accent = accent, drag = drag }
    Theme.frames[#Theme.frames + 1] = frame
  end
  Theme.Paint(frame)
  return frame._lfgsTheme
end

function Theme.RefreshAll()
  for _, f in ipairs(Theme.frames) do Theme.Paint(f) end
end

-- Custom progress bar: gradient fill (bright leading edge -> base color),
-- dark track, optional pulse flash (overtime). Returns a Frame with
-- :Set(fraction, r, g, b) and :SetPulse(bool). Ticks can be textured onto
-- it like any frame.
function Theme.CreateBar(parent, width, height)
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetSize(width, height)
  local track = bar:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(0.05, 0.07, 0.12, 0.55)
  local fill = bar:CreateTexture(nil, "ARTWORK")
  fill:SetHeight(height)
  fill:SetPoint("TOPLEFT", bar, "TOPLEFT")
  fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT")
  fill:SetWidth(0)
  local function PaintFill(r, g, b)
    local ok = pcall(function()
      fill:SetGradient("HORIZONTAL",
        CreateColor(math.min(1, r * 1.35 + 0.08), math.min(1, g * 1.25 + 0.08),
          math.min(1, b * 1.25 + 0.10), 1),
        CreateColor(r, g, b, 1))
    end)
    if not ok then fill:SetColorTexture(r, g, b, 1) end
  end
  bar._pulse = false
  bar:SetScript("OnUpdate", function(self)
    if not self._pulse then return end
    fill:SetAlpha(0.65 + 0.35 * math.abs(math.sin(GetTime() * 4)))
  end)
  function bar:Set(frac, r, g, b)
    frac = math.max(0, math.min(1, frac or 0))
    fill:SetWidth(math.max(1, width * frac))
    PaintFill(r or 1, g or 1, b or 1)
    if not self._pulse then fill:SetAlpha(1) end
  end
  function bar:SetPulse(on)
    self._pulse = on and true or false
    if not self._pulse then fill:SetAlpha(1) end
  end
  return bar
end

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.theme = function(rest)
  local cmd, arg = rest:match("^(%S*)%s*(.-)$")
  if cmd == "bg" then
    local v = tonumber(arg)
    if v and v >= 0 and v <= 100 then
      ThemeDB().bgOpacity = v / 100
      Theme.RefreshAll()
      NS.Print(string.format(tl("theme_bg_fmt", "Background opacity set to %d%%."), v))
    else
      NS.Print(tl("theme_bg_usage", "Usage: /lfgs theme bg <0-100>"))
    end
  else
    NS.Print("/lfgs theme bg <0-100> - module background opacity")
  end
end

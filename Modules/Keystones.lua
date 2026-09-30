-- LFG Suite - Modules/Keystones.lua
-- PHASE 1. Absorbs: Astral Keys, Better Keystone Display, MKS Helper,
-- Mythic Plus Tweaks (keystone sync + affixes).
--
-- Feature checklist:
--   [x] Own keystone tracking (C_MythicPlus.GetOwnedKeystone*)
--   [x] Keystone window: own key + weekly affixes + one merged list of
--       party (synced) / alt / guild keystones, sortable
--   [x] Comms: "LFGS" protocol broadcast + request (party/raid/guild)
--   [x] Alt keys: recorded per character, persisted
--   [x] Guild/friends keystone registry (comms, pruned after 14 days)
--   [x] Bag keystone tooltip: dungeon name + level + weekly affixes
--   [x] Lindormi panel: auto-open the key window at the keystone NPC
--   [x] Announce own key to party/guild (/lfgs keys announce)
--   [x] Auto-insert keystone at the pedestal (default OFF + /lfgs keys insert)
--   [x] Reroll advisor: /lfgs keys reroll (timed +1/+2/+3, new random
--       dungeon; untimed -1) for self + synced party keys, plus an
--       automatic notice when your own key changes after a run
--   [x] Improved keystone chat-link rendering ("The Necrotic Wake +7",
--       clickable) + announce sends the real keystone link
--   [x] Listen-only interop with LibOpenRaid (LRS/LRS_LOGGED keystone
--       broadcasts feed the party/guild registry); Astral Keys / Angry
--       Keystones intentionally not sniffed (ARR sources - not read)

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local Util = NS.Util
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

local KEYS_DEFAULTS = {
  guildSync = true,  -- broadcast + listen on GUILD
  autoInsert = false,
  lindormi = true,
  sort = "level",    -- level | name | age
  guild = {},        -- [fullName] = { level, mapID, class, t }
  alts = {},         -- [fullName] = { level, mapID, class, t }
}

local KEY_NPCS = { ["Lindormi"] = true } -- Midnight keystone NPC
local ROWS_VISIBLE, ROW_H = 10, 20

local ownLevel, ownMapID
local party = {} -- session: [fullName] = { level, mapID, class, t }
local weAutoOpened = false
local tooltipHooked, receptacleFrame, lastReplyT
local rosterSyncPending = false -- GROUP_ROSTER_UPDATE arrives in bursts; one delayed sync max

local function MDB() return NS.EnsureModuleDB("keystones", KEYS_DEFAULTS) end

local function MyFullName()
  return (UnitName("player") or "?") .. "-" .. GetRealmName()
end

local function NormalizeFullName(n)
  if not n or n == "" then return nil end
  if n:find("-", 1, true) then return n end
  return n .. "-" .. GetRealmName()
end

-- ---------------------------------------------------------------------------
-- Own keystone
-- ---------------------------------------------------------------------------

local function ProbeOwnKey()
  if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel) then return nil end
  local okL, lvl = pcall(C_MythicPlus.GetOwnedKeystoneLevel)
  local okM, mapID = pcall(C_MythicPlus.GetOwnedKeystoneChallengeMapID)
  if okL and okM and lvl and mapID and lvl >= 2 then return lvl, mapID end
end

-- "|Hkeystone:itemID:mapID:level:..." -> level, mapID
local function ParseKeystoneLink(link)
  local payload = link:match("|Hkeystone:(.-)|h")
  if not payload then return nil end
  local _, mapStr, lvlStr = strsplit(":", payload)
  local mapID, level = tonumber(mapStr), tonumber(lvlStr)
  if mapID and level and level >= 2 and level <= 40 then return level, mapID end
  return nil
end

-- Fallback: the owned-keystone APIs can report nothing while a freshly looted
-- key is still settling; the bag link is always authoritative.
local function ProbeOwnKeyFromBags()
  if not (C_Container and C_Container.GetContainerItemLink) then return nil end
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    local okN, slots = pcall(C_Container.GetContainerNumSlots, bag)
    if okN and type(slots) == "number" and slots > 0 then
      -- Clamp: a misbehaving slot count must not become a bag-scan freeze.
      for slot = 1, math.min(slots, 64) do
        local okL, link = pcall(C_Container.GetContainerItemLink, bag, slot)
        if okL and type(link) == "string" and link:find("|Hkeystone:", 1, true) then
          local level, mapID = ParseKeystoneLink(link)
          if level then return level, mapID end
        end
      end
    end
  end
end

local function RefreshOwn()
  local lvl, mapID = ProbeOwnKey()
  if not lvl then lvl, mapID = ProbeOwnKeyFromBags() end
  local changed = (lvl ~= ownLevel) or (mapID ~= ownMapID)
  ownLevel, ownMapID = lvl, mapID
  return changed
end

local function RecordAlt()
  if not ownLevel then return end -- don't seed junk "no key" alt records
  local db = MDB()
  local _, class = UnitClass("player")
  db.alts[MyFullName()] = { level = ownLevel, mapID = ownMapID, class = class, t = time() }
end

local function PruneGuild()
  local db = MDB()
  local now = time()
  for name, e in pairs(db.guild) do
    if not (e and e.t and (now - e.t) < 14 * 86400) then db.guild[name] = nil end
  end
  local n = 0
  for _ in pairs(db.guild) do n = n + 1 end
  while n > 200 do
    local oldest, oldestKey = nil, nil
    for k, e in pairs(db.guild) do
      if oldest == nil or (e.t or 0) < oldest then oldest, oldestKey = (e.t or 0), k end
    end
    if not oldestKey then break end
    db.guild[oldestKey] = nil
    n = n - 1
  end
end

-- ---------------------------------------------------------------------------
-- Broadcast / receive
-- ---------------------------------------------------------------------------

local function PartyChannel()
  if IsInRaid and IsInRaid() then return "RAID" end
  return "PARTY"
end

local function SendOwn(channel)
  if not ownLevel then return end
  local _, class = UnitClass("player")
  NS.Comms.SendKeystone(channel, ownLevel, ownMapID, class)
end

local function GuildBroadcast()
  local db = MDB()
  if db.guildSync == false then return end
  SendOwn("GUILD")
end

local function PartySend()
  if not (IsInGroup and IsInGroup()) then return end
  SendOwn(PartyChannel())
  NS.Comms.SendRequest(PartyChannel())
end

function NS.OnKeystoneBroadcast(channel, sender, level, mapID, class)
  if not NS.IsModuleEnabled("keystones") then return end
  if channel == "GUILD" then
    if MDB().guildSync == false then return end
    local db = MDB()
    db.guild[sender] = { level = level, mapID = mapID, class = class, t = time() }
  else
    party[sender] = { level = level, mapID = mapID, class = class, t = time() }
  end
  NS.RefreshKeysUI()
end

function NS.OnKeystoneRequest(channel)
  if not NS.IsModuleEnabled("keystones") then return end
  -- Throttle replies so a busy guild cannot storm us.
  local now = time()
  if lastReplyT and (now - lastReplyT) < 4 then return end
  lastReplyT = now
  if channel == "GUILD" then
    GuildBroadcast()
  else
    SendOwn(PartyChannel())
  end
end

local function PruneParty()
  if not (IsInGroup and IsInGroup()) then
    wipe(party)
    return
  end
  local keep = {}
  local n = GetNumGroupMembers and GetNumGroupMembers() or 0
  n = math.min(tonumber(n) or 0, 40)
  for i = 1, n do
    local name = GetRaidRosterInfo and GetRaidRosterInfo(i)
    name = NormalizeFullName(name)
    if name then keep[name] = true end
  end
  for name in pairs(party) do
    if not keep[name] then party[name] = nil end
  end
end

-- ---------------------------------------------------------------------------
-- Auto-insert (bag scan + use)
-- ---------------------------------------------------------------------------

local function FindKeystoneInBags()
  if not (C_Container and C_Container.GetContainerNumSlots) then return nil end
  for bag = 0, 4 do
    local okN, slots = pcall(C_Container.GetContainerNumSlots, bag)
    if okN and type(slots) == "number" and slots > 0 then
      for slot = 1, math.min(slots, 64) do
        local okL, link = pcall(C_Container.GetContainerItemLink, bag, slot)
        if okL and type(link) == "string" and link:find("|Hkeystone:", 1, true) then
          return bag, slot, link
        end
      end
    end
  end
end

local function InsertKeystone()
  if InCombatLockdown and InCombatLockdown() then
    NS.Print(l("insert_combat", "Cannot auto-insert keystone in combat."))
    return
  end
  local bag, slot = FindKeystoneInBags()
  if bag then
    pcall(UseContainerItem, bag, slot)
  else
    NS.Print(l("insert_none", "No keystone found in bags."))
  end
end

local function EnsureReceptacleHook()
  if receptacleFrame then return end
  local f = CreateFrame("Frame")
  local ok = pcall(f.RegisterEvent, f, "CHALLENGE_MODE_KEYSTONE_RECEPTACLE_OPEN")
  if ok then
    f:SetScript("OnEvent", function()
      if MDB().autoInsert then InsertKeystone() end
    end)
    receptacleFrame = f
  end
  -- Event missing on this client: auto-insert stays available via slash only.
end

-- ---------------------------------------------------------------------------
-- Keystone tooltip enrichment (bag keystone: dungeon + level + affixes)
-- ---------------------------------------------------------------------------

local function InitTooltipHook()
  if tooltipHooked then return end
  if not (TooltipDataProcessor and Enum and Enum.TooltipDataType) then return end
  local ok = pcall(TooltipDataProcessor.AddTooltipPostProcessor, Enum.TooltipDataType.Item, function(tooltip)
    local okL, link = pcall(tooltip.GetItem, tooltip)
    if not (okL and type(link) == "string") then return end
    if not link:find("|Hkeystone:", 1, true) then return end
    -- "|cffa335ee|Hkeystone:itemID:mapID:level:...|h"
    local payload = link:match("|Hkeystone:(.-)|h")
    if not payload then return end
    local itemID, mapStr, lvlStr = strsplit(":", payload)
    local mapID, level = tonumber(mapStr), tonumber(lvlStr)
    if not (type(itemID) == "string" and mapID and level and level >= 2 and level <= 40) then return end
    local name = Util.GetChallengeMapName(mapID)
    pcall(tooltip.AddLine, tooltip, string.format("|cffffd100%s +%d|r", name or "?", level))
    local aff = NS.Affixes and NS.Affixes.Summary()
    if aff then pcall(tooltip.AddLine, tooltip, aff) end
  end)
  tooltipHooked = ok
end

-- ---------------------------------------------------------------------------
-- Keystone chat-link beautifier: "[Keystone: The Necrotic Wake (Level 7)]"
-- -> "The Necrotic Wake +7" (the hyperlink stays clickable). The label text
-- is the primary name source (always carries the dungeon name); the link
-- payload's level wins when parseable.
-- ---------------------------------------------------------------------------

local function BeautifyKeystoneLinks(msg)
  if type(msg) ~= "string" or not msg:find("|Hkeystone:", 1, true) then return msg end
  return (msg:gsub("(|Hkeystone:[^|]*)|h%[([^%]]*)%]|h", function(h, label)
    local level
    local payload = h:match("|Hkeystone:(.-)$")
    if payload then
      local _, _, lvlStr = strsplit(":", payload)
      level = tonumber(lvlStr)
    end
    if not level then level = tonumber(label:match("%(Level%s*(%d+)%)")) end
    local name = label:match("^Keystone:%s*(.+)%s*%(.-%)$") or label
    if not (level and level >= 2 and level <= 40) then
      return h .. "|h[" .. label .. "]|h"
    end
    return h .. "|h[" .. name .. " |cffffd100+" .. level .. "|r]|h"
  end))
end

local chatLinkFiltered = false
local function InitChatLinkFilter()
  if chatLinkFiltered then return end
  if not ChatFrame_AddMessageEventFilter then return end
  local events = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL",
  }
  for _, ev in ipairs(events) do
    pcall(ChatFrame_AddMessageEventFilter, ev, function(_, _, msg, ...)
      local fixed = BeautifyKeystoneLinks(msg)
      if fixed ~= msg then return false, fixed end
      return false
    end)
  end
  chatLinkFiltered = true
end

-- ---------------------------------------------------------------------------
-- Reroll advisor (Midnight rules: timed = +1/+2/+3 by time remaining, key
-- moves to a random dungeon from the season pool; untimed = -1)
-- ---------------------------------------------------------------------------

local function RerollAdvisor()
  RefreshOwn()
  local n = 0
  local function advise(name, level, mapID, class, isMe)
    local dname = Util.GetChallengeMapName(mapID) or "?"
    local who = isMe and ("|cffffd100" .. l("you", "You") .. "|r")
      or Util.ClassColorize(class, Util.ShortName(name))
    NS.Print(string.format("%s: |cffffd100+%d %s|r |cff888888→|r |cff43ff43+%d/%d/%d|r |cff888888"
      .. l("reroll_newdungeon", "new dungeon") .. " · |r" .. l("reroll_un", "untimed") .. " |cffee6666+%d|r",
      who, level, dname, level + 1, level + 2, level + 3, level - 1))
    n = n + 1
  end
  if ownLevel then
    advise(MyFullName(), ownLevel, ownMapID, select(2, UnitClass("player")), true)
  end
  for name, e in pairs(party) do advise(name, e.level, e.mapID, e.class) end
  if n == 0 then
    NS.Print(l("reroll_nodata", "No keystones known yet (own key not detected, no synced party keys)."))
  else
    NS.Print("|cff888888" .. l("reroll_note",
      "timed: +1/+2/+3 by time left, dungeon rerolls within the season pool; untimed: -1") .. "|r")
  end
end

-- ---------------------------------------------------------------------------
-- Listen-only interop: LibOpenRaid keystone broadcasts (MIT; wire format
-- read from the public source per PLAN). Prefixes "LRS"/"LRS_LOGGED";
-- "K,level,mapID,challengeMapID,classID,rating,mythicPlusMapID,specID" is a
-- keystone, "J" a request. We never speak their protocol back - pure
-- listening, and anything that doesn't parse is silently dropped. (Astral
-- Keys / Angry Keystones stay un-listened: ARR sources are not read.)
-- ---------------------------------------------------------------------------

local INTEROP_PREFIXES = { "LRS", "LRS_LOGGED" }
local interopRegistered = false

local function InitInteropListeners()
  if interopRegistered then return end
  if not (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) then return end
  local any = false
  for _, p in ipairs(INTEROP_PREFIXES) do
    if pcall(C_ChatInfo.RegisterAddonMessagePrefix, p) then any = true end
  end
  interopRegistered = any
end

local function OnInteropMessage(prefix, msg, channel, sender)
  if type(msg) ~= "string" then return end
  if msg:sub(1, 1) ~= "K" then return end -- keystone data only; "J" (request) ignored
  local parts = { strsplit(",", msg:sub(2)) }
  local level = tonumber(parts[1])
  local mapID = tonumber(parts[2])
  local challengeMapID = tonumber(parts[3])
  local classID = tonumber(parts[4])
  if not (level and level >= 2 and level <= 40) then return end
  if not ((mapID or 0) > 0) then return end
  -- challengeMapID is what C_ChallengeMode.GetMapUIInfo names correctly.
  local useMap = (challengeMapID and challengeMapID > 0) and challengeMapID or mapID
  local name = NormalizeSender(sender)
  if not name then return end
  local class
  if classID and classID > 0 and GetClassInfo then
    local okC, _, token = pcall(GetClassInfo, classID)
    if okC and token then class = token end
  end
  local entry = { level = level, mapID = useMap, class = class, t = time() }
  if channel == "GUILD" then
    local db = MDB()
    if db.guildSync == false then return end
    db.guild[name] = entry
  else
    party[name] = entry
  end
  NS.RefreshKeysUI()
end

-- ---------------------------------------------------------------------------
-- Keystone window
-- ---------------------------------------------------------------------------

local frame, scroll
local rows = {}
local sortCycle = { "level", "name", "age" }

local function BuildRows()
  local db = MDB()
  local me = MyFullName()
  local out = {}
  local function add(name, e, src)
    if name == me then return end
    if e and e.level and e.level >= 2 and e.mapID then
      out[#out + 1] = { name = name, level = e.level, mapID = e.mapID,
        class = e.class, t = e.t or 0, src = src }
    end
  end
  for name, e in pairs(party) do add(name, e, "party") end
  for name, e in pairs(db.alts or {}) do add(name, e, "alt") end
  for name, e in pairs(db.guild or {}) do add(name, e, "guild") end
  local mode = db.sort or "level"
  if mode == "name" then
    table.sort(out, function(a, b) return a.name < b.name end)
  elseif mode == "age" then
    table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
  else
    table.sort(out, function(a, b)
      if a.level ~= b.level then return a.level > b.level end
      return a.name < b.name
    end)
  end
  return out
end

function NS.RefreshKeysUI()
  if not frame then return end
  if ownLevel and ownMapID then
    local name = Util.GetChallengeMapName(ownMapID) or "?"
    frame.ownLine:SetText("|cffffd100" .. string.format(l("own_key_fmt", "Your key: +%d %s"), ownLevel, name) .. "|r")
  else
    frame.ownLine:SetText("|cff888888" .. l("own_key_none", "No keystone in bags") .. "|r")
  end
  local aff = NS.Affixes.Summary()
  frame.affixLine:SetText(aff and (l("affixes_lbl", "Affixes: ") .. aff) or "")
  local data = BuildRows()
  if frame.emptyHint then frame.emptyHint:SetShown(#data == 0) end
  FauxScrollFrame_Update(scroll, #data, ROWS_VISIBLE, ROW_H)
  local offset = FauxScrollFrame_GetOffset(scroll)
  for i = 1, ROWS_VISIBLE do
    local row = rows[i]
    local e = data[offset + i]
    if e then
      local short = Util.ShortName(e.name)
      row.name:SetText(Util.ClassColorize(e.class, short))
      local dname = Util.GetChallengeMapName(e.mapID) or "?"
      row.dungeon:SetText(Util.AbbrevDungeonName(dname) or dname)
      row.key:SetText(string.format("|cffffd100+%d|r", e.level))
      local srcTag = e.src
      if e.t and e.t > 0 and e.src ~= "party" then
        srcTag = srcTag .. " " .. (Util.FormatAge(time() - e.t) or "")
      end
      row.src:SetText("|cff888888" .. srcTag .. "|r")
      row:Show()
    else
      row:Hide()
    end
  end
end

local function BuildUI()
  if frame then return end
  frame = CreateFrame("Frame", "LFGSuiteKeysFrame", UIParent, "BackdropTemplate")
  frame:SetSize(400, 386)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
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
  title:SetText("|cffffd100" .. l("keys_title", "Keystones") .. "|r")

  local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  close:SetSize(24, 20)
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
  close:SetText("X")
  close:SetScript("OnClick", function() frame:Hide() end)

  frame.ownLine = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  frame.ownLine:SetPoint("TOP", frame, "TOP", 0, -34)

  frame.affixLine = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.affixLine:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -54)
  frame.affixLine:SetWidth(368)
  frame.affixLine:SetJustifyH("LEFT")

  local hy = -78
  local function Header(text, x, w)
    local h = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetPoint("TOPLEFT", frame, "TOPLEFT", x, hy)
    h:SetWidth(w)
    h:SetJustifyH("LEFT")
    h:SetText("|cffffd100" .. text .. "|r")
    return h
  end
  Header(l("col_name", "Name"), 16, 130)
  Header(l("col_dungeon", "Dungeon"), 150, 76)
  Header(l("col_key", "Key"), 230, 40)
  Header(l("col_source", "Source"), 276, 100)

  scroll = CreateFrame("ScrollFrame", "LFGSuiteKeysScroll", frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, hy - 6)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 42)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, NS.RefreshKeysUI)
  end)

  for i = 1, ROWS_VISIBLE do
    local row = CreateFrame("Frame", nil, frame)
    row:SetSize(360, ROW_H)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, hy - 8 - (i - 1) * ROW_H)
    if i % 2 == 0 then
      local zebra = row:CreateTexture(nil, "BACKGROUND")
      zebra:SetAllPoints()
      zebra:SetColorTexture(0.15, 0.15, 0.15, 0.35)
    end
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.name:SetWidth(130)
    row.name:SetJustifyH("LEFT")
    row.dungeon = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.dungeon:SetPoint("LEFT", row, "LEFT", 134, 0)
    row.dungeon:SetWidth(76)
    row.dungeon:SetJustifyH("LEFT")
    row.key = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.key:SetPoint("LEFT", row, "LEFT", 214, 0)
    row.key:SetWidth(40)
    row.src = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.src:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.src:SetWidth(100)
    row.src:SetJustifyH("RIGHT")
    rows[i] = row
  end

  local sortBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  sortBtn:SetSize(190, 22)
  sortBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 10)
  local function PaintSort()
    sortBtn:SetText(l("sort_fmt", "Sort: %s"):format(MDB().sort or "level"))
  end
  sortBtn:SetScript("OnClick", function()
    local db = MDB()
    local cur = db.sort or "level"
    local nxt = "level"
    for i, m in ipairs(sortCycle) do
      if m == cur then nxt = sortCycle[(i % #sortCycle) + 1] break end
    end
    db.sort = nxt
    PaintSort()
    NS.RefreshKeysUI()
  end)
  PaintSort()
  frame.sortBtn = sortBtn

  local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 14)
  hint:SetText("|cff888888" .. l("keys_hint", "/lfgs keys announce party|guild") .. "|r")

  -- Shown when the merged list is empty so the window is never silently blank.
  frame.emptyHint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.emptyHint:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, hy - 16)
  frame.emptyHint:SetWidth(368)
  frame.emptyHint:SetJustifyH("LEFT")
  frame.emptyHint:SetText("|cff888888"
    .. l("keys_empty", "No synced keys yet.\nParty/guild keys appear as their players log in with LFG Suite; alts are recorded as you log them.")
    .. "|r")
  frame.emptyHint:Hide()
end

function NS.ToggleKeysWindow(state)
  BuildUI()
  if not frame then return end
  if state == nil then state = not frame:IsShown() end
  if state then
    RefreshOwn()
    NS.Affixes.Refresh()
    NS.RefreshKeysUI()
  end
  frame:SetShown(state)
end

-- ---------------------------------------------------------------------------
-- Announce
-- ---------------------------------------------------------------------------

local function Announce(where)
  RefreshOwn()
  if not ownLevel then
    NS.Print(l("announce_nokey", "No keystone to announce."))
    return
  end
  -- Prefer the real clickable keystone link from bags: recipients get a
  -- hoverable link (and our own chat beautifier renders it compactly here).
  local _, _, link = FindKeystoneInBags()
  local msg = link or string.format("[LFG Suite] +%d %s", ownLevel,
    Util.GetChallengeMapName(ownMapID) or "?")
  if where == "guild" then
    pcall(SendChatMessage, msg, "GUILD")
  else
    pcall(SendChatMessage, msg, IsInRaid and IsInRaid() and "RAID" or "PARTY")
  end
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {
  key = "keystones",
  label = "Keystones",
  desc = "Own/party/guild/alt keystone tracking, sync, tooltip, auto-insert",
  phase = 1,
  status = "alpha",
  defaultEnabled = true,
  events = {
    "PLAYER_ENTERING_WORLD", "CHALLENGE_MODE_COMPLETED", "CHAT_MSG_ADDON",
    "GROUP_ROSTER_UPDATE", "PLAYER_LOGOUT", "UNIT_TARGET",
  },
  OnLoad = function()
    MDB()
    BuildUI()
    InitTooltipHook()
    InitChatLinkFilter()
    InitInteropListeners()
    EnsureReceptacleHook()
  end,
  OnEnable = function()
    MDB()
    BuildUI()
    InitTooltipHook()
    InitChatLinkFilter()
    InitInteropListeners()
    EnsureReceptacleHook()
  end,
  OnDisable = function()
    weAutoOpened = false
    if frame then frame:Hide() end
  end,
  OnEvent = function(_, event, ...)
    local arg1 = ...
    if event == "PLAYER_ENTERING_WORLD" then
      C_Timer.After(2, function()
        RefreshOwn()
        RecordAlt()
        NS.Affixes.Refresh()
        PruneGuild()
        PruneParty()
        NS.RefreshKeysUI()
      end)
      -- Stagger the guild broadcast so a raid of users logging in doesn't storm.
      C_Timer.After(15 + math.random(0, 5), function()
        RefreshOwn()
        GuildBroadcast()
      end)
    elseif event == "CHALLENGE_MODE_COMPLETED" then
      local prevLvl, prevMap = ownLevel, ownMapID
      C_Timer.After(3, function()
        if RefreshOwn() then
          if ownLevel then
            local n = Util.GetChallengeMapName(ownMapID) or "?"
            if prevLvl then
              local p = Util.GetChallengeMapName(prevMap) or "?"
              NS.Print("|cffffd100" .. (l("reroll_fmt", "Keystone updated: +%d %s → +%d %s")
                :format(prevLvl, p, ownLevel, n)) .. "|r")
            else
              NS.Print("|cffffd100" .. (l("reroll_newkey_fmt", "New keystone: +%d %s")
                :format(ownLevel, n)) .. "|r")
            end
          end
          RecordAlt()
          GuildBroadcast()
          SendOwn(PartyChannel())
          NS.RefreshKeysUI()
        end
      end)
    elseif event == "CHAT_MSG_ADDON" then
      -- payload: prefix, message, channel, sender
      local prefix, msg, channel, sender = ...
      if not NS.Comms.OnMessage(prefix, msg, channel, sender) then
        OnInteropMessage(prefix, msg, channel, sender)
      end
    elseif event == "GROUP_ROSTER_UPDATE" then
      PruneParty()
      NS.RefreshKeysUI()
      -- Coalesce: roster updates arrive in bursts (joins/leaves/role swaps);
      -- each used to schedule its own delayed bag scan + party broadcast.
      if IsInGroup and IsInGroup() and not rosterSyncPending then
        rosterSyncPending = true
        C_Timer.After(1.5, function()
          rosterSyncPending = false
          RefreshOwn()
          PartySend()
        end)
      end
    elseif event == "PLAYER_LOGOUT" then
      RecordAlt()
    elseif event == "UNIT_TARGET" and arg1 == "player" then
      local db = MDB()
      local nm = UnitName and UnitName("target")
      if nm and KEY_NPCS[nm] and db.lindormi ~= false then
        weAutoOpened = true
        NS.ToggleKeysWindow(true)
      elseif weAutoOpened then
        weAutoOpened = false
        NS.ToggleKeysWindow(false)
      end
    end
  end,
  OnOptions = function(ctx)
    ctx.AddCB(l("opt_guildsync", "Sync keystones with guild (broadcast + listen)"),
      function() return MDB().guildSync ~= false end,
      function(v) MDB().guildSync = v end)
    ctx.AddCB(l("opt_lindormi", "Auto-open key window at the keystone NPC (Lindormi)"),
      function() return MDB().lindormi ~= false end,
      function(v) MDB().lindormi = v end)
    ctx.AddCB(l("opt_autoinsert", "Auto-insert my keystone at the pedestal"),
      function() return MDB().autoInsert == true end,
      function(v) MDB().autoInsert = v end)
  end,
}
NS.RegisterModule(M)

-- Slash subcommands (registered after all locals exist) --------------------

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.keys = function(rest)
  if rest == "announce party" or rest == "announce raid" then
    Announce("party")
  elseif rest == "announce guild" then
    Announce("guild")
  elseif rest == "reroll" then
    RerollAdvisor()
  elseif rest == "insert" then
    InsertKeystone()
  elseif rest == "sort" then
    if frame and frame.sortBtn then frame.sortBtn:Click() end
  else
    NS.ToggleKeysWindow()
  end
end
NS.SlashHandlers.affixes = function()
  NS.Affixes.Refresh()
  local summary = NS.Affixes.Summary() or l("affixes_unknown", "unknown")
  NS.Print("|cffffd100" .. l("affixes_lbl", "Affixes: ") .. "|r" .. summary)
  if ownLevel and ownMapID then
    NS.Print(string.format(l("own_key_fmt", "Your key: +%d %s"), ownLevel, Util.GetChallengeMapName(ownMapID) or "?"))
  end
end

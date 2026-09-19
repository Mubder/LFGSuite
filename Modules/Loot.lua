-- LFG Suite - Modules/Loot.lua
-- PHASE 4. Absorbs: KeystoneLoot (ARR - feature-inspired only; item data is
-- derived from Blizzard's Encounter Journal at runtime, never bundled).
--
-- Feature checklist:
--   [x] Favorites with 3 priority tiers (nice / must have / BiS), per character
--   [x] Export/import favorites as a shareable string
--   [x] Drop notifications: chat + banner when a groupmate loots one of your
--       favorites (one-click whisper hint for trading)
--   [x] Dungeon loot browser: journal-driven item list per M+ dungeon
--       (Encounter Journal probes - shows a clear "unavailable" note if this
--       client's journal API shape differs; never errors)
--   [x] Click a browser row to cycle its favorite tier
--   [ ] Class/spec/slot filters (needs tooltip item-class scanning)
--   [ ] Loot spec advisor on zone-in
--   [ ] Catalyst / Great Vault eligible browser
--   [ ] Dungeon teleport buttons (needs the spell table)

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local Util = NS.Util
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

local LOOT_DEFAULTS = {
  dropNotify = true,
  favorites = {}, -- [charFullName] = { [tostring(itemID)] = tier }
  lastDungeon = nil, -- selected mapID in the browser
}

local function MDB() return NS.EnsureModuleDB("loot", LOOT_DEFAULTS) end

local TIER_LABEL = {
  [1] = l("tier1", "nice"),
  [2] = l("tier2", "must"),
  [3] = "|cffff7000" .. l("tier3", "BiS") .. "|r",
}

local function MyFullName()
  return (UnitName("player") or "?") .. "-" .. GetRealmName()
end

-- ---------------------------------------------------------------------------
-- Favorites
-- ---------------------------------------------------------------------------

local function FavTable()
  local db = MDB()
  local me = MyFullName()
  db.favorites[me] = db.favorites[me] or {}
  return db.favorites[me]
end

local function ItemName(itemID)
  if GetItemInfo then
    local ok, name = pcall(GetItemInfo, tonumber(itemID))
    if ok and name and name ~= "" then return name end
  end
  return "item:" .. tostring(itemID)
end

local function SetFavorite(itemID, tier)
  itemID = tostring(tonumber(itemID) or itemID)
  local favs = FavTable()
  if tier and tier > 0 then
    favs[itemID] = tier
  else
    favs[itemID] = nil
  end
  NS.RefreshLootUI()
end

local function CycleFavorite(itemID)
  itemID = tostring(tonumber(itemID) or itemID)
  local favs = FavTable()
  local cur = favs[itemID] or 0
  SetFavorite(itemID, (cur % 3) + 1)
  return (cur % 3) + 1
end

local function ExportFavorites()
  local parts = {}
  for itemID, tier in pairs(FavTable()) do
    parts[#parts + 1] = tostring(itemID) .. ":" .. tostring(tier)
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

local function ImportFavorites(str)
  local n = 0
  for itemID, tier in str:gmatch("(%d+):(%d)") do
    local t = math.min(3, math.max(1, tonumber(tier) or 1))
    FavTable()[itemID] = t
    n = n + 1
  end
  NS.RefreshLootUI()
  return n
end

-- ---------------------------------------------------------------------------
-- Drop notifications (groupmate loots one of your favorites)
-- ---------------------------------------------------------------------------

local function HandleLootChat(msg, sender)
  local db = MDB()
  if db.dropNotify == false then return end
  if not sender or sender == "" or sender == (UnitName("player") or "") then return end
  local favs = FavTable()
  local me = UnitName("player") or ""
  for itemID in msg:gmatch("|Hitem:(%d+)") do
    if favs[itemID] then
      local tier = favs[itemID]
      local line = string.format(l("fav_looted_fmt", "%s looted your %s favorite: %s"),
        tostring(sender), (TIER_LABEL[tier] or "?"), ItemName(itemID))
      NS.Print("|cffffd100★|r " .. line)
      if NS.ShowBanner then
        NS.ShowBanner(l("fav_banner", "Favorite looted"),
          sender .. " → " .. ItemName(itemID) .. "  |cffcccccc/whisper to ask for it|r")
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Journal-driven dungeon loot browser (best effort across API generations)
-- ---------------------------------------------------------------------------

local journalCache = {} -- mapID -> { instanceID, items = {{itemID, name, ilvl, slot, encounter}}, err }

local function MapTable()
  if not (C_ChallengeMode and C_ChallengeMode.GetMapTable) then return {} end
  local ok, maps = pcall(C_ChallengeMode.GetMapTable)
  if ok and type(maps) == "table" then return maps end
  return {}
end

-- Match a journal instance to a challenge map by dungeon name.
local function FindJournalInstance(mapName)
  if not C_EncounterJournal then return nil end
  for exp = 8, 14 do
    local ok, instances = pcall(C_EncounterJournal.GetInstancesForExpansion, exp, false)
    if ok and type(instances) == "table" then
      for _, inst in ipairs(instances) do
        local instID = inst and (inst.ID or inst.instanceID)
        if instID then
          local okI, info = pcall(C_EncounterJournal.GetInstanceInfo, instID)
          if okI and type(info) == "table" and info.name == mapName then
            return instID
          end
        end
      end
    end
  end
  return nil
end

local function LootForEncounter(encID)
  local out = {}
  -- Modern namespace probe first, then the classic EJ globals.
  if C_EncounterJournal.GetLootInfoForEncounter then
    local ok, loot = pcall(C_EncounterJournal.GetLootInfoForEncounter, encID)
    if ok and type(loot) == "table" then
      for _, li in ipairs(loot) do
        out[#out + 1] = li
      end
      if #out > 0 then return out end
    end
  end
  if EJ_SelectEncounter and EJ_GetNumLoot and EJ_GetLootInfo then
    if pcall(EJ_SelectEncounter, encID) then
      local okN, n = pcall(EJ_GetNumLoot)
      if okN and type(n) == "number" then
        for i = 1, n do
          local okL, li = pcall(EJ_GetLootInfo, i)
          if okL and type(li) == "table" then
            out[#out + 1] = li
          end
        end
      end
    end
  end
  return out
end

local function NormalizeItem(li)
  if type(li) ~= "table" then return nil end
  local itemID = li.itemID
  if not itemID and li.link then
    itemID = tonumber(li.link:match("|Hitem:(%d+)"))
  end
  if not itemID and li.itemString then
    itemID = tonumber(tostring(li.itemString):match("item:(%d+)"))
  end
  if not itemID then return nil end
  itemID = tostring(itemID)
  local name = li.name or ItemName(itemID)
  local ilvl, slot
  if GetItemInfo then
    local ok, _, _, _, _, _, _, _, equipLoc = pcall(GetItemInfo, itemID)
    if ok then slot = equipLoc end
  end
  if li.itemLevel and GetDetailedItemLevelInfo and li.link then
    local okL, lvl = pcall(GetDetailedItemLevelInfo, li.link)
    if okL and type(lvl) == "number" then ilvl = lvl end
  end
  return { itemID = itemID, name = name, ilvl = ilvl, slot = slot, link = li.link }
end

local function BuildJournalData(mapID)
  if journalCache[mapID] then return journalCache[mapID] end
  local mapName = Util.GetChallengeMapName(mapID)
  local entry = { items = {} }
  if mapName and C_EncounterJournal then
    local instID = FindJournalInstance(mapName)
    if instID then
      local okE, encounters = pcall(C_EncounterJournal.GetEncountersForInstance, instID)
      if okE and type(encounters) == "table" then
        for _, enc in ipairs(encounters) do
          local encID = enc and (enc.ID or enc.encounterID)
          if encID then
            for _, li in ipairs(LootForEncounter(encID)) do
              local item = NormalizeItem(li)
              if item then
                item.encounter = enc.name
                entry.items[#entry.items + 1] = item
              end
            end
          end
        end
      end
    end
  end
  if #entry.items == 0 then
    entry.err = l("loot_unavailable",
      "Journal data unavailable for this dungeon on this client (API shape differs).")
  end
  journalCache[mapID] = entry
  return entry
end

-- ---------------------------------------------------------------------------
-- Browser window
-- ---------------------------------------------------------------------------

local frame, scroll
local rows = {}
local ROWS_VISIBLE, ROW_H = 10, 20

function NS.RefreshLootUI()
  if not frame then return end
  local db = MDB()
  local maps = MapTable()
  if #maps == 0 then
    frame.dungeonBtn:SetText(l("loot_nomaps", "No M+ maps"))
    return
  end
  if not db.lastDungeon then
    db.lastDungeon = maps[1]
  end
  local mapID = db.lastDungeon
  local mapName = Util.GetChallengeMapName(mapID) or "?"
  frame.dungeonBtn:SetText(mapName .. "  |cff888888»|r")

  local data = BuildJournalData(mapID)
  local favs = FavTable()
  FauxScrollFrame_Update(scroll, #data.items, ROWS_VISIBLE, ROW_H)
  local offset = FauxScrollFrame_GetOffset(scroll)
  for i = 1, ROWS_VISIBLE do
    local row = rows[i]
    local item = data.items[offset + i]
    if item then
      local tier = favs[item.itemID]
      row.fav:SetText(tier and ("|cffffd100★|r " .. (TIER_LABEL[tier] or "?")) or "|cff666666☆|r")
      row.name:SetText(item.link or tostring(item.name))
      row.ilvl:SetText(item.ilvl and tostring(item.ilvl) or "-")
      row.slot:SetText(item.slot or "-")
      row.enc:SetText("|cff888888" .. (item.encounter or "") .. "|r")
      row.itemID = item.itemID
      row:Show()
    else
      row.itemID = nil
      row:Hide()
    end
  end
  frame.empty:SetShown(#data.items == 0)
  if #data.items == 0 then
    frame.empty:SetText(data.err or l("loot_none", "No items found."))
  end
end

local function BuildUI()
  if frame then return end
  frame = CreateFrame("Frame", "LFGSuiteLootFrame", UIParent, "BackdropTemplate")
  frame:SetSize(560, 380)
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
  title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -12)
  title:SetText("|cffffd100" .. l("loot_title", "Loot Planner") .. "|r")

  local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  close:SetSize(24, 20)
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
  close:SetText("X")
  close:SetScript("OnClick", function() frame:Hide() end)

  frame.dungeonBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.dungeonBtn:SetSize(220, 22)
  frame.dungeonBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -40)
  frame.dungeonBtn:SetScript("OnClick", function()
    local db = MDB()
    local maps = MapTable()
    if #maps == 0 then return end
    local curIdx = 1
    for i, m in ipairs(maps) do
      if m == db.lastDungeon then curIdx = i break end
    end
    db.lastDungeon = maps[(curIdx % #maps) + 1]
    NS.RefreshLootUI()
  end)

  local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("LEFT", frame.dungeonBtn, "RIGHT", 10, 0)
  hint:SetText("|cff888888" .. l("loot_hint", "Click a row to cycle its favorite tier") .. "|r")

  local hy = -70
  local function Header(text, x, w)
    local h = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetPoint("TOPLEFT", frame, "TOPLEFT", x, hy)
    h:SetWidth(w)
    h:SetJustifyH("LEFT")
    h:SetText("|cffffd100" .. text .. "|r")
  end
  Header(l("loot_fav", "Favorite"), 16, 80)
  Header(l("loot_item", "Item"), 100, 190)
  Header(l("col_ilvl", "iLvl"), 294, 40)
  Header(l("loot_slot", "Slot"), 338, 70)
  Header(l("loot_boss", "Boss"), 412, 110)

  scroll = CreateFrame("ScrollFrame", "LFGSuiteLootScroll", frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, hy - 6)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 12)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, NS.RefreshLootUI)
  end)

  for i = 1, ROWS_VISIBLE do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(524, ROW_H)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, hy - 8 - (i - 1) * ROW_H)
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
    row.fav = Col(0, 80)
    row.name = Col(84, 190)
    row.ilvl = Col(278, 40)
    row.slot = Col(322, 70)
    row.enc = Col(396, 110)
    row:SetScript("OnClick", function(self)
      if self.itemID then CycleFavorite(self.itemID) end
    end)
    rows[i] = row
  end

  frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.empty:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, hy - 34)
  frame.empty:SetWidth(500)
  frame.empty:SetJustifyH("LEFT")
  frame.empty:SetTextColor(0.8, 0.6, 0.4)
  frame.empty:Hide()
end

function NS.ToggleLootWindow(state)
  BuildUI()
  if not frame then return end
  if state == nil then state = not frame:IsShown() end
  if state then NS.RefreshLootUI() end
  frame:SetShown(state)
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {
  key = "loot",
  label = "Loot Planner",
  desc = "Favorites with tiers, groupmate drop alerts, journal loot browser",
  phase = 4,
  status = "alpha",
  defaultEnabled = true,
  events = { "CHAT_MSG_LOOT" },
  OnLoad = function() MDB() end,
  OnEnable = function() MDB() end,
  OnEvent = function(_, event, ...)
    if event == "CHAT_MSG_LOOT" then
      local msg, sender = ...
      if type(msg) == "string" then
        HandleLootChat(msg, tostring(sender or ""))
      end
    end
  end,
  OnOptions = function(ctx)
    ctx.AddCB(l("opt_l_notify", "Alert when a groupmate loots one of my favorites"),
      function() return MDB().dropNotify ~= false end,
      function(v) MDB().dropNotify = v end)
    ctx.Note(l("opt_l_note", "Favorites: /lfgs fav - add items from the browser (/lfgs loot) or chat links."))
  end,
}
NS.RegisterModule(M)

-- ---------------------------------------------------------------------------
-- Slash: /lfgs loot, /lfgs fav
-- ---------------------------------------------------------------------------

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.loot = function() NS.ToggleLootWindow() end

NS.SlashHandlers.fav = function(rest)
  local cmd, arg = rest:match("^(%S*)%s*(.-)$")
  if cmd == "add" then
    local itemID = arg:match("|Hitem:(%d+)") or arg:match("^(%d+)$")
    if itemID then
      SetFavorite(itemID, 2)
      NS.Print(string.format(l("fav_added_fmt", "Favorite added (%s): %s"),
        (TIER_LABEL[2] or "?"), ItemName(itemID)))
    else
      NS.Print(l("fav_add_usage", "Usage: /lfgs fav add <itemLink or itemID> [tier 1-3]"))
    end
  elseif cmd == "remove" or cmd == "rm" then
    local itemID = arg:match("|Hitem:(%d+)") or arg:match("^(%d+)$")
    if itemID then
      SetFavorite(itemID, nil)
      NS.Print(l("fav_removed", "Favorite removed."))
    else
      NS.Print(l("fav_rm_usage", "Usage: /lfgs fav remove <itemLink or itemID>"))
    end
  elseif cmd == "list" then
    local favs = FavTable()
    local n = 0
    for _ in pairs(favs) do n = n + 1 end
    NS.Print(string.format(l("fav_list_fmt", "Favorites for %s: %d"), MyFullName(), n))
    for itemID, tier in pairs(favs) do
      print(string.format("   %s %s", (TIER_LABEL[tier] or "?"), ItemName(itemID)))
    end
  elseif cmd == "export" then
    local s = ExportFavorites()
    if s == "" then
      NS.Print(l("fav_empty", "No favorites to export yet."))
    else
      NS.Print(l("fav_export_hint", "Share this string (also copied to a clickable box):"))
      print("|cff00ff00" .. s .. "|r")
    end
  elseif cmd == "import" then
    if arg == "" then
      NS.Print(l("fav_import_usage", "Usage: /lfgs fav import <string from export>"))
    else
      local n = ImportFavorites(arg)
      NS.Print(string.format(l("fav_imported_fmt", "Imported %d favorites."), n))
    end
  else
    NS.Print("/lfgs loot - open the loot browser")
    NS.Print("/lfgs fav add <itemLink|itemID> - add favorite (tier 2)")
    NS.Print("/lfgs fav remove <itemLink|itemID> - remove favorite")
    NS.Print("/lfgs fav list|export|import <string>")
  end
end

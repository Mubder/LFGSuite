-- LFG Suite - Core.lua
-- All-in-One LFG + Mythic+ companion. Phase 0 scaffold:
--   * DB + defaults migration (LFGAlert pattern)
--   * module registry + shared event bus (one frame, pcall-guarded dispatch)
--   * /lfgs slash hub
-- Feature specs per module live in Modules/*.lua headers + PLAN.md.

local ADDON_NAME = ...
LFGSuite = LFGSuite or {}
local NS = LFGSuite
local L = NS.L or {} -- from Locales\enUS.lua (loaded first per .toc)
local function l(key, fallback) return L[key] or fallback end
NS.BUILD = 1 -- bump every shipment; shown in load message

-- ---------------------------------------------------------------------------
-- Defaults / DB
-- ---------------------------------------------------------------------------

local DEFAULTS = {
  enabled = true,
  showMinimapButton = true,
  minimapAngle = 200,
  modules = {}, -- modules[key] = { enabled = bool }; seeded from module defs
}

local function CopyDefaults(src)
  local t = {}
  for k, v in pairs(src) do
    if type(v) == "table" then
      t[k] = CopyDefaults(v)
    else
      t[k] = v
    end
  end
  return t
end

local function InitDB()
  if type(LFGSuiteDB) ~= "table" then
    LFGSuiteDB = CopyDefaults(DEFAULTS)
  else
    for k, v in pairs(DEFAULTS) do
      if LFGSuiteDB[k] == nil then
        if type(v) == "table" then
          LFGSuiteDB[k] = CopyDefaults(v)
        else
          LFGSuiteDB[k] = v
        end
      end
    end
  end
  NS.db = LFGSuiteDB
end

-- ---------------------------------------------------------------------------
-- Printing / error collection
-- ---------------------------------------------------------------------------

function NS.Print(msg)
  print("|cff43d9ff[LFG Suite]|r " .. tostring(msg))
end

-- A module error must never cascade: print once, collect for diagnostics.
function NS.ModuleError(def, err)
  NS._moduleErrors = NS._moduleErrors or {}
  local line = tostring(def and def.key or "?") .. ": " .. tostring(err)
  for _, seen in ipairs(NS._moduleErrors) do
    if seen == line then return end
  end
  NS._moduleErrors[#NS._moduleErrors + 1] = line
  NS.Print("|cffff5555" .. l("module_error_fmt", "module '%s' error: %s"):format(
    tostring(def and def.key or "?"), tostring(err)) .. "|r")
end

-- ---------------------------------------------------------------------------
-- Module registry
-- ---------------------------------------------------------------------------
-- def = {
--   key = "keystones", label = "Keystones", phase = 1, status = "planned",
--   desc = "one-line description for the settings panel",
--   defaultEnabled = false, events = { "EVENT_NAME", ... },
--   OnLoad(self), OnEvent(self, event, ...), OnEnable(self), OnDisable(self),
-- }
-- OnLoad runs once at ADDON_LOADED (after DB init). OnEvent is dispatched by
-- the shared event bus below, only while the module + addon are enabled.

NS.Modules = {} -- ordered array (load order = .toc order)
NS.ModulesByName = {}

function NS.RegisterModule(def)
  if not (def and type(def.key) == "string" and type(def.label) == "string") then return end
  if NS.ModulesByName[def.key] then return end
  def.phase = def.phase or 0
  def.status = def.status or "planned"
  def.defaultEnabled = def.defaultEnabled == true -- planned modules default OFF
  def.events = def.events or {}
  NS.ModulesByName[def.key] = def
  NS.Modules[#NS.Modules + 1] = def
end

local function SeedModuleDBs()
  if not (NS.db and type(NS.db.modules) == "table") then return end
  for _, def in ipairs(NS.Modules) do
    if type(NS.db.modules[def.key]) ~= "table" then
      NS.db.modules[def.key] = { enabled = def.defaultEnabled }
    end
  end
end

-- Per-module settings namespace: db.<key> = { ...defaults } (separate from the
-- db.modules[key].enabled toggle). Modules call this from OnLoad/OnOptions.
function NS.EnsureModuleDB(key, defaults)
  if not NS.db then return nil end
  if type(NS.db[key]) ~= "table" then NS.db[key] = {} end
  local t = NS.db[key]
  for k, v in pairs(defaults or {}) do
    if t[k] == nil then
      if type(v) == "table" then
        local c = CopyDefaults(v)
        t[k] = c
      else
        t[k] = v
      end
    end
  end
  return t
end

function NS.IsModuleEnabled(key)
  local m = NS.db and NS.db.modules and NS.db.modules[key]
  if type(m) == "table" and m.enabled ~= nil then return m.enabled end
  local def = NS.ModulesByName[key]
  return def ~= nil and def.defaultEnabled == true
end

function NS.SetModuleEnabled(key, state)
  local def = NS.ModulesByName[key]
  if not (def and NS.db) then return false end
  if type(NS.db.modules) ~= "table" then NS.db.modules = {} end
  NS.db.modules[key] = NS.db.modules[key] or {}
  NS.db.modules[key].enabled = state and true or false
  local fn = state and def.OnEnable or def.OnDisable
  if type(fn) == "function" then
    local ok, err = pcall(fn, def)
    if not ok then NS.ModuleError(def, err) end
  end
  NS.SyncEventRegistrations()
  if NS.RefreshOptionsPanel then NS.RefreshOptionsPanel() end
  NS.Print(l("module_enabled_fmt", "module '%s' %s."):format(def.key,
    state and "|cff33cc33" .. l("on", "ON") .. "|r" or "|cffff4444" .. l("off", "OFF") .. "|r"))
  return true
end

-- ---------------------------------------------------------------------------
-- Shared event bus: ONE frame for the whole addon. ADDON_LOADED boots Core
-- (DB, module OnLoads, UI builds); every other event dispatches to enabled
-- modules, pcall-guarded so one broken module never takes down the rest.
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local registeredEvents = {}

local function Boot()
  InitDB()
  SeedModuleDBs()
  local function SafeBuild(label, fn)
    if type(fn) ~= "function" then return end
    local ok, err = pcall(fn)
    if not ok then NS.ModuleError({ key = label }, err) end
  end
  for _, def in ipairs(NS.Modules) do
    if NS.IsModuleEnabled(def.key) then
      SafeBuild(def.key .. ".OnLoad", def.OnLoad)
    end
  end
  SafeBuild("options", NS.BuildOptions)
  SafeBuild("minimap button", NS.BuildMinimapButton)
  NS.SyncEventRegistrations()
  local loaded = l("msg_loaded", "LFG Suite loaded (build %s). /lfgs for modules & options."):format(tostring(NS.BUILD))
  NS.Print("|cffffcc00" .. loaded .. "|r")
end

function NS.SyncEventRegistrations()
  local wanted = {}
  if NS.db and NS.db.enabled then
    for _, def in ipairs(NS.Modules) do
      if NS.IsModuleEnabled(def.key) then
        for _, ev in ipairs(def.events) do wanted[ev] = true end
      end
    end
  end
  for ev in pairs(wanted) do
    if not registeredEvents[ev] then
      -- pcall: a module may list an event Blizzard renamed/removed - it must
      -- not break the bus, it just never fires.
      local ok = pcall(eventFrame.RegisterEvent, eventFrame, ev)
      if ok then registeredEvents[ev] = true end
    end
  end
  for ev in pairs(registeredEvents) do
    if not wanted[ev] then
      pcall(eventFrame.UnregisterEvent, eventFrame, ev)
      registeredEvents[ev] = nil
    end
  end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name == ADDON_NAME then Boot() end
    return
  end
  if not (NS.db and NS.db.enabled) then return end
  for _, def in ipairs(NS.Modules) do
    if NS.IsModuleEnabled(def.key) and type(def.OnEvent) == "function" then
      local ok, err = pcall(def.OnEvent, def, event, ...)
      if not ok then NS.ModuleError(def, err) end
    end
  end
end)

-- ---------------------------------------------------------------------------
-- Slash hub: /lfgs
-- ---------------------------------------------------------------------------

SLASH_LFGSUITE1 = "/lfgs"
SLASH_LFGSUITE2 = "/lfgsuite"
SlashCmdList["LFGSUITE"] = function(msg)
  msg = (msg or ""):lower()
  if strtrim then msg = strtrim(msg) else msg = msg:match("^%s*(.-)%s*$") end
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")

  if cmd == "config" or cmd == "options" or cmd == "settings" then
    if Settings and Settings.OpenToCategory and NS._settingsCategory then
      local okC, id = pcall(function() return NS._settingsCategory:GetID() end)
      if okC and id then pcall(Settings.OpenToCategory, id) end
    else
      NS.Print("open via Esc > Options > AddOns > LFG Suite")
    end
  elseif cmd == "modules" or cmd == "module" then
    NS.Print("|cffffcc00Modules:|r")
    for _, def in ipairs(NS.Modules) do
      local state = NS.IsModuleEnabled(def.key) and "|cff33cc33on |r" or "|cffff4444off|r"
      local stat = def.status == "planned"
        and ("[" .. l("status_planned", "planned - not implemented yet (phase %s)"):format(tostring(def.phase)) .. "]")
        or ("[" .. tostring(def.status) .. "]")
      print(string.format("  %-12s %s  %s %s", def.key, state, stat, tostring(def.desc or "")))
    end
  elseif cmd == "version" or cmd == "build" then
    NS.Print("build " .. tostring(NS.BUILD) .. ", " .. #NS.Modules .. " modules registered")
    if NS._moduleErrors then
      for _, e in ipairs(NS._moduleErrors) do print("  |cffff5555" .. e .. "|r") end
    end
  elseif (cmd == "on" or cmd == "off") and rest ~= "" then
    if NS.ModulesByName[rest] then
      NS.SetModuleEnabled(rest, cmd == "on")
    else
      NS.Print("unknown module: " .. rest .. " (see /lfgs modules)")
    end
  elseif cmd == "on" or cmd == "off" then
    NS.db.enabled = (cmd == "on")
    NS.SyncEventRegistrations()
    local state = NS.db.enabled and ("|cff33cc33" .. l("on", "ON") .. "|r") or ("|cffff4444" .. l("off", "OFF") .. "|r")
    NS.Print("LFG Suite " .. state)
  elseif cmd ~= "" and NS.ModulesByName[cmd] then
    -- /lfgs keystones on|off|toggle
    local def = NS.ModulesByName[cmd]
    if rest == "on" or rest == "off" then
      NS.SetModuleEnabled(cmd, rest == "on")
    else
      NS.SetModuleEnabled(cmd, not NS.IsModuleEnabled(cmd))
    end
    if def.status == "planned" then
      local note = l("status_planned", "planned - not implemented yet (phase %s)"):format(tostring(def.phase))
      NS.Print("|cffffcc00" .. def.label .. ": " .. note .. "|r")
    end
  elseif NS.SlashHandlers and NS.SlashHandlers[cmd] then
    -- Module subcommands: /lfgs keys, /lfgs affixes, /lfgs refresh, ...
    local ok, err = pcall(NS.SlashHandlers[cmd], rest)
    if not ok then NS.Print("|cffff5555/" .. cmd .. " error: " .. tostring(err) .. "|r") end
  else
    print("|cffffcc00" .. l("help_header", "LFG Suite commands:") .. "|r")
    print("  " .. l("help_config", "/lfgs config - open settings"))
    print("  " .. l("help_modules", "/lfgs modules - list modules & status"))
    print("  " .. l("help_module_toggle", "/lfgs <module> on|off - e.g. /lfgs keystones on"))
    print("  " .. l("help_version", "/lfgs version - build info"))
  end
end

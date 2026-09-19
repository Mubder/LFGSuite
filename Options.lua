-- LFG Suite - Options.lua
-- One minimap button + one Blizzard Settings panel: master toggle and a
-- checkbox per registered module (built dynamically from NS.Modules).
LFGSuite = LFGSuite or {}
local ADDON_NAME = ...
local NS = LFGSuite
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

-- ---------------------------------------------------------------------------
-- Minimap button (Blizzard-style, no library)
-- ---------------------------------------------------------------------------

local mmButton

local function UpdatePos()
  if not mmButton then return end
  local rad = math.rad(NS.db and NS.db.minimapAngle or 200)
  mmButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * 80, math.sin(rad) * 80)
end

function NS.BuildMinimapButton()
  if mmButton then
    mmButton:SetShown(NS.db and NS.db.showMinimapButton ~= false)
    return
  end
  mmButton = CreateFrame("Button", "LFGSuiteMinimapButton", Minimap)
  mmButton:SetSize(31, 31)
  mmButton:SetFrameStrata("MEDIUM")
  mmButton:SetFrameLevel(8)
  mmButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local overlay = mmButton:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetPoint("TOPLEFT", 0, 0)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  local bg = mmButton:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("CENTER", 0, 1)
  bg:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
  bg:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  mmButton:RegisterForClicks("AnyUp")
  mmButton:RegisterForDrag("LeftButton")
  mmButton:SetMovable(true)
  mmButton:SetScript("OnDragStart", function(self)
    self:StartMoving()
    self:SetScript("OnUpdate", function()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      cx, cy = cx / scale, cy / scale
      local mx, my = Minimap:GetCenter()
      NS.db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
      self:ClearAllPoints()
      UpdatePos()
    end)
  end)
  mmButton:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetScript("OnUpdate", nil)
  end)
  mmButton:SetScript("OnClick", function(_, button)
    if button == "LeftButton" then
      if NS.IsModuleEnabled and NS.IsModuleEnabled("keystones") and NS.ToggleKeysWindow then
        NS.ToggleKeysWindow()
      elseif Settings and Settings.OpenToCategory and NS._settingsCategory then
        local okC, id = pcall(function() return NS._settingsCategory:GetID() end)
        if okC and id then pcall(Settings.OpenToCategory, id) end
      end
    else
      SlashCmdList["LFGSUITE"]("modules")
    end
  end)
  mmButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("LFG Suite")
    GameTooltip:AddLine(l("mm_open", "Left-click: keystones window (settings if module off)"), 1, 1, 1)
    GameTooltip:AddLine(l("mm_modules", "Right-click: list modules in chat"), 1, 1, 1)
    GameTooltip:AddLine(l("mm_drag", "Drag: move minimap icon"), 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  mmButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  UpdatePos()
  mmButton:SetShown(NS.db and NS.db.showMinimapButton ~= false)
end

-- ---------------------------------------------------------------------------
-- Settings panel
-- ---------------------------------------------------------------------------

local optionChecks = {} -- live-synced so slash toggles repaint the panel

local function Checkbox(parent, label, get, set)
  local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
  cb.Text:SetText(label)
  cb._get = get
  optionChecks[#optionChecks + 1] = cb
  cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
  cb:SetScript("OnClick", function(self) set(self:GetChecked()) end)
  return cb
end

function NS.RefreshOptionsPanel()
  for _, cb in ipairs(optionChecks) do
    if cb._get then cb:SetChecked(cb._get()) end
  end
end

function NS.BuildOptions()
  local panel = CreateFrame("Frame", "LFGSuiteOptionsPanel")
  panel.name = "LFG Suite"

  local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -8)
  scroll:SetPoint("BOTTOMRIGHT", 0, 8)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(620, 200)
  scroll:SetScrollChild(content)

  local y = -8
  local function Section(text)
    y = y - 20
    local h = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    h:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
    h:SetText(text)
    h:SetTextColor(1, 0.82, 0)
    y = y - 28
  end
  local function AddCB(label, get, set)
    local cb = Checkbox(content, label, get, set)
    cb:SetPoint("TOPLEFT", content, "TOPLEFT", 24, y)
    y = y - 30
    return cb
  end
  local function Note(text, h)
    local d = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d:SetPoint("TOPLEFT", content, "TOPLEFT", 24, y)
    d:SetWidth(560)
    d:SetJustifyH("LEFT")
    d:SetText(text)
    d:SetTextColor(0.7, 0.7, 0.7)
    y = y - (h or 22)
  end

  local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
  title:SetText(l("opt_title", "LFG Suite - All-in-One LFG & M+ companion"))
  y = y - 24
  local addonVer = "?"
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    local ok, vv = pcall(C_AddOns.GetAddOnMetadata, ADDON_NAME, "Version")
    if ok and vv then addonVer = vv end
  end
  local verText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  verText:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
  verText:SetTextColor(0.6, 0.6, 0.6)
  verText:SetText(l("opt_version_fmt", "Version %s  •  build %s  •  /lfgs for commands")
    :format(tostring(addonVer), tostring(NS.BUILD or "?")))
  y = y - 20

  Section(l("sec_general", "General"))
  AddCB(l("cb_enable", "Enable LFG Suite"), function() return NS.db.enabled end,
    function(v) NS.db.enabled = v; NS.SyncEventRegistrations() end)
  AddCB(l("cb_minimap", "Show minimap button (left: settings, right: module list)"),
    function() return NS.db.showMinimapButton ~= false end,
    function(v) NS.db.showMinimapButton = v; if mmButton then mmButton:SetShown(v) end end)

  Section(l("sec_modules", "Modules"))
  Note(l("note_modules", "Each module is independent. Modules marked 'planned' are "
    .. "placeholders for upcoming phases (see PLAN.md)."), 34)
  for _, def in ipairs(NS.Modules) do
    local stateNote = def.status == "planned"
      and l("status_planned", "planned - not implemented yet (phase %s)"):format(tostring(def.phase))
      or tostring(def.status)
    AddCB(string.format("%s (%s)", def.label, stateNote),
      function() return NS.IsModuleEnabled(def.key) end,
      function(v) NS.SetModuleEnabled(def.key, v) end)
    if def.desc and def.desc ~= "" then
      Note(def.desc)
    end
    -- Per-module settings (indented under the module's checkbox).
    if type(def.OnOptions) == "function" then
      local ctx = {
        AddCB = function(label, get, set)
          local cb = Checkbox(content, label, get, set)
          cb:SetPoint("TOPLEFT", content, "TOPLEFT", 44, y)
          y = y - 26
          return cb
        end,
        Note = function(text, h) Note(text, h) end,
      }
      local ok, err = pcall(def.OnOptions, ctx)
      if not ok then NS.ModuleError(def, err) end
      y = y - 4
    end
  end

  Section(l("sec_about", "About"))
  Note(l("note_about", "LFG Suite combines keystone trackers, group-finder enhancers, "
    .. "queue QoL, M+ timers and loot planners into one modular addon. "
    .. "Every feature set can be toggled separately."), 48)

  content:SetHeight(-y + 20)
  content:SetScript("OnShow", function() NS.RefreshOptionsPanel() end)

  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local cat = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(cat)
    NS._settingsCategory = cat
  elseif InterfaceOptions_AddCategory then
    pcall(InterfaceOptions_AddCategory, panel)
  end
end

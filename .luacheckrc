-- luacheck config for LFGSuite (WoW addon, Lua 5.1)
-- Run: luacheck .   (CI runs this on every push/PR)
std = "max"
cache = true
max_line_length = 120

-- Globals this addon creates.
globals = {
  "LFGSuite",
  "LFGSuiteDB",
  "SlashCmdList",
  "SLASH_LFGSUITE1",
  "SLASH_LFGSUITE2",
  -- Named frames created at runtime
  "LFGSuiteMinimapButton",
  "LFGSuiteOptionsPanel",
  "LFGSuiteKeysFrame",
  "LFGSuiteKeysScroll",
  "LFGSuiteBanner",
  "LFGSuiteQueueTimer",
  "LFGSuiteApplicantsFrame",
  "LFGSuiteApplicantsScrollBar",
  "LFGSuiteApplicantsDropMenu",
  "LFGSuiteApplicantsClassMenu",
  "LFGSuiteApplicantsKeyMenu",
  "LFGSuiteApplicantsFilterMenu",
  "LFGSuiteMPlusTimer",
  "LFGSuiteForcesBar",
  "LFGSuiteSummary",
  "LFGSuiteRosterFrame",
  "LFGSuiteRosterScroll",
  "LFGSuiteLootFrame",
  "LFGSuiteLootScroll",
  -- Keybindings (Bindings.xml)
  "BINDING_HEADER_LFGSUITE",
  "BINDING_NAME_LFGSUITE_BROWSEREFRESH",
}

-- WoW API + FrameXML we read. Not exhaustive: extend as new APIs are used.
read_globals = {
  -- Lua-adjacent WoW helpers
  "wipe", "strsplit", "strtrim", "date", "time", "tinsert",
  -- Frames / widgets
  "CreateFrame", "UIParent", "Minimap", "GameTooltip", "UISpecialFrames",
  "RAID_CLASS_COLORS", "LOCALIZED_CLASS_NAMES_MALE",
  "GameFontNormal", "GameFontNormalLarge", "GameFontNormalSmall",
  "GameFontHighlight", "GameFontHighlightSmall",
  "SELECTED_CHAT_FRAME", "DEFAULT_CHAT_FRAME",
  "BackdropTemplateMixin",
  -- C_* namespaces
  "C_Timer", "C_LFGList", "C_MythicPlus", "C_ChallengeMode", "C_PartyInfo",
  "C_AddOns", "C_Texture", "C_Container", "C_ChatInfo", "C_Scenario",
  "C_WeeklyRewards", "C_EncounterJournal",
  -- API functions
  "PlaySound", "PlaySoundFile", "FlashClientIcon",
  "RaidNotice_AddMessage", "RaidWarningFrame", "UIErrorsFrame", "ChatTypeInfo",
  "GetSpecializationInfoByID", "GetRealmName", "GetCursorPosition",
  "UnitIsGroupLeader", "UnitName", "UnitClass", "UnitLevel", "UnitGUID",
  "IsInGroup", "IsInRaid", "IsInInstance", "InCombatLockdown", "GetMouseFoci",
  "GetTime", "GetRealZoneText", "GetAverageItemLevel",
  "GetNumGroupMembers", "GetRaidRosterInfo",
  "GetLFGMode", "GetLFGProposal", "AcceptProposal",
  "GetBattlefieldStatus", "GetBattlefieldTimeWaited",
  "UseContainerItem", "SendChatMessage", "hooksecurefunc", "InviteUnit",
  "GetItemInfo", "GetDetailedItemLevelInfo",
  "GetNumSavedInstances", "GetSavedInstanceInfo",
  "EJ_SelectEncounter", "EJ_GetNumLoot", "EJ_GetLootInfo",
  -- Menus / chat interop
  "MenuUtil", "EasyMenu", "UIDropDownMenuTemplate",
  "ChatFrame_OpenChat", "ChatEdit_ChooseBoxForSend",
  -- Settings (modern + legacy)
  "Settings", "InterfaceOptionsFrame_OpenToCategory", "InterfaceOptions_AddCategory",
  -- Scroll frame helpers (FauxScrollFrameTemplate)
  "FauxScrollFrame_OnVerticalScroll", "FauxScrollFrame_Update", "FauxScrollFrame_GetOffset",
  -- Blizzard frames we hook/read
  "LFGListFrame", "GroupFinderFrame", "PVEFrame", "PVEFrame_ShowFrame",
  "LFGListFrame_SetActivePanel",
  -- Tooltip / optional addons
  "TooltipDataProcessor", "Enum", "RaiderIO",
}

-- Unused self/placeholder args are common in WoW script handlers.
ignore = {
  "212/self", "212/_", "212/button", "212/delta", "212/value",
  "213",   -- unused loop variable
  "542",   -- empty if branch (defensive guards)
}

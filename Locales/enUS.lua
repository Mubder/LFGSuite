-- LFG Suite - Locales/enUS.lua
-- All user-facing strings. Translation-ready from day one (LFGAlert pattern:
-- Core falls back to the embedded English when a key is missing).

LFGSuite = LFGSuite or {}
LFGSuite.L = {
  -- Core / load
  msg_loaded = "LFG Suite loaded (build %s). /lfgs for modules & options.",
  module_error_fmt = "LFG Suite: module '%s' error: %s",
  module_enabled_fmt = "LFG Suite: module '%s' %s.",

  -- Slash help
  help_header = "LFG Suite commands:",
  help_config = "/lfgs config - open settings",
  help_modules = "/lfgs modules - list modules & status",
  help_module_toggle = "/lfgs <module> on|off - e.g. /lfgs keystones on",
  help_version = "/lfgs version - build info",

  -- Options panel
  opt_title = "LFG Suite - All-in-One LFG & M+ companion",
  opt_version_fmt = "Version %s  •  build %s  •  /lfgs for commands",
  sec_general = "General",
  cb_enable = "Enable LFG Suite",
  cb_minimap = "Show minimap button (left: settings, right: module list)",
  sec_modules = "Modules",
  note_modules = "Each module is independent. Modules marked 'planned' are placeholders "
    .. "for upcoming phases (see PLAN.md).",
  status_planned = "planned - not implemented yet (phase %s)",
  sec_about = "About",
  note_about = "LFG Suite combines keystone trackers, group-finder enhancers, queue QoL, "
    .. "M+ timers and loot planners into one modular addon. "
    .. "Every feature set can be toggled separately.",

  -- Minimap
  mm_open = "Left-click: open settings",
  mm_modules = "Right-click: list modules in chat",
  mm_drag = "Drag: move minimap icon",

  -- Generic on/off
  on = "ON",
  off = "OFF",

  -- Keystones module
  keys_title = "Keystones",
  own_key_fmt = "Your key: +%d %s",
  own_key_none = "No keystone in bags",
  affixes_lbl = "Affixes: ",
  affixes_unknown = "unknown (not in a Mythic+ season yet)",
  col_name = "Name",
  col_dungeon = "Dungeon",
  col_key = "Key",
  col_source = "Source",
  sort_fmt = "Sort: %s",
  keys_hint = "/lfgs keys announce party|guild",
  opt_guildsync = "Sync keystones with guild (broadcast + listen)",
  opt_lindormi = "Auto-open key window at the keystone NPC (Lindormi)",
  opt_autoinsert = "Auto-insert my keystone at the pedestal",
  insert_combat = "Cannot auto-insert keystone in combat.",
  insert_none = "No keystone found in bags.",
  announce_nokey = "No keystone to announce.",
  you = "You",
  reroll_newdungeon = "new dungeon",
  reroll_un = "untimed",
  reroll_nodata = "No keystones known yet (own key not detected, no synced party keys).",
  reroll_note = "timed: +1/+2/+3 by time left, dungeon rerolls within the season pool; untimed: -1",
  reroll_fmt = "Keystone updated: +%d %s → +%d %s",
  reroll_newkey_fmt = "New keystone: +%d %s",

  -- Browser module
  opt_tags = "Show age / key level / leader score tags on listings",
  opt_dblclick = "Double-click a listing to sign up",
  opt_roles = "Remember my selected roles for signups",
  signup_unavailable = "Cannot sign up automatically on this client.",
  signed_up_fmt = "Signed up: %s",
  refresh_nopanel = "Open the Group Finder (Premade Groups) first.",
  refresh_nosearch = "Start a search first - no refresh button visible.",
  refresh_done = "Group Finder search refreshed.",
  signup_filtered = "That listing is filtered out - adjust /lfgs filters to sign up.",
  filters_title = "Listing filters",
  filters_enable = "Enable filters",
  filters_keylevels = "Key levels",
  filters_levelhint = "(none = all)",
  filters_nogf = "Open the Group Finder (Premade Groups) first.",
  filters_maxage = "Max age (min)",
  filters_minscore = "Min leader score",
  filters_hidefull = "Hide full M+ groups (5/5)",
  filters_off = "filters off",
  filters_nosearch = "open the Group Finder and run a search",
  shown = "shown",
  filtered = "filtered",
  members_fmt = "%d members",
  avgilvl_fmt = "avg ilvl %d",
  score_lbl = "score",

  -- Forces module
  pull_lbl = "pull",
  opt_f_plates = "Show per-mob forces % on nameplates (taught mobs only)",
  opt_f_pull = "Show pull-size estimate on the forces bar",

  -- Loot module (filters/advisor)
  loot_f_class_mine = "My spec",
  loot_f_class_all = "All specs",
  loot_f_all = "All",
  loot_f_slot_fmt = "Slot: %s",
  loot_filtered = "All items filtered out - loosen the class/slot filters.",
  advisor_fmt = "Loot spec advisor - %d of your favorites drop here: %s",

  -- Roster module
  col_ilvl2 = "Item level",
  roster_inbags = "in bags",

  -- Browser: group inspect + composition filters
  tt_ignored = "IGNORED players in group",
  tt_members_fmt = "%d members",
  tt_armor = "Armor",
  opt_inspectshift = "Listing group details (members/armor) only while holding Shift",
  filters_needs = "Still needs",
  filters_needshint = "(tick = must lack)",
  filters_minmembers = "Min members",
  filters_minreqilvl = "Min ilvl req",
  role_tank = "Tank",
  role_heal = "Heal",
  role_dps = "DPS",

  -- Timer / Forces
  remains = "remains",

  -- Queue: destination card
  dest_card = "Destination",
  opt_destcard = "Show the destination card with the banner (dungeon name + description)",

  -- Queue module
  opt_popsound = "Play sound when a queue pops",
  opt_flash = "Flash taskbar when a queue pops",
  opt_banner = "Show 'what did I queue for' banner",
  opt_showtimer = "Show queue timer frame while queued",
  opt_autoaccept = "Auto-accept queue pops (use with care)",
  timer_queue = "Queue:",
  timer_bg = "BG queue:",
  banner_joined = "Joined group",
  banner_pop = "Queue popped",
  banner_pop_dungeon = "Your dungeon group is ready",
  banner_bg_ready = "Battleground ready",
  banner_test = "Banner test",
  banner_test_sub = "This is how the joined-group banner looks.",
  leader_fmt = "leader: %s",

  -- M+ Timer module
  boss_par_fmt = "Boss %d/%d par %s",
  timer_scale_fmt = "Timer scale set to %.2f.",
  timer_scale_usage = "Usage: /lfgs timer scale <0.5-2>",
  elapsed = "elapsed",
  max = "max",
  in_fmt = "+%s in %s",
  missed_fmt = "+%s --",
  killed = "killed",
  not_done = "not done",

  -- Theme
  sec_theme = "Theme",
  opt_bgopacity = "Module background opacity (%)",
  note_theme = "0 = fully transparent, 100 = solid. Header strips stay slightly "
    .. "stronger so blocks remain easy to grab and drag. Quick change: /lfgs theme bg <0-100>.",
  theme_bg_fmt = "Background opacity set to %d%%.",
  theme_bg_usage = "Usage: /lfgs theme bg <0-100>",
}

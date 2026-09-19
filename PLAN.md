# LFG Suite — All-in-One LFG + Mythic+ addon: design plan

Status: Phase 0 (scaffold) · Target: WoW Retail / Midnight 12.x · License: MIT
Companion addon to **LFGAlert** (which stays untouched and shippable for now).

---

## 1. Goal & ground rules

One addon that covers the whole "list / apply / queue / run" loop:

- **Finding a group** (browse, filter, sort, vet listings)
- **Running the group** (queue QoL, applicant handling)
- **The M+ run itself** (timer, forces, run summary)
- **Between runs** (keystones, loot planning, alt/vault tracking)

Rules:

1. **New addon, new namespace** (`LFGSuite`, `/lfgs`), built in `LFGSuite/` inside this
   repo during development. When it ships, it moves to its own repo/package (see §8).
2. **No code copied** from the 15 source addons. Several are All Rights Reserved
   (KeystoneLoot, AlterEgo, Premade Sort, IFTL, MythicPlusCount, MKS Helper); two are
   GPL (Premade Groups Filter, Premade Regions); two are permissive (WarpDeplete MIT,
   LFG Inspect Public Domain). Everything is reimplemented from scratch, feature-inspired.
   GPL addons: do not read their source while writing our filter language.
3. **Every module is independently toggleable** and must not error when its Blizzard
   surface is missing (same `pcall`-defensive style as LFGAlert `Core.lua`).
4. **No duplicated features inside the addon**: one keystore, one comms channel, one
   inspect cache, one teleport service, one settings panel, one minimap button —
   shared services in Core, consumed by modules.

Name is provisional: `LFG Suite` / folder `LFGSuite` / command `/lfgs`.
Alternatives if CurseForge naming clashes: "Premade Suite", "Key & Group Suite".

---

## 2. Source inventory — what each addon contributes

| # | Addon | One-liner | Absorbed into module(s) |
|---|-------|-----------|--------------------------|
| 1 | LFGAlert (ours) | applicant alerts + log | **Applicants** (ported in Phase 2) |
| 2 | Astral Keys | guild/friends keystone list via comms, weekly affixes, auto-insert key, vault/cache | **Keystones**, **Roster** |
| 3 | Better Keystone Display | party key display + reroll advice after timed runs | **Keystones** |
| 4 | BetterBlizzQueue | queue timers, sound on pop, queue-popup QoL | **Queue** |
| 5 | Details! M+ | end-of-run scoreboard (needs Details!) | **RunSummary** (lightweight replacement, no Details dependency) |
| 6 | IFTL What Did I Queue For | "which group accepted me" banner for 2 min | **Queue** |
| 7 | KeystoneLoot | per-dungeon loot tables, favorites/BiS tiers, drop notifications, loot-spec advisor, teleports | **Loot**, teleport service in Core |
| 8 | LFG Inspect | member names + listing age + ignore warnings + raid comp on listings; applicant notes | **Browser**, **Applicants** |
| 9 | MKS Helper | own-keystone panel at Lindormi (key NPC) | **Keystones** |
| 10 | Mythic Plus Tweaks | dungeon teleports, party rating via inspect, keystone sync (multi-protocol), LFG tooltip score fixes, keystone links, always-show affixes | **Keystones** (sync), **Browser** (tooltip scores), **Timer** (affixes), teleport service |
| 11 | Premade Sort | LFG list sort by age + age display + double-click signup + role preselect + refresh keybind | **Browser** |
| 12 | Premade Groups Filter | filter UI + expression language (difficulty, comp, ilvl, leader rating, boss defeats) | **Browser** |
| 13 | Premade Regions | leader/applicant region tags + API for filters | **Browser**, **Applicants** |
| 14 | WarpDeplete | M+ timer, objectives, pulls, death log, personal bests | **Timer** |
| 15 | AlterEgo | account-wide alt roster (rating, keys, vault, lockouts, currencies), affix schedule | **Roster** |
| 16 | MythicPlusCount Midnight | per-mob forces % on nameplates/tooltips, pull counter, progress bar, teach mode, auto queue accept | **Forces**, auto-accept → **Queue** |

## 3. Dedup map — 9 modules, 16 sources

The overlaps that motivated merging (one feature, N addons doing it):

- **Keystone data**: Astral Keys + Better Keystone Display + M+ Tweaks (sync) + AlterEgo (alts) + MKS Helper → **one Keystones module + one comms service** (send once, everyone consumes).
- **LFG browse list**: Premade Sort + PGF + Premade Regions + LFG Inspect + M+ Tweaks tooltips → **one Browser module** that owns every hook into `LFGListFrame.SearchPanel`; age, region, scores, filters, sorting all render in one pass instead of five addons fighting over the same rows.
- **Dungeon teleports**: KeystoneLoot + M+ Tweaks + AlterEgo → one `NS.TeleportToDungeon(mapID)` service, buttons wherever relevant.
- **Queue pops**: BetterBlizzQueue + MPC auto-accept + IFTL banner → **one Queue module**.
- **Weekly affixes**: Astral Keys + M+ Tweaks + AlterEgo → one affix helper in Keystones, shown by Timer & Roster.
- **M+ rating lookups**: M+ Tweaks party-rating + LFG Inspect comp + PGF leader-rating filter → one inspect/rating cache service in Core.

### Module list (folder order = load order)

| Module | Key | Phase | Status | Absorbs (by # above) |
|--------|-----|-------|--------|------------------------|
| Keystones | `keystones` | 1 | **alpha** | 2, 3, 9, 10 |
| Group Browser | `browser` | 1 | **alpha** | 8, 10, 11, 12, 13 |
| Queue & Pop | `queue` | 1 | **alpha** | 4, 6, 16 |
| Applicants (leader) | `applicants` | 2 | **alpha (core)** | 1, 8, 13 |
| M+ Timer | `timer` | 3 | **alpha** | 10, 14 |
| Enemy Forces | `forces` | 3 | **alpha** | 16 |
| Run Summary | `runsummary` | 3 | **alpha** | 5 |
| Loot Planner | `loot` | 4 | **alpha** | 7 |
| Alt Roster | `roster` | 4 | **alpha** | 2, 15 |

Each module file carries a full feature checklist in its header comment (source-addon
feature → our spec), so implementation phases can be executed one checklist at a time.

## 4. Deliberately out of scope

- **Embedding/requiring Details!** — RunSummary shows *our own* numbers (time, upgrade
  result, score, deaths, forces, PB delta). No damage breakdown; Details users keep Details.
- **Raider.IO-style scoring database** — we *read* RIO's addon if installed (LFGAlert
  already does) but never ship rating data.
- **KeystoneLoot's web BiS lists / Void Core meta** — Phase 4 starts from the
  Encounter Journal API only. No scraped item databases.
- **M+ Tweaks' Tirna Scithe maze sync** — dungeon-specific helper, low Midnight value
  (Tirna is not in the Midnight S1/S2 pool per MPC data). Revisit if it returns.
- **Full profiles** (per-character settings) — until someone asks; per-module toggles
  are account-wide for now, keystone/roster data is per-character by nature.

## 5. Architecture

```
LFGSuite/
  LFGSuite.toc              # Interface 120100, SavedVariables LFGSuiteDB
  Locales/enUS.lua          # every user-facing string (LFGAlert pattern)
  Core.lua                  # namespace, DB + migration, module registry, event bus,
                            # shared services: Print, Comms, InspectCache, Teleports
  Modules/
    Keystones.lua Browser.lua Queue.lua Applicants.lua
    Timer.lua Forces.lua RunSummary.lua Loot.lua Roster.lua
  Options.lua               # one Settings panel (module toggles + per-module options),
                            # one minimap button, /lfgs slash hub
```

**Module contract** (Phase 0, already implemented in `Core.lua`):

```lua
NS.RegisterModule{
  key = "keystones", label = "Keystones", phase = 1, status = "planned",
  defaultEnabled = false,        -- planned modules default OFF until they do something
  events = { "PLAYER_ENTERING_WORLD" },
  OnLoad = function(self) end,   -- called at ADDON_LOADED, pcall-guarded
  OnEvent = function(self, event, ...) end, -- via the shared event bus, pcall-guarded
  OnEnable = function(self) end, OnDisable = function(self) end,
}
```

- One event frame total; the bus (un)registers the union of enabled modules' events.
- A module error prints once with the module key and is collected for `/lfgs errors` —
  one broken module never takes down the rest (LFGAlert `SafeBuild` philosophy).
- `NS.IsModuleEnabled(key)` / `NS.SetModuleEnabled(key, state)` drive options, slash,
  and runtime enable/disable.

**Shared services** (grow per phase, all in Core or dedicated `Services/` files):
`NS.Comms` (keystone sync; Phase 1 must decide protocol compat — see §6),
`NS.InspectCache` (party ratings), `NS.Teleports` (dungeon teleport buttons),
`NS.Affixes` (weekly schedule), locale `l()`.

## 6. Compatibility & conflicts

| Other addon | Policy |
|-------------|--------|
| **LFGAlert** | Phase 0–1: no overlap (Applicants module inert). Phase 2 ports LFGAlert in; while LFGAlert is also enabled, Applicants auto-disables itself with a chat notice (no double sounds/logs). Eventually LFGAlert's README points users here. |
| **Premade Groups Filter** | If PGF is enabled, our Browser filter panel hides (PGF wins; our row decorations still work). Never fight over list sorting: if Premade Sort or PGF sorts, ours defers. |
| **Details!** | No overlap by design. |
| **Plater / ElvUI / KUI nameplates** | Forces module hooks Blizzard nameplates first, falls back to a floating bar; never hard-hook other addons' plates — read their public APIs if needed (MPC-style compat list). |
| **Raider.IO** | Score source only (already proven in LFGAlert). |
| **Angry Keystones / Astral Keys / LibOpenRaid users** | Keystones comms: Phase 1 implements our own protocol *and* listens to the common keystone broadcast formats so we interop without those addons installed. Protocol details to be reverse-engineered from MIT/GPL sources or observed traffic at implementation time — flagged as the main research task of Phase 1. |

## 7. Roadmap

- **Phase 0 — scaffold (DONE).** Module registry, event bus, settings panel with
  per-module toggles + per-module option blocks, minimap button, `/lfgs`, locales,
  shared services (`NS.Util`, `NS.Affixes`, `NS.Comms`).
- **Phase 1 — the LFG loop (ALPHA SHIPPED, needs in-game testing).**
  Shipped: Keystones (own key + affixes + party/alt/guild registry via "LFGS"
  comms + keystone bag tooltip + auto-insert (off) + Lindormi auto-open +
  announce + alt recording), Browser (age/key-level/leader-score row tags,
  double-click signup, role memory via `ApplyToGroup` hook, `/lfgs refresh` +
  keybind), Queue (elapsed timer for LFD/LFR/BG, pop sound/flash, joined-group
  banner, auto-accept (off)).
  Deferred inside Phase 1 (tracked in module headers): age-sorting the list
  (ScrollBox reordering is fragile - moved to Phase 2), role pre-select on
  Blizzard's signup dialog, comms interop listeners (Astral/LibOpenRaid),
  reroll advisor, chat keystone-link rewriting.
  Acceptance bar before calling Phase 1 done: run the loop list → apply → run
  in-game on 12.x and fix what the defensive probes can't paper over
  (ScrollButton names, `LFG_LIST_APPLICATION_STATUS_UPDATED`, battlefield wait
  units - all pcall-guarded, worst case a feature silently no-ops).
- **Phase 2 — vetting (IN PROGRESS - Applicants core shipped).**
  Shipped: the Applicants module = a full port of LFGAlert's tracking + log
  window (alerts, lifecycle log, right-click actions, auto-decline, stats,
  filters, key per row) under `NS.A` / `db.applicants`, plus the LFGAlert
  interop rule (module goes idle while LFGAlert is enabled; `/lfgs import`
  pulls LFGAlert settings/log/stats) and `/lfgs applicants ...` commands.
  Remaining: applicant region tags, persistent applicant notes, non-leader
  applicant tooltips, Browser advanced filters + member/comp/ignore tooltips.
- **Phase 3 — the run (ALPHA SHIPPED, needs in-game testing).**
  Shipped: Timer (countdown/overtime, +2/+3 cutoffs via `GetPowerLevels` with
  60%/100% fallback, deaths, affixes, personal bests, `/lfgs timer
  unlock|lock|demo`), Forces (progress bar from the scenario-criteria probe,
  per-mob % on tooltips from a teachable DB - `/lfgs forces teach <n>`,
  ships empty by design), RunSummary (end-of-run panel: time vs cutoffs,
  upgrade result, rating change, deaths, PB + new-PB flag, party roster,
  `/lfgs summary`).
  Deferred inside Phase 3: boss objective par times, pull-count prediction,
  per-mob % ON nameplates (Blatter/ElvUI/KUI), forces timeline in summary,
  full styling options.
- **Phase 4 — meta (ALPHA SHIPPED, needs in-game testing).**
  Shipped: Loot Planner (favorites with 3 tiers per character + export/import
  `/lfgs fav`, groupmate drop alerts via CHAT_MSG_LOOT, journal-driven
  dungeon loot browser `/lfgs loot` - degrades to an "unavailable" note if the
  client's journal API shape differs), Alt Roster (per-char snapshot of
  rating/ilvl/key/vault/lockouts, sortable account-wide window `/lfgs roster`,
  Great Vault login notification, optional instance-reset announcement).
  Deferred inside Phase 4: class/spec/slot loot filters, loot-spec advisor,
  catalyst browser, dungeon teleports, seasonal currencies, cross-alt
  equipment inspection, localization pass, CurseForge launch/repo split.

## 8. Release strategy

- Dev happens in `LFGSuite/` here; `.pkgmeta` ignores it so **LFGAlert packages stay
  byte-identical** until the split.
- At first playable alpha: move `LFGSuite/` + its plan slice to a new repo
  `LFGSuite` (own `.pkgmeta`, `package-as: LFGSuite`, own CurseForge project), keep
  git history via `git subtree` or a fresh import.
- LFGAlert remains supported until LFG Suite's Applicants module reaches parity
  (Phase 2 exit), then goes maintenance-mode.

## 9. Open questions (non-blocking)

1. Final name (`LFG Suite` vs alternatives) — decide before CurseForge creation.
2. Keystones comms: pure-own protocol vs LibOpenRaid compat first. Default: own + listen-only compat.
3. Forces data seeding: ship empty + `/teach` (MPC model) vs pre-mined S1/S2 table. Default: ship a minimal starter table for current-season dungeons, extendable by teach.
4. Auto queue accept (from MPC) is a cheat-adjacent automation? No — it is a standard
   QoL toggle (Blizzard allows accepting your own queue pop), but it stays **default OFF**
   and clearly labelled.

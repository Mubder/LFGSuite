# LFG Suite

WoW Retail addon (Midnight / 12.x): the **all-in-one LFG + Mythic+ companion**. One modular addon covering the whole loop — finding a group, managing applicants, queueing, and running keys.

Status: **alpha** — all modules implemented, undergoing in-game testing. Every Blizzard API surface is probed defensively, so a renamed API degrades quietly instead of erroring.

## Modules (each toggleable in Settings → AddOns → LFG Suite)

| Module | What it does | Slash |
|--------|--------------|-------|
| **Keystones** | Own/party/guild/alt keystone registry with live sync (`LFGS` comms protocol), weekly affixes, keystone bag tooltip, auto-insert at the pedestal (off), auto-open at Lindormi | `/lfgs keys` |
| **Group Browser** | Listing age / key level / leader score tags, double-click signup with remembered roles, refresh keybind | `/lfgs refresh` |
| **Queue & Pop** | Queue timer (LFD/LFR/BG), pop sound + flash, "what did I queue for" banner, auto-accept (off) | `/lfgs banner` |
| **Applicants (leader)** | Full applicant alerts + lifecycle log window — successor to [LFGAlert](https://github.com/Mubder/LFGAlert), with one-command import | `/lfgs applicants` |
| **M+ Timer** | Run timer with +2/+3 cutoffs, deaths, affixes, personal bests | `/lfgs timer demo` |
| **Enemy Forces** | Forces progress bar + per-mob % on tooltips, community-taught data | `/lfgs forces teach` |
| **Run Summary** | End-of-run panel: time vs cutoffs, upgrade result, rating, PB | `/lfgs summary` |
| **Loot Planner** | Favorites with tiers, groupmate drop alerts, journal loot browser | `/lfgs loot` · `/lfgs fav` |
| **Alt Roster** | Account-wide alts: rating, ilvl, keys, Great Vault, lockouts | `/lfgs roster` |

`/lfgs` lists everything; `/lfgs modules` shows status; `/lfgs config` opens settings.

## Compatibility

- **LFGAlert**: the Applicants module goes idle while LFGAlert is enabled (no double alerts). `/lfgs import` pulls settings/log/stats, then disable LFGAlert to hand over.
- **Premade Sort / Premade Groups Filter**: Browser defers its age tag to Premade Sort and never fights PGF's filters.
- **Raider.IO**: used as the preferred score source when installed.
- **Details!**: no overlap — Run Summary shows run stats, not damage meters.

## Install (manual)

1. Copy the repo folder (containing `LFGSuite.toc`) into `World of Warcraft\_retail_\Interface\AddOns\` as `LFGSuite`.
2. Restart WoW. Enable "LFG Suite" in the AddOns list if needed.
3. `/lfgs version` should report the build; `/lfgs modules` lists all modules.

## Development

- Architecture: `Core.lua` (module registry + shared event bus) → `Services.lua` (Util / Affixes / Comms) → `Modules/*.lua` → `Options.lua` (settings + minimap). Feature roadmaps live in each module header and in `PLAN.md`.
- Lua 5.1, no dependencies, no embedded libraries.
- Lint: `luacheck .` (config in `.luacheckrc`; CI runs it on every push/PR).
- Releasing: tag `vX.Y.Z` and the BigWigs packager builds the CurseForge zip from `.pkgmeta`.

## Credits & licensing

MIT (see `LICENSE`). All code is original. Feature inspiration (no code copied — several sources are ARR/GPL) from: Astral Keys, Better Keystone Display, BetterBlizzQueue, Details! Mythic+, IFTL, KeystoneLoot, LFG Inspect, MKS Helper, Mythic Plus Tweaks, Premade Sort, Premade Groups Filter, Premade Regions, WarpDeplete, AlterEgo, MythicPlusCount — and our own LFGAlert, whose applicant tracking + log window this addon succeeds.

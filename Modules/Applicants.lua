-- LFG Suite - Modules/Applicants.lua
-- PHASE 2 (core shipped). Absorbs: LFGAlert (our own addon, MIT - ported),
-- LFG Inspect (applicant notes - pending), Premade Regions (pending).
--
-- This is the LFGAlert successor module. Tracking logic is a direct port of
-- LFGAlert/Core.lua (proven on Midnight 12.x), namespaced under NS.A and the
-- module DB (db.applicants). The log window lives in ApplicantsUI.lua.
--
-- Feature checklist:
--   [x] Sound + raid-warning + chat alert on new applicant (leader only)
--   [x] Applicant log with full lifecycle (queued/invited/accepted/declined/
--       cancelled/timeout), one row per applicant, history tooltip
--   [x] One-click whisper/invite/decline + right-click menu (UI file)
--   [x] min ilvl / min M+ score highlights + auto-decline (never without data)
--   [x] Dungeon/key per row (|Ku5|k sanitization + own-key fallback)
--   [x] Auto-open Group Finder applicants (deferred out of combat)
--   [x] Session separators + per-listing/all-time stats
--   [x] Interop: stays silent while LFGAlert is enabled (no double alerts)
--   [x] /lfgs import - pull settings/log/stats from LFGAlertDB
--   [ ] Applicant region tags (Premade Regions)
--   [ ] Persistent per-applicant notes (LFG Inspect)
--   [ ] Non-leader applicant tooltips + notes (LFG Inspect)

LFGSuite = LFGSuite or {}
local NS = LFGSuite
local Util = NS.Util
local L = NS.L or {}
local function l(key, fallback) return L[key] or fallback end

local APPLICANTS_DEFAULTS = {
  soundEnabled = true,
  soundID = 8959, -- SOUNDKIT RAID_WARNING
  useCustomSound = false,
  customSoundPath = "",
  useMasterChannel = true,
  raidWarning = true,
  chatMessage = true,
  flashTaskbar = true,
  autoOpenLFG = true,
  assumeOwnKey = true,
  minIlvl = 0,
  minScore = 0,
  autoDecline = false,
  maxLogEntries = 300,
  stats = { sessions = {}, total = { queued = 0, invited = 0, accepted = 0, declined = 0, auto = 0, gone = 0 } },
  log = {},
}

local A = NS.A or {}
NS.A = A
local function DB() return NS.EnsureModuleDB("applicants", APPLICANTS_DEFAULTS) end
A.db = DB

-- ---------------------------------------------------------------------------
-- LFGAlert interop: never double-alert while the original addon is running.
-- ---------------------------------------------------------------------------

local function IsAddonLoaded(name)
  if not (C_AddOns and C_AddOns.IsAddOnLoaded) then return false end
  local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, name)
  return ok and loaded or false
end

local function LFGAlertActive()
  return IsAddonLoaded("LFGAlert") and type(_G.LFGAlertDB) == "table"
    and _G.LFGAlertDB.enabled ~= false
end

local interopNoted = false
local function NoteInterop()
  if interopNoted then return end
  interopNoted = true
  NS.Print("|cffffcc00LFGAlert is also enabled - the Applicants module is idle to avoid "
    .. "double alerts. Disable LFGAlert (or /lfgalert off) to hand over, then /lfgs import.|r")
end

-- ---------------------------------------------------------------------------
-- Helpers (ported from LFGAlert/Core.lua)
-- ---------------------------------------------------------------------------

local function HasActiveListing()
  if not (C_LFGList and C_LFGList.GetActiveEntryInfo) then return false end
  local ok, info = pcall(C_LFGList.GetActiveEntryInfo)
  if not ok then return false end
  return info ~= nil
end

local function IsGroupLeader()
  if not IsInGroup() then return HasActiveListing() end
  local ok, res = pcall(UnitIsGroupLeader, "player")
  if ok and res then return true end
  return HasActiveListing()
end

local function GetSpecName(specID)
  if not specID or specID == 0 then return nil end
  local ok, _, name = pcall(GetSpecializationInfoByID, specID)
  if ok and name and name ~= "" then return name end
  return nil
end

-- Raider.IO optional score source (probes several RIO API generations).
local function GetRaiderIOScore(fullName, memo)
  if not fullName or not _G.RaiderIO then return nil end
  if memo then
    local cached = memo[fullName]
    if cached ~= nil then return cached or nil end
  end
  local score
  local RIO = _G.RaiderIO
  if type(RIO.GetScore) == "function" then
    local ok, s1, s2 = pcall(RIO.GetScore, fullName)
    if ok then
      if type(s1) == "number" and s1 > 0 then score = math.floor(s1) end
      if not score and type(s2) == "number" and s2 > 0 then score = math.floor(s2) end
    end
  end
  if not score and type(RIO.GetProfile) == "function" then
    local bare, realm = strsplit("-", fullName, 2)
    local ok, profile = pcall(RIO.GetProfile, bare, realm or GetRealmName())
    if ok and type(profile) == "table" then
      local s = profile.mythicPlusScoresBySeason
        and profile.mythicPlusScoresBySeason[1]
        and profile.mythicPlusScoresBySeason[1].scores
        and profile.mythicPlusScoresBySeason[1].scores.all
      if type(s) == "number" and s > 0 then score = math.floor(s) end
      if not score and type(profile.mplusCurrentScore) == "number" and profile.mplusCurrentScore > 0 then
        score = math.floor(profile.mplusCurrentScore)
      end
    end
  end
  if memo then memo[fullName] = score or false end
  return score
end

local function FormatScore(blizzScore, rioScore)
  rioScore = rioScore and rioScore > 0 and rioScore or nil
  blizzScore = blizzScore and blizzScore > 0 and blizzScore or nil
  local base = rioScore or blizzScore
  if not base then return "-" end
  return tostring(base)
end

-- ---------------------------------------------------------------------------
-- Listing context: dungeon + key level for the current listing
-- ---------------------------------------------------------------------------

local function GetOwnedKeystone()
  if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel and C_MythicPlus.GetOwnedKeystoneChallengeMapID) then
    return nil
  end
  local okL, lvl = pcall(C_MythicPlus.GetOwnedKeystoneLevel)
  local okM, mapID = pcall(C_MythicPlus.GetOwnedKeystoneChallengeMapID)
  if not (okL and okM and lvl and mapID and lvl >= 2) then return nil end
  local full = Util.GetChallengeMapName(mapID)
  return { key = lvl, dungeonFull = full, dungeon = full and Util.AbbrevDungeonName(full) or nil, source = "keystone" }
end

-- { dungeon="AOF", dungeonFull="Altar of Fangs", key=5, title="..." }
function A.CurrentListingInfo()
  local info = { dungeon = nil, dungeonFull = nil, key = nil, title = nil, source = nil }
  if not (C_LFGList and C_LFGList.GetActiveEntryInfo) then return info end
  local ok, entry = pcall(C_LFGList.GetActiveEntryInfo)
  if not ok or not entry then return info end
  local cleanTitle = Util.CleanKString(entry.name or "")
  info.title = cleanTitle
  local actID = (entry.activityIDs and entry.activityIDs[1]) or entry.activityID
  if actID and C_LFGList.GetActivityInfo then
    local okA, full, short = pcall(C_LFGList.GetActivityInfo, actID)
    if okA and full then
      if type(full) == "table" then
        local fn = full.fullName or full.name
        local sn = full.shortName or full.short
        if type(fn) == "string" and fn ~= "" then
          info.dungeonFull = fn
          info.dungeon = (type(sn) == "string" and sn ~= "" and #sn <= 12 and sn)
            or Util.AbbrevDungeonName(fn) or fn
        end
      elseif type(full) == "string" and full ~= "" then
        info.dungeonFull = full
        if type(short) == "string" and short ~= "" and #short <= 12 then
          info.dungeon = short
        else
          info.dungeon = Util.AbbrevDungeonName(full) or full
        end
      end
    end
  end
  info.key = Util.ParseKeyLevel(cleanTitle .. " " .. Util.CleanKString(entry.comment or ""))
  if info.dungeon == nil and info.key == nil and DB().assumeOwnKey ~= false then
    local ks = GetOwnedKeystone()
    if ks then
      info.dungeon, info.dungeonFull, info.key, info.source = ks.dungeon, ks.dungeonFull, ks.key, ks.source
    end
  end
  return info
end

-- ---------------------------------------------------------------------------
-- Applicant snapshot
-- ---------------------------------------------------------------------------

-- known[applicantID] = { status, snap }; applicantIDs reset per relist, so a
-- listingSession stamps every entry and gates ID-based actions (see UI file).
local known = {}
A._known = known
local listingSession = 1
local hadListing = false

function A.CurrentListingSession()
  return listingSession
end

local function SnapshotApplicant(applicantID, cachedListing, rioMemo)
  local infoOk, appInfo = pcall(C_LFGList.GetApplicantInfo, applicantID)
  if not infoOk or not appInfo then return nil end
  local members = {}
  local numMembers = appInfo.numMembers or 1
  for i = 1, numMembers do
    local mOk, name, class, locClass, level, itemLevel, honorLevel,
      tank, healer, damage, assignedRole, relationship,
      dungeonScore, pvpItemLevel, factionGroup, raceID, specID, isLeaver =
      pcall(C_LFGList.GetApplicantMemberInfo, applicantID, i)
    if mOk and name and type(name) == "string" then
      local saneSpec = (type(specID) == "number" and specID > 0 and specID < 10000) and specID or 0
      members[#members + 1] = {
        name = name, class = class, localizedClass = locClass,
        level = level, itemLevel = itemLevel or 0,
        dungeonScore = dungeonScore or 0,
        rioScore = GetRaiderIOScore(name, rioMemo) or 0,
        specID = saneSpec, specName = GetSpecName(saneSpec),
        role = assignedRole, tank = tank, healer = healer, damage = damage,
      }
    end
  end
  return {
    status = appInfo.applicationStatus,
    numMembers = numMembers,
    comment = Util.CleanKString(appInfo.comment) or "",
    isNew = appInfo.isNew,
    members = members,
    listing = cachedListing or A.CurrentListingInfo(),
  }
end

local function PrimaryMember(snap)
  if snap and snap.members and snap.members[1] then return snap.members[1] end
  return nil
end

local function MemberSummary(snap)
  local m = PrimaryMember(snap)
  if not m then return "?  -  ilvl -  -  M+ -" end
  local classCol = Util.ClassColorize(m.class, Util.ShortName(m.name))
  local roleTag = A.RoleTag(A.ResolveRole(m))
  local specTxt = m.specName or m.localizedClass or m.class or ""
  local ilvl = (m.itemLevel and m.itemLevel > 0) and tostring(math.floor(m.itemLevel)) or "-"
  local score = FormatScore(m.dungeonScore, m.rioScore)
  local extra = ""
  if (snap.numMembers or 1) > 1 then
    extra = " (+" .. ((snap.numMembers or 1) - 1) .. ")"
  end
  local runTag = ""
  local li = snap and snap.listing
  if li and (li.dungeon or li.key) then
    runTag = "  |cffffd100[" .. (li.key and ("+" .. li.key .. " ") or "") .. (li.dungeon or "?") .. "]|r"
  end
  return string.format("%s%s  %s  %s  ilvl %s  M+ %s%s", classCol, extra, roleTag, specTxt, ilvl, score, runTag)
end

-- ---------------------------------------------------------------------------
-- Status labels / roles
-- ---------------------------------------------------------------------------

local STATUS_META = {
  applied           = { label = l("st_applied", "QUEUED"),           color = "ffd100" },
  invited           = { label = l("st_invited", "INVITED"),          color = "5599ff" },
  inviteaccepted    = { label = l("st_inviteaccepted", "ACCEPTED"),  color = "33cc33" },
  declined          = { label = l("st_declined", "DECLINED"),        color = "ff4444" },
  declined_full     = { label = l("st_declined_full", "DECLINED (FULL)"), color = "ff4444" },
  declined_delisted = { label = l("st_declined_delisted", "DECLINED (DELISTED)"), color = "ff4444" },
  cancelled         = { label = l("st_cancelled", "CANCELLED"),      color = "999999" },
  timedout          = { label = l("st_timedout", "TIMEOUT"),         color = "ff8800" },
  failed            = { label = l("st_failed", "FAILED"),            color = "ff4444" },
  invitedeclined    = { label = l("st_invitedeclined", "DECLINED INVITE"), color = "ff8844" },
}

function A.StatusLabel(status)
  local m = STATUS_META[status]
  if m then return m.label, m.color end
  return (status or "UNKNOWN"):upper(), "ffffff"
end

function A.ResolveRole(mem)
  if mem then
    if mem.role and mem.role ~= "" then return (mem.role .. ""):upper() end
    if mem.tank then return "TANK" end
    if mem.healer then return "HEALER" end
    if mem.damage then return "DAMAGER" end
  end
  return nil
end

function A.RoleTag(role)
  local key = role and (role .. ""):upper() or ""
  local label, color, iconKey = "—", "aaaaaa", nil
  if key == "TANK" then
    label, color, iconKey = l("role_tank", "Tank"), "5b9bff", "INLINE_TANK_ICON"
  elseif key == "HEALER" then
    label, color, iconKey = l("role_healer", "Heal"), "4dff4d", "INLINE_HEALER_ICON"
  elseif key == "DAMAGER" then
    label, color, iconKey = l("role_dps", "DPS"), "ff6b6b", "INLINE_DAMAGER_ICON"
  end
  local icon = (iconKey and _G[iconKey]) or ""
  if icon ~= "" then icon = icon .. " " end
  return icon .. "|cff" .. color .. label .. "|r", label
end

-- ---------------------------------------------------------------------------
-- Log + stats
-- ---------------------------------------------------------------------------

local function TrimLog()
  local maxN = DB().maxLogEntries or 300
  local log = DB().log
  while #log > maxN do table.remove(log, 1) end
end

local function SnapHasData(snap)
  return snap and snap.members and snap.members[1]
    and type(snap.members[1].name) == "string" and true or false
end

local function CopySnapMembers(dest, snap)
  if not (snap and snap.members) then return end
  for i, mem in ipairs(snap.members) do
    dest[i] = {
      name = mem.name, class = mem.class, localizedClass = mem.localizedClass,
      specName = mem.specName, level = mem.level, itemLevel = mem.itemLevel,
      dungeonScore = mem.dungeonScore, rioScore = mem.rioScore, role = mem.role,
    }
    if i >= 8 then break end
  end
end

local autoPending = {}

local function BucketFor(status)
  if status == "applied" then return "queued" end
  if status == "invited" then return "invited" end
  if status == "inviteaccepted" then return "accepted" end
  if status == "cancelled" or status == "timedout" then return "gone" end
  return "declined"
end

local function EnsureStats()
  local db = DB()
  if type(db.stats) ~= "table" then
    db.stats = { sessions = {}, total = { queued = 0, invited = 0, accepted = 0, declined = 0, auto = 0, gone = 0 } }
  end
  if type(db.stats.sessions) ~= "table" then db.stats.sessions = {} end
  if type(db.stats.total) ~= "table" then
    db.stats.total = { queued = 0, invited = 0, accepted = 0, declined = 0, auto = 0, gone = 0 }
  end
  return db.stats
end

function A.RecordStat(applicantID, status, session)
  if not applicantID or applicantID == 0 then return end
  local st = EnsureStats()
  local bucket = BucketFor(status)
  if bucket == "declined" and autoPending[applicantID] then
    autoPending[applicantID] = nil
    bucket = "auto"
  end
  session = session or listingSession
  local sess = st.sessions[session]
  if not sess then
    sess = { queued = 0, invited = 0, accepted = 0, declined = 0, auto = 0, gone = 0, started = time() }
    st.sessions[session] = sess
    local n = 0
    for _ in pairs(st.sessions) do n = n + 1 end
    while n > 30 do
      local oldest, oldestKey = nil, nil
      for k, v in pairs(st.sessions) do
        if oldest == nil or (v.started or 0) < oldest then oldest, oldestKey = (v.started or 0), k end
      end
      if oldestKey == nil then break end
      st.sessions[oldestKey] = nil
      n = n - 1
    end
  end
  sess[bucket] = (sess[bucket] or 0) + 1
  st.total[bucket] = (st.total[bucket] or 0) + 1
end

local function StatLine(label, s)
  s = s or {}
  local q, a, d, au = s.queued or 0, s.accepted or 0, s.declined or 0, s.auto or 0
  local rate = q > 0 and math.floor(a / q * 100 + 0.5) or 0
  local autoTxt = au > 0 and l("stats_auto_paren", " (%d auto)"):format(au) or ""
  return l("stats_line_fmt", "%s: %d queued • %d accepted (%d%%) • %d declined%s • %d invited • %d left")
    :format(label, q, a, rate, d + au, autoTxt, s.invited or 0, s.gone or 0)
end

function A.PrintStats()
  local st = EnsureStats()
  NS.Print("|cffffcc00" .. l("stats_header", "Applicant stats:") .. "|r")
  local cur = st.sessions[listingSession]
  if cur and (cur.queued or 0) > 0 then
    print("  " .. StatLine(l("this_listing", "This listing"), cur))
  else
    print("  " .. l("this_listing_none", "This listing: no queues yet"))
  end
  print("  " .. StatLine(l("all_time", "All time"), st.total))
  local n, ilvlSum, scoreSum, scoreN = 0, 0, 0, 0
  for _, e in ipairs(DB().log or {}) do
    if not e.separator and e.status == "inviteaccepted" and e.members and e.members[1] and e.members[1].name then
      local m = e.members[1]
      n = n + 1
      ilvlSum = ilvlSum + (m.itemLevel or 0)
      local sc = A.EffectiveScore(m)
      if sc > 0 then scoreSum, scoreN = scoreSum + sc, scoreN + 1 end
    end
  end
  if n > 0 then
    local scTxt = scoreN > 0 and l("stats_avg_score", " M+ %d"):format(math.floor(scoreSum / scoreN + 0.5)) or ""
    print(l("stats_avg_fmt", "  Accepted avg (n=%d): ilvl %d%s"):format(n, math.floor(ilvlSum / n + 0.5), scTxt))
  end
end

function A.AddLogEntry(applicantID, oldStatus, newStatus, snap, isNewApplicant)
  local db = DB()
  local m = PrimaryMember(snap)
  local li = (snap and snap.listing) or A.CurrentListingInfo()
  local log = db.log

  local entry
  for i = #log, 1, -1 do
    local e = log[i]
    if e and not e.separator and e.applicantID == applicantID
      and (e.session == nil or e.session == listingSession) then
      entry = e
      break
    end
  end

  local now = time()
  if entry then
    entry.oldStatus = oldStatus
    entry.status = newStatus
    if newStatus == "applied" then entry.t = now end
    if SnapHasData(snap) then
      wipe(entry.members)
      CopySnapMembers(entry.members, snap)
    end
    entry.numMembers = (snap and snap.numMembers) or entry.numMembers or 1
    if snap and snap.comment and snap.comment ~= "" then entry.comment = snap.comment end
    if entry.dungeon == nil and li then
      entry.dungeon, entry.dungeonFull, entry.key, entry.keySource, entry.listingTitle =
        li.dungeon, li.dungeonFull, li.key, li.source, li.title
    end
    entry.history = entry.history or {}
    entry.history[#entry.history + 1] = { status = newStatus, t = now }
    if #entry.history > 8 then table.remove(entry.history, 1) end
  else
    entry = {
      t = now, applicantID = applicantID, oldStatus = oldStatus, status = newStatus,
      isNew = isNewApplicant and true or false,
      comment = (snap and snap.comment) or "",
      numMembers = (snap and snap.numMembers) or (m and 1) or 1,
      members = {}, detailShown = SnapHasData(snap),
      dungeon = li and li.dungeon or nil, dungeonFull = li and li.dungeonFull or nil,
      key = li and li.key or nil, keySource = li and li.source or nil,
      listingTitle = li and li.title or nil,
      session = listingSession, history = { { status = newStatus, t = now } },
    }
    CopySnapMembers(entry.members, snap)
    log[#log + 1] = entry
  end
  if BucketFor(newStatus) == "declined" and A._autoReason then
    local ar = A._autoReason[applicantID]
    if ar and (ar.session == nil or ar.session == listingSession) then
      entry.declineReason = ar.text or "Auto"
      entry.autoDeclined = true
    end
    A._autoReason[applicantID] = nil
  end
  TrimLog()
  A.RecordStat(applicantID, newStatus, entry.session)
  if A.RefreshLogUI then A.RefreshLogUI() end
  return entry
end

function A.ClearLog()
  DB().log = {}
  if A.RefreshLogUI then A.RefreshLogUI() end
end

-- ---------------------------------------------------------------------------
-- Alerts / thresholds / auto-decline
-- ---------------------------------------------------------------------------

function A.PlayAlertSound()
  local db = DB()
  if not db.soundEnabled then return end
  local channel = db.useMasterChannel and "Master" or nil
  if db.useCustomSound and db.customSoundPath and db.customSoundPath ~= "" then
    local ok, played = pcall(PlaySoundFile, db.customSoundPath, channel)
    if ok and played ~= false then return end
  end
  local id = tonumber(db.soundID) or 8959
  local ok = pcall(PlaySound, id, channel)
  if not ok then pcall(PlaySound, 8959, channel) end
end

function A.EffectiveScore(mem)
  if not mem then return 0 end
  if mem.rioScore and mem.rioScore > 0 then return mem.rioScore end
  return mem.dungeonScore or 0
end

function A.MeetsThresholds(mem)
  if not mem then return true, true, true end
  local db = DB()
  local minIlvl = db.minIlvl or 0
  local minScore = db.minScore or 0
  local meetsIlvl = minIlvl <= 0 or (mem.itemLevel or 0) >= minIlvl
  local meetsScore = minScore <= 0 or A.EffectiveScore(mem) >= minScore
  return meetsIlvl, meetsScore, (meetsIlvl and meetsScore)
end

local function CenterMessage(text)
  if not DB().raidWarning then return end
  if RaidWarningFrame and RaidNotice_AddMessage then
    local ok = pcall(RaidNotice_AddMessage, RaidWarningFrame, text, ChatTypeInfo and ChatTypeInfo["RAID_WARNING"])
    if ok then return end
  end
  if UIErrorsFrame then
    pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, text, 1, 0.2, 0.2, 1.0, 5)
  end
end

local function ChatMessage(text)
  if not DB().chatMessage then return end
  print("|cffff2020[Applicants]|r " .. text)
end

function A.AlertNewApplicant(applicantID, snap)
  A.PlayAlertSound()
  local db = DB()
  if db.flashTaskbar and FlashClientIcon then
    pcall(FlashClientIcon)
  end
  if db.autoOpenLFG then
    A.OpenApplicants()
  end
  if not SnapHasData(snap) then
    CenterMessage(l("alert_banner", "New applicant!"))
    return
  end
  local summary = MemberSummary(snap)
  local pm = PrimaryMember(snap)
  local name = pm and pm.name or ("#" .. tostring(applicantID))
  local _, rolePlain = A.RoleTag(A.ResolveRole(pm))
  CenterMessage(l("alert_center_fmt", "New applicant: %s (%s)"):format(Util.ShortName(name), rolePlain))
  ChatMessage(l("alert_chat_fmt", "New applicant: %s"):format(summary))
  if snap and snap.comment and snap.comment ~= "" then
    ChatMessage(l("note_fmt", 'Note: "%s"'):format(snap.comment))
  end
end

function A.AnnounceStatusChange(applicantID, oldStatus, newStatus, snap)
  local label, color = A.StatusLabel(newStatus)
  local summary = MemberSummary(snap)
  ChatMessage(string.format("%s: |cff%s%s|r - %s",
    Util.ShortName(PrimaryMember(snap) and PrimaryMember(snap).name or ("#" .. applicantID)), color, label, summary))
end

local function BackfillLogEntry(applicantID, snap)
  if not SnapHasData(snap) then return false end
  local db = DB()
  local changed = false
  for _, e in ipairs(db.log) do
    if not e.separator and e.applicantID == applicantID and (e.session == nil or e.session == listingSession) then
      local em = e.members and e.members[1]
      if not (em and em.name) then
        e.members = e.members or {}
        CopySnapMembers(e.members, snap)
        e.numMembers = snap.numMembers or e.numMembers
        if snap.comment and snap.comment ~= "" then e.comment = snap.comment end
        if e.dungeon == nil and snap.listing and snap.listing.dungeon then
          e.dungeon, e.dungeonFull, e.key, e.keySource, e.listingTitle =
            snap.listing.dungeon, snap.listing.dungeonFull, snap.listing.key, snap.listing.source, snap.listing.title
        end
        if not e.detailShown then
          e.detailShown = true
          local sum = MemberSummary({ members = e.members, numMembers = e.numMembers,
            comment = e.comment, listing = snap.listing })
          ChatMessage(l("alert_chat_fmt", "New applicant: %s"):format(sum))
          if e.comment and e.comment ~= "" then
            ChatMessage(l("note_fmt", 'Note: "%s"'):format(e.comment))
          end
        end
        A.MaybeAutoDecline(applicantID, snap)
        changed = true
      end
    end
  end
  if changed and A.RefreshLogUI then A.RefreshLogUI() end
  return changed
end
A.BackfillLogEntry = BackfillLogEntry

function A.MaybeAutoDecline(applicantID, snap)
  local db = DB()
  if not db.autoDecline then return false end
  if not applicantID or applicantID == 0 then return false end
  if not ((db.minIlvl or 0) > 0 or (db.minScore or 0) > 0) then return false end
  local m = snap and snap.members and snap.members[1]
  if not (m and m.name) then return false end
  local ok, info = pcall(C_LFGList.GetApplicantInfo, applicantID)
  if not (ok and info and info.applicationStatus == "applied") then return false end
  local reasons = {}
  local ilvlFail, scoreFail = false, false
  if (db.minIlvl or 0) > 0 and (m.itemLevel or 0) > 0 and m.itemLevel < db.minIlvl then
    ilvlFail = true
    reasons[#reasons + 1] = "ilvl " .. math.floor(m.itemLevel) .. " < " .. db.minIlvl
  end
  if (db.minScore or 0) > 0 then
    local sc = A.EffectiveScore(m)
    if sc > 0 and sc < db.minScore then
      scoreFail = true
      reasons[#reasons + 1] = "M+ " .. math.floor(sc) .. " < " .. db.minScore
    end
  end
  if #reasons == 0 then return false end
  autoPending[applicantID] = true
  A._autoReason = A._autoReason or {}
  A._autoReason[applicantID] = {
    text = (ilvlFail and scoreFail) and l("ar_both", "Low ILvl/M+")
      or (ilvlFail and l("ar_ilvl", "Low ILvl") or l("ar_score", "Low M+")),
    session = listingSession,
  }
  pcall(C_LFGList.DeclineApplicant, applicantID)
  ChatMessage(l("auto_declined_fmt", "Auto-declined %s (%s)"):format(
    Util.ShortName(m.name), table.concat(reasons, ", ")))
  return true
end

-- ---------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------

local TERMINAL_STATUSES = {
  declined = true, declined_full = true, declined_delisted = true,
  cancelled = true, timedout = true, failed = true,
  inviteaccepted = true, invitedeclined = true,
}

local function IsApplicantPresent(applicantID)
  if not applicantID or not (C_LFGList and C_LFGList.GetApplicants) then return false end
  local ok, ids = pcall(C_LFGList.GetApplicants)
  if not ok or type(ids) ~= "table" then return false end
  for _, id in ipairs(ids) do if id == applicantID then return true end end
  return false
end

local function HandleApplicantGone(applicantID)
  local prev = known[applicantID]
  if not prev or not prev.status or TERMINAL_STATUSES[prev.status] then return end
  local old = prev.status
  local newStatus = (old == "invited") and "inviteaccepted" or "cancelled"
  known[applicantID] = { status = newStatus, snap = prev.snap, gone = true }
  A.AddLogEntry(applicantID, old, newStatus, prev.snap, false)
  A.AnnounceStatusChange(applicantID, old, newStatus, prev.snap)
end

local function HandleApplicantSnapshot(applicantID, snap, reason)
  if not snap then return end
  local prev = known[applicantID]
  if not prev then
    known[applicantID] = { status = snap.status, snap = snap }
    A.AddLogEntry(applicantID, nil, snap.status or "applied", snap, true)
    if snap.status == "applied" then
      A.AlertNewApplicant(applicantID, snap)
      A.MaybeAutoDecline(applicantID, snap)
    else
      A.AnnounceStatusChange(applicantID, nil, snap.status, snap)
    end
  elseif prev.status ~= snap.status then
    local old = prev.status
    known[applicantID] = { status = snap.status, snap = snap }
    A.AddLogEntry(applicantID, old, snap.status, snap, false)
    A.AnnounceStatusChange(applicantID, old, snap.status, snap)
    if snap.status == "applied" and reason == "list" then
      A.PlayAlertSound()
    end
  else
    prev.snap = snap
    BackfillLogEntry(applicantID, snap)
  end
end

local function ScanApplicants(reason, retryN)
  if not NS.IsModuleEnabled("applicants") then return end
  if LFGAlertActive() then NoteInterop() return end
  if not HasActiveListing() then return end
  if not IsGroupLeader() then return end
  if not C_LFGList.GetApplicants then return end

  local ok, ids = pcall(C_LFGList.GetApplicants)
  if not ok or type(ids) ~= "table" then return end

  local listing = A.CurrentListingInfo()
  local rioMemo = {}
  local missingData = false
  local seen = {}
  for _, applicantID in ipairs(ids) do
    seen[applicantID] = true
    local snap = SnapshotApplicant(applicantID, listing, rioMemo)
    if snap then
      if not SnapHasData(snap) then missingData = true end
      HandleApplicantSnapshot(applicantID, snap, reason)
    end
  end
  for id in pairs(known) do
    if not seen[id] then HandleApplicantGone(id) end
  end

  retryN = retryN or 0
  if missingData and retryN < 4 and HasActiveListing() then
    C_Timer.After(2, function() ScanApplicants(reason, retryN + 1) end)
  end
end

function A.Rescan(reason)
  C_Timer.After(0.5, function() ScanApplicants(reason or "list", 0) end)
end

function A.WipeKnown(reasonLabel)
  if reasonLabel then
    local st = EnsureStats()
    local s = st and st.sessions[listingSession]
    if s and (s.queued or 0) > 0 then
      ChatMessage(StatLine(l("listing_over", "Listing over"), s))
    end
  end
  wipe(known)
  wipe(autoPending)
  if A._autoReason then wipe(A._autoReason) end
  if reasonLabel then
    local db = DB()
    db.log[#db.log + 1] = { t = time(), separator = l("sep_ended", "— listing ended —") }
    TrimLog()
    if A.RefreshLogUI then A.RefreshLogUI() end
  end
end

-- ---------------------------------------------------------------------------
-- Open Blizzard's Group Finder on the applicant list (combat-deferred)
-- ---------------------------------------------------------------------------

local pendingOpenLFG = false

function A.OpenApplicants()
  if InCombatLockdown and InCombatLockdown() then
    pendingOpenLFG = true
    return
  end
  if C_AddOns and C_AddOns.LoadAddOn then
    pcall(C_AddOns.LoadAddOn, "Blizzard_GroupFinder")
  end
  if GroupFinderFrame and PVEFrame_ShowFrame then
    local okV, vis = pcall(GroupFinderFrame.IsVisible, GroupFinderFrame)
    if not okV or not vis then
      pcall(PVEFrame_ShowFrame, "GroupFinderFrame")
    end
  elseif PVEFrame and PVEFrame.Show then
    local okV, vis = pcall(PVEFrame.IsShown, PVEFrame)
    if not okV or not vis then
      pcall(PVEFrame.Show, PVEFrame)
    end
  end
  if LFGListFrame and LFGListFrame.ApplicationViewer and LFGListFrame_SetActivePanel then
    pcall(LFGListFrame_SetActivePanel, LFGListFrame, LFGListFrame.ApplicationViewer)
  end
end

-- ---------------------------------------------------------------------------
-- Row actions (called from the UI file)
-- ---------------------------------------------------------------------------

function A.Whisper(name)
  if not name or name == "" then return end
  if ChatFrame_OpenChat then
    local frame = SELECTED_CHAT_FRAME or DEFAULT_CHAT_FRAME
    pcall(ChatFrame_OpenChat, ("/w %s "):format(name), frame)
  else
    print("|cffff2020[Applicants]|r /w " .. name)
  end
end

function A.InviteApplicantByID(applicantID)
  if applicantID and C_LFGList and C_LFGList.InviteApplicant then
    pcall(C_LFGList.InviteApplicant, applicantID)
  end
end

function A.DeclineApplicantByID(applicantID)
  if applicantID and C_LFGList and C_LFGList.DeclineApplicant then
    pcall(C_LFGList.DeclineApplicant, applicantID)
  end
end

function A.InviteByName(name)
  if not name or name == "" then return end
  if C_PartyInfo and C_PartyInfo.InviteUnit then
    pcall(C_PartyInfo.InviteUnit, name)
  elseif InviteUnit then
    pcall(InviteUnit, name)
  end
end

-- ---------------------------------------------------------------------------
-- Import from LFGAlert
-- ---------------------------------------------------------------------------

local function ImportFromLFGAlert()
  local src = _G.LFGAlertDB
  if type(src) ~= "table" then
    NS.Print(l("import_none", "No LFGAlert data found (is LFGAlert installed?)."))
    return
  end
  local db = DB()
  local fields = {
    "soundEnabled", "soundID", "useCustomSound", "customSoundPath", "useMasterChannel",
    "raidWarning", "chatMessage", "flashTaskbar", "autoOpenLFG", "assumeOwnKey",
    "minIlvl", "minScore", "autoDecline", "maxLogEntries",
  }
  for _, f in ipairs(fields) do
    if src[f] ~= nil then db[f] = src[f] end
  end
  if type(src.log) == "table" then db.log = src.log end
  if type(src.stats) == "table" then db.stats = src.stats end
  NS.Print(string.format(l("import_done_fmt", "Imported LFGAlert settings, log (%d entries) and stats."),
    #(src.log or {})))
  if A.RefreshLogUI then A.RefreshLogUI(true) end
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local M = {
  key = "applicants",
  label = "Applicants (leader)",
  desc = "LFGAlert successor: alerts, log window, auto-decline, stats",
  phase = 2,
  status = "alpha",
  defaultEnabled = true,
  events = {
    "LFG_LIST_APPLICANT_LIST_UPDATED", "LFG_LIST_APPLICANT_UPDATED",
    "LFG_LIST_ACTIVE_ENTRY_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
  },
  OnLoad = function()
    DB()
    if LFGAlertActive() then NoteInterop() end
  end,
  OnEnable = function()
    DB()
    if LFGAlertActive() then NoteInterop() end
  end,
  OnDisable = function()
    wipe(known)
    if A._logFrame then A._logFrame:Hide() end
  end,
  OnEvent = function(_, event, ...)
    if LFGAlertActive() then NoteInterop() return end
    local applicantID = ...

    if event == "PLAYER_REGEN_ENABLED" then
      if pendingOpenLFG then
        pendingOpenLFG = false
        A.OpenApplicants()
      end
      return
    end

    if event == "LFG_LIST_APPLICANT_LIST_UPDATED" then
      A.Rescan("list")
    elseif event == "LFG_LIST_APPLICANT_UPDATED" then
      if applicantID then
        C_Timer.After(0.3, function()
          if LFGAlertActive() or not HasActiveListing() then return end
          local snap = SnapshotApplicant(applicantID)
          if not snap then
            if IsApplicantPresent(applicantID) then
              A.Rescan("retry")
            else
              HandleApplicantGone(applicantID)
            end
            return
          end
          HandleApplicantSnapshot(applicantID, snap, "updated")
          if not SnapHasData(snap) then
            local prev = known[applicantID]
            if prev then
              local n = (prev.retries or 0) + 1
              prev.retries = n
              if n <= 4 then
                C_Timer.After(2, function()
                  if LFGAlertActive() or not HasActiveListing() then return end
                  local s2 = SnapshotApplicant(applicantID)
                  if s2 then
                    local p2 = known[applicantID]
                    if p2 then p2.snap = s2 end
                    BackfillLogEntry(applicantID, s2)
                  elseif not IsApplicantPresent(applicantID) then
                    HandleApplicantGone(applicantID)
                  end
                end)
              end
            end
          end
        end)
      else
        A.Rescan("updated")
      end
    elseif event == "LFG_LIST_ACTIVE_ENTRY_UPDATE" then
      if HasActiveListing() then
        if not hadListing then listingSession = listingSession + 1 end
        hadListing = true
        A.Rescan("entry")
      else
        hadListing = false
        A.WipeKnown("ended")
      end
    elseif event == "PLAYER_ENTERING_WORLD" then
      C_Timer.After(2, function() ScanApplicants("login") end)
    end
  end,
  OnOptions = function(ctx)
    ctx.AddCB(l("opt_ap_sound", "Play sound on new application"),
      function() return DB().soundEnabled end, function(v) DB().soundEnabled = v end)
    ctx.AddCB(l("opt_ap_rw", "Show raid-warning in screen center"),
      function() return DB().raidWarning end, function(v) DB().raidWarning = v end)
    ctx.AddCB(l("opt_ap_chat", "Show chat message"),
      function() return DB().chatMessage end, function(v) DB().chatMessage = v end)
    ctx.AddCB(l("opt_ap_flash", "Flash taskbar on new application"),
      function() return DB().flashTaskbar end, function(v) DB().flashTaskbar = v end)
    ctx.AddCB(l("opt_ap_open", "Open Group Finder applicants on new queue"),
      function() return DB().autoOpenLFG ~= false end, function(v) DB().autoOpenLFG = v end)
    ctx.AddCB(l("opt_ap_autodecline", "Auto-decline below thresholds (only with real data)"),
      function() return DB().autoDecline end, function(v) DB().autoDecline = v end)
    ctx.Note(l("opt_ap_thresh_note", "Thresholds: /lfgs applicants minilvl <n> and minscore <n> (0 = off)."))
  end,
}
NS.RegisterModule(M)

-- ---------------------------------------------------------------------------
-- Slash: /lfgs applicants ...
-- ---------------------------------------------------------------------------

NS.SlashHandlers = NS.SlashHandlers or {}
NS.SlashHandlers.applicants = function(rest)
  local cmd, arg = rest:match("^(%S*)%s*(.-)$")
  local db = DB()
  if cmd == "" or cmd == "show" or cmd == "log" then
    if A.ToggleLogUI then A.ToggleLogUI(true) end
  elseif cmd == "hide" then
    if A.ToggleLogUI then A.ToggleLogUI(false) end
  elseif cmd == "toggle" then
    if A.ToggleLogUI then A.ToggleLogUI() end
  elseif cmd == "clear" then
    A.ClearLog()
    NS.Print("Applicant log cleared.")
  elseif cmd == "test" then
    A.PlayAlertSound()
    CenterMessage("Applicants test: sound + warning OK")
    A.AddLogEntry(0, nil, "applied", {
      status = "applied", numMembers = 1, comment = "Test entry (/lfgs applicants clear to remove)",
      listing = { dungeon = "AOF", dungeonFull = "Altar of Fangs", key = 5, title = "Test group" },
      members = { { name = UnitName("player") or "TestPlayer", class = select(2, UnitClass("player")) or "WARRIOR",
        localizedClass = select(1, UnitClass("player")) or "Warrior", level = UnitLevel("player") or 80,
        itemLevel = 600, dungeonScore = 1500, rioScore = 0, specName = "Test", role = "DAMAGER" } },
    }, true)
    if A.ToggleLogUI then A.ToggleLogUI(true) end
  elseif cmd == "sound" then
    local id = tonumber(arg)
    if id then
      db.soundID = id
      db.useCustomSound = false
      db.soundEnabled = true
      NS.Print("Sound set to " .. id .. " (playing...)")
      A.PlayAlertSound()
    else
      db.soundEnabled = not db.soundEnabled
      NS.Print("Sound " .. (db.soundEnabled and "ON" or "OFF"))
    end
  elseif cmd == "minilvl" or cmd == "minscore" then
    local n = math.max(0, math.floor(tonumber(arg) or 0))
    db[cmd == "minilvl" and "minIlvl" or "minScore"] = n
    NS.Print((cmd == "minilvl" and "Min item level: " or "Min M+ score: ") .. (n > 0 and tostring(n) or "OFF"))
    if A.RefreshLogUI then A.RefreshLogUI(true) end
  elseif cmd == "autodecline" then
    if arg == "on" then db.autoDecline = true
    elseif arg == "off" then db.autoDecline = false
    else db.autoDecline = not db.autoDecline end
    NS.Print("Auto-decline " .. (db.autoDecline and "ON" or "OFF"))
  elseif cmd == "stats" then
    A.PrintStats()
  elseif cmd == "filter" then
    if A.SetLogFilter then A.SetLogFilter(arg ~= "" and arg or "ALL") end
    if A.ToggleLogUI then A.ToggleLogUI(true) end
  elseif cmd == "open" then
    A.OpenApplicants()
  elseif cmd == "resetui" then
    if A.ResetUI then A.ResetUI() end
    NS.Print("Log window reset (position / size / scale).")
  else
    NS.Print("/lfgs applicants show|hide|toggle|clear|test|stats|filter|open|resetui")
    NS.Print("/lfgs applicants sound [<id>]|minilvl <n>|minscore <n>|autodecline [on|off]")
  end
end
NS.SlashHandlers.import = function() ImportFromLFGAlert() end

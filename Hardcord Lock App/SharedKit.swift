//
//  SharedKit.swift
//  Hardcord Lock App
//
//  Shared between the main app AND the DeviceActivityManager extension.
//  Keep imports limited to frameworks available inside the extension
//  (Foundation / FamilyControls / ManagedSettings / DeviceActivity).
//  NEVER import SwiftUI/UIKit here.
//
//  This file is the single source of truth for:
//   - the App Group container (cross-process storage),
//   - named ManagedSettings stores (isolating manual / schedule / AI shields),
//   - the Codable models for Schedule mode + AI mode,
//   - week-parity math for "every N weeks",
//   - the on-device usage histogram the AI mode learns from.
//

import Foundation
import FamilyControls
import ManagedSettings
import DeviceActivity
import UserNotifications

// MARK: - App Group container

/// Cross-process storage shared by the app and its extensions.
/// REQUIRES `group.com.bluewave.hardcorelock` in every target's entitlements
/// (and registered in the Apple Developer portal). If the group is missing,
/// `UserDefaults(suiteName:)` is nil and sharing silently fails — we assert in DEBUG.
enum AppGroup {
    static let id = "group.com.bluewave.hardcorelock"

    /// Resolved once: `defaults` is read on hot paths (including a SwiftUI body),
    /// so don't re-resolve the suite on every access.
    private static let suite: UserDefaults? = UserDefaults(suiteName: id)

    /// `UserDefaults(suiteName:)` succeeds even without the entitlement (it then
    /// writes to a private, unshared plist), so check the container itself. When
    /// this is false the extension can't see schedules and nothing auto-blocks.
    static var isConfigured: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
    }

    static var defaults: UserDefaults {
        if let d = suite { return d }
        #if DEBUG
        assertionFailure("App Group \(id) is not configured. Add it to all target entitlements.")
        #endif
        return .standard
    }
}

// MARK: - Persisted keys

enum StoreKeys {
    /// Encoded FamilyActivitySelection for the manual (NOW) mode.
    static let manualSelection = "selection.manual"
    /// Encoded [ScheduleConfig].
    static let schedules = "schedules.v1"
    /// Encoded FamilyActivitySelection per schedule id.
    static func scheduleSelection(_ id: String) -> String { "selection.schedule.\(id)" }
    /// Encoded AIConfig.
    static let aiConfig = "ai.config.v1"
    /// Encoded FamilyActivitySelection the AI mode watches.
    static let aiSelection = "selection.ai"
    /// Encoded AIStats (the learned usage histogram).
    static let aiStats = "ai.stats.v1"
    /// Number of DeviceActivity activities each subsystem currently owns
    /// (so the other can respect the 20-activity system cap).
    static let scheduleActivityCount = "budget.schedule"
    static let aiActivityCount = "budget.ai"
    /// [[startMin, endMin]] per registered AI window, by window index, so the
    /// extension knows which hours a window that just ended actually watched.
    static let aiWindowLayout = "ai.windows.v1"
    /// Free-trial bookkeeping (shared: the monitor extension both reads and
    /// increments the schedule counter when a scheduled session fires).
    static let proPurchased = "pro.purchased"
    static let scheduleTrialCount = "trial.schedule.count"
    static let aiTrialCount = "trial.ai.count"
    /// Encoded ManualLockRecord — the running NOW / AI lock (see LockGuard).
    static let manualLock = "lock.manual.v2"
    /// Frozen snapshot of what the running manual lock blocks. Separate from
    /// `manualSelection` (the picker's draft) so editing the picker can't change
    /// a lock that is already running.
    static let manualLockSelection = "selection.manual.lock"
    static let preventUninstall = "hardcore.preventUninstall"
    static let heartbeatEvent = "ext.heartbeat.event"
    static let heartbeatTime = "ext.heartbeat.time"
    /// Encoded HabitModel (the Bayesian per-weekday model).
    static let aiModel = "ai.model.v2"
    /// Encoded LeadBandit + today's pinned arm ("yyyy-MM-dd|minutes").
    static let leadBandit = "ai.leadBandit.v1"
    static let leadChoice = "ai.leadChoice"
    /// One-line nudge copy written by the on-device language model, if any.
    static let coachNudgeLine = "ai.coach.nudgeLine"
}

// MARK: - Free-trial gate

/// Each mode gets `limit` free uses before Pro is required.
/// Manual (NOW) locks keep their original counter in the app's own defaults;
/// Schedule and AI counters live in the App Group so the monitor extension —
/// which fires scheduled sessions with the app closed — can enforce and count.
enum TrialGate {
    static let limit = 3

    static var isPro: Bool { AppGroup.defaults.bool(forKey: StoreKeys.proPurchased) }
    static func setPro(_ value: Bool) { AppGroup.defaults.set(value, forKey: StoreKeys.proPurchased) }

    static var scheduleUsesRemaining: Int {
        max(0, limit - AppGroup.defaults.integer(forKey: StoreKeys.scheduleTrialCount))
    }
    static var aiUsesRemaining: Int {
        max(0, limit - AppGroup.defaults.integer(forKey: StoreKeys.aiTrialCount))
    }

    private static func sessionKey(_ scheduleId: String) -> String { "trial.sch.session.\(scheduleId)" }

    /// Count one fired scheduled session and remember which day it ran for this
    /// schedule. The day stamp does double duty: it lets the overnight morning
    /// half verify its evening half was paid, AND it makes the charge idempotent
    /// (iOS re-delivers intervalDidStart every time we re-register a monitor
    /// mid-window, which happens on every foreground — without this a user would
    /// burn all three free sessions just by opening the app three times).
    static func recordScheduleUse(scheduleId: String, dayKey: String) {
        AppGroup.defaults.set(AppGroup.defaults.integer(forKey: StoreKeys.scheduleTrialCount) + 1,
                              forKey: StoreKeys.scheduleTrialCount)
        AppGroup.defaults.set(dayKey, forKey: sessionKey(scheduleId))
    }

    /// Has this schedule's session for `dayKey` already been charged?
    static func sessionCounted(scheduleId: String, dayKey: String) -> Bool {
        AppGroup.defaults.string(forKey: sessionKey(scheduleId)) == dayKey
    }

    /// The morning half of an overnight window continues last night's session,
    /// which was already charged — it is not a new one.
    private static func isOvernightContinuation(_ config: ScheduleConfig, now: Date) -> Bool {
        guard config.isOvernight, AIStatsStore.minuteOfDay(for: now) < config.endMinutes else { return false }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        return sessionCounted(scheduleId: config.id, dayKey: AIStatsStore.dayKey(for: yesterday))
    }

    /// May this schedule block at `now`? PURE — charges nothing, so it is safe
    /// to call from a SwiftUI body. Use `claimSession` when actually shielding.
    static func sessionEntitled(_ config: ScheduleConfig, now: Date) -> Bool {
        if isPro { return true }
        if sessionCounted(scheduleId: config.id, dayKey: AIStatsStore.dayKey(for: now)) { return true }
        if isOvernightContinuation(config, now: now) { return true }
        return scheduleUsesRemaining > 0
    }

    /// Entitlement AND payment in one step: charges one trial session the first
    /// time this schedule blocks today, then reports whether it may block.
    ///
    /// Whoever applies a shield MUST call this, because whoever applies a shield
    /// must be the one who pays for it. Previously only the extension charged
    /// while the app also applied shields, which let a free user block forever
    /// without the counter ever moving: enable an overnight schedule after
    /// midnight and the app shields on the strength of the balance, while the
    /// extension's morning-half branch declines to charge. Repeat nightly.
    ///
    /// Idempotent per schedule per day, so re-registering a monitor mid-window —
    /// which makes iOS re-deliver intervalDidStart — never charges twice.
    /// NEVER call this from a view body.
    static func claimSession(_ config: ScheduleConfig, now: Date) -> Bool {
        if isPro { return true }
        let todayKey = AIStatsStore.dayKey(for: now)
        if sessionCounted(scheduleId: config.id, dayKey: todayKey) { return true }
        if isOvernightContinuation(config, now: now) { return true }
        guard scheduleUsesRemaining > 0 else { return false }
        recordScheduleUse(scheduleId: config.id, dayKey: todayKey)
        return true
    }
    static func recordAIUse() {
        AppGroup.defaults.set(AppGroup.defaults.integer(forKey: StoreKeys.aiTrialCount) + 1,
                              forKey: StoreKeys.aiTrialCount)
    }
}

/// Apple hard-caps an app + its extensions at 20 monitored activities total.
/// Keep one slot reserved for a manual lock.
enum ActivityBudget {
    static let max = 20
    static let manualReserve = 1
}

// MARK: - Named ManagedSettings stores

extension ManagedSettingsStore.Name {
    static let manual = ManagedSettingsStore.Name("manual")
    static let ai = ManagedSettingsStore.Name("ai")
}

enum Stores {
    static func manual() -> ManagedSettingsStore { ManagedSettingsStore(named: .manual) }
    static func ai() -> ManagedSettingsStore { ManagedSettingsStore(named: .ai) }
    /// One isolated store per schedule so a schedule ending never clears a manual/other lock.
    static func schedule(_ id: String) -> ManagedSettingsStore {
        ManagedSettingsStore(named: ManagedSettingsStore.Name("sch.\(id)"))
    }
}

// MARK: - Shield helpers (apply / clear a selection on a store)

enum Shielder {
    static func apply(_ selection: FamilyActivitySelection, to store: ManagedSettingsStore) {
        let apps = selection.applicationTokens
        let cats = selection.categoryTokens
        let webs = selection.webDomainTokens

        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = cats.isEmpty ? nil : .specific(cats)
        store.shield.webDomains = webs.isEmpty ? nil : webs
        store.shield.webDomainCategories = cats.isEmpty ? nil : .specific(cats)
        // Deleting FIFTEEN removes every shield it set, so while a block is up,
        // deleting apps is denied. Lives on the same store, so it lifts exactly
        // when this block's shield does.
        store.application.denyAppRemoval = HardcoreSettings.preventUninstall ? true : nil
    }

    static func clear(_ store: ManagedSettingsStore) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
        store.application.denyAppRemoval = nil
    }
}

// MARK: - FamilyActivitySelection persistence

enum SelectionStore {
    static func save(_ selection: FamilyActivitySelection, forKey key: String) {
        if let data = try? JSONEncoder().encode(selection) {
            AppGroup.defaults.set(data, forKey: key)
        }
    }

    static func load(forKey key: String) -> FamilyActivitySelection? {
        guard let data = AppGroup.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    static func remove(forKey key: String) {
        AppGroup.defaults.removeObject(forKey: key)
    }

    static func isEmpty(_ selection: FamilyActivitySelection) -> Bool {
        selection.applicationTokens.isEmpty &&
        selection.categoryTokens.isEmpty &&
        selection.webDomainTokens.isEmpty
    }
}

// MARK: - Schedule model

/// A user-defined recurring block. Each schedule is registered as one or more
/// DeviceActivity monitors (one per selected weekday, or a single daily monitor
/// when every weekday is selected). "Every N weeks" is enforced by a parity check
/// in the monitor extension rather than a native repeat (iOS has no biweekly repeat).
struct ScheduleConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var isEnabled: Bool
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday.
    var weekdays: [Int]
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    /// 1 = weekly, 2 = every other week, 3 = every third week …
    var everyNWeeks: Int
    /// Reference instant inside an "on" week; parity is measured from here.
    var anchorEpoch: Double

    init(id: String = UUID().uuidString,
         name: String = "Focus block",
         isEnabled: Bool = true,
         weekdays: [Int] = [2, 3, 4, 5, 6],
         startHour: Int = 9, startMinute: Int = 0,
         endHour: Int = 17, endMinute: Int = 0,
         everyNWeeks: Int = 1,
         anchorEpoch: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.weekdays = weekdays
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.everyNWeeks = everyNWeeks
        self.anchorEpoch = anchorEpoch
    }

    var startMinutes: Int { startHour * 60 + startMinute }
    var endMinutes: Int { endHour * 60 + endMinute }
    /// True when the window wraps past midnight (e.g. 22:00 → 06:00).
    /// An end of exactly 00:00 means "until midnight" — same-day, no morning half.
    var isOvernight: Bool { endMinutes <= startMinutes && endMinutes != 0 }
    /// Ends exactly at midnight → registered as one same-day segment to 23:59:59.
    var endsAtMidnight: Bool { endMinutes == 0 }
    var coversEveryDay: Bool { Set(weekdays) == Set(1...7) }

    /// How many DeviceActivity activities this schedule will register.
    var activityCount: Int {
        let dayUnits = coversEveryDay ? 1 : max(weekdays.count, 0)
        return dayUnits * (isOvernight ? 2 : 1)
    }
}

enum ScheduleStore {
    static func load() -> [ScheduleConfig] {
        guard let data = AppGroup.defaults.data(forKey: StoreKeys.schedules) else { return [] }
        return (try? JSONDecoder().decode([ScheduleConfig].self, from: data)) ?? []
    }

    static func save(_ schedules: [ScheduleConfig]) {
        if let data = try? JSONEncoder().encode(schedules) {
            AppGroup.defaults.set(data, forKey: StoreKeys.schedules)
        }
    }

    static func find(_ id: String) -> ScheduleConfig? {
        load().first { $0.id == id }
    }
}

// MARK: - Week parity ("every N weeks")

enum WeekParity {
    /// True if `date` falls in an "on" week relative to the schedule's anchor.
    /// Weekly (N<=1) is always on. The morning half of an overnight window is
    /// shifted back a full day so it is always attributed to the prior evening's
    /// week (a 12h shift lands on the wrong day for windows ending after noon).
    static func isActiveWeek(_ config: ScheduleConfig, on date: Date, morningHalf: Bool = false) -> Bool {
        guard config.everyNWeeks > 1 else { return true }
        let cal = Calendar.current
        // Calendar arithmetic, not a fixed 86400s: on a DST spring-forward day a
        // literal 24h shift lands on the wrong calendar day (and so, at a week
        // boundary, the wrong week) and would silently skip an overnight block.
        let evalDate = morningHalf ? (cal.date(byAdding: .day, value: -1, to: date) ?? date) : date
        let anchor = Date(timeIntervalSince1970: config.anchorEpoch)

        guard let anchorWeek = cal.dateInterval(of: .weekOfYear, for: anchor)?.start,
              let evalWeek = cal.dateInterval(of: .weekOfYear, for: evalDate)?.start else {
            return true
        }
        let days = cal.dateComponents([.day], from: anchorWeek, to: evalWeek).day ?? 0
        let weeks = Int((Double(days) / 7.0).rounded())
        let n = config.everyNWeeks
        return ((weeks % n) + n) % n == 0
    }
}

// MARK: - DeviceActivity name encoding

/// Stable, parseable names so the monitor extension can route callbacks.
/// Schedule: "sch.<id>.<weekday>.<segment>"  (weekday 0 = every-day optimization)
/// Segment:  "s" same-day, "o0" overnight-open (don't clear on end),
///           "o1" overnight-close (clears on end).
/// AI window: "ai.win.<index>".
enum ActivityNaming {
    static let schedulePrefix = "sch."
    static let aiWindowPrefix = "ai.win."
    static let manual = "HardcoreLock"

    static func schedule(id: String, weekday: Int, segment: String) -> String {
        "sch.\(id).\(weekday).\(segment)"
    }

    static func aiWindow(_ index: Int) -> String { "ai.win.\(index)" }

    struct ParsedSchedule {
        let id: String
        let weekday: Int
        let segment: String
    }

    /// Parse "sch.<uuid>.<weekday>.<segment>". UUIDs contain no dots, so the
    /// first and last two components are unambiguous.
    static func parseSchedule(_ raw: String) -> ParsedSchedule? {
        guard raw.hasPrefix(schedulePrefix) else { return nil }
        let parts = raw.split(separator: ".").map(String.init)
        // ["sch", <uuid>, <weekday>, <segment>]
        guard parts.count == 4, let wd = Int(parts[2]) else { return nil }
        return ParsedSchedule(id: parts[1], weekday: wd, segment: parts[3])
    }

    static func parseAIWindow(_ raw: String) -> Int? {
        guard raw.hasPrefix(aiWindowPrefix) else { return nil }
        return Int(raw.dropFirst(aiWindowPrefix.count))
    }
}

// MARK: - AI mode configuration

struct AIConfig: Codable, Equatable {
    var isEnabled: Bool
    /// Minutes BEFORE a predicted peak window to nudge the user.
    var leadMinutes: Int
    /// Length of an accepted "challenge" lock.
    var lockDurationSeconds: Int
    /// Days of observation required before the model will predict/nudge.
    var minObservationDays: Int
    /// A window must trigger on at least this fraction of observed days to count as a peak.
    var triggerFrequency: Double
    /// Let the bandit pick the lead time from how the user answers nudges,
    /// instead of always using `leadMinutes`.
    var adaptiveLead: Bool

    init(isEnabled: Bool = false,
         leadMinutes: Int = 15,
         lockDurationSeconds: Int = 2 * 3600,
         minObservationDays: Int = 3,
         triggerFrequency: Double = 0.4,
         adaptiveLead: Bool = true) {
        self.isEnabled = isEnabled
        self.leadMinutes = leadMinutes
        self.lockDurationSeconds = lockDurationSeconds
        self.minObservationDays = minObservationDays
        self.triggerFrequency = triggerFrequency
        self.adaptiveLead = adaptiveLead
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, leadMinutes, lockDurationSeconds, minObservationDays, triggerFrequency, adaptiveLead
    }

    /// Tolerates configs saved by older builds: a missing key must not fail the
    /// whole decode, which would silently reset AI mode to OFF on upgrade.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AIConfig()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        leadMinutes = try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? d.leadMinutes
        lockDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .lockDurationSeconds) ?? d.lockDurationSeconds
        minObservationDays = try c.decodeIfPresent(Int.self, forKey: .minObservationDays) ?? d.minObservationDays
        triggerFrequency = try c.decodeIfPresent(Double.self, forKey: .triggerFrequency) ?? d.triggerFrequency
        adaptiveLead = try c.decodeIfPresent(Bool.self, forKey: .adaptiveLead) ?? d.adaptiveLead
    }

    /// The posterior LOWER bound an hour must clear to count as a habit. Lower
    /// than `triggerFrequency` because it is a pessimistic bound, not a mean.
    var peakThreshold: Double { max(0.15, triggerFrequency - 0.15) }

    // ── Observation coverage ────────────────────────────────────────────────
    // A "window" = one background time-slot we ask iOS to watch. Coverage runs
    // 07:00 → 02:00 next day; only 02:00–07:00 (deep sleep) is unmonitored. The
    // span crosses midnight, which iOS windows can't do cleanly, so it is modelled
    // as two same-day pieces (evening 07:00–24:00, morning 00:00–02:00) and NO
    // monitoring window ever crosses midnight. AI fills as many windows as the
    // shared 20-activity budget leaves free; when slots are scarce the windows
    // just get wider (always full coverage, still ≥ iOS's 15-min floor). Window
    // size never limits precision — the peak comes from the exact hit TIMESTAMPS.
    static let coverageStartHour = 7        // 07:00
    static let coverageEndHour = 26         // 02:00 next day (24 + 2)
    static let maxWindows = 19              // 19 × 1h = the full 07:00–02:00 span
    static let thresholdMinutes = 5         // a hit = ≥5 min of the watched apps in a window

    // Fine prediction (independent of window size).
    static let binMinutes = 5               // the peak is located to the nearest 5 minutes
    static let minPeakSamples = 6           // need this many timestamps before a precise peak
    static let peakKernelHalfWidth = 25     // ± minutes of smoothing when locating the peak

    // Hourly DISPLAY grid across the coverage span (does NOT depend on how many
    // monitoring windows the budget allowed this run).
    static var displayBins: Int { coverageEndHour - coverageStartHour }   // 19
    /// Clock hour (0–23) at the start of display bin i.
    static func displayBinStartHour(_ i: Int) -> Int { (coverageStartHour + i) % 24 }

    /// Map a clock minute-of-day (0–1439) onto the coverage's linear axis,
    /// folding the post-midnight hours after 24:00 so midnight is continuous.
    static func linearPosition(_ clockMinute: Int) -> Int {
        clockMinute >= coverageStartHour * 60 ? clockMinute : clockMinute + 1440
    }

    /// Same-day pieces (startMin, endMin) that make up the coverage, in order.
    private static var segments: [(start: Int, end: Int)] {
        let lo = coverageStartHour * 60, hiLinear = coverageEndHour * 60
        if hiLinear <= 1440 { return [(lo, hiLinear)] }
        return [(lo, 1440), (0, hiLinear - 1440)]   // evening 07:00–24:00, morning 00:00–02:00
    }

    /// Clock hours (0…23) a same-day window [startMin, endMin) overlaps.
    static func clockHours(startMin: Int, endMin: Int) -> [Int] {
        guard endMin > startMin else { return [] }
        return (startMin / 60...(endMin - 1) / 60).map { $0 % 24 }
    }

    /// Monitoring layout for `n` windows, split between the evening and morning
    /// pieces in proportion to their length so none crosses midnight.
    static func windowLayout(_ n: Int) -> [(startMin: Int, endMin: Int)] {
        let segs = segments
        let count = max(1, min(n, maxWindows))
        func slice(_ seg: (start: Int, end: Int), _ k: Int) -> [(startMin: Int, endMin: Int)] {
            guard k > 0 else { return [] }
            let span = seg.end - seg.start
            return (0..<k).map { (seg.start + span * $0 / k, seg.start + span * ($0 + 1) / k) }
        }
        guard segs.count > 1 else { return slice(segs[0], count) }
        let total = segs.reduce(0) { $0 + ($1.end - $1.start) }
        let morningSpan = segs[1].end - segs[1].start
        var nMorning = Int((Double(count) * Double(morningSpan) / Double(total)).rounded())
        // Rounding gave the morning piece ZERO windows whenever n ≤ 4, silently
        // leaving 00:00–02:00 unwatched; any n ≥ 2 can afford one there.
        if count >= 2 { nMorning = max(1, nMorning) }
        nMorning = min(nMorning, max(0, count - 1))   // keep at least one evening window
        return slice(segs[0], count - nMorning) + slice(segs[1], nMorning)
    }

    private static func clock(_ minuteOfDay: Int) -> String {
        let m = ((minuteOfDay % 1440) + 1440) % 1440
        let h24 = m / 60, mins = m % 60
        let suffix = h24 < 12 ? "AM" : "PM"
        var hour12 = h24 % 12
        if hour12 == 0 { hour12 = 12 }
        return mins == 0 ? "\(hour12) \(suffix)" : String(format: "%d:%02d %@", hour12, mins, suffix)
    }

    /// Display label for hourly bin i, e.g. "7 AM".
    static func binLabel(_ i: Int) -> String { clock(displayBinStartHour(i) * 60) }

    /// Precise time label like "8:35 PM".
    static func minuteLabel(_ minuteOfDay: Int) -> String { clock(minuteOfDay) }

    /// When the pre-cue fires: `leadMinutes` before the peak, wrapped around
    /// midnight. Shared so the UI label and the scheduler can never disagree.
    static func nudgeMinute(peakMinute: Int, leadMinutes: Int) -> Int {
        ((peakMinute - leadMinutes) % 1440 + 1440) % 1440
    }
}

enum AIConfigStore {
    static func load() -> AIConfig {
        guard let data = AppGroup.defaults.data(forKey: StoreKeys.aiConfig),
              let cfg = try? JSONDecoder().decode(AIConfig.self, from: data) else {
            return AIConfig()
        }
        return cfg
    }

    static func save(_ config: AIConfig) {
        if let data = try? JSONEncoder().encode(config) {
            AppGroup.defaults.set(data, forKey: StoreKeys.aiConfig)
        }
    }
}

// MARK: - AI usage statistics (the learned histogram)

/// The learned signal. `hitMinutes` (absolute minute-of-day of every counted
/// "heavy use" event) is THE data — all analysis derives from it, so it stays
/// valid no matter how the monitoring windows were sized this run.
/// Written by the monitor extension (tiny read-modify-write), read by the app.
struct AIStats: Codable, Equatable {
    var hitMinutes: [Int]
    var daysObserved: Int
    var lastDayKey: String
    /// Per monitoring-window day key, so a window records at most one hit per day
    /// even if its threshold event re-fires (e.g. after re-registration).
    var lastHitDayKey: [String]
    /// Behavioral weekday of each entry in `hitMinutes` (v4+). Optional so v3
    /// data, which never recorded it, still decodes.
    var hitWeekdays: [Int]?

    init() {
        hitWeekdays = []
        hitMinutes = []
        daysObserved = 0
        lastDayKey = ""
        lastHitDayKey = Array(repeating: "", count: AIConfig.maxWindows)
    }

    /// Hits per fixed hourly display bin over the coverage span (midnight-folded).
    func histogram() -> [Int] {
        var bins = Array(repeating: 0, count: AIConfig.displayBins)
        let lo = AIConfig.coverageStartHour * 60
        for m in hitMinutes {
            let idx = (AIConfig.linearPosition(m) - lo) / 60
            if idx >= 0 && idx < bins.count { bins[idx] += 1 }
        }
        return bins
    }

    /// Each hourly bin's share of observed days (clamped to 1.0).
    func frequencies() -> [Double] {
        guard daysObserved > 0 else { return Array(repeating: 0, count: AIConfig.displayBins) }
        return histogram().map { min(1.0, Double($0) / Double(daysObserved)) }
    }
}

enum AIStatsStore {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(for date: Date) -> String { dayFormatter.string(from: date) }

    static func minuteOfDay(for date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func load() -> AIStats {
        guard let data = AppGroup.defaults.data(forKey: StoreKeys.aiStats),
              var stats = try? JSONDecoder().decode(AIStats.self, from: data) else {
            return AIStats()
        }
        // Defensive: keep the dedup array sized to the max window count.
        if stats.lastHitDayKey.count != AIConfig.maxWindows {
            var fixed = Array(repeating: "", count: AIConfig.maxWindows)
            for i in 0..<min(fixed.count, stats.lastHitDayKey.count) { fixed[i] = stats.lastHitDayKey[i] }
            stats.lastHitDayKey = fixed
        }
        return stats
    }

    static func save(_ stats: AIStats) {
        if let data = try? JSONEncoder().encode(stats) {
            AppGroup.defaults.set(data, forKey: StoreKeys.aiStats)
        }
    }

    static func reset() {
        AppGroup.defaults.removeObject(forKey: StoreKeys.aiStats)
        HabitModelStore.reset()
        // Everything learned goes, including what the bandit and coach derived.
        for key in [StoreKeys.leadBandit, StoreKeys.leadChoice, StoreKeys.coachNudgeLine] {
            AppGroup.defaults.removeObject(forKey: key)
        }
    }

    /// Mark that we observed the user during the active part of the day.
    static func markDayObserved(now: Date) {
        // Migrate v3 stats BEFORE this update so today isn't counted twice.
        _ = HabitModelStore.loadOrMigrate(now: now)
        var stats = load()
        let key = dayKey(for: now)
        if stats.lastDayKey != key {
            stats.daysObserved += 1
            stats.lastDayKey = key
        }
        save(stats)
    }

    /// A monitoring window ran to its end → its hours were watched today. Only
    /// these hours become trials: crediting the whole day on the first window
    /// start fabricated zero-hit days for hours that were never monitored
    /// (enabling AI at 20:00 counted 07:00–19:00 as "no heavy use").
    static func markWindowObserved(window index: Int, now: Date) {
        let layout = AppGroup.defaults.array(forKey: StoreKeys.aiWindowLayout) as? [[Int]] ?? []
        guard index >= 0, index < layout.count, layout[index].count == 2 else { return }
        var model = HabitModelStore.loadOrMigrate(now: now)
        // The end callback lands at (or just after) the boundary; step back so
        // a window ending at 02:00 still belongs to the night it watched.
        let inside = now.addingTimeInterval(-60)
        let slot = BehavioralDay.slot(for: inside)
        model.observe(weekday: slot.weekday,
                      hours: AIConfig.clockHours(startMin: layout[index][0], endMin: layout[index][1]),
                      day: BehavioralDay.behavioralDayNumber(for: inside))
        HabitModelStore.save(model)
    }

    /// Record one "heavy use" threshold hit for a window (called from the extension).
    /// A window records at most one timestamp per day, so re-fired thresholds
    /// (from monitor re-registration) can't inflate the data.
    static func recordHit(window index: Int, now: Date) {
        var model = HabitModelStore.loadOrMigrate(now: now)
        var stats = load()
        let key = dayKey(for: now)
        // Make sure a day is counted even if intervalDidStart was missed.
        if stats.lastDayKey != key {
            stats.daysObserved += 1
            stats.lastDayKey = key
        }
        let slot = BehavioralDay.slot(for: now)
        if index >= 0 && index < stats.lastHitDayKey.count, stats.lastHitDayKey[index] != key {
            stats.lastHitDayKey[index] = key
            // The exact time this hit fired → fine-grained peak. Pad the weekday
            // log for v3 entries that predate it so the arrays stay aligned.
            var weekdays = stats.hitWeekdays ?? []
            if weekdays.count < stats.hitMinutes.count {
                weekdays = Array(repeating: 0, count: stats.hitMinutes.count - weekdays.count) + weekdays
            }
            stats.hitMinutes.append(minuteOfDay(for: now))
            weekdays.append(slot.weekday)
            if stats.hitMinutes.count > 400 {
                let excess = stats.hitMinutes.count - 400
                stats.hitMinutes.removeFirst(excess)
                weekdays.removeFirst(excess)
            }
            stats.hitWeekdays = weekdays
        }
        save(stats)

        model.recordHit(weekday: slot.weekday, hour: slot.hour, day: BehavioralDay.behavioralDayNumber(for: now))
        HabitModelStore.save(model)
    }
}

// MARK: - Prediction (shared by app + extension)

enum AIPredictor {
    /// This week's nudges, one per weekday that has a confident habit, or none
    /// while the model is still learning. See HabitModel for the statistics.
    static func weeklyPlan(config: AIConfig, stats: AIStats, model: HabitModel, leadMinutes: Int) -> [NudgePlan] {
        guard stats.daysObserved >= config.minObservationDays else { return [] }
        return NudgePlanner.plan(model: model, samples: stats.hitMinutes, sampleWeekdays: stats.hitWeekdays,
                                 config: config, leadMinutes: leadMinutes)
    }
}

// MARK: - Pre-cue nudges (shared so the extension can re-arm them in the background)

enum NudgeScheduler {
    /// v3's single every-day nudge; still removed so an upgrade never leaves it firing.
    static let identifier = "ai.nudge"
    static let categoryIdentifier = "AI_NUDGE"
    /// userInfo key carrying the lead time a nudge was sent with, so the answer
    /// can be credited to the right bandit arm.
    static let leadKey = "leadMinutes"

    static func identifier(weekday: Int) -> String { "ai.nudge.\(weekday)" }
    static var allIdentifiers: [String] { [identifier] + (1...7).map { identifier(weekday: $0) } }

    /// Recompute the plan and (re)arm one weekly-repeating nudge per weekday.
    /// Idempotent — safe from the app foreground OR the monitor extension, so a
    /// shifting habit never leaves a stale nudge firing.
    static func reschedule(now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers)

        let config = AIConfigStore.load()
        guard config.isEnabled else { return }
        // Don't nudge if there is nothing being watched.
        guard let sel = SelectionStore.load(forKey: StoreKeys.aiSelection),
              !SelectionStore.isEmpty(sel) else { return }

        let lead = LeadBanditStore.todaysLead(config: config, now: now)
        let plans = AIPredictor.weeklyPlan(config: config, stats: AIStatsStore.load(),
                                           model: HabitModelStore.loadOrMigrate(now: now), leadMinutes: lead)
        let coachLine = AppGroup.defaults.string(forKey: StoreKeys.coachNudgeLine)
        let dayNames = Calendar.current.weekdaySymbols

        for plan in plans {
            var fire = DateComponents()
            fire.weekday = plan.fireWeekday
            fire.hour = plan.fireMinute / 60
            fire.minute = plan.fireMinute % 60

            let day = dayNames[plan.weekday - 1]
            let content = UNMutableNotificationContent()
            content.title = "BEAT THE URGE"
            content.body = coachLine ?? "On \(day)s you usually reach for these apps around \(AIConfig.minuteLabel(plan.peakMinute)) (\(Int(plan.probability * 100))% of the time). Lock in now, before the urge hits?"
            content.sound = .default
            content.categoryIdentifier = categoryIdentifier
            content.userInfo = [leadKey: lead]

            let trigger = UNCalendarNotificationTrigger(dateMatching: fire, repeats: true)
            center.add(UNNotificationRequest(identifier: identifier(weekday: plan.weekday), content: content, trigger: trigger))
        }
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: allIdentifiers)
    }
}

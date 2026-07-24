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

    static var defaults: UserDefaults {
        if let d = UserDefaults(suiteName: id) { return d }
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
    /// Free-trial bookkeeping (shared: the monitor extension both reads and
    /// increments the schedule counter when a scheduled session fires).
    static let proPurchased = "pro.purchased"
    static let scheduleTrialCount = "trial.schedule.count"
    static let aiTrialCount = "trial.ai.count"
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

    /// Count one fired scheduled session and remember which day it ran for this
    /// schedule, so the overnight morning half can verify its evening half was paid.
    static func recordScheduleUse(scheduleId: String, dayKey: String) {
        AppGroup.defaults.set(AppGroup.defaults.integer(forKey: StoreKeys.scheduleTrialCount) + 1,
                              forKey: StoreKeys.scheduleTrialCount)
        AppGroup.defaults.set(dayKey, forKey: "trial.sch.session.\(scheduleId)")
    }

    /// The overnight morning ("o1") half is free ONLY when the evening half of the
    /// same schedule actually ran (and was counted) the previous day.
    static func overnightContinuationAllowed(scheduleId: String, eveningDayKey: String) -> Bool {
        AppGroup.defaults.string(forKey: "trial.sch.session.\(scheduleId)") == eveningDayKey
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
    }

    static func clear(_ store: ManagedSettingsStore) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
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
    var isOvernight: Bool { endMinutes <= startMinutes }
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
    /// shifted back ~12h so it is attributed to the prior evening's week.
    static func isActiveWeek(_ config: ScheduleConfig, on date: Date, morningHalf: Bool = false) -> Bool {
        guard config.everyNWeeks > 1 else { return true }
        let cal = Calendar.current
        let evalDate = morningHalf ? date.addingTimeInterval(-12 * 3600) : date
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

    init(isEnabled: Bool = false,
         leadMinutes: Int = 15,
         lockDurationSeconds: Int = 2 * 3600,
         minObservationDays: Int = 3,
         triggerFrequency: Double = 0.4) {
        self.isEnabled = isEnabled
        self.leadMinutes = leadMinutes
        self.lockDurationSeconds = lockDurationSeconds
        self.minObservationDays = minObservationDays
        self.triggerFrequency = triggerFrequency
    }

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

    init() {
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
    }

    /// Mark that we observed the user during the active part of the day.
    static func markDayObserved(now: Date) {
        var stats = load()
        let key = dayKey(for: now)
        if stats.lastDayKey != key {
            stats.daysObserved += 1
            stats.lastDayKey = key
        }
        save(stats)
    }

    /// Record one "heavy use" threshold hit for a window (called from the extension).
    /// A window records at most one timestamp per day, so re-fired thresholds
    /// (from monitor re-registration) can't inflate the data.
    static func recordHit(window index: Int, now: Date) {
        var stats = load()
        let key = dayKey(for: now)
        // Make sure a day is counted even if intervalDidStart was missed.
        if stats.lastDayKey != key {
            stats.daysObserved += 1
            stats.lastDayKey = key
        }
        if index >= 0 && index < stats.lastHitDayKey.count, stats.lastHitDayKey[index] != key {
            stats.lastHitDayKey[index] = key
            // The exact time this hit fired → fine-grained peak.
            stats.hitMinutes.append(minuteOfDay(for: now))
            if stats.hitMinutes.count > 400 {
                stats.hitMinutes.removeFirst(stats.hitMinutes.count - 400)
            }
        }
        save(stats)
    }
}

// MARK: - Prediction (shared by app + extension)

enum AIPredictor {
    /// Coarse confidence gate: which hourly bin is the user's habitual peak, or
    /// nil while still learning / no clear pattern. Drives the histogram highlight
    /// and the "is there a habit at all" decision.
    static func predictedPeakIndex(config: AIConfig, stats: AIStats) -> Int? {
        guard stats.daysObserved >= config.minObservationDays else { return nil }
        let freqs = stats.frequencies()
        var best: Int?
        var bestFreq = config.triggerFrequency - 0.0001
        for (i, f) in freqs.enumerated() where f >= config.triggerFrequency {
            if f > bestFreq { bestFreq = f; best = i }
        }
        return best
    }

    /// Fine peak time-of-day (minute 0–1439) to ~5-minute resolution, located from
    /// the recorded hit timestamps with a triangular kernel so a handful of noisy
    /// samples can't fabricate a false sharp peak. Nil until enough samples.
    static func predictedPeakMinute(stats: AIStats) -> Int? {
        let samples = stats.hitMinutes
        guard samples.count >= AIConfig.minPeakSamples else { return nil }
        // Work on the coverage's linear axis so a peak straddling midnight isn't split.
        let lo = AIConfig.coverageStartHour * 60
        let hi = AIConfig.coverageEndHour * 60
        let lin = samples.map { AIConfig.linearPosition($0) }
        let h = Double(AIConfig.peakKernelHalfWidth)
        var bestPos = lo
        var bestScore = -1.0
        var p = lo
        while p < hi {
            var score = 0.0
            for s in lin {
                let d = abs(Double(s - p))
                if d < h { score += 1.0 - d / h }
            }
            if score > bestScore { bestScore = score; bestPos = p }
            p += AIConfig.binMinutes
        }
        return bestPos % 1440
    }
}

// MARK: - Pre-cue nudge (shared so the extension can re-arm it in the background)

enum NudgeScheduler {
    static let identifier = "ai.nudge"
    static let categoryIdentifier = "AI_NUDGE"

    /// Recompute the predicted peak and (re)arm the daily pre-cue notification.
    /// Idempotent — safe to call from the app foreground OR the monitor extension
    /// on day rollover, so a shifting peak never leaves a stale nudge firing.
    static func reschedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let config = AIConfigStore.load()
        guard config.isEnabled else { return }
        // Don't nudge if there is nothing being watched.
        guard let sel = SelectionStore.load(forKey: StoreKeys.aiSelection),
              !SelectionStore.isEmpty(sel) else { return }

        let stats = AIStatsStore.load()
        // Coarse gate: only nudge once there's a real habit.
        guard let peak = AIPredictor.predictedPeakIndex(config: config, stats: stats) else { return }
        // Fine timing: the precise minute from the timestamps, falling back to the
        // peak hour until enough samples have accumulated.
        let targetMinute = AIPredictor.predictedPeakMinute(stats: stats) ?? (AIConfig.displayBinStartHour(peak) * 60)
        let fireMinutes = max(0, targetMinute - config.leadMinutes)
        var fire = DateComponents()
        fire.hour = fireMinutes / 60
        fire.minute = fireMinutes % 60

        let content = UNMutableNotificationContent()
        content.title = "BEAT THE URGE"
        content.body = "You usually reach for these apps around \(AIConfig.minuteLabel(targetMinute)). Challenge yourself — lock now before the urge hits?"
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        let trigger = UNCalendarNotificationTrigger(dateMatching: fire, repeats: true)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

//
//  HabitEngine.swift
//  Hardcord Lock App
//
//  The "AI" mode — fully on-device:
//
//   1. LEARN  — the monitor extension records a "heavy use" hit whenever the
//               user spends ≥AIConfig.thresholdMinutes in the watched apps within
//               a window, and every observed day as a trial (HabitModel).
//   2. PREDICT— a hierarchical Bayesian model gives, per weekday and hour, the
//               probability of heavy use with a confidence bound; each weekday
//               with a confident habit gets its own predicted peak.
//   3. INTERVENE — a nudge fires a lead time before each weekday's peak. A
//               Thompson-sampling bandit learns which lead time the user actually
//               acts on. A lock only ever starts when the user taps LOCK NOW.
//   4. EXPLAIN — on iOS 26 devices with Apple Intelligence, AICoach turns the
//               model's numbers into a short weekly insight (on-device LLM).
//
//  No usage data ever leaves the device.
//

import Foundation
import Combine
import DeviceActivity
import FamilyControls
import UserNotifications

@MainActor
final class HabitEngine: ObservableObject {
    static let shared = HabitEngine()

    @Published var config: AIConfig
    @Published var stats: AIStats
    @Published private(set) var model: HabitModel
    @Published private(set) var bandit: LeadBandit
    /// Lead time nudges use today (the bandit's pinned pick, or the fixed one).
    @Published private(set) var currentLead: Int
    @Published var watchedSelection: FamilyActivitySelection
    @Published var lastBudgetWarning: String?

    /// Set when an accepted challenge should start a lock (observed by the UI).
    @Published var pendingChallenge: Bool = false

    private let center = DeviceActivityCenter()
    static let categoryIdentifier = NudgeScheduler.categoryIdentifier
    static let actionLockNow = "AI_LOCK_NOW"
    static let actionSkip = "AI_SKIP"

    private init() {
        let loaded = AIConfigStore.load()
        config = loaded
        stats = AIStatsStore.load()
        model = HabitModelStore.load() ?? HabitModel()
        bandit = LeadBanditStore.load()
        currentLead = loaded.leadMinutes
        watchedSelection = SelectionStore.load(forKey: StoreKeys.aiSelection) ?? FamilyActivitySelection()
    }

    // MARK: - Derived prediction state

    var isLearning: Bool { stats.daysObserved < config.minObservationDays }

    var daysObserved: Int { stats.daysObserved }

    /// One entry per weekday with a confident habit, Sunday first.
    var weeklyPlan: [NudgePlan] {
        AIPredictor.weeklyPlan(config: config, stats: stats, model: model, leadMinutes: currentLead)
            .sorted { $0.weekday < $1.weekday }
    }

    /// The behavioral weekday right now (after midnight still counts as last night).
    var todayWeekday: Int { BehavioralDay.slot(for: Date()).weekday }

    var todayPlan: NudgePlan? { weeklyPlan.first { $0.weekday == todayWeekday } }

    /// Today's modelled probability of heavy use per display bin (hour).
    var riskCurve: [Double] {
        let weekday = todayWeekday
        return (0..<AIConfig.displayBins).map {
            model.estimate(weekday: weekday, hour: AIConfig.displayBinStartHour($0)).mean
        }
    }

    /// Display bin of today's peak, for the histogram highlight.
    var todayPeakBin: Int? {
        guard let plan = todayPlan else { return nil }
        let hour = plan.peakMinute / 60
        return (0..<AIConfig.displayBins).first { AIConfig.displayBinStartHour($0) == hour }
    }

    /// Plain-language facts for the on-device coach. No app names — the
    /// selection tokens are opaque, and the coach doesn't need them.
    func coachFacts() -> String {
        let days = Calendar.current.weekdaySymbols
        var lines = ["Days observed: \(stats.daysObserved)."]
        let plan = weeklyPlan
        if plan.isEmpty {
            lines.append("No confident daily pattern yet.")
        } else {
            for p in plan {
                lines.append("\(days[p.weekday - 1]): heavy use usually starts around \(AIConfig.minuteLabel(p.peakMinute)), on \(Int(p.probability * 100))% of those days.")
            }
        }
        if bandit.trials > 0 {
            let accepted = Int((bandit.successes.reduce(0, +) - Double(LeadBandit.arms.count)).rounded())
            lines.append("Nudges answered: \(bandit.trials); accepted: \(accepted).")
            lines.append("Most effective nudge lead so far: \(bandit.bestMeanArm) minutes.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Watched apps

    func saveWatchedSelection(_ selection: FamilyActivitySelection) {
        watchedSelection = selection
        SelectionStore.save(selection, forKey: StoreKeys.aiSelection)
        if SelectionStore.isEmpty(selection) {
            stopWindows()
            NudgeScheduler.cancel()
        }
        Automation.reconcileAll()
    }

    // MARK: - Enable / disable

    func setEnabled(_ enabled: Bool) {
        config.isEnabled = enabled
        AIConfigStore.save(config)
        if enabled {
            // The pre-cue notification is the only way this mode ever acts, so
            // ask for permission when the feature is switched on.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if !enabled {
            stopWindows()
            NudgeScheduler.cancel()
        }
        Automation.reconcileAll()
    }

    func updateConfig(_ newConfig: AIConfig) {
        config = newConfig
        AIConfigStore.save(config)
        Automation.reconcileAll()
    }

    func resetLearning() {
        AIStatsStore.reset()
        stats = AIStats()
        model = HabitModel()
        registeredSelection = nil
        Automation.reconcileAll()
    }

    // MARK: - Refresh (foreground / after changes)

    /// Reload the learned stats and (re)assert monitors + nudge. Called by the
    /// coordinator; never re-registers monitors when nothing changed (avoids the
    /// re-fire double-counting that a stop+restart on every foreground caused).
    func refresh() {
        stats = AIStatsStore.load()
        model = HabitModelStore.loadOrMigrate()
        bandit = LeadBanditStore.load()
        currentLead = LeadBanditStore.todaysLead(config: config)
        watchedSelection = SelectionStore.load(forKey: StoreKeys.aiSelection) ?? watchedSelection
        // AI "on" with nothing to watch is a meaningless state (and can linger
        // from old builds' persisted config) — normalize it to OFF so the toggle
        // always reflects reality and no slots are ever held for nothing.
        if config.isEnabled, SelectionStore.isEmpty(watchedSelection) {
            config.isEnabled = false
            AIConfigStore.save(config)
        }
        if config.isEnabled, !SelectionStore.isEmpty(watchedSelection) {
            registerWindows()
            NudgeScheduler.reschedule()
        } else {
            // Nothing is registered on this path, so a leftover budget warning
            // would be a permanent lie on the AI screen.
            lastBudgetWarning = nil
            stopWindows()
            NudgeScheduler.cancel()
        }
    }

    // MARK: - Window monitoring (the learning signal)

    /// The selection the current monitors were registered for, so we can skip a
    /// needless stop+restart when nothing changed.
    private var registeredSelection: FamilyActivitySelection?

    private func registerWindows() {
        guard !SelectionStore.isEmpty(watchedSelection) else {
            lastBudgetWarning = nil
            stopWindows()
            registeredSelection = nil
            return
        }
        lastBudgetWarning = nil

        // Take whatever of the shared 20-activity budget schedules aren't using,
        // and cover the FULL day with that many windows (wider when slots are scarce).
        let scheduleCount = AppGroup.defaults.integer(forKey: StoreKeys.scheduleActivityCount)
        let available = max(0, ActivityBudget.max - ActivityBudget.manualReserve - scheduleCount)
        let n = min(available, AIConfig.maxWindows)

        // Derive the warning from `n` BEFORE the no-op fast path below, so a
        // reconcile that changes nothing still reproduces it (it is surfaced in
        // the AI screen and must not blink out on every foreground).
        if n <= 0 {
            lastBudgetWarning = "AI is paused — your schedules are using all \(ActivityBudget.max) background-timer slots. Disable a schedule to free one."
        } else if n < AIConfig.maxWindows {
            lastBudgetWarning = "AI is covering the day in \(n) wider blocks (schedules are using some of the \(ActivityBudget.max) slots). Fewer schedules = finer learning."
        }

        // Skip a needless restart only when nothing changed (same apps AND same
        // window count). If the budget shifted, n changes and we re-register.
        let liveWindows = center.activities.filter { $0.rawValue.hasPrefix(ActivityNaming.aiWindowPrefix) }.count
        if registeredSelection == watchedSelection, liveWindows == n, n > 0 { return }

        stopWindows()

        guard n > 0 else { return }

        let event = DeviceActivityEvent(
            applications: watchedSelection.applicationTokens,
            categories: watchedSelection.categoryTokens,
            webDomains: watchedSelection.webDomainTokens,
            threshold: DateComponents(minute: AIConfig.thresholdMinutes),
            includesPastActivity: true
        )
        let eventName = DeviceActivityEvent.Name("heavyUse")

        var registered = 0
        var layout: [[Int]] = []
        for (i, w) in AIConfig.windowLayout(n).enumerated() {
            let start = DateComponents(hour: w.startMin / 60, minute: w.startMin % 60)
            // Keep the interval inside the same calendar day.
            let end: DateComponents = (w.endMin >= 1440)
                ? DateComponents(hour: 23, minute: 59, second: 59)
                : DateComponents(hour: w.endMin / 60, minute: w.endMin % 60)

            let schedule = DeviceActivitySchedule(intervalStart: start, intervalEnd: end, repeats: true)
            do {
                try center.startMonitoring(
                    DeviceActivityName(ActivityNaming.aiWindow(i)),
                    during: schedule,
                    events: [eventName: event]
                )
                registered += 1
                layout.append([w.startMin, min(w.endMin, 1440)])
            } catch {
                lastBudgetWarning = "AI mode couldn't start all monitors (iOS background-timer limit)."
                break
            }
        }
        AppGroup.defaults.set(registered, forKey: StoreKeys.aiActivityCount)
        AppGroup.defaults.set(layout, forKey: StoreKeys.aiWindowLayout)
        registeredSelection = registered > 0 ? watchedSelection : nil
    }

    private func stopWindows() {
        let windows = center.activities.filter { $0.rawValue.hasPrefix(ActivityNaming.aiWindowPrefix) }
        if !windows.isEmpty { center.stopMonitoring(windows) }
        AppGroup.defaults.set(0, forKey: StoreKeys.aiActivityCount)
        AppGroup.defaults.removeObject(forKey: StoreKeys.aiWindowLayout)
        registeredSelection = nil
    }

    // MARK: - Challenge trigger

    /// Called only when the user explicitly accepts a pre-cue nudge by tapping
    /// its "LOCK NOW" action. There is no in-app one-tap lock button by design.
    func requestChallenge() {
        pendingChallenge = true
    }
}

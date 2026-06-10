//
//  HabitEngine.swift
//  Hardcord Lock App
//
//  The "AI" mode. It is a fully on-device, transparent behavioral model:
//
//   1. LEARN  — monitor the user's watched apps across fixed time windows.
//               The extension records a "heavy use" hit whenever the user spends
//               ≥10 min in those apps within a window (DeviceActivityEvent threshold).
//   2. PREDICT— after a few days, the window(s) the user reliably over-uses become
//               the predicted "peak" (frequency = hits / observed days).
//   3. INTERVENE — schedule a notification a user-set lead time (10/15 min) BEFORE
//               the peak window's cue, inviting the user to pre-commit to a lock.
//               Acting before the cue is the core of habit change (cue → routine →
//               reward): we add friction at the moment of temptation, on the user's
//               own command — never an automatic, non-consensual lock.
//
//  No usage data ever leaves the device. Apple sandboxes Screen Time usage data;
//  on-device frequency analysis is both the compliant and the privacy-respecting
//  way to do this.
//

import Foundation
import Combine
import DeviceActivity
import FamilyControls

@MainActor
final class HabitEngine: ObservableObject {
    static let shared = HabitEngine()

    @Published var config: AIConfig
    @Published var stats: AIStats
    @Published var watchedSelection: FamilyActivitySelection
    @Published var lastBudgetWarning: String?

    /// Set when an accepted challenge should start a lock (observed by the UI).
    @Published var pendingChallenge: Bool = false

    private let center = DeviceActivityCenter()
    static let categoryIdentifier = NudgeScheduler.categoryIdentifier
    static let actionLockNow = "AI_LOCK_NOW"
    static let actionSkip = "AI_SKIP"

    private init() {
        config = AIConfigStore.load()
        stats = AIStatsStore.load()
        watchedSelection = SelectionStore.load(forKey: StoreKeys.aiSelection) ?? FamilyActivitySelection()
    }

    // MARK: - Derived prediction state

    var frequencies: [Double] { stats.frequencies() }

    var isLearning: Bool { stats.daysObserved < config.minObservationDays }

    var daysObserved: Int { stats.daysObserved }

    /// Index of the predicted peak window, or nil while learning / no clear peak.
    var predictedPeakIndex: Int? {
        AIPredictor.predictedPeakIndex(config: config, stats: stats)
    }

    /// Precise peak minute-of-day once enough timestamps exist (nil otherwise).
    var predictedPeakMinute: Int? {
        guard predictedPeakIndex != nil else { return nil }
        return AIPredictor.predictedPeakMinute(stats: stats)
    }

    /// Best available label: the precise time (e.g. "8:35 PM") when we have it,
    /// otherwise the coarse 1-hour window while fine samples accumulate.
    var predictedPeakLabel: String? {
        guard let i = predictedPeakIndex else { return nil }
        if let m = AIPredictor.predictedPeakMinute(stats: stats) {
            return AIConfig.minuteLabel(m)
        }
        return AIConfig.binLabel(i)
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
        registeredSelection = nil
        Automation.reconcileAll()
    }

    // MARK: - Refresh (foreground / after changes)

    /// Reload the learned stats and (re)assert monitors + nudge. Called by the
    /// coordinator; never re-registers monitors when nothing changed (avoids the
    /// re-fire double-counting that a stop+restart on every foreground caused).
    func refresh() {
        stats = AIStatsStore.load()
        watchedSelection = SelectionStore.load(forKey: StoreKeys.aiSelection) ?? watchedSelection
        if config.isEnabled, !SelectionStore.isEmpty(watchedSelection) {
            registerWindows()
            NudgeScheduler.reschedule()
        } else {
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

        // Skip a needless restart only when nothing changed (same apps AND same
        // window count). If the budget shifted, n changes and we re-register.
        let liveWindows = center.activities.filter { $0.rawValue.hasPrefix(ActivityNaming.aiWindowPrefix) }.count
        if registeredSelection == watchedSelection, liveWindows == n, n > 0 { return }

        stopWindows()

        guard n > 0 else {
            lastBudgetWarning = "AI is paused — your schedules are using all \(ActivityBudget.max) background-timer slots. Disable a schedule to free one."
            return
        }
        if n < AIConfig.maxWindows {
            lastBudgetWarning = "AI is covering the day in \(n) wider blocks (schedules are using some of the \(ActivityBudget.max) slots). Fewer schedules = finer learning."
        }

        let event = DeviceActivityEvent(
            applications: watchedSelection.applicationTokens,
            categories: watchedSelection.categoryTokens,
            webDomains: watchedSelection.webDomainTokens,
            threshold: DateComponents(minute: AIConfig.thresholdMinutes),
            includesPastActivity: true
        )
        let eventName = DeviceActivityEvent.Name("heavyUse")

        var registered = 0
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
            } catch {
                lastBudgetWarning = "AI mode couldn't start all monitors (iOS background-timer limit)."
                break
            }
        }
        AppGroup.defaults.set(registered, forKey: StoreKeys.aiActivityCount)
        registeredSelection = registered > 0 ? watchedSelection : nil
    }

    private func stopWindows() {
        let windows = center.activities.filter { $0.rawValue.hasPrefix(ActivityNaming.aiWindowPrefix) }
        if !windows.isEmpty { center.stopMonitoring(windows) }
        AppGroup.defaults.set(0, forKey: StoreKeys.aiActivityCount)
        registeredSelection = nil
    }

    // MARK: - Challenge trigger

    /// Called from the AI UI ("challenge me now") or from an accepted nudge action.
    func requestChallenge() {
        pendingChallenge = true
    }
}

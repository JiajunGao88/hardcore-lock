//
//  DeviceActivityMonitorExtension.swift
//  DeviceActivityManager
//
//  Runs in a separate, sandboxed, memory-limited (~6MB) process that the system
//  wakes to deliver schedule/threshold callbacks — even when the app is closed.
//  Keep every callback tiny: read shared state, apply/clear a shield, return.
//

import DeviceActivity
import ManagedSettings
import Foundation

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    /// Remaining time under which an ending manual segment counts as the end.
    private static let endSlack: TimeInterval = 60

    // MARK: - Interval start

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        let raw = activity.rawValue
        Heartbeat.record("start \(raw)")

        if raw == ActivityNaming.manual {
            // The app shields before arming this interval, but re-assert anyway:
            // a chained segment started from here has no app around to do it.
            reassertManualShield()
        } else if let parsed = ActivityNaming.parseSchedule(raw) {
            applyScheduleShield(parsed)
        } else if ActivityNaming.parseAIWindow(raw) != nil {
            // The AI observation window opened → count today as observed (its
            // hours become model trials when the window ENDS), then re-sync the
            // pre-cue nudges in case the predicted peak shifted (the app may
            // have been closed for days while the model learned).
            AIStatsStore.markDayObserved(now: Date())
            NudgeScheduler.reschedule()
        }
    }

    // MARK: - Interval end

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        let raw = activity.rawValue
        Heartbeat.record("end \(raw)")

        if raw == ActivityNaming.manual {
            endManualSegment()
            return
        }

        if let index = ActivityNaming.parseAIWindow(raw) {
            // Only a window that ran to its end counts as watched hours.
            AIStatsStore.markWindowObserved(window: index, now: Date())
            return
        }

        guard let parsed = ActivityNaming.parseSchedule(raw) else { return }

        // For an overnight window, the evening ("o0") segment must NOT clear at
        // 23:59:59 — the block continues until the morning ("o1") segment ends.
        if parsed.segment == "o0" { return }

        // Same-day ("s") or overnight-close ("o1") → clear this schedule's store.
        // Clearing is always safe: each schedule owns an isolated named store, so
        // a manual lock or another schedule remains enforced via its own store.
        Shielder.clear(Stores.schedule(parsed.id))
    }

    // MARK: - Usage threshold (AI learning signal)

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)

        if let index = ActivityNaming.parseAIWindow(activity.rawValue) {
            // The user has spent the threshold amount of time in the watched apps
            // during this window → one "heavy use" observation for the model.
            AIStatsStore.recordHit(window: index, now: Date())
            NudgeScheduler.reschedule()
        }
    }

    // MARK: - Manual lock

    /// An interval ending is only a wake-up call, never proof the lock is over:
    /// the user may have moved the clock forward (which ends DeviceActivity
    /// intervals early), or the lock may simply be longer than one segment.
    /// The lock record and the tamper-resistant clock decide.
    private func endManualSegment() {
        guard let record = ManualLockStore.load() else {
            // No record at all: a lock from a pre-v4 build. Its end time lived in
            // the app's private defaults, so the interval is all we can go by.
            Shielder.clear(Stores.manual())
            Shielder.clear(ManagedSettingsStore()) // legacy default store
            return
        }

        let clock = TamperClock.now()
        let remaining = LockGuard.remaining(record, at: clock)
        // Callbacks can arrive a few seconds early; re-arming for those seconds
        // would round up to iOS's 15-minute minimum and over-lock by ~15 min.
        guard remaining > Self.endSlack else {
            // Really over. Leave the record: the app reads it on next open to
            // credit TIME SAVED and the free-lock counter, then deletes it.
            Shielder.clear(Stores.manual())
            Shielder.clear(ManagedSettingsStore())
            return
        }

        // Not over. Keep the shield up and wake again when it might be. If the
        // re-arm fails the shield simply stays (fail-closed) until the app,
        // next opened, sees the lock has expired and clears it.
        reassertManualShield()
        try? ManualLockScheduler.armSegment(remaining: remaining, now: clock.wall)
    }

    private func reassertManualShield() {
        guard ManualLockStore.active() != nil,
              let selection = SelectionStore.load(forKey: StoreKeys.manualLockSelection),
              !SelectionStore.isEmpty(selection) else { return }
        Shielder.apply(selection, to: Stores.manual())
    }

    // MARK: - Schedule shield application

    private func applyScheduleShield(_ parsed: ActivityNaming.ParsedSchedule) {
        guard let config = ScheduleStore.find(parsed.id), config.isEnabled else { return }

        // "Every N weeks" gate. The morning half of an overnight window is
        // attributed to the prior evening's week.
        let isMorningHalf = (parsed.segment == "o1")
        guard WeekParity.isActiveWeek(config, on: Date(), morningHalf: isMorningHalf) else { return }

        guard let selection = SelectionStore.load(forKey: StoreKeys.scheduleSelection(parsed.id)),
              !SelectionStore.isEmpty(selection) else { return }

        // Free trial: one charge per schedule per day, shared with the app so
        // whichever side applies the shield is the side that pays for it. The
        // overnight morning half is a continuation of last night's paid session.
        guard TrialGate.claimSession(config, now: Date()) else { return }

        Shielder.apply(selection, to: Stores.schedule(parsed.id))
    }
}

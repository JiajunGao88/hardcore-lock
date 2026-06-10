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

    // MARK: - Interval start

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        let raw = activity.rawValue

        if let parsed = ActivityNaming.parseSchedule(raw) {
            applyScheduleShield(parsed)
        } else if ActivityNaming.parseAIWindow(raw) != nil {
            // The AI observation window opened → mark that today was observed,
            // then re-sync the pre-cue nudge in case the predicted peak shifted
            // (the app may have been closed for days while the histogram grew).
            AIStatsStore.markDayObserved(now: Date())
            NudgeScheduler.reschedule()
        }
        // Manual lock ("HardcoreLock"): the app already applied the shield.
    }

    // MARK: - Interval end

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        let raw = activity.rawValue

        if raw == ActivityNaming.manual {
            // Backstop: clear the manual lock's shield when its interval ends.
            Shielder.clear(Stores.manual())
            Shielder.clear(ManagedSettingsStore()) // legacy default store (older versions)
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
            // during this window → record one "heavy use" hit for this hour band.
            AIStatsStore.recordHit(window: index, now: Date())
            NudgeScheduler.reschedule()
        }
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

        Shielder.apply(selection, to: Stores.schedule(parsed.id))
    }
}

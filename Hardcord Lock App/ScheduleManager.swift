//
//  ScheduleManager.swift
//  Hardcord Lock App
//
//  Owns Schedule-mode state and translates each ScheduleConfig into
//  DeviceActivity monitors. Recurrence rules:
//    • every-day schedule  → one daily monitor (weekday component omitted)
//    • specific weekdays   → one monitor per weekday (Apple's canonical pattern)
//    • overnight window    → split into evening + morning segments
//    • every N weeks       → weekly monitor + parity check in the extension
//

import Foundation
import Combine
import DeviceActivity
import FamilyControls

@MainActor
final class ScheduleManager: ObservableObject {
    static let shared = ScheduleManager()

    @Published var schedules: [ScheduleConfig] = []
    /// Set when the last reconcile hit the 20-activity system cap.
    @Published var lastBudgetWarning: String?

    private let center = DeviceActivityCenter()

    private init() {
        schedules = ScheduleStore.load()
    }

    // MARK: - Selection access (stored per schedule in the App Group)

    func selection(for id: String) -> FamilyActivitySelection {
        SelectionStore.load(forKey: StoreKeys.scheduleSelection(id)) ?? FamilyActivitySelection()
    }

    func saveSelection(_ selection: FamilyActivitySelection, for id: String) {
        SelectionStore.save(selection, forKey: StoreKeys.scheduleSelection(id))
    }

    // MARK: - CRUD

    func upsert(_ config: ScheduleConfig, selection: FamilyActivitySelection) {
        saveSelection(selection, for: config.id)
        if let idx = schedules.firstIndex(where: { $0.id == config.id }) {
            schedules[idx] = config
        } else {
            schedules.append(config)
        }
        persistAndReconcile()
    }

    func delete(_ id: String) {
        // Clear any active shield this schedule owns before we forget about it,
        // otherwise the apps could stay blocked with no way to reach them.
        Shielder.clear(Stores.schedule(id))
        schedules.removeAll { $0.id == id }
        SelectionStore.remove(forKey: StoreKeys.scheduleSelection(id))
        persistAndReconcile()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let idx = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[idx].isEnabled = enabled
        // Re-anchor parity to "this week is on" whenever a schedule is switched on.
        if enabled { schedules[idx].anchorEpoch = Date().timeIntervalSince1970 }
        persistAndReconcile()
    }

    private func persistAndReconcile() {
        ScheduleStore.save(schedules)
        Automation.reconcileAll()
    }

    // MARK: - Is a schedule currently inside its window?

    func isActiveNow(_ config: ScheduleConfig, now: Date = Date()) -> Bool {
        guard config.isEnabled else { return false }
        let cal = Calendar.current
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
        guard let wd = comps.weekday, let h = comps.hour, let m = comps.minute else { return false }
        let minutesNow = h * 60 + m

        func inWindowOnDay(_ day: Int, morningHalf: Bool) -> Bool {
            guard config.coversEveryDay || config.weekdays.contains(day) else { return false }
            return WeekParity.isActiveWeek(config, on: now, morningHalf: morningHalf)
        }

        if config.isOvernight {
            // Evening half (today is the start weekday) …
            if minutesNow >= config.startMinutes, inWindowOnDay(wd, morningHalf: false) { return true }
            // … or morning half (today is the day AFTER a start weekday).
            let prevDay = (wd + 5) % 7 + 1 // yesterday's weekday (1...7)
            if minutesNow < config.endMinutes, inWindowOnDay(prevDay, morningHalf: true) { return true }
            return false
        } else {
            let endM = config.endsAtMidnight ? 1440 : config.endMinutes
            guard minutesNow >= config.startMinutes, minutesNow < endM else { return false }
            return inWindowOnDay(wd, morningHalf: false)
        }
    }

    var hasActiveScheduleNow: Bool {
        schedules.contains { isActiveNow($0) }
    }

    // MARK: - Reconcile DeviceActivity monitors

    /// Stop all schedule monitors and re-register the enabled ones, respecting
    /// the 20-activity system cap shared with AI mode + a manual-lock reserve.
    func reconcile() {
        lastBudgetWarning = nil

        // Stop existing schedule monitors.
        let existing = center.activities.filter { $0.rawValue.hasPrefix(ActivityNaming.schedulePrefix) }
        if !existing.isEmpty { center.stopMonitoring(existing) }

        // Reset every known schedule's shield to a clean baseline. Stopping a
        // monitor does NOT clear a shield it already applied, so without this a
        // disabled/edited schedule could leave apps blocked. Active schedules are
        // re-asserted directly below (no gap).
        for config in schedules {
            Shielder.clear(Stores.schedule(config.id))
        }

        // Schedules get budget priority; AI mode fills whatever slots remain
        // (HabitEngine reads the count we write below). This avoids a circular
        // reservation between the two subsystems.
        var available = ActivityBudget.max - ActivityBudget.manualReserve

        // AI registers "everything left", so it may be sitting on the slots a
        // newly created schedule needs (it grabbed them before the schedule
        // existed). Priority means AI must yield NOW: stop its windows when the
        // enabled schedules can't fit in what's free — HabitEngine.refresh()
        // runs right after us (Automation order) and re-fills what remains.
        let neededCost = schedules.reduce(0) { sum, c in
            guard c.isEnabled, !SelectionStore.isEmpty(selection(for: c.id)) else { return sum }
            return sum + c.activityCount
        }
        let aiWindows = center.activities.filter { $0.rawValue.hasPrefix(ActivityNaming.aiWindowPrefix) }
        if neededCost > available - aiWindows.count, !aiWindows.isEmpty {
            center.stopMonitoring(aiWindows)
            AppGroup.defaults.set(0, forKey: StoreKeys.aiActivityCount)
        }

        for config in schedules where config.isEnabled {
            let selection = selection(for: config.id)
            guard !SelectionStore.isEmpty(selection) else { continue }
            let cost = config.activityCount
            if cost > available {
                lastBudgetWarning = "Some schedules are paused: iOS limits background blocking to \(ActivityBudget.max) timers. Reduce days/schedules."
                break
            }
            do {
                try register(config)
                available -= cost
                // If we're inside the window right now, apply the shield immediately
                // so foreground re-registration never opens a gap. Free users must
                // still have trial sessions left (the extension counts them at
                // window start; this path only re-asserts, it never counts).
                if isActiveNow(config), TrialGate.isPro || TrialGate.scheduleUsesRemaining > 0 {
                    Shielder.apply(selection, to: Stores.schedule(config.id))
                }
            } catch {
                lastBudgetWarning = "Couldn't activate “\(config.name)”. iOS background-timer limit reached."
                break
            }
        }

        // Write the GROUND-TRUTH count (not an accumulator) so a partial/failed
        // registration can't desync the budget shared with AI mode.
        let liveCount = center.activities.filter { $0.rawValue.hasPrefix(ActivityNaming.schedulePrefix) }.count
        AppGroup.defaults.set(liveCount, forKey: StoreKeys.scheduleActivityCount)
    }

    // MARK: - Registration

    private func register(_ config: ScheduleConfig) throws {
        let days: [Int] = config.coversEveryDay ? [0] : config.weekdays  // 0 = daily (no weekday)

        // Register all segments atomically: if any segment throws, roll back the
        // ones already started so we never leak a half-registered schedule
        // (which would strand the morning shield and desync the budget).
        var started: [DeviceActivityName] = []
        do {
            for day in days {
                if config.isOvernight {
                    // Evening segment: start → 23:59:59 on `day`.
                    started.append(try start(
                        name: ActivityNaming.schedule(id: config.id, weekday: day, segment: "o0"),
                        weekday: day,
                        start: DateComponents(hour: config.startHour, minute: config.startMinute),
                        end: DateComponents(hour: 23, minute: 59, second: 59)
                    ))
                    // Morning segment: 00:00 → end on the FOLLOWING weekday.
                    let morningDay = (day == 0) ? 0 : (day % 7) + 1
                    started.append(try start(
                        name: ActivityNaming.schedule(id: config.id, weekday: morningDay, segment: "o1"),
                        weekday: morningDay,
                        start: DateComponents(hour: 0, minute: 0),
                        end: DateComponents(hour: config.endHour, minute: config.endMinute)
                    ))
                } else {
                    // "Until midnight" (end 00:00) is same-day: cap at 23:59:59
                    // instead of producing a zero-length overnight morning half.
                    let end = config.endsAtMidnight
                        ? DateComponents(hour: 23, minute: 59, second: 59)
                        : DateComponents(hour: config.endHour, minute: config.endMinute)
                    started.append(try start(
                        name: ActivityNaming.schedule(id: config.id, weekday: day, segment: "s"),
                        weekday: day,
                        start: DateComponents(hour: config.startHour, minute: config.startMinute),
                        end: end
                    ))
                }
            }
        } catch {
            if !started.isEmpty { center.stopMonitoring(started) }
            throw error
        }
    }

    @discardableResult
    private func start(name: String, weekday: Int, start: DateComponents, end: DateComponents) throws -> DeviceActivityName {
        var startC = start
        var endC = end
        if weekday != 0 {            // 0 = every-day; otherwise pin to a weekday (weekly repeat)
            startC.weekday = weekday
            endC.weekday = weekday
        }
        let schedule = DeviceActivitySchedule(intervalStart: startC, intervalEnd: endC, repeats: true)
        let activityName = DeviceActivityName(name)
        try center.startMonitoring(activityName, during: schedule)
        return activityName
    }
}

// MARK: - Automation coordinator

/// Runs both subsystems in a fixed order (schedules first, then AI fills the
/// remaining activity slots) so freed slots are reclaimed immediately and the
/// shared 20-activity budget never depends on stale cross-manager counts.
@MainActor
enum Automation {
    static func reconcileAll() {
        ScheduleManager.shared.reconcile()
        HabitEngine.shared.refresh()
    }
}

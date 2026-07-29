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

/// What a schedule is doing right now. Replaces a single ambiguous "ACTIVE"
/// boolean: users read that as "switched on", the code meant "inside its window".
enum ScheduleStatus: Equatable {
    /// Switched off by the user.
    case off
    /// On and registered, waiting for its next window.
    case armed
    /// On and inside its window right now — apps are shielded.
    case blocking
    /// On, but it cannot block; the string is the user-facing reason.
    case paused(String)
}

@MainActor
final class ScheduleManager: ObservableObject {
    static let shared = ScheduleManager()

    @Published var schedules: [ScheduleConfig] = []
    /// Set when the last reconcile hit the 20-activity system cap.
    @Published var lastBudgetWarning: String?

    /// Snapshots taken by `reconcile()` so `status(_:now:)` — which SwiftUI calls
    /// once per row on every render — stays pure arithmetic instead of doing
    /// UserDefaults I/O, a JSON decode and a DeviceActivityCenter query per row.
    @Published private(set) var registeredScheduleIds: Set<String> = []
    @Published private(set) var emptySelectionIds: Set<String> = []

    private let center = DeviceActivityCenter()

    private init() {
        schedules = ScheduleStore.load()
        // Seed the snapshots from reality. Left empty, any row rendered before
        // the first reconcile would claim "PAUSED · iOS LIMIT" — monitors from
        // the previous launch are still registered, so ask.
        registeredScheduleIds = Set(center.activities.compactMap {
            ActivityNaming.parseSchedule($0.rawValue)?.id
        })
        emptySelectionIds = Set(schedules.filter { SelectionStore.isEmpty(selection(for: $0.id)) }.map(\.id))
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

    // MARK: - Status (what the row badge shows)

    /// Ground truth for one schedule, so the badge can never claim a schedule is
    /// blocking when it demonstrably isn't. `isActiveNow` alone was ambiguous:
    /// it means "inside its clock window", which users read as "switched on".
    func status(_ config: ScheduleConfig, now: Date = Date()) -> ScheduleStatus {
        guard config.isEnabled else { return .off }
        if emptySelectionIds.contains(config.id) { return .paused("NO APPS") }
        // A session already charged stays entitled even at zero balance — never
        // tell a user their running block is paused.
        if isActiveNow(config, now: now), TrialGate.sessionEntitled(config, now: now) { return .blocking }
        // Ask the trial question BEFORE the registration question: a schedule the
        // trial can't pay for is deliberately left unregistered, and blaming
        // that on iOS's timer cap would be a lie.
        if !canEverFire(config, now: now) { return .paused("TRIAL USED UP") }
        // Enabled and payable, but iOS never accepted its monitors (20-activity
        // cap, or a rejected window) → it will not fire, so "armed" would lie too.
        if !registeredScheduleIds.contains(config.id) { return .paused("iOS LIMIT") }
        return .armed
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
            guard c.isEnabled, canEverFire(c), !SelectionStore.isEmpty(selection(for: c.id)) else { return sum }
            return sum + c.activityCount
        }
        let aiWindows = center.activities.filter { $0.rawValue.hasPrefix(ActivityNaming.aiWindowPrefix) }
        if neededCost > available - aiWindows.count, !aiWindows.isEmpty {
            center.stopMonitoring(aiWindows)
            AppGroup.defaults.set(0, forKey: StoreKeys.aiActivityCount)
        }

        var starved: [String] = []
        var failed: [String] = []

        for config in schedules where config.isEnabled {
            let selection = selection(for: config.id)
            guard !SelectionStore.isEmpty(selection) else { continue }
            // A schedule the trial can never pay for would hold monitor slots
            // hostage forever (starving AI mode) while never blocking anything.
            guard canEverFire(config) else { continue }
            let cost = config.activityCount
            if cost > available {
                // `continue`, not `break`: a later schedule may be cheap enough
                // to fit in what's left. One expensive schedule must not silently
                // disable every schedule after it in the list.
                starved.append(config.name)
                continue
            }
            do {
                try register(config)
                available -= cost
                // Inside the window right now → shield immediately so foreground
                // re-registration never opens a gap. claimSession charges the
                // first block of the day; it is idempotent, so re-asserting is free.
                if isActiveNow(config), TrialGate.claimSession(config, now: Date()) {
                    Shielder.apply(selection, to: Stores.schedule(config.id))
                }
            } catch {
                failed.append(config.name)
                continue
            }
        }

        lastBudgetWarning = budgetWarning(starved: starved, failed: failed)

        // Write the GROUND-TRUTH count (not an accumulator) so a partial/failed
        // registration can't desync the budget shared with AI mode.
        let live = center.activities.filter { $0.rawValue.hasPrefix(ActivityNaming.schedulePrefix) }
        AppGroup.defaults.set(live.count, forKey: StoreKeys.scheduleActivityCount)

        // Snapshot what the badge needs, so rendering never touches disk or
        // DeviceActivity again (see `status(_:now:)`).
        registeredScheduleIds = Set(live.compactMap { ActivityNaming.parseSchedule($0.rawValue)?.id })
        emptySelectionIds = Set(schedules.filter { SelectionStore.isEmpty(selection(for: $0.id)) }.map(\.id))
    }

    /// False when the free trial can never pay for this schedule again, so
    /// registering it would burn monitor slots for something that can't fire.
    private func canEverFire(_ config: ScheduleConfig, now: Date = Date()) -> Bool {
        TrialGate.isPro || TrialGate.scheduleUsesRemaining > 0 || TrialGate.sessionEntitled(config, now: now)
    }

    private func budgetWarning(starved: [String], failed: [String]) -> String? {
        var parts: [String] = []
        if !starved.isEmpty {
            parts.append("Paused (iOS allows only \(ActivityBudget.max) background timers): \(starved.joined(separator: ", ")). Use fewer days or schedules.")
        }
        if !failed.isEmpty {
            parts.append("Couldn't activate: \(failed.joined(separator: ", ")). Check Screen Time access and that each window is at least 15 minutes.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
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

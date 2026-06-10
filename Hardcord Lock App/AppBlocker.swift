//
//  AppBlocker.swift
//  Hardcord Lock App
//
//  Manual ("NOW") and AI-challenge locks. These use the isolated `.manual`
//  ManagedSettings store so they are never affected by Schedule-mode shields
//  (which live in their own per-schedule stores) and vice-versa.
//

import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

final class AppBlocker {
    static let shared = AppBlocker()

    private let center = DeviceActivityCenter()

    private init() {}

    // MARK: - Start blocking (manual / AI)

    func startBlocking(apps: FamilyActivitySelection, duration: TimeInterval) throws {

        let minSeconds: TimeInterval = 15 * 60
        guard duration >= minSeconds else {
            throw AppBlockerError.intervalTooShort(minMinutes: 15)
        }

        print("🚫 Start blocking apps (manual store)...")

        let activityName = DeviceActivityName(ActivityNaming.manual)

        // Persist the selection so the extension can re-assert/clear if needed.
        SelectionStore.save(apps, forKey: StoreKeys.manualSelection)

        let now = Date()
        let endDate = now.addingTimeInterval(duration)

        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComponents = calendar.dateComponents([.hour, .minute, .second], from: endDate)

        let schedule = DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )

        // NOTE: this time-of-day schedule is only a best-effort backstop for
        // clearing the shield. For locks that cross midnight or span >24h the
        // interval is degenerate/unreliable, so REAL enforcement comes from:
        //   • the shield living on a persistent ManagedSettingsStore (stays applied
        //     until explicitly cleared), and
        //   • LockManager's absolute end-time timer (resumed across relaunches), plus
        //     the foreground/relaunch stale-shield clearing in ContentView/LockManager.
        // This guarantees we never unlock early; at worst the shield lingers until
        // the app is next opened.
        try center.startMonitoring(activityName, during: schedule)

        // Apply the shield to the isolated manual store.
        Shielder.apply(apps, to: Stores.manual())

        print("✅ Apps shielded for \(Int(duration)) seconds")
    }

    // MARK: - Stop blocking (internal only — no early-unlock UI)

    func stopBlocking() {
        let activityName = DeviceActivityName(ActivityNaming.manual)
        center.stopMonitoring([activityName])
        Shielder.clear(Stores.manual())
        // Also clear the legacy default store, in case a lock from an older
        // version (which used the default store) is still in flight after upgrade.
        Shielder.clear(ManagedSettingsStore())
        print("🔓 Manual shield removed")
    }
}

enum AppBlockerError: LocalizedError {
    case intervalTooShort(minMinutes: Int)

    var errorDescription: String? {
        switch self {
        case .intervalTooShort(let minMinutes):
            return "Minimum duration is \(minMinutes) minutes."
        }
    }
}

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

    private init() {}

    // MARK: - Start blocking (manual / AI)

    /// Shields `apps` for `duration` and returns the lock record. Order matters:
    /// the record and selection are written BEFORE the DeviceActivity interval
    /// is armed, because arming can fire intervalDidStart in the extension
    /// immediately and the extension acts on what it finds in the App Group.
    @discardableResult
    func startBlocking(apps: FamilyActivitySelection, duration: TimeInterval, source: String) throws -> ManualLockRecord {
        let minSeconds: TimeInterval = 15 * 60
        guard duration >= minSeconds else {
            throw AppBlockerError.intervalTooShort(minMinutes: 15)
        }
        guard !SelectionStore.isEmpty(apps) else { throw AppBlockerError.nothingSelected }

        let record = ManualLockRecord(duration: duration, source: source, clock: TamperClock.now())
        SelectionStore.save(apps, forKey: StoreKeys.manualLockSelection)
        ManualLockStore.save(record)

        do {
            // A wake-up call for the extension, not the enforcement: the shield
            // lives on a persistent store until explicitly cleared, and the
            // extension re-arms segment after segment until LockGuard says the
            // lock is really over. Segments keep a multi-day lock legal for iOS.
            try ManualLockScheduler.armSegment(remaining: duration, now: record.startWall)
        } catch {
            ManualLockStore.clear()
            SelectionStore.remove(forKey: StoreKeys.manualLockSelection)
            throw error
        }

        Shielder.apply(apps, to: Stores.manual())
        return record
    }

    // MARK: - Stop blocking (internal only — no early-unlock UI)

    /// Lifts the manual shield. Callers must have established that the lock is
    /// over (LockGuard) — this does not check.
    func stopBlocking() {
        DeviceActivityCenter().stopMonitoring([DeviceActivityName(ActivityNaming.manual)])
        Shielder.clear(Stores.manual())
        // Also clear the legacy default store, in case a lock from an older
        // version (which used the default store) is still in flight after upgrade.
        Shielder.clear(ManagedSettingsStore())
        SelectionStore.remove(forKey: StoreKeys.manualLockSelection)
    }
}

enum AppBlockerError: LocalizedError {
    case intervalTooShort(minMinutes: Int)
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case .intervalTooShort(let minMinutes):
            return "Minimum duration is \(minMinutes) minutes."
        case .nothingSelected:
            return "Pick at least one app or category to block."
        }
    }
}

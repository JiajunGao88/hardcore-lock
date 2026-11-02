//
//  LockManager.swift
//  Hardcord Lock App
//
//  UI-facing state of the manual / AI lock. The truth lives in the App Group
//  (ManualLockStore) and is judged by LockGuard's tamper-resistant clock, so
//  changing the system time neither ends a lock early nor confuses the
//  countdown.
//

import Foundation
import Combine
import UserNotifications

@MainActor
final class LockManager: ObservableObject {
    static let shared = LockManager()

    @Published var isLocked: Bool = false
    @Published var remainingSeconds: Int = 0
    @Published var totalLockedSeconds: Int = 0
    /// Full length of the running lock, for progress display.
    @Published private(set) var lockDuration: Int = 0

    /// When the current lock ends, for display. Derived from the tamper-resistant
    /// remaining time, not the stored wall-clock end, so a moved clock can't skew it.
    var lockEndDate: Date? {
        isLocked ? Date().addingTimeInterval(TimeInterval(remainingSeconds)) : nil
    }

    private var displayUpdateTimer: Timer?

    private init() {
        totalLockedSeconds = UserDefaults.standard.integer(forKey: "totalLockedSeconds")
        migrateLegacyLock()
        refresh()
        requestNotificationPermission()
    }

    // MARK: - Start

    /// Adopt a lock AppBlocker has just applied.
    func startLock(_ record: ManualLockRecord) {
        isLocked = true
        lockDuration = Int(record.duration)
        remainingSeconds = Int(record.duration)
        startDisplayTimer()
        scheduleNotification(in: Int(record.duration))
    }

    // MARK: - Re-sync (launch / foreground)

    /// Reconcile with the stored lock: resume a running one, or finish one that
    /// ended while the app wasn't running (crediting it exactly once).
    func refresh() {
        guard let record = ManualLockStore.load() else {
            stopDisplayTimer()
            if isLocked { isLocked = false; remainingSeconds = 0 }
            return
        }
        let remaining = LockGuard.remaining(record, at: TamperClock.now())
        if remaining > 0 {
            isLocked = true
            lockDuration = Int(record.duration)
            remainingSeconds = Int(remaining.rounded(.up))
            startDisplayTimer()
        } else {
            finish(record)
        }
    }

    // MARK: - Display timer

    private func startDisplayTimer() {
        guard displayUpdateTimer == nil else { return }
        displayUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let record = ManualLockStore.load() else {
            stopDisplayTimer()
            isLocked = false
            remainingSeconds = 0
            return
        }
        let remaining = LockGuard.remaining(record, at: TamperClock.now())
        if remaining > 0 {
            remainingSeconds = Int(remaining.rounded(.up))
        } else {
            finish(record)
        }
    }

    private func stopDisplayTimer() {
        displayUpdateTimer?.invalidate()
        displayUpdateTimer = nil
    }

    // MARK: - Finish

    private func finish(_ record: ManualLockRecord) {
        stopDisplayTimer()
        // Lift immediately — don't wait on the extension's intervalDidEnd.
        AppBlocker.shared.stopBlocking()
        ManualLockStore.clear()

        let lockedDuration = Int(record.duration)
        if lockedDuration > 0 {
            totalLockedSeconds += lockedDuration
            UserDefaults.standard.set(totalLockedSeconds, forKey: "totalLockedSeconds")
            StoreManager.shared.recordCompletedLock(source: record.source)
        }

        isLocked = false
        remainingSeconds = 0
    }

    /// v3 kept the lock in the app's private defaults, judged by the wall clock.
    /// Carry a lock in flight across the upgrade instead of dropping it.
    private func migrateLegacyLock() {
        let std = UserDefaults.standard
        guard let end = std.object(forKey: "lockEndTime") as? Date else { return }
        defer {
            std.removeObject(forKey: "lockEndTime")
            std.removeObject(forKey: "lockStartTime")
            std.removeObject(forKey: "activeLockSource")
        }
        guard ManualLockStore.load() == nil else { return }

        let clock = TamperClock.now()
        let start = std.object(forKey: "lockStartTime") as? Date ?? min(clock.wall, end)
        var record = ManualLockRecord(duration: end.timeIntervalSince(start),
                                      source: std.string(forKey: "activeLockSource") ?? "manual",
                                      clock: clock)
        record.startWall = start
        record.endWall = end
        // No boot ID: v3 never recorded one, so LockGuard judges this lock by
        // the wall clock — exactly as v3 did, no stricter and no looser.
        record.bootID = nil
        ManualLockStore.save(record)
        if let legacySelection = SelectionStore.load(forKey: StoreKeys.manualSelection) {
            SelectionStore.save(legacySelection, forKey: StoreKeys.manualLockSelection)
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func scheduleNotification(in seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "LOCK COMPLETE"
        content.body = "Your focus session has ended."
        content.sound = .default
        content.badge = NSNumber(value: 1)

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(1, seconds)), repeats: false)
        let request = UNNotificationRequest(identifier: "lockComplete", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Formatting

    func formatTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    func formatTotalTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return "\(minutes)m"
    }

    // MARK: - Debug functions (development only)
    #if DEBUG
    func debugAddTime(seconds: Int) {
        totalLockedSeconds += seconds
        UserDefaults.standard.set(totalLockedSeconds, forKey: "totalLockedSeconds")
    }

    func debugResetTime() {
        totalLockedSeconds = 0
        UserDefaults.standard.set(0, forKey: "totalLockedSeconds")
    }

    func debugSkipLock() {
        guard let record = ManualLockStore.load() else { return }
        stopDisplayTimer()
        AppBlocker.shared.stopBlocking()
        ManualLockStore.clear()
        let elapsed = Int(record.duration) - remainingSeconds
        if elapsed > 0 {
            totalLockedSeconds += elapsed
            UserDefaults.standard.set(totalLockedSeconds, forKey: "totalLockedSeconds")
        }
        StoreManager.shared.recordCompletedLock(source: record.source)
        isLocked = false
        remainingSeconds = 0
    }
    #endif
}

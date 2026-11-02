//
//  LockGuard.swift
//  Hardcord Lock App
//
//  SHARED with the DeviceActivityManager extension (same rules as SharedKit:
//  Foundation / ManagedSettings / DeviceActivity only — never SwiftUI/UIKit).
//
//  The manual (NOW / AI-challenge) lock's single source of truth. Before v4 the
//  lock's end time lived in the app's private UserDefaults and was judged by the
//  wall clock, so:
//    • the extension couldn't see it and cleared the shield whenever its
//      DeviceActivity interval ended — which for a lock of 24h+ was
//      (duration mod 24h) after it started;
//    • moving the system clock forward ended the lock on the next app open.
//  Now the record lives in the App Group and expiry is judged by a clock the
//  user can't set.
//

import Foundation
import DeviceActivity
import ManagedSettings

// MARK: - Tamper-resistant clock

/// A reading of every clock we judge a lock by.
struct ClockReading: Equatable {
    var wall: Date
    /// Seconds since boot, INCLUDING time asleep. Unaffected by Settings >
    /// Date & Time. Resets on reboot.
    var monotonic: Double
    /// Identifies the current boot, or nil when the OS won't say.
    var bootID: String?
}

enum TamperClock {
    /// `CLOCK_MONOTONIC_RAW` on Darwin keeps counting while the device sleeps.
    /// (`ProcessInfo.systemUptime` / `CLOCK_UPTIME_RAW` stop during sleep, which
    /// would over-lock by every hour the screen was off.)
    static func monotonicSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
    }

    /// Resolved once per process: it can't change without a reboot, and a
    /// reboot starts a new process.
    static let bootID: String? = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let id = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return id.isEmpty ? nil : id
    }()

    static func now() -> ClockReading {
        ClockReading(wall: Date(), monotonic: monotonicSeconds(), bootID: bootID)
    }
}

// MARK: - Lock record

struct ManualLockRecord: Codable, Equatable {
    var startWall: Date
    var endWall: Date
    var startMonotonic: Double
    var bootID: String?
    /// "manual" or "ai" — decides which free-trial counter a finished lock uses.
    var source: String

    var duration: TimeInterval { endWall.timeIntervalSince(startWall) }

    init(duration: TimeInterval, source: String, clock: ClockReading) {
        startWall = clock.wall
        endWall = clock.wall.addingTimeInterval(duration)
        startMonotonic = clock.monotonic
        bootID = clock.bootID
        self.source = source
    }
}

enum LockGuard {
    /// Same boot, and we can prove it? Then the monotonic clock is authoritative.
    private static func sameBoot(_ record: ManualLockRecord, _ clock: ClockReading) -> Bool {
        guard let recorded = record.bootID, let current = clock.bootID else { return false }
        return recorded == current
    }

    /// Seconds left on the lock. Within one boot this ignores the wall clock
    /// entirely, so changing the date neither ends nor stretches the lock. After
    /// a reboot the monotonic clock restarted and only the wall clock is left.
    static func remaining(_ record: ManualLockRecord, at clock: ClockReading) -> TimeInterval {
        if sameBoot(record, clock) {
            return max(0, record.duration - (clock.monotonic - record.startMonotonic))
        }
        return max(0, record.endWall.timeIntervalSince(clock.wall))
    }

    static func isExpired(_ record: ManualLockRecord, at clock: ClockReading) -> Bool {
        remaining(record, at: clock) <= 0
    }
}

enum ManualLockStore {
    static func load() -> ManualLockRecord? {
        guard let data = AppGroup.defaults.data(forKey: StoreKeys.manualLock) else { return nil }
        return try? JSONDecoder().decode(ManualLockRecord.self, from: data)
    }

    static func save(_ record: ManualLockRecord) {
        if let data = try? JSONEncoder().encode(record) {
            AppGroup.defaults.set(data, forKey: StoreKeys.manualLock)
        }
    }

    static func clear() {
        AppGroup.defaults.removeObject(forKey: StoreKeys.manualLock)
    }

    /// The record, if a lock is still running right now.
    static func active(at clock: ClockReading = TamperClock.now()) -> ManualLockRecord? {
        guard let record = load(), !LockGuard.isExpired(record, at: clock) else { return nil }
        return record
    }
}

// MARK: - Segmented DeviceActivity backstop

/// Arms the DeviceActivity interval that wakes the extension when a manual lock
/// may have ended. The interval is only a wake-up call: the extension consults
/// `LockGuard` and, if the lock isn't really over (clock moved, or a lock longer
/// than one segment), re-shields and arms the next segment.
enum ManualLockScheduler {
    /// iOS rejects intervals over a week; a day keeps every segment well inside
    /// the limit at the cost of one extra extension wake per day of lock.
    static let maxSegment: TimeInterval = 24 * 3600
    /// iOS rejects intervals under 15 minutes; a few seconds of slack absorbs
    /// truncating both ends to whole seconds.
    static let minSegment: TimeInterval = 15 * 60 + 5

    static func segmentLength(remaining: TimeInterval) -> TimeInterval {
        min(max(remaining, minSegment), maxSegment)
    }

    /// Absolute (year…second) components. Hour/minute-only components — what
    /// v3 used — are ambiguous across midnight and alias every 24 hours.
    static func components(_ date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    static func armSegment(remaining: TimeInterval, now: Date = Date()) throws {
        let center = DeviceActivityCenter()
        let name = DeviceActivityName(ActivityNaming.manual)
        let schedule = DeviceActivitySchedule(
            intervalStart: components(now),
            intervalEnd: components(now.addingTimeInterval(segmentLength(remaining: remaining))),
            repeats: false
        )
        center.stopMonitoring([name])
        try center.startMonitoring(name, during: schedule)
    }
}

// MARK: - Hardcore settings

enum HardcoreSettings {
    /// While any lock or schedule is blocking, deny deleting apps — including
    /// FIFTEEN itself, which would otherwise take every shield with it.
    /// iOS can't scope this to one app: it blocks deleting ALL apps meanwhile.
    static var preventUninstall: Bool {
        get { AppGroup.defaults.object(forKey: StoreKeys.preventUninstall) as? Bool ?? true }
        set { AppGroup.defaults.set(newValue, forKey: StoreKeys.preventUninstall) }
    }
}

// MARK: - Extension heartbeat (diagnostics)

/// The extension stamps every callback here so the app can tell "the schedule
/// never fired" apart from "the extension isn't running at all".
enum Heartbeat {
    static func record(_ event: String, at date: Date = Date()) {
        AppGroup.defaults.set(event, forKey: StoreKeys.heartbeatEvent)
        AppGroup.defaults.set(date.timeIntervalSince1970, forKey: StoreKeys.heartbeatTime)
    }

    static var last: (event: String, at: Date)? {
        let t = AppGroup.defaults.double(forKey: StoreKeys.heartbeatTime)
        guard t > 0, let event = AppGroup.defaults.string(forKey: StoreKeys.heartbeatEvent) else { return nil }
        return (event, Date(timeIntervalSince1970: t))
    }
}

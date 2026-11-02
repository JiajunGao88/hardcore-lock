//
//  Hardcord_Lock_AppTests.swift
//  Hardcord Lock AppTests
//
//  Pure-logic tests: everything here runs without Screen Time, so it works on
//  the simulator in CI. Device-only behaviour (shields actually appearing) is
//  covered by the manual checklist in docs/adr/0001.
//

import XCTest
@testable import Hardcord_Lock_App

/// Deterministic RNG so bandit/sampler tests can't flake.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

// MARK: - Lock guard (anti-tamper)

final class LockGuardTests: XCTestCase {
    private let start = ClockReading(wall: Date(timeIntervalSince1970: 1_000_000), monotonic: 500, bootID: "boot-A")

    func testSameBootIgnoresWallClockJumpForward() {
        let record = ManualLockRecord(duration: 3600, source: "manual", clock: start)
        // User moves the clock a day forward, but only 10 real minutes passed.
        let later = ClockReading(wall: start.wall.addingTimeInterval(86_400), monotonic: 500 + 600, bootID: "boot-A")
        XCTAssertFalse(LockGuard.isExpired(record, at: later))
        XCTAssertEqual(LockGuard.remaining(record, at: later), 3000, accuracy: 0.001)
    }

    func testSameBootIgnoresWallClockJumpBackward() {
        let record = ManualLockRecord(duration: 3600, source: "manual", clock: start)
        let later = ClockReading(wall: start.wall.addingTimeInterval(-86_400), monotonic: 500 + 3600, bootID: "boot-A")
        XCTAssertTrue(LockGuard.isExpired(record, at: later))
    }

    func testAfterRebootFallsBackToWallClock() {
        let record = ManualLockRecord(duration: 3600, source: "manual", clock: start)
        let rebooted = ClockReading(wall: start.wall.addingTimeInterval(1800), monotonic: 30, bootID: "boot-B")
        XCTAssertEqual(LockGuard.remaining(record, at: rebooted), 1800, accuracy: 0.001)
        let rebootedLater = ClockReading(wall: start.wall.addingTimeInterval(3601), monotonic: 30, bootID: "boot-B")
        XCTAssertTrue(LockGuard.isExpired(record, at: rebootedLater))
    }

    func testUnknownBootIDFallsBackToWallClock() {
        let noID = ClockReading(wall: start.wall, monotonic: 500, bootID: nil)
        let record = ManualLockRecord(duration: 3600, source: "ai", clock: noID)
        let later = ClockReading(wall: start.wall.addingTimeInterval(4000), monotonic: 600, bootID: nil)
        XCTAssertTrue(LockGuard.isExpired(record, at: later))
    }

    func testRecordRoundTripsThroughJSON() throws {
        let record = ManualLockRecord(duration: 7200, source: "ai", clock: start)
        let decoded = try JSONDecoder().decode(ManualLockRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.duration, 7200, accuracy: 0.001)
    }

    func testSegmentLengthStaysInsideIOSLimits() {
        XCTAssertEqual(ManualLockScheduler.segmentLength(remaining: 60), ManualLockScheduler.minSegment)
        XCTAssertEqual(ManualLockScheduler.segmentLength(remaining: 3600), 3600)
        XCTAssertEqual(ManualLockScheduler.segmentLength(remaining: 30 * 86_400), ManualLockScheduler.maxSegment)
        XCTAssertGreaterThanOrEqual(ManualLockScheduler.minSegment, 15 * 60)
    }

    func testSegmentComponentsAreAbsolute() {
        let c = ManualLockScheduler.components(Date())
        XCTAssertNotNil(c.year)
        XCTAssertNotNil(c.month)
        XCTAssertNotNil(c.day)
        XCTAssertNotNil(c.second)
    }
}

// MARK: - Schedules

final class ScheduleLogicTests: XCTestCase {
    func testOvernightDetection() {
        XCTAssertTrue(ScheduleConfig(startHour: 22, endHour: 6).isOvernight)
        XCTAssertFalse(ScheduleConfig(startHour: 9, endHour: 17).isOvernight)
        // Ending exactly at midnight is "until midnight", not overnight.
        let midnight = ScheduleConfig(startHour: 20, endHour: 0)
        XCTAssertFalse(midnight.isOvernight)
        XCTAssertTrue(midnight.endsAtMidnight)
    }

    func testActivityCount() {
        XCTAssertEqual(ScheduleConfig(weekdays: [2, 3, 4, 5, 6]).activityCount, 5)
        XCTAssertEqual(ScheduleConfig(weekdays: Array(1...7)).activityCount, 1)
        XCTAssertEqual(ScheduleConfig(weekdays: [2, 3], startHour: 22, endHour: 6).activityCount, 4)
    }

    func testEveryOtherWeekParity() {
        let anchor = Date(timeIntervalSince1970: 1_780_000_000)
        let config = ScheduleConfig(everyNWeeks: 2, anchorEpoch: anchor.timeIntervalSince1970)
        XCTAssertTrue(WeekParity.isActiveWeek(config, on: anchor))
        XCTAssertFalse(WeekParity.isActiveWeek(config, on: anchor.addingTimeInterval(7 * 86_400)))
        XCTAssertTrue(WeekParity.isActiveWeek(config, on: anchor.addingTimeInterval(14 * 86_400)))
    }

    func testWeeklyIsAlwaysActive() {
        let config = ScheduleConfig(everyNWeeks: 1)
        XCTAssertTrue(WeekParity.isActiveWeek(config, on: Date().addingTimeInterval(7 * 86_400)))
    }

    func testActivityNameRoundTrip() {
        let id = UUID().uuidString
        let raw = ActivityNaming.schedule(id: id, weekday: 3, segment: "o1")
        let parsed = ActivityNaming.parseSchedule(raw)
        XCTAssertEqual(parsed?.id, id)
        XCTAssertEqual(parsed?.weekday, 3)
        XCTAssertEqual(parsed?.segment, "o1")
        XCTAssertNil(ActivityNaming.parseSchedule(ActivityNaming.manual))
        XCTAssertEqual(ActivityNaming.parseAIWindow(ActivityNaming.aiWindow(7)), 7)
    }
}

// MARK: - AI configuration

final class AIConfigTests: XCTestCase {
    func testWindowLayoutNeverCrossesMidnightAndCoversSpan() {
        for n in 1...AIConfig.maxWindows {
            let layout = AIConfig.windowLayout(n)
            XCTAssertEqual(layout.count, n)
            var covered = 0
            for w in layout {
                XCTAssertLessThan(w.startMin, w.endMin, "window crosses midnight for n=\(n)")
                XCTAssertLessThanOrEqual(w.endMin, 1440)
                XCTAssertGreaterThanOrEqual(w.endMin - w.startMin, 15, "window under iOS minimum for n=\(n)")
                covered += w.endMin - w.startMin
            }
            // One window can't straddle midnight, so n = 1 covers the evening only.
            let span = n == 1 ? (24 - AIConfig.coverageStartHour) * 60 : (AIConfig.coverageEndHour - AIConfig.coverageStartHour) * 60
            XCTAssertEqual(covered, span, "coverage gap for n=\(n)")
        }
    }

    func testClockHoursCoverOnlyTheWindow() {
        XCTAssertEqual(AIConfig.clockHours(startMin: 20 * 60, endMin: 21 * 60), [20])
        XCTAssertEqual(AIConfig.clockHours(startMin: 7 * 60, endMin: 11 * 60 + 15), [7, 8, 9, 10, 11])
        XCTAssertEqual(AIConfig.clockHours(startMin: 23 * 60, endMin: 1440), [23])
        XCTAssertEqual(AIConfig.clockHours(startMin: 0, endMin: 120), [0, 1])
        XCTAssertEqual(AIConfig.clockHours(startMin: 60, endMin: 60), [])
    }

    func testLegacyConfigDecodesWithoutResettingAIMode() throws {
        // A v3 config: no adaptiveLead key.
        let json = #"{"isEnabled":true,"leadMinutes":20,"lockDurationSeconds":3600,"minObservationDays":3,"triggerFrequency":0.4}"#
        let config = try JSONDecoder().decode(AIConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.leadMinutes, 20)
        XCTAssertTrue(config.adaptiveLead)
    }

    func testNudgeMinuteWraps() {
        XCTAssertEqual(AIConfig.nudgeMinute(peakMinute: 5, leadMinutes: 15), 1430)
        XCTAssertEqual(AIConfig.nudgeMinute(peakMinute: 1260, leadMinutes: 15), 1245)
    }
}

// MARK: - Habit model

final class HabitModelTests: XCTestCase {
    private let friday = 6
    private var hours: [Int] { BehavioralDay.coverageHours }

    /// `days` observed Fridays, each with a hit at `hitHour` on the first `hitDays`.
    private func model(days: Int, hitDays: Int, hitHour: Int, weekday: Int = 6) -> HabitModel {
        var m = HabitModel()
        for d in 0..<days {
            let day = 20_000 + d * 7
            m.observe(weekday: weekday, hours: hours, day: day)
            if d < hitDays { m.recordHit(weekday: weekday, hour: hitHour, day: day) }
        }
        return m
    }

    func testConsistentHabitIsFound() {
        let m = model(days: 5, hitDays: 5, hitHour: 21)
        XCTAssertEqual(m.peakHour(weekday: friday, threshold: AIConfig().peakThreshold), 21)
    }

    func testSingleNoisyHitIsNotAHabit() {
        let m = model(days: 6, hitDays: 1, hitHour: 14)
        XCTAssertNil(m.peakHour(weekday: friday, threshold: AIConfig().peakThreshold))
    }

    func testEstimateIsAProbabilityWithLowerBoundBelowMean() {
        let m = model(days: 4, hitDays: 4, hitHour: 21)
        let e = m.estimate(weekday: friday, hour: 21)
        XCTAssertGreaterThan(e.mean, 0.5)
        XCTAssertLessThan(e.mean, 1)
        XCTAssertLessThan(e.lower, e.mean)
        XCTAssertGreaterThanOrEqual(e.lower, 0)
    }

    func testOtherWeekdaysBorrowStrengthButStayLessCertain() {
        var m = HabitModel()
        // Strong habit on every weekday but Sunday, which is never observed.
        for weekday in 2...7 {
            for d in 0..<4 {
                let day = 20_000 + d * 7 + weekday
                m.observe(weekday: weekday, hours: hours, day: day)
                m.recordHit(weekday: weekday, hour: 22, day: day)
            }
        }
        let observed = m.estimate(weekday: 2, hour: 22)
        let unobserved = m.estimate(weekday: 1, hour: 22)
        XCTAssertGreaterThan(unobserved.mean, 0.5, "pooled estimate should carry over")
        XCTAssertLessThan(unobserved.lower, observed.lower, "but with less certainty")
    }

    func testDuplicateHitsSameDayCountOnce() {
        var m = HabitModel()
        m.observe(weekday: friday, hours: hours, day: 20_000)
        m.recordHit(weekday: friday, hour: 21, day: 20_000)
        m.recordHit(weekday: friday, hour: 21, day: 20_000)
        let i = HabitModel.index(weekday: friday, hour: 21)
        XCTAssertEqual(m.hits[i], 1)
        XCTAssertEqual(m.exposures[i], 1)
    }

    func testHitsNeverExceedExposures() {
        var m = HabitModel()
        m.recordHit(weekday: friday, hour: 21, day: 20_000) // hit with no observe first
        let i = HabitModel.index(weekday: friday, hour: 21)
        XCTAssertLessThanOrEqual(m.hits[i], m.exposures[i])
    }

    func testDecayHalvesAfterHalfLife() {
        var m = model(days: 1, hitDays: 1, hitHour: 21)
        let i = HabitModel.index(weekday: friday, hour: 21)
        let before = m.hits[i]
        m.decay(to: m.decayedThrough + Int(HabitModel.halfLifeDays))
        XCTAssertEqual(m.hits[i], before / 2, accuracy: 1e-9)
    }

    func testModelRoundTripsThroughJSON() throws {
        let m = model(days: 3, hitDays: 2, hitHour: 20)
        let decoded = try JSONDecoder().decode(HabitModel.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(decoded, m)
    }

    func testMigrationFromLegacyStats() {
        var stats = AIStats()
        stats.daysObserved = 14
        stats.hitMinutes = Array(repeating: 21 * 60 + 10, count: 12)
        let m = HabitModel.migrated(from: stats, day: 20_000)
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(m.peakHour(weekday: 3, threshold: AIConfig().peakThreshold), 21)
    }
}

// MARK: - Timing

final class NudgeTimingTests: XCTestCase {
    func testLateNightBelongsToPreviousEvening() {
        let saturday0030 = date(2026, 10, 31, 0, 30)
        let slot = BehavioralDay.slot(for: saturday0030, calendar: utc)
        XCTAssertEqual(slot.weekday, 6) // Friday night
        XCTAssertEqual(slot.hour, 0)
    }

    func testMorningWindowSharesThePreviousEveningsDayNumber() {
        let friday2000 = date(2026, 10, 30, 20, 0)
        let saturday0030 = date(2026, 10, 31, 0, 30)
        XCTAssertEqual(BehavioralDay.behavioralDayNumber(for: friday2000, calendar: utc),
                       BehavioralDay.behavioralDayNumber(for: saturday0030, calendar: utc))
    }

    func testDaytimeStaysOnItsOwnDay() {
        let saturday1400 = date(2026, 10, 31, 14, 0)
        XCTAssertEqual(BehavioralDay.slot(for: saturday1400, calendar: utc).weekday, 7)
    }

    func testFireTimeOrdinaryEvening() {
        let fire = NudgePlanner.fireTime(weekday: 6, peakMinute: 21 * 60, leadMinutes: 15)
        XCTAssertEqual(fire.weekday, 6)
        XCTAssertEqual(fire.minute, 20 * 60 + 45)
    }

    func testFireTimeBeforeMidnightPeakFiresPreviousEvening() {
        // Friday-night peak at 00:05 (calendar Saturday) with a 15-min lead → Friday 23:50.
        let fire = NudgePlanner.fireTime(weekday: 6, peakMinute: 5, leadMinutes: 15)
        XCTAssertEqual(fire.weekday, 6)
        XCTAssertEqual(fire.minute, 23 * 60 + 50)
    }

    func testFireTimeAfterMidnightMovesToNextCalendarDay() {
        // Saturday-night peak at 00:40 (calendar Sunday) with a 10-min lead → Sunday 00:30.
        let fire = NudgePlanner.fireTime(weekday: 7, peakMinute: 40, leadMinutes: 10)
        XCTAssertEqual(fire.weekday, 1)
        XCTAssertEqual(fire.minute, 30)
    }

    func testPeakTimingFindsTheCluster() {
        let samples = [21 * 60 + 30, 21 * 60 + 35, 21 * 60 + 40, 21 * 60 + 35, 21 * 60 + 30, 21 * 60 + 40]
        let minute = PeakTiming.minute(near: 21, samples: samples)
        XCTAssertEqual(Double(minute), Double(21 * 60 + 35), accuracy: 10)
    }

    func testPeakTimingFallsBackToTopOfHour() {
        XCTAssertEqual(PeakTiming.minute(near: 21, samples: [21 * 60 + 30]), 21 * 60)
    }

    func testPlanSkipsWeekdaysWithoutAHabit() {
        var m = HabitModel()
        for d in 0..<4 {
            let day = 20_000 + d * 7
            m.observe(weekday: 6, hours: BehavioralDay.coverageHours, day: day)
            m.recordHit(weekday: 6, hour: 21, day: day)
            m.observe(weekday: 3, hours: BehavioralDay.coverageHours, day: day + 4)
        }
        let plans = NudgePlanner.plan(model: m, samples: [], sampleWeekdays: nil, config: AIConfig(), leadMinutes: 15)
        XCTAssertTrue(plans.contains { $0.weekday == 6 && $0.peakMinute / 60 == 21 })
        XCTAssertFalse(plans.contains { $0.weekday == 3 })
    }
}

// MARK: - Bandit

final class LeadBanditTests: XCTestCase {
    func testLearnsTheArmThatGetsAccepted() {
        var bandit = LeadBandit()
        for _ in 0..<20 {
            bandit.record(leadMinutes: 10, accepted: true)
            for other in LeadBandit.arms where other != 10 {
                bandit.record(leadMinutes: other, accepted: false)
            }
        }
        XCTAssertEqual(bandit.bestMeanArm, 10)
        var rng = SplitMix64(state: 42)
        let picks = (0..<200).map { _ in bandit.sample(using: &rng) }
        XCTAssertGreaterThan(picks.filter { $0 == 10 }.count, 180)
    }

    func testUntrainedBanditExplores() {
        let bandit = LeadBandit()
        var rng = SplitMix64(state: 7)
        let picks = Set((0..<300).map { _ in bandit.sample(using: &rng) })
        XCTAssertEqual(picks, Set(LeadBandit.arms))
        XCTAssertEqual(bandit.trials, 0)
    }

    func testUnknownArmIsIgnored() {
        var bandit = LeadBandit()
        bandit.record(leadMinutes: 7, accepted: true)
        XCTAssertEqual(bandit.trials, 0)
    }

    func testBetaSamplerMean() {
        var rng = SplitMix64(state: 1)
        let n = 4000
        let mean = (0..<n).map { _ in BetaSampler.sample(alpha: 2, beta: 6, using: &rng) }.reduce(0, +) / Double(n)
        XCTAssertEqual(mean, 0.25, accuracy: 0.02)
    }

    func testGammaHandlesSmallShape() {
        var rng = SplitMix64(state: 3)
        for _ in 0..<500 {
            let g = BetaSampler.gamma(shape: 0.3, using: &rng)
            XCTAssertTrue(g.isFinite && g >= 0)
        }
    }
}

// MARK: - UI formatting

final class UIFormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(UIFormat.duration(900), "15m")
        XCTAssertEqual(UIFormat.duration(3600), "1h")
        XCTAssertEqual(UIFormat.duration(5400), "1h 30m")
        XCTAssertEqual(UIFormat.duration(2 * 86_400 + 3 * 3600), "2d 3h")
        XCTAssertEqual(UIFormat.duration(86_400), "1d")
    }
}

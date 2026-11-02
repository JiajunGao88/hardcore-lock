//
//  HabitModel.swift
//  Hardcord Lock App
//
//  SHARED with the DeviceActivityManager extension. Pure Foundation, so it runs
//  inside the extension's ~6MB budget and is fully unit-testable.
//
//  What the model can see: Apple sandboxes Screen Time usage, so neither the app
//  nor any model (on-device or cloud) can read per-app minutes. The only signal
//  is the monitor extension's threshold event — "the watched apps passed N
//  minutes inside this window" — plus how the user answers our nudges.
//  Given that signal, this is the statistically sound approach:
//
//   1. WHEN — a hierarchical Beta-Binomial model per (weekday × hour). Each cell
//      is shrunk toward the pooled all-days estimate for that hour, so a new user
//      gets a sensible estimate on day 3 and weekday/weekend differences emerge
//      as evidence accumulates. Counts decay with a 21-day half-life, so a habit
//      that changes is forgotten instead of haunting the nudges forever. Peaks
//      are chosen on the posterior LOWER bound, so three noisy samples can't
//      fabricate a "habit".
//   2. HOW EARLY — a Thompson-sampling bandit over nudge lead times, rewarded
//      when the user taps LOCK NOW and penalised when they dismiss.
//

import Foundation

// MARK: - Behavioral day

/// Late-night use belongs to the evening it started in: 00:30 on Saturday is
/// Friday night's habit. Hours before `AIConfig.coverageStartHour` are therefore
/// attributed to the previous weekday.
enum BehavioralDay {
    /// (weekday 1…7, clock hour 0…23) the moment `date` is attributed to.
    static func slot(for date: Date, calendar: Calendar = .current) -> (weekday: Int, hour: Int) {
        let c = calendar.dateComponents([.weekday, .hour], from: date)
        let weekday = c.weekday ?? 1
        let hour = c.hour ?? 0
        return (hour < AIConfig.coverageStartHour ? previous(weekday) : weekday, hour)
    }

    static func previous(_ weekday: Int) -> Int { (weekday + 5) % 7 + 1 }
    static func next(_ weekday: Int) -> Int { weekday % 7 + 1 }

    /// Days since the epoch in the user's calendar — the unit decay is measured in.
    static func dayNumber(for date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let local = start.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: start))
        return Int((local / 86_400).rounded())
    }

    /// Day number of the BEHAVIORAL day — the one `slot(for:)` attributes to.
    /// Exposures and hits must be keyed by this, not the calendar day: keyed by
    /// the calendar day, Friday's 07:00 window and Saturday's 00:00 window (both
    /// "Friday" behaviorally) each counted a separate Friday exposure.
    static func behavioralDayNumber(for date: Date, calendar: Calendar = .current) -> Int {
        let hour = calendar.component(.hour, from: date)
        let anchor = hour < AIConfig.coverageStartHour
            ? (calendar.date(byAdding: .day, value: -1, to: date) ?? date)
            : date
        return dayNumber(for: anchor, calendar: calendar)
    }

    /// Clock hours the AI coverage monitors, in behavioral order (07…23, 0…1).
    static var coverageHours: [Int] {
        (AIConfig.coverageStartHour..<AIConfig.coverageEndHour).map { $0 % 24 }
    }
}

// MARK: - Posterior

struct SlotEstimate: Equatable {
    /// Posterior mean probability of heavy use in this hour on this weekday.
    var mean: Double
    /// ~10th-percentile of the posterior (normal approximation). Decisions use this.
    var lower: Double
    /// Effective (decayed) number of observed days behind the estimate.
    var evidence: Double
}

// MARK: - Hierarchical Beta-Binomial model

struct HabitModel: Codable, Equatable {
    static let cells = 7 * 24
    /// Base-rate prior for the pooled estimate: Beta(1, 4) ≈ "20% of days".
    static let priorAlpha = 1.0
    static let priorBeta = 4.0
    /// How strongly a weekday cell is pulled toward the pooled hour estimate,
    /// in pseudo-days. Small: a few real days of a weekday override it.
    static let shrinkage = 4.0
    static let halfLifeDays = 21.0
    /// z for the 10th percentile.
    static let lowerZ = 1.2816

    /// Decayed count of days that had a heavy-use hit in the cell.
    var hits: [Double]
    /// Decayed count of days the cell was observed.
    var exposures: [Double]
    /// Day number each cell last recorded a hit (dedups re-fired thresholds).
    var lastHitDay: [Int]
    /// Day number the cell last recorded an exposure.
    var lastExposureDay: [Int]
    /// Day number decay was last applied up to.
    var decayedThrough: Int

    init() {
        hits = Array(repeating: 0, count: Self.cells)
        exposures = Array(repeating: 0, count: Self.cells)
        lastHitDay = Array(repeating: -1, count: Self.cells)
        lastExposureDay = Array(repeating: -1, count: Self.cells)
        decayedThrough = -1
    }

    static func index(weekday: Int, hour: Int) -> Int {
        (min(max(weekday, 1), 7) - 1) * 24 + min(max(hour, 0), 23)
    }

    var isEmpty: Bool { exposures.allSatisfy { $0 == 0 } }

    // MARK: Updates

    /// Multiply every count by the decay owed since the last update.
    mutating func decay(to day: Int) {
        guard decayedThrough >= 0 else { decayedThrough = day; return }
        let elapsed = day - decayedThrough
        guard elapsed > 0 else { return }
        let factor = pow(0.5, Double(elapsed) / Self.halfLifeDays)
        for i in 0..<Self.cells {
            hits[i] *= factor
            exposures[i] *= factor
        }
        decayedThrough = day
    }

    /// One observed behavioral day: every covered hour of `weekday` was watched.
    mutating func observe(weekday: Int, hours: [Int], day: Int) {
        decay(to: day)
        for hour in hours {
            let i = Self.index(weekday: weekday, hour: hour)
            guard lastExposureDay[i] != day else { continue }
            lastExposureDay[i] = day
            exposures[i] += 1
        }
    }

    /// A heavy-use hit. At most one per cell per day, and a hit always implies
    /// the cell was observed that day (so hits can never exceed exposures).
    mutating func recordHit(weekday: Int, hour: Int, day: Int) {
        decay(to: day)
        let i = Self.index(weekday: weekday, hour: hour)
        if lastExposureDay[i] != day {
            lastExposureDay[i] = day
            exposures[i] += 1
        }
        guard lastHitDay[i] != day else { return }
        lastHitDay[i] = day
        hits[i] += 1
    }

    // MARK: Inference

    /// Pooled (all weekdays) posterior mean for one hour — the shrinkage target.
    func pooledMean(hour: Int) -> Double {
        var h = 0.0, n = 0.0
        for weekday in 1...7 {
            let i = Self.index(weekday: weekday, hour: hour)
            h += hits[i]
            n += exposures[i]
        }
        let a = Self.priorAlpha + h
        let b = Self.priorBeta + max(0, n - h)
        return a / (a + b)
    }

    func estimate(weekday: Int, hour: Int) -> SlotEstimate {
        let i = Self.index(weekday: weekday, hour: hour)
        let p = pooledMean(hour: hour)
        let a = Self.shrinkage * p + hits[i]
        let b = Self.shrinkage * (1 - p) + max(0, exposures[i] - hits[i])
        let n = a + b
        let mean = a / n
        let sd = (a * b / (n * n * (n + 1))).squareRoot()
        return SlotEstimate(mean: mean, lower: max(0, mean - Self.lowerZ * sd), evidence: exposures[i])
    }

    /// The hour (clock 0…23) this weekday most reliably over-uses, or nil when no
    /// hour clears `threshold` on its posterior lower bound.
    func peakHour(weekday: Int, threshold: Double) -> Int? {
        var best: (hour: Int, lower: Double)?
        for hour in BehavioralDay.coverageHours {
            let e = estimate(weekday: weekday, hour: hour)
            guard e.lower >= threshold else { continue }
            if best == nil || e.lower > best!.lower { best = (hour, e.lower) }
        }
        return best?.hour
    }

    /// Bootstrap from v3's flat timestamp list (no weekday was recorded then),
    /// spreading each hit and each observed day evenly over the week.
    static func migrated(from stats: AIStats, day: Int) -> HabitModel {
        var model = HabitModel()
        model.decayedThrough = day
        guard stats.daysObserved > 0 else { return model }
        let perWeekdayDays = Double(stats.daysObserved) / 7
        var hourHits = Array(repeating: 0.0, count: 24)
        for m in stats.hitMinutes { hourHits[(m / 60) % 24] += 1 }
        for weekday in 1...7 {
            for hour in BehavioralDay.coverageHours {
                let i = index(weekday: weekday, hour: hour)
                model.exposures[i] = perWeekdayDays
                model.hits[i] = min(perWeekdayDays, hourHits[hour] / 7)
            }
        }
        return model
    }
}

// MARK: - Fine timing within the peak hour

enum PeakTiming {
    /// The minute (0…1439) inside the ±90-minute neighbourhood of `hour` where the
    /// recorded hit timestamps concentrate, via a triangular kernel. Falls back to
    /// the top of the hour when there are too few nearby samples.
    static func minute(near hour: Int, samples: [Int], minSamples: Int = AIConfig.minPeakSamples) -> Int {
        let centre = AIConfig.linearPosition(hour * 60) + 30
        let lin = samples.map(AIConfig.linearPosition).filter { abs($0 - centre) <= 90 }
        guard lin.count >= minSamples else { return hour * 60 }
        let h = Double(AIConfig.peakKernelHalfWidth)
        var bestPos = centre - 30, bestScore = -1.0
        var p = centre - 90
        while p <= centre + 90 {
            var score = 0.0
            for s in lin {
                let d = abs(Double(s - p))
                if d < h { score += 1 - d / h }
            }
            if score > bestScore { bestScore = score; bestPos = p }
            p += AIConfig.binMinutes
        }
        return ((bestPos % 1440) + 1440) % 1440
    }
}

// MARK: - Weekly nudge plan

struct NudgePlan: Equatable {
    /// Behavioral weekday the habit belongs to.
    var weekday: Int
    var peakMinute: Int
    var probability: Double
    /// When the notification fires: calendar weekday + minute of day.
    var fireWeekday: Int
    var fireMinute: Int
}

enum NudgePlanner {
    /// Peak minute on the behavioral day (may be 24:xx for after-midnight peaks)
    /// minus the lead, converted back to a calendar weekday + minute. Handles a
    /// lead that crosses midnight in either direction.
    static func fireTime(weekday: Int, peakMinute: Int, leadMinutes: Int) -> (weekday: Int, minute: Int) {
        let linear = AIConfig.linearPosition(peakMinute) - leadMinutes
        let dayShift = Int((Double(linear) / 1440).rounded(.down))
        var w = weekday
        if dayShift > 0 { for _ in 0..<dayShift { w = BehavioralDay.next(w) } }
        if dayShift < 0 { for _ in 0..<(-dayShift) { w = BehavioralDay.previous(w) } }
        return (w, ((linear % 1440) + 1440) % 1440)
    }

    static func plan(model: HabitModel, samples: [Int], sampleWeekdays: [Int]?,
                     config: AIConfig, leadMinutes: Int) -> [NudgePlan] {
        (1...7).compactMap { weekday in
            guard let hour = model.peakHour(weekday: weekday, threshold: config.peakThreshold) else { return nil }
            // Prefer this weekday's own timestamps; v3 data has no weekday, so
            // fall back to every sample.
            var own = samples
            if let wds = sampleWeekdays, wds.count == samples.count {
                own = zip(samples, wds).filter { $0.1 == weekday }.map { $0.0 }
            }
            let minute = own.count >= AIConfig.minPeakSamples
                ? PeakTiming.minute(near: hour, samples: own)
                : PeakTiming.minute(near: hour, samples: samples)
            let fire = fireTime(weekday: weekday, peakMinute: minute, leadMinutes: leadMinutes)
            return NudgePlan(weekday: weekday, peakMinute: minute,
                             probability: model.estimate(weekday: weekday, hour: hour).mean,
                             fireWeekday: fire.weekday, fireMinute: fire.minute)
        }
    }
}

// MARK: - Thompson-sampling bandit for nudge lead time

struct LeadBandit: Codable, Equatable {
    static let arms = [5, 10, 15, 20, 30]

    /// Beta(1, 1) prior per arm.
    var successes: [Double] = Array(repeating: 1, count: LeadBandit.arms.count)
    var failures: [Double] = Array(repeating: 1, count: LeadBandit.arms.count)

    mutating func record(leadMinutes: Int, accepted: Bool) {
        guard let i = Self.arms.firstIndex(of: leadMinutes) else { return }
        if accepted { successes[i] += 1 } else { failures[i] += 1 }
    }

    func acceptRate(_ i: Int) -> Double { successes[i] / (successes[i] + failures[i]) }

    /// Number of real outcomes recorded (excluding the prior).
    var trials: Int { Int((successes + failures).reduce(0, +)) - 2 * Self.arms.count }

    /// Thompson sampling: draw from every arm's posterior, play the best draw.
    func sample<G: RandomNumberGenerator>(using rng: inout G) -> Int {
        var bestArm = Self.arms[0], bestDraw = -1.0
        for (i, arm) in Self.arms.enumerated() {
            let draw = BetaSampler.sample(alpha: successes[i], beta: failures[i], using: &rng)
            if draw > bestDraw { bestDraw = draw; bestArm = arm }
        }
        return bestArm
    }

    var bestMeanArm: Int {
        let i = Self.arms.indices.max { acceptRate($0) < acceptRate($1) } ?? 0
        return Self.arms[i]
    }
}

enum BetaSampler {
    static func sample<G: RandomNumberGenerator>(alpha: Double, beta: Double, using rng: inout G) -> Double {
        let x = gamma(shape: alpha, using: &rng)
        let y = gamma(shape: beta, using: &rng)
        return x + y > 0 ? x / (x + y) : 0.5
    }

    /// Marsaglia–Tsang; shape < 1 uses the U^(1/a) boost.
    static func gamma<G: RandomNumberGenerator>(shape: Double, using rng: inout G) -> Double {
        if shape < 1 {
            let u = Double.random(in: Double.ulpOfOne..<1, using: &rng)
            return gamma(shape: shape + 1, using: &rng) * pow(u, 1 / shape)
        }
        let d = shape - 1.0 / 3.0
        let c = 1 / (9 * d).squareRoot()
        // Acceptance rate is >95% for every shape; the cap only bounds the loop.
        for _ in 0..<1_000 {
            var x: Double, v: Double
            repeat {
                x = normal(using: &rng)
                v = 1 + c * x
            } while v <= 0
            v = v * v * v
            let u = Double.random(in: Double.ulpOfOne..<1, using: &rng)
            if u < 1 - 0.0331 * x * x * x * x { return d * v }
            if log(u) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v }
        }
        return d
    }

    /// Box–Muller.
    static func normal<G: RandomNumberGenerator>(using rng: inout G) -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &rng)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

// MARK: - Persistence

enum HabitModelStore {
    static func load() -> HabitModel? {
        guard let data = AppGroup.defaults.data(forKey: StoreKeys.aiModel) else { return nil }
        return try? JSONDecoder().decode(HabitModel.self, from: data)
    }

    /// The model, bootstrapping from v3 stats on first use.
    static func loadOrMigrate(now: Date = Date()) -> HabitModel {
        if let model = load() { return model }
        let model = HabitModel.migrated(from: AIStatsStore.load(), day: BehavioralDay.dayNumber(for: now))
        save(model)
        return model
    }

    static func save(_ model: HabitModel) {
        if let data = try? JSONEncoder().encode(model) {
            AppGroup.defaults.set(data, forKey: StoreKeys.aiModel)
        }
    }

    static func reset() {
        AppGroup.defaults.removeObject(forKey: StoreKeys.aiModel)
    }
}

enum LeadBanditStore {
    static func load() -> LeadBandit {
        guard let data = AppGroup.defaults.data(forKey: StoreKeys.leadBandit),
              let bandit = try? JSONDecoder().decode(LeadBandit.self, from: data) else { return LeadBandit() }
        return bandit
    }

    static func save(_ bandit: LeadBandit) {
        if let data = try? JSONEncoder().encode(bandit) {
            AppGroup.defaults.set(data, forKey: StoreKeys.leadBandit)
        }
    }

    static func record(leadMinutes: Int, accepted: Bool) {
        var bandit = load()
        bandit.record(leadMinutes: leadMinutes, accepted: accepted)
        save(bandit)
    }

    /// The lead to use today. Sampled once per day and pinned, so the many
    /// reschedules in a day don't flicker the nudge time around.
    static func todaysLead(config: AIConfig, now: Date = Date()) -> Int {
        guard config.adaptiveLead else { return config.leadMinutes }
        let today = AIStatsStore.dayKey(for: now)
        if let pinned = AppGroup.defaults.string(forKey: StoreKeys.leadChoice) {
            let parts = pinned.split(separator: "|")
            if parts.count == 2, parts[0] == today, let lead = Int(parts[1]) { return lead }
        }
        var rng = SystemRandomNumberGenerator()
        let lead = load().sample(using: &rng)
        AppGroup.defaults.set("\(today)|\(lead)", forKey: StoreKeys.leadChoice)
        return lead
    }
}

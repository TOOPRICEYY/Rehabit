import Foundation

extension MetricName {
    /// A day's mean heart-rate weight of its steps (`StepWeighting`). The ledger
    /// multiplies the day's step count by it; with none the steps count at 1.
    public static let stepHRWeight = "step_hr_weight"
}

/// A count or a rate over a stretch of time: steps in a few minutes, or the
/// heart rate measured then (a single reading has the same start and end).
public struct IntervalSample: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var value: Double
    public init(start: Date, end: Date, value: Double) { self.start = start; self.end = end; self.value = value }

    var minutes: Double { max(end.timeIntervalSince(start), 60) / 60 }
}

public struct StepWeightSettings: Sendable {
    public var minWeight = 0.3
    public var maxWeight = 4.0
    /// Steps a minute that make a sample "walking", for the person's walking heart rate.
    public var walkingCadence = 60.0
    /// Walking heart rate above resting when there are no walking samples to learn it from.
    public var defaultWalkingAboveResting = 30.0
    /// The walking rate must be at least this far above resting, or the weights blow up.
    public var minWalkingAboveResting = 10.0
    /// A heart-rate reading this close to a step sample counts for it when none overlaps.
    public var nearbySeconds: TimeInterval = 5 * 60
    public init() {}
}

/// Steps weighted by the heart rate they were taken at:
///
///     weight = (HR - resting HR) / (walking HR - resting HR), kept between 0.3 and 4
///
/// so a step at the person's ordinary walking heart rate counts as 1, a stroll
/// less, and a hill or a court more. Resting is the day's usual resting rate
/// (the 28-day median); walking is the median heart rate of the person's own
/// walking samples (60 or more steps a minute) over the 28 days up to the day.
/// Steps inside an excluded window (a recorded workout: lifting raises heart
/// rate without steps, and an activity has its own load) and steps with no heart
/// rate count at 1. Heart rate also rises with heat, stress or a poor night, so
/// this describes effort, not measured force. The values are starting settings.
public enum StepWeighting {
    /// Each day's mean weight of its steps, Σ steps × weight / Σ steps.
    public static func dayWeights(steps: [IntervalSample], heartRate: [IntervalSample], excluded: [DateInterval],
                                  restingHR: [Day: Double], zone: TimeZone,
                                  settings: StepWeightSettings = StepWeightSettings()) -> [Day: Double] {
        let beats = heartRate.filter { $0.value.isFinite && $0.value > 20 && $0.value < 260 && $0.end >= $0.start }
            .sorted { $0.start < $1.start }
        let samples = steps.filter { $0.value.isFinite && $0.value > 0 && $0.end >= $0.start }
        // The heart rate of each step sample, nil when there is none or it is excluded.
        var rated: [(sample: IntervalSample, day: Day, hr: Double?)] = []
        for s in samples {
            let mid = s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2)
            let day = Day(mid, in: zone)
            if excluded.contains(where: { $0.contains(mid) }) {
                rated.append((s, day, nil)); continue
            }
            rated.append((s, day, StepWeighting.heartRate(during: s, in: beats, settings: settings)))
        }
        // The person's walking heart rate by day, from their own walking samples.
        var walkingByDay: [Day: [Double]] = [:]
        for r in rated where r.hr != nil && r.sample.value / r.sample.minutes >= settings.walkingCadence {
            walkingByDay[r.day, default: []].append(r.hr!)
        }
        var sums: [Day: (weighted: Double, total: Double)] = [:]
        var walkingCache: [Day: Double?] = [:]
        for r in rated {
            var weight = 1.0
            if let hr = r.hr, let rest = Ledger.usualRestingHR(restingHR, on: r.day) {
                let walking: Double? = walkingCache[r.day] ?? {
                    let values = (0...28).flatMap { walkingByDay[r.day.adding(-$0)] ?? [] }
                    let w = values.isEmpty ? nil : Ledger.median(values)
                    walkingCache[r.day] = w
                    return w
                }()
                var walk = walking ?? rest + settings.defaultWalkingAboveResting
                if walk - rest < settings.minWalkingAboveResting { walk = rest + settings.minWalkingAboveResting }
                weight = min(settings.maxWeight, max(settings.minWeight, (hr - rest) / (walk - rest)))
            }
            var cell = sums[r.day] ?? (0, 0)
            cell.weighted += r.sample.value * weight
            cell.total += r.sample.value
            sums[r.day] = cell
        }
        return sums.compactMapValues { $0.total > 0 ? $0.weighted / $0.total : nil }
    }

    /// The time-weighted mean of the readings that overlap a sample, else the
    /// nearest reading within a few minutes, else nil.
    static func heartRate(during s: IntervalSample, in beats: [IntervalSample], settings: StepWeightSettings) -> Double? {
        var weighted = 0.0, span = 0.0
        var nearest: (gap: TimeInterval, value: Double)?
        for b in beats {
            if b.start > s.end.addingTimeInterval(settings.nearbySeconds) { break }
            let overlap = min(s.end, b.end).timeIntervalSince(max(s.start, b.start))
            // A stretch that only touches the sample's edge is not during it; a single reading inside is.
            if overlap > 0 || (b.start == b.end && b.start >= s.start && b.start <= s.end) {
                let w = max(overlap, 1)
                weighted += b.value * w; span += w
            } else {
                let gap = b.end < s.start ? s.start.timeIntervalSince(b.end) : b.start.timeIntervalSince(s.end)
                if gap <= settings.nearbySeconds, nearest == nil || gap < nearest!.gap { nearest = (gap, b.value) }
            }
        }
        if span > 0 { return weighted / span }
        return nearest?.value
    }
}

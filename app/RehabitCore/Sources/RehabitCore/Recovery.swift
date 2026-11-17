import Foundation

/// One recovery measure this week against the person's own previous four
/// weeks. It says where the week sits in their own range; it does not say
/// what that means for training, which nothing in this record has shown.
public struct RecoveryReading: Identifiable, Equatable, Sendable {
    public let metric: String
    /// The device the values came from. HRV from two devices is two measures and is never mixed.
    public let source: String
    /// The most recent value and its day.
    public let latest: Double
    public let latestDay: Day
    /// Mean of the last 7 days and of the 28 days before them, with how many days had a value.
    public let recentMean: Double
    public let recentDays: Int
    public let usualMean: Double
    public let usualDays: Int
    /// The middle 80 percent of the values in those 28 days: the usual range.
    public let usualLow: Double
    public let usualHigh: Double
    /// How many of the 28 days' values the recent mean is above.
    public let daysBelow: Int
    public var id: String { metric + "|" + source }

    /// The recent mean against the usual one.
    public var ratio: Double? { usualMean > 0 ? recentMean / usualMean : nil }
    /// True when the recent mean is outside the middle 80 percent of the usual days.
    public var isOutsideUsual: Bool { recentMean < usualLow || recentMean > usualHigh }

    public var name: String {
        switch metric {
        case MetricName.hrv: return "Overnight HRV"
        case MetricName.hrvSDNN: return "HRV (Apple Health)"
        case MetricName.restingHeartRate: return "Resting heart rate"
        case MetricName.sleepMinutes: return "Sleep"
        case MetricName.steps: return "Steps"
        default: return metric
        }
    }

    /// A value of this measure as it is read: "52 ms", "7 h 10 min", "8,400".
    public func text(_ value: Double) -> String {
        switch metric {
        case MetricName.hrv, MetricName.hrvSDNN: return "\(Int(value.rounded())) ms"
        case MetricName.restingHeartRate: return "\(Int(value.rounded())) bpm"
        case MetricName.sleepMinutes:
            let minutes = Int(value.rounded())
            return "\(minutes / 60) h \(minutes % 60) min"
        default:
            let whole = Int(value.rounded())
            return whole >= 1000 ? "\(whole / 1000),\(String(format: "%03d", whole % 1000))" : String(whole)
        }
    }

    /// The reading in a sentence, with the counts behind it.
    public var sentence: String {
        var text = "\(name): \(self.text(recentMean)) over the last 7 days (\(recentDays) with a value), "
        text += "\(self.text(usualMean)) over the 28 days before (\(usualDays)). "
        if daysBelow == usualDays { text += "Higher than every one of those days." }
        else if daysBelow == 0 { text += "Lower than every one of those days." }
        else { text += "Higher than \(daysBelow) of those \(usualDays) days." }
        return text
    }
}

extension AppModel {
    /// Days with a value needed in the last 7 and in the 28 before, as the service asks.
    static let recoveryRecentMin = 4
    static let recoveryUsualMin = 14

    /// Each recovery measure with enough history, for the week ending on a
    /// day (today if none is given): HRV, resting heart rate, sleep and
    /// steps. A measure with too few days says nothing and is left out.
    public func recoveryReadings(on day: Day? = nil) -> [RecoveryReading] {
        _ = tick; _ = revision
        let end = day ?? Day(clock, in: localZone)
        var out: [RecoveryReading] = []
        for metric in [MetricName.hrv, MetricName.hrvSDNN, MetricName.restingHeartRate, MetricName.sleepMinutes, MetricName.steps] {
            let all = dailyMetrics(metric).filter { $0.value.isFinite && $0.value > 0 && $0.day <= end && end.days(since: $0.day) < 35 }
            guard !all.isEmpty else { continue }
            var series: [Day: Double] = [:]
            var source = "all"
            if metric == MetricName.steps {
                // Phone and watch count the same walking: the larger reading of each day.
                for m in all { series[m.day] = max(series[m.day] ?? 0, m.value) }
            } else {
                // One device, the one with the most days: two devices measure differently.
                let bySource = Dictionary(grouping: all, by: \.source)
                guard let best = bySource.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) else { continue }
                source = best.key
                for m in best.value { series[m.day] = m.value }
            }
            let recent = (0..<7).compactMap { series[end.adding(-$0)] }
            let usual = (7..<35).compactMap { series[end.adding(-$0)] }.sorted()
            guard recent.count >= AppModel.recoveryRecentMin, usual.count >= AppModel.recoveryUsualMin,
                  let latestDay = series.keys.max(), let latest = series[latestDay] else { continue }
            let mean = recent.reduce(0, +) / Double(recent.count)
            func quantile(_ q: Double) -> Double {
                let at = q * Double(usual.count - 1), low = Int(at.rounded(.down)), high = min(usual.count - 1, low + 1)
                return usual[low] + (usual[high] - usual[low]) * (at - Double(low))
            }
            out.append(RecoveryReading(
                metric: metric, source: source, latest: latest, latestDay: latestDay, recentMean: mean,
                recentDays: recent.count, usualMean: usual.reduce(0, +) / Double(usual.count), usualDays: usual.count,
                usualLow: quantile(0.1), usualHigh: quantile(0.9), daysBelow: usual.filter { $0 < mean }.count))
        }
        return out
    }

    /// This week's load on each injured tissue and side against its usual week.
    public func injuredTissueWeeks() -> [TissueWeek] {
        let injured = injuredTissueSides
        return tissueWeeks().filter { injured[$0.tissue.id]?.contains($0.side) ?? false }
    }
}

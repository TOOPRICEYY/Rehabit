import Foundation
import HealthKit
import RehabitCore

/// Apple Health as a source of nightly and daily values. Read-only.
struct HealthKitSource: HealthSource {
    let name = "apple_health"
    private let store = HKHealthStore()

    private var quantities: [(HKQuantityTypeIdentifier, String, HKStatisticsOptions, HKUnit)] {
        [(.stepCount, MetricName.steps, .cumulativeSum, .count()),
         (.restingHeartRate, MetricName.restingHeartRate, .discreteAverage, HKUnit.count().unitDivided(by: .minute())),
         (.heartRateVariabilitySDNN, MetricName.hrvSDNN, .discreteAverage, .secondUnit(with: .milli))]
    }

    func requestAccess() async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        var types: Set<HKObjectType> = [HKCategoryType(.sleepAnalysis)]
        for (identifier, _, _, _) in quantities { types.insert(HKQuantityType(identifier)) }
        try await store.requestAuthorization(toShare: [], read: types)
        return true
    }

    func dailyMetrics(from: Day, through: Day) async throws -> [DailyMetric] {
        let calendar = Calendar.current
        let start = from.start()
        let end = through.adding(1).start()
        let range = HKQuery.predicateForSamples(withStart: start, end: end)
        var out: [DailyMetric] = []

        for (identifier, metric, options, unit) in quantities {
            let descriptor = HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(identifier), predicate: range),
                options: options, anchorDate: calendar.startOfDay(for: start),
                intervalComponents: DateComponents(day: 1))
            let collection = try await descriptor.result(for: store)
            collection.enumerateStatistics(from: start, to: end) { statistics, _ in
                let quantity = options == .cumulativeSum ? statistics.sumQuantity() : statistics.averageQuantity()
                // No samples that day means no value. It is not stored as zero.
                guard let value = quantity?.doubleValue(for: unit), value > 0 else { return }
                out.append(DailyMetric(day: Day(statistics.startDate), metric: metric, value: value, source: name))
            }
        }

        // Sleep: minutes asleep, filed under the day the sleep ended on.
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue]
        let sleepQuery = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: range)],
            sortDescriptors: [SortDescriptor(\.endDate)])
        var minutes: [Day: Double] = [:]
        for sample in try await sleepQuery.result(for: store) where asleep.contains(sample.value) {
            minutes[Day(sample.endDate), default: 0] += sample.endDate.timeIntervalSince(sample.startDate) / 60
        }
        for (day, total) in minutes where total > 0 {
            out.append(DailyMetric(day: day, metric: MetricName.sleepMinutes, value: total.rounded(), source: name))
        }
        return out
    }
}

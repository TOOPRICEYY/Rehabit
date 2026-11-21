import Foundation
import HealthKit
import RehabitCore

/// Sessions from Apple Health: workouts recorded by an Apple Watch or another
/// app (pickleball, tennis, a walk), and the steps and heart rate inside any
/// window, for a session logged by hand. Read-only.
extension HealthKitSource {
    /// What reading workouts and heart rate needs on top of the daily values.
    static var activityTypes: Set<HKObjectType> { [HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.stepCount)] }

    /// True when Apple would still show its permission sheet for these types:
    /// then nothing is read until the person taps to connect.
    func needsPermission(for types: Set<HKObjectType>) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: types)
        return status != .unnecessary
    }

    func requestActivityAccess() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.activityTypes)
    }

    /// Steps, average and highest heart rate between two times. Nil values: nothing recorded.
    func window(from start: Date, to end: Date) async -> (steps: Double?, averageHR: Double?, maxHR: Double?) {
        let range = HKQuery.predicateForSamples(withStart: start, end: end)
        func stat(_ id: HKQuantityTypeIdentifier, _ options: HKStatisticsOptions) async -> HKStatistics? {
            let d = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(id), predicate: range), options: options)
            return try? await d.result(for: store)
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let steps = await stat(.stepCount, .cumulativeSum)?.sumQuantity()?.doubleValue(for: .count())
        let hr = await stat(.heartRate, [.discreteAverage, .discreteMax])
        return (steps.flatMap { $0 > 0 ? $0 : nil }, hr?.averageQuantity()?.doubleValue(for: bpm), hr?.maximumQuantity()?.doubleValue(for: bpm))
    }

    /// Workouts recorded in Apple Health in a range of days, as sessions with no
    /// sets. Strength workouts are left out (they have no sets here to give),
    /// and so are workouts Garmin Connect copied into Health: Garmin's own come in from Garmin.
    func workouts(from: Day, through: Day) async throws -> [ImportedWorkout] {
        let range = HKQuery.predicateForSamples(withStart: from.start(), end: through.adding(1).start())
        let query = HKSampleQueryDescriptor(predicates: [.workout(range)], sortDescriptors: [SortDescriptor(\.startDate)])
        var out: [ImportedWorkout] = []
        for workout in try await query.result(for: store) {
            let bundle = workout.sourceRevision.source.bundleIdentifier.lowercased()
            if bundle.contains("garmin") { continue }
            let kind = Self.typeName(workout.workoutActivityType)
            if kind == "strength_training" { continue }
            let inside = await window(from: workout.startDate, to: workout.endDate)
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            let distance = workout.totalDistance?.doubleValue(for: .meter())
            let summary = ActivitySummary(type: kind, distanceMeters: distance, averageHeartRate: inside.averageHR,
                                          maxHeartRate: inside.maxHR, calories: energy, steps: inside.steps)
            out.append(ImportedWorkout(sourceID: workout.uuid.uuidString, title: summary.name,
                                       start: workout.startDate, end: workout.endDate, activity: summary))
        }
        return out
    }

    /// Garmin-style type keys, so the same matching rules read both.
    static func typeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .pickleball: "pickleball"
        case .tennis: "tennis"
        case .tableTennis: "table_tennis"
        case .badminton: "badminton"
        case .squash: "squash"
        case .racquetball: "racquetball"
        case .paddleSports: "paddling"
        case .running: "running"
        case .walking: "walking"
        case .hiking: "hiking"
        case .cycling: "cycling"
        case .handCycling: "hand_cycling"
        case .swimming: "swimming"
        case .rowing: "rowing"
        case .elliptical: "elliptical"
        case .stairClimbing, .stairs, .stepTraining: "stair_climbing"
        case .yoga: "yoga"
        case .pilates: "pilates"
        case .highIntensityIntervalTraining: "hiit"
        case .crossTraining, .mixedCardio: "cardio"
        case .functionalStrengthTraining, .traditionalStrengthTraining, .coreTraining: "strength_training"
        case .basketball: "basketball"
        case .soccer: "soccer"
        case .volleyball: "volleyball"
        case .golf: "golf"
        case .downhillSkiing, .crossCountrySkiing: "skiing"
        case .snowboarding: "snowboarding"
        case .dance, .cardioDance, .socialDance: "dance"
        case .flexibility, .cooldown, .preparationAndRecovery, .mindAndBody: "mobility"
        default: "other"
        }
    }
}

/// Steps weighted by the heart rate they were taken at (the core's
/// StepWeighting), from Apple Health's hourly steps and heart rate. Stored as
/// one daily value per day; the last two days are worked out again on every
/// read, since heart rate can sync late.
@MainActor
enum StepWeightRefresh {
    /// A short note of what was stored, or nil.
    static func run(_ model: AppModel, days: Int) async -> String? {
        let source = HealthKitSource()
        guard !(await source.needsPermission(for: HealthKitSource.activityTypes)) else { return nil }
        let today = Day(Date())
        // 28 days more than asked, for the usual walking heart rate.
        let from = today.adding(-(days + 28))
        // Minutes for the last two weeks, where step bursts and heart rate line up;
        // hours before that, which is plenty for the 28-day walking heart rate.
        let recent = today.adding(-13)
        guard let oldSteps = try? await source.samples(.stepCount, from: from, through: recent.adding(-1), minutes: 60),
              let oldHeart = try? await source.samples(.heartRate, from: from, through: recent.adding(-1), minutes: 60),
              let newSteps = try? await source.samples(.stepCount, from: recent, through: today, minutes: 1),
              let newHeart = try? await source.samples(.heartRate, from: recent, through: today, minutes: 1) else { return nil }
        let steps = oldSteps + newSteps, heart = oldHeart + newHeart
        let excluded = model.workouts.map { DateInterval(start: $0.start, end: max($0.start, $0.end ?? $0.start)) }
        var resting: [Day: Double] = [:]
        for m in model.dailyMetrics(MetricName.restingHeartRate) where m.value > 0 {
            resting[m.day] = min(resting[m.day] ?? .infinity, m.value)
        }
        let weights = StepWeighting.dayWeights(steps: steps, heartRate: heart, excluded: excluded,
                                               restingHR: resting, zone: .current)
        let keep = today.adding(-days)
        let rows = weights.filter { $0.key >= keep }.map {
            DailyMetric(day: $0.key, metric: MetricName.stepHRWeight, value: $0.value, source: source.name)
        }
        guard !rows.isEmpty else { return nil }
        model.saveDailyMetrics(rows)
        return "heart-rate weighting of steps for \(rows.count) days"
    }
}

extension HealthKitSource {
    /// Sums (steps) or averages (heart rate) over buckets of `minutes`, as samples for the core.
    func samples(_ id: HKQuantityTypeIdentifier, from: Day, through: Day, minutes: Int) async throws -> [IntervalSample] {
        guard from <= through else { return [] }
        let start = from.start(), end = through.adding(1).start()
        let sum = id == .stepCount
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(id), predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: sum ? .cumulativeSum : .discreteAverage, anchorDate: Calendar.current.startOfDay(for: start),
            intervalComponents: DateComponents(minute: minutes))
        let unit: HKUnit = sum ? .count() : HKUnit.count().unitDivided(by: .minute())
        var out: [IntervalSample] = []
        try await descriptor.result(for: store).enumerateStatistics(from: start, to: end) { s, _ in
            guard let v = (sum ? s.sumQuantity() : s.averageQuantity())?.doubleValue(for: unit), v > 0 else { return }
            out.append(IntervalSample(start: s.startDate, end: s.endDate, value: v))
        }
        return out
    }
}

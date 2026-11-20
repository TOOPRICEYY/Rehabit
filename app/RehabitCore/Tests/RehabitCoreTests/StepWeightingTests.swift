import XCTest
@testable import RehabitCore

/// Steps weighted by the heart rate they were taken at. Made-up samples only.
final class StepWeightingTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    lazy var noon = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: zone, year: 2026, month: 3, day: 2, hour: 12))!
    var day: Day { Day(noon, in: zone) }

    func sample(_ minute: Double, _ minutes: Double, _ value: Double) -> IntervalSample {
        IntervalSample(start: noon.addingTimeInterval(minute * 60), end: noon.addingTimeInterval((minute + minutes) * 60), value: value)
    }

    var resting: [Day: Double] { [day: 50, day.adding(-1): 50] }

    func testAStepAtWalkingRateCountsOnceAndAHarderOneMore() {
        // Ten minutes of walking at 80 (the walking rate learned from them), then ten at 110.
        let steps = [sample(0, 10, 1000), sample(10, 10, 1000)]
        let hr = [sample(0, 10, 80), sample(10, 10, 110)]
        let w = StepWeighting.dayWeights(steps: steps, heartRate: hr, excluded: [], restingHR: resting, zone: zone)
        // Walking HR is the median of the two walking samples, 95: weights 30/45 and 60/45.
        let want: Double = (30.0 / 45 + 60.0 / 45) / 2
        XCTAssertEqual(w[day] ?? 0, want, accuracy: 1e-9)
    }

    func testWeightsAreClampedAndUnknownOrExcludedStepsCountOnce() {
        let steps = [sample(0, 10, 1000), sample(10, 10, 300), sample(30, 10, 500), sample(60, 10, 800)]
        let hr = [sample(0, 10, 79), sample(10, 10, 300), sample(60, 10, 200)]   // 300 is no heart rate
        let gym = DateInterval(start: noon.addingTimeInterval(55 * 60), duration: 30 * 60)
        let w = StepWeighting.dayWeights(steps: steps, heartRate: hr, excluded: [gym], restingHR: resting, zone: zone)
        // Only the first sample is walking (100 a minute) and rated: walking HR 79, weight 1.
        // The second has no usable rate (1), the third none at all (1), the fourth is in the gym window (1).
        XCTAssertEqual(w[day] ?? 0, 1, accuracy: 1e-9)
        let hard = StepWeighting.dayWeights(steps: [sample(0, 10, 1000), sample(10, 10, 1000)],
                                            heartRate: [sample(0, 10, 80), sample(10, 10, 250)],
                                            excluded: [], restingHR: resting, zone: zone)
        // Walking HR median(80, 250) = 165; 80 gives 30/115 = 0.26, held at 0.3; 250 gives 200/115.
        let high: Double = 200.0 / 115
        XCTAssertEqual(hard[day] ?? 0, (0.3 + high) / 2, accuracy: 1e-9)
    }

    func testWithoutWalkingSamplesTheWalkingRateIsRestingPlusThirty() {
        // 30 steps a minute is not walking, so nothing to learn from: walking = 50 + 30.
        let w = StepWeighting.dayWeights(steps: [sample(0, 10, 300)], heartRate: [sample(0, 10, 110)],
                                         excluded: [], restingHR: resting, zone: zone)
        XCTAssertEqual(w[day] ?? 0, 2, accuracy: 1e-9)
        // No resting rate at all: the steps count once.
        let none = StepWeighting.dayWeights(steps: [sample(0, 10, 300)], heartRate: [sample(0, 10, 110)],
                                            excluded: [], restingHR: [:], zone: zone)
        XCTAssertEqual(none[day] ?? 0, 1, accuracy: 1e-9)
    }

    func testHourlyHeartRateCoversTheStepsInsideIt() {
        let hour = sample(0, 60, 95)
        // 20 steps a minute: not walking, so the walking rate is 50 + 30 and both weigh 45 / 30.
        let w = StepWeighting.dayWeights(steps: [sample(5, 5, 100), sample(40, 3, 60)], heartRate: [hour],
                                         excluded: [], restingHR: resting, zone: zone)
        XCTAssertEqual(w[day] ?? 0, 1.5, accuracy: 1e-9)
        // A single reading inside a sample counts; one just outside it, within five minutes, does too.
        let point = IntervalSample(start: noon.addingTimeInterval(7 * 60), end: noon.addingTimeInterval(7 * 60), value: 110)
        let near = StepWeighting.dayWeights(steps: [sample(5, 5, 100), sample(12, 2, 40)], heartRate: [point],
                                            excluded: [], restingHR: resting, zone: zone)
        XCTAssertEqual(near[day] ?? 0, 2, accuracy: 1e-9)
    }

    func testTheLedgerUsesTheWeightOnlyOnDaysWithSteps() {
        let ledger = Ledger()
        let sets = ledger.walkingSets(steps: [day: 8000, day.adding(1): 8000], weights: [day: 1.5, day.adding(5): 3])
        XCTAssertEqual(sets.first { $0.day == day }?.reps ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(sets.first { $0.day == day.adding(1) }?.reps ?? 0, 40, accuracy: 1e-9)
        var off = Ledger(); off.settings.weightStepsByHR = false
        XCTAssertEqual(off.walkingSets(steps: [day: 8000], weights: [day: 1.5]).last?.reps ?? 0, 40, accuracy: 1e-9)
    }

    func testOnFootActivitiesCountFromTheirSteps() {
        let ledger = Ledger()
        XCTAssertEqual(Library.standard.activityPerStep["pickleball"], 3)
        XCTAssertEqual(ActivityMatcher.pattern(type: "pickleball", name: nil), "pickleball")
        let game = LedgerActivity(day: day, type: "pickleball", name: "Pickleball", minutes: 120, averageHR: nil, steps: 4000)
        XCTAssertEqual(ledger.activitySets([game], restingHR: [:], maxHR: nil).first?.reps ?? 0, 40, accuracy: 1e-9)
        var noSteps = game; noSteps.steps = nil
        XCTAssertEqual(ledger.activitySets([noSteps], restingHR: [:], maxHR: nil).first?.reps ?? 0, 72, accuracy: 1e-9)
        var ride = LedgerActivity(day: day, type: "cycling", name: nil, minutes: 40, averageHR: nil, steps: 300)
        XCTAssertEqual(ledger.activitySets([ride], restingHR: [:], maxHR: nil).first?.reps ?? 0, 10, accuracy: 1e-9)
        ride.steps = .infinity
        XCTAssertEqual(ledger.activitySets([ride], restingHR: [:], maxHR: nil).first?.reps ?? 0, 10, accuracy: 1e-9)
    }
}

import XCTest
@testable import RehabitCore

/// Adversarial probes of what the app says about an injury and a load (round 2).
/// Each test failed because of a defect when it was written; the data is synthetic.
final class ReportRoundTwoRegressionTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 0)

    func at(_ text: String) -> Date { GarminClient.localTime(text + ":00", zone: zone)! }
    func model(_ store: Store? = nil) throws -> AppModel {
        AppModel(store: try store ?? Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }
    func fill(_ m: AppModel, _ set: WorkoutSet, load: Double?, reps: Double = 10) {
        var s = m.activeSets.first { $0.id == set.id } ?? set
        s.loadValue = load; s.reps = reps
        m.update(s)
    }
    /// A finished session at the clock: `rounds` rounds of an exercise on the sides given.
    func session(_ m: AppModel, _ name: String, sides: [Side], load: Double?, rounds: Int = 3) throws {
        let e = try entry(name, m)
        m.startWorkout()
        for _ in 0..<rounds { for set in m.addRound(e, sides: sides) { fill(m, set, load: load) } }
        clock.addTimeInterval(1800)
        m.finishWorkout()
        clock.addTimeInterval(-1800)
    }

    // MARK: Report

    /// An injury on both sides lists no exercise done one side at a time: the
    /// sessions are filtered to side == .both, so a bilateral patellar
    /// tendinopathy's split squats vanish and the report says "None logged".
    func testABothSidesInjuryListsExercisesDoneOneSideAtATime() throws {
        clock = at("2026-11-09 17:00")
        let m = try model()
        m.profile.unit = .kg
        let knees = Injury(label: "Patellar tendinopathy, both knees", side: .both, onset: Day("2026-09-01")!,
                           tissues: ["patellar_tendon"])
        m.save(knees)
        try session(m, "Bulgarian Split Squat (Dumbbell)", sides: [.left, .right], load: 12)
        clock = at("2026-11-10 12:00")
        let report = m.report(for: knees, days: 14)
        XCTAssertGreaterThan(report.weeklyLoad.reduce(0, +), 0, "precondition: the sets loaded the tendon")
        XCTAssertEqual(report.exercises.map(\.exercise), ["Bulgarian Split Squat (Dumbbell)"],
                       "a both-sides injury's report drops every exercise logged per side")
        XCTAssertFalse(m.reportText(for: knees, days: 14).contains("None logged in this period."),
                       "the report tells the therapist no exercise loaded the knees")
    }

    /// Body-weight sets on a movement with no share of body weight set for it
    /// (lunge, calf raise, bridge, hip abduction, Copenhagen) have no weight
    /// known. They are not passed off as 0 kg moved: the timeline counts them
    /// and the report says they are in effective reps and not in weight moved.
    func testBodyweightSplitSquatsAreCountedAsUnweighedNotAsZero() throws {
        clock = at("2026-11-10 17:00")
        let m = try model()
        m.profile.unit = .kg
        m.profile.bodyweightKg = 80
        let knee = Injury(label: "Left knee", side: .left, onset: Day("2026-10-01")!, tissues: ["quads"])
        m.save(knee)
        try session(m, "Split Squat (Bodyweight)", sides: [.left, .right], load: nil)
        let today = try XCTUnwrap(m.timeline(for: knee, days: 7).last)
        XCTAssertGreaterThan(today.load, 0, "precondition: the sets loaded the quads")
        XCTAssertEqual(today.unweighedSets, 6, "30 body-weight split squats a side are neither weighed nor counted as unweighed")
        XCTAssertEqual(m.report(for: knee, days: 7).unweighedSets, 6)
        XCTAssertTrue(m.reportText(for: knee, days: 7).contains("6 sets that loaded it had no weight known"),
                      m.reportText(for: knee, days: 7))
    }

    /// Resolving an injury deletes every check not answered, including the
    /// skipped and the lapsed ones, so its report afterwards shows perfect
    /// adherence: "Questions answered: 1." and nothing skipped or missed.
    func testResolvingAnInjuryKeepsItsSkippedAndMissedQuestions() throws {
        clock = at("2026-11-02 08:05")
        let m = try model()
        var quad = Injury(label: "Right quad strain", side: .right, onset: Day("2026-10-20")!, tissues: ["quads"])
        m.save(quad)
        m.skip([try XCTUnwrap(m.dueChecks.first)])                         // morning question skipped
        clock = at("2026-11-02 17:00")
        try session(m, "Single-Leg Extension (Machine)", sides: [.right], load: 20, rounds: 1)
        clock = at("2026-11-03 08:05")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 2)
        clock = at("2026-11-04 12:00")
        let before = m.report(for: quad, days: 14)
        XCTAssertGreaterThan(before.skipped, 0, "precondition"); XCTAssertGreaterThan(before.missed, 0, "precondition")
        quad.resolvedOn = Day("2026-11-04")
        m.save(quad)
        let after = m.report(for: quad, days: 14)
        XCTAssertEqual(after.answered, before.answered)
        XCTAssertEqual(after.skipped, before.skipped, "resolving the injury erased the skipped questions from its report")
        XCTAssertEqual(after.missed, before.missed, "resolving the injury erased the missed questions from its report")
    }

    /// "1 weeks before this report", and "0 weeks" for an injury begun days ago.
    func testWeeksSinceOnsetAreWrittenAsWords() throws {
        clock = at("2026-11-10 12:00")
        let m = try model()
        let calf = Injury(label: "Calf", side: .left, onset: Day("2026-11-01")!, tissues: ["calf"])
        m.save(calf)
        let began = { (injury: Injury) in m.reportText(for: injury).split(separator: "\n").first { $0.contains("Began") } ?? "" }
        XCTAssertFalse(began(calf).contains("1 weeks"), "plural for one week: \(began(calf))")
        let fresh = Injury(label: "Fresh", side: .left, onset: Day("2026-11-08")!, tissues: ["calf"])
        m.save(fresh)
        XCTAssertFalse(began(fresh).contains("0 weeks"), "an injury two days old reads: \(began(fresh))")
    }

    /// With a period that is not whole weeks the last row of the table sums
    /// the remaining days but is headed like a week, so a steady load reads
    /// as a fall (10 days: a 7-day row, then a 3-day row).
    func testAPartWeekIsNotTabledAsAWeek() throws {
        clock = at("2026-11-10 21:00")
        let store = try Store(path: ":memory:")
        let today = Day(clock, in: zone)
        try store.save((0..<60).map { DailyMetric(day: today.adding(-$0), metric: MetricName.steps, value: 8000, source: "watch") })
        let m = try model(store)
        let calf = Injury(label: "Left calf", side: .left, onset: Day("2026-08-01")!, tissues: ["calf"])
        m.save(calf)
        let report = m.report(for: calf, days: 10)
        XCTAssertEqual(report.days.count, 10)
        let weeks = report.weeklyLoad
        XCTAssertEqual(weeks.last ?? 0, weeks.first ?? 0, accuracy: 1,
                       "steady walking: the last row (\(weeks.last ?? 0)) is 3 days, headed as a week next to 7 days (\(weeks.first ?? 0))")
    }

    // MARK: Usual week

    /// `hasUsualWeek` turns true after 14 days, but the usual week is the 28
    /// days before the last 7 divided by 4, of which only 8 days hold data:
    /// training the same every day reads as 3.5 times usual.
    func testTwoWeeksOfSteadyTrainingIsNotThreeTimesUsual() throws {
        let start = at("2026-10-01 17:00")
        let m = try model()
        m.profile.unit = .kg
        for i in 0...14 {
            clock = start.addingTimeInterval(Double(i) * 86_400)
            try session(m, "Leg Extension (Machine)", sides: [.both], load: 40, rounds: 1)
        }
        m.refreshClock()
        XCTAssertTrue(m.hasUsualWeek)
        let quads = try XCTUnwrap(m.tissueWeeks(weeksAgo: 0).first { $0.tissue.id == "quads" && $0.side == .left })
        let ratio = try XCTUnwrap(quads.ratio)
        XCTAssertEqual(ratio, 1, accuracy: 0.34,
                       "the same session every day reads as \(ratio)x usual once hasUsualWeek is true")
    }

    // MARK: Catalogue conventions

    /// The assisted machines are logged as plain body weight: the assistance
    /// typed in is ignored, so 40 kg of help counts as an unassisted pull-up
    /// (load, effective reps, weight moved, and the advice all overstate it).
    func testAssistanceOnAnAssistedPullUpIsNotIgnored() throws {
        let m = try model()
        m.profile.bodyweightKg = 80
        m.startWorkout()
        var assisted = try XCTUnwrap(m.addSet(try entry("Assisted Pull-Up (Machine)", m)))
        assisted.loadValue = 40; assisted.loadUnit = .kg; assisted.reps = 8
        var plain = try XCTUnwrap(m.addSet(try entry("Pull-Up", m)))
        plain.reps = 8
        let ledger = Ledger(library: m.library)
        let help = try XCTUnwrap(ledger.loadKg(assisted, profile: m.profile))
        let full = try XCTUnwrap(ledger.loadKg(plain, profile: m.profile))
        XCTAssertLessThan(help, full, "an assisted pull-up with 40 kg of help counts \(help) kg, the same as a pull-up (\(full) kg)")
    }

    // MARK: Injury suggestions

    /// A spinal level ("L4-L5", "L5-S1") is read as the left side.
    func testASpinalLevelIsNotASide() {
        for name in ["Herniated disc L4-L5", "L5-S1 disc bulge"] {
            XCTAssertNil(Library.standard.suggestInjury(named: name).side, "\(name) suggested the left side")
        }
    }

    /// "Back of ..." names a place, not the spine: the erectors are suggested.
    func testTheBackOfAJointIsNotTheSpine() {
        for name in ["Back of knee pain", "Back of thigh", "Back of shoulder"] {
            let tissues = Library.standard.suggestInjury(named: name).tissues
            XCTAssertFalse(tissues.contains("erectors"), "\(name) suggested the spinal erectors: \(tissues)")
        }
        XCTAssertFalse(Library.standard.suggestInjury(named: "Back of thigh").tissues.contains("quads"),
                       "the back of the thigh is the hamstrings, not the quadriceps")
    }

    /// "knee" used as a landmark puts the patellar tendon first, before the muscle named.
    func testAMuscleNamedNearTheKneeIsNotThePatellarTendon() {
        for (name, muscle) in [("Hamstring strain behind the knee", "hamstrings"), ("Calf strain below the knee", "calf")] {
            let tissues = Library.standard.suggestInjury(named: name).tissues
            XCTAssertEqual(tissues.first, muscle, "\(name) suggested \(tissues)")
            XCTAssertFalse(tissues.contains("patellar_tendon"), "\(name) suggested the patellar tendon")
        }
    }

    /// Gluteal tendinopathy is a gluteus medius and minimus tendon problem,
    /// not the gluteus maximus.
    func testGlutealTendinopathyIsGluteMedius() {
        let tissues = Library.standard.suggestInjury(named: "Gluteal tendinopathy").tissues
        XCTAssertEqual(tissues, ["glute_med"], "suggested \(tissues)")
    }

    /// Heel pain is most often the plantar fascia; "heel" alone suggests the Achilles.
    func testPlantarHeelPainIsNotTheAchilles() {
        for name in ["Plantar fasciitis (heel)", "Heel spur"] {
            let tissues = Library.standard.suggestInjury(named: name).tissues
            XCTAssertFalse(tissues.contains("achilles"), "\(name) suggested the Achilles tendon")
        }
    }

    /// "hip" with another word that places it still adds the gluteus medius.
    func testHipAsAPlaceDoesNotAddGluteMedius() {
        for name in ["Hip adductor strain", "Front of hip pain"] {
            let tissues = Library.standard.suggestInjury(named: name).tissues
            XCTAssertFalse(tissues.contains("glute_med"), "\(name) suggested the gluteus medius: \(tissues)")
        }
    }

    /// Plurals of a joint suggest nothing: "Both knees" gets the side but no tissue.
    func testPluralJointsSuggestTheirTissues() {
        XCTAssertEqual(Library.standard.suggestInjury(named: "Both knees").tissues.first, "patellar_tendon")
        XCTAssertEqual(Library.standard.suggestInjury(named: "Bilateral shoulders").tissues.first, "rotator_cuff")
    }
}

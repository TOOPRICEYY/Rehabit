import Foundation
#if canImport(Observation)
import Observation
#endif

/// One tissue and side over the last week, against its own previous four weeks.
public struct TissueWeek: Identifiable, Equatable, Sendable {
    public let tissue: Tissue
    public let side: Side
    /// Dose in the last 7 days, in effective reps.
    public let week: Double
    /// Mean weekly dose over the 28 days before that.
    public let usualWeek: Double
    public var id: String { tissue.id + "|" + side.rawValue }
    /// Nil when there was no load in the earlier four weeks to compare with.
    public var ratio: Double? { usualWeek > 0 ? week / usualWeek : nil }
}

/// Everything the screens do, with no screen code in it, so it can be tested
/// without a phone. The views only read these properties and call these methods.
#if canImport(Observation)
@Observable
#endif
public final class AppModel {
    public private(set) var workouts: [Workout] = []        // finished, newest first
    public private(set) var injuries: [Injury] = []
    public private(set) var checks: [PainCheck] = []
    public private(set) var active: Workout?
    public private(set) var activeSets: [WorkoutSet] = []
    public private(set) var lastError: String?
    public var profile: Profile { didSet { store.profile = profile } }

    public let library: Library
    private let store: Store
    private let ledger: Ledger
    private let advisor: Advisor
    private let now: () -> Date
    private let zone: TimeZone
    private var allSets: [WorkoutSet] = []

    public init(store: Store, library: Library = .standard, zone: TimeZone = .current,
                now: @escaping () -> Date = Date.init) {
        self.store = store; self.library = library; self.zone = zone; self.now = now
        ledger = Ledger(library: library)
        advisor = Advisor(ledger: ledger)
        profile = store.profile
        reload()
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body(); lastError = nil } catch { lastError = String(describing: error) }
    }

    public func reload() {
        attempt {
            let everything = try store.all(Workout.self)
            active = everything.last { $0.end == nil }
            workouts = everything.filter { $0.end != nil }.sorted { $0.start > $1.start }
            allSets = try store.all(WorkoutSet.self)
            activeSets = active.map { a in allSets.filter { $0.workoutID == a.id }.sorted { $0.position < $1.position } } ?? []
            injuries = try store.all(Injury.self).sorted { $0.onset > $1.onset }
            checks = try store.all(PainCheck.self).sorted { $0.dueAt < $1.dueAt }
        }
    }

    // MARK: Workouts

    public func startWorkout(title: String = "Workout") {
        guard active == nil else { return }
        attempt {
            try store.save(Workout(title: title, start: now(), zone: zone))
        }
        reload()
    }

    public func renameActive(_ title: String) {
        guard var workout = active else { return }
        workout.title = title
        workout.updatedAt = now()
        attempt { try store.save(workout) }
        reload()
    }

    /// Adds a set to the workout in progress. A repeat of an exercise copies the
    /// set before it; a first set copies the first set of the last session.
    @discardableResult
    public func addSet(_ exercise: CatalogueExercise, side: Side? = nil) -> WorkoutSet? {
        guard let workout = active else { return nil }
        let position = (activeSets.map(\.position).max() ?? -1) + 1
        var set: WorkoutSet
        if let last = activeSets.last(where: { $0.exercise == exercise.name && (side == nil || $0.side == side) }) {
            set = last
            set.id = UUID().uuidString
            set.position = position
            set.pain = nil; set.painType = nil; set.repsInReserve = nil; set.notes = ""
        } else {
            let chosen = side ?? (exercise.unilateral ? (injuries.first { $0.isActive }?.side ?? .left) : .both)
            set = WorkoutSet(workout: workout, position: position, exercise: exercise.name,
                             pattern: exercise.pattern, side: chosen == .both && exercise.unilateral ? .left : chosen,
                             loadUnit: profile.unit, convention: exercise.convention)
            if let previous = previousSets(exercise: exercise.name, side: set.side).first {
                set.kind = previous.kind; set.reps = previous.reps; set.holdSeconds = previous.holdSeconds
                set.loadValue = previous.loadValue; set.loadUnit = previous.loadUnit
                set.convention = previous.convention
            }
        }
        set.updatedAt = now()
        attempt { try store.save(set) }
        reload()
        return set
    }

    public func update(_ set: WorkoutSet) {
        var set = set
        set.updatedAt = now()
        attempt { try store.save(set) }
        reload()
    }

    public func removeSet(id: String) {
        attempt { try store.delete(WorkoutSet.self, id: id, at: now()) }
        reload()
    }

    /// The sets of the most recent finished session of this exercise on this side.
    public func previousSets(exercise: String, side: Side) -> [WorkoutSet] {
        let finished = Set(workouts.map(\.id))
        let earlier = allSets.filter { $0.exercise == exercise && $0.side == side && finished.contains($0.workoutID) }
        guard let lastDay = earlier.map(\.workoutDay).max() else { return [] }
        return earlier.filter { $0.workoutDay == lastDay }.sorted { $0.position < $1.position }
    }

    public func sets(of workout: Workout) -> [WorkoutSet] {
        allSets.filter { $0.workoutID == workout.id }.sorted { $0.position < $1.position }
    }

    /// Statements about this set against the history: load jump, layoff, a tissue
    /// coming back from weeks of nothing, an injured tissue being loaded.
    public func advice(for set: WorkoutSet) -> [Advice] {
        let history = allSets.filter { $0.id != set.id }.map { ledger.ledgerSet($0, profile: profile) }
        return advisor.advice(for: ledger.ledgerSet(set, profile: profile), history: history, injuries: injuries)
    }

    /// Ends the workout and schedules pain checks for each injury it loaded.
    /// Returns the checks that are due now (the after-session ones).
    @discardableResult
    public func finishWorkout() -> [PainCheck] {
        guard var workout = active else { return [] }
        if activeSets.isEmpty {
            discardWorkout()
            return []
        }
        let end = now()
        workout.end = end
        workout.updatedAt = end
        let schedule = PainSchedule(zone: zone)
        var created: [PainCheck] = []
        attempt {
            try store.save(workout)
            for injury in schedule.injuriesLoaded(by: activeSets, injuries: injuries, library: library) {
                for check in schedule.checks(for: injury, workout: workout, endedAt: end) {
                    try store.save(check)
                    created.append(check)
                }
            }
        }
        reload()
        return created.filter { $0.moment == .afterSession }
    }

    public func discardWorkout() {
        guard let workout = active else { return }
        attempt { try store.deleteWorkout(id: workout.id, at: now()) }
        reload()
    }

    public func deleteWorkout(_ workout: Workout) {
        attempt { try store.deleteWorkout(id: workout.id, at: now()) }
        reload()
    }

    // MARK: Injuries and pain

    public func save(_ injury: Injury) {
        var injury = injury
        injury.updatedAt = now()
        attempt { try store.save(injury) }
        reload()
    }

    public func deleteInjury(id: String) {
        attempt { try store.delete(Injury.self, id: id, at: now()) }
        reload()
    }

    /// Unanswered checks whose time has come, oldest first. A check more than
    /// three days overdue is dropped from the list and stays recorded as missing.
    public var dueChecks: [PainCheck] {
        let time = now()
        return checks.filter { !$0.isAnswered && $0.dueAt <= time && time.timeIntervalSince($0.dueAt) < 3 * 86_400 }
    }

    /// Checks still to come, for scheduling reminders.
    public var upcomingChecks: [PainCheck] {
        let time = now()
        return checks.filter { !$0.isAnswered && $0.dueAt > time }
    }

    public func answer(_ check: PainCheck, pain: Double, type: PainType? = nil, notes: String = "") {
        var check = check
        check.pain = (pain * 2).rounded() / 2          // half points
        check.painType = type
        check.notes = notes
        check.answeredAt = now()
        check.updatedAt = now()
        attempt { try store.save(check) }
        reload()
    }

    /// Records a baseline reading for an injury with no session attached.
    public func logBaseline(injury: Injury, pain: Double, type: PainType? = nil, notes: String = "") {
        let check = PainCheck(injuryID: injury.id, workoutID: nil, moment: .baseline, dueAt: now(), zone: zone,
                              updatedAt: now())
        attempt { try store.save(check) }
        answer(check, pain: pain, type: type, notes: notes)
    }

    public func painHistory(for injury: Injury) -> [PainCheck] {
        checks.filter { $0.injuryID == injury.id && $0.isAnswered }
    }

    // MARK: Load

    /// Each loaded tissue and side: the last 7 days against its own previous four weeks.
    public func tissueWeeks() -> [TissueWeek] {
        let today = Day(now(), in: zone)
        let finished = Set(workouts.map(\.id)).union(active.map { [$0.id] } ?? [])
        let sets = allSets.filter { finished.contains($0.workoutID) }.map { ledger.ledgerSet($0, profile: profile) }
        let days = ledger.tissueDays(sets, through: today).filter { today.days(since: $0.day) < 35 && $0.day <= today }
        var week: [String: Double] = [:], prior: [String: Double] = [:], sides: [String: (String, Side)] = [:]
        for d in days where d.dose > 0 {
            let key = d.tissue + "|" + d.side.rawValue
            sides[key] = (d.tissue, d.side)
            if today.days(since: d.day) < 7 { week[key, default: 0] += d.dose } else { prior[key, default: 0] += d.dose }
        }
        return sides.compactMap { key, value in
            guard let tissue = library.tissue(value.0) else { return nil }
            return TissueWeek(tissue: tissue, side: value.1, week: week[key] ?? 0, usualWeek: (prior[key] ?? 0) / 4)
        }.sorted { ($0.tissue.region, $0.tissue.name, $0.side.rawValue) < ($1.tissue.region, $1.tissue.name, $1.side.rawValue) }
    }

    // MARK: Health and export

    public func importHealth(from source: HealthSource, days: Int = 60) async {
        let today = Day(now(), in: zone)
        do {
            guard try await source.requestAccess() else { return }
            try store.save(try await source.dailyMetrics(from: today.adding(-days), through: today))
        } catch { lastError = String(describing: error) }
    }

    public func dailyMetrics(_ metric: String) -> [DailyMetric] { (try? store.dailyMetrics(metric)) ?? [] }

    public func exportJSON() -> Data? { try? store.snapshotJSON(at: now()) }

    public func merge(_ data: Data) -> Int {
        var changed = 0
        attempt { changed = try store.merge(try Store.decodeSnapshot(data)) }
        reload()
        return changed
    }
}

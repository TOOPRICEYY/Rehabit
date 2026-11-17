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
    /// Records in the database that this version cannot read. They are kept and exported.
    public private(set) var unreadableCount = 0
    /// Bumped when the clock should be read again; see `refreshClock()`.
    public private(set) var tick = 0
    /// Exercises in the workout in progress whose left and right sides were linked
    /// or unlinked by hand. The rest follow `defaultLinked(_:)`. Not stored: it
    /// only steers how the next edit is copied.
    public var linkOverrides: [String: Bool] = [:]
    /// Goes up whenever stored records were saved and read back (a workout
    /// finished, a pain check answered, an injury saved, an import), so the
    /// app knows when to write its export for the Mac again.
    public private(set) var revision = 0
    public var profile: Profile {
        didSet {
            guard profile != oldValue else { return }
            attempt { try store.setProfile(profile, at: now()) }
            history = nil
        }
    }

    public let library: Library
    private let store: Store
    private let ledger: Ledger
    private let advisor: Advisor
    private let now: () -> Date
    private let zone: TimeZone
    private var allSets: [WorkoutSet] = []
    /// Every set of a workout that still exists, in the form the ledger reads.
    /// Built when first needed and thrown away when a set or the profile changes.
    private var history: [(id: String, set: LedgerSet)]?

    /// How long each kind of question stays on the list before it counts as missed.
    /// "Right after the session" answered the next day would be a different reading.
    static let afterSessionWindow: TimeInterval = 3 * 3600
    static let delayedWindow: TimeInterval = 3 * 86_400

    public init(store: Store, library: Library = .standard, zone: TimeZone = .current,
                now: @escaping () -> Date = Date.init) {
        // Times are kept to the millisecond, the precision they are stored and compared at.
        self.store = store; self.library = library; self.zone = zone
        self.now = { Stamp.date(Stamp.millis(now())) }
        ledger = Ledger(library: library)
        advisor = Advisor(ledger: ledger)
        profile = store.profile
        reload()
    }

    var importZone: TimeZone { zone }
    var importNow: Date { now() }
    func noteError(_ text: String) { lastError = text }
    func storeImported(_ workout: Workout, sets: [WorkoutSet]) throws -> Bool { try store.addIfNew(workout, sets: sets) }

    func attempt(_ body: () throws -> Void) {
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
            unreadableCount = try store.unreadable().count
            history = nil
        }
        revision += 1
    }

    /// Call when time has passed without any change to the data (the app came
    /// back to the front, or a minute went by), so lists that depend on the
    /// time of day are worked out again.
    public func refreshClock() { tick += 1 }

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
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (name.isEmpty ? "Workout" : name) != workout.title else { return }
        workout.title = name.isEmpty ? "Workout" : name
        workout.updatedAt = now()
        attempt { try store.save(workout) }
        active = workout
    }

    /// The side a one-sided exercise most likely means: the side of an active
    /// injury in a tissue this exercise actually loads. Left if there is none.
    public func likelySide(for exercise: CatalogueExercise) -> Side {
        let loaded = Set((library.pattern(exercise.pattern)?.links ?? []).filter { $0.share >= 0.25 }.map(\.tissue))
        let match = injuries.first { $0.isActive && $0.side != .both && !loaded.isDisjoint(with: $0.tissues) }
        return match?.side ?? .left
    }

    /// Adds a set to the workout in progress. A repeat of an exercise on the
    /// same side copies the set before it (never its pain); a first set is
    /// prefilled from the last finished session. With no side given, a
    /// two-sided exercise is logged as both and a one-sided one on `likelySide`.
    @discardableResult
    public func addSet(_ exercise: CatalogueExercise, side: Side? = nil) -> WorkoutSet? {
        guard let workout = active else { return nil }
        let chosen = side ?? (exercise.unilateral ? likelySide(for: exercise) : .both)
        let position = (activeSets.map(\.position).max() ?? -1) + 1
        var set: WorkoutSet
        if let last = activeSets.last(where: { $0.exercise == exercise.name && $0.side == chosen }) {
            set = last
            set.id = UUID().uuidString
            set.position = position
            set.pain = nil; set.painType = nil; set.repsInReserve = nil; set.notes = ""
        } else {
            set = WorkoutSet(workout: workout, position: position, exercise: exercise.name,
                             pattern: exercise.pattern.isEmpty ? nil : exercise.pattern, side: chosen,
                             loadUnit: profile.unit, convention: exercise.convention)
            // Prefill from the first working set of last time, not a warm-up.
            let previous = previousSets(exercise: exercise.name, side: chosen)
            if let first = previous.first(where: { !$0.isWarmup }) ?? previous.first {
                set.kind = first.kind; set.reps = first.reps; set.holdSeconds = first.holdSeconds
                set.loadValue = first.loadValue; set.loadUnit = first.loadUnit
                set.convention = first.convention
            }
        }
        set.updatedAt = now()
        attempt { try store.save(set) }
        allSets.append(set)
        activeSets.append(set)
        history = nil
        return set
    }

    /// Saves a change to a set. A set that has been removed, or whose workout is
    /// gone, is not brought back by a late write from a field that still held it.
    public func update(_ set: WorkoutSet) {
        guard let index = allSets.firstIndex(where: { $0.id == set.id }),
              set.workoutID == active?.id || workouts.contains(where: { $0.id == set.workoutID }) else { return }
        var set = set
        if let pain = set.pain { set.pain = AppModel.cleanPain(pain) }
        guard set != allSets[index] else { return }
        set.updatedAt = now()
        attempt { try store.save(set) }
        // Patched in place: this runs on every keystroke, and reading the whole
        // database back each time is what made typing lag on a long history.
        allSets[index] = set
        if let i = activeSets.firstIndex(where: { $0.id == set.id }) { activeSets[i] = set }
        history = nil
    }

    public func removeSet(id: String) {
        attempt { try store.delete(WorkoutSet.self, id: id, at: now()) }
        allSets.removeAll { $0.id == id }
        activeSets.removeAll { $0.id == id }
        history = nil
    }

    /// The sets of the most recent finished session of this exercise on this side.
    public func previousSets(exercise: String, side: Side) -> [WorkoutSet] {
        let name = AppModel.normal(exercise)
        let finished = Dictionary(workouts.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
        let earlier = allSets.filter { AppModel.normal($0.exercise) == name && $0.side == side && finished[$0.workoutID] != nil }
        guard let last = earlier.max(by: { finished[$0.workoutID]! < finished[$1.workoutID]! }) else { return [] }
        return earlier.filter { $0.workoutID == last.workoutID }.sorted { $0.position < $1.position }
    }

    /// Names are compared the way the ledger compares them: case and outer spaces do not matter.
    private static func normal(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The picker entry for a set already logged, so "add set" can repeat it.
    public func catalogueEntry(for set: WorkoutSet) -> CatalogueExercise {
        library.catalogue.first { $0.name == set.exercise }
            ?? CatalogueExercise(name: set.exercise, pattern: set.pattern ?? "", convention: set.convention,
                                 unilateral: set.side != .both)
    }

    /// Exercises the person has added themselves, newest first, for the picker.
    public var customExercises: [CatalogueExercise] {
        let known = Set(library.catalogue.map { AppModel.normal($0.name) })
        var seen = Set<String>(), out: [CatalogueExercise] = []
        for set in allSets.reversed() {
            let key = AppModel.normal(set.exercise)
            if known.contains(key) || !seen.insert(key).inserted { continue }
            out.append(catalogueEntry(for: set))
        }
        return out
    }

    public func sets(of workout: Workout) -> [WorkoutSet] {
        allSets.filter { $0.workoutID == workout.id }.sorted { $0.position < $1.position }
    }

    private func ledgerHistory() -> [(id: String, set: LedgerSet)] {
        if let history { return history }
        var existing = Set(workouts.map(\.id))
        if let active { existing.insert(active.id) }
        let built = allSets.filter { existing.contains($0.workoutID) }
            .map { (id: $0.id, set: ledger.ledgerSet($0, profile: profile)) }
        history = built
        return built
    }

    /// Statements about this set against the history: load jump, layoff, a tissue
    /// coming back from weeks of nothing, an injured tissue being loaded.
    public func advice(for set: WorkoutSet) -> [Advice] {
        let others = ledgerHistory().filter { $0.id != set.id }.map(\.set)
        return advisor.advice(for: ledger.ledgerSet(set, profile: profile), history: others, injuries: injuries)
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
        deleteWorkout(workout)
    }

    /// Deletes a workout, its sets, and the pain questions that were still to
    /// be asked about it. Answers already given stay: the pain was real.
    public func deleteWorkout(_ workout: Workout) {
        attempt {
            try store.deleteWorkout(id: workout.id, at: now())
            for check in checks where check.workoutID == workout.id && !check.isAnswered {
                try store.delete(PainCheck.self, id: check.id, at: now())
            }
        }
        reload()
    }

    // MARK: Injuries and pain

    public func save(_ injury: Injury) {
        var injury = injury
        injury.updatedAt = now()
        attempt {
            try store.save(injury)
            if !injury.isActive {
                // A resolved injury is not asked about any more.
                for check in checks where check.injuryID == injury.id && !check.isAnswered {
                    try store.delete(PainCheck.self, id: check.id, at: now())
                }
            }
        }
        reload()
    }

    /// Deletes an injury with all of its pain readings.
    public func deleteInjury(id: String) {
        attempt { try store.delete(Injury.self, id: id, at: now()) }
        reload()
    }

    /// Unanswered checks whose time has come, oldest first. One left too long
    /// drops off the list and stays recorded as missing, never as zero.
    public var dueChecks: [PainCheck] {
        _ = tick
        let time = now()
        return checks.filter { check in
            guard !check.isAnswered, check.dueAt <= time else { return false }
            let window = check.moment == .afterSession ? AppModel.afterSessionWindow : AppModel.delayedWindow
            return time.timeIntervalSince(check.dueAt) <= window
        }
    }

    /// Checks still to come, for scheduling reminders.
    public var upcomingChecks: [PainCheck] {
        _ = tick
        let time = now()
        return checks.filter { !$0.isAnswered && $0.dueAt > time }
    }

    /// Pain is 0 to 10 in half points. Anything else typed or dragged is pulled into that range.
    static func cleanPain(_ pain: Double) -> Double? {
        guard pain.isFinite else { return nil }
        return min(10, max(0, (pain * 2).rounded() / 2))
    }

    public func answer(_ check: PainCheck, pain: Double, type: PainType? = nil, notes: String = "") {
        guard let clean = AppModel.cleanPain(pain) else {
            lastError = "That pain value is not a number."
            return
        }
        var check = check
        check.pain = clean
        check.painType = type
        check.notes = notes
        check.answeredAt = now()
        check.updatedAt = now()
        attempt { try store.save(check) }
        reload()
    }

    /// Records a baseline reading for an injury with no session attached.
    public func logBaseline(injury: Injury, pain: Double, type: PainType? = nil, notes: String = "") {
        guard AppModel.cleanPain(pain) != nil else {
            lastError = "That pain value is not a number."
            return
        }
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
    public func tissueWeeks() -> [TissueWeek] { tissueWeeks(weeksAgo: 0) }

    /// The day load weeks end on: today, or a later day a session was already logged on.
    private var loadToday: Day {
        // After a flight west the clock can read a day earlier than a session
        // already logged; that session still counts as this week.
        var today = Day(now(), in: zone)
        if let latest = allSets.map(\.workoutDay).max(), latest > today { today = latest }
        return today
    }

    /// The 35 days of tissue load up to the end of a week (0 is the week ending
    /// today, 1 the week before), with the sets read to work them out.
    private func loadWindow(weeksAgo: Int) -> (end: Day, sets: [LedgerSet], days: [TissueDay]) {
        _ = tick
        let end = loadToday.adding(-7 * max(0, weeksAgo))
        // 35 days are shown; the 28 before them are only needed as reference loads.
        let from = end.adding(-35 - ledger.settings.referenceWindowDays)
        let sets = ledgerHistory().map(\.set).filter { $0.day >= from && $0.day <= end }
        let days = ledger.tissueDays(sets, through: end).filter { end.days(since: $0.day) < 35 && $0.day <= end }
        return (end, sets, days)
    }

    /// Each loaded tissue and side for the week ending `weeksAgo` weeks before
    /// today, against its own four weeks before that.
    public func tissueWeeks(weeksAgo: Int) -> [TissueWeek] {
        let window = loadWindow(weeksAgo: weeksAgo)
        var week: [String: Double] = [:], prior: [String: Double] = [:], sides: [String: (String, Side)] = [:]
        for d in window.days where d.dose > 0 {
            let key = d.tissue + "|" + d.side.rawValue
            sides[key] = (d.tissue, d.side)
            if window.end.days(since: d.day) < 7 { week[key, default: 0] += d.dose } else { prior[key, default: 0] += d.dose }
        }
        return sides.compactMap { key, value in
            guard let tissue = library.tissue(value.0) else { return nil }
            return TissueWeek(tissue: tissue, side: value.1, week: week[key] ?? 0, usualWeek: (prior[key] ?? 0) / 4)
        }.sorted { ($0.tissue.region, $0.tissue.name, $0.side.rawValue) < ($1.tissue.region, $1.tissue.name, $1.side.rawValue) }
    }

    /// One tissue and side in detail for the week ending `weeksAgo` weeks back:
    /// its dose in each of the five weeks up to then (oldest first) and the
    /// exercises that made up the last of them, largest first.
    public func tissueDetail(_ tissue: String, side: Side, weeksAgo: Int = 0) -> TissueDetail {
        let window = loadWindow(weeksAgo: weeksAgo)
        var weekly = [Double](repeating: 0, count: 5)
        for d in window.days where d.tissue == tissue && d.side == side {
            let back = window.end.days(since: d.day) / 7
            if (0..<5).contains(back) { weekly[4 - back] += d.dose }
        }
        var byExercise: [String: Double] = [:]
        for record in ledger.setDoses(window.sets)
        where window.end.days(since: record.set.day) < 7 && record.set.side.bodySides.contains(side) {
            for link in library.pattern(record.set.pattern)?.links ?? [] where link.tissue == tissue {
                byExercise[record.set.exercise, default: 0] += link.share * record.dose
            }
        }
        let contributions = byExercise.filter { $0.value > 0 }
            .map { TissueDetail.Contribution(exercise: $0.key, dose: $0.value) }
            .sorted { ($0.dose, $1.exercise) > ($1.dose, $0.exercise) }
        return TissueDetail(tissue: tissue, side: side, weekEnding: window.end, weekly: weekly, contributions: contributions)
    }

    /// The sides of each tissue with an active injury.
    public var injuredTissueSides: [String: Set<Side>] {
        var out: [String: Set<Side>] = [:]
        for injury in injuries where injury.isActive {
            for tissue in injury.tissues { out[tissue, default: []].formUnion(injury.side.bodySides) }
        }
        return out
    }

    // MARK: Health and export

    /// Reads the last `days` days from a health source. Returns how many values
    /// were stored, or nil if access was unavailable or the read failed.
    @MainActor
    @discardableResult
    public func importHealth(from source: HealthSource, days: Int = 60) async -> Int? {
        let today = Day(now(), in: zone)
        lastError = nil
        do {
            guard try await source.requestAccess() else { return nil }
            let metrics = try await source.dailyMetrics(from: today.adding(-days), through: today)
            try store.save(metrics)
            revision += 1
            return metrics.filter { $0.value.isFinite }.count
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    public func dailyMetrics(_ metric: String) -> [DailyMetric] { (try? store.dailyMetrics(metric)) ?? [] }

    public func exportJSON() -> Data? { try? store.snapshotJSON(at: now()) }

    public func merge(_ data: Data) -> Int {
        var changed = 0
        attempt { changed = try store.merge(try Store.decodeSnapshot(data)) }
        profile = store.profile
        reload()
        return changed
    }
}

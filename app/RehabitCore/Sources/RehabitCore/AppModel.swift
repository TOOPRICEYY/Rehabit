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
    /// Sessions to start from, the most recently used first.
    public private(set) var routines: [Routine] = []
    public private(set) var active: Workout?
    public private(set) var activeSets: [WorkoutSet] = []
    public private(set) var lastError: String?
    /// Records in the database that this version cannot read. They are kept and exported.
    public private(set) var unreadableCount = 0
    /// Bumped when the clock should be read again; see `refreshClock()`.
    public private(set) var tick = 0
    /// Exercises in the workout in progress whose left and right sides were linked
    /// or unlinked by hand. The rest follow `defaultLinked(_:)`. Kept with the
    /// workout, so leaving the app mid-workout does not forget it.
    public var linkOverrides: [String: Bool] {
        get { active?.linkOverrides ?? [:] }
        set {
            guard var workout = active, (workout.linkOverrides ?? [:]) != newValue else { return }
            workout.linkOverrides = newValue.isEmpty ? nil : newValue
            workout.updatedAt = now()
            attempt { try store.save(workout) }
            active = workout
        }
    }
    /// When the rest countdown was last dismissed by hand. Not stored.
    public var restSkippedAt: Date?
    /// Seconds added to or taken from the rest running now. Not stored.
    public var restAdjust: RestAdjust?
    /// The hold being timed now, if one is. Not stored: it is a few seconds long.
    public internal(set) var holdRun: HoldRun?
    /// The set whose rest was dismissed, and the set most recently marked done. Not stored.
    var restSkippedFor: String?
    var lastMarkedDone: String?
    /// Goes up whenever stored records were saved and read back (a workout
    /// finished, a pain check answered, an injury saved, an import), so the
    /// app knows when to write its export for the Mac again.
    public private(set) var revision = 0
    public var profile: Profile {
        didSet {
            guard profile != oldValue else { return }
            attempt { try store.setProfile(profile, at: now()) }
            history = nil; nameIndex = nil
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
    /// Every set held, by exercise name as names are compared. Built when first
    /// needed and thrown away with `history`: lowercasing twelve thousand names
    /// on every keystroke is what made a long history slow.
    private var nameIndex: [String: [WorkoutSet]]?
    /// Body weight by day, oldest first, one value a day. Built when first needed.
    private var massSeries: [(day: Day, kg: Double)]?

    /// How long each kind of question stays on the list before it counts as missed.
    /// "Right after the session" answered the next day would be a different reading.
    /// A delayed question answered much later would be stored under a moment
    /// it does not describe, so it lapses after half a day and stays missing.
    static let afterSessionWindow: TimeInterval = 3 * 3600
    static let delayedWindow: TimeInterval = 12 * 3600
    static func window(_ moment: PainCheckMoment) -> TimeInterval {
        moment == .afterSession ? afterSessionWindow : delayedWindow
    }

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
    var clock: Date { now() }
    var localZone: TimeZone { zone }
    var schedule: PainSchedule { PainSchedule(zone: zone, morningHour: profile.morningHour) }
    func storeChecks(_ checks: [PainCheck]) throws { try store.saveAll(checks) }
    func storeRoutine(_ routine: Routine) throws { try store.save(routine) }
    func removeRoutine(id: String) throws { try store.delete(Routine.self, id: id, at: now()) }
    /// Changes the workout in progress (its supersets, the routine it came from) and saves it.
    func changeActive(_ change: (inout Workout) -> Void) {
        guard var workout = active else { return }
        let before = workout
        change(&workout)
        guard workout != before else { return }
        workout.updatedAt = now()
        attempt { try store.save(workout) }
        active = workout
    }
    func storeSets(_ sets: [WorkoutSet]) throws { try store.saveAll(sets) }
    func noteError(_ text: String) { lastError = text }
    func storeImported(_ workout: Workout, sets: [WorkoutSet]) throws -> Bool { try store.addIfNew(workout, sets: sets) }
    /// Every set held, of any workout, for the progress views (Progress.swift),
    /// which would otherwise have to ask `sets(of:)` once per workout.
    var storedSets: [WorkoutSet] { allSets }

    /// Every set of an exercise, of any workout. Case and outer spaces in the name do not matter.
    func sets(named exercise: String) -> [WorkoutSet] {
        if nameIndex == nil {
            var index: [String: [WorkoutSet]] = [:]
            for (name, sets) in Dictionary(grouping: allSets, by: \.exercise) {
                index[AppModel.normal(name), default: []] += sets
            }
            nameIndex = index
        }
        return nameIndex?[AppModel.normal(exercise)] ?? []
    }

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
            routines = try store.all(Routine.self).sorted {
                ($0.lastUsed ?? .distantPast, $1.name.lowercased()) > ($1.lastUsed ?? .distantPast, $0.name.lowercased())
            }
            unreadableCount = try store.unreadable().count
            history = nil; nameIndex = nil; massSeries = nil
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

    /// The side a one-sided exercise most likely means: the side of the active
    /// injury whose tissue this exercise works hardest. Left if there is none.
    public func likelySide(for exercise: CatalogueExercise) -> Side {
        guard let pattern = library.pattern(exercise.pattern) else { return .left }
        return AppModel.hardestWorked(injuries.filter(\.isActive), by: pattern, minShare: 0.25)?.side ?? .left
    }

    /// Adds a set to the workout in progress. A repeat of an exercise on the
    /// same side copies the set before it (never its pain); a first set is
    /// prefilled from the last finished session. With no side given, a
    /// two-sided exercise is logged as both and a one-sided one on `likelySide`.
    ///
    /// With `workoutID` it adds to a finished workout instead, the same way:
    /// a set added afterwards to a workout already done (an imported one too).
    @discardableResult
    public func addSet(_ exercise: CatalogueExercise, side: Side? = nil, to workoutID: String? = nil) -> WorkoutSet? {
        let target = workoutID.map { id in workouts.first { $0.id == id } } ?? active
        guard let workout = target else { return nil }
        let isActive = workout.id == active?.id
        let current = isActive ? activeSets : sets(of: workout)
        let chosen = side ?? (exercise.unilateral ? likelySide(for: exercise) : .both)
        let position = (current.map(\.position).max() ?? -1) + 1
        var set: WorkoutSet
        let sameSide = current.filter { $0.exercise == exercise.name && $0.side == chosen }
        if let last = sameSide.last {
            set = last
            set.id = UUID().uuidString
            set.position = position
            set.pain = nil; set.painType = nil; set.repsInReserve = nil; set.notes = ""
            set.completedAt = nil; set.pairID = nil; set.tag = nil
            // The set after a warm-up or a drop set is a working set: it takes the
            // numbers of the working set before it, or of last session's, never the
            // warm-up's or the drop's lighter load.
            if last.isWarmup || last.tag == .drop {
                set.isWarmup = false
                let source = sameSide.last { !$0.isWarmup && $0.tag != .drop }
                    ?? prefillSets(for: exercise, side: chosen).first { !$0.isWarmup && $0.tag != .drop }
                if let source { set.copyPrescription(from: source) }
            }
            // Chosen here, never worked out by rule, whatever the set it copies was.
            set.sideInferred = workoutID == nil ? set.sideInferred.map { _ in false } : false
        } else {
            set = WorkoutSet(workout: workout, position: position, exercise: exercise.name,
                             pattern: exercise.pattern.isEmpty ? nil : exercise.pattern, side: chosen,
                             kind: exercise.kind, loadUnit: profile.unit, convention: exercise.convention)
            if !isActive { set.sideInferred = false }
            // Prefill from the first working set of last time, not a warm-up.
            let previous = prefillSets(for: exercise, side: chosen)
            if let first = previous.first(where: { !$0.isWarmup }) ?? previous.first {
                set.kind = first.kind; set.reps = first.reps; set.holdSeconds = first.holdSeconds
                set.loadValue = first.loadValue; set.loadUnit = first.loadUnit
                set.convention = first.convention
            }
        }
        set.updatedAt = now()
        attempt { try store.save(set) }
        allSets.append(set)
        if isActive { activeSets.append(set) }
        history = nil; nameIndex = nil
        return set
    }

    /// Saves a change to a set. A set that has been removed, or whose workout is
    /// gone, is not brought back by a late write from a field that still held it.
    public func update(_ set: WorkoutSet) {
        guard let index = allSets.firstIndex(where: { $0.id == set.id }),
              set.workoutID == active?.id || workouts.contains(where: { $0.id == set.workoutID }) else { return }
        var set = set
        if let pain = set.pain { set.pain = AppModel.cleanPain(pain) }
        // A set is done only with reps or seconds: clearing them takes the mark off.
        if set.completedAt != nil, !((set.count ?? 0) > 0) { set.completedAt = nil }
        // A side changed by hand is the person's, and is never worked out again by rule.
        if set.side != allSets[index].side { set.sideInferred = false }
        // Touched: no longer only a plan.
        let before = allSets[index]
        if set.planned == true, before.planned == true, set.prescription != before.prescription || set.pain != before.pain
            || set.notes != before.notes || set.completedAt != before.completedAt || set.isWarmup != before.isWarmup
            || set.tag != before.tag || set.repsInReserve != before.repsInReserve { set.planned = nil }
        guard set != allSets[index] else { return }
        set.updatedAt = now()
        attempt { try store.save(set) }
        // Patched in place: this runs on every keystroke, and reading the whole
        // database back each time is what made typing lag on a long history.
        let moved = allSets[index].position != set.position
        allSets[index] = set
        if let i = activeSets.firstIndex(where: { $0.id == set.id }) { activeSets[i] = set }
        if moved { activeSets.sort { $0.position < $1.position } }      // kept in the order shown
        history = nil; nameIndex = nil
    }

    public func removeSet(id: String) {
        attempt { try store.delete(WorkoutSet.self, id: id, at: now()) }
        allSets.removeAll { $0.id == id }
        activeSets.removeAll { $0.id == id }
        history = nil; nameIndex = nil
        if holdRun?.setID == id { holdRun = nil }
        if lastMarkedDone == id { lastMarkedDone = nil }
    }

    /// The sets of the most recent finished session of this exercise on this side.
    public func previousSets(exercise: String, side: Side) -> [WorkoutSet] {
        let finished = Dictionary(workouts.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
        let earlier = sets(named: exercise).filter { $0.side == side && finished[$0.workoutID] != nil }
        guard let last = earlier.max(by: { (finished[$0.workoutID] ?? .distantPast) < (finished[$1.workoutID] ?? .distantPast) }) else { return [] }
        return earlier.filter { $0.workoutID == last.workoutID }.sorted { $0.position < $1.position }
    }

    /// Names are compared the way the ledger compares them: case and outer spaces do not matter.
    static func normal(_ name: String) -> String {
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
        // In the workout in progress, once any set has been marked done, the sets
        // only planned so far are not load yet. With nothing marked, all count.
        let ticking = usesDoneMarks
        let built = allSets.filter { existing.contains($0.workoutID) && !(ticking && $0.workoutID == active?.id && !$0.isDone) }
            .map { (id: $0.id, set: ledger.ledgerSet($0, profile: profile(on: $0.workoutDay))) }
        history = built
        return built
    }

    /// Each day's resting heart rate, the lowest reading of the day.
    private func restingHeartRates() -> [Day: Double] {
        var out: [Day: Double] = [:]
        for m in dailyMetrics(MetricName.restingHeartRate) where m.value > 0 { out[m.day] = min(out[m.day] ?? .infinity, m.value) }
        return out
    }

    /// The trusted maximum heart rate: the highest any session recorded, once enough have.
    private var trustedMaxHR: Double? {
        ledger.observedMaxHR(workouts.compactMap { $0.activity?.maxHeartRate })
    }

    private func ledgerActivity(_ workout: Workout) -> LedgerActivity? {
        guard let activity = workout.activity else { return nil }
        // A kind the person chose wins over the watch's type and name; "none" adds nothing.
        return LedgerActivity(day: workout.startDay, type: activity.type, name: workout.title,
                              minutes: workout.minutes, averageHR: activity.averageHeartRate,
                              countsAs: activity.countsAs, steps: activity.steps)
    }

    /// `ActivitySummary.countsAs` for a session the person says adds no load.
    public static let notCounted = "none"

    /// The kinds a session can be counted as, by name.
    public var activityKinds: [(id: String, name: String)] {
        // The library's names can carry a note in brackets ("Pickleball (beyond its steps)"); a menu shows the plain name.
        library.activityRates.keys.sorted().map { id -> (id: String, name: String) in
            let full = library.pattern(id)?.name ?? id
            let plain = full.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces) ?? full
            return (id, plain.isEmpty ? full : plain)
        }
        .sorted { $0.name < $1.name }
    }

    /// Sets what a session counts as (a pattern id, `notCounted`, or nil for
    /// the watch's own type). With `sameName`, every session of the same
    /// watch type and name gets it too, such as all of Garmin's "Cardio".
    public func setActivityCountsAs(_ kind: String?, for workout: Workout, sameName: Bool) {
        guard let activity = workout.activity else { return }
        let targets = sameName
            ? workouts.filter { $0.activity?.type == activity.type && $0.title == workout.title }
            : workouts.filter { $0.id == workout.id }
        for var target in targets {
            target.activity?.countsAs = kind
            update(target)
        }
    }

    /// How many sessions share this one's watch type and name.
    public func sessionsLike(_ workout: Workout) -> Int {
        guard let type = workout.activity?.type else { return 0 }
        return workouts.filter { $0.activity?.type == type && $0.title == workout.title }.count
    }

    /// Sessions with no sets (a run, a ride) as load, once each.
    private func activityHistory() -> [LedgerSet] {
        ledger.activitySets(workouts.compactMap(ledgerActivity), restingHR: restingHeartRates(), maxHR: trustedMaxHR)
    }

    /// What a run, ride or other session with no sets adds to load: the
    /// pattern it counts as, its effective reps, and the tissue with the
    /// largest share. Nil for a session with sets.
    public func activityLoad(for workout: Workout) -> (pattern: String?, effectiveReps: Double, tissue: Tissue?)? {
        guard let item = ledgerActivity(workout) else { return nil }
        guard let set = ledger.activitySets([item], restingHR: restingHeartRates(), maxHR: trustedMaxHR).first else {
            return (ledger.activityPattern(item), 0, nil)
        }
        let top = library.pattern(set.pattern)?.links.max { $0.share < $1.share }
        return (set.pattern, (set.reps ?? 0) * (top?.share ?? 1), top.flatMap { library.tissue($0.tissue) })
    }

    /// Daily steps from every source, the largest reading of each day (phone and
    /// watch count the same walking), as walking load.
    private func walkingHistory() -> [LedgerSet] {
        var steps: [Day: Double] = [:]
        for m in dailyMetrics(MetricName.steps) where m.value > 0 { steps[m.day] = max(steps[m.day] ?? 0, m.value) }
        // The heart-rate weighting of each day's steps; the mean when two sources have one.
        var weights: [Day: [Double]] = [:]
        for m in dailyMetrics(MetricName.stepHRWeight) where m.value.isFinite && m.value > 0 { weights[m.day, default: []].append(m.value) }
        return ledger.walkingSets(steps: steps, weights: weights.mapValues { $0.reduce(0, +) / Double($0.count) })
    }

    /// Statements about this set against the history: load jump, layoff, a tissue
    /// coming back from weeks of nothing, an injured tissue being loaded.
    public func advice(for set: WorkoutSet) -> [Advice] {
        let others = ledgerHistory().filter { $0.id != set.id }.map(\.set)
        let step = loadStep(for: set.exercise, unit: set.loadUnit) * set.loadUnit.kilograms
        // The sets of this exercise and side already done in the same workout.
        let ticking = set.workoutID == active?.id && usesDoneMarks
        let today = allSets.filter { $0.workoutID == set.workoutID && $0.id != set.id && $0.position < set.position
            && $0.side == set.side && AppModel.normal($0.exercise) == AppModel.normal(set.exercise) && (!ticking || $0.isDone) }
            .compactMap { ledger.ledgerSet($0, profile: profile(on: $0.workoutDay)).loadKg }.max()
        return advisor.advice(for: ledger.ledgerSet(set, profile: profile(on: set.workoutDay)), history: others,
                              injuries: injuries, stepKg: step, earlierTodayKg: today)
    }

    /// Ends the workout and schedules pain checks for each injury it loaded.
    /// Returns the checks that are due now (the after-session ones).
    @discardableResult
    public func finishWorkout(removingUnfinished: Bool = false) -> [PainCheck] {
        if removingUnfinished { for set in unfinishedSets { removeSet(id: set.id) } }
        // Rows added and never filled in were not done: they are not kept.
        for set in activeSets where set.isBlank { removeSet(id: set.id) }
        pruneSupersets()
        for var set in activeSets where set.planned != nil { set.planned = nil; update(set) }
        guard var workout = active else { return [] }
        restSkippedAt = nil; restAdjust = nil; restSkippedFor = nil; lastMarkedDone = nil; holdRun = nil
        if activeSets.isEmpty {
            discardWorkout()
            return []
        }
        let end = now()
        workout.end = end
        workout.planned = nil
        workout.updatedAt = end
        let created = newChecks(for: workout, sets: activeSets, end: end)
        attempt {
            try store.save(workout)
            try store.saveAll(created)
        }
        reload()
        return created.filter { $0.moment == .afterSession }
    }

    /// Saves a change to a finished workout: its title, notes, start or end.
    /// The start keeps its day as a fixed date, so moving it to another day
    /// moves the sets with it. An end before the start is taken as the start.
    public func update(_ workout: Workout) {
        guard let old = workouts.first(where: { $0.id == workout.id }) else { return }
        var workout = workout
        let name = workout.title.trimmingCharacters(in: .whitespacesAndNewlines)
        workout.title = name.isEmpty ? "Workout" : name
        if let end = workout.end, end < workout.start { workout.end = workout.start }
        if workout.end == nil { workout.end = old.end ?? workout.start }   // a finished workout stays finished
        workout.startDay = Day(workout.start, in: zone)
        guard workout != old else { return }
        workout.updatedAt = now()
        attempt {
            try store.save(workout)
            if workout.startDay != old.startDay {
                var moved = sets(of: old)
                for i in moved.indices { moved[i].workoutDay = workout.startDay; moved[i].updatedAt = workout.updatedAt }
                try store.saveAll(moved)
            }
            if workout.end != old.end, let end = workout.end {
                // The questions still open were timed from the old end. They are
                // asked again from the new one; those whose time has passed are not.
                let open = checks.filter { $0.workoutID == workout.id && $0.isOpen }
                for check in open { try store.delete(PainCheck.self, id: check.id, at: now()) }
                checks.removeAll { check in open.contains { $0.id == check.id } }
                try store.saveAll(newChecks(for: workout, sets: sets(of: old), end: end))
            }
        }
        reload()
        reapplyImportedSides()   // a Hevy session moved to another day may fall in another injury's span
    }

    public func discardWorkout() {
        guard let workout = active else { return }
        deleteWorkout(workout)
    }

    /// Deletes a workout, its sets, and the pain questions that were still to
    /// be asked about it. Answers already given stay: the pain was real. A
    /// workout with anything logged in it can be restored for 30 days.
    public func deleteWorkout(_ workout: Workout) {
        // Sets laid out from a routine and never touched are last time's numbers, not something logged.
        let worthKeeping = allSets.contains { $0.workoutID == workout.id && !$0.isBlank && $0.planned != true }
        if workout.id == active?.id { holdRun = nil; lastMarkedDone = nil; restAdjust = nil; restSkippedFor = nil }
        attempt {
            try store.deleteWorkout(id: workout.id, at: now(), keeping: worthKeeping)
            for check in checks where check.workoutID == workout.id && !check.isAnswered {
                try store.delete(PainCheck.self, id: check.id, at: now())
            }
        }
        reload()
    }

    /// Workouts deleted on this phone in the last 30 days, newest first.
    public var recentlyDeleted: [DeletedWorkout] {
        _ = revision; _ = tick
        return ((try? store.deletedWorkouts(at: now())) ?? []).map {
            DeletedWorkout(workout: $0.workout, sets: $0.sets.count, deletedAt: $0.deletedAt)
        }
    }

    /// Brings a deleted workout back with its sets. One that was thrown away
    /// in progress comes back finished. Its pain questions are not asked again.
    @discardableResult
    public func restoreWorkout(id: String) -> Bool {
        var restored = false
        attempt { restored = try store.restoreWorkout(id: id, at: now()) }
        reload()
        if restored { reapplyImportedSides() }
        return restored
    }

    // MARK: Injuries and pain

    public func save(_ injury: Injury) {
        var injury = injury
        injury.updatedAt = now()
        attempt {
            try store.save(injury)
            if !injury.isActive {
                // A resolved injury is not asked about any more. What was skipped
                // or left unanswered before then stays: it is part of its record.
                let time = now()
                for check in checks where check.injuryID == injury.id && check.isOpen
                    && check.dueAt.addingTimeInterval(AppModel.window(check.moment)) >= time {
                    try store.delete(PainCheck.self, id: check.id, at: time)
                }
            }
        }
        reload()
        // A log kept for the injured side reads differently once this injury is known.
        reapplyImportedSides()
    }

    /// Deletes an injury with all of its pain readings.
    public func deleteInjury(id: String) {
        attempt { try store.delete(Injury.self, id: id, at: now()) }
        reload()
        reapplyImportedSides()
    }

    /// Pain is 0 to 10 in half points. Anything else typed or dragged is pulled into that range.
    static func cleanPain(_ pain: Double) -> Double? {
        guard pain.isFinite else { return nil }
        let clamped = min(10, max(0, (pain * 2).rounded() / 2))
        return clamped == 0 ? 0 : clamped      // never the negative zero that -0.2 rounds to
    }

    public func answer(_ check: PainCheck, pain: Double, type: PainType? = nil, notes: String = "") {
        guard let clean = AppModel.cleanPain(pain) else {
            lastError = "That pain value is not a number."
            return
        }
        answer([(check: check, pain: clean, type: type, notes: notes)])
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
        checks.append(check)
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
        let sets = (ledgerHistory().map(\.set) + walkingHistory() + activityHistory()).filter { $0.day >= from && $0.day <= end }
        let days = ledger.tissueDays(sets, through: end).filter { end.days(since: $0.day) < 35 && $0.day <= end }
        return (end, sets, days)
    }

    /// Daily tissue load, walking included, for the `days` days ending today.
    func tissueDays(last days: Int) -> (end: Day, days: [TissueDay]) {
        _ = tick
        let end = loadToday
        let from = end.adding(-days - ledger.settings.referenceWindowDays)
        let sets = (ledgerHistory().map(\.set) + walkingHistory() + activityHistory()).filter { $0.day >= from && $0.day <= end }
        return (end, ledger.tissueDays(sets, through: end).filter { end.days(since: $0.day) < days && $0.day <= end })
    }

    /// The first day anything was logged or counted: a set, or steps.
    var firstRecordedDay: Day? {
        let firstSet = allSets.map(\.workoutDay).min()
        let firstSteps = dailyMetrics(MetricName.steps).filter { $0.value > 0 }.map(\.day).min()
        return [firstSet, firstSteps].compactMap { $0 }.min()
    }

    /// How many of the 28 days before a week (ending `end`) have any history
    /// behind them. The usual week is the load of those days as a weekly rate,
    /// so three weeks of history are not read as four with one of them empty.
    func priorDays(before end: Day) -> Int {
        guard let first = firstRecordedDay else { return 0 }
        return min(28, max(0, end.adding(-7).days(since: first) + 1))
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
        let days = priorDays(before: window.end)
        return sides.compactMap { key, value in
            guard let tissue = library.tissue(value.0) else { return nil }
            return TissueWeek(tissue: tissue, side: value.1, week: week[key] ?? 0,
                              usualWeek: days >= 7 ? (prior[key] ?? 0) * 7 / Double(days) : 0)
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
        return TissueDetail(tissue: tissue, side: side, weekEnding: window.end, weekly: weekly, contributions: contributions,
                            priorDays: priorDays(before: window.end))
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
            history = nil; massSeries = nil
            revision += 1
            return metrics.filter { $0.value.isFinite }.count
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    public func dailyMetrics(_ metric: String) -> [DailyMetric] { (try? store.dailyMetrics(metric)) ?? [] }

    /// Stores daily values worked out on the phone (such as the heart-rate
    /// weighting of steps). A value for the same day, metric and source is replaced.
    public func saveDailyMetrics(_ metrics: [DailyMetric]) {
        let usable = metrics.filter { $0.value.isFinite }
        guard !usable.isEmpty else { return }
        attempt { try store.save(usable) }
        history = nil; massSeries = nil
        revision += 1
    }

    // MARK: Body weight

    /// Body weight by day, oldest first: one value a day, the one typed in if
    /// there is one, else the mean of what devices reported.
    public var bodyweightHistory: [(day: Day, kg: Double)] {
        if let massSeries { return massSeries }
        var typed: [Day: Double] = [:], measured: [Day: [Double]] = [:]
        for m in dailyMetrics(MetricName.bodyMass) where m.value > 0 && m.value.isFinite {
            if m.source == MetricName.manualSource { typed[m.day] = m.value } else { measured[m.day, default: []].append(m.value) }
        }
        var byDay = measured.mapValues { $0.reduce(0, +) / Double($0.count) }
        for (day, kg) in typed { byDay[day] = kg }
        let series = byDay.sorted { $0.key < $1.key }.map { (day: $0.key, kg: $0.value) }
        massSeries = series
        return series
    }

    /// Body weight on a day: the latest reading on or before it; before the
    /// first reading, that first one; with no readings, the weight in the
    /// profile. So a weight entered today does not rewrite what a push-up
    /// weighed last spring once there are readings from then.
    public func bodyweightKg(on day: Day) -> Double? {
        let series = bodyweightHistory
        guard let first = series.first else { return profile.bodyweightKg }
        var low = 0, high = series.count - 1, found = first.kg
        while low <= high {
            let mid = (low + high) / 2
            if series[mid].day <= day { found = series[mid].kg; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    /// The profile as it was on a day: its body weight is that day's.
    func profile(on day: Day) -> Profile {
        var dated = profile
        dated.bodyweightKg = bodyweightKg(on: day)
        return dated
    }

    /// Records body weight for a day (today if none is given). The latest
    /// reading is also the profile's weight, which other devices and the Mac read.
    public func logBodyweight(_ kg: Double, on day: Day? = nil) {
        guard kg.isFinite, kg > 0, kg < 500 else {
            lastError = "That body weight is not a usable number."
            return
        }
        let day = day ?? Day(now(), in: zone)
        attempt { try store.save([DailyMetric(day: day, metric: MetricName.bodyMass, value: kg, source: MetricName.manualSource)]) }
        massSeries = nil; history = nil
        if let latest = bodyweightHistory.last, latest.day <= day || profile.bodyweightKg == nil {
            profile.bodyweightKg = latest.kg
        }
        revision += 1
    }

    public func exportJSON() -> Data? { try? store.snapshotJSON(at: now()) }

    public func merge(_ data: Data) -> Int {
        var changed = 0
        attempt { changed = try store.merge(try Store.decodeSnapshot(data)) }
        profile = store.profile
        reload()
        reapplyImportedSides()
        return changed
    }

    // MARK: Records prepared away from the phone

    /// The records in a file that would add to or change what is held here.
    /// Nothing is stored. Throws if the file cannot be read as Rehabit records.
    public func incoming(_ data: Data) throws -> IncomingRecords {
        let file = try Store.decodeSnapshot(data)
        return IncomingRecords(injuries: try store.arriving(file.injuries, reviving: false),
                               workouts: try store.arriving(file.workouts, reviving: false),
                               sets: try store.arriving(file.sets, reviving: false).count,
                               painChecks: try store.arriving(file.painChecks, reviving: false).count,
                               routines: try store.arriving(file.routines, reviving: false),
                               unreadable: file.unreadable.count)
    }

    /// Stores the records `incoming` listed. Such a file can add records and
    /// change them, and nothing else: its deletions, profile and daily values
    /// are ignored, so a file made elsewhere cannot remove anything or alter
    /// settings. Returns how many records changed; a failure is in `lastError`.
    @discardableResult
    public func takeIn(_ data: Data) -> Int {
        var changed = 0
        attempt {
            let file = try Store.decodeSnapshot(data)
            changed = try store.merge(Snapshot(
                schemaVersion: file.schemaVersion, exportedAt: file.exportedAt, profile: profile,
                workouts: try store.arriving(file.workouts, reviving: false),
                sets: try store.arriving(file.sets, reviving: false),
                injuries: try store.arriving(file.injuries, reviving: false),
                painChecks: try store.arriving(file.painChecks, reviving: false),
                routines: try store.arriving(file.routines, reviving: false),
                dailyMetrics: [], tombstones: []))
        }
        reload()
        reapplyImportedSides()
        return changed
    }
}

/// A workout deleted on this phone and still held, so it can be restored.
public struct DeletedWorkout: Identifiable, Equatable, Sendable {
    public let workout: Workout
    public let sets: Int
    public let deletedAt: Date
    public var id: String { workout.id }
}

/// Records prepared away from the phone (by Claude on the Mac, for one) and
/// left for the app to take in: only those that would add to or change the
/// store, so a file already taken in lists nothing.
public struct IncomingRecords: Equatable, Sendable {
    public var injuries: [Injury] = []
    public var workouts: [Workout] = []
    public var sets = 0
    public var painChecks = 0
    public var routines: [Routine] = []
    /// Records in the file this version of the app could not read. They are left out.
    public var unreadable = 0
    public var isEmpty: Bool { injuries.isEmpty && workouts.isEmpty && sets == 0 && painChecks == 0 && routines.isEmpty }
    public var count: Int { injuries.count + workouts.count + sets + painChecks + routines.count }
}

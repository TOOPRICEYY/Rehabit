import Foundation

/// The estimated one-rep max, by the Epley formula: load x (1 + reps / 30).
///
/// Past about twelve reps a set says more about endurance than strength, so the
/// estimate is left out there instead of being stretched. A hold, an unknown
/// load or no load has nothing to estimate from.
public enum OneRepMax {
    public static let repRange: ClosedRange<Double> = 1...12

    public static func epley(loadKg: Double?, reps: Double?) -> Double? {
        guard let loadKg, loadKg > 0, loadKg.isFinite, let reps, repRange.contains(reps) else { return nil }
        return loadKg * (1 + reps / 30)
    }
}

/// One finished session of one exercise on one side: what the progress and
/// records screens chart. Warm-ups are left out of every number here.
public struct ExerciseSession: Identifiable, Equatable, Sendable {
    public let workoutID: String
    public let day: Day
    public let side: Side
    /// The working sets, in the order they were logged.
    public let sets: [WorkoutSet]
    /// The heaviest set of reps; on equal loads, the one with more reps. Nil when
    /// the session was holds only: holding a weight still is a different feat
    /// from lifting it.
    public let topSet: WorkoutSet?
    public let topLoadKg: Double?
    public let bestE1RMKg: Double?
    /// Load in kg x reps over the working sets. A per-hand load done with both
    /// hands counts twice; holds move nothing and add none.
    public let volumeKg: Double
    public let longestHoldSeconds: Double?
    /// The load the longest hold was held at; nil when unknown.
    public let longestHoldLoadKg: Double?
    /// Highest pain reported during a working set; nil when none was recorded.
    public let maxPain: Double?
    public var id: String { workoutID + "|" + side.rawValue }
}

/// What can be beaten. Reps and holds are compared only at the same load, so
/// a lighter day never reads as a record just for being lighter.
public enum RecordKind: String, CaseIterable, Sendable {
    case heaviestLoad
    case bestE1RM
    case mostRepsAtLoad
    case longestHoldAtLoad
}

/// A best value and the session it was set in.
public struct RecordMark: Equatable, Sendable {
    public let value: Double
    public let day: Day
    public let workoutID: String
}

/// A best at one load. `loadKg` is nil for no load or an unknown one, which
/// are kept together: a plank with no weight is the same feat either way.
public struct LoadRecord: Equatable, Sendable {
    public let loadKg: Double?
    /// Reps, or hold seconds.
    public let value: Double
    public let day: Day
    public let workoutID: String
}

/// The bests for one exercise on one side. A tie does not move a record: it
/// stays with the day it was first reached.
public struct ExerciseRecords: Equatable, Sendable {
    /// Heaviest load lifted for at least one rep, in kg.
    public var heaviestLoad: RecordMark?
    public var bestE1RM: RecordMark?
    /// Lightest load first; no load first of all.
    public var mostRepsAtLoad: [LoadRecord]
    public var longestHoldAtLoad: [LoadRecord]
    public var isEmpty: Bool {
        heaviestLoad == nil && bestE1RM == nil && mostRepsAtLoad.isEmpty && longestHoldAtLoad.isEmpty
    }
}

/// How a left side compares with a right one on one day.
public enum SymmetryMeasure: String, Sendable {
    /// Best estimated one-rep max, kg.
    case e1RM
    /// Longest hold x the load held, second-kg.
    case holdLoad
    /// Longest hold in seconds, when neither side had a known load.
    case holdSeconds
}

/// One workout in which the left and the right were both logged as sides of their own.
public struct SymmetryPoint: Identifiable, Equatable, Sendable {
    public let workoutID: String
    public let day: Day
    /// Nil when the two sides have no measure in common (one lifted, one held),
    /// and then both values are nil too: different measures are never divided.
    public let measure: SymmetryMeasure?
    public let left: Double?
    public let right: Double?
    public var id: String { workoutID }

    public func value(on side: Side) -> Double? {
        switch side { case .left: return left; case .right: return right; case .both: return nil }
    }

    /// The injured side's value over the other side's: 1 is even, below 1 the
    /// injured side is behind. It is not weaker over stronger, so a recovery
    /// that overshoots shows as above 1 instead of being folded back.
    public func ratio(injured: Side) -> Double? {
        guard injured != .both, let mine = value(on: injured),
              let other = value(on: injured == .left ? .right : .left), other > 0 else { return nil }
        return mine / other
    }
}

/// One exercise's left-right balance for a one-sided injury, over a window.
public struct SymmetryRow: Identifiable, Equatable, Sendable {
    public let exercise: String
    public let latest: SymmetryPoint
    /// The latest point's ratio, injured side over the other.
    public let ratio: Double?
    /// The ratio at the earliest point in the window, when there are two or more.
    public let firstRatio: Double?
    /// Highest pain during a working set on the injured side in the window.
    public let maxPain: Double?
    public var id: String { exercise }
    /// How far the ratio has moved across the window; positive is closing the gap.
    public var trend: Double? {
        guard let ratio, let firstRatio else { return nil }
        return ratio - firstRatio
    }
}

/// Seven days of training, for the week card.
public struct WeekSummary: Equatable, Sendable {
    public let start: Day
    public let end: Day
    /// Finished workouts begun in the week.
    public let sessions: Int
    public let workingSets: Int
    public let volumeKg: Double
    /// Working sets per body region (Library's tissue regions). A set counts
    /// once for each region whose tissues its pattern loads as a prime mover.
    public let setsByRegion: [String: Int]
}

/// The numbers one set contributes, worked out once.
struct SetFacts {
    let set: WorkoutSet
    let loadKg: Double?
    let e1RM: Double?
    let volumeKg: Double

    init(_ set: WorkoutSet, loadKg: Double?) {
        self.set = set
        self.loadKg = loadKg
        guard set.kind == .reps else {
            e1RM = nil; volumeKg = 0
            return
        }
        e1RM = OneRepMax.epley(loadKg: loadKg, reps: set.reps)
        // A mistyped negative number must not subtract volume.
        let reps = max(0, set.reps ?? 0), load = max(0, loadKg ?? 0)
        let hands: Double = set.convention == .perHand && set.side == .both ? 2 : 1
        volumeKg = load * reps * hands
    }

    var reps: Double? {
        guard set.kind == .reps, let reps = set.reps, reps > 0 else { return nil }
        return reps
    }
    var holdSeconds: Double? {
        guard set.kind == .hold, let seconds = set.holdSeconds, seconds > 0 else { return nil }
        return seconds
    }
    /// A load that was really moved or held, as opposed to none or unknown.
    var realLoad: Double? { loadKg.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
    /// The key loads are grouped by: to the gram, so a load typed the same way twice always matches.
    var loadKey: Int? { realLoad.map { Int(($0 * 1000).rounded()) } }
}

/// Bests built up session by session, oldest first.
struct RecordBook {
    var heaviest: RecordMark?
    var e1RM: RecordMark?
    var reps: [Optional<Int>: LoadRecord] = [:]
    var holds: [Optional<Int>: LoadRecord] = [:]
    /// Strictly more, with room for rounding, so a tie is never a record.
    static func beats(_ value: Double, _ mark: Double?) -> Bool {
        guard let mark else { return false }
        return value > mark + 1e-9
    }

    mutating func add(_ f: SetFacts, day: Day, workoutID: String) {
        if f.reps.map({ $0 >= 1 }) == true, let load = f.realLoad, heaviest == nil || RecordBook.beats(load, heaviest?.value) {
            heaviest = RecordMark(value: load, day: day, workoutID: workoutID)
        }
        if let e = f.e1RM, e1RM == nil || RecordBook.beats(e, e1RM?.value) {
            e1RM = RecordMark(value: e, day: day, workoutID: workoutID)
        }
        if let r = f.reps, reps[f.loadKey] == nil || RecordBook.beats(r, reps[f.loadKey]?.value) {
            reps[f.loadKey] = LoadRecord(loadKg: f.realLoad, value: r, day: day, workoutID: workoutID)
        }
        if let s = f.holdSeconds, holds[f.loadKey] == nil || RecordBook.beats(s, holds[f.loadKey]?.value) {
            holds[f.loadKey] = LoadRecord(loadKg: f.realLoad, value: s, day: day, workoutID: workoutID)
        }
    }

    /// The records this set would take. Each needs an earlier best of the same
    /// kind to beat: a first time at something is not a record.
    func broken(by f: SetFacts) -> [RecordKind] {
        guard !f.set.isWarmup else { return [] }
        var out: [RecordKind] = []
        if f.reps.map({ $0 >= 1 }) == true, let load = f.realLoad, RecordBook.beats(load, heaviest?.value) {
            out.append(.heaviestLoad)
        }
        if let e = f.e1RM, RecordBook.beats(e, e1RM?.value) { out.append(.bestE1RM) }
        if let r = f.reps, RecordBook.beats(r, reps[f.loadKey]?.value) { out.append(.mostRepsAtLoad) }
        if let s = f.holdSeconds, RecordBook.beats(s, holds[f.loadKey]?.value) { out.append(.longestHoldAtLoad) }
        return out
    }

    var records: ExerciseRecords {
        func ordered(_ d: [Optional<Int>: LoadRecord]) -> [LoadRecord] {
            d.values.sorted { ($0.loadKg ?? -1) < ($1.loadKg ?? -1) }
        }
        return ExerciseRecords(heaviestLoad: heaviest, bestE1RM: e1RM,
                               mostRepsAtLoad: ordered(reps), longestHoldAtLoad: ordered(holds))
    }
}

extension ExerciseSession {
    /// Nil when there is no working set: a session of warm-ups only has nothing to show.
    init?(workout: Workout, side: Side, facts: [SetFacts]) {
        let working = facts.filter { !$0.set.isWarmup }.sorted { $0.set.position < $1.set.position }
        guard !working.isEmpty else { return nil }
        workoutID = workout.id
        day = workout.startDay
        self.side = side
        sets = working.map(\.set)
        // Heaviest first, then more reps; on a full tie the earlier set stands.
        let top = working.filter { $0.set.kind == .reps }.reduce(nil as SetFacts?) { best, f in
            guard let best else { return f }
            let a = (f.loadKg ?? -1, f.set.reps ?? -1), b = (best.loadKg ?? -1, best.set.reps ?? -1)
            return a > b ? f : best
        }
        topSet = top?.set
        topLoadKg = top?.loadKg
        bestE1RMKg = working.compactMap(\.e1RM).max()
        volumeKg = working.map(\.volumeKg).reduce(0, +)
        // Longest hold; on equal time, the heavier one.
        let hold = working.filter { $0.holdSeconds != nil }.reduce(nil as SetFacts?) { best, f in
            guard let best else { return f }
            let a = (f.holdSeconds ?? 0, f.realLoad ?? 0), b = (best.holdSeconds ?? 0, best.realLoad ?? 0)
            return a > b ? f : best
        }
        longestHoldSeconds = hold?.holdSeconds
        longestHoldLoadKg = hold?.loadKg
        maxPain = working.compactMap(\.set.pain).max()
    }

    /// The value compared across sides, if both use the same measure.
    static func symmetry(_ left: ExerciseSession, _ right: ExerciseSession) -> (SymmetryMeasure, Double, Double)? {
        if let l = left.bestE1RMKg, let r = right.bestE1RMKg { return (.e1RM, l, r) }
        guard let ls = left.longestHoldSeconds, let rs = right.longestHoldSeconds else { return nil }
        let ll = left.longestHoldLoadKg.flatMap { $0 > 0 ? $0 : nil }
        let rl = right.longestHoldLoadKg.flatMap { $0 > 0 ? $0 : nil }
        switch (ll, rl) {
        case let (l?, r?): return (.holdLoad, ls * l, rs * r)
        case (nil, nil): return (.holdSeconds, ls, rs)
        default: return nil   // a loaded hold against an unloaded one says nothing about balance
        }
    }
}

extension AppModel {
    /// Names are compared the way `previousSets` compares them: case and outer spaces do not matter.
    private static func progressName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func setFacts(_ set: WorkoutSet) -> SetFacts {
        // The ledger only reads the library to turn an entry into kilograms.
        SetFacts(set, loadKg: Ledger(library: library).loadKg(set, profile: profile))
    }

    /// The estimated one-rep max of one set in kg, body-weight share included.
    public func estimatedOneRepMax(_ set: WorkoutSet) -> Double? {
        set.kind == .reps ? setFacts(set).e1RM : nil
    }

    /// Every finished session of an exercise, oldest first: one per workout and
    /// side with at least one working set.
    public func exerciseHistory(_ exercise: String) -> [ExerciseSession] {
        let finished = Dictionary(workouts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        struct Key: Hashable { let workout: String; let side: Side }
        var grouped: [Key: [SetFacts]] = [:]
        for set in sets(named: exercise) where finished[set.workoutID] != nil {
            grouped[Key(workout: set.workoutID, side: set.side), default: []].append(setFacts(set))
        }
        let sideOrder = Dictionary(uniqueKeysWithValues: Side.allCases.enumerated().map { ($1, $0) })
        return grouped.compactMap { key, facts -> (Date, Int, ExerciseSession)? in
            guard let workout = finished[key.workout],
                  let session = ExerciseSession(workout: workout, side: key.side, facts: facts) else { return nil }
            return (workout.start, sideOrder[key.side] ?? 0, session)
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
    }

    private func recordBook(_ sessions: [ExerciseSession]) -> RecordBook {
        var book = RecordBook()
        for session in sessions {
            for set in session.sets { book.add(setFacts(set), day: session.day, workoutID: session.workoutID) }
        }
        return book
    }

    /// The bests for an exercise on one side, over finished workouts.
    public func records(for exercise: String, side: Side) -> ExerciseRecords {
        recordBook(exerciseHistory(exercise).filter { $0.side == side }).records
    }

    /// The records a set beats, against every finished session of its exercise
    /// and side begun before its workout. The set may be in the workout in
    /// progress, so a badge can show while it is logged.
    public func recordsBroken(by set: WorkoutSet) -> [RecordKind] {
        let start = workouts.first { $0.id == set.workoutID }?.start
            ?? (active?.id == set.workoutID ? active?.start : nil)
        let starts = Dictionary(workouts.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
        let before = exerciseHistory(set.exercise).filter { session in
            guard session.side == set.side, session.workoutID != set.workoutID else { return false }
            guard let start, let other = starts[session.workoutID] else { return true }
            return other < start
        }
        var book = recordBook(before)
        // The sets before it in its own workout count too: the second of three
        // equal sets is not a record again.
        if let day = before.last?.day ?? Optional(set.workoutDay) {
            for other in sets(named: set.exercise) where other.workoutID == set.workoutID && other.side == set.side
                && other.id != set.id && other.position < set.position && !other.isWarmup {
                book.add(setFacts(other), day: day, workoutID: set.workoutID)
            }
        }
        return book.broken(by: setFacts(set))
    }

    /// One point per finished workout in which the left and right were both
    /// logged, oldest first.
    public func symmetry(exercise: String) -> [SymmetryPoint] {
        var lefts: [String: ExerciseSession] = [:], order: [ExerciseSession] = []
        var rights: [String: ExerciseSession] = [:]
        for session in exerciseHistory(exercise) {
            switch session.side {
            case .left: lefts[session.workoutID] = session; order.append(session)
            case .right: rights[session.workoutID] = session
            case .both: break
            }
        }
        return order.compactMap { left in
            guard let right = rights[left.workoutID] else { return nil }
            let compared = ExerciseSession.symmetry(left, right)
            return SymmetryPoint(workoutID: left.workoutID, day: left.day, measure: compared?.0,
                                 left: compared?.1, right: compared?.2)
        }
    }

    /// For a one-sided injury: each exercise of the last `days` days that loads
    /// one of its tissues (share 0.25 or more) and was compared left with right
    /// in that time. Empty for an injury on both sides, which has no good side to
    /// compare with.
    public func symmetry(for injury: Injury, days: Int = 28) -> [SymmetryRow] {
        guard injury.side != .both, days > 0 else { return [] }
        let end = progressToday, start = end.adding(-(days - 1))
        let inWindow = { (day: Day) in day >= start && day <= end }
        let tissues = Set(injury.tissues)
        let finished = Set(workouts.map(\.id))
        // The latest spelling of each exercise name names the row.
        var names: [String: (day: Day, name: String)] = [:]
        for set in storedSets where finished.contains(set.workoutID) && inWindow(set.workoutDay) {
            let loads = library.pattern(set.pattern)?.links.contains { $0.share >= 0.25 && tissues.contains($0.tissue) } ?? false
            guard loads else { continue }
            let key = AppModel.progressName(set.exercise)
            if let seen = names[key], seen.day > set.workoutDay { continue }
            names[key] = (set.workoutDay, set.exercise)
        }
        var rows: [SymmetryRow] = []
        for (_, entry) in names {
            let points = symmetry(exercise: entry.name).filter { inWindow($0.day) && $0.measure != nil }
            guard let latest = points.last, let first = points.first else { continue }
            let pain = exerciseHistory(entry.name)
                .filter { $0.side == injury.side && inWindow($0.day) }
                .compactMap(\.maxPain).max()
            rows.append(SymmetryRow(exercise: entry.name, latest: latest, ratio: latest.ratio(injured: injury.side),
                                    firstRatio: points.count >= 2 ? first.ratio(injured: injury.side) : nil,
                                    maxPain: pain))
        }
        return rows.sorted { AppModel.progressName($0.exercise) < AppModel.progressName($1.exercise) }
    }

    /// Today, or a later day a finished session is already dated (after a
    /// flight west), the same rule the load weeks follow.
    private var progressToday: Day {
        _ = tick
        let today = Day(importNow, in: importZone)
        return max(today, workouts.map(\.startDay).max() ?? today)
    }

    /// The seven days ending today, or `weeksAgo` whole weeks before.
    public func weekSummary(weeksAgo: Int = 0) -> WeekSummary {
        let end = progressToday.adding(-7 * max(0, weeksAgo)), start = end.adding(-6)
        let inWeek = Set(workouts.filter { $0.startDay >= start && $0.startDay <= end }.map(\.id))
        var sets = 0, volume = 0.0, regions: [String: Int] = [:]
        for set in storedSets where inWeek.contains(set.workoutID) && !set.isWarmup {
            sets += 1
            volume += setFacts(set).volumeKg
            let prime = (library.pattern(set.pattern)?.links ?? []).filter { $0.role == "prime" }
            for region in Set(prime.compactMap { library.tissue($0.tissue)?.region }) {
                regions[region, default: 0] += 1
            }
        }
        return WeekSummary(start: start, end: end, sessions: inWeek.count, workingSets: sets,
                           volumeKg: volume, setsByRegion: regions)
    }

    /// How many seven-day windows in a row, the latest ending today, each had
    /// at least `minSessions` finished workouts.
    public func weeklyStreak(minSessions: Int = 1) -> Int {
        let needed = max(1, minSessions)
        let days = workouts.map(\.startDay)
        guard let first = days.min() else { return 0 }
        var end = progressToday, streak = 0
        while end >= first {
            let start = end.adding(-6)
            guard days.filter({ $0 >= start && $0 <= end }).count >= needed else { break }
            streak += 1
            end = end.adding(-7)
        }
        return streak
    }
}

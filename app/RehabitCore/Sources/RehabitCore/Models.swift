import Foundation

public enum Side: String, Codable, CaseIterable, Sendable {
    case left, right, both
    /// The sides of the body a set on this side loads.
    public var bodySides: [Side] { self == .both ? [.left, .right] : [self] }
}

public enum SetKind: String, Codable, CaseIterable, Sendable {
    case reps
    /// An isometric hold: the load is held still for a time instead of moved.
    case hold
}

/// What the number typed into the load field means.
public enum LoadConvention: String, Codable, CaseIterable, Sendable {
    case perHand = "per_hand"            // one dumbbell or one cable handle
    case total                           // the whole bar or stack
    case bodyweight                      // no added load
    case bodyweightPlus = "bodyweight_plus"  // body weight plus the number entered
    case bodyweightMinus = "bodyweight_minus"  // body weight less the help an assisted machine gives
}

public enum WeightUnit: String, Codable, CaseIterable, Sendable {
    case lb, kg
    public var kilograms: Double { self == .lb ? 0.45359237 : 1 }
}

/// What a pain feels like. The kind matters as much as the number: a stretch
/// that fades is a different signal from a sharp catch at one point in the range.
///
/// This is an open list, not a closed enum: a word added by a newer version of
/// the app is kept as it is instead of making the whole record unreadable.
public struct PainType: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let ache = PainType(rawValue: "ache")
    public static let sharp = PainType(rawValue: "sharp")
    public static let pulling = PainType(rawValue: "pulling")
    public static let pinching = PainType(rawValue: "pinching")
    public static let burning = PainType(rawValue: "burning")
    public static let tightness = PainType(rawValue: "tightness")
    public static let throbbing = PainType(rawValue: "throbbing")
    public static let tingling = PainType(rawValue: "tingling")
    public static let allCases: [PainType] = [.ache, .sharp, .pulling, .pinching, .burning, .tightness,
                                              .throbbing, .tingling]
}

/// What kind of set it was, beyond an ordinary working set or a warm-up. An
/// open list, like `PainType`: a tag from a newer version is kept as it is.
public struct SetTag: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Done straight after the set before it, at a lighter load, with no rest between.
    public static let drop = SetTag(rawValue: "drop")
    /// Taken until no further rep could be done.
    public static let failure = SetTag(rawValue: "failure")
    public static let allCases: [SetTag] = [.drop, .failure]

    public var label: String {
        switch self {
        case .drop: return "Drop set"
        case .failure: return "To failure"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

public enum RangeOfMotion: String, Codable, CaseIterable, Sendable {
    case full, partial
    case shortOfEndRange = "short_of_end_range"
}

/// Fields every stored record has. `updatedAt` decides which copy wins when two
/// devices have changed the same record.
public protocol Record: Codable, Identifiable, Sendable where ID == String {
    static var kind: String { get }
    var id: String { get }
    var updatedAt: Date { get set }
    /// The record this one belongs to, if any (a set's workout).
    var parentID: String? { get }
    var day: Day? { get }
}

/// The totals a watch keeps for a session that has no sets: a run, a ride,
/// a swim, yoga. Values the watch did not send, or sent as 0, are nil.
public struct ActivitySummary: Codable, Equatable, Sendable {
    /// The watch's own name for the kind, such as Garmin's "running" or "lap_swimming".
    public var type: String
    public var distanceMeters: Double?
    public var averageHeartRate: Double?
    public var maxHeartRate: Double?
    public var calories: Double?
    public var elevationGainMeters: Double?
    public var steps: Double?

    public init(type: String, distanceMeters: Double? = nil, averageHeartRate: Double? = nil, maxHeartRate: Double? = nil,
                calories: Double? = nil, elevationGainMeters: Double? = nil, steps: Double? = nil) {
        self.type = type
        func positive(_ v: Double?) -> Double? { v.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
        self.distanceMeters = positive(distanceMeters); self.averageHeartRate = positive(averageHeartRate)
        self.maxHeartRate = positive(maxHeartRate); self.calories = positive(calories)
        self.elevationGainMeters = positive(elevationGainMeters); self.steps = positive(steps)
    }

    /// "running" → "Running", "lap_swimming" → "Lap swimming", "e_bike_fitness" → "E bike fitness".
    public var name: String {
        let words = type.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return "Activity" }
        return first.uppercased() + words.dropFirst()
    }
}

public struct Workout: Record, Equatable {
    public static let kind = "workout"
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date?
    public var startDay: Day
    public var notes: String
    /// Exercises whose left and right sides were linked or unlinked by hand
    /// in this workout. Kept so a relaunch mid-workout does not forget it.
    public var linkOverrides: [String: Bool]?
    /// Exercises whose linked sides share reps or seconds only: each side keeps
    /// its own weight, as when the injured side works lighter.
    public var linkCountsOnly: [String]?
    /// Groups of exercises done back to back, by name: the rest comes after
    /// the last of a group, not between them.
    public var supersets: [[String]]?
    /// The routine this workout was started from, if any.
    public var routineID: String?
    /// For a session from a watch: sessions logged by hand in the same visit
    /// that the person looked at and chose to keep beside it, by id.
    public var overlapsKept: [String]?
    /// True for a workout laid out ahead from a routine or a repeat: its sets
    /// are a plan until marked done, even before the first is.
    public var planned: Bool?
    /// How hard the whole session felt, 0 to 10 in half points. Nil when not asked or not said.
    public var effort: Double?
    /// For a session from a watch that was not strength training (a run, a
    /// ride, a walk): what kind it was and its totals. Such a session has no sets.
    public var activity: ActivitySummary?
    public var updatedAt: Date
    public var parentID: String? { nil }
    public var day: Day? { startDay }
    /// Minutes from start to end. Nil while in progress, or when the end is not known or not after the start.
    public var minutes: Double? {
        guard let end, end > start else { return nil }
        return end.timeIntervalSince(start) / 60
    }
    /// Effort times minutes: one number for how much a session took, in its
    /// own units. Nil without both. A session from another app has no effort until one is given.
    public var sessionLoad: Double? {
        guard let effort, let minutes else { return nil }
        return effort * minutes
    }

    public init(id: String = UUID().uuidString, title: String = "Workout", start: Date = Date(),
                end: Date? = nil, zone: TimeZone = .current, notes: String = "") {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.startDay = Day(start, in: zone); self.notes = notes; self.updatedAt = start
    }
}

public struct WorkoutSet: Record, Equatable {
    public static let kind = "set"
    public var id: String
    public var workoutID: String
    public var workoutDay: Day
    public var position: Int
    /// The name as shown in the picker. Loads are compared within one name and side.
    public var exercise: String
    /// The movement pattern, which decides the tissues loaded. Nil for an unmapped custom exercise.
    public var pattern: String?
    public var side: Side
    /// True when the side was worked out by rule (from an injury) instead of
    /// logged or noted. Nil in records written before this was kept.
    public var sideInferred: Bool?
    public var kind: SetKind
    public var reps: Double?
    public var holdSeconds: Double?
    public var loadValue: Double?
    public var loadUnit: WeightUnit
    public var convention: LoadConvention
    /// Reps in reserve: how many more could have been done.
    public var repsInReserve: Double?
    /// 0 to 10 in half points. Nil means not recorded, which is never the same as zero.
    public var pain: Double?
    public var painType: PainType?
    public var range: RangeOfMotion?
    public var isWarmup: Bool
    /// When the set was marked done. Nil for a set only planned so far, and
    /// for records from before this was kept or from another app.
    public var completedAt: Date?
    /// Shared by the left and the right set of one round, so removing one half
    /// leaves the other where it was. Nil for a set that is no half of a pair,
    /// and in older records, which are paired in the order they were added.
    public var pairID: String?
    /// A drop set or a set to failure. Nil for an ordinary set; a warm-up is `isWarmup`.
    public var tag: SetTag?
    /// Seconds for each phase of a rep, as written: "3-1-1-0" is three down,
    /// one held, one up, none at the top. Nil when no tempo was set.
    public var tempo: String?
    /// True for a set laid out from a routine or a repeat and not touched
    /// since: its numbers are last time's, not something the person entered.
    public var planned: Bool?
    public var notes: String
    public var updatedAt: Date
    public var parentID: String? { workoutID }
    /// The reps, or for a hold the seconds: what makes it a set that was done.
    public var count: Double? { kind == .hold ? holdSeconds : reps }
    public var isDone: Bool { completedAt != nil }
    /// Nothing was entered: no reps or seconds, no pain, no note, not marked
    /// done. A row added and left alone, which is not a set that was done.
    public var isBlank: Bool {
        let count = kind == .hold ? holdSeconds : reps
        return (count ?? 0) <= 0 && pain == nil && notes.isEmpty && !isDone
    }
    public var day: Day? { workoutDay }

    public init(id: String = UUID().uuidString, workout: Workout, position: Int, exercise: String,
                pattern: String?, side: Side = .both, sideInferred: Bool? = nil, kind: SetKind = .reps,
                reps: Double? = nil,
                holdSeconds: Double? = nil, loadValue: Double? = nil, loadUnit: WeightUnit = .lb,
                convention: LoadConvention = .total, repsInReserve: Double? = nil, pain: Double? = nil,
                painType: PainType? = nil, range: RangeOfMotion? = nil, isWarmup: Bool = false,
                completedAt: Date? = nil, notes: String = "", updatedAt: Date = Date()) {
        self.id = id; self.workoutID = workout.id; self.workoutDay = workout.startDay
        self.position = position; self.exercise = exercise; self.pattern = pattern; self.side = side
        self.sideInferred = sideInferred; self.kind = kind; self.reps = reps; self.holdSeconds = holdSeconds; self.loadValue = loadValue
        self.loadUnit = loadUnit; self.convention = convention; self.repsInReserve = repsInReserve
        self.pain = pain; self.painType = painType; self.range = range; self.isWarmup = isWarmup
        self.completedAt = completedAt; self.notes = notes; self.updatedAt = updatedAt
    }
}

/// One exercise of a routine: what to do, how many rounds, on which sides.
public struct RoutineItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var exercise: String
    public var pattern: String?
    public var convention: LoadConvention
    public var unilateral: Bool
    public var kind: SetKind
    /// "together", "perSide", "leftOnly" or "rightOnly" (`SideMode`).
    public var mode: String
    /// Working rounds, and warm-up rounds before them.
    public var rounds: Int
    public var warmups: Int
    /// Rest after each set, where it differs from the person's default.
    public var restSeconds: Int?
    /// Items with the same number are done back to back, as a superset.
    public var group: Int?
    public var notes: String
    /// The reps, or for a hold the seconds, each working set is to be: a
    /// prescription ("5 holds of 45 seconds"). Nil to start from last time.
    public var targetCount: Double?
    /// The tempo each working set starts with. Nil for none.
    public var tempo: String?

    public init(id: String = UUID().uuidString, exercise: String, pattern: String?, convention: LoadConvention = .total,
                unilateral: Bool = false, kind: SetKind = .reps, mode: String = "together", rounds: Int = 3,
                warmups: Int = 0, restSeconds: Int? = nil, group: Int? = nil, notes: String = "",
                targetCount: Double? = nil, tempo: String? = nil) {
        self.id = id; self.exercise = exercise; self.pattern = pattern; self.convention = convention
        self.unilateral = unilateral; self.kind = kind; self.mode = mode; self.rounds = rounds
        self.warmups = warmups; self.restSeconds = restSeconds; self.group = group; self.notes = notes
        self.targetCount = targetCount; self.tempo = tempo
        self = clamped
    }

    /// The item with counts a workout can be laid out from: no negative
    /// rounds or warm-ups, at least one round of some kind, at most 20 of each.
    public var clamped: RoutineItem {
        var item = self
        item.warmups = min(20, max(0, warmups))
        item.rounds = min(20, max(item.warmups > 0 ? 0 : 1, rounds))
        if let rest = restSeconds { item.restSeconds = min(3600, max(0, rest)) }
        // A target of nothing, or not a number, is no target.
        if let target = targetCount { item.targetCount = target.isFinite && target > 0 ? min(target, 3600) : nil }
        item.tempo = tempo.flatMap { Tempo($0)?.text }
        return item
    }
}

extension RoutineItem {
    private enum CodingKeys: String, CodingKey {
        case id, exercise, pattern, convention, unilateral, kind, mode, rounds, warmups, restSeconds, group, notes
        case targetCount, tempo
    }

    /// Counts read from a file are held to the same limits as counts typed in.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), exercise: try c.decode(String.self, forKey: .exercise),
                  pattern: try c.decodeIfPresent(String.self, forKey: .pattern),
                  convention: (try? c.decode(LoadConvention.self, forKey: .convention)) ?? .total,
                  unilateral: (try? c.decode(Bool.self, forKey: .unilateral)) ?? false,
                  kind: (try? c.decode(SetKind.self, forKey: .kind)) ?? .reps,
                  mode: (try? c.decode(String.self, forKey: .mode)) ?? "together",
                  rounds: (try? c.decode(Int.self, forKey: .rounds)) ?? 3,
                  warmups: (try? c.decode(Int.self, forKey: .warmups)) ?? 0,
                  restSeconds: try? c.decodeIfPresent(Int.self, forKey: .restSeconds),
                  group: try? c.decodeIfPresent(Int.self, forKey: .group),
                  notes: (try? c.decode(String.self, forKey: .notes)) ?? "",
                  targetCount: try? c.decodeIfPresent(Double.self, forKey: .targetCount),
                  tempo: try? c.decodeIfPresent(String.self, forKey: .tempo))
    }
}

/// A session to start from: its exercises in order. Loads are not kept in
/// it; each set starts from what was done last time.
public struct Routine: Record, Equatable {
    public static let kind = "routine"
    public var id: String
    public var name: String
    public var items: [RoutineItem]
    public var notes: String
    public var lastUsed: Date?
    public var updatedAt: Date
    public var parentID: String? { nil }
    public var day: Day? { nil }

    public init(id: String = UUID().uuidString, name: String, items: [RoutineItem] = [], notes: String = "",
                lastUsed: Date? = nil, updatedAt: Date = Date()) {
        self.id = id; self.name = name; self.items = items; self.notes = notes
        self.lastUsed = lastUsed; self.updatedAt = updatedAt
    }
}

public enum OnsetPrecision: String, Codable, CaseIterable, Sendable { case day, week, month }

public struct Injury: Record, Equatable {
    public static let kind = "injury"
    public var id: String
    public var label: String
    public var side: Side
    public var onset: Day
    public var onsetPrecision: OnsetPrecision
    public var tissues: [String]
    public var mechanism: String
    public var notes: String
    /// Set when the injury no longer needs follow-up.
    public var resolvedOn: Day?
    /// The limits and milestones set for this injury by the person or their therapist.
    public var plan: InjuryPlan?
    public var updatedAt: Date
    public var parentID: String? { nil }
    public var day: Day? { onset }
    public var isActive: Bool { resolvedOn == nil }
    /// The first day the injury may have begun, given how exactly its start is
    /// known: an injury dated to a month may have begun on the first of it.
    public var earliestOnset: Day {
        switch onsetPrecision {
        case .day: return onset
        case .week: return onset.adding(-6)
        case .month: return Day(year: onset.components.year, month: onset.components.month, day: 1)
        }
    }

    public init(id: String = UUID().uuidString, label: String, side: Side, onset: Day,
                onsetPrecision: OnsetPrecision = .day, tissues: [String], mechanism: String = "",
                notes: String = "", resolvedOn: Day? = nil, updatedAt: Date = Date()) {
        self.id = id; self.label = label; self.side = side; self.onset = onset
        self.onsetPrecision = onsetPrecision; self.tissues = tissues; self.mechanism = mechanism
        self.notes = notes; self.resolvedOn = resolvedOn; self.updatedAt = updatedAt
    }
}

/// When a pain report is asked for, relative to a session.
public enum PainCheckMoment: String, Codable, CaseIterable, Sendable {
    case afterSession = "after_session"
    case evening
    case nextMorning = "next_morning"
    case hours24 = "24h"
    case hours48 = "48h"
    case baseline          // a daily reading with no session attached
    case flare             // logged by the person when something hurt, outside any schedule

    /// The moment in words, as a question's heading.
    public var label: String {
        switch self {
        case .afterSession: return "Right after the session"
        case .evening: return "That evening"
        case .nextMorning: return "The next morning"
        case .hours24: return "24 hours after"
        case .hours48: return "48 hours after"
        case .baseline: return "Daily check"
        case .flare: return "Flare-up"
        }
    }
}

/// One question about one injury at one moment. It exists from the time it is
/// scheduled; `pain` stays nil until answered, so a skipped check is recorded
/// as missing and never as "no pain".
public struct PainCheck: Record, Equatable {
    public static let kind = "pain_check"
    public var id: String
    public var injuryID: String
    public var workoutID: String?
    public var moment: PainCheckMoment
    public var dueAt: Date
    public var dueDay: Day
    public var answeredAt: Date?
    public var pain: Double?
    public var painType: PainType?
    public var notes: String
    /// "unchanged" when the person said nothing had changed and the value was
    /// copied from their reading before it. Nil for a value they entered.
    public var source: String?
    /// Set when the person chose not to answer. The reading stays missing; it
    /// is only no longer asked for.
    public var skippedAt: Date?
    /// What was going on, for a flare-up: "sleep", "stairs", anything.
    public var context: String?
    public var updatedAt: Date
    public var parentID: String? { injuryID }
    public var day: Day? { dueDay }
    public var isAnswered: Bool { answeredAt != nil }
    /// Still waiting for an answer.
    public var isOpen: Bool { answeredAt == nil && skippedAt == nil }
    public static let unchanged = "unchanged"

    public init(id: String = UUID().uuidString, injuryID: String, workoutID: String?,
                moment: PainCheckMoment, dueAt: Date, zone: TimeZone = .current,
                updatedAt: Date = Date()) {
        self.id = id; self.injuryID = injuryID; self.workoutID = workoutID; self.moment = moment
        self.dueAt = dueAt; self.dueDay = Day(dueAt, in: zone); self.notes = ""
        self.updatedAt = updatedAt
    }
}

/// A daily value from a watch or phone: `hrv_ms`, `resting_hr`, `sleep_minutes`, `steps`.
/// The names match the service's `daily_metric` table.
public struct DailyMetric: Codable, Equatable, Sendable {
    public var day: Day
    public var metric: String
    public var value: Double
    public var source: String
    public init(day: Day, metric: String, value: Double, source: String) {
        self.day = day; self.metric = metric; self.value = value; self.source = source
    }
}

/// Settings the model needs that belong to the person, not the code.
public struct Profile: Codable, Equatable, Sendable {
    public var bodyweightKg: Double?
    public var unit: WeightUnit
    /// Ask once each morning how every active injury is, sessions or not.
    public var dailyCheckIn: Bool
    /// The local hour of the morning questions, 0 to 23.
    public var morningHour: Int
    /// Seconds of rest counted down after a set is marked done. 0 turns the timer off.
    public var defaultRestSeconds: Int
    /// Rest for single exercises, by lowercased name, where it differs from the default.
    public var restSeconds: [String: Int]
    /// A standing note for an exercise, by lowercased name: a cue, a seat
    /// height, what the therapist said. Shown whenever the exercise is.
    public var exerciseNotes: [String: String]
    /// Ask how hard the session felt when it is finished.
    public var askEffort: Bool
    public init(bodyweightKg: Double? = nil, unit: WeightUnit = .lb, dailyCheckIn: Bool = true, morningHour: Int = 8,
                defaultRestSeconds: Int = 120, restSeconds: [String: Int] = [:], exerciseNotes: [String: String] = [:],
                askEffort: Bool = true) {
        self.bodyweightKg = bodyweightKg; self.unit = unit
        self.dailyCheckIn = dailyCheckIn; self.morningHour = min(23, max(0, morningHour))
        self.defaultRestSeconds = max(0, defaultRestSeconds); self.restSeconds = restSeconds
        self.exerciseNotes = exerciseNotes; self.askEffort = askEffort
    }

    private enum CodingKeys: String, CodingKey {
        case bodyweightKg, unit, dailyCheckIn, morningHour, defaultRestSeconds, restSeconds, exerciseNotes, askEffort
    }

    /// An unrecognised unit falls back to pounds; it must not cost the body weight.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bodyweightKg = try? c.decodeIfPresent(Double.self, forKey: .bodyweightKg)
        unit = (try? c.decode(WeightUnit.self, forKey: .unit)) ?? .lb
        dailyCheckIn = (try? c.decodeIfPresent(Bool.self, forKey: .dailyCheckIn)) ?? true
        morningHour = min(23, max(0, (try? c.decodeIfPresent(Int.self, forKey: .morningHour)) ?? 8))
        defaultRestSeconds = max(0, (try? c.decodeIfPresent(Int.self, forKey: .defaultRestSeconds)) ?? 120)
        restSeconds = (try? c.decodeIfPresent([String: Int].self, forKey: .restSeconds)) ?? [:]
        exerciseNotes = (try? c.decodeIfPresent([String: String].self, forKey: .exerciseNotes)) ?? [:]
        askEffort = (try? c.decodeIfPresent(Bool.self, forKey: .askEffort)) ?? true
    }
}

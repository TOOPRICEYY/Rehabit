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

public struct Workout: Record, Equatable {
    public static let kind = "workout"
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date?
    public var startDay: Day
    public var notes: String
    public var updatedAt: Date
    public var parentID: String? { nil }
    public var day: Day? { startDay }

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
    public var notes: String
    public var updatedAt: Date
    public var parentID: String? { workoutID }
    public var day: Day? { workoutDay }

    public init(id: String = UUID().uuidString, workout: Workout, position: Int, exercise: String,
                pattern: String?, side: Side = .both, kind: SetKind = .reps, reps: Double? = nil,
                holdSeconds: Double? = nil, loadValue: Double? = nil, loadUnit: WeightUnit = .lb,
                convention: LoadConvention = .total, repsInReserve: Double? = nil, pain: Double? = nil,
                painType: PainType? = nil, range: RangeOfMotion? = nil, isWarmup: Bool = false,
                notes: String = "", updatedAt: Date = Date()) {
        self.id = id; self.workoutID = workout.id; self.workoutDay = workout.startDay
        self.position = position; self.exercise = exercise; self.pattern = pattern; self.side = side
        self.kind = kind; self.reps = reps; self.holdSeconds = holdSeconds; self.loadValue = loadValue
        self.loadUnit = loadUnit; self.convention = convention; self.repsInReserve = repsInReserve
        self.pain = pain; self.painType = painType; self.range = range; self.isWarmup = isWarmup
        self.notes = notes; self.updatedAt = updatedAt
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
    public var updatedAt: Date
    public var parentID: String? { nil }
    public var day: Day? { onset }
    public var isActive: Bool { resolvedOn == nil }

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
    public var updatedAt: Date
    public var parentID: String? { injuryID }
    public var day: Day? { dueDay }
    public var isAnswered: Bool { answeredAt != nil }

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
    public init(bodyweightKg: Double? = nil, unit: WeightUnit = .lb) {
        self.bodyweightKg = bodyweightKg; self.unit = unit
    }

    private enum CodingKeys: String, CodingKey { case bodyweightKg, unit }

    /// An unrecognised unit falls back to pounds; it must not cost the body weight.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bodyweightKg = try? c.decodeIfPresent(Double.self, forKey: .bodyweightKg)
        unit = (try? c.decode(WeightUnit.self, forKey: .unit)) ?? .lb
    }
}

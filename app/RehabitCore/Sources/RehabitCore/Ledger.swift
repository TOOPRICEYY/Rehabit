import Foundation

/// Tissue load ledger: turns logged sets into a daily dose per tissue and side.
///
///     dose = share x n x (load / reference load) ^ k
///
/// `n` is reps, or hold seconds / 5 for an isometric hold. The reference load is
/// the heaviest load used for that exercise and side in the previous 28 days, so
/// the ratio is 1 at the usual weight. `k` is 2, so a heavier load costs more
/// than the same percentage of extra reps. At the usual weight a dose reads as
/// "effective reps" for that tissue.
///
/// Daily steps count too, as the "walking" pattern (`walkingSets`): each leg
/// takes half the steps, and every `stepsPerEffectiveRep` steps on a leg make
/// one effective rep. Days off the wrist are filled with the median of the 28
/// days before, and the 28 days before the first reading with the median of
/// the first 28 readings, so neither reads as a change in load.
///
/// Recorded activities (a ride, a row, a run) count as one "set" of their own
/// pattern on both sides (`activitySets`):
///
///     effective reps = minutes x rate(type) x intensity
///
/// The rate is effective reps a minute at a moderate effort, from the library.
/// For an activity whose steps the daily count already holds, it is only what
/// the activity adds beyond those steps. Intensity is the heart-rate reserve
/// used, (average - resting) / (max - resting), over that of a moderate effort
/// (0.5), kept between 0.5 and 2, and 1 when a heart rate is unknown. An
/// activity type with no rate (a sauna, a walk, an unnamed "cardio") adds nothing.
///
/// This is a port of the service's `ledger.py` and is held to the same numbers
/// by a shared fixture. The values are starting settings, not measured constants.
public struct LedgerSettings: Sendable {
    public var intensityExponent = 2.0
    public var holdSecondsPerRep = 5.0
    public var referenceWindowDays = 28
    public var acuteDays = 7.0
    public var chronicDays = 28.0
    public var minRatio = 0.25
    public var maxRatio = 3.0
    /// Steps on one leg that count as one effective rep at usual weight.
    public var stepsPerEffectiveRep = 100.0
    public var countSteps = true
    public var countActivities = true
    /// Heart-rate reserve of the moderate effort each activity rate is set at.
    public var activityReferenceReserve = 0.5
    public var activityIntensityMin = 0.5
    public var activityIntensityMax = 2.0
    /// The highest heart rate seen is trusted as the maximum only after this many
    /// recordings, and only when it is this far above the resting rate.
    public var activityMinHRRecordings = 5
    public var activityMinHRRange = 40.0
    public var activityMaxMinutes = 600.0
    public init() {}
}

/// The part of a recorded activity the ledger needs.
public struct LedgerActivity: Sendable, Equatable {
    public var day: Day
    /// The recording's type, such as Garmin's "indoor_cycling".
    public var type: String?
    public var name: String?
    public var minutes: Double?
    public var averageHR: Double?

    public init(day: Day, type: String?, name: String?, minutes: Double?, averageHR: Double?) {
        self.day = day; self.type = type; self.name = name; self.minutes = minutes; self.averageHR = averageHR
    }
}

/// Names a recorded activity's pattern with the service's rules
/// (`library.match_activity`): the type first, then the name when the type
/// matched nothing. A rule with no pattern means the activity adds nothing.
public enum ActivityMatcher {
    private static let rules: [(NSRegularExpression, String)] = Library.standard.activityMatchers.compactMap { rule in
        guard rule.count == 2, let regex = try? NSRegularExpression(pattern: rule[0]) else { return nil }
        return (regex, rule[1])
    }

    public static func pattern(type: String?, name: String?) -> String? {
        for raw in [type, name] {
            let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "_", with: " ")
            guard !text.isEmpty else { continue }
            let whole = NSRange(text.startIndex..., in: text)
            if let found = rules.first(where: { $0.0.firstMatch(in: text, range: whole) != nil }) {
                return found.1.isEmpty ? nil : found.1
            }
        }
        return nil
    }
}

/// The part of a set the ledger needs.
public struct LedgerSet: Sendable {
    public var day: Day
    public var exercise: String
    public var pattern: String?
    public var side: Side
    public var kind: SetKind
    public var reps: Double?
    public var holdSeconds: Double?
    public var loadKg: Double?

    public init(day: Day, exercise: String, pattern: String?, side: Side, kind: SetKind,
                reps: Double?, holdSeconds: Double?, loadKg: Double?) {
        self.day = day; self.exercise = exercise; self.pattern = pattern; self.side = side
        self.kind = kind; self.reps = reps; self.holdSeconds = holdSeconds; self.loadKg = loadKg
    }

    /// Loads are compared within one exercise name on one side.
    var referenceKey: String { exercise.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" + side.rawValue }
}

public struct SetDose: Sendable {
    public let set: LedgerSet
    /// Heaviest load for this exercise and side in the window before the set's day.
    public let referenceKg: Double?
    public let ratio: Double
    public let effectiveReps: Double
    public let dose: Double
}

public struct TissueDay: Sendable, Equatable {
    public let day: Day
    public let tissue: String
    public let side: Side
    public let dose: Double
    public let sets: Double
    public let reps: Double
    /// Exponentially weighted means of the daily dose over about 7 and 28 days.
    public let acute: Double
    public let chronic: Double
}

public struct Ledger: Sendable {
    public let library: Library
    public var settings: LedgerSettings

    public init(library: Library = .standard, settings: LedgerSettings = LedgerSettings()) {
        self.library = library; self.settings = settings
    }

    /// The load in kilograms that a set's entered number stands for.
    public func loadKg(_ set: WorkoutSet, profile: Profile) -> Double? {
        let entered = set.loadValue.map { $0 * set.loadUnit.kilograms }
        let share = library.pattern(set.pattern)?.bodyweightShare ?? 0
        switch set.convention {
        case .perHand, .total:
            return entered
        case .bodyweight:
            return profile.bodyweightKg.map { $0 * share }
        case .bodyweightPlus:
            // Unknown body weight stays unknown. Counting it as zero would make
            // 10 added then 15 added look like a 50 percent jump.
            guard let body = profile.bodyweightKg else { return nil }
            return body * share + (entered ?? 0)
        case .bodyweightMinus:
            // The number is the help: more of it is less lifted. Never below nothing.
            guard let body = profile.bodyweightKg, share > 0 else { return nil }
            return max(0, body * share - (entered ?? 0))
        }
    }

    public func ledgerSet(_ set: WorkoutSet, profile: Profile) -> LedgerSet {
        LedgerSet(day: set.workoutDay, exercise: set.exercise, pattern: set.pattern, side: set.side,
                  kind: set.kind, reps: set.reps, holdSeconds: set.holdSeconds,
                  loadKg: loadKg(set, profile: profile))
    }

    func effectiveReps(_ set: LedgerSet) -> Double {
        // A mistyped negative number must not subtract load.
        max(0, set.kind == .hold ? (set.holdSeconds ?? 0) / settings.holdSecondsPerRep : (set.reps ?? 0))
    }

    public static let walkingPattern = "walking"
    public static let walkingName = "Walking (daily steps)"

    private static func median(_ values: [Double]) -> Double {
        let v = values.sorted(), m = v.count / 2
        return v.count % 2 == 1 ? v[m] : (v[m - 1] + v[m]) / 2
    }

    /// Daily steps (the largest reading of each day) as one walking "set" a day
    /// on both legs, in effective reps per leg.
    public func walkingSets(steps: [Day: Double]) -> [LedgerSet] {
        let readings = steps.filter { $0.value > 0 && $0.value.isFinite }
        guard settings.countSteps, settings.stepsPerEffectiveRep > 0,
              let first = readings.keys.min(), let last = readings.keys.max() else { return [] }
        let warm = Ledger.median(readings.filter { $0.key.days(since: first) < 28 }.map(\.value))
        var out: [LedgerSet] = []
        var day = first.adding(-28)
        while day <= last {
            let value: Double
            if let reading = readings[day] {
                value = reading
            } else if day < first {
                value = warm
            } else {
                let before = (1...28).compactMap { readings[day.adding(-$0)] }
                value = before.isEmpty ? warm : Ledger.median(before)
            }
            out.append(LedgerSet(day: day, exercise: Ledger.walkingName, pattern: Ledger.walkingPattern, side: .both,
                                 kind: .reps, reps: value / 2 / settings.stepsPerEffectiveRep, holdSeconds: nil, loadKg: nil))
            day = day.adding(1)
        }
        return out
    }

    /// How hard an activity was against a moderate effort, from heart-rate reserve.
    /// 1 when any of the three is unknown or they do not make sense together.
    public func activityIntensity(averageHR: Double?, restingHR: Double?, maxHR: Double?) -> Double {
        guard let avg = averageHR, let rest = restingHR, let top = maxHR,
              [avg, rest, top].allSatisfy({ $0.isFinite && $0 > 0 }),
              top - rest >= settings.activityMinHRRange, settings.activityReferenceReserve > 0 else { return 1 }
        let reserve = (avg - rest) / (top - rest)
        return min(settings.activityIntensityMax, max(settings.activityIntensityMin, reserve / settings.activityReferenceReserve))
    }

    /// The median resting heart rate of the 28 days up to and including `day`.
    public static func usualRestingHR(_ resting: [Day: Double], on day: Day) -> Double? {
        let values = resting.filter { (0...28).contains(day.days(since: $0.key)) }.map(\.value)
        return values.isEmpty ? nil : median(values)
    }

    /// The highest heart rate recorded, once there are enough recordings to trust it.
    public func observedMaxHR(_ values: [Double]) -> Double? {
        let seen = values.filter { $0.isFinite && $0 > 0 }
        return seen.count >= settings.activityMinHRRecordings ? seen.max() : nil
    }

    /// Effective reps of one activity on a tissue with share 1.
    public func activityReps(pattern: String?, minutes: Double?, intensity: Double) -> Double {
        guard let pattern, let rate = library.activityRates[pattern], rate > 0,
              let minutes, minutes.isFinite, minutes > 0 else { return 0 }
        return min(minutes, settings.activityMaxMinutes) * rate * intensity
    }

    /// Recorded activities as one "set" each on both sides, in effective reps.
    /// `restingHR` is the day's resting heart rate (the lowest reading of a day);
    /// `maxHR` is the trusted maximum (`observedMaxHR`), if any.
    public func activitySets(_ activities: [LedgerActivity], restingHR: [Day: Double], maxHR: Double?) -> [LedgerSet] {
        guard settings.countActivities else { return [] }
        return activities.compactMap { a in
            let pattern = ActivityMatcher.pattern(type: a.type, name: a.name)
            let intensity = activityIntensity(averageHR: a.averageHR, restingHR: Ledger.usualRestingHR(restingHR, on: a.day),
                                              maxHR: maxHR)
            let reps = activityReps(pattern: pattern, minutes: a.minutes, intensity: intensity)
            guard let pattern, reps > 0 else { return nil }
            return LedgerSet(day: a.day, exercise: library.pattern(pattern)?.name ?? pattern, pattern: pattern, side: .both,
                             kind: .reps, reps: reps, holdSeconds: nil, loadKg: nil)
        }
    }

    /// One record per mapped set, in day order. Sets with no pattern are left out.
    public func setDoses(_ sets: [LedgerSet]) -> [SetDose] {
        let ordered = sets.enumerated()
            .filter { $0.element.pattern != nil }
            .sorted { ($0.element.day, $0.offset) < ($1.element.day, $1.offset) }
            .map(\.element)
        var history: [String: [(day: Day, load: Double)]] = [:]
        var pending: [(key: String, day: Day, load: Double)] = []
        var currentDay: Day?
        var out: [SetDose] = []
        for set in ordered {
            if set.day != currentDay {
                // Loads from one day only become history once the day is over, so a
                // heavy set never lowers the ratio of the sets around it.
                for p in pending { history[p.key, default: []].append((p.day, p.load)) }
                pending = []
                currentDay = set.day
            }
            let key = set.referenceKey
            let windowStart = set.day.adding(-settings.referenceWindowDays)
            let reference = history[key]?.filter { $0.day >= windowStart && $0.day < set.day }
                .map(\.load).max()
            var ratio = 1.0
            if let load = set.loadKg, load > 0, let reference, reference > 0 {
                ratio = min(settings.maxRatio, max(settings.minRatio, load / reference))
            }
            let n = effectiveReps(set)
            out.append(SetDose(set: set, referenceKg: reference, ratio: ratio, effectiveReps: n,
                               dose: n * pow(ratio, settings.intensityExponent)))
            if let load = set.loadKg, load > 0 { pending.append((key, set.day, load)) }
        }
        return out
    }

    /// Daily dose for every tissue and side that was ever loaded, for every day
    /// from the first set to `through` (default: the last set).
    public func tissueDays(_ sets: [LedgerSet], through: Day? = nil) -> [TissueDay] {
        struct Key: Hashable { let tissue: String; let side: Side }
        struct Cell { var dose = 0.0, sets = 0.0, reps = 0.0 }
        let doses = setDoses(sets)
        guard let first = doses.map(\.set.day).min(), let lastSet = doses.map(\.set.day).max() else { return [] }
        let last = max(lastSet, through ?? lastSet)
        var daily: [Key: [Day: Cell]] = [:]
        for record in doses {
            for link in library.pattern(record.set.pattern)?.links ?? [] {
                for side in record.set.side.bodySides {
                    var cell = daily[Key(tissue: link.tissue, side: side)]?[record.set.day] ?? Cell()
                    cell.dose += link.share * record.dose
                    // Walking and recorded activities have no sets or reps to count.
                    if link.role == "prime", record.set.pattern != Ledger.walkingPattern,
                       !library.isActivity(record.set.pattern) {
                        cell.sets += 1
                        cell.reps += record.effectiveReps
                    }
                    daily[Key(tissue: link.tissue, side: side), default: [:]][record.set.day] = cell
                }
            }
        }
        let decayA = exp(-1 / settings.acuteDays), decayC = exp(-1 / settings.chronicDays)
        var out: [TissueDay] = []
        for (key, byDay) in daily {
            var acute = 0.0, chronic = 0.0
            var day = first
            while day <= last {
                let cell = byDay[day] ?? Cell()
                acute = acute * decayA + cell.dose * (1 - decayA)
                chronic = chronic * decayC + cell.dose * (1 - decayC)
                out.append(TissueDay(day: day, tissue: key.tissue, side: key.side, dose: cell.dose,
                                     sets: cell.sets, reps: cell.reps, acute: acute, chronic: chronic))
                day = day.adding(1)
            }
        }
        return out.sorted { ($0.day, $0.tissue, $0.side.rawValue) < ($1.day, $1.tissue, $1.side.rawValue) }
    }
}

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
    public init() {}
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
                    if link.role == "prime" {
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

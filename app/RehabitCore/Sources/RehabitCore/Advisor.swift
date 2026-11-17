import Foundation

/// A plain statement about a set, shown while logging. It says what is true of
/// the load ("12 percent above your heaviest in 28 days"), with its reason. It
/// does not say what to do: progression is the physical therapist's call.
public struct Advice: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case intensityJump = "intensity_jump"
        case layoff = "layoff_no_step_back"
        case reEntry = "re_entry"
        case density
        case injuredTissue = "injured_tissue"
    }
    public let kind: Kind
    public let detail: String
}

public struct AdvisorThresholds: Sendable {
    public var intensityJump = 1.10     // load against the 28-day heaviest
    public var layoffDays = 7           // gap after which the same load is worth a note
    public var reEntryDays = 21         // a tissue unloaded this long, then loaded
    public var minShare = 0.25          // tissues carrying less than this are ignored
    public var densityMinDose = 5.0     // effective reps that count as "loaded"
    public init() {}
}

/// The same rules as the service's exercise and tissue flags, applied to one
/// set before it is saved.
public struct Advisor: Sendable {
    public let ledger: Ledger
    public var thresholds = AdvisorThresholds()

    public init(ledger: Ledger = Ledger()) { self.ledger = ledger }

    public func advice(for candidate: LedgerSet, history: [LedgerSet], injuries: [Injury] = []) -> [Advice] {
        var out: [Advice] = []
        let t = thresholds
        let library = ledger.library
        let earlier = history.filter { $0.day < candidate.day }
        let sameExercise = earlier.filter { $0.referenceKey == candidate.referenceKey && ($0.loadKg ?? 0) > 0 }

        if let load = candidate.loadKg, load > 0 {
            let windowStart = candidate.day.adding(-ledger.settings.referenceWindowDays)
            if let reference = sameExercise.filter({ $0.day >= windowStart }).compactMap(\.loadKg).max(),
               load > reference * t.intensityJump {
                let percent = Int(((load / reference - 1) * 100).rounded())
                out.append(Advice(kind: .intensityJump,
                                  detail: "\(percent) percent above the heaviest in the last 28 days"))
            }
            if let lastDay = sameExercise.map(\.day).max() {
                let gap = candidate.day.days(since: lastDay)
                let lastTop = sameExercise.filter { $0.day == lastDay }.compactMap(\.loadKg).max() ?? 0
                if gap >= t.layoffDays && load >= lastTop * 0.999 {
                    out.append(Advice(kind: .layoff,
                                      detail: "First time in \(gap) days, at the same or a heavier load"))
                }
            }
        }

        let links = (library.pattern(candidate.pattern)?.links ?? []).filter { $0.share >= t.minShare }
        guard !links.isEmpty else { return out }

        // When each tissue and side last carried any load, from the whole history.
        struct Key: Hashable { let tissue: String; let side: Side }
        var lastLoaded: [Key: Day] = [:]
        for set in earlier where ledger.effectiveReps(set) > 0 {
            for link in library.pattern(set.pattern)?.links ?? [] {
                for side in set.side.bodySides {
                    let key = Key(tissue: link.tissue, side: side)
                    if let known = lastLoaded[key], known >= set.day { continue }
                    lastLoaded[key] = set.day
                }
            }
        }
        // Yesterday's dose only needs the sets inside one reference window.
        let yesterday = candidate.day.adding(-1)
        let windowStart = yesterday.adding(-ledger.settings.referenceWindowDays)
        var yesterdayDose: [Key: Double] = [:]
        for record in ledger.setDoses(earlier.filter { $0.day >= windowStart }) where record.set.day == yesterday {
            for link in library.pattern(record.set.pattern)?.links ?? [] {
                for side in record.set.side.bodySides {
                    yesterdayDose[Key(tissue: link.tissue, side: side), default: 0] += link.share * record.dose
                }
            }
        }

        for side in candidate.side.bodySides {
            for link in links {
                let key = Key(tissue: link.tissue, side: side)
                let name = library.tissue(link.tissue)?.name ?? link.tissue
                let where_ = "\(name) (\(side.rawValue))"
                if let last = lastLoaded[key] {
                    let gap = candidate.day.days(since: last)
                    if gap >= t.reEntryDays {
                        out.append(Advice(kind: .reEntry, detail: "\(where_) has had no load for \(gap) days"))
                    }
                }
                if link.role == "prime", (yesterdayDose[key] ?? 0) >= t.densityMinDose {
                    out.append(Advice(kind: .density, detail: "\(where_) was also loaded yesterday"))
                }
                for injury in injuries where injury.isActive && injury.tissues.contains(link.tissue)
                    && (injury.side == side || injury.side == .both) {
                    out.append(Advice(kind: .injuredTissue,
                                      detail: "Loads \(where_): \(injury.label). Record how the \(side.rawValue) side feels on each set."))
                }
            }
        }
        // One line per kind and wording is enough on a small screen.
        var seen = Set<String>()
        return out.filter { seen.insert($0.kind.rawValue + $0.detail).inserted }
    }
}

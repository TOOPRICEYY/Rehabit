import Foundation

/// A workout read from another app, before it becomes records here. Every
/// source (a Hevy export, Garmin) produces these, and one path stores them.
public struct ImportedWorkout: Equatable, Sendable {
    /// Stable within the source, so reading the same export twice adds nothing.
    public var sourceID: String
    public var title: String
    public var start: Date
    public var end: Date?
    public var notes: String
    public var sets: [ImportedSet]

    public init(sourceID: String, title: String, start: Date, end: Date?, notes: String = "",
                sets: [ImportedSet] = []) {
        self.sourceID = sourceID; self.title = title; self.start = start; self.end = end
        self.notes = notes; self.sets = sets
    }
}

public struct ImportedSet: Equatable, Sendable {
    public var exercise: String
    /// Nil when the source does not say, which is the usual case.
    public var side: Side?
    public var kind: SetKind
    public var reps: Double?
    public var holdSeconds: Double?
    public var loadValue: Double?
    public var loadUnit: WeightUnit
    public var isWarmup: Bool
    public var repsInReserve: Double?
    public var pain: Double?
    public var notes: String

    public init(exercise: String, side: Side? = nil, kind: SetKind = .reps, reps: Double? = nil,
                holdSeconds: Double? = nil, loadValue: Double? = nil, loadUnit: WeightUnit = .lb,
                isWarmup: Bool = false, repsInReserve: Double? = nil, pain: Double? = nil, notes: String = "") {
        self.exercise = exercise; self.side = side; self.kind = kind; self.reps = reps
        self.holdSeconds = holdSeconds; self.loadValue = loadValue; self.loadUnit = loadUnit
        self.isWarmup = isWarmup; self.repsInReserve = repsInReserve; self.pain = pain; self.notes = notes
    }
}

public struct ImportSummary: Equatable, Sendable {
    public var workoutsAdded = 0
    public var setsAdded = 0
    /// Workouts already here, or deleted here earlier, and so left alone.
    public var workoutsSkipped = 0
    /// Exercise names with no known movement pattern. Their sets are stored
    /// but add nothing to tissue load until the exercise is mapped.
    public var unmapped: [String] = []
    public var sidesInferred = 0
}

public struct ImportError: Error, CustomStringConvertible, Equatable {
    public let description: String
}

/// Maps another app's exercise name to a movement pattern. The rules are the
/// service's (`library.match_exercise`), read from the shared library file so
/// the two cannot drift: first match wins.
public enum ExerciseMatcher {
    private static let rules: [(NSRegularExpression, String)] = Library.standard.matchers.compactMap { rule in
        guard rule.count == 2, let regex = try? NSRegularExpression(pattern: rule[0]) else { return nil }
        return (regex, rule[1])
    }

    public static func pattern(for name: String) -> String? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text != "unknown" else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        // A rule with no pattern says the name is not a loaded strength exercise: it stays unmapped.
        guard let found = rules.first(where: { $0.0.firstMatch(in: text, range: whole) != nil })?.1, !found.isEmpty else { return nil }
        return found
    }

    /// The catalogue entry with this exact name if there is one, else an entry
    /// built from the name: its pattern from the rules, and the meaning of the
    /// load from the words (a dumbbell weight is per hand).
    public static func entry(for name: String, in library: Library) -> (entry: CatalogueExercise, pattern: String?) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = library.catalogue.first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            return (known, known.pattern)
        }
        let pattern = pattern(for: clean)
        let lower = clean.lowercased()
        let bodyweight = (library.pattern(pattern)?.bodyweightShare ?? 0) > 0
        // An assisted pull-up's number is weight taken off, not added.
        let convention: LoadConvention = bodyweight ? (lower.contains("assist") ? .bodyweightMinus : .bodyweightPlus)
            : lower.contains("dumbbell") ? .perHand : .total
        let oneSided = lower.contains("single") || lower.contains("one arm") || lower.contains("one leg")
        let hold = lower.contains("isometric") || lower.hasSuffix(" hold") || lower.contains("plank") || lower.contains("wall sit")
        return (CatalogueExercise(name: clean, pattern: pattern ?? "", convention: convention, unilateral: oneSided,
                                  kind: hold ? .hold : .reps), pattern)
    }
}

/// Reads a Hevy CSV export: one row per set, workouts told apart by title and start time.
public enum HevyCSV {
    public static let source = "hevy"

    private static let sideNote = try! NSRegularExpression(pattern: "\\b(left|right)\\s+(arm|leg|side|hand)\\b",
                                                           options: .caseInsensitive)
    private static let holdNote = try! NSRegularExpression(pattern: "^\\s*iso", options: .caseInsensitive)
    private static let painNote = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*/\\s*10\\s*pain",
                                                           options: .caseInsensitive)
    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// Splits CSV text into rows of fields. Quoted fields may hold commas,
    /// line breaks and doubled quotes.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, started = false
        var chars = text.makeIterator(), pending: Character?
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return chars.next()
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let after = next() {
                        if after == "\"" { field.append("\"") } else { quoted = false; pending = after }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true; started = true }
            else if c == "," { row.append(field); field = ""; started = true }
            else if c == "\n" || c == "\r" || c == "\r\n" {
                if started || !field.isEmpty { row.append(field); rows.append(row) }
                row = []; field = ""; started = false
            } else { field.append(c); started = true }
        }
        if started || !field.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// "23 Oct 2026, 16:58", read as a clock time in `zone`.
    static func time(_ text: String, zone: TimeZone) -> Date? {
        let parts = text.split(whereSeparator: { " ,:".contains($0) }).map(String.init)
        guard parts.count >= 5, let day = Int(parts[0]), let month = months[String(parts[1].lowercased().prefix(3))],
              let year = Int(parts[2]), let hour = Int(parts[3]), let minute = Int(parts[4]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var c = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        if parts.count >= 6, let second = Int(parts[5]) { c.second = second }
        return calendar.date(from: c)
    }

    private static func firstGroup(_ regex: NSRegularExpression, _ text: String) -> String? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// The side a set's note names ("Left arm", "right leg"), if it names one.
    static func side(inNote note: String) -> Side? {
        firstGroup(sideNote, note).flatMap { Side(rawValue: $0.lowercased()) }
    }

    public static func parse(_ text: String, zone: TimeZone = .current) throws -> [ImportedWorkout] {
        var lines = rows(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard !lines.isEmpty else { throw ImportError(description: "The file is empty.") }
        let header = lines.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let cTitle = column("title"), let cStart = column("start_time"), let cExercise = column("exercise_title") else {
            throw ImportError(description: "This does not look like a Hevy export: the title, start_time or exercise_title column is missing.")
        }
        let cEnd = column("end_time"), cDescription = column("description"), cNotes = column("exercise_notes")
        let cType = column("set_type"), cReps = column("reps"), cDuration = column("duration_seconds"), cRPE = column("rpe")
        let cLb = column("weight_lbs"), cKg = column("weight_kg")
        // Columns Rehabit's own export adds; a Hevy file has neither.
        let cSide = column("side"), cPain = column("pain")

        var order: [String] = [], found: [String: ImportedWorkout] = [:]
        for (index, line) in lines.enumerated() {
            func cell(_ i: Int?) -> String {
                guard let i, i < line.count else { return "" }
                return line[i].trimmingCharacters(in: .whitespaces)
            }
            func number(_ i: Int?) -> Double? {
                guard let v = Double(cell(i)), v.isFinite else { return nil }
                return v
            }
            let title = cell(cTitle), startText = cell(cStart)
            guard let start = time(startText, zone: zone) else {
                throw ImportError(description: "Row \(index + 2) has a start time that could not be read: \"\(startText)\".")
            }
            let key = title + "|" + startText
            if found[key] == nil {
                order.append(key)
                found[key] = ImportedWorkout(sourceID: key, title: title.isEmpty ? "Workout" : title, start: start,
                                             end: time(cell(cEnd), zone: zone), notes: cell(cDescription))
            }
            let name = cell(cExercise)
            guard !name.isEmpty else { continue }
            let note = cell(cNotes)
            var reps = number(cReps), hold = number(cDuration)
            var kind: SetKind = (hold ?? 0) > 0 && (reps ?? 0) == 0 ? .hold : .reps
            // Hevy has no hold field for a weighted exercise, so a hold is logged as reps with a note saying so.
            if kind == .reps, let seconds = reps, seconds > 0,
               holdNote.firstMatch(in: note, range: NSRange(note.startIndex..., in: note)) != nil {
                kind = .hold; hold = seconds; reps = nil
            }
            if kind == .hold { reps = nil } else { hold = nil }
            let named = Side(rawValue: cell(cSide).lowercased())
            let side = named == .left || named == .right ? named : side(inNote: note)
            let rpe = number(cRPE)
            let type = cell(cType).lowercased()
            found[key]?.sets.append(ImportedSet(
                exercise: name, side: side, kind: kind, reps: reps, holdSeconds: hold,
                loadValue: number(cLb) ?? number(cKg), loadUnit: number(cLb) == nil && number(cKg) != nil ? .kg : .lb,
                isWarmup: type == "warmup" || type == "warm_up",
                repsInReserve: rpe.map { max(0, 10 - $0) },
                pain: (number(cPain) ?? firstGroup(painNote, note).flatMap(Double.init)).flatMap { (0...10).contains($0) ? $0 : nil },
                notes: note))
        }
        return order.compactMap { found[$0] }
    }
}

extension AppModel {
    /// A short stable id for a workout from another app: the same workout
    /// always gets the same id, on every device.
    static func importID(source: String, sourceID: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a, which gives the same value on every run
        for byte in sourceID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return source + ":" + String(hash, radix: 16)
    }

    /// How much of an exercise's work must fall on an injured tissue before a
    /// set is read as rehab for that injury. A prime mover is 1.0 and a main
    /// assistant about 0.5; a stabiliser is far below.
    static let rehabShare = 0.5

    /// The side an imported set was done on when the source does not say. This
    /// is how a log kept only for the injured side reads: the set belongs to
    /// the one-sided injury, begun by that day and not yet resolved, whose
    /// tissue the exercise works hardest. A dumbbell press works the chest
    /// harder than the triceps, so with a left chest and a right triceps injury
    /// it is read as left. Between equals the newer injury is taken. An
    /// exercise that moves the body's own weight (a push-up, a bodyweight
    /// squat) uses both sides whatever is injured, so no side is guessed.
    func inferredSide(pattern: String?, on day: Day) -> Side? {
        guard let pattern = library.pattern(pattern), pattern.bodyweightShare == 0 else { return nil }
        let open = injuries.filter { $0.earliestOnset <= day && ($0.resolvedOn.map { $0 >= day } ?? true) }
        return AppModel.hardestWorked(open, by: pattern, minShare: AppModel.rehabShare)?.side
    }

    /// The one-sided injury whose tissue an exercise works hardest, if any
    /// reaches `minShare`. Between equals the first in the list is taken; the
    /// model keeps injuries newest first.
    static func hardestWorked(_ injuries: [Injury], by pattern: Pattern, minShare: Double) -> Injury? {
        var best: (share: Double, injury: Injury)?
        for injury in injuries where injury.side != .both {
            let share = pattern.links.filter { injury.tissues.contains($0.tissue) }.map(\.share).max() ?? 0
            if share >= minShare, share > (best?.share ?? 0) { best = (share, injury) }
        }
        return best?.injury
    }

    /// Works out again which side each set of a Hevy-imported workout was done
    /// on, after the injuries changed. A Hevy log is read as the injured side's
    /// log, so its sides depend on which injuries are known; entering an injury
    /// after the import would otherwise leave those sets filed under both sides.
    /// A side named in the set's own note is kept, and so is a side chosen by
    /// hand (`sideInferred == false`) or a set added by hand to the workout.
    /// Returns how many sets changed.
    @discardableResult
    public func reapplyImportedSides() -> Int {
        let prefix = HevyCSV.source + ":"
        var changed: [WorkoutSet] = []
        for workout in workouts where workout.id.hasPrefix(prefix) {
            for var set in sets(of: workout) where set.id.hasPrefix(workout.id + ":") && set.sideInferred != false {
                let noted = HevyCSV.side(inNote: set.notes)
                let guess = noted == nil ? inferredSide(pattern: set.pattern, on: workout.startDay) : nil
                let side = noted ?? guess ?? .both
                let inferred: Bool? = guess != nil ? true : nil
                if side != set.side || inferred != set.sideInferred {
                    set.side = side
                    set.sideInferred = inferred
                    set.updatedAt = importNow
                    changed.append(set)
                }
            }
        }
        guard !changed.isEmpty else { return 0 }
        attempt { try storeSets(changed) }
        reload()
        return changed.count
    }

    /// Stores workouts read from another app. Reading the same file again adds nothing.
    @discardableResult
    public func importWorkouts(_ imported: [ImportedWorkout], source: String, inferSide: Bool = true) -> ImportSummary {
        var summary = ImportSummary(), unmapped = Set<String>()
        attempt {
            for item in imported {
                let id = AppModel.importID(source: source, sourceID: item.sourceID)
                // A workout with no end would be taken for the one in progress.
                var workout = Workout(id: id, title: item.title, start: item.start, end: item.end ?? item.start,
                                      zone: importZone, notes: item.notes)
                if let end = workout.end, end < workout.start { workout.end = workout.start }
                var sets: [WorkoutSet] = [], inferred = 0
                for (position, s) in item.sets.enumerated() {
                    let match = ExerciseMatcher.entry(for: s.exercise, in: library)
                    if match.pattern == nil { unmapped.insert(match.entry.name) }
                    var side = s.side ?? .both, guessed: Bool?
                    if s.side == nil, inferSide, let guess = inferredSide(pattern: match.pattern, on: workout.startDay) {
                        side = guess; guessed = true; inferred += 1
                    } else if s.side != nil { inferred += 1 }
                    let own = match.entry.convention
                    let bodyweight = own == .bodyweight || own == .bodyweightPlus || own == .bodyweightMinus
                    let convention: LoadConvention = !bodyweight ? own
                        : s.loadValue == nil ? .bodyweight : (own == .bodyweightMinus ? .bodyweightMinus : .bodyweightPlus)
                    sets.append(WorkoutSet(
                        id: id + ":" + String(position), workout: workout, position: position,
                        exercise: match.entry.name, pattern: match.pattern, side: side, sideInferred: guessed,
                        kind: s.kind,
                        reps: s.reps, holdSeconds: s.holdSeconds, loadValue: s.loadValue, loadUnit: s.loadUnit,
                        convention: convention, repsInReserve: s.repsInReserve, pain: s.pain,
                        isWarmup: s.isWarmup, notes: s.notes, updatedAt: workout.start))
                }
                if try storeImported(workout, sets: sets) {
                    summary.workoutsAdded += 1; summary.setsAdded += sets.count; summary.sidesInferred += inferred
                } else { summary.workoutsSkipped += 1 }
            }
        }
        summary.unmapped = unmapped.sorted()
        reload()
        return summary
    }
}

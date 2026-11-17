import Charts
import RehabitCore
import SwiftUI

extension Format {
    /// A weight held in kg, shown in the person's unit: "72.5 lb".
    static func weight(_ kg: Double?, _ unit: WeightUnit, decimals: Bool = true) -> String {
        guard let kg else { return "–" }
        let value = decimals ? (kg / unit.kilograms * 10).rounded() / 10 : (kg / unit.kilograms).rounded()
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit.rawValue)"
    }

    static func date(_ day: Day) -> Date { day.start() }

    /// "1 set", "3 sets".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// "Off", "45 s", "2 min", "2 min 30 s".
    static func restLength(_ seconds: Int) -> String {
        if seconds <= 0 { return "Off" }
        if seconds < 60 { return "\(seconds) s" }
        return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
    }

    static func day(_ day: Day) -> String {
        date(day).formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - Exercise history

/// Every session of one exercise, per side: the top set, the best estimated
/// one-rep max (or the longest hold), volume, pain, and the records.
struct ExerciseHistoryView: View {
    @Environment(AppModel.self) private var model
    let exercise: String

    var body: some View {
        let sessions = model.exerciseHistory(exercise)
        let unit = model.profile.unit
        let sides = Side.allCases.filter { side in sessions.contains { $0.side == side } }
        let holdsOnly = sessions.allSatisfy { $0.bestE1RMKg == nil }
        List {
            if sessions.isEmpty {
                ContentUnavailableView("No finished sessions yet", systemImage: "chart.xyaxis.line",
                                       description: Text("Finish a workout with \(exercise) to see it here."))
            } else {
                Section(holdsOnly ? "Longest hold" : "Best estimated one-rep max") {
                    Chart {
                        ForEach(sessions) { s in
                            if let y = holdsOnly ? s.longestHoldSeconds : s.bestE1RMKg.map({ $0 / unit.kilograms }) {
                                LineMark(x: .value("Day", Format.date(s.day)), y: .value("Value", y))
                                    .foregroundStyle(by: .value("Side", Format.side(s.side)))
                                PointMark(x: .value("Day", Format.date(s.day)), y: .value("Value", y))
                                    .foregroundStyle(by: .value("Side", Format.side(s.side)))
                            }
                        }
                    }
                    .chartYAxisLabel(holdsOnly ? "seconds" : unit.rawValue)
                    .frame(height: 200)
                    .accessibilityLabel(holdsOnly ? "Longest hold over time, per side" : "Best estimated one-rep max over time, per side")
                }
                ForEach(sides, id: \.self) { side in
                    RecordsSection(exercise: exercise, side: side, showSide: sides.count > 1)
                }
                Section("Sessions") {
                    ForEach(sessions.reversed()) { s in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Format.day(s.day)).font(.subheadline.weight(.semibold))
                                if sides.count > 1 || s.side != .both {
                                    Text(s.side == .both ? "both" : Format.side(s.side).lowercased())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let pain = s.maxPain {
                                    Text("pain \(Format.number(pain))").font(.caption).foregroundStyle(Format.painColor(pain))
                                }
                            }
                            Text(summary(s, unit)).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle(exercise)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summary(_ s: ExerciseSession, _ unit: WeightUnit) -> String {
        var parts: [String] = []
        if let top = s.topSet { parts.append("top \(Format.short(top))") }
        if let e = s.bestE1RMKg { parts.append("est. max \(Format.weight(e, unit))") }
        if s.volumeKg > 0 { parts.append("volume \(Format.weight(s.volumeKg, unit))") }
        if let hold = s.longestHoldSeconds {
            parts.append("hold \(Format.number(hold)) s" + (s.longestHoldLoadKg.map { " at \(Format.weight($0, unit))" } ?? ""))
        }
        parts.append("\(s.sets.count) sets")
        return parts.joined(separator: " · ")
    }
}

struct RecordsSection: View {
    @Environment(AppModel.self) private var model
    let exercise: String
    let side: Side
    let showSide: Bool

    var body: some View {
        let r = model.records(for: exercise, side: side)
        let unit = model.profile.unit
        if !r.isEmpty {
            Section(showSide ? "Records, \(side == .both ? "both sides" : Format.side(side).lowercased())" : "Records") {
                if let m = r.heaviestLoad {
                    LabeledContent("Heaviest", value: "\(Format.weight(m.value, unit)) · \(Format.day(m.day))")
                }
                if let m = r.bestE1RM {
                    LabeledContent("Best estimated max", value: "\(Format.weight(m.value, unit)) · \(Format.day(m.day))")
                }
                ForEach(Array(r.mostRepsAtLoad.enumerated()), id: \.offset) { _, rec in
                    LabeledContent("Most reps at \(rec.loadKg.map { Format.weight($0, unit) } ?? "body weight")",
                                   value: "\(Format.number(rec.value)) · \(Format.day(rec.day))")
                }
                ForEach(Array(r.longestHoldAtLoad.enumerated()), id: \.offset) { _, rec in
                    LabeledContent("Longest hold at \(rec.loadKg.map { Format.weight($0, unit) } ?? "no load")",
                                   value: "\(Format.number(rec.value)) s · \(Format.day(rec.day))")
                }
            }
        }
    }
}

/// Every exercise ever logged, most recent first.
struct ExercisesListView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        let names = exercises()
        List(names.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.name) { item in
            NavigationLink {
                ExerciseHistoryView(exercise: item.name)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text("\(Format.count(item.sessions, "session")) · last \(Format.day(item.last))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Exercises")
    }

    private func exercises() -> [(name: String, sessions: Int, last: Day)] {
        var seen: [String: (Set<String>, Day)] = [:]
        for workout in model.workouts {
            for set in model.sets(of: workout) {
                var entry = seen[set.exercise] ?? ([], workout.startDay)
                entry.0.insert(workout.id)
                entry.1 = max(entry.1, workout.startDay)
                seen[set.exercise] = entry
            }
        }
        // Most recently done first; on the same day, by name.
        return seen.map { (name: $0.key, sessions: $0.value.0.count, last: $0.value.1) }
            .sorted { ($0.last, $1.name) > ($1.last, $0.name) }
    }
}

// MARK: - Records in the live workout

extension RecordKind {
    var shortLabel: String {
        switch self {
        case .heaviestLoad: return "heaviest"
        case .bestE1RM: return "best est. max"
        case .mostRepsAtLoad: return "most reps"
        case .longestHoldAtLoad: return "longest hold"
        }
    }
}

// MARK: - Injury: left and right

struct SymmetrySection: View {
    @Environment(AppModel.self) private var model
    let injury: Injury

    var body: some View {
        let rows = model.symmetry(for: injury)
        if injury.side != .both {
            let other: Side = injury.side == .left ? .right : .left
            Section {
                if rows.isEmpty {
                    Text("Log an exercise for this area on each side separately to compare them here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            NavigationLink(row.exercise) { ExerciseHistoryView(exercise: row.exercise) }
                                .font(.subheadline.weight(.semibold))
                        }
                        Text(words(row, other: other)).font(.subheadline)
                        Text(detail(row)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Left and right")
            } footer: {
                Text("The \(Format.side(injury.side).lowercased()) side as a share of the \(Format.side(other).lowercased()), over the last four weeks. A description, not a target.")
            }
        }
    }

    private func words(_ row: SymmetryRow, other: Side) -> String {
        guard let ratio = row.ratio else { return "Not enough to compare yet" }
        var text = "\(Format.side(injury.side)) is \(Int((ratio * 100).rounded()))% of \(Format.side(other).lowercased())"
        if let first = row.firstRatio, abs(first - ratio) >= 0.005 {
            text += ", from \(Int((first * 100).rounded()))% at the start"
        }
        return text
    }

    private func detail(_ row: SymmetryRow) -> String {
        var parts = ["compares \(measure(row.latest.measure))", "last \(Format.day(row.latest.day))"]
        if row.latest.measure == .holdLoad || row.latest.measure == .holdSeconds,
           let l = row.latest.left, let r = row.latest.right {
            let unit = row.latest.measure == .holdSeconds ? " s" : ""
            parts.insert("left \(Format.number((l * 10).rounded() / 10))\(unit), right \(Format.number((r * 10).rounded() / 10))\(unit)", at: 1)
        }
        if let pain = row.maxPain { parts.append("max pain \(Format.number(pain))") }
        return parts.joined(separator: " · ")
    }

    private func measure(_ m: SymmetryMeasure?) -> String {
        switch m {
        case .e1RM: return "estimated max"
        case .holdLoad: return "load held × seconds"
        case .holdSeconds: return "hold time"
        case nil: return "–"
        }
    }
}

// MARK: - A finished workout: how pain settled

struct SettlingSection: View {
    @Environment(AppModel.self) private var model
    let workout: Workout

    var body: some View {
        let items = model.settling(for: workout)
        if !items.isEmpty {
            Section("How it settled") {
                ForEach(items, id: \.injury.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.injury.label).font(.subheadline.weight(.semibold))
                        Text(item.baseline.map { "Before the session: \(Format.number($0))" } ?? "No reading before the session")
                            .font(.caption).foregroundStyle(.secondary)
                        if let during = item.during {
                            Text("Highest during the session: \(Format.number(during))").font(.caption)
                        }
                        ForEach(item.readings) { r in
                            HStack {
                                Text(r.moment.label).font(.caption)
                                Spacer()
                                Text(r.pain.map { Format.number($0) } ?? "not answered")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(r.pain.map { Format.painColor($0) } ?? .secondary)
                            }
                        }
                        Text(outcome(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func outcome(_ item: SessionSettling) -> String {
        guard let s = item.summary else {
            return item.baseline == nil ? "Needs a reading from before a session to compare" : "Needs a later reading"
        }
        var parts: [String] = []
        if let peak = s.peak { parts.append("peak \(Format.number(peak))") }
        if let hours = s.hoursToSettle {
            parts.append("back to baseline after \(Int(hours.rounded())) h")
        } else {
            parts.append(s.answered < s.asked ? "needs a later reading" : "not settled yet")
        }
        parts.append("\(s.answered) of \(s.asked) answered")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Workouts tab: this week

struct WeekHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let week = model.weekSummary()
        let streak = model.weeklyStreak()
        let unit = model.profile.unit
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat("\(week.sessions)", week.sessions == 1 ? "session" : "sessions")
                stat("\(week.workingSets)", "working sets")
                stat(Format.weight(week.volumeKg, unit, decimals: false), "volume")
            }
            if !week.setsByRegion.isEmpty {
                Text(week.setsByRegion.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if streak > 1 {
                Label("\(streak) weeks in a row with a session", systemImage: "calendar").font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

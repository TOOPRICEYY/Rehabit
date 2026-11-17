import Foundation

/// Every finished workout as a spreadsheet, in the columns of a Hevy export,
/// so it opens in the tools that read one and reads back in here.
extension AppModel {
    public func exportCSV() -> String {
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            let rounded = (value * 1000).rounded() / 1000
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = localZone
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        func time(_ date: Date?) -> String {
            guard let date else { return "" }
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
            return "\(c.day ?? 1) \(months[(c.month ?? 1) - 1]) \(c.year ?? 0), \(two(c.hour)):\(two(c.minute)):\(two(c.second))"
        }
        var lines = ["title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,"
                     + "weight_lbs,weight_kg,reps,distance_miles,duration_seconds,rpe,side,pain,pain_type,load_meaning"]
        for workout in workouts.sorted(by: { $0.start < $1.start }) {
            let groups = workout.supersets ?? []
            var index: [String: Int] = [:]
            for set in sets(of: workout) {
                let place = index[set.exercise, default: 0]
                index[set.exercise] = place + 1
                let type = set.isWarmup ? "warmup" : set.tag == .drop ? "dropset" : set.tag == .failure ? "failure" : "normal"
                // A note that names the side, so the side survives a round trip through this format.
                var note = set.notes
                if set.side != .both, HevyCSV.side(inNote: note) == nil {
                    note = (set.side == .left ? "Left side" : "Right side") + (note.isEmpty ? "" : ". " + note)
                }
                let fields: [String] = [
                    quote(workout.title), quote(time(workout.start)), quote(time(workout.end)), quote(workout.notes),
                    quote(set.exercise), groups.firstIndex { $0.contains(set.exercise) }.map(String.init) ?? "", quote(note),
                    String(place), type,
                    set.loadUnit == .lb ? number(set.loadValue) : "", set.loadUnit == .kg ? number(set.loadValue) : "",
                    set.kind == .hold ? "" : number(set.reps), "", set.kind == .hold ? number(set.holdSeconds) : "",
                    number(set.repsInReserve.map { 10 - $0 }), set.side.rawValue, number(set.pain),
                    set.painType?.rawValue ?? "", set.convention.rawValue,
                ]
                lines.append(fields.joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

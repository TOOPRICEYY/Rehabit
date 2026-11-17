import RehabitCore
import SwiftUI

/// This week's recovery measures and the load on injured tissue, each against
/// the person's own usual weeks, in words. It describes; it does not score the
/// week or say whether to train. Shows nothing when there is nothing to compare.
struct RecoveryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let readings = model.recoveryReadings()
        let weeks = model.injuredTissueWeeks().sorted { line($0) < line($1) }
        if !readings.isEmpty || !weeks.isEmpty {
            Section {
                ForEach(readings) { reading in
                    Text(reading.sentence)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(weeks) { week in
                    Text(line(week))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("This week against your usual")
            } footer: {
                Text(footer(readings: !readings.isEmpty, weeks: !weeks.isEmpty))
            }
        }
    }

    /// "Left quadriceps: 1.4× a usual week".
    private func line(_ week: TissueWeek) -> String {
        let name = "\(Format.side(week.side)) \(week.tissue.name.lowercased())"
        if week.week <= 0 { return "\(name): no load this week" }
        guard let ratio = week.ratio else {
            return "\(name): \(model.hasUsualWeek ? "new this week" : "no usual week yet")"
        }
        return "\(name): \(Format.ratio(ratio)) a usual week"
    }

    private func footer(readings: Bool, weeks: Bool) -> String {
        var parts: [String] = []
        if readings { parts.append("Measures are the last 7 days against the 28 days before.") }
        if weeks { parts.append("Injured tissue is this week's load against the mean of the 4 weeks before.") }
        return parts.joined(separator: " ")
    }
}

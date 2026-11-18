import RehabitCore
import SwiftUI

/// This week's recovery measures and the load on injured tissue, each against
/// the person's own usual weeks, in words. It describes; it does not score the
/// week or say whether to train. Before there are readings it says when they come.
struct RecoveryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let readings = model.recoveryReadings()
        let weeks = model.injuredTissueWeeks().sorted { line($0) < line($1) }
        // Always shown: with no readings yet it says when they will appear, so a
        // new person knows the card is coming rather than missing.
        Section {
            if readings.isEmpty {
                Text("This card appears after about three weeks of readings.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            let text = footer(readings: !readings.isEmpty, weeks: !weeks.isEmpty)
            if !text.isEmpty { Text(text) }
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

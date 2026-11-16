import RehabitCore
import SwiftUI

struct CheckInsView: View {
    var body: some View {
        NavigationStack {
            CheckInsList().navigationTitle("Check-ins")
        }
    }
}

/// Pain questions whose time has come. A question left unanswered is kept as
/// missing; it is never filled in as zero.
struct CheckInsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.dueChecks.isEmpty {
                ContentUnavailableView("Nothing to answer", systemImage: "checkmark.circle",
                                       description: Text("Pain check-ins appear here after a session that loads an injury."))
            }
            ForEach(model.dueChecks) { check in
                CheckRow(check: check, injury: model.injuries.first { $0.id == check.injuryID })
            }
        }
    }
}

struct CheckRow: View {
    @Environment(AppModel.self) private var model
    let check: PainCheck
    let injury: Injury?
    @State private var pain = 0.0
    @State private var type: PainType?
    @State private var notes = ""

    var body: some View {
        Section {
            HStack {
                Text("Pain")
                Slider(value: $pain, in: 0...10, step: 0.5)
                Text(Format.number(pain)).monospacedDigit().frame(width: 36)
            }
            Picker("Feels", selection: $type) {
                Text("Not recorded").tag(PainType?.none)
                ForEach(PainType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(PainType?.some($0)) }
            }
            TextField("Notes", text: $notes, axis: .vertical)
            Button("Save") { model.answer(check, pain: pain, type: type, notes: notes) }
        } header: {
            Text("\(injury?.label ?? "Injury") · \(Format.moment(check.moment))")
        } footer: {
            Text("Asked for \(check.dueAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}

import Charts
import RehabitCore
import SwiftUI

struct InjuriesView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                if model.injuries.isEmpty {
                    Text("No injuries recorded.").foregroundStyle(.secondary)
                }
                ForEach(model.injuries) { injury in
                    NavigationLink {
                        InjuryDetailView(injuryID: injury.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(injury.label)
                            Text(injury.isActive ? "Since \(injury.onset.description)" : "Resolved \(injury.resolvedOn?.description ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for injury in offsets.map({ model.injuries[$0] }) { model.deleteInjury(id: injury.id) }
                }
            }
            .navigationTitle("Injuries")
            .toolbar {
                Button { adding = true } label: { Label("Add injury", systemImage: "plus") }
            }
            .sheet(isPresented: $adding) {
                InjuryEditorView(injury: nil)
            }
        }
    }
}

struct InjuryDetailView: View {
    @Environment(AppModel.self) private var model
    let injuryID: String
    @State private var editing = false
    @State private var baseline = 0.0

    var body: some View {
        if let injury = model.injuries.first(where: { $0.id == injuryID }) {
            let history = model.painHistory(for: injury)
            List {
                Section("Pain over time") {
                    if history.isEmpty {
                        Text("No pain readings yet.").foregroundStyle(.secondary)
                    } else {
                        Chart(history) { check in
                            LineMark(x: .value("Time", check.answeredAt ?? check.dueAt),
                                     y: .value("Pain", check.pain ?? 0))
                            PointMark(x: .value("Time", check.answeredAt ?? check.dueAt),
                                      y: .value("Pain", check.pain ?? 0))
                        }
                        .chartYScale(domain: 0...10)
                        .frame(height: 180)
                    }
                }
                Section("Baseline today") {
                    HStack {
                        Slider(value: $baseline, in: 0...10, step: 0.5)
                        Text(Format.number(baseline)).monospacedDigit().frame(width: 36)
                    }
                    Button("Save baseline") { model.logBaseline(injury: injury, pain: baseline) }
                }
                Section("Details") {
                    LabeledContent("Side", value: Format.side(injury.side))
                    LabeledContent("Onset", value: "\(injury.onset.description) (to the \(injury.onsetPrecision.rawValue))")
                    LabeledContent("Tissues", value: injury.tissues.compactMap { model.library.tissue($0)?.name }.joined(separator: ", "))
                    if !injury.mechanism.isEmpty { LabeledContent("How it happened", value: injury.mechanism) }
                    if !injury.notes.isEmpty { Text(injury.notes) }
                }
            }
            .navigationTitle(injury.label)
            .toolbar { Button("Edit") { editing = true } }
            .sheet(isPresented: $editing) { InjuryEditorView(injury: injury) }
        } else {
            ContentUnavailableView("Injury removed", systemImage: "bandage")
        }
    }
}

struct InjuryEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let injury: Injury?
    @State private var label = ""
    @State private var side: Side = .left
    @State private var onset = Date()
    @State private var precision: OnsetPrecision = .day
    @State private var tissues: Set<String> = []
    @State private var mechanism = ""
    @State private var notes = ""
    @State private var resolved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, such as Left pec strain", text: $label)
                    Picker("Side", selection: $side) {
                        Text("Left").tag(Side.left)
                        Text("Right").tag(Side.right)
                        Text("Both").tag(Side.both)
                    }
                    DatePicker("Onset", selection: $onset, displayedComponents: .date)
                    Picker("Date is known to the", selection: $precision) {
                        ForEach(OnsetPrecision.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("How it happened", text: $mechanism, axis: .vertical)
                    TextField("Notes", text: $notes, axis: .vertical)
                    if injury != nil { Toggle("Resolved", isOn: $resolved) }
                }
                Section("Tissues involved") {
                    ForEach(model.library.tissues) { tissue in
                        Button {
                            if tissues.contains(tissue.id) { tissues.remove(tissue.id) } else { tissues.insert(tissue.id) }
                        } label: {
                            HStack {
                                Text(tissue.name).foregroundStyle(.primary)
                                Spacer()
                                if tissues.contains(tissue.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle(injury == nil ? "New injury" : "Edit injury")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || tissues.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let injury else { return }
        label = injury.label; side = injury.side; onset = injury.onset.start()
        precision = injury.onsetPrecision; tissues = Set(injury.tissues)
        mechanism = injury.mechanism; notes = injury.notes; resolved = !injury.isActive
    }

    private func save() {
        var record = injury ?? Injury(label: label, side: side, onset: Day(onset), tissues: [])
        record.label = label.trimmingCharacters(in: .whitespaces)
        record.side = side
        record.onset = Day(onset)
        record.onsetPrecision = precision
        record.tissues = tissues.sorted()
        record.mechanism = mechanism
        record.notes = notes
        record.resolvedOn = resolved ? (record.resolvedOn ?? Day(Date())) : nil
        model.save(record)
        dismiss()
    }
}

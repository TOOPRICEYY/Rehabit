import Charts
import RehabitCore
import SwiftUI

struct InjuriesView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var deleting: Injury?
    @State private var sync = MacSync.shared
    @State private var reviewing = false

    var body: some View {
        NavigationStack {
            List {
                if let waiting = sync.inbox {
                    Section {
                        IncomingCard(records: waiting) { reviewing = true }
                    }
                }
                if model.injuries.isEmpty {
                    Text("No injuries recorded.").foregroundStyle(.secondary)
                }
                ForEach(model.injuries) { injury in
                    NavigationLink {
                        InjuryDetailView(injuryID: injury.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(injury.label)
                            Text("\(injury.side == .both ? "Both sides" : "\(Format.side(injury.side)) side") · \(injury.tissues.compactMap { model.library.tissue($0)?.name }.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(injury.isActive ? "Since \(injury.onset.readable)" : "Resolved \(injury.resolvedOn?.readable ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    deleting = offsets.first.map { model.injuries[$0] }
                }
                let active = model.injuries.filter(\.isActive)
                if active.count > 1 {
                    Section {
                        ShareLink(item: model.reportText(for: active),
                                  subject: Text("Rehabit report: all injuries"),
                                  preview: SharePreview("Rehabit report: all injuries")) {
                            Label("Report for all injuries", systemImage: "doc.on.doc")
                        }
                    } footer: {
                        Text("One document covering the last 4 weeks of the \(active.count) injuries still healing.")
                    }
                }
            }
            .navigationTitle("Injuries")
            .onAppear { sync.checkInbox(model) }
            .toolbar {
                Button { adding = true } label: { Label("Add injury", systemImage: "plus") }
            }
            .sheet(isPresented: $adding) {
                InjuryEditorView(injury: nil)
            }
            .sheet(isPresented: $reviewing) {
                if let waiting = sync.inbox {
                    IncomingRecordsView(records: waiting, onAdd: {
                        sync.takeInbox(model)
                        reviewing = false
                    }, onLater: { reviewing = false })
                }
            }
            .confirmationDialog("Delete \(deleting?.label ?? "this injury") and all of its pain readings?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete injury", role: .destructive) {
                    if let deleting { model.deleteInjury(id: deleting.id) }
                    deleting = nil
                }
            } message: {
                Text("To keep the history, edit the injury and mark it resolved instead.")
            }
        }
    }
}

struct InjuryDetailView: View {
    @Environment(AppModel.self) private var model
    let injuryID: String
    @State private var editing = false
    @State private var baseline: Double?
    @State private var logging = false
    @State private var planning = false

    var body: some View {
        if let injury = model.injuries.first(where: { $0.id == injuryID }) {
            let history = model.painHistory(for: injury)
            List {
                Section("Pain over time") {
                    if history.isEmpty {
                        Text(model.timeline(for: injury, days: 84).contains { $0.setPain != nil }
                             ? "No check-in answers yet. Pain recorded during sets is on the Load and pain chart below."
                             : "No pain readings yet.").foregroundStyle(.secondary)
                    } else {
                        Chart(history) { check in
                            LineMark(x: .value("Time", check.answeredAt ?? check.dueAt),
                                     y: .value("Pain", check.pain ?? 0))
                            PointMark(x: .value("Time", check.answeredAt ?? check.dueAt),
                                      y: .value("Pain", check.pain ?? 0))
                        }
                        .chartYScale(domain: 0...10)
                        .frame(height: 180)
                        ForEach(history.suffix(6).reversed()) { check in
                            HStack {
                                Text(check.moment.label).font(.subheadline)
                                Spacer()
                                Text((check.answeredAt ?? check.dueAt).formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(check.pain.map { Format.number($0) } ?? "–")
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(check.pain.map { Format.painColor($0) } ?? .secondary)
                                    .frame(minWidth: 28, alignment: .trailing)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Section {
                    Button { logging = true } label: { Label("Log pain now", systemImage: "plus.circle") }
                }
                InjuryPlanSections(injury: injury) { planning = true }
                Section("Load and pain") {
                    LoadPainChart(injury: injury)
                    NavigationLink {
                        TherapistReportView(injury: injury)
                    } label: {
                        Label("Report for your therapist", systemImage: "doc.text")
                    }
                }
                SymmetrySection(injury: injury)
                Section("Baseline today") {
                    PainChipStrip(value: $baseline)
                    Button("Save baseline") {
                        if let baseline { model.logBaseline(injury: injury, pain: baseline) }
                        baseline = nil          // the new point appears on the chart above
                    }
                    .disabled(baseline == nil)
                }
                Section("Details") {
                    LabeledContent("Side", value: Format.side(injury.side))
                    LabeledContent("Began", value: IncomingRecordsView.onset(injury))
                    LabeledContent("Tissues", value: injury.tissues.compactMap { model.library.tissue($0)?.name }.joined(separator: ", "))
                    if !injury.mechanism.isEmpty { LabeledContent("How it happened", value: injury.mechanism) }
                    if !injury.notes.isEmpty { Text(injury.notes) }
                }
            }
            .navigationTitle(injury.label)
            .sheet(isPresented: $logging) { LogPainSheet(injuryID: injury.id) }
            .toolbar { Button("Edit") { editing = true } }
            .sheet(isPresented: $editing) { InjuryEditorView(injury: injury) }
            .sheet(isPresented: $planning) { InjuryPlanEditorView(injury: injury) }
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
    /// Nil until the name says which side or the person picks one: never assumed.
    @State private var side: Side?
    /// Nil for a new injury until the person picks the day it began: never assumed to be today.
    @State private var onset: Date?
    @State private var pickingDate = false
    @State private var draftOnset = Date()
    @State private var precision: OnsetPrecision = .day
    @State private var tissues: Set<String> = []
    @State private var mechanism = ""
    @State private var notes = ""
    @State private var resolved = false
    @State private var sideChosen = false

    var body: some View {
        let suggestion = model.library.suggestInjury(named: label)
        let suggested = suggestion.tissues.filter { !tissues.contains($0) }
        NavigationStack {
            Form {
                Section {
                    TextField("Name, such as Left pec strain", text: $label)
                        .onChange(of: label) { _, name in
                            // "Right rotator cuff" means the right side, until a side is picked by hand.
                            guard !sideChosen else { return }
                            side = model.library.suggestInjury(named: name).side
                        }
                    if !suggested.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tissues the name suggests. Tap to add.")
                                .font(.caption).foregroundStyle(.secondary)
                            WrapStack(spacing: 8) {
                                ForEach(suggested, id: \.self) { id in
                                    let name = model.library.tissue(id)?.name ?? id
                                    Button {
                                        tissues.insert(id)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus").imageScale(.small)
                                            Text(name)
                                        }
                                            .font(.subheadline)
                                            .lineLimit(1)
                                            .fixedSize()
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("Add suggested tissue \(name)")
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Side")
                        Picker("Side", selection: Binding(get: { side }, set: { side = $0; sideChosen = true })) {
                            Text("Left").tag(Side?.some(.left))
                            Text("Right").tag(Side?.some(.right))
                            Text("Both").tag(Side?.some(.both))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Side")
                        if side == nil {
                            Text("Choose a side to save.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    onsetRow
                    Picker("Date is known to the", selection: $precision) {
                        ForEach(OnsetPrecision.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("How it happened", text: $mechanism, axis: .vertical)
                    TextField("Notes", text: $notes, axis: .vertical)
                    if injury != nil { Toggle("Resolved", isOn: $resolved) }
                }
                let regions = Dictionary(grouping: model.library.tissues, by: \.region)
                ForEach(regions.keys.sorted(), id: \.self) { region in
                    Section("Tissues · \(region)") {
                        ForEach(regions[region] ?? []) { tissue in
                            Button {
                                if tissues.contains(tissue.id) { tissues.remove(tissue.id) } else { tissues.insert(tissue.id) }
                            } label: {
                                HStack {
                                    Text(tissue.name).foregroundStyle(.primary)
                                    Spacer()
                                    if tissues.contains(tissue.id) { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityAddTraits(tissues.contains(tissue.id) ? .isSelected : [])
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
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || tissues.isEmpty || side == nil
                                  || onset == nil)
                }
            }
            .onAppear(perform: load)
        }
    }

    /// The day it began: picked on purpose for a new injury, kept for one being edited.
    @ViewBuilder private var onsetRow: some View {
        if let chosen = onset {
            DatePicker("Began", selection: Binding(get: { chosen }, set: { onset = $0 }),
                       in: ...Date(), displayedComponents: .date)
        } else if pickingDate {
            VStack(alignment: .leading, spacing: 6) {
                Text("When it began")
                DatePicker("When it began", selection: $draftOnset, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                Button {
                    onset = draftOnset
                    pickingDate = false
                } label: {
                    Text("Use \(Day(draftOnset).readable)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Began")
                    Spacer()
                    Button("Pick the date") {
                        // The calendar opens below the name; the keyboard would cover it.
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        pickingDate = true
                    }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Pick the date it began")
                }
                Text("Choose the day it began to save. A rough day is fine: say below how well it is known.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() {
        guard let injury else { return }
        label = injury.label; side = injury.side; sideChosen = true; onset = injury.onset.start()
        precision = injury.onsetPrecision; tissues = Set(injury.tissues)
        mechanism = injury.mechanism; notes = injury.notes; resolved = !injury.isActive
    }

    private func save() {
        guard let side, let onset else { return }
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

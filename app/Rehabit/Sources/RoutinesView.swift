import RehabitCore
import SwiftUI

// MARK: - Opening the live workout from deeper screens

/// Opens the live workout screen. Set by the Workouts tab, so a routine or a
/// finished workout further down its stack can start a workout and show it.
private struct OpenLiveWorkoutKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var openLiveWorkout: (() -> Void)? {
        get { self[OpenLiveWorkoutKey.self] }
        set { self[OpenLiveWorkoutKey.self] = newValue }
    }
}

/// The alert shown when a workout cannot be started because one is already in progress.
struct WorkoutInProgressAlert: ViewModifier {
    @Binding var isPresented: Bool
    let resume: (() -> Void)?

    func body(content: Content) -> some View {
        content.alert("A workout is in progress", isPresented: $isPresented) {
            if let resume { Button("Resume workout", action: resume) }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Finish or discard it before starting another.")
        }
    }
}

extension View {
    func workoutInProgressAlert(_ isPresented: Binding<Bool>, resume: (() -> Void)?) -> some View {
        modifier(WorkoutInProgressAlert(isPresented: isPresented, resume: resume))
    }
}

enum RoutineFormat {
    static func mode(_ raw: String) -> String {
        switch SideMode(rawValue: raw) {
        case .together: return "Together"
        case .perSide: return "Each side"
        case .leftOnly: return "Left only"
        case .rightOnly: return "Right only"
        case nil: return raw
        }
    }

    /// "Nov 15, 2026", or "Not used yet".
    static func lastUsed(_ routine: Routine) -> String {
        guard let date = routine.lastUsed else { return "Not used yet" }
        return "Last used \(Day(date).readable)"
    }

    /// Superset groups shown as letters, A for the lowest number in use.
    static func groupLetters(_ items: [RoutineItem]) -> [Int: String] {
        let groups = Array(Set(items.compactMap(\.group))).sorted()
        var out: [Int: String] = [:]
        for (index, group) in groups.enumerated() {
            out[group] = index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "\(index + 1)"
        }
        return out
    }

    static func summary(_ item: RoutineItem, letters: [Int: String]) -> String {
        var parts = [Format.count(item.rounds, "round"), mode(item.mode).lowercased()]
        if let target = item.targetCount {
            parts.append(item.kind == .hold ? "\(Format.number(target)) s" : "\(Format.number(target)) reps")
        }
        if item.kind != .hold, let tempo = item.tempo { parts.append("tempo \(tempo)") }
        if item.warmups > 0 { parts.append(Format.count(item.warmups, "warm-up")) }
        if let rest = item.restSeconds { parts.append("rest \(Format.restLength(rest))") }
        if let group = item.group, let letter = letters[group] { parts.append("superset \(letter)") }
        return parts.joined(separator: " · ")
    }

    static let restChoices = [0, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300]
}

// MARK: - Routines list

/// Saved routines: start one, or open it to change it.
struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openLiveWorkout) private var openLive
    @State private var editing: Routine?
    @State private var busy = false
    @State private var deleting: Routine?

    var body: some View {
        List {
            if model.active != nil {
                Section {
                    Label("A workout is in progress. Finish or discard it to start a routine.", systemImage: "info.circle")
                        .font(.subheadline)
                    if let openLive {
                        Button("Resume workout", action: openLive)
                    }
                }
            }
            Section {
                if model.routines.isEmpty {
                    Text("No routines yet. Save a finished workout as a routine from its page, or make a new one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.routines) { routine in
                    row(routine)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = routine }
                        }
                }
            } footer: {
                if !model.routines.isEmpty {
                    Text("Each set starts from what was done in the last session of that exercise.")
                }
            }
        }
        .navigationTitle("Routines")
        .toolbar {
            Button {
                editing = Routine(name: "", items: [])
            } label: {
                Label("New routine", systemImage: "plus")
            }
        }
        .sheet(item: $editing) { routine in
            RoutineEditor(routine: routine, isNew: !model.routines.contains { $0.id == routine.id })
        }
        .workoutInProgressAlert($busy, resume: openLive)
        .confirmationDialog("Delete \(deleting?.name ?? "routine")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete routine", role: .destructive) {
                if let deleting { model.deleteRoutine(id: deleting.id) }
                deleting = nil
            }
        } message: {
            Text("Workouts done from it are kept.")
        }
    }

    private func row(_ routine: Routine) -> some View {
        HStack(spacing: 12) {
            Button {
                editing = routine
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name).font(.headline).foregroundStyle(Color(uiColor: .label))
                    Text("\(Format.count(routine.items.count, "exercise")) · \(RoutineFormat.lastUsed(routine))")
                        .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the routine to change it")
            Button("Start") { start(routine) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Start \(routine.name)")
        }
        .padding(.vertical, 2)
    }

    private func start(_ routine: Routine) {
        guard model.active == nil else { busy = true; return }
        if model.startWorkout(from: routine) {
            RestNotice.askPermissionIfNeeded()
            openLive?()
        } else {
            busy = model.active != nil
        }
    }
}

// MARK: - Routine editor

/// A routine's name and exercises. Nothing is stored until Save.
struct RoutineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Routine
    let isNew: Bool
    @State private var picking = false
    @State private var confirmingDelete = false

    init(routine: Routine, isNew: Bool) {
        _draft = State(initialValue: routine)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Name") {
                    TextField("Routine name", text: $draft.name)
                        .accessibilityLabel("Routine name")
                }
                Section {
                    let letters = RoutineFormat.groupLetters(draft.items)
                    ForEach(draft.items) { item in
                        NavigationLink {
                            RoutineItemEditor(items: $draft.items, itemID: item.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.exercise)
                                Text(RoutineFormat.summary(item, letters: letters))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityActions {
                            Button("Move up") { move(item.id, by: -1) }
                            Button("Move down") { move(item.id, by: 1) }
                        }
                    }
                    .onMove { draft.items.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { draft.items.remove(atOffsets: $0) }
                    Button { picking = true } label: { Label("Add exercise", systemImage: "plus.circle") }
                } header: {
                    Text("Exercises")
                } footer: {
                    if draft.items.count > 1 {
                        Text("Press and hold an exercise to drag it into a new place. Swipe left to remove it.")
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete routine", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "New routine" : "Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.save(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $picking) {
                ExercisePickerView(title: "Add exercise") { exercise, mode in
                    draft.items.append(RoutineItem(exercise: exercise.name, pattern: exercise.pattern,
                                                   convention: exercise.convention, unilateral: exercise.unilateral,
                                                   kind: exercise.kind, mode: mode.rawValue))
                    picking = false
                }
            }
            .confirmationDialog("Delete \(draft.name.isEmpty ? "this routine" : draft.name)?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete routine", role: .destructive) {
                    model.deleteRoutine(id: draft.id)
                    dismiss()
                }
            } message: {
                Text("Workouts done from it are kept.")
            }
        }
    }

    private func move(_ id: String, by step: Int) {
        guard let from = draft.items.firstIndex(where: { $0.id == id }) else { return }
        let to = from + step
        guard draft.items.indices.contains(to) else { return }
        draft.items.swapAt(from, to)
    }
}

/// One exercise of a routine: rounds, warm-ups, sides, rest and superset.
struct RoutineItemEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var items: [RoutineItem]
    let itemID: String

    private var index: Int? { items.firstIndex { $0.id == itemID } }

    var body: some View {
        if let index {
            form(index)
        } else {
            ContentUnavailableView("Exercise removed", systemImage: "trash")
        }
    }

    private func form(_ index: Int) -> some View {
        let item = $items[index]
        let letters = RoutineFormat.groupLetters(items)
        let nextGroup = (items.compactMap(\.group).max() ?? 0) + 1
        let defaultRest = model.profile.defaultRestSeconds
        return Form {
            Section {
                Stepper(value: item.rounds, in: 1...20) {
                    Text("Rounds: \(item.wrappedValue.rounds)")
                }
                .accessibilityLabel("Rounds")
                .accessibilityValue("\(item.wrappedValue.rounds)")
                Stepper(value: item.warmups, in: 0...10) {
                    Text("Warm-ups: \(item.wrappedValue.warmups)")
                }
                .accessibilityLabel("Warm-ups")
                .accessibilityValue("\(item.wrappedValue.warmups)")
            } footer: {
                Text("Warm-up rounds come before the working rounds.")
            }
            RoutineTargetSection(item: item)
            Section {
                Picker("Sides", selection: item.mode) {
                    ForEach(SideMode.allCases, id: \.rawValue) { mode in
                        Text(RoutineFormat.mode(mode.rawValue)).tag(mode.rawValue)
                    }
                }
                Picker("Rest after a set", selection: item.restSeconds) {
                    Text("Default (\(Format.restLength(defaultRest)))").tag(Int?.none)
                    ForEach(Array(Set(RoutineFormat.restChoices + [item.wrappedValue.restSeconds ?? 0])).sorted(), id: \.self) {
                        Text(Format.restLength($0)).tag(Int?.some($0))
                    }
                }
                Picker("Superset", selection: item.group) {
                    Text("None").tag(Int?.none)
                    ForEach(letters.keys.sorted(), id: \.self) { group in
                        Text("Superset \(letters[group] ?? "")").tag(Int?.some(group))
                    }
                    Text("New superset").tag(Int?.some(nextGroup))
                }
            } footer: {
                Text("Exercises in the same superset are done back to back.")
            }
            Section("Notes") {
                TextField("Notes", text: item.notes, axis: .vertical).lineLimit(2...6)
            }
            Section {
                Button("Remove from routine", role: .destructive) {
                    dismiss()
                    items.remove(at: index)
                }
            }
        }
        .navigationTitle(item.wrappedValue.exercise)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The reps (or seconds, for a hold) each working set is to be, and the tempo
/// each rep is done at. A tempo is only kept when it can be read.
private struct RoutineTargetSection: View {
    @Binding var item: RoutineItem
    @State private var tempoText = ""
    /// The tempo saved before this edit, kept while the typed text is not a tempo.
    @State private var savedTempo: String?
    @FocusState private var tempoFocused: Bool
    @ScaledMetric(relativeTo: .body) private var fieldWidth: CGFloat = 72

    private var isHold: Bool { item.kind == .hold }
    private var typedTempo: Tempo? { Tempo(tempoText) }
    private var tempoInvalid: Bool {
        !tempoText.trimmingCharacters(in: .whitespaces).isEmpty && typedTempo == nil
    }

    var body: some View {
        Section {
            HStack {
                Text(isHold ? "Target seconds" : "Target reps")
                Spacer()
                NumberField(title: isHold ? "s" : "reps", value: $item.targetCount, width: fieldWidth, decimal: false)
                    .accessibilityLabel(isHold ? "Target seconds for each hold" : "Target reps for each set")
                    .accessibilityIdentifier("routine-target")
            }
            if !isHold {
                HStack {
                    Text("Tempo")
                    Spacer()
                    TextField("3-1-1-0", text: $tempoText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: fieldWidth * 1.4, maxWidth: fieldWidth * 2.2)
                        .focused($tempoFocused)
                        .submitLabel(.done)
                        .onSubmit { normalise() }
                        .accessibilityLabel("Tempo")
                        .accessibilityHint("Seconds lowering, paused, lifting and paused, such as 3-1-1-0")
                        .accessibilityIdentifier("routine-tempo")
                }
                if tempoInvalid {
                    Label(savedTempo.map { "Not a tempo, so \($0) stays saved. Write three or four numbers, such as 3-1-1-0. X means as fast as possible." }
                          ?? "Not a tempo, so none is saved. Write three or four numbers, such as 3-1-1-0. X means as fast as possible.",
                          systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("routine-tempo-invalid")
                } else if let tempo = typedTempo {
                    Text(tension(tempo))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("routine-tension")
                }
            }
        } header: {
            Text("Target")
        } footer: {
            Text(isHold ? "Leave the target empty to start each hold from last time."
                 : "Leave the target empty to start each set from last time. Tempo is seconds lowering, paused at the bottom, lifting and paused at the top.")
        }
        .onAppear { tempoText = item.tempo ?? ""; savedTempo = item.tempo }
        .onChange(of: tempoText) { _, typed in
            // Emptying the field clears the tempo; text that is not a tempo
            // leaves the last good one in place rather than erasing it.
            let trimmed = typed.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { item.tempo = nil; savedTempo = nil }
            else if let tempo = Tempo(trimmed) { item.tempo = tempo.text; savedTempo = tempo.text }
        }
        .onChange(of: tempoFocused) { _, focused in
            // Shown as it is stored once typing is done: "31x0" becomes "3-1-X-0".
            if !focused {
                // Leaving with text that is not a tempo shows the one kept.
                if tempoInvalid { tempoText = savedTempo ?? "" } else { normalise() }
            }
        }
    }

    private func normalise() {
        if let tempo = typedTempo, tempo.text != tempoText { tempoText = tempo.text }
    }

    /// "Time under tension 40 s a set (5 s a rep)", or per rep without a target.
    private func tension(_ tempo: Tempo) -> String {
        let perRep = Format.number(tempo.secondsPerRep)
        if let reps = item.targetCount, reps > 0 {
            return "Saved as \(tempo.text). Time under tension \(Format.number(reps * tempo.secondsPerRep)) s a set (\(perRep) s a rep)."
        }
        return "Saved as \(tempo.text). Time under tension \(perRep) s a rep."
    }
}

import RehabitCore
import SwiftUI

/// A finished workout, logged here or imported. Read-only until Edit is
/// tapped, so scrolling through history never changes anything by accident.
/// In Edit, changes save as they are made, as in a live workout.
struct WorkoutDetailView: View {
    @Environment(AppModel.self) private var model
    let workoutID: String
    @State private var editing = false
    @State private var editingInfo = false
    @State private var picking = false
    @Environment(\.openLiveWorkout) private var openLive
    @State private var namingRoutine = false
    @State private var routineName = ""
    @State private var savedRoutine: String?
    @State private var replacing: Routine?
    @State private var busy = false

    init(workout: Workout) { workoutID = workout.id }

    private var workout: Workout? { model.workouts.first { $0.id == workoutID } }

    var body: some View {
        if let workout {
            content(workout)
        } else {
            ContentUnavailableView("Workout deleted", systemImage: "trash")
        }
    }

    private func saveRoutine(replacing old: Routine?) {
        guard let workout else { return }
        var routine = model.routine(from: workout, name: routineName)
        if let old { routine.id = old.id }
        model.save(routine)
        savedRoutine = model.routines.first { $0.id == routine.id }?.name ?? routine.name
    }

    private func content(_ workout: Workout) -> some View {
        let sets = model.sets(of: workout)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.start.formatted(date: .complete, time: .shortened)).font(.subheadline)
                    if let end = workout.end, end > workout.start {
                        Text("\(Int(end.timeIntervalSince(workout.start) / 60)) min · \(sets.count) \(sets.count == 1 ? "set" : "sets")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let source = Self.source(workout) {
                        Text("Imported from \(source)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !editing, let effort = workout.effort {
                        Text(Format.effort(effort))
                            .font(.subheadline.weight(.medium))
                            .padding(.top, 2)
                            .accessibilityIdentifier("workout-effort")
                    }
                    if !workout.notes.isEmpty {
                        Text(workout.notes).font(.callout).padding(.top, 4)
                    }
                }
                if editing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workout.effort.map { "How hard it was: \(Format.number($0)) of 10" } ?? "How hard it was: not given")
                            .font(.subheadline)
                            .accessibilityIdentifier("workout-effort")
                        EffortChipStrip(value: Binding(get: { workout.effort },
                                                       set: { model.setEffort($0, for: workout) }))
                        Text("0 is no effort at all, 10 is the hardest you could do. Tap the chosen number to clear it.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if editing {
                    Button { editingInfo = true } label: {
                        Label("Name, notes and times…", systemImage: "pencil")
                    }
                }
            }
            SettlingSection(workout: workout)
            ForEach(ExerciseBlock.blocks(sets)) { block in
                Section {
                    let ordered = block.sets.sorted { $0.position < $1.position }
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, set in
                        if editing {
                            FinishedSetRow(set: set, number: ordered.prefix(index + 1).filter { !$0.isWarmup }.count)
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) { model.removeSet(id: set.id) }
                                }
                        } else {
                            ReadOnlySetRow(set: set)
                        }
                    }
                    if editing, let last = block.sets.max(by: { $0.position < $1.position }) {
                        Button {
                            var added = model.addSet(model.catalogueEntry(for: last), side: last.side, to: workout.id)
                            // Start from the last set's numbers, as a live workout does.
                            if var new = added {
                                new.copyPrescription(from: last, in: new.loadUnit)
                                model.update(new)
                                added = new
                            }
                        } label: {
                            Label("Add set", systemImage: "plus").font(.subheadline.weight(.medium))
                        }
                    }
                } header: {
                    NavigationLink {
                        ExerciseHistoryView(exercise: block.exercise)
                    } label: {
                        HStack(spacing: 4) {
                            Text(block.exercise).font(.headline).foregroundStyle(Color(uiColor: .label))
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .textCase(nil)
                    .accessibilityHint("Shows the history and records for this exercise")
                }
            }
            if editing {
                Section {
                    Button { picking = true } label: { Label("Add exercise", systemImage: "plus.circle") }
                }
            }
        }
        .navigationTitle(workout.title)
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editing ? "Done" : "Edit") {
                    if editing { dismissKeyboard() }
                    editing.toggle()
                }
                .fontWeight(editing ? .semibold : .regular)
            }
            if !editing {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if openLive != nil {
                            Button("Repeat this workout", systemImage: "arrow.clockwise") { repeatWorkout(workout) }
                        }
                        Button("Save as routine…", systemImage: "list.bullet.clipboard") {
                            routineName = workout.title
                            namingRoutine = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Save as routine", isPresented: $namingRoutine) {
            TextField("Routine name", text: $routineName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let existing = model.routine(named: routineName) { replacing = existing } else { saveRoutine(replacing: nil) }
            }
        } message: {
            Text("Keeps the exercises, rounds, sides, supersets and tempo. Each set starts from the last session when the routine is started.")
        }
        .confirmationDialog("A routine called \(replacing?.name ?? "") already exists",
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                            titleVisibility: .visible) {
            Button("Replace it") { saveRoutine(replacing: replacing); replacing = nil }
            Button("Keep both") { saveRoutine(replacing: nil); replacing = nil }
        } message: {
            Text("Replacing keeps its place in Routines and swaps in this workout's exercises.")
        }
        .alert("Routine saved", isPresented: Binding(get: { savedRoutine != nil }, set: { if !$0 { savedRoutine = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(savedRoutine ?? "") is in Routines on the Workouts tab.")
        }
        .workoutInProgressAlert($busy, resume: openLive)
        .sheet(isPresented: $editingInfo) { WorkoutInfoEditor(workout: workout) }
        .sheet(isPresented: $picking) {
            ExercisePickerView(title: "Add exercise") { exercise, mode in
                for side in mode.sides { model.addSet(exercise, side: side, to: workout.id) }
                picking = false
            }
        }
        // Edits are saved as made; leave a fresh export for the Mac shortly after.
        .onChange(of: sets) { _, _ in MacSync.shared.changed(model) }
        .onChange(of: workout) { _, _ in MacSync.shared.changed(model) }
    }

    private func repeatWorkout(_ workout: Workout) {
        guard model.active == nil else { busy = true; return }
        if model.startWorkout(repeating: workout) {
            RestNotice.askPermissionIfNeeded()
            openLive?()
        }
    }

    static func source(_ workout: Workout) -> String? {
        if workout.id.hasPrefix("hevy:") { return "Hevy" }
        if workout.id.hasPrefix("garmin:") { return "Garmin" }
        return nil
    }
}

/// A set as logged, with its side named when it is one side only.
struct ReadOnlySetRow: View {
    let set: WorkoutSet

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.summary(set))
            let marks = [set.tag?.label, set.repsInReserve.map { "RIR \(Format.number($0))" }].compactMap { $0 }
            if !marks.isEmpty {
                Text(marks.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
            if set.side != .both {
                Text("\(Format.side(set.side).lowercased()) side\(set.sideInferred == true ? ", inferred" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !set.notes.isEmpty {
                Text(set.notes).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One set of a finished workout in Edit: side, load × reps (or seconds), pain,
/// and a menu (tap the side chip's neighbour badge, or press and hold the row).
struct FinishedSetRow: View {
    @Environment(AppModel.self) private var model
    let set: WorkoutSet
    var number = 1
    @State private var draft: WorkoutSet
    @ScaledMetric(relativeTo: .body) private var loadWidth: CGFloat = 58
    @ScaledMetric(relativeTo: .body) private var repsWidth: CGFloat = 44

    init(set: WorkoutSet, number: Int = 1) {
        self.set = set
        self.number = number
        _draft = State(initialValue: set)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    menu
                } label: {
                    Text(draft.isWarmup ? "W" : "\(number)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(draft.isWarmup ? Color.orange : Color.primary)
                        .frame(width: 30, height: 30)
                        .background(draft.isWarmup ? Color.orange.opacity(0.15) : Color(.tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel(draft.isWarmup ? "Warm-up set, options" : "Set \(number), options")
                if draft.convention == .bodyweight {
                    Text("BW").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).frame(width: loadWidth)
                } else {
                    NumberField(title: draft.loadUnit.rawValue, value: $draft.loadValue, width: loadWidth)
                        .accessibilityLabel("Weight, \(draft.loadUnit == .lb ? "pounds" : "kilograms")")
                }
                Text("×").foregroundStyle(.secondary).accessibilityHidden(true)
                if draft.kind == .hold {
                    NumberField(title: "s", value: $draft.holdSeconds, width: repsWidth, decimal: false)
                        .accessibilityLabel("Seconds held")
                } else {
                    NumberField(title: "reps", value: $draft.reps, width: repsWidth, decimal: false)
                        .accessibilityLabel("Reps")
                }
                Spacer(minLength: 4)
                sideMenu
            }
            HStack(spacing: 6) {
                PainChip(pain: $draft.pain, type: $draft.painType, context: "Set")
                if draft.sideInferred == true && draft.side != .both {
                    Text("side inferred").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.borderless)
        .contextMenu { menu }
        .onChange(of: draft) { _, changed in model.update(changed) }
        .onChange(of: set) { _, changed in
            var mine = draft
            mine.updatedAt = changed.updatedAt
            if mine != changed { draft = changed }
        }
    }

    private var sideMenu: some View {
        Menu {
            Picker("Side", selection: $draft.side) {
                Text("Both sides").tag(Side.both)
                Text("Left").tag(Side.left)
                Text("Right").tag(Side.right)
            }
        } label: {
            HStack(spacing: 3) {
                Text(draft.side == .both ? "Both" : Format.side(draft.side))
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .accessibilityLabel("Side: \(Format.side(draft.side))")
    }

    @ViewBuilder private var menu: some View {
        Picker("Side", selection: $draft.side) {
            Text("Both sides").tag(Side.both)
            Text("Left").tag(Side.left)
            Text("Right").tag(Side.right)
        }
        Toggle(isOn: $draft.isWarmup) { Label("Warm-up", systemImage: "flame") }
        Picker(selection: $draft.kind) {
            Text("Reps").tag(SetKind.reps)
            Text("Isometric hold").tag(SetKind.hold)
        } label: { Label("Type", systemImage: "repeat") }
        .pickerStyle(.menu)
        Button(role: .destructive) { model.removeSet(id: set.id) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// Title, notes, start and end of a finished workout.
struct WorkoutInfoEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Workout

    init(workout: Workout) { _draft = State(initialValue: workout) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $draft.title)
                DatePicker("Started", selection: $draft.start)
                DatePicker("Ended", selection: Binding(get: { draft.end ?? draft.start }, set: { draft.end = $0 }),
                           in: draft.start...)
                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                }
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.update(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

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

    init(workout: Workout) { workoutID = workout.id }

    private var workout: Workout? { model.workouts.first { $0.id == workoutID } }

    var body: some View {
        if let workout {
            content(workout)
        } else {
            ContentUnavailableView("Workout deleted", systemImage: "trash")
        }
    }

    private func content(_ workout: Workout) -> some View {
        let sets = model.sets(of: workout)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workout.start.formatted(date: .complete, time: .shortened)).font(.subheadline)
                    if let end = workout.end, end > workout.start {
                        Text("\(Int(end.timeIntervalSince(workout.start) / 60)) minutes · \(sets.count) sets")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let source = Self.source(workout) {
                        Text("Imported from \(source)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !workout.notes.isEmpty {
                        Text(workout.notes).font(.callout).padding(.top, 4)
                    }
                }
                if editing {
                    Button { editingInfo = true } label: {
                        Label("Name, notes and times…", systemImage: "pencil")
                    }
                }
            }
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
                                new.copyPrescription(from: last)
                                model.update(new)
                                added = new
                            }
                        } label: {
                            Label("Add set", systemImage: "plus").font(.subheadline.weight(.medium))
                        }
                    }
                } header: {
                    Text(block.exercise).font(.headline).foregroundStyle(Color(uiColor: .label)).textCase(nil)
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
            Button(editing ? "Done" : "Edit") {
                if editing { dismissKeyboard() }
                editing.toggle()
            }
            .fontWeight(editing ? .semibold : .regular)
        }
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

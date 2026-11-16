import RehabitCore
import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(AppModel.self) private var model
    /// Called when the workout is finished or discarded, with the pain checks due right away.
    let onClose: ([PainCheck]) -> Void
    @State private var title = ""
    @State private var pickingExercise = false
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Workout name", text: $title)
                        .onSubmit { model.renameActive(title) }
                }
                ForEach(ExerciseGroup.groups(model.activeSets)) { group in
                    Section {
                        ForEach(Array(group.sets.enumerated()), id: \.element.id) { index, set in
                            SetRow(set: set, number: index + 1)
                        }
                        .onDelete { offsets in
                            for set in offsets.map({ group.sets[$0] }) { model.removeSet(id: set.id) }
                        }
                        Button {
                            if let last = group.sets.last {
                                model.addSet(model.catalogueEntry(for: last), side: group.side)
                            }
                        } label: {
                            Label("Add set", systemImage: "plus")
                        }
                    } header: {
                        Text(group.title)
                    } footer: {
                        PreviousSetsNote(exercise: group.exercise, side: group.side)
                    }
                }
                Section {
                    Button {
                        pickingExercise = true
                    } label: {
                        Label("Add exercise", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { confirmingDiscard = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") {
                        model.renameActive(title)
                        onClose(model.finishWorkout())
                    }
                }
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmingDiscard) {
                Button("Discard workout", role: .destructive) {
                    model.discardWorkout()
                    onClose([])
                }
            }
            .sheet(isPresented: $pickingExercise) {
                ExercisePickerView { exercise, side in
                    model.addSet(exercise, side: side)
                    pickingExercise = false
                }
            }
            .onAppear { title = model.active?.title ?? "" }
        }
    }
}

/// What was done last time for this exercise and side.
struct PreviousSetsNote: View {
    @Environment(AppModel.self) private var model
    let exercise: String
    let side: Side

    var body: some View {
        let previous = model.previousSets(exercise: exercise, side: side)
        if let first = previous.first {
            Text("Last time (\(first.workoutDay.description)): " + previous.map(Format.summary).joined(separator: "; "))
        }
    }
}

/// One set: load, reps or hold, pain, and the details behind a disclosure.
struct SetRow: View {
    @Environment(AppModel.self) private var model
    let number: Int
    @State private var draft: WorkoutSet
    @State private var showingDetails = false

    init(set: WorkoutSet, number: Int) {
        self.number = number
        _draft = State(initialValue: set)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("\(number)").font(.headline).frame(width: 22)
                if draft.convention != .bodyweight {
                    TextField(draft.loadUnit.rawValue, value: $draft.loadValue, format: .number)
                        .keyboardType(.decimalPad)
                        .frame(width: 64)
                        .textFieldStyle(.roundedBorder)
                }
                if draft.kind == .hold {
                    TextField("sec", value: $draft.holdSeconds, format: .number)
                        .keyboardType(.numberPad).frame(width: 56).textFieldStyle(.roundedBorder)
                    Text("s hold").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("reps", value: $draft.reps, format: .number)
                        .keyboardType(.numberPad).frame(width: 56).textFieldStyle(.roundedBorder)
                    Text("reps").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Pain", selection: $draft.pain) {
                    Text("Pain –").tag(Double?.none)
                    ForEach(Format.painSteps, id: \.self) { step in
                        Text("Pain \(Format.number(step))").tag(Double?.some(step))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            ForEach(model.advice(for: draft), id: \.detail) { advice in
                Label(advice.detail, systemImage: advice.kind == .injuredTissue ? "bandage" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(advice.kind == .injuredTissue ? Color.secondary : Color.orange)
            }
            DisclosureGroup("Details", isExpanded: $showingDetails) {
                Picker("Type", selection: $draft.kind) {
                    Text("Reps").tag(SetKind.reps)
                    Text("Isometric hold").tag(SetKind.hold)
                }
                Picker("Load is", selection: $draft.convention) {
                    Text("Per hand").tag(LoadConvention.perHand)
                    Text("Total").tag(LoadConvention.total)
                    Text("Body weight").tag(LoadConvention.bodyweight)
                    Text("Body weight plus").tag(LoadConvention.bodyweightPlus)
                }
                Picker("Unit", selection: $draft.loadUnit) {
                    ForEach(WeightUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Reps in reserve", selection: $draft.repsInReserve) {
                    Text("Not recorded").tag(Double?.none)
                    ForEach([0.0, 1, 2, 3, 4, 5], id: \.self) { Text(Format.number($0)).tag(Double?.some($0)) }
                }
                Picker("Pain feels", selection: $draft.painType) {
                    Text("Not recorded").tag(PainType?.none)
                    ForEach(PainType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(PainType?.some($0)) }
                }
                Picker("Range of motion", selection: $draft.range) {
                    Text("Not recorded").tag(RangeOfMotion?.none)
                    Text("Full").tag(RangeOfMotion?.some(.full))
                    Text("Partial").tag(RangeOfMotion?.some(.partial))
                    Text("Short of end range").tag(RangeOfMotion?.some(.shortOfEndRange))
                }
                Toggle("Warm-up set", isOn: $draft.isWarmup)
                TextField("Notes", text: $draft.notes, axis: .vertical)
            }
            .font(.subheadline)
        }
        .onChange(of: draft) { _, changed in model.update(changed) }
    }
}

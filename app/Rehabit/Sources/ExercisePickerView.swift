import RehabitCore
import SwiftUI

struct ExercisePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onPick: (CatalogueExercise, Side) -> Void
    @State private var search = ""
    @State private var customPattern = ""
    @State private var customOneSided = false
    /// A one-sided exercise waiting for its side to be chosen.
    @State private var asking: CatalogueExercise?

    private var matches: [CatalogueExercise] {
        let words = search.lowercased().split(separator: " ")
        let mine = model.customExercises.filter { entry in
            words.allSatisfy { entry.name.lowercased().contains($0) }
        }
        return mine + model.library.search(search)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matches, id: \.name) { exercise in
                        Button {
                            // A two-sided exercise is logged as both sides. A one-sided
                            // one always asks, so load is never filed under a guessed side.
                            if exercise.unilateral { asking = exercise } else { onPick(exercise, .both) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(exercise.name).foregroundStyle(.primary)
                                Text(subtitle(exercise)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Picker("Movement", selection: $customPattern) {
                            Text("None of these").tag("")
                            ForEach(model.library.patterns) { Text($0.name).tag($0.id) }
                        }
                        Toggle("Done one side at a time", isOn: $customOneSided)
                        Button("Add \"\(search.trimmingCharacters(in: .whitespaces))\"") {
                            let exercise = CatalogueExercise(name: search.trimmingCharacters(in: .whitespaces),
                                                             pattern: customPattern, convention: .total,
                                                             unilateral: customOneSided)
                            if customOneSided { asking = exercise } else { onPick(exercise, .both) }
                        }
                    } header: {
                        Text("Custom exercise")
                    } footer: {
                        Text("The movement decides which tissues the exercise counts toward. With none chosen it is logged but adds no tissue load.")
                    }
                }
            }
            .searchable(text: $search, prompt: "Search or name a new exercise")
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
            .confirmationDialog("Which side?", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                                titleVisibility: .visible, presenting: asking) { exercise in
                let likely = model.likelySide(for: exercise)
                // The side of a matching injury is offered first.
                ForEach(likely == .right ? [Side.right, .left] : [Side.left, .right], id: \.self) { side in
                    Button(Format.side(side)) { onPick(exercise, side) }
                }
                Button("Both together") { onPick(exercise, .both) }
            } message: { _ in
                Text("Log each side by itself when the two sides do different work. You can add the other side afterwards.")
            }
        }
    }

    private func subtitle(_ exercise: CatalogueExercise) -> String {
        let movement = model.library.pattern(exercise.pattern)?.name ?? "No movement set"
        return exercise.unilateral ? "\(movement) · one side" : movement
    }
}

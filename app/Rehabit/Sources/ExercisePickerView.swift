import RehabitCore
import SwiftUI

struct ExercisePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onPick: (CatalogueExercise, Side?) -> Void
    @State private var search = ""
    @State private var side: Side = .both
    @State private var customPattern = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Side", selection: $side) {
                        Text("Both").tag(Side.both)
                        Text("Left").tag(Side.left)
                        Text("Right").tag(Side.right)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Log each side by itself when the two sides do different work.")
                }
                Section {
                    ForEach(model.library.search(search), id: \.name) { exercise in
                        Button {
                            onPick(exercise, side == .both && exercise.unilateral ? nil : side)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(exercise.name).foregroundStyle(.primary)
                                Text(model.library.pattern(exercise.pattern)?.name ?? "")
                                    .font(.caption).foregroundStyle(.secondary)
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
                        Button("Add \"\(search)\"") {
                            onPick(CatalogueExercise(name: search.trimmingCharacters(in: .whitespaces),
                                                     pattern: customPattern, convention: .total,
                                                     unilateral: side != .both), side)
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
        }
    }
}

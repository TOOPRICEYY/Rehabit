import RehabitCore
import SwiftUI

struct ExercisePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var title = "Add exercise"
    let onPick: (CatalogueExercise, SideMode) -> Void
    @State private var search = ""
    @State private var customPattern = ""
    @State private var customOneSided = false
    @State private var customKind = SetKind.reps
    @State private var holdsOnly = false

    private var matches: [CatalogueExercise] {
        let words = search.lowercased().split(separator: " ")
        let mine = model.customExercises.filter { entry in
            words.allSatisfy { entry.name.lowercased().contains($0) }
        }
        let all = mine + model.library.search(search)
        return holdsOnly ? all.filter { $0.kind == .hold } : all
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $holdsOnly) {
                        Label("Isometric holds only", systemImage: "timer")
                    }
                    .toggleStyle(.button)
                    .buttonBorderShape(.capsule)
                    .font(.subheadline)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
                Section {
                    ForEach(matches, id: \.name) { exercise in
                        // One tap adds it the usual way: one-sided exercises as a left
                        // and right pair. A long press offers the other ways.
                        Button {
                            onPick(exercise, model.startingMode(for: exercise))
                        } label: {
                            row(exercise)
                        }
                        .contextMenu {
                            Section("Add \(exercise.name)") {
                                Button { onPick(exercise, .perSide) } label: {
                                    Label("Each side separately", systemImage: "rectangle.split.2x1")
                                }
                                Button { onPick(exercise, .together) } label: {
                                    Label("Both sides together", systemImage: "arrow.left.and.right")
                                }
                                Button { onPick(exercise, .leftOnly) } label: { Label("Left side only", systemImage: "l.square") }
                                Button { onPick(exercise, .rightOnly) } label: { Label("Right side only", systemImage: "r.square") }
                            }
                        }
                    }
                } footer: {
                    if search.isEmpty {
                        Text("Touch and hold an exercise to choose which sides to log.")
                    }
                }
                if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Picker("Movement", selection: $customPattern) {
                            Text("None of these").tag("")
                            ForEach(model.library.exercisePatterns) { Text($0.name).tag($0.id) }
                        }
                        Toggle("Done one side at a time", isOn: $customOneSided)
                        Picker("Sets are", selection: $customKind) {
                            Text("Reps").tag(SetKind.reps)
                            Text("Isometric holds").tag(SetKind.hold)
                        }
                        .pickerStyle(.segmented)
                        Button("Add \"\(search.trimmingCharacters(in: .whitespaces))\"") {
                            let exercise = CatalogueExercise(name: search.trimmingCharacters(in: .whitespaces),
                                                             pattern: customPattern, convention: .total,
                                                             unilateral: customOneSided, kind: customKind)
                            onPick(exercise, customOneSided ? .perSide : .together)
                        }
                    } header: {
                        Text("Custom exercise")
                    } footer: {
                        Text("The movement decides which tissues the exercise counts toward. With none chosen it is logged but adds no tissue load.")
                    }
                }
            }
            .searchable(text: $search, prompt: "Search or name a new exercise")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }

    private func row(_ exercise: CatalogueExercise) -> some View {
        let injured = model.injuredSides(for: exercise)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name).foregroundStyle(.primary)
                Text(subtitle(exercise)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !injured.isEmpty {
                Image(systemName: "bandage.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Loads an injured tissue")
            }
        }
    }

    private func subtitle(_ exercise: CatalogueExercise) -> String {
        let movement = model.library.pattern(exercise.pattern)?.name ?? "No movement set"
        var parts = [movement]
        if exercise.unilateral { parts.append("each side") }
        if exercise.kind == .hold { parts.append("hold") }
        return parts.joined(separator: " · ")
    }
}

import RehabitCore
import SwiftUI

extension Format {
    /// Effort 0 to 10 in half points, the same steps as pain.
    static let effortSteps: [Double] = painSteps

    /// "Effort 7 of 10".
    static func effort(_ effort: Double) -> String { "Effort \(number(effort)) of 10" }
}

/// 0 to 10 in half points as large chips, all on screen at once. Neutral
/// colours: effort is not good or bad. Tapping the chosen chip clears it.
struct EffortChipStrip: View {
    @Binding var value: Double?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(Format.effortSteps, id: \.self) { step in
                let chosen = value == step
                Button {
                    value = chosen ? nil : step
                } label: {
                    Text(Format.number(step))
                        .font(.callout.monospacedDigit().weight(chosen ? .bold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(chosen ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(chosen ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Effort \(Format.number(step))")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// Asked once a workout is finished: how hard the whole session was.
/// Skip leaves the workout with no effort; it can be added later in Edit.
struct EffortPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workout: Workout
    @State private var effort: Double?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    EffortChipStrip(value: $effort)
                        .accessibilityIdentifier("effort-chips")
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How hard was that session?")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color(uiColor: .label))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("effort-question")
                        Text(workout.title).font(.headline).foregroundStyle(Color(uiColor: .label))
                        Text("0 is no effort at all, 10 is the hardest you could do.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textCase(nil)
                } footer: {
                    Text("You can add or change it later on the finished workout, in Edit.")
                }
            }
            .navigationTitle("Session effort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                        .accessibilityHint("Closes without saving an effort")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(effort == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { save() } label: {
                    Text(effort.map { "Save effort \(Format.number($0))" } ?? "Choose a number")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(effort == nil)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier("effort-save")
            }
        }
        .onAppear { effort = workout.effort }
    }

    private func save() {
        guard let effort else { return }
        model.setEffort(effort, for: workout)
        dismiss()
    }
}

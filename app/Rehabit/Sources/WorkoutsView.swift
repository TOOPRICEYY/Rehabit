import RehabitCore
import SwiftUI

struct WorkoutsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingActive = false
    @State private var showingChecks = false
    @State private var checksWaiting = false
    @State private var busy = false
    /// The workout waiting for the person to confirm its deletion.
    @State private var pendingDelete: Workout?
    /// The workout just deleted, while the Undo banner shows.
    @State private var undoable: Workout?
    @State private var undoTask: Task<Void, Never>?
    @State private var reviewingOverlaps = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if model.active == nil {
                            model.startWorkout()
                            // Asked now, before the first set, rather than under the bar
                            // when the first rest starts.
                            RestNotice.askPermissionIfNeeded()
                        }
                        showingActive = true
                    } label: {
                        Label(model.active == nil ? "Start workout" : "Resume workout",
                              systemImage: model.active == nil ? "plus.circle.fill" : "play.circle.fill")
                            .font(.headline)
                    }
                    NavigationLink {
                        RoutinesView()
                    } label: {
                        Label("Routines", systemImage: "list.bullet.clipboard")
                    }
                    .accessibilityHint("Start a workout from a saved routine")
                }
                RecoveryCard()
                Section("This week") {
                    WeekHeader()
                    NavigationLink {
                        ExercisesListView()
                    } label: {
                        Label("Exercises", systemImage: "list.bullet.rectangle")
                    }
                }
                Section("History") {
                    let overlaps = model.sessionOverlaps.count
                    if overlaps > 0 {
                        Button {
                            reviewingOverlaps = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "applewatch")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(overlaps == 1 ? "Your watch and Rehabit both recorded this visit"
                                         : "Your watch and Rehabit both recorded \(overlaps) visits")
                                        .foregroundStyle(Color.primary)
                                    Text("See what each recorded and choose what to keep. Nothing changes until you choose.")
                                        .font(.caption).foregroundStyle(Color.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.secondary.opacity(0.6))
                                    .accessibilityHidden(true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .accessibilityIdentifier("overlap-card")
                        .accessibilityHint("Opens the review")
                    }
                    if model.workouts.isEmpty {
                        Text("No workouts yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.workouts) { workout in
                        NavigationLink {
                            WorkoutDetailView(workout: workout)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(workout.title)
                                Text("\(workout.start.formatted(date: .abbreviated, time: .shortened)) · \(Format.count(model.sets(of: workout).count, "set"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Repeat", systemImage: "arrow.clockwise") { repeatWorkout(workout) }
                                .tint(.accentColor)
                        }
                        .swipeActions(edge: .trailing) {
                            // Not the destructive role: that removes the row before the person confirms.
                            Button("Delete", systemImage: "trash") { pendingDelete = workout }
                                .tint(.red)
                        }
                        .contextMenu {
                            Button("Repeat this workout", systemImage: "arrow.clockwise") { repeatWorkout(workout) }
                        }
                    }
                }
            }
            .navigationTitle("Workouts")
            // An alert rather than a confirmation dialog: on iOS 26 a dialog becomes a
            // popover pointing at the list, not at the row being deleted.
            .alert(pendingDelete.map { "Delete \($0.title)?" } ?? "", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete) { workout in
                Button("Delete", role: .destructive) { delete(workout) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { workout in
                Text(keepsAfterDelete(workout) ? "It is kept in Recently deleted for 30 days."
                     : "Nothing was logged in it, so it is not kept.")
            }
            .safeAreaInset(edge: .bottom) {
                if let workout = undoable {
                    UndoBanner(title: workout.title) { undo(workout) }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: undoable?.id)
            .sheet(isPresented: $reviewingOverlaps) { OverlapReviewView() }
            .workoutInProgressAlert($busy, resume: { showingActive = true })
            // The pain questions are shown once the workout screen has finished
            // closing; asking for a second screen while the first is still on its
            // way out is ignored by the system.
            .fullScreenCover(isPresented: $showingActive, onDismiss: {
                showingChecks = checksWaiting
                checksWaiting = false
            }) {
                ActiveWorkoutView { dueNow in
                    checksWaiting = !dueNow.isEmpty
                    showingActive = false
                }
            }
            .sheet(isPresented: $showingChecks) {
                NavigationStack {
                    CheckInsList()
                        .navigationTitle("How does it feel?")
                        .toolbar { Button("Done") { showingChecks = false } }
                        .onChange(of: model.checkInRound.isEmpty) { _, empty in if empty { showingChecks = false } }
                }
            }
        }
        .environment(\.openLiveWorkout, { showingActive = true })
    }

    /// A workout with anything logged in it goes to Recently deleted; an empty one does not.
    private func keepsAfterDelete(_ workout: Workout) -> Bool {
        model.sets(of: workout).contains { !$0.isBlank }
    }

    private func delete(_ workout: Workout) {
        pendingDelete = nil
        let kept = keepsAfterDelete(workout)
        model.deleteWorkout(workout)
        undoTask?.cancel()
        guard kept else { undoable = nil; return }
        undoable = workout
        UIAccessibility.post(notification: .announcement, argument: "Deleted \(workout.title). Undo is available.")
        // Longer with VoiceOver on, so there is time to reach the button.
        let seconds: Double = UIAccessibility.isVoiceOverRunning ? 20 : 6
        undoTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if undoable?.id == workout.id { undoable = nil }
        }
    }

    private func undo(_ workout: Workout) {
        undoTask?.cancel()
        undoable = nil
        model.restoreWorkout(id: workout.id)
    }

    /// Starts a workout with the same exercises as a finished one and opens it.
    private func repeatWorkout(_ workout: Workout) {
        guard model.active == nil else { busy = true; return }
        if model.startWorkout(repeating: workout) {
            RestNotice.askPermissionIfNeeded()
            showingActive = true
        }
    }
}

/// "Deleted Lower A" with an Undo button, shown for a few seconds after a delete.
private struct UndoBanner: View {
    let title: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Deleted \(title)")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo", action: undo)
                .fontWeight(.semibold)
                .accessibilityHint("Brings the workout back")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("undo-banner")
    }
}

/// Consecutive sets of one exercise on one side, shown as one block.
struct ExerciseGroup: Identifiable {
    let id: String
    let exercise: String
    let side: Side
    var sets: [WorkoutSet]

    var title: String { side == .both ? exercise : "\(exercise) · \(Format.side(side))" }

    static func groups(_ sets: [WorkoutSet]) -> [ExerciseGroup] {
        var out: [ExerciseGroup] = []
        for set in sets {
            if let index = out.firstIndex(where: { $0.exercise == set.exercise && $0.side == set.side }) {
                out[index].sets.append(set)
            } else {
                out.append(ExerciseGroup(id: set.exercise + "|" + set.side.rawValue, exercise: set.exercise,
                                         side: set.side, sets: [set]))
            }
        }
        return out
    }
}

import RehabitCore
import SwiftUI

struct WorkoutsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingActive = false
    @State private var showingChecks = false
    @State private var checksWaiting = false
    @State private var busy = false

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
                Section("This week") {
                    WeekHeader()
                    NavigationLink {
                        ExercisesListView()
                    } label: {
                        Label("Exercises", systemImage: "list.bullet.rectangle")
                    }
                }
                Section("History") {
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
                            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteWorkout(workout) }
                        }
                        .contextMenu {
                            Button("Repeat this workout", systemImage: "arrow.clockwise") { repeatWorkout(workout) }
                        }
                    }
                }
            }
            .navigationTitle("Workouts")
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

    /// Starts a workout with the same exercises as a finished one and opens it.
    private func repeatWorkout(_ workout: Workout) {
        guard model.active == nil else { busy = true; return }
        if model.startWorkout(repeating: workout) {
            RestNotice.askPermissionIfNeeded()
            showingActive = true
        }
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

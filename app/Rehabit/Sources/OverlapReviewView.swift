import RehabitCore
import SwiftUI

/// A watch session and a session logged on the phone in the same visit, set
/// out in words: which workouts, which sets, and what each choice would
/// change. Nothing is changed until one of the buttons is tapped.
struct OverlapReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var removing: SessionOverlap?

    var body: some View {
        let overlaps = model.sessionOverlaps
        NavigationStack {
            List {
                if overlaps.isEmpty {
                    Section {
                        Text("Nothing left to review.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                    } footer: {
                        Text("Your watch recorded a session at the same time as one logged in Rehabit. Nothing is changed until you choose below.")
                    }
                }
                ForEach(overlaps) { overlap in
                    OverlapSection(overlap: overlap, remove: { removing = overlap })
                }
            }
            .navigationTitle("Same visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .alert(removing.map { removeTitle($0) } ?? "", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }),
                presenting: removing) { overlap in
                Button("Remove the repeated sets", role: .destructive) {
                    for repeated in overlap.repeated { model.remove(repeated) }
                    removing = nil
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: { _ in
                Text("The sets logged in Rehabit stay as they are.")
            }
        }
    }

    private func removeTitle(_ overlap: SessionOverlap) -> String {
        let count = overlap.repeated.reduce(0) { $0 + $1.setIDs.count }
        return "Remove \(Format.count(count, "set")) from \(overlap.watch.title)?"
    }
}

private struct OverlapSection: View {
    @Environment(AppModel.self) private var model
    let overlap: SessionOverlap
    let remove: () -> Void

    var body: some View {
        let watchSets = model.sets(of: overlap.watch)
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Imported from your watch: \(describe(overlap.watch, sets: watchSets.count))")
                Text("Logged in Rehabit: \(describe(overlap.logged, sets: model.sets(of: overlap.logged).count))")
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            ForEach(overlap.proposals) { proposal in
                VStack(alignment: .leading, spacing: 4) {
                    Text(proposalText(proposal))
                        .fixedSize(horizontal: false, vertical: true)
                    setLines(proposal.setIDs, in: watchSets)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(overlap.repeated) { repeated in
                VStack(alignment: .leading, spacing: 4) {
                    Text(repeatedText(repeated))
                        .fixedSize(horizontal: false, vertical: true)
                    setLines(repeated.setIDs, in: watchSets)
                }
                .accessibilityElement(children: .combine)
            }

            if !overlap.proposals.isEmpty {
                Button {
                    model.accept(overlap.proposals)
                } label: {
                    Label("Use the proposed sides", systemImage: "arrow.left.and.right")
                }
                .accessibilityHint(acceptHint)
            }
            if !overlap.repeated.isEmpty {
                Button(role: .destructive) {
                    remove()
                } label: {
                    Label("Remove the repeated sets", systemImage: "minus.circle")
                        .foregroundStyle(.red)
                }
                .accessibilityHint("Deletes the watch's copies. The sets logged in Rehabit stay.")
            }
            Button {
                model.keep(overlap)
            } label: {
                Label("Keep both as they are", systemImage: "checkmark.circle")
            }
            .accessibilityHint("Both sessions count, and this pair is not asked about again.")
        } header: {
            Text(Day(overlap.watch.start).readable)
        }
    }

    private var acceptHint: String {
        overlap.proposals.map { "Files \(Format.count($0.setIDs.count, "set")) of \($0.exercise) under the \(side($0.side)) side" }
            .joined(separator: ". ")
    }

    /// "Strength, 9:05 to 9:50 AM, 6 sets".
    private func describe(_ workout: Workout, sets: Int) -> String {
        var text = "\(workout.title), \(workout.start.formatted(date: .omitted, time: .shortened))"
        if let end = workout.end, end.timeIntervalSince(workout.start) >= 60 {
            text += " to \(end.formatted(date: .omitted, time: .shortened))"
        }
        return text + ", \(Format.count(sets, "set"))."
    }

    private func proposalText(_ proposal: OverlapProposal) -> String {
        let count = Format.count(proposal.setIDs.count, "set")
        return "The watch recorded \(count) of \(proposal.exercise) with no side. "
            + "You logged \(proposal.loggedExercise == proposal.exercise ? "it" : proposal.loggedExercise) "
            + "on the \(side(proposal.loggedSide)) side only, "
            + "so these may be the \(side(proposal.side)) side. "
            + "Using the proposed sides files \(proposal.setIDs.count == 1 ? "it" : "them") under \(side(proposal.side))."
    }

    private func repeatedText(_ repeated: RepeatedSets) -> String {
        let count = Format.count(repeated.setIDs.count, "set")
        let logged = repeated.loggedExercise == repeated.exercise
            ? "you logged it in Rehabit" : "\(repeated.loggedExercise) logged in Rehabit"
        return "The watch recorded \(count) of \(repeated.exercise) on the same sides as \(logged). "
            + "They may be the same work recorded twice. "
            + "Removing the repeated sets deletes the watch's copies."
    }

    private func side(_ side: Side) -> String { Format.side(side).lowercased() }

    /// The sets themselves, one line each: "Set 1: 30 lb · 10 reps".
    @ViewBuilder
    private func setLines(_ ids: [String], in sets: [WorkoutSet]) -> some View {
        let chosen = sets.filter { ids.contains($0.id) }
        ForEach(Array(chosen.enumerated()), id: \.element.id) { index, set in
            Text("Set \(index + 1): \(Format.summary(set).isEmpty ? "nothing recorded" : Format.summary(set))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

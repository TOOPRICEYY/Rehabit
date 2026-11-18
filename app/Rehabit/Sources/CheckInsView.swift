import RehabitCore
import SwiftUI

struct CheckInsView: View {
    @State private var logging = false

    var body: some View {
        NavigationStack {
            CheckInsList()
                .navigationTitle("Check-ins")
                .toolbar {
                    Button { logging = true } label: { Label("Log pain now", systemImage: "plus.circle") }
                }
                .sheet(isPresented: $logging) { LogPainSheet() }
        }
    }
}

/// Every pain question due now, one row per injury, answered on one screen.
/// A question skipped is kept as missing; it is never filled in as zero.
struct CheckInsList: View {
    @Environment(AppModel.self) private var model
    @State private var pain: [String: Double] = [:]
    @State private var type: [String: PainType] = [:]
    @State private var notes = ""
    /// Questions "Unchanged" could not answer, because there was no earlier reading.
    @State private var needsNumber: Set<String> = []
    @State private var logging = false

    var body: some View {
        // The session's follow-ups first, then the daily checks.
        let round = model.checkInRound.sorted { ($0.check.workoutID == nil ? 1 : 0) < ($1.check.workoutID == nil ? 1 : 0) }
        List {
            if let error = model.lastError, !round.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.subheadline)
            }
            if round.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to answer", systemImage: "checkmark.circle")
                } description: {
                    if let next = model.reminderRounds.min(by: { $0.fireAt < $1.fireAt }) {
                        Text("Next check-in: \(next.injuryLabels.joined(separator: ", ")), \(next.fireAt.formatted(.relative(presentation: .named))) (\(next.fireAt.formatted(date: .omitted, time: .shortened))).")
                    } else {
                        Text("Pain check-ins appear here after a session that loads an injury, and each morning if that is turned on in Settings.")
                    }
                } actions: {
                    Button("Log pain now") { logging = true }.buttonStyle(.bordered)
                }
            }
            ForEach(round) { item in
                Section {
                    PainChipStrip(value: binding(item.check.id))
                    if let same = item.unchangedValue, pain[item.check.id] == nil {
                        Button("Same as last time: \(Format.number(same))") { pain[item.check.id] = same }
                            .font(.subheadline)
                    }
                    DisclosureGroup("How it feels") {
                        PainTypeChips(selection: Binding(get: { type[item.check.id] },
                                                         set: { type[item.check.id] = $0 }))
                    }
                    .font(.subheadline)
                    if needsNumber.contains(item.check.id) && pain[item.check.id] == nil {
                        Label("Needs a number: nothing entered in the last three days to copy.", systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.injury.label).font(.headline).foregroundStyle(Color(uiColor: .label))
                        Text(item.check.moment.label).font(.subheadline)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lastText(item.last))
                            if let during = item.sessionPain { Text("During the session: \(Format.number(during))") }
                            if let flare = recentFlare(item.injury) {
                                Text("Flare-up \(Format.number(flare.pain ?? 0)), \((flare.answeredAt ?? flare.dueAt).formatted(.relative(presentation: .named)))")
                            }
                        }
                        .font(.caption)
                        if recentFlare(item.injury) != nil {
                            Text("The flare-up is shown for context. Unchanged does not copy it.")
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textCase(nil)
                }
            }
            if !round.isEmpty {
                Section {
                    TextField("Notes for this round (optional)", text: $notes, axis: .vertical)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !round.isEmpty { buttons(round) }
        }
        .sheet(isPresented: $logging) { LogPainSheet() }
    }

    private func binding(_ id: String) -> Binding<Double?> {
        Binding(get: { pain[id] }, set: { pain[id] = $0 })
    }

    /// A flare-up logged in the last day, shown beside the question so it does not look lost.
    private func recentFlare(_ injury: Injury) -> PainCheck? {
        model.painHistory(for: injury).last { $0.moment == .flare && ($0.answeredAt ?? $0.dueAt) > Date().addingTimeInterval(-86_400) }
    }

    private func lastText(_ last: PainCheck?) -> String {
        guard let last, let value = last.pain else { return "No earlier reading" }
        let when = (last.answeredAt ?? last.dueAt).formatted(.relative(presentation: .named))
        return "Last: \(Format.number(value)), \(when)"
    }

    private func buttons(_ round: [CheckInItem]) -> some View {
        let answered = round.filter { pain[$0.check.id] != nil }
        let open = round.filter { pain[$0.check.id] == nil }
        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button("Skip") {
                    saveAnswered(answered)
                    model.skip(open.map(\.check))
                    reset()
                }
                .buttonStyle(.bordered)
                Button("Unchanged") {
                    saveAnswered(answered)
                    let copyable = open.filter { $0.unchangedValue != nil }
                    let left = model.answerUnchanged(copyable.map(\.check)).map(\.id)
                    needsNumber = Set(left + open.filter { $0.unchangedValue == nil }.map(\.check.id))
                }
                .buttonStyle(.bordered)
                .disabled(!open.contains { $0.unchangedValue != nil })
                Button {
                    saveAnswered(answered)
                    if open.isEmpty { reset() }
                } label: {
                    Text(answered.isEmpty ? "Save" : "Save \(answered.count)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(answered.isEmpty)
            }
            .controlSize(.large)
            Text("Unchanged copies a number entered in the last three days. Skip leaves it unanswered, never zero.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func saveAnswered(_ items: [CheckInItem]) {
        let entries = items.compactMap { item -> (check: PainCheck, pain: Double, type: PainType?, notes: String)? in
            guard let value = pain[item.check.id] else { return nil }
            return (item.check, value, type[item.check.id], notes)
        }
        if !entries.isEmpty { model.answer(entries) }
        for item in items { pain[item.check.id] = nil; type[item.check.id] = nil }
    }

    private func reset() {
        pain = [:]; type = [:]; notes = ""; needsNumber = []
    }
}

/// Pain 0 to 10 in half points as a row of large chips. Nothing is selected
/// until one is tapped, so an untouched row is never read as zero.
struct PainChipStrip: View {
    @Binding var value: Double?

    /// All of 0 to 10 at once, in three rows, so no number is hidden off-screen.
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(Format.painSteps, id: \.self) { step in
                let chosen = value == step
                Button {
                    value = chosen ? nil : step
                } label: {
                    Text(Format.number(step))
                        .font(.callout.monospacedDigit().weight(chosen ? .bold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(chosen ? Format.painColor(step) : Format.painColor(step).opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(chosen ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pain \(Format.number(step))")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// The pain words as chips; tapping the chosen one clears it.
struct PainTypeChips: View {
    @Binding var selection: PainType?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(PainType.allCases, id: \.self) { word in
                let chosen = selection == word
                Button {
                    selection = chosen ? nil : word
                } label: {
                    Text(word.rawValue).font(.footnote).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(chosen ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(chosen ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Pain felt now, outside any schedule, for one injury or several.
struct LogPainSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opened from one injury's page: that injury comes first.
    var injuryID: String?
    @State private var pain: [String: Double] = [:]
    @State private var type: [String: PainType] = [:]
    @State private var context = ""
    @State private var notes = ""
    @State private var showAll = false

    var body: some View {
        let active = model.injuries.filter(\.isActive)
            .filter { injuryID == nil || showAll || $0.id == injuryID }
            .sorted { ($0.id == injuryID ? 0 : 1) < ($1.id == injuryID ? 0 : 1) }
        NavigationStack {
            List {
                if active.isEmpty {
                    Text("No active injuries. Add one on the Injuries tab first.").foregroundStyle(.secondary)
                }
                ForEach(active) { injury in
                    Section {
                        PainChipStrip(value: Binding(get: { pain[injury.id] }, set: { pain[injury.id] = $0 }))
                        if pain[injury.id] != nil {
                            DisclosureGroup("How it feels") {
                                PainTypeChips(selection: Binding(get: { type[injury.id] }, set: { type[injury.id] = $0 }))
                            }
                            .font(.subheadline)
                        }
                    } header: {
                        Text(injury.label).font(.headline).foregroundStyle(Color(uiColor: .label)).textCase(nil)
                    }
                }
                if injuryID != nil && !showAll && model.injuries.filter(\.isActive).count > 1 {
                    Button("Also log other injuries") { showAll = true }
                }
                Section {
                    TextField("What was going on? (stairs, woke up with it)", text: $context)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                } footer: {
                    Text("Only the injuries given a number are saved.")
                }
            }
            .navigationTitle("Log pain now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let readings = active.compactMap { injury -> (injury: Injury, pain: Double, type: PainType?)? in
                            pain[injury.id].map { (injury, $0, type[injury.id]) }
                        }
                        model.logPain(readings, context: context, notes: notes)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(pain.isEmpty)
                }
            }
        }
    }
}

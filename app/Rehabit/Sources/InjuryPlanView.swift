import RehabitCore
import SwiftUI

// MARK: On the injury screen

/// The plan for an injury on its screen: who set it, the limits and each
/// recent session against them, the milestones and the next visit. The
/// limits are the person's or their therapist's; the app sets none.
struct InjuryPlanSections: View {
    @Environment(AppModel.self) private var model
    let injury: Injury
    let onEdit: () -> Void

    var body: some View {
        let plan = injury.plan ?? InjuryPlan()
        Section {
            if plan.isEmpty {
                Text("No plan yet. Add the limits and milestones you or your therapist set.")
                    .foregroundStyle(.secondary)
                Button(action: onEdit) { Label("Add a plan", systemImage: "plus.circle") }
            } else {
                if !plan.setBy.isEmpty { LabeledContent("Set by", value: plan.setBy) }
                if let rule = model.ruleText(for: injury) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Limits").font(.subheadline).foregroundStyle(.secondary)
                        Text(rule)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let visit = plan.nextVisit { LabeledContent("Next visit", value: visit.readable) }
                Button(action: onEdit) { Label("Edit plan", systemImage: "pencil") }
            }
        } header: {
            Text("Plan")
        } footer: {
            if !plan.isEmpty {
                Text("These are the limits and milestones you or your therapist set. The app sets none of its own.")
            }
        }
        if plan.rule != nil {
            let checks = model.ruleChecks(for: injury)
            Section {
                if checks.isEmpty {
                    Text("No finished sessions in the last 4 weeks loaded this injury.").foregroundStyle(.secondary)
                }
                ForEach(checks) { check in RuleCheckRow(check: check) }
            } header: {
                Text("Sessions against the limits")
            } footer: {
                if !checks.isEmpty {
                    Text("Last 4 weeks. A dashed circle means nothing was recorded to tell either way.")
                }
            }
        }
        if !plan.milestones.isEmpty {
            Section("Milestones") {
                ForEach(model.milestones(for: injury)) { progress in
                    MilestoneRow(progress: progress, text: model.milestoneText(progress.milestone)) {
                        model.setMilestone(progress.milestone.id, done: progress.milestone.doneOn == nil, for: injury)
                    }
                }
            }
        }
    }
}

/// One session and how it sat against the limits. The mark is a shape and a
/// word, never a colour: within is a plain check, over an exclamation mark,
/// and not known a dashed circle with a question mark.
private struct RuleCheckRow: View {
    let check: RuleCheck

    private var outcome: RuleOutcome {
        let parts = [check.duringOutcome, check.settleOutcome].compactMap { $0 }
        if parts.contains(.over) { return .over }
        if parts.contains(.unknown) || parts.isEmpty { return .unknown }
        return .within
    }

    private var word: String {
        switch outcome {
        case .within: return "Within"
        case .over: return "Over"
        case .unknown:
            // One limit kept and the other not known is said as such, not as nothing known.
            return [check.duringOutcome, check.settleOutcome].contains(.within) ? "Partly known" : "Not known"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            OutcomeMark(outcome: outcome)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(check.day.readable) · \(check.title)").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(word).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(check.sentence).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.day.readable), \(check.title). \(outcome == .unknown ? word : "\(word) the limits"). \(check.sentence)")
        .accessibilityIdentifier("rule-check")
    }
}

private struct OutcomeMark: View {
    let outcome: RuleOutcome

    var body: some View {
        Group {
            switch outcome {
            case .within:
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
            case .over:
                Image(systemName: "exclamationmark")
                    .font(.body.weight(.heavy))
                    .padding(4)
                    .overlay(Circle().stroke(lineWidth: 1.5))
            case .unknown:
                Image(systemName: "questionmark")
                    .font(.caption.weight(.semibold))
                    .padding(5)
                    .overlay(Circle().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

private struct MilestoneRow: View {
    let progress: MilestoneProgress
    let text: String
    let onToggle: () -> Void

    var body: some View {
        let byHand = progress.milestone.exercise == nil
        let title = progress.milestone.title
        if byHand {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: progress.milestone.doneOn == nil ? "square" : "checkmark.square.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).foregroundStyle(.primary)
                        Text(progress.sentence).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title). \(progress.sentence)")
            .accessibilityHint(progress.milestone.doneOn == nil ? "Ticks it as done today" : "Takes the tick away")
            .accessibilityAddTraits(progress.milestone.doneOn == nil ? [] : .isSelected)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: progress.isReached ? "flag.checkered" : "flag")
                    .font(.title3)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if !title.isEmpty && title != text { Text(title) }
                    Text(text).font(title.isEmpty || title == text ? .body : .subheadline)
                        .foregroundStyle(title.isEmpty || title == text ? .primary : .secondary)
                    Text(progress.sentence).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title.isEmpty ? "" : "\(title). ")\(text). \(progress.isReached ? "Reached" : "Not reached yet"). \(progress.sentence)")
        }
    }
}

// MARK: Editing

/// Who set the plan, as one of the usual answers or in the person's words.
private enum SetByChoice: Hashable {
    case therapist, me, other

    static let therapistText = "My physical therapist"
    static let meText = "Me"
}

struct InjuryPlanEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let injury: Injury
    @State private var duringMax: Double?
    @State private var settleHours: Double?
    @State private var setBy: SetByChoice?
    @State private var setByText = ""
    @State private var hasVisit = false
    @State private var visit = Date()
    @State private var milestones: [Milestone] = []
    @State private var editing: MilestoneDraft?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Record the limits and milestones you or your therapist agreed. The app does not suggest any; it only counts your sessions against what you enter here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    choice(.therapist, SetByChoice.therapistText)
                    choice(.me, SetByChoice.meText)
                    choice(.other, "Someone else")
                    if setBy == .other {
                        TextField("Name, such as Dana, physio", text: $setByText)
                    }
                } header: {
                    Text("Who set it")
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Most pain during a set")
                        Text(duringMax.map { "No higher than \(Format.number($0)) out of 10." } ?? "No limit. Tap a number to set one.")
                            .font(.caption).foregroundStyle(.secondary)
                        PainChipStrip(value: $duringMax)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Settle within")
                            Text("Hours after a session for pain to be back to the level before. Empty for no limit.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        NumberField(title: "Hours", value: $settleHours, width: 72)
                            .accessibilityLabel("Settle within, hours")
                        Text("hours").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    if let hours = settleHours, hours > 60 {
                        Text("The longest time that can be set is 60 hours.").font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Pain limits")
                } footer: {
                    Text("Each session that loads this injury is shown against these limits on the injury's screen.")
                }
                Section {
                    ForEach(milestones) { milestone in
                        Button {
                            editing = MilestoneDraft(milestone, model: model)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(milestone.title.isEmpty ? model.milestoneText(milestone) : milestone.title)
                                    .foregroundStyle(.primary)
                                Text(milestone.exercise == nil ? "Ticked by hand" : model.milestoneText(milestone))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityHint("Edits the milestone")
                    }
                    .onDelete { milestones.remove(atOffsets: $0) }
                    .onMove { milestones.move(fromOffsets: $0, toOffset: $1) }
                    Button {
                        editing = MilestoneDraft()
                    } label: {
                        Label("Add milestone", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Milestones")
                } footer: {
                    Text("With an exercise, a milestone is reached when a logged set meets it. Without one, you tick it yourself.")
                }
                Section {
                    Toggle("Next visit booked", isOn: $hasVisit)
                    if hasVisit {
                        DatePicker("Next visit", selection: $visit, displayedComponents: .date)
                    }
                } header: {
                    Text("Next visit")
                }
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(setBy == .other && setByText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(item: $editing) { draft in
                MilestoneEditorView(draft: draft) { saved in
                    if let at = milestones.firstIndex(where: { $0.id == saved.id }) { milestones[at] = saved }
                    else { milestones.append(saved) }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func choice(_ value: SetByChoice, _ text: String) -> some View {
        Button {
            setBy = setBy == value ? nil : value
        } label: {
            HStack {
                Text(text).foregroundStyle(.primary)
                Spacer()
                if setBy == value { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .accessibilityAddTraits(setBy == value ? .isSelected : [])
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let plan = injury.plan else { return }
        duringMax = plan.rule?.duringMax
        settleHours = plan.rule?.settleHours
        switch plan.setBy {
        case "": setBy = nil
        case SetByChoice.therapistText: setBy = .therapist
        case SetByChoice.meText: setBy = .me
        default: setBy = .other; setByText = plan.setBy
        }
        if let day = plan.nextVisit { hasVisit = true; visit = day.start() }
        milestones = plan.milestones
    }

    private func save() {
        guard var current = model.injuries.first(where: { $0.id == injury.id }) else { dismiss(); return }
        let who: String
        switch setBy {
        case .therapist: who = SetByChoice.therapistText
        case .me: who = SetByChoice.meText
        case .other: who = setByText.trimmingCharacters(in: .whitespacesAndNewlines)
        case nil: who = ""
        }
        // A tick given on the injury's screen while this sheet was open is kept.
        let ticks = Dictionary((current.plan?.milestones ?? []).map { ($0.id, $0.doneOn) }, uniquingKeysWith: { a, _ in a })
        let kept = milestones.map { milestone -> Milestone in
            var copy = milestone
            if let tick = ticks[milestone.id] { copy.doneOn = tick }
            return copy
        }
        let plan = InjuryPlan(rule: PainRule(duringMax: duringMax, settleHours: settleHours), milestones: kept,
                              setBy: who, nextVisit: hasVisit ? Day(visit) : nil)
        current.plan = plan.isEmpty ? nil : plan
        model.save(current)
        dismiss()
    }
}

/// A milestone while it is being written.
struct MilestoneDraft: Identifiable {
    var id = UUID().uuidString
    var title = ""
    var exercise: String?
    var isHold = false
    var loadValue: Double?
    var loadUnit: WeightUnit = .lb
    var count: Double?
    var maxPain: Double?
    var doneOn: Day?

    init() {}

    @MainActor init(_ milestone: Milestone, model: AppModel) {
        id = milestone.id; title = milestone.title; exercise = milestone.exercise
        loadValue = milestone.loadValue; loadUnit = milestone.loadUnit; count = milestone.count
        maxPain = milestone.maxPain; doneOn = milestone.doneOn
        if let name = milestone.exercise {
            isHold = (model.library.catalogue + model.customExercises)
                .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.kind == .hold
        }
    }

    var milestone: Milestone {
        Milestone(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines), exercise: exercise,
                  loadValue: exercise == nil ? nil : loadValue, loadUnit: loadUnit,
                  count: exercise == nil ? nil : count, maxPain: exercise == nil ? nil : maxPain, doneOn: doneOn)
    }
}

struct MilestoneEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: MilestoneDraft
    let onSave: (Milestone) -> Void
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title, such as Stairs without the rail", text: $draft.title, axis: .vertical)
                } header: {
                    Text("Milestone")
                }
                Section {
                    if let exercise = draft.exercise {
                        LabeledContent("Exercise", value: exercise)
                        Button("Change exercise") { picking = true }
                        Button("Remove exercise", role: .destructive) { draft.exercise = nil }
                    } else {
                        Button { picking = true } label: { Label("Choose an exercise", systemImage: "dumbbell") }
                    }
                } header: {
                    Text("Exercise (optional)")
                } footer: {
                    Text(draft.exercise == nil
                         ? "Without an exercise, you tick this milestone yourself on the injury's screen."
                         : "Reached when a set of this exercise, on the injured side or both sides, meets everything below. Leave a field empty for any.")
                }
                if draft.exercise != nil {
                    Section("What a set needs") {
                        HStack {
                            Text("Load, at least")
                            Spacer()
                            NumberField(title: "Load", value: $draft.loadValue, width: 80)
                                .accessibilityLabel("Load, at least")
                            Picker("Unit", selection: $draft.loadUnit) {
                                ForEach(WeightUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 90)
                            .accessibilityLabel("Load unit")
                        }
                        HStack {
                            Text(draft.isHold ? "Seconds held, at least" : "Reps, at least")
                            Spacer()
                            NumberField(title: draft.isHold ? "Seconds" : "Reps", value: $draft.count, width: 80)
                                .accessibilityLabel(draft.isHold ? "Seconds held, at least" : "Reps, at least")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pain on the set, at most")
                            Text(draft.maxPain.map { "\(Format.number($0)) or less. A set with no pain recorded does not count." }
                                 ?? "Any pain. Tap a number to set a most.")
                                .font(.caption).foregroundStyle(.secondary)
                            PainChipStrip(value: $draft.maxPain)
                        }
                    }
                }
            }
            .navigationTitle(draft.title.isEmpty && draft.exercise == nil ? "New milestone" : "Milestone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(draft.milestone); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.exercise == nil)
                }
            }
            .sheet(isPresented: $picking) {
                ExercisePickerView(title: "Choose exercise") { exercise, _ in
                    draft.exercise = exercise.name
                    draft.isHold = exercise.kind == .hold
                    picking = false
                }
            }
        }
    }
}

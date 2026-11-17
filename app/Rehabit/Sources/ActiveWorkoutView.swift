import RehabitCore
import SwiftUI
import UIKit

/// What the exercise picker was opened for.
enum PickerPurpose: Identifiable {
    case add
    case replace(String)
    var id: String {
        switch self {
        case .add: return "add"
        case .replace(let name): return "replace|" + name
        }
    }
}

struct ActiveWorkoutView: View {
    @Environment(AppModel.self) private var model
    /// Called when the workout is finished or discarded, with the pain checks due right away.
    let onClose: ([PainCheck]) -> Void
    @State private var title = ""
    @State private var picker: PickerPurpose?
    @State private var confirmingDiscard = false
    @State private var confirmingUnfinished = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    TextField("Workout name", text: $title)
                        .font(.headline)
                        .onChange(of: title) { _, name in model.renameActive(name) }
                }
                let blocks = model.activeBlocks
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    ExerciseCard(block: block, isFirst: index == 0, isLast: index == blocks.count - 1) {
                        picker = .replace(block.exercise)
                    }
                    .id(block.id)
                }
                if blocks.isEmpty {
                    Section {
                        Text("Add the first exercise from the button below. One-sided exercises are logged left and right on the same line.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listSectionSpacing(.compact)
            // A newly added exercise is brought into view.
            .onChange(of: model.activeBlocks.map(\.id)) { old, new in
                if let added = new.first(where: { !old.contains($0) }) {
                    withAnimation { proxy.scrollTo(added, anchor: .top) }
                }
            }
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardStepBar()
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .onChange(of: model.rest) { _, rest in RestNotice.schedule(rest) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { confirmingDiscard = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish") {
                        // Close the keyboard first so a field still being typed in hands over its value.
                        dismissKeyboard()
                        model.renameActive(title)
                        if model.unfinishedSets.isEmpty { finish(removing: false) } else { confirmingUnfinished = true }
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog("\(model.unfinishedSets.count) sets not marked done", isPresented: $confirmingUnfinished,
                                titleVisibility: .visible) {
                Button("Keep them") { finish(removing: false) }
                Button("Remove them", role: .destructive) { finish(removing: true) }
            } message: {
                Text("Sets you planned but did not mark done can be kept as logged or left out of this workout.")
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmingDiscard) {
                Button("Discard workout", role: .destructive) {
                    model.discardWorkout()
                    onClose([])
                }
            }
            .sheet(item: $picker) { purpose in
                switch purpose {
                case .add:
                    ExercisePickerView(title: "Add exercise") { exercise, mode in
                        model.addExercise(exercise, mode: mode)
                        picker = nil
                    }
                case .replace(let name):
                    ExercisePickerView(title: "Replace \(name)") { exercise, _ in
                        model.replaceExercise(name, with: exercise)
                        picker = nil
                    }
                }
            }
            .onAppear { title = model.active?.title ?? "" }
        }
    }

    private func finish(removing: Bool) {
        RestNotice.schedule(nil)
        onClose(model.finishWorkout(removingUnfinished: removing))
    }

    /// Always in reach: the rest countdown after a set marked done (or the
    /// time since the last set) and the way to add the next exercise.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let rest = model.rest {
                    RestReadout(rest: rest, now: context.date)
                } else {
                    let since = model.lastActivity.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Since last set").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text(Format.elapsed(since)).font(.title3.monospacedDigit().weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Spacer(minLength: 8)
            Button {
                dismissKeyboard()
                picker = .add
            } label: {
                if model.rest == nil {
                    Label("Add exercise", systemImage: "plus")
                        .font(.headline)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                } else {
                    Image(systemName: "plus").font(.headline).accessibilityLabel("Add exercise")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        // A bar that grew with the largest text sizes would cover half the screen.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Exercise card

/// Every set of one exercise: a header with the side mode and the card menu,
/// a line per round, and the advice and last session underneath.
struct ExerciseCard: View {
    @Environment(AppModel.self) private var model
    let block: ExerciseBlock
    let isFirst: Bool
    let isLast: Bool
    let onReplace: () -> Void
    @State private var confirmingRemove = false
    @State private var askingWhichSide = false
    @State private var showingHistory = false
    @State private var confirmingLink = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var mode: SideMode { block.mode }
    private var injured: Set<Side> { model.injuredSides(of: block.exercise) }
    private var sample: WorkoutSet? { block.sample }

    var body: some View {
        Section {
            if mode == .perSide { columnHeader }
            let rounds = block.rounds
            ForEach(rounds) { round in
                RoundRow(round: round, number: number(of: round, in: rounds), mode: mode, injured: injured)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { model.remove(round) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicate(round) }
                            .tint(.accentColor)
                    }
            }
            Button {
                model.addRound(to: block)
            } label: {
                Label(mode == .perSide ? "Add set, both sides" : "Add set", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
        } header: {
            header
        } footer: {
            footer
        }
        .sheet(isPresented: $showingHistory) {
            NavigationStack {
                ExerciseHistoryView(exercise: block.exercise)
                    .toolbar { Button("Done") { showingHistory = false } }
            }
        }
        .confirmationDialog(linkWarning, isPresented: $confirmingLink, titleVisibility: .visible) {
            Button("Link anyway") { model.setLinked(true, for: block.exercise) }
        } message: {
            Text("While linked, a change to the left side's load and reps is copied to the right side.")
        }
        .confirmationDialog("Remove \(block.exercise) and its \(block.sets.count) sets?",
                            isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove exercise", role: .destructive) { model.removeExercise(block.exercise) }
        }
        .confirmationDialog("Left and right differ", isPresented: $askingWhichSide, titleVisibility: .visible) {
            Button("Keep the left side's sets") { model.setSideMode(.together, for: block.exercise, keep: .left) }
            Button("Keep the right side's sets") { model.setSideMode(.together, for: block.exercise, keep: .right) }
        } message: {
            Text("Logging both sides together keeps one set per line. The other side's numbers, pain and notes are removed.")
        }
    }

    /// Warm-ups are marked W; working sets are counted from 1.
    private func number(of round: SetRound, in rounds: [SetRound]) -> Int {
        rounds.prefix(round.index + 1).filter { !$0.isWarmup }.count
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(block.exercise)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .label))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Menu {
                    cardMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 30)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .accessibilityLabel("Options for \(block.exercise)")
            }
            HStack(spacing: 8) {
                sideSwitch
                Text(loadDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .textCase(nil)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .contextMenu { cardMenu }
    }

    /// A small switch between logging the sides together and each side by itself.
    private var sideSwitch: some View {
        Button {
            change(to: mode == .together ? .perSide : .together)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode == .together ? "arrow.left.and.right" : "rectangle.split.2x1")
                Text(sideName)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(mode == .together ? Color(.tertiarySystemFill) : Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(mode == .together ? Color.primary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sides: \(sideName)")
        .accessibilityHint(mode == .together ? "Switches to logging each side separately" : "Switches to logging both sides together")
    }

    private var sideName: String {
        switch mode {
        case .together: return "Together"
        case .perSide: return "Each side"
        case .leftOnly: return "Left only"
        case .rightOnly: return "Right only"
        }
    }

    private var loadDescription: String {
        guard let s = sample else { return "" }
        let unit = s.loadUnit.rawValue
        let what: String
        switch s.convention {
        case .perHand: what = "\(unit) per hand"
        case .total: what = "\(unit) total"
        case .bodyweight: what = "body weight"
        case .bodyweightPlus: what = "\(unit) added to body weight"
        }
        return s.kind == .hold ? "\(what) · holds in seconds" : what
    }

    private func change(to newMode: SideMode) {
        if newMode == .together, mode == .perSide, model.mergeLosesData(block.exercise) {
            askingWhichSide = true
        } else {
            model.setSideMode(newMode, for: block.exercise)
        }
    }

    // MARK: Card menu

    @ViewBuilder private var cardMenu: some View {
        Section("Sides") {
            Picker("Sides", selection: Binding(get: { mode }, set: change(to:))) {
                Label("Both together", systemImage: "arrow.left.and.right").tag(SideMode.together)
                Label("Each side separately", systemImage: "rectangle.split.2x1").tag(SideMode.perSide)
                Label("Left side only", systemImage: "l.square").tag(SideMode.leftOnly)
                Label("Right side only", systemImage: "r.square").tag(SideMode.rightOnly)
            }
            .pickerStyle(.inline)
            if mode == .perSide {
                Toggle(isOn: Binding(get: { model.isLinked(block.exercise) },
                                     set: { requestLink($0) })) {
                    Label("Right follows left", systemImage: "link")
                }
            }
        }
        Section {
            Menu {
                Picker("Load means", selection: allSets(\.convention)) {
                    Text("Per hand (one dumbbell)").tag(LoadConvention.perHand)
                    Text("Total (bar or stack)").tag(LoadConvention.total)
                    Text("Body weight").tag(LoadConvention.bodyweight)
                    Text("Body weight plus added").tag(LoadConvention.bodyweightPlus)
                }
            } label: {
                Label("Load means: \(conventionName)", systemImage: "scalemass")
            }
            Menu {
                let current = sample?.loadUnit ?? model.profile.unit
                ForEach(WeightUnit.allCases.filter { $0 != current }, id: \.self) { unit in
                    Button("Convert to \(unit.rawValue)") { model.setUnit(unit, for: block.exercise) }
                    Button("Numbers were already in \(unit.rawValue)") {
                        model.setUnit(unit, for: block.exercise, converting: false)
                    }
                }
            } label: {
                Label("Unit: \(sample?.loadUnit.rawValue ?? model.profile.unit.rawValue)", systemImage: "ruler")
            }
            Menu {
                let own = model.profile.restSeconds[block.exercise.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
                Button { model.setRest(nil, for: block.exercise) } label: {
                    Label("Default (\(Format.restLength(model.profile.defaultRestSeconds)))",
                          systemImage: own == nil ? "checkmark" : "")
                }
                ForEach([0, 30, 45, 60, 90, 120, 150, 180, 240, 300], id: \.self) { seconds in
                    Button { model.setRest(seconds, for: block.exercise) } label: {
                        Label(Format.restLength(seconds), systemImage: own == seconds ? "checkmark" : "")
                    }
                }
            } label: {
                Label("Rest for this exercise: \(Format.restLength(model.restSeconds(for: block.exercise)))", systemImage: "timer")
            }
            Picker(selection: allSets(\.kind)) {
                Text("Reps").tag(SetKind.reps)
                Text("Isometric holds").tag(SetKind.hold)
            } label: {
                Label("Sets are", systemImage: "timer")
            }
            .pickerStyle(.menu)
        }
        Section {
            Button {
                model.addWarmupRound(to: block)
            } label: {
                Label("Add warm-up set", systemImage: "flame")
            }
            Button {
                model.moveExercise(block.exercise, by: -1)
            } label: {
                Label("Move up", systemImage: "arrow.up")
            }
            .disabled(isFirst)
            Button {
                model.moveExercise(block.exercise, by: 1)
            } label: {
                Label("Move down", systemImage: "arrow.down")
            }
            .disabled(isLast)
            Button { showingHistory = true } label: {
                Label("History and records", systemImage: "chart.xyaxis.line")
            }
            Button(action: onReplace) {
                Label("Replace exercise…", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive) {
                confirmingRemove = true
            } label: {
                Label("Remove exercise…", systemImage: "trash")
            }
        }
    }

    private var conventionName: String {
        switch sample?.convention ?? .total {
        case .perHand: return "per hand"
        case .total: return "total"
        case .bodyweight: return "body weight"
        case .bodyweightPlus: return "body weight plus"
        }
    }

    /// A binding that reads the first set and writes every set of the exercise.
    private func allSets<Value: Hashable>(_ path: WritableKeyPath<WorkoutSet, Value>) -> Binding<Value> {
        Binding(get: { sample?[keyPath: path] ?? WorkoutSet.placeholder[keyPath: path] },
                set: { value in model.updateAll(of: block.exercise) { $0[keyPath: path] = value } })
    }

    // MARK: Columns and footer

    private var linkWarning: String {
        let side = injured.first.map { Format.side($0).lowercased() } ?? "one"
        return "The \(side) side is injured. Linking copies the left side's numbers onto the right."
    }

    /// Linking an exercise that loads a one-sided injury asks first: it would
    /// copy one side's load onto the other.
    private func requestLink(_ on: Bool) {
        if on && injured.count == 1 { confirmingLink = true } else { model.setLinked(on, for: block.exercise) }
    }

    /// Whether the right follows the left, and which side is injured.
    private var columnHeader: some View {
        let linked = model.isLinked(block.exercise)
        return HStack(spacing: 8) {
            Button {
                requestLink(!linked)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: linked ? "link" : "link.badge.plus")
                    Text(linked ? "Right follows left" : "Sides separate")
                }
                .lineLimit(1)
                .font(.caption.weight(.semibold))
                .foregroundStyle(linked ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(linked ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityHint("When linked, the right side copies the left side's load and reps")
            if injured.count == 1, let side = injured.first {
                Label("\(Format.side(side)) injured", systemImage: "bandage.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .listRowSeparator(.hidden, edges: .bottom)
    }

    @ViewBuilder private var footer: some View {
        let advice = model.advice(for: block)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(advice, id: \.detail) { item in
                Label(item.detail, systemImage: item.kind == .injuredTissue ? "bandage" : "exclamationmark.triangle")
                    .foregroundStyle(item.kind == .injuredTissue ? Color.secondary : Color.orange)
            }
            ForEach(mode.sides, id: \.self) { side in
                PreviousSetsNote(exercise: block.exercise, side: side, showSide: mode == .perSide)
            }
        }
        .font(.footnote)
    }
}

extension WorkoutSet {
    /// Default values for a binding whose exercise has no sets left.
    static let placeholder = WorkoutSet(workout: Workout(), position: 0, exercise: "", pattern: nil)
}

/// What was done last time for this exercise and side.
struct PreviousSetsNote: View {
    @Environment(AppModel.self) private var model
    let exercise: String
    let side: Side
    var showSide = false

    var body: some View {
        let previous = model.previousSets(exercise: exercise, side: side)
        if let first = previous.first {
            let sets = previous.map(Format.short).joined(separator: ", ")
            Text("Last time\(showSide ? ", \(Format.side(side).lowercased())" : "") (\(first.workoutDay.description)): \(sets)")
        }
    }
}

// MARK: - A round

/// One line: the set badge (also the set menu), then one cell, or a left and a
/// right cell side by side, stacked when they do not fit.
struct RoundRow: View {
    static let badgeSize: CGFloat = 34
    /// Two cells of load × reps fit side by side on the narrowest iPhone up to this text size.
    static func stacks(_ size: DynamicTypeSize) -> Bool { size > .large }
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppModel.self) private var model
    let round: SetRound
    let number: Int
    let mode: SideMode
    let injured: Set<Side>
    @State private var noteFor: WorkoutSet?
    @State private var noteText = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Menu {
                setMenu
            } label: {
                badge
            }
            .accessibilityLabel(round.isWarmup ? "Warm-up set, options" : "Set \(number), options")
            if round.isPair {
                // Left above right, each with its own done mark within reach of a thumb.
                VStack(alignment: .leading, spacing: 10) {
                    cell(.left, label: "L")
                    cell(.right, label: "R")
                }
            } else if let both = round.both {
                SetCell(set: both, partner: nil, number: number, label: nil,
                        showPain: !injured.isEmpty)
            }
        }
        .padding(.vertical, 2)
        .buttonStyle(.borderless)
        .contextMenu { setMenu }
        // Done rounds look settled; planned ones stay plain.
        .listRowBackground(round.members.allSatisfy(\.isDone) && !round.members.isEmpty
                           ? Color.green.opacity(0.09) : Color(.secondarySystemGroupedBackground))
        .alert(noteFor.map { noteTitle($0) } ?? "Note", isPresented: Binding(get: { noteFor != nil }, set: { if !$0 { noteFor = nil } })) {
            TextField("Note", text: $noteText)
            Button("Save") {
                if var set = noteFor.flatMap({ s in model.activeSets.first { $0.id == s.id } }) {
                    set.notes = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.update(set)
                }
                noteFor = nil
            }
            Button("Cancel", role: .cancel) { noteFor = nil }
        }
    }

    private var badge: some View {
        Text(round.isWarmup ? "W" : "\(number)")
            .font(.headline.monospacedDigit())
            .foregroundStyle(round.isWarmup ? Color.orange : Color.primary)
            .frame(width: Self.badgeSize, height: Self.badgeSize)
            .background(round.isWarmup ? Color.orange.opacity(0.15) : Color(.tertiarySystemFill), in: Circle())
            .contentShape(Circle())
    }

    @ViewBuilder private func cell(_ side: Side, label: String?) -> some View {
        if let set = round.set(on: side) {
            SetCell(set: set, partner: round.set(on: side == .left ? .right : .left), number: number,
                    label: label, showPain: injured.contains(side))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Button {
                model.fillMissingSide(of: round)
            } label: {
                HStack(spacing: 4) {
                    if let label { Text(label).font(.caption.weight(.bold)) }
                    Image(systemName: "plus")
                    Text(Format.side(side))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .accessibilityLabel("Add the \(Format.side(side).lowercased()) side of set \(number)")
        }
    }

    private func noteTitle(_ set: WorkoutSet) -> String {
        set.side == .both ? "Note for set \(number)" : "Note for set \(number), \(Format.side(set.side).lowercased())"
    }

    // MARK: Set menu

    @ViewBuilder private var setMenu: some View {
        Section {
            let allDone = round.members.allSatisfy(\.isDone)
            Button { model.setDone(!allDone, round) } label: {
                Label(allDone ? "Mark \(round.isPair ? "both sides" : "set") not done" : "Mark \(round.isPair ? "both sides" : "set") done",
                      systemImage: allDone ? "circle" : "checkmark.circle.fill")
            }
            if let first = round.members.first, first.convention != .bodyweight {
                Text("Load step \(Format.number(model.loadStep(for: first.exercise, unit: first.loadUnit))) \(first.loadUnit.rawValue)")
            }
        }
        Section {
            Toggle(isOn: Binding(get: { round.isWarmup }, set: { on in each { $0.isWarmup = on } })) {
                Label("Warm-up", systemImage: "flame")
            }
            Picker(selection: Binding(get: { round.members.first?.kind ?? .reps }, set: { kind in each { $0.kind = kind } })) {
                Label("Reps", systemImage: "repeat").tag(SetKind.reps)
                Label("Isometric hold", systemImage: "timer").tag(SetKind.hold)
            } label: {
                Label("Type", systemImage: "repeat")
            }
            .pickerStyle(.menu)
        }
        ForEach(round.members, id: \.id) { set in
            Section(round.isPair ? Format.side(set.side) : "") {
                Menu {
                    Picker("Pain", selection: field(set, \.pain)) {
                        Text("Not recorded").tag(Double?.none)
                        ForEach(Format.painSteps, id: \.self) { Text(Format.number($0)).tag(Double?.some($0)) }
                    }
                    Picker("Feels", selection: field(set, \.painType)) {
                        Text("Not recorded").tag(PainType?.none)
                        ForEach(PainType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(PainType?.some($0)) }
                    }
                } label: {
                    Label(set.pain.map { "Pain \(Format.number($0))" + (set.painType.map { " · \($0.rawValue)" } ?? "") } ?? "Pain and how it feels", systemImage: "bolt.heart")
                }
                Picker(selection: field(set, \.repsInReserve)) {
                    Text("Not recorded").tag(Double?.none)
                    ForEach([0.0, 1, 2, 3, 4, 5], id: \.self) { Text(Format.number($0)).tag(Double?.some($0)) }
                } label: {
                    Label("Reps in reserve", systemImage: "gauge.with.dots.needle.33percent")
                }
                .pickerStyle(.menu)
                Picker(selection: field(set, \.range)) {
                    Text("Not recorded").tag(RangeOfMotion?.none)
                    Text("Full").tag(RangeOfMotion?.some(.full))
                    Text("Partial").tag(RangeOfMotion?.some(.partial))
                    Text("Short of end range").tag(RangeOfMotion?.some(.shortOfEndRange))
                } label: {
                    Label("Range of motion", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                .pickerStyle(.menu)
                Button {
                    noteText = set.notes
                    noteFor = set
                } label: {
                    Label(set.notes.isEmpty ? "Add note…" : "Edit note…", systemImage: "note.text")
                }
            }
        }
        Section {
            if round.isPair {
                if let left = round.left, round.right != nil {
                    Button { model.copyToOtherSide(left) } label: { Label("Copy left to right", systemImage: "arrow.right") }
                }
                if let right = round.right, round.left != nil {
                    Button { model.copyToOtherSide(right) } label: { Label("Copy right to left", systemImage: "arrow.left") }
                }
                if round.left == nil || round.right == nil {
                    Button { model.fillMissingSide(of: round) } label: {
                        Label("Add the \(round.left == nil ? "left" : "right") side", systemImage: "plus")
                    }
                }
            } else if let both = round.both {
                Button { model.split(both) } label: { Label("Split into left and right", systemImage: "rectangle.split.2x1") }
            }
            Button { model.duplicate(round) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { model.remove(round) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// Applies a change to every set in the round.
    private func each(_ change: (inout WorkoutSet) -> Void) {
        for set in round.members {
            guard var current = model.activeSets.first(where: { $0.id == set.id }) else { continue }
            change(&current)
            model.update(current)
        }
    }

    private func field<Value>(_ set: WorkoutSet, _ path: WritableKeyPath<WorkoutSet, Value>) -> Binding<Value> {
        Binding(get: { (model.activeSets.first { $0.id == set.id } ?? set)[keyPath: path] },
                set: { value in
                    guard var current = model.activeSets.first(where: { $0.id == set.id }) else { return }
                    current[keyPath: path] = value
                    model.update(current)
                })
    }
}

// MARK: - A set

/// Load × reps (or seconds), with last session's numbers as the placeholders,
/// the pain chip, and tags for anything set from the menu.
struct SetCell: View {
    @Environment(AppModel.self) private var model
    let set: WorkoutSet
    let partner: WorkoutSet?
    let number: Int
    let label: String?
    /// The pain chip is always shown where an injured tissue is loaded, and
    /// elsewhere once a pain has been recorded.
    let showPain: Bool
    @State private var draft: WorkoutSet
    @State private var timingHold = false
    @ScaledMetric(relativeTo: .body) private var loadWidth: CGFloat = 58
    @ScaledMetric(relativeTo: .body) private var repsWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var checkSize: CGFloat = 40

    init(set: WorkoutSet, partner: WorkoutSet?, number: Int, label: String?, showPain: Bool) {
        self.set = set; self.partner = partner; self.number = number; self.label = label; self.showPain = showPain
        _draft = State(initialValue: set)
    }

    private var previous: WorkoutSet? {
        let rounds = model.block(set.exercise).rounds
        let index = rounds.firstIndex { $0.members.contains { $0.id == set.id } } ?? 0
        return model.previousSet(exercise: set.exercise, side: set.side, index: index)
    }

    private var sideWords: String { (self.set.side == .both ? "" : ", \(Format.side(self.set.side).lowercased())") + ", \(self.set.exercise)" }
    private var unitWords: String { draft.loadUnit == .lb ? "pounds" : "kilograms" }

    var body: some View {
        let last = previous
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let label {
                    Text(label).font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(minWidth: 12)
                }
                if draft.convention == .bodyweight {
                    Text("BW").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .frame(width: loadWidth)
                        .accessibilityLabel("Body weight")
                } else {
                    NumberField(title: Format.number(last?.loadValue).ifEmpty(draft.loadUnit.rawValue),
                                value: $draft.loadValue, width: loadWidth, step: loadStep)
                        .accessibilityLabel("Set \(number)\(sideWords), \(unitWords)")
                }
                Text("×").foregroundStyle(.secondary).accessibilityHidden(true)
                if draft.kind == .hold {
                    NumberField(title: Format.number(last?.holdSeconds).ifEmpty("s"), value: $draft.holdSeconds,
                                width: repsWidth, decimal: false, step: countStep)
                        .accessibilityLabel("Set \(number)\(sideWords), seconds held")
                    Text("s").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                } else {
                    NumberField(title: Format.number(last?.reps).ifEmpty("rep"), value: $draft.reps,
                                width: repsWidth, decimal: false, step: countStep)
                        .accessibilityLabel("Set \(number)\(sideWords), reps")
                }
                Spacer(minLength: 4)
                if draft.kind == .hold && !draft.isDone {
                    Button { timingHold = true } label: {
                        Image(systemName: "stopwatch").font(.title3).frame(width: checkSize, height: checkSize)
                    }
                    .accessibilityLabel("Time the hold")
                }
                doneButton
            }
            let tags = self.tags
            // Records are only claimed for a set marked done.
            let records = draft.isDone ? model.recordsBroken(by: draft) : []
            if !records.isEmpty {
                HStack(spacing: 4) {
                    ForEach(records, id: \.self) { kind in
                        Label(kind.shortLabel, systemImage: "trophy.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(Color.orange)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                }
                .accessibilityLabel("Record: " + records.map(\.shortLabel).joined(separator: ", "))
            }
            if showPain || draft.pain != nil || !tags.isEmpty {
                WrapStack(spacing: 6) {
                    if showPain || draft.pain != nil {
                        PainChip(pain: $draft.pain, type: $draft.painType, context: "Set \(number)\(sideWords)")
                    }
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
            }
                if let last, lastDiffers(last) {
                    Button {
                        draft.copyPrescription(from: last)
                    } label: {
                        Text("last \(Format.short(last))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityLabel("Use last session's \(Format.short(last))")
                }
            if !draft.notes.isEmpty {
                Text(draft.notes).font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
            }
        }
        // Saved as it changes, so nothing typed is lost if the app is closed.
        .onChange(of: draft) { _, changed in model.update(changed, partner: partner) }
        // Changes made elsewhere (the menus, the linked side) come back in.
        .onChange(of: set) { _, changed in
            var mine = draft
            mine.updatedAt = changed.updatedAt
            if mine != changed { draft = changed }
        }
    }

    /// A large check at the row's end: planned until tapped, then done (and the rest starts).
    private var doneButton: some View {
        Button {
            model.setDone(!draft.isDone, draft)
        } label: {
            Image(systemName: draft.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: checkSize * 0.75, weight: .regular))
                .foregroundStyle(draft.isDone ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: checkSize, height: checkSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Set \(number)\(sideWords) done")
        .accessibilityValue(draft.isDone ? "done" : "not done")
        .sheet(isPresented: $timingHold) {
            HoldTimerView(set: draft).presentationDetents([.medium])
        }
    }

    private var loadStep: StepAction {
        let step = model.loadStep(for: draft.exercise, unit: draft.loadUnit)
        return StepAction(id: draft.id + "|load", label: "\(Format.number(step)) \(draft.loadUnit.rawValue)",
                          minus: { draft = model.stepped(draft, load: -1) },
                          plus: { draft = model.stepped(draft, load: 1) })
    }

    private var countStep: StepAction {
        StepAction(id: draft.id + "|count", label: draft.kind == .hold ? "5 s" : "1 rep",
                   minus: { draft = model.stepped(draft, count: -1) },
                   plus: { draft = model.stepped(draft, count: 1) })
    }

    private func lastDiffers(_ last: WorkoutSet?) -> Bool {
        guard let last else { return false }
        return last.loadValue != draft.loadValue || last.reps != draft.reps || last.holdSeconds != draft.holdSeconds
    }

    private var tags: [String] {
        var out: [String] = []
        // A slip of the thumb ("1015 lb") is shown, not silently counted.
        let heavy = draft.loadUnit == .lb ? 1000.0 : 450.0
        if (draft.loadValue ?? 0) > heavy || (draft.reps ?? 0) > 100 || (draft.holdSeconds ?? 0) > 900 {
            out.append("check this number")
        }
        if let rir = draft.repsInReserve { out.append("RIR \(Format.number(rir))") }
        switch draft.range {
        case .partial: out.append("partial")
        case .shortOfEndRange: out.append("short of end range")
        case .full: out.append("full range")
        case nil: break
        }
        return out
    }
}

/// Pain for one set: dashed while not recorded (never shown as zero), filled
/// and coloured once given. Opens a small grid of half steps and the words.
struct PainChip: View {
    @Binding var pain: Double?
    @Binding var type: PainType?
    let context: String
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "bolt.heart.fill")
                Text(pain.map { Format.number($0) } ?? "pain")
                if let type { Text(type.rawValue) }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(pain == nil ? Color.secondary : Format.painColor(pain))
            .background(pain == nil ? Color.clear : Format.painColor(pain).opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(pain == nil ? Color.secondary.opacity(0.6) : Format.painColor(pain),
                                            style: StrokeStyle(lineWidth: 1, dash: pain == nil ? [3, 2] : [])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(context), pain")
        .accessibilityValue(pain.map { "\(Format.number($0)) out of 10" } ?? "not recorded")
        .popover(isPresented: $open) {
            PainPicker(pain: $pain, type: $type) { open = false }
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct PainPicker: View {
    @Binding var pain: Double?
    @Binding var type: PainType?
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pain").font(.headline)
                Spacer()
                Button("Not recorded") { pain = nil; type = nil; done() }.font(.footnote)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(Format.painSteps, id: \.self) { step in
                    let chosen = pain == step
                    Button {
                        pain = step
                    } label: {
                        Text(Format.number(step))
                            .font(.callout.monospacedDigit().weight(chosen ? .bold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(chosen ? Format.painColor(step) : Format.painColor(step).opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(chosen ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Feels").font(.subheadline.weight(.semibold)).padding(.top, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(PainType.allCases, id: \.self) { word in
                    let chosen = type == word
                    Button {
                        type = chosen ? nil : word
                    } label: {
                        Text(word.rawValue)
                            .font(.footnote)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(chosen ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(chosen ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 330)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// Lays its pieces out in lines, wrapping to the next line when one is full.
struct WrapStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? widest
        return arrange(subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(subviews, width: bounds.width).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return (points, CGSize(width: min(widest, width), height: y + line))
    }
}

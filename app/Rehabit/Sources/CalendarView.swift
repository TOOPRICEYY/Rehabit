import RehabitCore
import SwiftUI

/// The history as a month: which days had sessions, the highest pain answered
/// each day, and flare-ups. Tapping a day lists its workouts.
struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var year: Int
    @State private var month: Int
    @State private var selected: Day?

    init() {
        let today = Day(Date()).components
        _year = State(initialValue: today.year)
        _month = State(initialValue: today.month)
    }

    var body: some View {
        let days = model.calendar(year: year, month: month)
        let selectedDay = days.first { $0.day == selected }
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                MonthGrid(days: days, selected: $selected)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
            } footer: {
                legend
            }
            Section {
                MonthSummary(days: days)
            }
            if let selectedDay {
                DaySection(day: selectedDay)
            } else {
                Section {
                    Text("Tap a day to see what was logged on it.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var monthTitle: String { Day(year: year, month: month, day: 1).readableMonth }

    private var isCurrentMonth: Bool {
        let today = Day(Date()).components
        return today.year == year && today.month == month
    }

    private var header: some View {
        HStack {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Previous month")
            Spacer()
            Text(monthTitle)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("calendar-month")
            Spacer()
            Button { step(1) } label: {
                Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Next month")
            .disabled(isCurrentMonth)
        }
        .buttonStyle(.borderless)
    }

    private var legend: some View {
        // In a row when it fits, one under another at large text sizes.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems }
            VStack(alignment: .leading, spacing: 4) { legendItems }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A dot marks a day with a session, a number is the highest pain answered that day, and a bolt marks a flare-up.")
    }

    @ViewBuilder private var legendItems: some View {
        Group {
            HStack(spacing: 4) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                Text("Session")
            }
            HStack(spacing: 4) {
                Text("3").font(.caption2.weight(.semibold).monospacedDigit())
                Text("Highest pain answered")
            }
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                Text("Flare-up")
            }
        }
        .fixedSize()
    }

    private func step(_ by: Int) {
        var m = month + by, y = year
        if m < 1 { m = 12; y -= 1 }
        if m > 12 { m = 1; y += 1 }
        month = m; year = y
        selected = nil
    }
}

/// "4 sessions · highest pain 3 · 1 flare-up" for the month shown.
private struct MonthSummary: View {
    let days: [CalendarDay]

    var body: some View {
        let sessions = days.reduce(0) { $0 + $1.workouts.count }
        let active = days.filter { !$0.workouts.isEmpty }.count
        let flares = days.reduce(0) { $0 + $1.flares }
        let pain = days.compactMap(\.painHigh).max()
        var parts = [Format.count(sessions, "session")]
        if sessions > 0 { parts.append("on \(Format.count(active, "day"))") }
        if let pain { parts.append("highest pain \(Format.number(pain))") }
        if flares > 0 { parts.append(Format.count(flares, "flare-up")) }
        return Text(parts.joined(separator: " · "))
            .font(.subheadline)
            .accessibilityIdentifier("calendar-summary")
    }
}

/// The days of a month in weeks, starting on the locale's first weekday.
private struct MonthGrid: View {
    let days: [CalendarDay]
    @Binding var selected: Day?

    private var calendar: Foundation.Calendar { .current }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let full = calendar.standaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let order = (0..<7).map { (first + $0) % 7 }
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(order.map { $0 + 100 }, id: \.self) { key in
                let index = key - 100
                Text(symbols[index])
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(full[index])
            }
            ForEach((0..<leadingBlanks).map { "blank-\($0)" }, id: \.self) { _ in
                Color.clear.frame(height: 1).accessibilityHidden(true)
            }
            ForEach(days) { day in
                DayCell(day: day, isSelected: selected == day.day, isToday: day.day == Day(Date())) {
                    selected = selected == day.day ? nil : day.day
                }
            }
        }
        // The grid keeps seven columns; past this size the numbers no longer fit.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var leadingBlanks: Int {
        guard let first = days.first else { return 0 }
        let weekday = calendar.component(.weekday, from: first.day.start())
        return (weekday - calendar.firstWeekday + 7) % 7
    }
}

private struct DayCell: View {
    let day: CalendarDay
    let isSelected: Bool
    let isToday: Bool
    let tap: () -> Void
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 58

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 2) {
                Text("\(day.day.components.day)")
                    .font(.callout.monospacedDigit().weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(minWidth: 28, minHeight: 28)
                    .background {
                        if isSelected {
                            Circle().fill(Color.accentColor)
                        } else if isToday {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                HStack(spacing: 3) {
                    if !day.workouts.isEmpty {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                    if let pain = day.painHigh {
                        Text(Format.number(pain))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 3)
                            .background(Format.painColor(pain).opacity(0.25), in: Capsule())
                    }
                    if day.flares > 0 {
                        HStack(spacing: 0) {
                            Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.orange)
                            if let flare = day.flareHigh, flare > (day.painHigh ?? -1) {
                                Text(Format.number(flare))
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.orange)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                    }
                }
                .frame(minHeight: 14)
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Days still to come have nothing to show yet.
        .disabled(day.day > Day(Date()))
        .opacity(day.day > Day(Date()) ? 0.35 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("calendar-day-\(day.day.description)")
    }

    /// "Nov 12: 1 session, pain 3, flare-up".
    private var label: String {
        let c = day.day.components
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var parts: [String] = []
        if !day.workouts.isEmpty { parts.append(Format.count(day.workouts.count, "session")) }
        if let pain = day.painHigh { parts.append("pain \(Format.number(pain))") }
        let worst = day.flareHigh.map { " up to \(Format.number($0))" } ?? ""
        if day.flares == 1 { parts.append("flare-up\(worst)") } else if day.flares > 1 { parts.append("\(day.flares) flare-ups\(worst)") }
        if parts.isEmpty { parts.append("nothing logged") }
        return "\(months[c.month - 1]) \(c.day)\(isToday ? ", today" : ""): " + parts.joined(separator: ", ")
    }
}

/// What was logged on one day: its workouts, to open, and its pain.
private struct DaySection: View {
    @Environment(AppModel.self) private var model
    let day: CalendarDay

    var body: some View {
        Section {
            if day.isEmpty {
                Text("Nothing logged.").foregroundStyle(.secondary)
            }
            ForEach(day.workouts) { workout in
                NavigationLink {
                    WorkoutDetailView(workout: workout)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.title)
                        Text(detail(workout)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let pain = day.painHigh {
                LabeledContent("Highest pain answered", value: Format.number(pain))
            }
            if let pain = day.setPain {
                LabeledContent("Highest pain on a set", value: Format.number(pain))
            }
            if day.flares > 0 {
                Label {
                    Text((day.flares == 1 ? "1 flare-up logged" : "\(day.flares) flare-ups logged")
                         + (day.flareHigh.map { ", worst \(Format.number($0))" } ?? ""))
                } icon: {
                    Image(systemName: "bolt.fill").foregroundStyle(.orange)
                }
            }
        } header: {
            Text(day.day.readable)
        }
    }

    private func detail(_ workout: Workout) -> String {
        var parts = [workout.start.formatted(date: .omitted, time: .shortened),
                     Format.count(model.sets(of: workout).count, "set")]
        if let minutes = workout.minutes, minutes >= 1 { parts.append("\(Int(minutes)) min") }
        if let effort = workout.effort { parts.append("effort \(Format.number(effort))") }
        return parts.joined(separator: " · ")
    }
}

import SwiftUI

/// Heatmap colours for the calendar. Deliberately pale: the day number sits on
/// top, and a saturated fill would swamp it. Every step keeps the near-black
/// numeral above 7:1 contrast.
extension DayGrade {
    var fill: Color? {
        switch self {
        case .empty: return nil
        case .none:  return Color(red: 0xF6 / 255, green: 0xC9 / 255, blue: 0xC5 / 255)
        case .low:   return Color(red: 0xE2 / 255, green: 0xEF / 255, blue: 0xCF / 255)
        case .high:  return Color(red: 0xBF / 255, green: 0xE2 / 255, blue: 0xC2 / 255)
        case .all:   return Color(red: 0x86 / 255, green: 0xCB / 255, blue: 0x92 / 255)
        }
    }

    var ink: Color {
        self == .empty ? .primary
                       : Color(red: 0x14 / 255, green: 0x1C / 255, blue: 0x14 / 255)
    }

    var caption: String {
        switch self {
        case .empty: return "no goals"
        case .none:  return "none done"
        case .low:   return "under half done"
        case .high:  return "over half done"
        case .all:   return "all done"
        }
    }
}

/// A month calendar tinted by how much of each day's plan got done.
///
/// Custom-built rather than using `DatePicker`/`MonthCalendar`: neither can be
/// coloured per day. Compact mode is a date picker; expanded mode lists each
/// day's goals in the cell, the way a calendar app does.
struct HeatCalendar: View {
    @EnvironmentObject var store: Store

    @Binding var expanded: Bool
    let onPick: (Date) -> Void

    /// The month on display, which is not always the selected day's month.
    @State private var month: Date = Date()
    @State private var hovered: Date?
    @State private var didSyncMonth = false

    private var cellWidth: CGFloat { expanded ? 132 : 34 }
    private var cellHeight: CGFloat { expanded ? 76 : 30 }

    private var selected: Date {
        DateUtil.date(fromKey: store.selectedDay) ?? Date()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdayRow
            grid
            footer
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            // Only on first appearance: reopening should not yank the user out
            // of a month they were browsing.
            if !didSyncMonth {
                month = startOfMonth(selected)
                didSyncMonth = true
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 6) {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Previous month")

            Spacer(minLength: 4)
            Text(monthLabel)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)

            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .help("Next month")

            Button { expanded.toggle() } label: {
                Image(systemName: expanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help(expanded ? "Shrink the calendar" : "Expand to show goals")
        }
        .padding(.bottom, 6)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdayNames.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.system(size: expanded ? 10 : 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: cellWidth)
            }
        }
        .padding(.bottom, 2)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        cell(for: dayAt(row: row, column: col))
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text("none").font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach([DayGrade.none, .low, .high, .all], id: \.caption) { grade in
                RoundedRectangle(cornerRadius: 2)
                    .fill(grade.fill ?? .clear)
                    .frame(width: 12, height: 9)
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(white: 0.85), lineWidth: 0.5))
                    .help(grade.caption)
            }
            Text("all").font(.system(size: 9)).foregroundStyle(.secondary)

            Spacer(minLength: 6)

            // .bordered rather than .link: the link style is nearly invisible
            // against the card, and this is a real action.
            Button("Today") {
                month = startOfMonth(Date())
                onPick(Calendar.current.startOfDay(for: Date()))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 10, weight: .semibold))
        }
        .padding(.top, 8)
    }

    // MARK: - One day

    @ViewBuilder
    private func cell(for day: Date) -> some View {
        let key = DateUtil.key(day)
        let score = store.dayScore(key)
        let grade = DayGrade.grade(done: score.done, total: score.total)
        let inMonth = Calendar.current.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = Calendar.current.isDateInToday(day)
        let isSelected = Calendar.current.isDate(day, inSameDayAs: selected)

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: expanded ? 11 : 11,
                                  weight: isToday ? .bold : .regular))
                    .foregroundStyle(grade.ink)
                if expanded {
                    Spacer(minLength: 0)
                    if score.total > 0 {
                        // A tally keeps the count readable when titles truncate.
                        Text("\(score.done)/\(score.total)")
                            .font(.system(size: 9))
                            .foregroundStyle(grade.ink.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)

            if expanded { goalLines(for: key) }
        }
        .padding(expanded ? 4 : 0)
        .frame(width: cellWidth - 3, height: cellHeight - 3,
               alignment: expanded ? .topLeading : .center)
        .background(RoundedRectangle(cornerRadius: 4).fill(grade.fill ?? .clear))
        .overlay(cellBorder(grade: grade, inMonth: inMonth,
                            isToday: isToday, isSelected: isSelected, day: day))
        .opacity(inMonth ? 1 : 0.42)
        .frame(width: cellWidth, height: cellHeight)
        .contentShape(Rectangle())
        .onTapGesture { onPick(day) }
        .onHover { hovered = $0 ? day : (hovered == day ? nil : hovered) }
        .help(tooltip(for: day, score: score))
    }

    @ViewBuilder
    private func cellBorder(grade: DayGrade, inMonth: Bool,
                            isToday: Bool, isSelected: Bool, day: Date) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2)
        } else if isToday {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        } else if hovered == day {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1.4)
        } else if expanded && grade == .empty {
            // Expanded cells need a frame or the grid dissolves into the card.
            RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.88), lineWidth: 0.5)
        }
    }

    /// The day's goals, as many as fit, with a "+N more" line when they do not.
    @ViewBuilder
    private func goalLines(for key: String) -> some View {
        let goals = store.goals(on: key)
        // Cell height minus the number strip, divided by the line height.
        let capacity = 3
        let shown = goals.count <= capacity ? goals.count : max(0, capacity - 1)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(goals.prefix(shown)) { goal in
                HStack(spacing: 3) {
                    statusPip(goal.status)
                    Text(goal.title)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .strikethrough(goal.status == .done)
                        .foregroundStyle(goal.status == .done
                                         ? Color.primary.opacity(0.55)
                                         : Color.primary)
                }
                .frame(height: 12, alignment: .leading)
            }
            if shown < goals.count {
                Text("+\(goals.count - shown) more")
                    .font(.system(size: 9)).italic()
                    .foregroundStyle(.secondary)
                    .frame(height: 12, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func statusPip(_ status: GoalStatus) -> some View {
        switch status {
        case .done:
            Circle().fill(Color(red: 0.08, green: 0.50, blue: 0.24))
                .frame(width: 5, height: 5)
        case .unfinished:
            Image(systemName: "xmark")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(Color(red: 0.73, green: 0.11, blue: 0.11))
                .frame(width: 5, height: 5)
        case .pending:
            Circle().stroke(Color(red: 0.71, green: 0.33, blue: 0.04), lineWidth: 1)
                .frame(width: 5, height: 5)
        }
    }

    // MARK: - Helpers

    private func tooltip(for day: Date, score: (done: Int, total: Int)) -> String {
        let label = DateUtil.pretty(DateUtil.key(day))
        if score.total == 0 { return "\(label) — no goals" }
        return "\(label) — \(score.done) of \(score.total) done"
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: month)
    }

    private var weekdayNames: [String] {
        expanded
            ? ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            : ["M", "T", "W", "T", "F", "S", "S"]
    }

    private func startOfMonth(_ date: Date) -> Date {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return Calendar.current.date(from: c) ?? date
    }

    private func shiftMonth(_ delta: Int) {
        month = Calendar.current.date(byAdding: .month, value: delta, to: month) ?? month
    }

    /// The Monday on or before the first of the displayed month, plus an offset.
    private func dayAt(row: Int, column: Int) -> Date {
        let first = startOfMonth(month)
        // Calendar.weekday is 1 = Sunday; shift so Monday is 0.
        let weekday = Calendar.current.component(.weekday, from: first)
        let offset = (weekday + 5) % 7
        let start = Calendar.current.date(byAdding: .day, value: -offset, to: first) ?? first
        return Calendar.current.date(byAdding: .day, value: row * 7 + column, to: start) ?? start
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ticker: Ticker

    @State private var showCalendar = false
    @AppStorage("calendarExpanded") private var calendarExpanded = false

    var body: some View {
        HSplitView {
            GoalsPane()
                .frame(minWidth: 400, idealWidth: 560)
            SidePane()
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
        }
        .safeAreaInset(edge: .top) {
            if let error = store.lastError {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reload") { store.load() }
                    Button("Dismiss") { store.dismissError() }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.16))
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            DayToolbar(showCalendar: $showCalendar,
                       calendarExpanded: $calendarExpanded)
        }
        .navigationTitle("Daily Plan")
        .navigationSubtitle(DateUtil.pretty(store.selectedDay))
    }
}

// MARK: - Toolbar

struct DayToolbar: ToolbarContent {
    @EnvironmentObject var store: Store
    @Binding var showCalendar: Bool
    @Binding var calendarExpanded: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button { store.shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous day")

            // A button that drops the heat calendar, not a DatePicker: the
            // stock picker cannot be coloured per day.
            Button {
                showCalendar.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                    Text(dateLabel).monospacedDigit()
                }
                .frame(minWidth: 132)
            }
            .help("Pick a day — the colours show how each day went")
            .popover(isPresented: $showCalendar, arrowEdge: .bottom) {
                HeatCalendar(expanded: $calendarExpanded) { day in
                    store.goToDay(DateUtil.key(day))
                    // The expanded view doubles as a month overview, so it
                    // stays open; the compact one behaves like a date picker.
                    if !calendarExpanded { showCalendar = false }
                }
                .environmentObject(store)
            }

            Button { store.shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .help("Next day")

            Button("Today") { store.goToToday() }
                .disabled(store.selectedDay == DateUtil.todayKey)
        }
    }

    private var dateLabel: String {
        guard let d = DateUtil.date(fromKey: store.selectedDay) else {
            return store.selectedDay
        }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return f.string(from: d)
    }
}

// MARK: - Goals

struct GoalsPane: View {
    @EnvironmentObject var store: Store
    @State private var draft = ""
    @State private var editingGoal: Goal?
    @State private var editingField: EditField = .title
    @State private var reflection = ""
    @State private var showHistory = false
    @State private var draggingGoal: Int?
    @FocusState private var draftFocused: Bool

    enum EditField { case title, note }

    private var done: Int { store.goals.filter { $0.status == .done }.count }

    var body: some View {
        // VSplitView so the Goals/Reflection divider can be dragged. AppKit
        // owns the drag, the cursor, and the double-click collapse.
        VSplitView {
            goalsSection
                .frame(minHeight: 220, idealHeight: 420)
            bottomSection
                .frame(minHeight: 150)
        }
        .onAppear { reflection = store.entry.reflection }
        .onChange(of: store.selectedDay) { _, _ in
            reflection = store.entry.reflection
            editingGoal = nil
        }
    }

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                addRow
                progressRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.goals.isEmpty {
                        Text("No goals yet. What is the plan for this day?")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        ForEach(Array(store.goals.enumerated()), id: \.element.id) { index, goal in
                            VStack(spacing: 0) {
                                GoalRow(goal: goal,
                                        isFirst: index == 0,
                                        isLast: index == store.goals.count - 1,
                                        editing: editingGoal?.id == goal.id ? editingField : nil,
                                        onEdit: { field in
                                            editingGoal = goal
                                            editingField = field
                                        },
                                        // Only close the editor this row opened: a title losing
                                        // focus must not close the note editor that took over.
                                        onDismissEdit: { field in
                                            if editingGoal?.id == goal.id, editingField == field {
                                                editingGoal = nil
                                            }
                                        },
                                        onDragStart: { draggingGoal = goal.id })
                                if index < store.goals.count - 1 { Divider() }
                            }
                            .onDrop(of: [.text], delegate: GoalDropDelegate(target: goal, store: store,
                                                                            dragging: $draggingGoal))
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            Button {
                let n = store.carryOver()
                Toast.show(n > 0 ? "Carried over \(n) goal\(n == 1 ? "" : "s")."
                                 : "Nothing unfinished to carry over.")
            } label: {
                Label("Carry over unfinished from \(DateUtil.shift(store.selectedDay, by: -1))",
                      systemImage: "arrow.uturn.down")
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var bottomSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                reflectionSection
                Divider()
                historySection
            }
            .padding(20)
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("What do you want to get done?", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($draftFocused)
                .onSubmit(submit)
            Button("Add", action: submit)
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() {
        let (added, skipped) = store.addGoals(draft)
        if added > 0 { draft = "" }
        if skipped > 0 {
            Toast.show(added > 0
                       ? "Added \(added), skipped \(skipped) already on this day."
                       : "Already on this day.")
        }
        draftFocused = true
    }

    private var progressRow: some View {
        HStack(spacing: 10) {
            ProgressView(value: store.goals.isEmpty ? 0 : Double(done),
                         total: Double(max(store.goals.count, 1)))
                .progressViewStyle(.linear)
                .tint(.green)
            Text("\(done) / \(store.goals.count)")
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var reflectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reflection").font(.headline)
            TextEditor(text: $reflection)
                .font(.body)
                .frame(minHeight: 70)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(white: 0.85)))
                .onChange(of: reflection) { _, text in
                    // Debounced by the store: identical text is a no-op.
                    store.setReflection(text)
                }
            Text("Saves automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var historySection: some View {
        DisclosureGroup("History", isExpanded: $showHistory) {
            let rows = store.historyDays
            if rows.isEmpty {
                Text("No history yet.").foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.day) { row in
                        Button { store.goToDay(row.day) } label: {
                            HStack {
                                Text(row.day).monospacedDigit()
                                Spacer()
                                Text("\(row.score) / \(row.total)")
                                    .monospacedDigit().foregroundStyle(.secondary)
                                Text("\(Int((100.0 * Double(row.score) / Double(max(row.total, 1))).rounded()))%")
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(.top, 6)
            }
        }
        .font(.headline)
    }
}

// MARK: - One goal row

struct GoalRow: View {
    @EnvironmentObject var store: Store
    let goal: Goal
    let isFirst: Bool
    let isLast: Bool
    let editing: GoalsPane.EditField?
    let onEdit: (GoalsPane.EditField) -> Void
    let onDismissEdit: (GoalsPane.EditField) -> Void
    let onDragStart: () -> Void

    @State private var hovering = false
    @State private var confirmingDelete = false
    @State private var titleDraft = ""
    @State private var titleEditActive = false
    @State private var noteDraft = ""
    @State private var noteEditor = NoteEditorProxy()
    @State private var showLinkForm = false
    @State private var linkRange = NSRange()
    @State private var linkText = ""
    @State private var linkURL = ""
    @FocusState private var titleFocused: Bool

    private var statusColor: Color {
        switch goal.status {
        case .done: return Color(red: 0.08, green: 0.50, blue: 0.24)
        case .pending: return Color(red: 0.71, green: 0.33, blue: 0.04)
        case .unfinished: return Color(red: 0.73, green: 0.11, blue: 0.11)
        }
    }

    private var statusFill: Color {
        switch goal.status {
        case .done: return Color(red: 0.91, green: 0.97, blue: 0.93)
        case .pending: return Color(red: 0.99, green: 0.96, blue: 0.91)
        case .unfinished: return Color(red: 0.99, green: 0.93, blue: 0.92)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // A hint that the row can be dragged; the whole row is the handle.
            // Lives in the list's left margin, so rows don't shift to make room.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 10, height: 20)
                .opacity(hovering && editing == nil ? 1 : 0)
                .help("Drag the row to reorder")

            HStack(alignment: .top, spacing: 10) {
                Button { store.cycleStatus(goal) } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(statusFill)
                        RoundedRectangle(cornerRadius: 5).stroke(statusColor.opacity(0.45))
                        if goal.status == .done {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        } else if goal.status == .unfinished {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .foregroundStyle(statusColor)
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("\(goal.status.label) — click to change")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if editing == .title {
                            titleField
                        } else {
                            Text(goal.title)
                                .strikethrough(goal.status == .done)
                                .foregroundStyle(goal.status == .done ? .secondary : .primary)
                                .onTapGesture(count: 2) { begin(.title) }
                        }
                        Text(goal.status.label.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(statusFill, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(statusColor)
                    }
                    if editing == .title {
                        Text("↵ to save · Esc to cancel")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if editing == .note {
                        noteEditorView
                    } else if !goal.note.isEmpty {
                        NoteView(text: .constant(goal.note), editable: false)
                            // The note lets clicks through except on links, so a shape
                            // behind it catches the double-click and links keep theirs.
                            .background(Color.clear.contentShape(Rectangle())
                                .onTapGesture(count: 2) { begin(.note) })
                    }
                    if let from = goal.carriedFrom, editing == nil {
                        Text("carried from \(from)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 4)

                if confirmingDelete {
                    HStack(spacing: 4) {
                        Button("Delete?") { store.delete(goal); confirmingDelete = false }
                            .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                        Button("Keep") { confirmingDelete = false }.controlSize(.small)
                    }
                } else if hovering || editing != nil {
                    HStack(spacing: 2) {
                        iconButton("chevron.up", "Move up") { store.move(goal, up: true) }
                            .disabled(isFirst)
                        iconButton("chevron.down", "Move down") { store.move(goal, up: false) }
                            .disabled(isLast)
                        iconButton("pencil", "Edit title") { begin(.title) }
                        iconButton(goal.note.isEmpty ? "plus.bubble" : "text.bubble",
                                   goal.note.isEmpty ? "Add note" : "Edit note") { begin(.note) }
                        iconButton("trash", "Delete goal") { confirmingDelete = true }
                    }
                }
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        // Drag from anywhere on the row. Buttons and text editors track their
        // own mouse, so clicking them and selecting text are unaffected.
        .onDrag {
            onDragStart()
            return NSItemProvider(object: goal.title as NSString)
        } preview: {
            Text(goal.title)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.6)))
        }
        .onHover { hovering = $0 }
        .background(confirmingDelete ? Color.red.opacity(0.06) : .clear)
        .padding(.leading, -14)
    }

    /// Edits the title where it sits: same font, same position, as wide as the
    /// text itself, with only a light frame drawn around it.
    private var titleField: some View {
        // A text field fills all the width it is offered; laying it over an
        // invisible copy of the title makes it exactly the title's size.
        Text((titleDraft.isEmpty ? "Goal title" : titleDraft) + "   ")
            .lineLimit(1)
            .opacity(0)
            .overlay(alignment: .leading) {
                TextField("Goal title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit(saveTitle)
                    .onExitCommand(perform: cancelTitle)
                    .onChange(of: titleFocused) { _, focused in
                        // Clicking away keeps the edit, as in Finder.
                        if !focused && commitTitle() { onDismissEdit(.title) }
                    }
            }
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .textBackgroundColor)).padding(-3))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor.opacity(0.7)).padding(-3))
    }

    private var noteEditorView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                iconButton("bold", "Bold (⌘B)") { noteEditor.textView?.formatBold() }
                iconButton("italic", "Italic (⌘I)") { noteEditor.textView?.formatItalic() }
                Divider().frame(height: 12).padding(.horizontal, 4)
                iconButton("list.bullet", "Bulleted list") { noteEditor.textView?.formatList(numbered: false) }
                iconButton("list.number", "Numbered list") { noteEditor.textView?.formatList(numbered: true) }
                Divider().frame(height: 12).padding(.horizontal, 4)
                iconButton("decrease.indent", "Outdent (⇧⇥)") { noteEditor.textView?.formatOutdent() }
                iconButton("increase.indent", "Indent (⇥)") { noteEditor.textView?.formatIndent() }
                Divider().frame(height: 12).padding(.horizontal, 4)
                iconButton("link", "Insert link (⌘K)", action: openLinkForm)
                    .popover(isPresented: $showLinkForm, arrowEdge: .bottom) {
                        LinkForm(text: $linkText, url: $linkURL) { text, url in
                            showLinkForm = false
                            noteEditor.textView?.insertLink(text: text, url: url, replacing: linkRange)
                        }
                    }
            }
            NoteView(text: $noteDraft, editable: true, proxy: noteEditor,
                     onDone: finishNote, onLinkRequest: openLinkForm)
                .frame(minHeight: 54)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor))
            HStack(spacing: 6) {
                Button("Done", action: finishNote)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Spacer()
                Text("Saves as you type · ⌘↵ or Esc to close")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 3)
        .onChange(of: noteDraft) { _, text in store.update(goal, note: text) }
    }

    private func iconButton(_ symbol: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(help)
    }

    private func begin(_ field: GoalsPane.EditField) {
        if field == .title {
            titleDraft = goal.title
            titleEditActive = true
        } else {
            noteDraft = goal.note
        }
        onEdit(field)
        if field == .title { DispatchQueue.main.async { titleFocused = true } }
    }

    private func saveTitle() {
        guard !titleDraft.trimmingCharacters(in: .whitespaces).isEmpty else {
            Toast.show("Title cannot be empty.", isError: true); return
        }
        if commitTitle() { onDismissEdit(.title) }
    }

    /// Runs at most once per edit, whether it ends by Return or by focus moving away.
    private func commitTitle() -> Bool {
        guard titleEditActive else { return true }
        guard store.update(goal, title: titleDraft) else {
            Toast.show("Title was not saved. Keep this draft and try again.", isError: true)
            return false
        }
        titleEditActive = false
        return true
    }

    private func cancelTitle() {
        titleEditActive = false
        onDismissEdit(.title)
    }

    private func finishNote() {
        guard store.update(goal, note: noteDraft) else {
            Toast.show("Note was not saved. Keep this draft and try again.", isError: true)
            return
        }
        onDismissEdit(.note)
    }

    private func openLinkForm() {
        guard let tv = noteEditor.textView else { return }
        linkRange = tv.selectedRange()
        let selected = (tv.string as NSString).substring(with: linkRange)
        // A selected address becomes the URL; any other selection is the text to show.
        (linkText, linkURL) = NoteFormat.isURL(selected) ? ("", selected) : (selected, "")
        showLinkForm = true
    }
}

/// Reorders live as a goal is dragged across its siblings, so the list itself
/// is the preview. Each crossing is one ordinary `reorder`.
struct GoalDropDelegate: DropDelegate {
    let target: Goal
    let store: Store
    @Binding var dragging: Int?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let id = dragging else { return }
        withAnimation(.easeInOut(duration: 0.15)) { store.moveGoal(id, to: target.id) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Right-hand side

struct SidePane: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HeroPanel()
                CountdownPanel()
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}

struct HeroPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.stats
        let r = store.rank

        VStack(alignment: .leading, spacing: 10) {
            Text("HEROIC PANEL")
                .font(.system(size: 10, weight: .semibold)).kerning(1.2)
                .foregroundStyle(.white.opacity(0.85))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r.name).font(.system(size: 24, weight: .semibold))
                Text("Lv \(r.level)").font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)

            ProgressView(value: r.progress)
                .progressViewStyle(.linear)
                .tint(.white)

            Text(r.next == nil
                 ? "Maximum rank reached."
                 : "\(r.next! - s.total) more point\(r.next! - s.total == 1 ? "" : "s") to \(r.nextName ?? "")")
                .font(.caption).foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 8) {
                statTile("\(s.total)", "TOTAL")
                statTile("\(s.today)", "TODAY")
                statTile("\(s.currentStreak)", "STREAK")
                statTile("\(s.bestDayScore)", "BEST DAY")
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.23, blue: 0.58),
                                    Color(red: 0.27, green: 0.44, blue: 0.88)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 8, weight: .medium)).kerning(0.6)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(.white)
    }
}

struct CountdownPanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ticker: Ticker

    @State private var newTitle = ""
    @State private var newDue = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var editing: Deadline?
    @State private var addingDeadline = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Countdowns").font(.headline)
                Spacer()
                // The form hides behind this until you want it, so the list
                // keeps the whole card.
                Button {
                    addingDeadline.toggle()
                    if addingDeadline { titleFocused = true } else { newTitle = "" }
                } label: {
                    Image(systemName: addingDeadline ? "xmark" : "plus")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help(addingDeadline ? "Close" : "Add a deadline")
            }

            if store.deadlinesSorted.isEmpty {
                Text("No deadlines set.")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            } else {
                ForEach(store.deadlinesSorted) { deadline in
                    DeadlineCard(deadline: deadline,
                                 now: ticker.now,
                                 isEditing: editing?.id == deadline.id,
                                 onEdit: { editing = deadline },
                                 onDismiss: { editing = nil })
                }
            }

            if addingDeadline {
                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 6) {
                    TextField("Deadline name", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFocused)
                        .onSubmit(add)
                        .onExitCommand { addingDeadline = false; newTitle = "" }
                    HStack(spacing: 6) {
                        DatePicker("", selection: $newDue)
                            .datePickerStyle(.field)
                            .labelsHidden()
                            .fixedSize()
                        Spacer(minLength: 0)
                        Button("Add", action: add)
                            .buttonStyle(.borderedProminent)
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Return to add · Esc to close")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: addingDeadline)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.88)))
    }

    private func add() {
        guard !newTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            Toast.show("Give the deadline a name.", isError: true); return
        }
        guard store.addDeadline(title: newTitle, due: newDue) else { return }
        newTitle = ""
        addingDeadline = false
        Notifier.shared.reschedule(for: store.state.deadlines)
        Toast.show("Deadline added.")
    }
}

struct DeadlineCard: View {
    @EnvironmentObject var store: Store
    let deadline: Deadline
    let now: Date
    let isEditing: Bool
    let onEdit: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false
    @State private var confirming = false
    @State private var draftTitle = ""
    @State private var draftDue = Date()

    var body: some View {
        let cd = Countdown(due: deadline.dueDate, now: now)

        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(cd.urgency.tint).frame(width: 4)

            VStack(alignment: .leading, spacing: 2) {
                numberRow(cd)

                HStack(spacing: 6) {
                    Text(deadline.title).font(.system(size: 13, weight: .medium))
                    if !cd.badge.isEmpty {
                        Text(cd.badge.uppercased())
                            .font(.system(size: 8, weight: .bold)).kerning(0.6)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(cd.urgency.tint, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                    }
                }

                Text(deadline.dueDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? deadline.due)
                    .font(.caption).foregroundStyle(.secondary)

                if !deadline.note.isEmpty {
                    Text(deadline.note).font(.caption).foregroundStyle(.secondary)
                }

                if isEditing { editor }
            }
            .padding(.leading, 10)
            .padding(.vertical, 9)

            Spacer(minLength: 4)

            if confirming {
                HStack(spacing: 4) {
                    Button("Delete?") {
                        store.delete(deadline)
                        Notifier.shared.reschedule(for: store.state.deadlines)
                        confirming = false
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                    Button("Keep") { confirming = false }.controlSize(.small)
                }
                .padding(.trailing, 8).padding(.top, 9)
            } else if hovering || isEditing {
                HStack(spacing: 2) {
                    Button { begin() } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Edit deadline")
                    Button { confirming = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete deadline")
                }
                .padding(.trailing, 8).padding(.top, 9)
            }
        }
        .background(cd.urgency.fill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(cd.urgency.stroke))
        .onHover { hovering = $0 }
    }

    private func numberRow(_ cd: Countdown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if cd.isPast {
                Text("−").font(.system(size: 20, weight: .bold, design: .monospaced))
            }
            ForEach(Array(cd.units.enumerated()), id: \.element.id) { i, unit in
                Text(i == 0 ? "\(unit.value)" : String(format: "%02d", unit.value))
                    .font(.system(size: cd.isPast ? 20 : 25, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                Text(unit.symbol)
                    .font(.system(size: cd.isPast ? 12 : 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(cd.urgency.tint.opacity(0.65))
                    .padding(.trailing, 2)
            }
        }
        .foregroundStyle(cd.urgency.tint)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Deadline name", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            DatePicker("", selection: $draftDue)
                .datePickerStyle(.field).labelsHidden()
            HStack(spacing: 6) {
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel", action: onDismiss)
                    .controlSize(.small).keyboardShortcut(.cancelAction)
            }
        }
        .padding(.top, 5).padding(.trailing, 8)
    }

    private func begin() {
        draftTitle = deadline.title
        draftDue = deadline.dueDate ?? Date()
        onEdit()
    }

    private func save() {
        guard !draftTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            Toast.show("Give the deadline a name.", isError: true); return
        }
        guard store.updateDeadline(deadline, title: draftTitle, due: draftDue) else { return }
        Notifier.shared.reschedule(for: store.state.deadlines)
        onDismiss()
    }
}

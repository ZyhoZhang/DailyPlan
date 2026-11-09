import Foundation
import Combine
import Darwin

/// Owns the on-disk state. All mutations go through here so that every change
/// is persisted, backed up, and mirrored into the Markdown logs.
@MainActor
final class Store: ObservableObject {

    @Published private(set) var state: AppState = .empty
    @Published var selectedDay: String = DateUtil.todayKey
    @Published private(set) var lastError: String?

    let home: URL
    private var dataDir: URL { home.appendingPathComponent("data") }
    private var logsDir: URL { home.appendingPathComponent("logs") }
    private var statePath: URL { dataDir.appendingPathComponent("state.json") }
    private var backupPath: URL { dataDir.appendingPathComponent("state.json.bak") }

    /// Guards against writing back a file another process changed underneath us.
    private var lastLoadedModified: Date?
    private var reloadTimer: Timer?

    init(home: URL? = nil) {
        // Same default location the Python version uses, so data is shared.
        if let home {
            self.home = home
        } else if let env = ProcessInfo.processInfo.environment["DAILY_PLAN_HOME"] {
            self.home = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            self.home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/daily_plan")
        }
        load()
        startWatching()
    }

    // MARK: - Loading and saving

    /// Both implementations lock this separate, stable inode, never state.json
    /// itself (atomic replacement changes that file's inode).
    private func withStateLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let fd = Darwin.open(dataDir.appendingPathComponent("state.lock").path,
                             O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        // Never freeze the UI while a different process holds the lock.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK {
                throw NSError(domain: "DailyPlan.Store", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Another Daily Plan window is saving. Please try your edit again."
                ])
            }
            throw posixError()
        }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    /// Caller must hold state.lock. Decode before changing the in-memory state.
    /// A corrupt/unreadable file throws, so no mutation or backup can follow.
    private func loadUnlocked() throws {
        guard FileManager.default.fileExists(atPath: statePath.path) else {
            state = .empty
            lastLoadedModified = nil
            return
        }
        let data = try Data(contentsOf: statePath)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        state = decoded
        lastLoadedModified = modifiedDate(statePath)
    }

    func load() {
        do {
            try withStateLock { try loadUnlocked() }
            lastError = nil
        } catch {
            lastError = "Could not read state.json. No changes were saved: \(error.localizedDescription)"
        }
    }

    func dismissError() { lastError = nil }

    private func modifiedDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Watching is only for refreshing the display. Save safety comes from
    /// reloading within the locked transaction, not the two-second timer.
    private func startWatching() {
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.modifiedDate(self.statePath) != self.lastLoadedModified {
                    self.load()
                }
            }
        }
    }

    /// Reload, mutate and save while holding one cross-process lock. Each
    /// operation starts from the newest state, preserving unrelated edits.
    private func mutate<T>(touching days: [String], failure: T, _ operation: () -> T) -> T {
        var before = state
        do {
            return try withStateLock {
                try loadUnlocked()
                before = state
                let result = operation()
                if state != before { try persistUnlocked(touching: days) }
                lastError = nil
                return result
            }
        } catch {
            state = before
            lastError = "Your edit was not saved: \(error.localizedDescription)"
            return failure
        }
    }

    /// Caller must hold state.lock and have successfully decoded the old state.
    private func persistUnlocked(touching days: [String]) throws {
        if FileManager.default.fileExists(atPath: statePath.path) {
            // Preserve the previous backup if writing the replacement fails.
            let previous = try Data(contentsOf: statePath)
            try previous.write(to: backupPath, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try data.write(to: statePath, options: .atomic)
        lastLoadedModified = modifiedDate(statePath)
        for day in Set(days) { writeMarkdown(day: day) }
        writeIndex()
    }

    // MARK: - Derived values

    var entry: DayEntry { state.days[selectedDay] ?? DayEntry() }
    var goals: [Goal] { entry.goals }

    /// The goals recorded on one day, for the calendar cells.
    func goals(on dayKey: String) -> [Goal] {
        state.days[dayKey]?.goals ?? []
    }

    /// Done / total for one day, for the calendar heatmap.
    func dayScore(_ dayKey: String) -> (done: Int, total: Int) {
        guard let entry = state.days[dayKey] else { return (0, 0) }
        return (entry.goals.filter { $0.status == .done }.count, entry.goals.count)
    }

    var deadlinesSorted: [Deadline] {
        state.deadlines.sorted {
            ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture)
        }
    }

    var stats: Stats {
        var s = Stats()
        var perDay: [String: Int] = [:]
        for (day, entry) in state.days {
            perDay[day] = entry.goals.filter { $0.status == .done }.count
        }
        s.total = perDay.values.reduce(0, +)
        s.today = perDay[DateUtil.todayKey] ?? 0
        s.daysTracked = state.days.filter { !$0.value.goals.isEmpty }.count

        let scored = Set(perDay.filter { $0.value > 0 }.keys)

        // Current streak: walk back from today, or yesterday if today is empty.
        var cursor = Date()
        if !scored.contains(DateUtil.todayKey) {
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while scored.contains(DateUtil.key(cursor)) {
            s.currentStreak += 1
            guard let prev = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        var run = 0
        var previous: Date?
        for key in scored.sorted() {
            guard let d = DateUtil.date(fromKey: key) else { continue }
            if let previous,
               let expected = Calendar.current.date(byAdding: .day, value: 1, to: previous),
               Calendar.current.isDate(d, inSameDayAs: expected) {
                run += 1
            } else {
                run = 1
            }
            s.longestStreak = max(s.longestStreak, run)
            previous = d
        }

        if let best = perDay.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            s.bestDayScore = best.value
            s.bestDayDate = best.key
        }
        return s
    }

    var rank: Rank { Ranks.forTotal(stats.total) }

    // MARK: - Goal mutations

    /// Adds one goal per line. Duplicate titles on the same day are skipped,
    /// matching the Python behaviour. Returns (added, skipped).
    @discardableResult
    func addGoals(_ raw: String, on day: String? = nil) -> (added: Int, skipped: Int) {
        return mutate(touching: [day ?? selectedDay], failure: (added: 0, skipped: 0)) {
            let day = day ?? selectedDay
            let titles = raw.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !titles.isEmpty else { return (0, 0) }

            var e = state.days[day] ?? DayEntry()
            var seen = Set(e.goals.map { $0.title.lowercased() })
            var added = 0, skipped = 0
            for title in titles {
                let key = title.lowercased()
                if seen.contains(key) { skipped += 1; continue }
                seen.insert(key)
                e.goals.append(Goal(id: state.takeId(), title: String(title.prefix(500)),
                                    createdAt: DateUtil.stamp()))
                added += 1
            }
            state.days[day] = e
            return (added, skipped)

        }
    }

    func setStatus(_ goal: Goal, to status: GoalStatus, on day: String? = nil) {
        return mutate(touching: [day ?? selectedDay], failure: ()) {
            let day = day ?? selectedDay
            guard var e = state.days[day], let i = e.goals.firstIndex(where: { $0.id == goal.id })
            else { return }
            e.goals[i].status = status
            e.goals[i].completedAt = status == .done ? DateUtil.stamp() : nil
            state.days[day] = e

        }
    }

    func cycleStatus(_ goal: Goal) {
        mutate(touching: [selectedDay], failure: ()) {
            guard var entry = state.days[selectedDay],
                  let index = entry.goals.firstIndex(where: { $0.id == goal.id }) else { return }
            let next = entry.goals[index].status.next
            entry.goals[index].status = next
            entry.goals[index].completedAt = next == .done ? DateUtil.stamp() : nil
            state.days[selectedDay] = entry
        }
    }

    @discardableResult
    func update(_ goal: Goal, title: String? = nil, note: String? = nil, on day: String? = nil) -> Bool {
        return mutate(touching: [day ?? selectedDay], failure: false) {
            let day = day ?? selectedDay
            guard var e = state.days[day], let i = e.goals.firstIndex(where: { $0.id == goal.id })
            else { return false }
            let before = e.goals[i]
            if let title {
                let trimmed = title.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return false }
                e.goals[i].title = String(trimmed.prefix(500))
            }
            // Notes save on every keystroke, so the cap has to sit well above any
            // real note: hitting it would cut text off mid-typing.
            if let note { e.goals[i].note = String(note.prefix(20_000)) }
            guard e.goals[i] != before else { return true }
            state.days[day] = e
            return true

        }
    }

    func delete(_ goal: Goal, on day: String? = nil) {
        return mutate(touching: [day ?? selectedDay], failure: ()) {
            let day = day ?? selectedDay
            guard var e = state.days[day] else { return }
            e.goals.removeAll { $0.id == goal.id }
            state.days[day] = e

        }
    }

    func move(_ goal: Goal, up: Bool, on day: String? = nil) {
        return mutate(touching: [day ?? selectedDay], failure: ()) {
            let day = day ?? selectedDay
            guard var e = state.days[day], let i = e.goals.firstIndex(where: { $0.id == goal.id })
            else { return }
            let j = up ? i - 1 : i + 1
            guard j >= 0, j < e.goals.count else { return }
            e.goals.swapAt(i, j)
            state.days[day] = e

        }
    }

    /// Moves a goal into another goal's slot: dragged down it lands after the
    /// target, dragged up it lands before it.
    func moveGoal(_ id: Int, to targetId: Int, on day: String? = nil) {
        return mutate(touching: [day ?? selectedDay], failure: ()) {
            let goals = state.days[day ?? selectedDay]?.goals ?? []
            guard id != targetId,
                  let from = goals.firstIndex(where: { $0.id == id }),
                  let to = goals.firstIndex(where: { $0.id == targetId }) else { return }
            // `toOffset` counts positions before the move, hence the +1 going down.
            let key = day ?? selectedDay
            guard var entry = state.days[key] else { return }
            entry.goals.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            state.days[key] = entry

        }
    }

    func reorder(from source: IndexSet, to destination: Int, on day: String? = nil) {
        return mutate(touching: [day ?? selectedDay], failure: ()) {
            let day = day ?? selectedDay
            guard var e = state.days[day] else { return }
            guard destination >= 0, destination <= e.goals.count,
                  source.allSatisfy({ e.goals.indices.contains($0) }) else { return }
            e.goals.move(fromOffsets: source, toOffset: destination)
            state.days[day] = e

        }
    }

    /// Copies unfinished goals forward from the previous day.
    @discardableResult
    func carryOver(into day: String? = nil) -> Int {
        return mutate(touching: [day ?? selectedDay], failure: 0) {
            let day = day ?? selectedDay
            let source = DateUtil.shift(day, by: -1)
            guard source != day, let from = state.days[source] else { return 0 }

            var e = state.days[day] ?? DayEntry()
            let existing = Set(e.goals.map { $0.title.lowercased() })
            var moved = 0
            for goal in from.goals where goal.status != .done {
                if existing.contains(goal.title.lowercased()) { continue }
                e.goals.append(Goal(id: state.takeId(), title: goal.title, status: .pending,
                                    note: goal.note, createdAt: DateUtil.stamp(),
                                    carriedFrom: source))
                moved += 1
            }
            guard moved > 0 else { return 0 }
            state.days[day] = e
            return moved

        }
    }

    func setReflection(_ text: String, on day: String? = nil) {
        return mutate(touching: [day ?? selectedDay], failure: ()) {
            let day = day ?? selectedDay
            var e = state.days[day] ?? DayEntry()
            let trimmed = String(text.prefix(5000))
            guard e.reflection != trimmed else { return }
            e.reflection = trimmed
            state.days[day] = e

        }
    }

    // MARK: - Deadline mutations

    @discardableResult
    func addDeadline(title: String, due: Date, note: String = "") -> Bool {
        return mutate(touching: [selectedDay], failure: false) {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            state.deadlines.append(Deadline(id: state.takeId(),
                                            title: String(trimmed.prefix(200)),
                                            due: DateUtil.dueFormatter.string(from: due),
                                            note: String(note.prefix(500))))
            return true

        }
    }

    @discardableResult
    func updateDeadline(_ deadline: Deadline, title: String, due: Date, note: String? = nil) -> Bool {
        return mutate(touching: [selectedDay], failure: false) {
            guard let i = state.deadlines.firstIndex(where: { $0.id == deadline.id }) else { return false }
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            state.deadlines[i].title = String(trimmed.prefix(200))
            state.deadlines[i].due = DateUtil.dueFormatter.string(from: due)
            if let note { state.deadlines[i].note = String(note.prefix(500)) }
            return true

        }
    }

    func delete(_ deadline: Deadline) {
        return mutate(touching: [selectedDay], failure: ()) {
            state.deadlines.removeAll { $0.id == deadline.id }

        }
    }

    // MARK: - Navigation

    func goToDay(_ key: String) { selectedDay = key }
    func shiftDay(_ delta: Int) { selectedDay = DateUtil.shift(selectedDay, by: delta) }
    func goToToday() { selectedDay = DateUtil.todayKey }

    var historyDays: [(day: String, score: Int, total: Int)] {
        state.days
            .filter { !$0.value.goals.isEmpty }
            .map { (day: $0.key,
                    score: $0.value.goals.filter { $0.status == .done }.count,
                    total: $0.value.goals.count) }
            .sorted { $0.day > $1.day }
    }

    // MARK: - Markdown mirrors

    private func writeMarkdown(day: String) {
        let path = logsDir.appendingPathComponent("\(day).md")
        guard let e = state.days[day], !(e.goals.isEmpty && e.reflection.isEmpty) else {
            try? FileManager.default.removeItem(at: path)
            return
        }
        let done = e.goals.filter { $0.status == .done }.count

        let pretty: String = {
            guard let d = DateUtil.date(fromKey: day) else { return day }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEEE, dd MMMM yyyy"
            return f.string(from: d)
        }()

        var lines = ["# \(day) — \(pretty)", ""]
        lines.append("**Score:** \(done) / \(e.goals.count) goals completed")
        lines.append("")
        if !e.goals.isEmpty {
            lines.append("## Goals")
            lines.append("")
            for g in e.goals {
                lines.append("- \(g.status.mark) \(g.title)")
                if !g.note.isEmpty {
                    for noteLine in g.note.split(separator: "\n", omittingEmptySubsequences: false) {
                        lines.append("      \(noteLine)")
                    }
                }
            }
            lines.append("")
        }
        if !e.reflection.isEmpty {
            lines.append("## Reflection")
            lines.append("")
            lines.append(e.reflection.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        lines.append("---")
        lines.append("")
        lines.append("_Legend: `[x]` done · `[ ]` pending · `[~]` unfinished._")
        lines.append("")

        try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private func writeIndex() {
        let s = stats
        var lines = ["# Daily Plan — log index", ""]
        lines.append("**Total score:** \(s.total)  ·  **Rank:** \(rank.name)  ·  "
                     + "**Current streak:** \(s.currentStreak) day(s)  ·  "
                     + "**Longest streak:** \(s.longestStreak) day(s)")
        lines.append("")
        lines.append("| Date | Score | Goals | Completion |")
        lines.append("| --- | ---: | ---: | ---: |")
        for row in historyDays {
            let pct = row.total > 0 ? Int((100.0 * Double(row.score) / Double(row.total)).rounded()) : 0
            lines.append("| [\(row.day)](\(row.day).md) | \(row.score) | \(row.total) | \(pct)% |")
        }
        lines.append("")
        if !state.deadlines.isEmpty {
            lines.append("## Deadlines")
            lines.append("")
            lines.append("| Deadline | Due | Note |")
            lines.append("| --- | --- | --- |")
            for d in deadlinesSorted {
                lines.append("| \(d.title) | \(d.due) | \(d.note.replacingOccurrences(of: "|", with: "\\|")) |")
            }
            lines.append("")
        }
        try? lines.joined(separator: "\n")
            .write(to: logsDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }
}

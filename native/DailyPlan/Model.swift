import Foundation

// The on-disk schema is shared with the Python version (data/state.json), so
// both can run against the same file. Field names and types must not drift.

enum GoalStatus: String, Codable, CaseIterable {
    case pending, done, unfinished

    var next: GoalStatus {
        switch self {
        case .pending: return .done
        case .done: return .unfinished
        case .unfinished: return .pending
        }
    }

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .done: return "Done"
        case .unfinished: return "Unfinished"
        }
    }

    var mark: String {
        switch self {
        case .pending: return "[ ]"
        case .done: return "[x]"
        case .unfinished: return "[~]"
        }
    }
}

struct Goal: Codable, Identifiable, Equatable {
    var id: Int
    var title: String
    var status: GoalStatus
    var note: String
    var createdAt: String?
    var completedAt: String?
    var carriedFrom: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status, note, createdAt, completedAt, carriedFrom
    }

    // Tolerate goals written by older versions that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = (try? c.decode(GoalStatus.self, forKey: .status)) ?? .pending
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        carriedFrom = try c.decodeIfPresent(String.self, forKey: .carriedFrom)
    }

    init(id: Int, title: String, status: GoalStatus = .pending, note: String = "",
         createdAt: String? = nil, completedAt: String? = nil, carriedFrom: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.note = note
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.carriedFrom = carriedFrom
    }

    /// Write `completedAt` as an explicit null rather than omitting it, so the
    /// file is byte-comparable with what app.py produces. `carriedFrom` is
    /// omitted when absent because Python only writes it on carried goals.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(status, forKey: .status)
        try c.encode(note, forKey: .note)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(carriedFrom, forKey: .carriedFrom)
    }
}

struct DayEntry: Codable, Equatable {
    var goals: [Goal]
    var reflection: String

    init(goals: [Goal] = [], reflection: String = "") {
        self.goals = goals
        self.reflection = reflection
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goals = try c.decodeIfPresent([Goal].self, forKey: .goals) ?? []
        reflection = try c.decodeIfPresent(String.self, forKey: .reflection) ?? ""
    }
}

struct Deadline: Codable, Identifiable, Equatable {
    var id: Int
    var title: String
    var due: String        // "YYYY-MM-DDTHH:MM"
    var note: String

    init(id: Int, title: String, due: String, note: String = "") {
        self.id = id
        self.title = title
        self.due = due
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        due = try c.decodeIfPresent(String.self, forKey: .due) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    var dueDate: Date? { DateUtil.parseDue(due) }
}

struct AppState: Codable, Equatable {
    var version: Int
    var days: [String: DayEntry]
    var deadlines: [Deadline]
    var nextId: Int

    static let empty = AppState(version: 1, days: [:], deadlines: [], nextId: 1)

    init(version: Int, days: [String: DayEntry], deadlines: [Deadline], nextId: Int) {
        self.version = version
        self.days = days
        self.deadlines = deadlines
        self.nextId = nextId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        days = try c.decodeIfPresent([String: DayEntry].self, forKey: .days) ?? [:]
        deadlines = try c.decodeIfPresent([Deadline].self, forKey: .deadlines) ?? []
        nextId = try c.decodeIfPresent(Int.self, forKey: .nextId) ?? 1
    }

    mutating func takeId() -> Int {
        let n = nextId
        nextId = n + 1
        return n
    }
}

// MARK: - Ranks

struct Rank {
    let name: String
    let level: Int
    let floor: Int
    let next: Int?
    let nextName: String?
    let progress: Double
}

enum Ranks {
    // Must match RANKS in app.py so both versions report the same rank.
    static let table: [(Int, String)] = [
        (0, "Novice"), (10, "Apprentice"), (25, "Journeyman"), (50, "Adept"),
        (100, "Expert"), (200, "Master"), (350, "Grandmaster"),
        (600, "Legend"), (1000, "Mythic"),
    ]

    static func forTotal(_ total: Int) -> Rank {
        var idx = 0
        for (i, entry) in table.enumerated() where total >= entry.0 { idx = i }
        let floor = table[idx].0
        let ceiling = idx + 1 < table.count ? table[idx + 1].0 : nil
        var progress = 1.0
        if let ceiling {
            let span = ceiling - floor
            progress = span > 0 ? Double(total - floor) / Double(span) : 1.0
        }
        return Rank(
            name: table[idx].1,
            level: idx + 1,
            floor: floor,
            next: ceiling,
            nextName: ceiling != nil ? table[idx + 1].1 : nil,
            progress: max(0, min(1, progress))
        )
    }
}

// MARK: - Stats

struct Stats: Equatable {
    var total = 0
    var today = 0
    var currentStreak = 0
    var longestStreak = 0
    var bestDayScore = 0
    var bestDayDate = ""
    var daysTracked = 0
}

// MARK: - Dates

enum DateUtil {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    static func key(_ date: Date) -> String { dayFormatter.string(from: date) }
    static var todayKey: String { key(Date()) }
    static func stamp(_ date: Date = Date()) -> String { stampFormatter.string(from: date) }

    static func date(fromKey key: String) -> Date? { dayFormatter.date(from: key) }

    /// Accepts "YYYY-MM-DD" (→ 23:59) and "YYYY-MM-DDTHH:MM".
    static func parseDue(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let d = dueFormatter.date(from: text) { return d }
        if let day = dayFormatter.date(from: text) {
            return Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: day)
        }
        // Tolerate a seconds component if something else wrote one.
        return stampFormatter.date(from: text)
    }

    static func normalizeDue(_ raw: String) -> String? {
        guard let d = parseDue(raw) else { return nil }
        return dueFormatter.string(from: d)
    }

    static func shift(_ key: String, by days: Int) -> String {
        guard let d = date(fromKey: key),
              let moved = Calendar.current.date(byAdding: .day, value: days, to: d)
        else { return key }
        return self.key(moved)
    }

    static func pretty(_ key: String) -> String {
        guard let d = date(fromKey: key) else { return key }
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        var label = f.string(from: d)
        if key == todayKey { label += " · today" }
        else if key == shift(todayKey, by: -1) { label += " · yesterday" }
        else if key == shift(todayKey, by: 1) { label += " · tomorrow" }
        return label
    }
}

// MARK: - Calendar heatmap

/// How a day scored, for the calendar heatmap.
enum DayGrade {
    /// No goals recorded.
    case empty
    /// Goals, none completed.
    case none
    /// Some completed, under half.
    case low
    /// Half or more completed, but not all.
    case high
    /// Every goal completed.
    case all

    /// Five steps rather than three so the spectrum reads as a gradient
    /// instead of a traffic light.
    static func grade(done: Int, total: Int) -> DayGrade {
        if total <= 0 { return .empty }
        if done <= 0 { return .none }
        if done >= total { return .all }
        return Double(done) / Double(total) < 0.5 ? .low : .high
    }
}

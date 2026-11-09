import SwiftUI

/// How close a deadline is, which drives every colour decision in the UI.
enum Urgency {
    case calm       // 4+ days out
    case soon       // under 4 days
    case urgent     // under 24 hours
    case passed     // overdue

    var tint: Color {
        switch self {
        case .calm:   return Color(red: 0.12, green: 0.23, blue: 0.58)   // accent blue
        case .soon:   return Color(red: 0.71, green: 0.33, blue: 0.04)   // amber
        case .urgent: return Color(red: 0.73, green: 0.11, blue: 0.11)   // red
        case .passed: return Color(white: 0.42)
        }
    }

    var fill: Color {
        switch self {
        case .calm:   return Color(red: 0.98, green: 0.99, blue: 1.0)
        case .soon:   return Color(red: 0.99, green: 0.96, blue: 0.91)
        case .urgent: return Color(red: 0.99, green: 0.93, blue: 0.92)
        case .passed: return Color(white: 0.96)
        }
    }

    var stroke: Color {
        switch self {
        case .calm:   return Color(white: 0.88)
        case .soon:   return Color(red: 0.94, green: 0.86, blue: 0.68)
        case .urgent: return Color(red: 0.95, green: 0.77, blue: 0.76)
        case .passed: return Color(white: 0.88)
        }
    }
}

/// One rendered countdown: the split units plus everything needed to style it.
struct Countdown {
    struct Unit: Identifiable {
        let id = UUID()
        let value: Int
        let symbol: String
        let isLast: Bool
    }

    let units: [Unit]
    let urgency: Urgency
    let badge: String
    let isPast: Bool

    /// Compact form for the menu bar, e.g. "6d", "5h", "12m".
    let compact: String

    init(due: Date?, now: Date = Date()) {
        guard let due else {
            units = []
            urgency = .calm
            badge = ""
            isPast = false
            compact = "—"
            return
        }

        let raw = due.timeIntervalSince(now)
        isPast = raw < 0
        let total = Int(abs(raw))

        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        // Show the three most useful units; seconds only inside the last day.
        var built: [(Int, String)]
        if days > 0 {
            built = [(days, "d"), (hours, "h"), (minutes, "m")]
        } else if hours > 0 {
            built = [(hours, "h"), (minutes, "m"), (seconds, "s")]
        } else {
            built = [(minutes, "m"), (seconds, "s")]
        }
        units = built.enumerated().map { i, u in
            Unit(value: u.0, symbol: u.1, isLast: i == built.count - 1)
        }

        if isPast {
            urgency = .passed
            badge = "overdue"
        } else if days < 1 {
            urgency = .urgent
            badge = hours < 1 ? "minutes left" : "today"
        } else if days < 4 {
            urgency = .soon
            badge = days == 1 ? "tomorrow" : "\(days) days"
        } else {
            urgency = .calm
            badge = ""
        }

        let sign = isPast ? "−" : ""
        if days > 0 { compact = "\(sign)\(days)d" }
        else if hours > 0 { compact = "\(sign)\(hours)h" }
        else { compact = "\(sign)\(minutes)m" }
    }

    /// "6d 12h 06m" — used in notifications and accessibility labels.
    var plain: String {
        let body = units.map { u in
            u.value == units.first?.value && u.symbol == units.first?.symbol
                ? "\(u.value)\(u.symbol)"
                : String(format: "%02d%@", u.value, u.symbol)
        }.joined(separator: " ")
        return (isPast ? "−" : "") + body
    }
}

/// Drives every countdown on screen from one timer rather than one per view.
@MainActor
final class Ticker: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        // Keep ticking while menus are open or the window is being resized.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    deinit { timer?.invalidate() }
}

import Foundation
import UserNotifications
import AppKit

/// Deadline alerts and the daily planning nudges.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()
    private(set) var authorized = false

    // User-facing switches, persisted in UserDefaults.
    var deadlineAlertsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "deadlineAlerts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "deadlineAlerts") }
    }
    var dailyRemindersEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "dailyReminders") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dailyReminders") }
    }
    var morningHour: Int {
        get { UserDefaults.standard.object(forKey: "morningHour") as? Int ?? 9 }
        set { UserDefaults.standard.set(newValue, forKey: "morningHour") }
    }
    var eveningHour: Int {
        get { UserDefaults.standard.object(forKey: "eveningHour") as? Int ?? 21 }
        set { UserDefaults.standard.set(newValue, forKey: "eveningHour") }
    }

    func start() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            self.authorized = granted
        }
    }

    /// Show alerts even while Daily Plan is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible || $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        handler()
    }

    // MARK: - Deadline alerts

    /// Rebuilds every pending deadline notification from scratch. Cheap, and
    /// avoids having to track which ones changed.
    func reschedule(for deadlines: [Deadline]) {
        center.getPendingNotificationRequests { requests in
            let stale = requests.map(\.identifier).filter { $0.hasPrefix("deadline-") }
            self.center.removePendingNotificationRequests(withIdentifiers: stale)

            guard self.deadlineAlertsEnabled else { return }
            let now = Date()
            for d in deadlines {
                guard let due = d.dueDate else { continue }
                // 24 hours out, 1 hour out, and at the deadline itself.
                let points: [(String, TimeInterval, String)] = [
                    ("24h", -86_400, "is due tomorrow"),
                    ("1h",  -3_600,  "is due in an hour"),
                    ("at",   0,      "is due now"),
                ]
                for (suffix, offset, phrase) in points {
                    let fire = due.addingTimeInterval(offset)
                    guard fire > now else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = d.title
                    content.body = "\(d.title) \(phrase)."
                    content.sound = .default

                    let comps = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: fire)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    self.center.add(UNNotificationRequest(
                        identifier: "deadline-\(d.id)-\(suffix)",
                        content: content, trigger: trigger))
                }
            }
        }
    }

    // MARK: - Daily planning nudges

    func scheduleDailyReminders() {
        let ids = ["daily-morning", "daily-evening"]
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard dailyRemindersEnabled else { return }

        let morning = UNMutableNotificationContent()
        morning.title = "Plan your day"
        morning.body = "What do you want to get done today?"
        morning.sound = .default

        let evening = UNMutableNotificationContent()
        evening.title = "How did today go?"
        evening.body = "Mark what you finished and note anything left over."
        evening.sound = .default

        for (id, content, hour) in [("daily-morning", morning, morningHour),
                                    ("daily-evening", evening, eveningHour)] {
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = 0
            center.add(UNNotificationRequest(
                identifier: id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
        }
    }
}

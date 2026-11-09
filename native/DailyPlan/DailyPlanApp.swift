import SwiftUI
import AppKit
import ServiceManagement

@main
struct DailyPlanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    @StateObject private var ticker = Ticker()

    var body: some Scene {
        Window("Daily Plan", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(ticker)
                .overlay(alignment: .bottom) { ToastView() }
                .onAppear {
                    delegate.attach(store: store, ticker: ticker)
                    Notifier.shared.start()
                    Notifier.shared.reschedule(for: store.state.deadlines)
                    Notifier.shared.scheduleDailyReminders()
                }
        }
        .defaultSize(width: 980, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Day") {
                Button("Previous Day") { store.shiftDay(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next Day") { store.shiftDay(1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Today") { store.goToToday() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Carry Over Unfinished") {
                    let n = store.carryOver()
                    Toast.show(n > 0 ? "Carried over \(n) goal\(n == 1 ? "" : "s")."
                                     : "Nothing unfinished to carry over.")
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Reveal Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [store.home.appendingPathComponent("data/state.json")])
                }
            }
            CommandMenu("Feedback") {
                Button("Email zyhozhang@gmail.com") {
                    NSWorkspace.shared.open(URL(string: "mailto:zyhozhang@gmail.com?subject=Daily%20Plan%20feedback")!)
                }
            }
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

// MARK: - Menu bar

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var store: Store?
    private var refresh: Timer?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { NSApp.setActivationPolicy(.regular) }
    }

    /// Called once the SwiftUI scene exists so we share its store instance.
    func attach(store: Store, ticker: Ticker) {
        guard self.store == nil else { return }
        self.store = store
        buildStatusItem()
        // The menu bar only needs minute resolution.
        refresh = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusTitle() }
        }
        if let refresh { RunLoop.main.add(refresh, forMode: .common) }
        updateStatusTitle()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "target", accessibilityDescription: "Daily Plan")
        item.button?.imagePosition = .imageLeading
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func updateStatusTitle() {
        guard let store else { return }
        let upcoming = store.deadlinesSorted.first { ($0.dueDate ?? .distantPast) > Date() }
        guard let next = upcoming, let due = next.dueDate else {
            statusItem?.button?.title = ""
            return
        }
        let cd = Countdown(due: due)
        // Keep it short so it does not crowd the menu bar.
        let name = next.title.count > 18 ? String(next.title.prefix(17)) + "…" : next.title
        statusItem?.button?.title = " \(name) \(cd.compact)"

        if cd.urgency == .urgent {
            statusItem?.button?.contentTintColor = .systemRed
        } else if cd.urgency == .soon {
            statusItem?.button?.contentTintColor = .systemOrange
        } else {
            statusItem?.button?.contentTintColor = nil
        }
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication,
                                                   hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { if !flag { showMainWindow() } }
        return true
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true })
            ?? NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func toggleGoal(_ sender: NSMenuItem) {
        guard let store, let goal = store.goals.first(where: { $0.id == sender.tag }) else { return }
        Task { @MainActor in store.cycleStatus(goal) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// Rebuild the dropdown each time it opens so it always reflects current state.
extension AppDelegate: NSMenuDelegate {
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            guard let store = self.store else { return }
            let s = store.stats
            let header = NSMenuItem(title: "\(store.rank.name) · \(s.total) points · \(s.currentStreak)-day streak",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())

            let goals = store.state.days[DateUtil.todayKey]?.goals ?? []
            if goals.isEmpty {
                let none = NSMenuItem(title: "No goals set for today", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            } else {
                let title = NSMenuItem(title: "TODAY", action: nil, keyEquivalent: "")
                title.isEnabled = false
                menu.addItem(title)
                for g in goals {
                    let item = NSMenuItem(title: g.title,
                                          action: #selector(toggleGoal(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = g.id
                    item.state = g.status == .done ? .on : .off
                    if g.status == .unfinished {
                        item.attributedTitle = NSAttributedString(
                            string: g.title,
                            attributes: [.foregroundColor: NSColor.systemRed])
                    }
                    menu.addItem(item)
                }
            }

            let upcoming = store.deadlinesSorted.filter { ($0.dueDate ?? .distantPast) > Date() }
            if !upcoming.isEmpty {
                menu.addItem(.separator())
                let title = NSMenuItem(title: "DEADLINES", action: nil, keyEquivalent: "")
                title.isEnabled = false
                menu.addItem(title)
                for d in upcoming.prefix(5) {
                    let cd = Countdown(due: d.dueDate)
                    let item = NSMenuItem(title: "\(d.title) — \(cd.plain)",
                                          action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())
            let open = NSMenuItem(title: "Open Daily Plan",
                                  action: #selector(showMainWindow), keyEquivalent: "o")
            open.target = self
            menu.addItem(open)
            let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var deadlineAlerts = Notifier.shared.deadlineAlertsEnabled
    @State private var dailyReminders = Notifier.shared.dailyRemindersEnabled
    @State private var morningHour = Notifier.shared.morningHour
    @State private var eveningHour = Notifier.shared.eveningHour
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Notifications") {
                Toggle("Deadline alerts (24h, 1h, and at the deadline)", isOn: $deadlineAlerts)
                    .onChange(of: deadlineAlerts) { _, on in
                        Notifier.shared.deadlineAlertsEnabled = on
                        Notifier.shared.reschedule(for: store.state.deadlines)
                    }
                Toggle("Daily planning reminders", isOn: $dailyReminders)
                    .onChange(of: dailyReminders) { _, on in
                        Notifier.shared.dailyRemindersEnabled = on
                        Notifier.shared.scheduleDailyReminders()
                    }
                if dailyReminders {
                    Picker("Morning prompt", selection: $morningHour) {
                        ForEach(5..<13) { Text(hourLabel($0)).tag($0) }
                    }
                    .onChange(of: morningHour) { _, h in
                        Notifier.shared.morningHour = h
                        Notifier.shared.scheduleDailyReminders()
                    }
                    Picker("Evening review", selection: $eveningHour) {
                        ForEach(16..<24) { Text(hourLabel($0)).tag($0) }
                    }
                    .onChange(of: eveningHour) { _, h in
                        Notifier.shared.eveningHour = h
                        Notifier.shared.scheduleDailyReminders()
                    }
                }
            }

            Section("Data") {
                LabeledContent("Folder") {
                    Text(store.home.path).font(.caption).textSelection(.enabled)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [store.home.appendingPathComponent("data/state.json")])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }

    private func hourLabel(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h
        c.minute = 0
        let d = Calendar.current.date(from: c) ?? Date()
        return d.formatted(date: .omitted, time: .shortened)
    }
}

// Compatibility harness: proves the Swift store reads and writes exactly the
// schema the Python version produces, so both can share data/state.json.
//
// Built and run by test_native.sh against a throwaway directory.

import Foundation
import AppKit
import Darwin

@MainActor
func run() async -> Int {
    var pass = 0, fail = 0
    func check(_ label: String, _ cond: Bool, _ detail: String = "") {
        if cond { pass += 1; print("  ok   \(label)") }
        else { fail += 1; print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
    }

    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dailyplan-swift-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    // A file exactly as app.py writes it, including a carried goal.
    let pythonJSON = """
    {
      "version": 1,
      "days": {
        "2026-08-02": {
          "goals": [
            {"id": 1, "title": "Practice questions *100", "status": "pending",
             "note": "Review the practice examples", "createdAt": "2026-08-02T01:00:57",
             "completedAt": null},
            {"id": 2, "title": "Finished thing", "status": "done", "note": "",
             "createdAt": "2026-08-02T01:20:00", "completedAt": "2026-08-02T09:00:00"},
            {"id": 3, "title": "Carried thing", "status": "unfinished", "note": "n",
             "createdAt": "2026-08-02T01:20:10", "completedAt": null,
             "carriedFrom": "2026-08-01"}
          ],
          "reflection": "A good day."
        },
        "2026-08-01": {
          "goals": [
            {"id": 4, "title": "Yesterday goal", "status": "done", "note": "",
             "createdAt": "2026-08-01T08:00:00", "completedAt": "2026-08-01T18:00:00"}
          ],
          "reflection": ""
        }
      },
      "deadlines": [
        {"id": 5, "title": "Demo planning session", "due": "2026-08-05T11:00", "note": ""},
        {"id": 6, "title": "Demo milestone", "due": "2026-08-08T13:30", "note": "Bring checklist"}
      ],
      "nextId": 7
    }
    """
    let dataDir = home.appendingPathComponent("data")
    try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    try? pythonJSON.write(to: dataDir.appendingPathComponent("state.json"),
                          atomically: true, encoding: .utf8)

    print("\n[S1] reads a Python-written state.json")
    let store = Store(home: home)
    check("two days loaded", store.state.days.count == 2, "\(store.state.days.count)")
    check("nextId preserved", store.state.nextId == 7, "\(store.state.nextId)")
    check("two deadlines loaded", store.state.deadlines.count == 2)
    store.goToDay("2026-08-02")
    check("three goals on the day", store.goals.count == 3, "\(store.goals.count)")
    check("pending status parsed", store.goals[0].status == .pending)
    check("done status parsed", store.goals[1].status == .done)
    check("unfinished status parsed", store.goals[2].status == .unfinished)
    check("note preserved", store.goals[0].note == "Review the practice examples")
    check("carriedFrom preserved", store.goals[2].carriedFrom == "2026-08-01")
    check("reflection preserved", store.entry.reflection == "A good day.")
    check("deadline note preserved",
          store.state.deadlines.first { $0.id == 6 }?.note == "Bring checklist")

    print("\n[S2] stats match the Python algorithm")
    let s = store.stats
    check("total is 2", s.total == 2, "\(s.total)")
    check("longest streak is 2", s.longestStreak == 2, "\(s.longestStreak)")
    check("best day score is 1", s.bestDayScore == 1, "\(s.bestDayScore)")
    check("days tracked is 2", s.daysTracked == 2, "\(s.daysTracked)")

    print("\n[S3] rank table matches app.py")
    let expected: [(Int, String)] = [
        (0, "Novice"), (9, "Novice"), (10, "Apprentice"), (25, "Journeyman"),
        (50, "Adept"), (100, "Expert"), (200, "Master"), (350, "Grandmaster"),
        (600, "Legend"), (1000, "Mythic"), (5000, "Mythic"),
    ]
    for (total, name) in expected {
        check("rank at \(total) is \(name)", Ranks.forTotal(total).name == name,
              Ranks.forTotal(total).name)
    }
    check("max rank has no next", Ranks.forTotal(5000).next == nil)
    check("progress at floor is 0", Ranks.forTotal(0).progress == 0)

    print("\n[S4] writes back a schema Python can read")
    store.addGoals("A brand new goal")
    let written = try! Data(contentsOf: dataDir.appendingPathComponent("state.json"))
    let obj = try! JSONSerialization.jsonObject(with: written) as! [String: Any]
    check("has version key", obj["version"] != nil)
    check("has days key", obj["days"] != nil)
    check("has deadlines key", obj["deadlines"] != nil)
    check("has nextId key", obj["nextId"] != nil)
    let days = obj["days"] as! [String: Any]
    let day = days["2026-08-02"] as! [String: Any]
    let goals = day["goals"] as! [[String: Any]]
    check("new goal appended", goals.count == 4, "\(goals.count)")
    check("nextId advanced", (obj["nextId"] as! Int) == 8, "\(obj["nextId"]!)")
    let newGoal = goals.last!
    check("status is a plain string", newGoal["status"] as? String == "pending")
    check("id is an integer", newGoal["id"] is Int)
    check("completedAt null for pending", newGoal["completedAt"] is NSNull)
    check("reflection key kept", day["reflection"] as? String == "A good day.")
    check("backup written",
          FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("state.json.bak").path))

    print("\n[S5] duplicate handling matches Python")
    let before = store.goals.count
    let r1 = store.addGoals("A brand new goal")
    check("exact duplicate skipped", store.goals.count == before && r1.skipped == 1)
    let r2 = store.addGoals("  a BRAND new goal  ")
    check("case/space duplicate skipped", store.goals.count == before && r2.skipped == 1)
    let r3 = store.addGoals("One fresh\nAnother fresh\nOne fresh")
    check("within-batch duplicate collapsed", r3.added == 2 && r3.skipped == 1,
          "added \(r3.added) skipped \(r3.skipped)")

    print("\n[S6] status cycling and scoring")
    let target = store.goals.first { $0.title == "A brand new goal" }!
    store.setStatus(target, to: .done)
    check("done scores a point", store.stats.total == 3, "\(store.stats.total)")
    check("completedAt stamped",
          store.goals.first { $0.id == target.id }?.completedAt != nil)
    store.setStatus(target, to: .unfinished)
    check("unfinished removes the point", store.stats.total == 2)
    check("completedAt cleared",
          store.goals.first { $0.id == target.id }?.completedAt == nil)
    check("cycle order pending→done", GoalStatus.pending.next == .done)
    check("cycle order done→unfinished", GoalStatus.done.next == .unfinished)
    check("cycle order unfinished→pending", GoalStatus.unfinished.next == .pending)

    print("\n[S7] Markdown mirrors the Python format")
    let md = try! String(contentsOf: home.appendingPathComponent("logs/2026-08-02.md"),
                         encoding: .utf8)
    check("has the date heading", md.contains("# 2026-08-02 —"))
    check("done marked [x]", md.contains("[x] Finished thing"))
    check("pending marked [ ]", md.contains("[ ] Practice questions *100"))
    check("unfinished marked [~]", md.contains("[~] Carried thing"))
    check("note indented six spaces", md.contains("      Review the practice examples"))
    check("score line present", md.contains("goals completed"))
    check("reflection section", md.contains("## Reflection") && md.contains("A good day."))
    check("legend present", md.contains("_Legend:"))
    let index = try! String(contentsOf: home.appendingPathComponent("logs/README.md"),
                            encoding: .utf8)
    check("index links days", index.contains("(2026-08-02.md)"))
    check("index lists deadlines", index.contains("Demo milestone"))

    print("\n[S8] carry over")
    store.goToDay("2026-08-03")
    let moved = store.carryOver()
    check("carried the unfinished ones", moved > 0, "\(moved)")
    check("completed goals not carried",
          !store.goals.contains { $0.title == "Finished thing" })
    check("carried marked pending", store.goals.allSatisfy { $0.status == .pending })
    check("provenance recorded", store.goals.allSatisfy { $0.carriedFrom == "2026-08-02" })
    let again = store.carryOver()
    check("carry is idempotent", again == 0, "\(again)")

    print("\n[S9] deadline parsing")
    check("datetime form parses", DateUtil.parseDue("2026-08-05T11:00") != nil)
    check("bare date defaults to 23:59", {
        guard let d = DateUtil.parseDue("2026-08-05") else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return c.hour == 23 && c.minute == 59
    }())
    check("garbage rejected", DateUtil.parseDue("not-a-date") == nil)
    check("normalize round-trips", DateUtil.normalizeDue("2026-08-05") == "2026-08-05T23:59")

    print("\n[S10] countdown maths")
    let now = Date()
    let inSixDays = now.addingTimeInterval(6 * 86_400 + 3_600)
    let c1 = Countdown(due: inSixDays, now: now)
    check("6 days is calm", c1.urgency == .calm, "\(c1.urgency)")
    check("no badge when calm", c1.badge.isEmpty)
    check("not past", !c1.isPast)
    check("compact reads 6d", c1.compact == "6d", c1.compact)
    check("shows d/h/m", c1.units.map(\.symbol) == ["d", "h", "m"])

    let inTwoDays = Countdown(due: now.addingTimeInterval(2 * 86_400), now: now)
    check("2 days is soon", inTwoDays.urgency == .soon)
    check("badge says 2 days", inTwoDays.badge == "2 days", inTwoDays.badge)

    let inFiveHours = Countdown(due: now.addingTimeInterval(5 * 3_600), now: now)
    check("5 hours is urgent", inFiveHours.urgency == .urgent)
    check("badge says today", inFiveHours.badge == "today")
    check("shows seconds under a day", inFiveHours.units.map(\.symbol) == ["h", "m", "s"])

    let inTenMinutes = Countdown(due: now.addingTimeInterval(600), now: now)
    check("10 minutes says minutes left", inTenMinutes.badge == "minutes left")

    let overdue = Countdown(due: now.addingTimeInterval(-2 * 86_400), now: now)
    check("overdue is passed", overdue.urgency == .passed)
    check("overdue flagged", overdue.isPast)
    check("overdue badge", overdue.badge == "overdue")
    check("overdue compact has minus", overdue.compact.hasPrefix("−"), overdue.compact)
    check("overdue plain has minus", overdue.plain.hasPrefix("−"), overdue.plain)

    print("\n[S11] deadline mutations")
    let dlBefore = store.state.deadlines.count
    _ = store.addDeadline(title: "New deadline", due: now.addingTimeInterval(86_400))
    check("deadline added", store.state.deadlines.count == dlBefore + 1)
    check("empty title rejected", store.addDeadline(title: "   ", due: now) == false)
    check("count unchanged after rejection", store.state.deadlines.count == dlBefore + 1)
    let toEdit = store.state.deadlines.last!
    store.updateDeadline(toEdit, title: "Renamed", due: now.addingTimeInterval(2 * 86_400))
    check("deadline renamed",
          store.state.deadlines.contains { $0.title == "Renamed" })
    store.delete(toEdit)
    check("deadline deleted", store.state.deadlines.count == dlBefore)
    check("sorted soonest first", {
        let ds = store.deadlinesSorted.compactMap(\.dueDate)
        return ds == ds.sorted()
    }())

    print("\n[S12] editing and deletion")
    store.goToDay("2026-08-02")
    let editTarget = store.goals.first!
    store.update(editTarget, title: "Renamed goal")
    check("title updated", store.goals.contains { $0.title == "Renamed goal" })
    store.update(editTarget, title: "   ")
    check("empty title ignored", store.goals.contains { $0.title == "Renamed goal" })
    store.update(editTarget, note: "fresh note")
    check("note updated",
          store.goals.first { $0.id == editTarget.id }?.note == "fresh note")
    let countBefore = store.goals.count
    store.delete(editTarget)
    check("goal deleted", store.goals.count == countBefore - 1)

    print("\n[S13] reorder")
    store.goToDay("2026-08-02")
    if store.goals.count >= 2 {
        let first = store.goals[0]
        store.move(first, up: false)
        check("moved down", store.goals[1].id == first.id)
        store.move(first, up: true)
        check("moved back up", store.goals[0].id == first.id)
        store.move(first, up: true)
        check("move past the top is a no-op", store.goals[0].id == first.id)
    }

    print("\n[S14] survives a reload from disk")
    let totalBefore = store.stats.total
    let reloaded = Store(home: home)
    check("state reloads", reloaded.state.days.count >= 2)
    check("score identical after reload", reloaded.stats.total == totalBefore,
          "\(reloaded.stats.total) vs \(totalBefore)")
    check("deadlines survive", reloaded.state.deadlines.count == store.state.deadlines.count)

    print("\n[S15] unicode and truncation")
    reloaded.goToDay("2026-08-04")
    reloaded.addGoals("写论文 — «σ» 📈")
    check("unicode round-trips", reloaded.goals.contains { $0.title == "写论文 — «σ» 📈" })
    reloaded.addGoals(String(repeating: "x", count: 900))
    check("long title truncated to 500",
          reloaded.goals.contains { $0.title.count == 500 })
    let mdUnicode = try! String(contentsOf: home.appendingPathComponent("logs/2026-08-04.md"),
                                encoding: .utf8)
    check("unicode reaches Markdown", mdUnicode.contains("写论文"))

    print("\n[S16] empty day removes its log")
    reloaded.goToDay("2026-08-09")
    reloaded.addGoals("Temporary")
    let tempLog = home.appendingPathComponent("logs/2026-08-09.md")
    check("log written", FileManager.default.fileExists(atPath: tempLog.path))
    reloaded.delete(reloaded.goals.first!)
    check("log removed when day empties",
          !FileManager.default.fileExists(atPath: tempLog.path))

    print("\n[S17] note auto-save")
    reloaded.goToDay("2026-08-10")
    reloaded.addGoals("Has a note")
    let noted = reloaded.goals[0]
    let backup = home.appendingPathComponent("data/state.json.bak")
    reloaded.update(noted, note: "first")
    try? FileManager.default.removeItem(at: backup)
    reloaded.update(reloaded.goals[0], note: "first")
    check("unchanged note skips the write", !FileManager.default.fileExists(atPath: backup.path))
    reloaded.update(reloaded.goals[0], note: "first, then more")
    check("changed note writes", FileManager.default.fileExists(atPath: backup.path))
    let long = String(repeating: "- item\n", count: 700)   // 4900 chars
    reloaded.update(reloaded.goals[0], note: long)
    check("long note kept whole", reloaded.goals[0].note == long, "\(reloaded.goals[0].note.count)")

    print("\n[S17b] drag to reorder")
    reloaded.goToDay("2026-08-11")
    reloaded.addGoals("a\nb\nc\nd")
    func order() -> String { reloaded.goals.map(\.title).joined() }
    func id(_ t: String) -> Int { reloaded.goals.first { $0.title == t }!.id }
    reloaded.moveGoal(id("a"), to: id("c"))
    check("dragged down lands after the target", order() == "bcad", order())
    reloaded.moveGoal(id("d"), to: id("b"))
    check("dragged up lands before the target", order() == "dbca", order())
    reloaded.moveGoal(id("c"), to: id("a"))
    check("adjacent swap down", order() == "dbac", order())
    try? FileManager.default.removeItem(at: backup)
    reloaded.moveGoal(id("b"), to: id("b"))
    check("onto itself is a no-op", order() == "dbac" && !FileManager.default.fileExists(atPath: backup.path))
    reloaded.moveGoal(id("b"), to: 999_999)
    check("unknown target is a no-op", order() == "dbac", order())

    print("\n[S18] note lines and markers")
    func applied(_ text: String, _ e: NoteFormat.Edit) -> String {
        (text as NSString).replacingCharacters(in: e.range, with: e.replacement)
    }
    let nested = NoteFormat.parse("\t\t- duality step down")
    check("nested bullet parsed", nested.indent == "\t\t" && nested.marker == "-"
          && nested.body == "duality step down" && nested.prefixLength == 4)
    check("numbered item parsed", NoteFormat.parse("\t1. CEO ").marker == "1.")
    check("lettered item parsed", NoteFormat.parse("\t\ta) -> CEO").marker == "a)")
    check("prose is not a list", NoteFormat.parse("Hypothesis 1: data imputed").marker == "")
    check("italic at line start is not a bullet", NoteFormat.parse("*really* not").marker == "")
    check("lone dash is not a bullet", NoteFormat.parse("-").marker == "")
    check("next number", NoteFormat.nextMarker("3.") == "4." && NoteFormat.nextMarker("9)") == "10)")
    check("next letter", NoteFormat.nextMarker("c)") == "d)" && NoteFormat.nextMarker("C.") == "D.")
    check("bullet repeats", NoteFormat.nextMarker("-") == "-")
    check("z stays z", NoteFormat.nextMarker("z)") == "z)")
    check("Return before the marker pushes the item down",
          applied("- foo", NoteFormat.newline("- foo", NSRange(location: 0, length: 0))) == "\n- foo")

    print("\n[S18b] Return in outlines")
    // Return with the caret at `caret` (end of text if nil): the new text and caret.
    func ret(_ text: String, at caret: Int? = nil) -> (String, Int) {
        let e = NoteFormat.newline(text, NSRange(location: caret ?? (text as NSString).length, length: 0))
        return (applied(text, e), e.selection.location)
    }
    check("bullet continues", ret("\t\t- duality step down/arise") == ("\t\t- duality step down/arise\n\t\t- ", 32),
          "\(ret("\t\t- duality step down/arise"))")
    check("number continues", ret("\t1. CEO").0 == "\t1. CEO\n\t2. ")
    check("letter continues", ret("\t\tb) -> Duality CEO").0 == "\t\tb) -> Duality CEO\n\t\tc) ")
    check("empty item ends the list in place", ret("\t\tb) x\n\t\tc) ") == ("\t\tb) x\n\t\t", 9),
          "\(ret("\t\tb) x\n\t\tc) "))")
    check("empty item with trailing spaces ends too", ret("- x\n-   ").0 == "- x\n")
    check("indented prose keeps its indent",
          ret("Maxi:\n\tdone with reverse engineering:").0 == "Maxi:\n\tdone with reverse engineering:\n\t")
    check("prose at the margin breaks plainly", ret("Specifically,").0 == "Specifically,\n")
    check("Return mid-item splits it into two items", ret("- foobar", at: 5) == ("- foo\n- bar", 8),
          "\(ret("- foobar", at: 5))")

    print("\n[S19] indent, outdent, tab, lists")
    let ind = NoteFormat.indent("a\nb", NSRange(location: 3, length: 0))
    check("indent one line", applied("a\nb", ind) == "a\n\tb" && ind.selection.location == 4)
    let outAll = NoteFormat.outdent("\tx\n\ty\nz", NSRange(location: 0, length: 7))
    check("outdent a selection", applied("\tx\n\ty\nz", outAll) == "x\ny\nz",
          applied("\tx\n\ty\nz", outAll).debugDescription)
    check("outdent spaces", applied("      x", NoteFormat.outdent("      x", NSRange(location: 6, length: 0))) == "  x")
    let outStart = NoteFormat.outdent("\tx", NSRange(location: 0, length: 0))
    check("outdent keeps caret at line start", outStart.selection.location == 0)
    check("selection ending at a line start leaves that line",
          applied("a\nb", NoteFormat.indent("a\nb", NSRange(location: 0, length: 2))) == "\ta\nb")
    check("tab on prose types a tab", NoteFormat.tab("plain", NSRange(location: 5, length: 0)) == nil)
    check("tab on a list item indents it",
          applied("- x", NoteFormat.tab("- x", NSRange(location: 3, length: 0))!) == "\t- x")
    check("tab over two lines indents both",
          applied("a\nb", NoteFormat.tab("a\nb", NSRange(location: 0, length: 3))!) == "\ta\n\tb")
    let bullets = applied("a\n\nb", NoteFormat.toggleList("a\n\nb", NSRange(location: 0, length: 4), numbered: false))
    check("bullet list skips blank lines", bullets == "- a\n\n- b", bullets.debugDescription)
    check("bullet list toggles off",
          applied(bullets, NoteFormat.toggleList(bullets, NSRange(location: 0, length: 9), numbered: false)) == "a\n\nb")
    let numbers = applied("- a\n- b", NoteFormat.toggleList("- a\n- b", NSRange(location: 0, length: 7), numbered: true))
    check("numbering replaces bullets", numbers == "1. a\n2. b", numbers.debugDescription)
    check("list keeps indent",
          applied("\ta", NoteFormat.toggleList("\ta", NSRange(location: 2, length: 0), numbered: false)) == "\t- a")

    print("\n[S20] bold and italic")
    let bold = NoteFormat.toggleEmphasis("hello world", NSRange(location: 6, length: 5), marker: "**")
    let bolded = applied("hello world", bold)
    check("bold wraps", bolded == "hello **world**" && bold.selection == NSRange(location: 8, length: 5))
    check("bold toggles back",
          applied(bolded, NoteFormat.toggleEmphasis(bolded, bold.selection, marker: "**")) == "hello world")
    check("bold with markers selected unwraps",
          applied(bolded, NoteFormat.toggleEmphasis(bolded, NSRange(location: 6, length: 9), marker: "**")) == "hello world")
    check("italic on bold makes both",
          applied("**b**", NoteFormat.toggleEmphasis("**b**", NSRange(location: 2, length: 1), marker: "*")) == "***b***")
    check("bold off bold-italic leaves italic",
          applied("***b***", NoteFormat.toggleEmphasis("***b***", NSRange(location: 3, length: 1), marker: "**")) == "*b*")
    let empty = NoteFormat.toggleEmphasis("ab", NSRange(location: 1, length: 0), marker: "**")
    check("bold with no selection opens a pair", applied("ab", empty) == "a****b" && empty.selection.location == 3)

    print("\n[S21] links")
    check("hyperlink", applied("x", NoteFormat.link("x", NSRange(location: 0, length: 1), label: "Google",
                                                    url: "google.com")) == "[Google](https://google.com)")
    check("bare link without text",
          applied("", NoteFormat.link("", NSRange(location: 0, length: 0), label: " ",
                                      url: "https://a.b/c")) == "https://a.b/c")
    check("spaces and brackets escaped",
          NoteFormat.normalizedURL("https://a.b/x y(1)") == "https://a.b/x%20y%281%29")
    let pasted = NoteFormat.pasteLink("see docs", NSRange(location: 4, length: 4), pasted: "https://x.y")
    check("paste URL over text links it", pasted.map { applied("see docs", $0) } == "see [docs](https://x.y)")
    check("paste plain text is ordinary",
          NoteFormat.pasteLink("see docs", NSRange(location: 4, length: 4), pasted: "words") == nil)
    check("paste with no selection is ordinary",
          NoteFormat.pasteLink("see", NSRange(location: 3, length: 0), pasted: "https://x.y") == nil)
    check("paste URL over a URL is ordinary",
          NoteFormat.pasteLink("https://a.b", NSRange(location: 0, length: 11), pasted: "https://x.y") == nil)

    print("\n[S22] inline spans")
    let sample = "**b** *i* [t](https://x.y) www.a.com app.py and https://q.r/s."
    let spans = NoteFormat.spans(in: sample)
    let ns = sample as NSString
    func text(_ s: NoteFormat.Span) -> String { ns.substring(with: s.content) }
    check("bold span", spans.contains { $0.kind == .bold && text($0) == "b" })
    check("italic span", spans.contains { $0.kind == .italic && text($0) == "i" })
    check("hyperlink span", spans.contains { $0.kind == .link(URL(string: "https://x.y")!) && text($0) == "t" })
    check("www link gets https", spans.contains { $0.kind == .link(URL(string: "https://www.a.com")!) })
    check("file names are not links", !spans.contains { text($0).contains("app.py") })
    check("trailing period left out", spans.contains { text($0) == "https://q.r/s" })
    check("five spans in all", spans.count == 5, "\(spans.count)")
    check("asterisks inside a URL are not italic",
          NoteFormat.spans(in: "https://x.y/a*b*c").allSatisfy { $0.kind != .italic })
    check("bold around a link keeps both",
          NoteFormat.spans(in: "**[t](https://x.y)**").count == 2)

    print("\n[S23] rendered note")
    let shown = NoteStyle.rendered("\n- **bold** and [site](example.com)\n\tnext\n\n", fontSize: 12)
    check("markup hidden, bullet drawn", shown.string == "• bold and site\n\tnext", shown.string.debugDescription)
    let boldAt = (shown.string as NSString).range(of: "bold").location
    let boldFont = shown.attribute(.font, at: boldAt, effectiveRange: nil) as? NSFont
    check("bold rendered bold", boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    let siteAt = (shown.string as NSString).range(of: "site").location
    check("link carries its URL",
          shown.attribute(.noteLink, at: siteAt, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    let para = shown.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    check("bullet lines hang", (para?.headIndent ?? 0) > 0)


    print("\n[S24] failed loads never overwrite data or backups")
    let corruptHome = home.appendingPathComponent("corrupt-case")
    let corruptDataDir = corruptHome.appendingPathComponent("data")
    try! FileManager.default.createDirectory(at: corruptDataDir, withIntermediateDirectories: true)
    let corruptPath = corruptDataDir.appendingPathComponent("state.json")
    let corruptBackup = corruptDataDir.appendingPathComponent("state.json.bak")
    let invalid = Data("{broken json".utf8)
    let savedBackup = Data(pythonJSON.utf8)
    try! invalid.write(to: corruptPath)
    try! savedBackup.write(to: corruptBackup)
    let broken = Store(home: corruptHome)
    check("bad JSON reports a load error", broken.lastError != nil)
    let rejected = broken.addGoals("Must not replace damaged data")
    check("failed-load edit reports no addition", rejected.added == 0)
    check("failed-load edit leaves original bytes", (try? Data(contentsOf: corruptPath)) == invalid)
    check("failed-load edit preserves backup", (try? Data(contentsOf: corruptBackup)) == savedBackup)
    check("failed-load edit reports an error", broken.lastError != nil)
    try! savedBackup.write(to: corruptPath, options: .atomic)
    broken.load()
    check("repaired file can be reloaded", broken.lastError == nil && broken.state.nextId == 7)
    check("editing resumes after repair", broken.addGoals("After repair").added == 1)

    print("\n[S25] stale native stores preserve one another's changes")
    let sharedHome = home.appendingPathComponent("shared-case")
    let firstWriter = Store(home: sharedHome)
    let staleWriter = Store(home: sharedHome)
    firstWriter.addGoals("First writer goal")
    staleWriter.addGoals("Second writer goal")
    let afterBoth = Store(home: sharedHome)
    check("both native writes survive", Set(afterBoth.goals.map(\.title)) ==
          Set(["First writer goal", "Second writer goal"]))
    check("native writers allocate unique IDs",
          afterBoth.goals.count == 2 && Set(afterBoth.goals.map(\.id)).count == 2)
    firstWriter.setReflection("Reflection from first writer")
    staleWriter.addDeadline(title: "Shared deadline", due: Date())
    let afterOtherFields = Store(home: sharedHome)
    check("stale deadline write preserves reflection",
          afterOtherFields.entry.reflection == "Reflection from first writer")
    check("stale writes preserve goals", afterOtherFields.goals.count == 2)
    check("deadline also survives", afterOtherFields.state.deadlines.count == 1)
    let priorGood = try! Data(contentsOf: sharedHome.appendingPathComponent("data/state.json"))
    try! invalid.write(to: sharedHome.appendingPathComponent("data/state.json"), options: .atomic)
    firstWriter.addGoals("Must not overwrite later corruption")
    check("already-open store protects newly corrupted file",
          (try? Data(contentsOf: sharedHome.appendingPathComponent("data/state.json"))) == invalid)
    try! priorGood.write(to: sharedHome.appendingPathComponent("data/state.json"), options: .atomic)


    print("\n[S26] lock contention and save failures are visible")
    firstWriter.load()
    let sharedLockPath = sharedHome.appendingPathComponent("data/state.lock")
    let held = Darwin.open(sharedLockPath.path, O_CREAT | O_RDWR, 0o600)
    check("test can open shared lock", held >= 0)
    if held >= 0 {
        check("test can acquire shared lock", flock(held, LOCK_EX | LOCK_NB) == 0)
        let busyResult = firstWriter.addGoals("Try after lock release")
        check("busy native writer reports no addition", busyResult.added == 0)
        check("busy native writer displays error", firstWriter.lastError != nil)
        if let goal = firstWriter.goals.first {
            check("busy title save reports failure", !firstWriter.update(goal, title: "Not saved"))
            check("busy note save reports failure", !firstWriter.update(goal, note: "Not saved"))
        }
        if let deadline = firstWriter.state.deadlines.first {
            check("busy deadline edit reports failure",
                  !firstWriter.updateDeadline(deadline, title: "Not saved", due: Date()))
        }
        check("busy native writer does not change disk",
              (try? Data(contentsOf: sharedHome.appendingPathComponent("data/state.json"))) == priorGood)
        flock(held, LOCK_UN)
        Darwin.close(held)
        check("edit succeeds after lock release", firstWriter.addGoals("Try after lock release").added == 1)
    }
    let backupFailure = sharedHome.appendingPathComponent("data/state.json.bak")
    try? FileManager.default.removeItem(at: backupFailure)
    try! FileManager.default.createDirectory(at: backupFailure, withIntermediateDirectories: true)
    let beforeFailedSave = try! Data(contentsOf: sharedHome.appendingPathComponent("data/state.json"))
    let failedSave = firstWriter.addGoals("Must roll back failed save")
    check("backup failure reports no addition", failedSave.added == 0)
    check("backup failure preserves disk state",
          (try? Data(contentsOf: sharedHome.appendingPathComponent("data/state.json"))) == beforeFailedSave)
    check("backup failure rolls back in-memory edit",
          !firstWriter.goals.contains { $0.title == "Must roll back failed save" })
    check("backup failure reports error", firstWriter.lastError != nil)
    try! FileManager.default.removeItem(at: backupFailure)

    print("\n[S27] native and Python processes share the same transaction lock")
    if CommandLine.arguments.count > 1 {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let mixedHome = home.appendingPathComponent("mixed-case")
        let nativeWriter = Store(home: mixedHome)
        nativeWriter.addGoals("Initial shared goal")
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.currentDirectoryURL = project
        python.environment = ProcessInfo.processInfo.environment.merging(
            ["DAILY_PLAN_HOME": mixedHome.path, "PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        python.arguments = ["python3", "-c", """
            import app, time
            from datetime import date
            for i in range(40):
                app.handle_api('/api/goals', 'POST',
                               {'date': date.today().isoformat(), 'titles': ['Python goal %d' % i]})
                time.sleep(0.001)
            """]
        do {
            try python.run()
            var nativeAdded = 0
            for i in 0..<40 {
                for _ in 0..<500 {
                    if nativeWriter.addGoals("Native goal \(i)").added == 1 {
                        nativeAdded += 1
                        break
                    }
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            python.waitUntilExit()
            check("Python writer exits successfully", python.terminationStatus == 0)
            check("native writer completes all edits", nativeAdded == 40)
            let combined = Store(home: mixedHome)
            check("all 81 mixed-process goals survive", combined.goals.count == 81,
                  "\(combined.goals.count)")
            check("all mixed-process IDs remain unique", Set(combined.goals.map(\.id)).count == 81)
            check("both sets of titles survive",
                  combined.goals.filter { $0.title.hasPrefix("Python goal ") }.count == 40 &&
                  combined.goals.filter { $0.title.hasPrefix("Native goal ") }.count == 40)
        } catch {
            check("cross-process test starts", false, error.localizedDescription)
        }
    } else {
        check("test script supplies project path for cross-process checks", false)
    }

    print("\n" + String(repeating: "=", count: 56))
    print("\(pass) passed, \(fail) failed")
    return fail
}

@main
struct CompatTests {
    static func main() async {
        let failures = await run()
        exit(failures == 0 ? 0 : 1)
    }
}

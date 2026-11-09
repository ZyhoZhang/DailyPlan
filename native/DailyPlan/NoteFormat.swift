import Foundation

// Notes are plain text with a light Markdown flavour, so state.json stays
// readable by the Python and Windows builds and the Markdown logs need no
// conversion:
//
//     leading tabs            indent
//     "- "  "* "  "• "        bullet items
//     "1. "  "a) "            numbered / lettered items
//     **bold**  *italic*      emphasis
//     [text](https://…)       hyperlink; bare https:// and www. links work too
//
// Every editing command is a pure function from (text, selection) to an
// `Edit`, so the note editor's behaviour is testable without a window. All
// ranges are UTF-16 offsets, like NSTextView's.

enum NoteFormat {

    struct Edit: Equatable {
        var range: NSRange        // what to replace
        var replacement: String
        var selection: NSRange    // caret / selection afterwards
    }

    // MARK: - Lines and list markers

    /// One line split into indent, list marker ("" when it is not a list
    /// item), and the text after them.
    struct Line: Equatable {
        var range = NSRange()     // the line, excluding its newline
        var indent = ""           // leading tabs / spaces
        var marker = ""           // "-", "*", "•", "12.", "c)" …
        var body = ""             // text after indent + marker + one space
        var prefixLength = 0      // UTF-16 length of indent + marker + space
    }

    private static let markerRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*•]|\d{1,3}[.)]|[A-Za-z][.)])[ \t]"#)

    static func parse(_ raw: String) -> Line {
        let ns = raw as NSString
        if let m = markerRegex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            return Line(range: NSRange(location: 0, length: ns.length),
                        indent: ns.substring(with: m.range(at: 1)),
                        marker: ns.substring(with: m.range(at: 2)),
                        body: ns.substring(from: m.range.length),
                        prefixLength: m.range.length)
        }
        let indent = String(raw.prefix { $0 == "\t" || $0 == " " })
        return Line(range: NSRange(location: 0, length: ns.length), indent: indent,
                    body: String(raw.dropFirst(indent.count)),
                    prefixLength: (indent as NSString).length)
    }

    static func line(at location: Int, in text: String) -> Line {
        let ns = text as NSString
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                        for: NSRange(location: min(location, ns.length), length: 0))
        var line = parse(ns.substring(with: NSRange(location: start, length: contentsEnd - start)))
        line.range = NSRange(location: start, length: contentsEnd - start)
        return line
    }

    /// Every line the selection touches. A selection that ends exactly at the
    /// start of a line does not touch that line.
    static func lines(in text: String, covering sel: NSRange) -> [Line] {
        let length = (text as NSString).length
        let last = sel.length > 0 ? NSMaxRange(sel) - 1 : sel.location
        var out: [Line] = []
        var loc = sel.location
        while true {
            let l = line(at: loc, in: text)
            out.append(l)
            let next = NSMaxRange(l.range) + 1
            if next > last || next > length { break }
            loc = next
        }
        return out
    }

    static func isBullet(_ marker: String) -> Bool { ["-", "*", "•"].contains(marker) }

    /// The marker for the item after this one: 3. → 4., c) → d), - → -.
    static func nextMarker(_ marker: String) -> String {
        guard let close = marker.last, close == "." || close == ")" else { return marker }
        let head = marker.dropLast()
        if let n = Int(head) { return "\(n + 1)\(close)" }
        if head.count == 1, let c = head.unicodeScalars.first, c != "z", c != "Z",
           let next = Unicode.Scalar(c.value + 1) {
            return "\(Character(next))\(close)"
        }
        return marker
    }

    // MARK: - Return

    /// What Return does on a line the caret is past the marker of.
    enum NewlineAction: Equatable {
        /// Break the line and start the next one with this prefix (indent + marker + space).
        case newLine(prefix: String)
        /// Don't break the line; replace this line's indent + marker with this
        /// instead. Used to end, or outdent, an empty list item.
        case rewritePrefix(String)
    }

    /// The Return-key policy for outlines like
    ///
    ///     Specifically,
    ///         1. CEO
    ///             a) -> CEO
    ///             b) -> Duality CEO
    ///
    /// An item with text starts the next item (b) → c)); an empty item ends
    /// the list where it stands, keeping its indent; a plain line passes its
    /// indent on, so an indented paragraph carries on indented.
    static func newlineAction(for line: Line) -> NewlineAction {
        if line.marker.isEmpty { return .newLine(prefix: line.indent) }
        if line.body.trimmingCharacters(in: .whitespaces).isEmpty { return .rewritePrefix(line.indent) }
        return .newLine(prefix: line.indent + nextMarker(line.marker) + " ")
    }

    static func newline(_ text: String, _ sel: NSRange) -> Edit {
        let line = line(at: sel.location, in: text)
        // Caret inside the indent or marker: a plain break that pushes the item down.
        let action = sel.location < line.range.location + line.prefixLength
            ? .newLine(prefix: "") : newlineAction(for: line)
        switch action {
        case .newLine(let prefix):
            let insert = "\n" + prefix
            return Edit(range: sel, replacement: insert,
                        selection: NSRange(location: sel.location + (insert as NSString).length, length: 0))
        case .rewritePrefix(let prefix):
            // An empty item's stray spaces go with its marker.
            let blank = line.body.trimmingCharacters(in: .whitespaces).isEmpty
            let range = NSRange(location: line.range.location,
                                length: blank ? line.range.length : line.prefixLength)
            return Edit(range: range, replacement: prefix,
                        selection: NSRange(location: range.location + (prefix as NSString).length, length: 0))
        }
    }

    // MARK: - Indent and lists

    /// Applies `transform` to every line the selection touches, keeping the
    /// selection on the same text.
    private static func rewriteLines(_ text: String, _ sel: NSRange,
                                     _ transform: (String) -> String) -> Edit {
        let touched = lines(in: text, covering: sel)
        let block = NSRange(location: touched[0].range.location,
                            length: NSMaxRange(touched[touched.count - 1].range) - touched[0].range.location)
        let old = (text as NSString).substring(with: block).components(separatedBy: "\n")
        let new = old.map(transform)
        let replacement = new.joined(separator: "\n")
        let firstDelta = (new[0] as NSString).length - (old[0] as NSString).length
        let totalDelta = (replacement as NSString).length - block.length
        let start = max(block.location, sel.location + firstDelta)
        let end = max(start, NSMaxRange(sel) + totalDelta)
        return Edit(range: block, replacement: replacement,
                    selection: NSRange(location: start, length: end - start))
    }

    static func indent(_ text: String, _ sel: NSRange) -> Edit {
        rewriteLines(text, sel) { "\t" + $0 }
    }

    /// Removes one tab, or up to four spaces, from each touched line.
    static func outdent(_ text: String, _ sel: NSRange) -> Edit {
        rewriteLines(text, sel) { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(line.prefix(4).prefix { $0 == " " }.count))
        }
    }

    /// Tab indents when that is clearly the intent — several lines selected,
    /// or the caret on a list item — and otherwise types a tab, which is how
    /// these notes have always been indented.
    static func tab(_ text: String, _ sel: NSRange) -> Edit? {
        let touched = lines(in: text, covering: sel)
        guard touched.count > 1 || !touched[0].marker.isEmpty else { return nil }
        return indent(text, sel)
    }

    /// Makes the touched lines a bulleted or numbered list, or plain lines
    /// again if they already are that kind of list.
    static func toggleList(_ text: String, _ sel: NSRange, numbered: Bool) -> Edit {
        let touched = lines(in: text, covering: sel)
        let skipBlank = touched.count > 1
        let items = touched.filter { !(skipBlank && $0.marker.isEmpty && $0.body.isEmpty) }
        let already = !items.isEmpty && items.allSatisfy {
            !$0.marker.isEmpty && isBullet($0.marker) != numbered
        }
        var n = 0
        return rewriteLines(text, sel) { raw in
            let l = parse(raw)
            if already { return l.indent + l.body }
            if skipBlank && l.marker.isEmpty && l.body.isEmpty { return raw }
            n += 1
            return l.indent + (numbered ? "\(n)." : "-") + " " + l.body
        }
    }

    // MARK: - Emphasis

    /// Wraps the selection in `marker` ("**" bold, "*" italic), or unwraps it
    /// if it already is. Three asterisks count as both.
    static func toggleEmphasis(_ text: String, _ sel: NSRange, marker: String) -> Edit {
        let ns = text as NSString
        let m = (marker as NSString).length
        let unwrapRuns: Set<Int> = m == 2 ? [2, 3] : [1, 3]
        let star = UInt16(UInt8(ascii: "*"))

        var before = 0
        while sel.location - before > 0, ns.character(at: sel.location - before - 1) == star { before += 1 }
        var after = 0
        while NSMaxRange(sel) + after < ns.length, ns.character(at: NSMaxRange(sel) + after) == star { after += 1 }
        let selected = ns.substring(with: sel)

        // Markers just outside the selection.
        if unwrapRuns.contains(min(before, after)) {
            return Edit(range: NSRange(location: sel.location - m, length: sel.length + 2 * m),
                        replacement: selected,
                        selection: NSRange(location: sel.location - m, length: sel.length))
        }
        // Markers included in the selection.
        let lead = selected.prefix { $0 == "*" }.count
        let trail = selected.reversed().prefix { $0 == "*" }.count
        if sel.length > 2 * m, lead < sel.length, unwrapRuns.contains(min(lead, trail)) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
            return Edit(range: sel, replacement: inner,
                        selection: NSRange(location: sel.location, length: (inner as NSString).length))
        }
        return Edit(range: sel, replacement: marker + selected + marker,
                    selection: NSRange(location: sel.location + m, length: sel.length))
    }

    // MARK: - Links

    /// A single token that is clearly a web address.
    static func isURL(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.range(of: #"^(https?://|www\.)\S+$"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "example.com" → "https://example.com"; anything with a scheme is kept.
    /// Spaces and parentheses are escaped so the Markdown link stays intact.
    static func normalizedURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil {
            s = "https://" + s
        }
        return s.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    /// Replaces the selection with a hyperlink, or a bare link when there is
    /// no text to show.
    static func link(_ text: String, _ sel: NSRange, label: String, url: String) -> Edit {
        let address = normalizedURL(url)
        let label = label.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let replacement = label.isEmpty ? address : "[\(label)](\(address))"
        return Edit(range: sel, replacement: replacement,
                    selection: NSRange(location: sel.location + (replacement as NSString).length, length: 0))
    }

    /// Pasting a URL over selected text links that text, as most editors do.
    static func pasteLink(_ text: String, _ sel: NSRange, pasted: String) -> Edit? {
        let selected = (text as NSString).substring(with: sel)
        guard sel.length > 0, isURL(pasted), !isURL(selected),
              !selected.contains("\n"), !selected.contains("](") else { return nil }
        return link(text, sel, label: selected, url: pasted)
    }

    // MARK: - Inline spans, for styling

    struct Span: Equatable {
        enum Kind: Equatable { case bold, italic, link(URL) }
        var kind: Kind
        var whole: NSRange        // including the markup
        var content: NSRange      // the text a reader sees
    }

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    // Explicit schemes only: a data detector would also link "app.py" and "clean.do".
    private static let bareURLRegex = try! NSRegularExpression(
        pattern: #"\b(?:https?://|www\.)[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'"]"#,
        options: .caseInsensitive)
    private static let boldRegex = try! NSRegularExpression(
        pattern: #"\*\*(?=[^\s*])(.+?)(?<=[^\s*])\*\*"#)
    private static let italicRegex = try! NSRegularExpression(
        pattern: #"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#)

    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out: [Span] = []
        var addresses: [NSRange] = []   // URL text, where emphasis markers can't start or end

        for m in linkRegex.matches(in: text, range: all) {
            guard let url = URL(string: normalizedURL(ns.substring(with: m.range(at: 2)))) else { continue }
            out.append(Span(kind: .link(url), whole: m.range, content: m.range(at: 1)))
            addresses.append(m.range(at: 2))
        }
        let linked = out.map(\.whole)
        for m in bareURLRegex.matches(in: text, range: all)
        where !linked.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            guard let url = URL(string: normalizedURL(ns.substring(with: m.range))) else { continue }
            out.append(Span(kind: .link(url), whole: m.range, content: m.range))
            addresses.append(m.range)
        }
        let insideAddress = { (i: Int) in addresses.contains { NSLocationInRange(i, $0) } }
        for (regex, kind) in [(boldRegex, Span.Kind.bold), (italicRegex, .italic)] {
            for m in regex.matches(in: text, range: all)
            where !insideAddress(m.range.location) && !insideAddress(NSMaxRange(m.range) - 1) {
                out.append(Span(kind: kind, whole: m.range, content: m.range(at: 1)))
            }
        }
        return out
    }
}

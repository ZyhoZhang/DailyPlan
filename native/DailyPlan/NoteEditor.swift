import SwiftUI
import AppKit

extension NSAttributedString.Key {
    /// Where a run of note text links to. Deliberately not `.link`: NSTextView
    /// opens those on any click, which fights placing the caret while editing.
    static let noteLink = NSAttributedString.Key("DailyPlanNoteLink")
}

// MARK: - Styling

enum NoteStyle {
    static let tabInterval: CGFloat = 24

    /// Tab stops every `tabInterval`, and wrapped lines hang under the text
    /// rather than under the marker or back at the margin.
    private static func paragraph(prefix: String, font: NSFont) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.tabStops = []
        p.defaultTabInterval = tabInterval
        let tabs = prefix.prefix { $0 == "\t" }.count
        p.headIndent = CGFloat(tabs) * tabInterval
            + (String(prefix.dropFirst(tabs)) as NSString).size(withAttributes: [.font: font]).width
        p.paragraphSpacing = 1
        return p
    }

    /// Paragraph styles for every line, plus the marker ranges.
    private static func styleLines(_ s: NSMutableAttributedString, font: NSFont,
                                   marker: (NSRange) -> Void) {
        let ns = s.string as NSString
        var loc = 0
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let line = NoteFormat.parse(ns.substring(with: lineRange))
            let prefix = ns.substring(with: NSRange(location: lineRange.location, length: line.prefixLength))
            s.addAttribute(.paragraphStyle, value: paragraph(prefix: prefix, font: font), range: lineRange)
            if !line.marker.isEmpty {
                marker(NSRange(location: lineRange.location + (line.indent as NSString).length,
                               length: (line.marker as NSString).length))
            }
            loc = NSMaxRange(lineRange)
        }
    }

    private static func markup(of span: NoteFormat.Span) -> [NSRange] {
        [NSRange(location: span.whole.location, length: span.content.location - span.whole.location),
         NSRange(location: NSMaxRange(span.content), length: NSMaxRange(span.whole) - NSMaxRange(span.content))]
            .filter { $0.length > 0 }
    }

    private static func applyInline(_ span: NoteFormat.Span, to s: NSMutableAttributedString) {
        switch span.kind {
        case .bold: s.applyFontTraits(.boldFontMask, range: span.content)
        case .italic: s.applyFontTraits(.italicFontMask, range: span.content)
        case .link(let url):
            s.addAttributes([.foregroundColor: NSColor.linkColor,
                             .underlineStyle: NSUnderlineStyle.single.rawValue,
                             .noteLink: url], range: span.content)
        }
    }

    /// Styles the note in place while editing: the markup stays visible but
    /// quiet, so what you type is exactly what is stored.
    static func decorate(_ storage: NSTextStorage, fontSize: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor],
                              range: NSRange(location: 0, length: storage.length))
        styleLines(storage, font: font) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: $0)
        }
        for span in NoteFormat.spans(in: storage.string) {
            applyInline(span, to: storage)
            for r in markup(of: span) {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            }
        }
        storage.endEditing()
    }

    /// The note as a reader sees it: markup removed, bullets drawn as •.
    static func rendered(_ text: String, fontSize: CGFloat,
                         color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let trimmed = text.trimmingCharacters(in: .newlines)
        let font = NSFont.systemFont(ofSize: fontSize)
        let out = NSMutableAttributedString(string: trimmed, attributes: [.font: font, .foregroundColor: color])
        styleLines(out, font: font) { range in
            if NoteFormat.isBullet((out.string as NSString).substring(with: range)) {
                out.replaceCharacters(in: range, with: "•")   // same length, ranges stay valid
            }
        }
        var hidden: [NSRange] = []
        for span in NoteFormat.spans(in: trimmed) {
            applyInline(span, to: out)
            hidden += markup(of: span)
        }
        // Delete from the end so earlier ranges stay valid; skip any overlap.
        var floor = Int.max
        for r in hidden.sorted(by: { $0.location > $1.location }) where NSMaxRange(r) <= floor {
            out.deleteCharacters(in: r)
            floor = r.location
        }
        return out
    }
}

// MARK: - Text view

/// The note's text view. It owns the note's keyboard shortcuts itself, so
/// they work no matter what SwiftUI does with key equivalents around it.
final class NoteTextView: NSTextView {
    var onDone: () -> Void = {}
    var onLinkRequest: () -> Void = {}
    var focusOnAppear = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, window != nil else { return }
        focusOnAppear = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
        }
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleShortcut(event) { super.keyDown(with: event) }
    }

    /// ⌘↵ finishes, ⌘B / ⌘I emphasise, ⌘K links.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard isEditable,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
        else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (36, _), (76, _): onDone()           // Return, keypad Enter
        case (_, "b"): formatBold()
        case (_, "i"): formatItalic()
        case (_, "k"): onLinkRequest()
        default: return false
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) { onDone() }   // Esc
    override func insertBacktab(_ sender: Any?) { formatOutdent() }

    override func insertNewline(_ sender: Any?) {
        let edit = NoteFormat.newline(string, selectedRange())
        guard edit.range == selectedRange(), edit.replacement.hasPrefix("\n") else { return apply(edit) }
        // A line break goes through AppKit so autocorrect and auto-capitalise
        // still finish the last word, as they do on Space; then the prefix.
        super.insertNewline(sender)
        let prefix = String(edit.replacement.dropFirst())
        if !prefix.isEmpty { insertText(prefix, replacementRange: selectedRange()) }
    }

    override func insertTab(_ sender: Any?) {
        if let edit = NoteFormat.tab(string, selectedRange()) { apply(edit) } else { super.insertTab(sender) }
    }

    override func paste(_ sender: Any?) {
        if let pasted = NSPasteboard.general.string(forType: .string),
           let edit = NoteFormat.pasteLink(string, selectedRange(), pasted: pasted) {
            apply(edit)
        } else {
            super.paste(sender)
        }
    }

    // MARK: Formatting commands, shared by the shortcuts and the format bar

    func formatBold() { apply(NoteFormat.toggleEmphasis(string, selectedRange(), marker: "**")) }
    func formatItalic() { apply(NoteFormat.toggleEmphasis(string, selectedRange(), marker: "*")) }
    func formatList(numbered: Bool) { apply(NoteFormat.toggleList(string, selectedRange(), numbered: numbered)) }
    func formatIndent() { apply(NoteFormat.indent(string, selectedRange())) }
    func formatOutdent() { apply(NoteFormat.outdent(string, selectedRange())) }

    func insertLink(text: String, url: String, replacing range: NSRange) {
        guard NSMaxRange(range) <= (string as NSString).length else { return }
        apply(NoteFormat.link(string, range, label: text, url: url))
    }

    /// Goes through shouldChangeText / didChangeText so the change is one undo
    /// step and the delegate sees it like typing.
    func apply(_ edit: NoteFormat.Edit) {
        guard isEditable, shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        window?.makeFirstResponder(self)
    }

    // MARK: Links

    /// A read-only note lets clicks through to the row, except on links.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isEditable { return super.hitTest(point) }
        return link(at: convert(point, from: superview)) == nil ? nil : self
    }

    /// Click opens a link in a read-only note; ⌘-click while editing.
    override func mouseDown(with event: NSEvent) {
        if let url = link(at: convert(event.locationInWindow, from: nil)),
           !isEditable || event.modifierFlags.contains(.command) {
            // The second click of a double-click must not open it again.
            if event.clickCount == 1 { NSWorkspace.shared.open(url) }
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isEditable, let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return }
        ts.enumerateAttribute(.noteLink, in: NSRange(location: 0, length: ts.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphs,
                                       withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                       in: tc) { rect, _ in
                self.addCursorRect(rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y),
                                   cursor: .pointingHand)
            }
        }
    }

    private func link(at point: NSPoint) -> URL? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        return index < ts.length ? ts.attribute(.noteLink, at: index, effectiveRange: nil) as? URL : nil
    }
}

/// Lets the SwiftUI format bar reach the live text view.
final class NoteEditorProxy {
    weak var textView: NoteTextView?
}

// MARK: - SwiftUI wrapper

/// A goal's note: rendered for reading, or editable as light Markdown.
struct NoteView: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var proxy: NoteEditorProxy?
    var onDone: () -> Void = {}
    var onLinkRequest: () -> Void = {}

    private var fontSize: CGFloat { editable ? 13 : 12 }

    func makeNSView(context: Context) -> NoteTextView {
        // TextKit 1: sizing and link hit-testing below use the layout manager.
        let tv = NoteTextView(usingTextLayoutManager: false)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.isEditable = editable
        tv.isSelectable = editable
        tv.isContinuousSpellCheckingEnabled = editable
        // Read-only text starts flush with the goal title above it.
        tv.textContainerInset = editable ? NSSize(width: 4, height: 5) : .zero
        tv.textContainer?.lineFragmentPadding = editable ? 2 : 0
        tv.focusOnAppear = editable
        proxy?.textView = tv
        return tv
    }

    func updateNSView(_ tv: NoteTextView, context: Context) {
        context.coordinator.parent = self
        tv.onDone = onDone
        tv.onLinkRequest = onLinkRequest
        if editable {
            guard tv.string != text, !tv.hasMarkedText() else { return }
            tv.string = text
            NoteStyle.decorate(tv.textStorage!, fontSize: fontSize)
        } else if context.coordinator.rendered != text {
            context.coordinator.rendered = text
            tv.textStorage?.setAttributedString(NoteStyle.rendered(text, fontSize: fontSize))
            tv.window?.invalidateCursorRects(for: tv)
        }
    }

    /// Height for the offered width, measured with the view's own layout
    /// manager so it matches what is drawn.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NoteTextView, context: Context) -> CGSize? {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let inset = tv.textContainerInset
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let saved = tc.containerSize
        tc.containerSize = NSSize(width: max((offered ?? 100_000) - 2 * inset.width, 40),
                                  height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        tc.containerSize = saved
        let natural = ceil(used.width + 2 * inset.width + 2 * tc.lineFragmentPadding)
        return CGSize(width: offered ?? natural, height: ceil(used.height + 2 * inset.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteView
        var rendered: String?

        init(_ parent: NoteView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            // Leave text that an input method is still composing alone.
            guard let tv = notification.object as? NoteTextView, !tv.hasMarkedText() else { return }
            NoteStyle.decorate(tv.textStorage!, fontSize: parent.fontSize)
            tv.invalidateIntrinsicContentSize()
            parent.text = tv.string
        }
    }
}

// MARK: - Link form

/// Text is optional: without it the note gets the bare address. The fields
/// are bindings because a popover's @State outlives one presentation and
/// would ignore each new selection.
struct LinkForm: View {
    @Binding var text: String
    @Binding var url: String
    let onInsert: (_ text: String, _ url: String) -> Void
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Insert link").font(.headline)
            TextField("Text to show (optional)", text: $text)
            TextField("https://…", text: $url)
                .focused($urlFocused)
                .onSubmit(insert)
            HStack {
                Text("↵ to insert · Esc to cancel").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Insert", action: insert)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .frame(width: 300)
        .onAppear { urlFocused = true }
    }

    private func insert() {
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onInsert(text, url)
    }
}

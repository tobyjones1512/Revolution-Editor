import AppKit

/// An NSTextView with an IDE's editing behaviour: a gutter with line numbers and fold arrows, code folding,
/// auto-indent, auto-closing pairs, comment toggling, line moves, bracket matching and a current-line band.
/// (An NSRulerView gutter made the whole SwiftUI window around it stop drawing, so the gutter is painted by the text view itself.)
final class GutterTextView: NSTextView {
    var language: CodeLanguage = .plainText
    var codeFolding = false
    var gutterWidth: CGFloat = 0 {
        didSet {
            guard gutterWidth != oldValue else { return }
            textContainerInset = NSSize(width: gutterWidth + 6, height: 6)
            needsDisplay = true
        }
    }

    private var prefs: CodeEditorPrefs { CodeEditorPrefs.shared }
    private var ns: NSString { string as NSString }
    private func char(at i: Int) -> Character? { i >= 0 && i < ns.length ? Character(UnicodeScalar(ns.character(at: i)) ?? " ") : nil }
    private var unit: String { prefs.indentUnit }

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private var matchedBrackets: [NSRange] = []

    private var commentPrefix: String? {
        switch language {
        case .swift, .c, .cpp, .objc, .javascript, .typescript, .rust, .go, .java, .php: return "//"
        case .python, .shell, .yaml, .ruby: return "#"
        case .sql: return "--"
        default: return nil
        }
    }

    // MARK: Lines

    private var lineStartsCache: [Int]?
    private var lineStarts: [Int] {
        if let lineStartsCache { return lineStartsCache }
        var starts = [0]
        var i = 0
        let s = ns
        while i < s.length { if s.character(at: i) == 10 { starts.append(i + 1) }; i += 1 }
        lineStartsCache = starts
        return starts
    }
    /// Zero-based line containing a character index.
    private func lineIndex(of location: Int) -> Int {
        let starts = lineStarts
        var lo = 0, hi = starts.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if starts[mid] <= location { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    // MARK: Folding

    struct FoldRegion { var lineStart: Int; var hide: NSRange }
    private var regions: [FoldRegion] = []
    private var regionAtLine: [Int: FoldRegion] = [:]
    /// Folded regions: where the hidden text starts -> where it ends.
    private var folded: [Int: Int] = [:]
    var hiddenRanges: [NSRange] { folded.map { NSRange(location: $0.key, length: $0.value - $0.key) } }
    private var chips: [(rect: NSRect, start: Int)] = []

    /// Call after the text changed: refreshes line numbers and fold regions.
    func textChanged() {
        lineStartsCache = nil
        regions = codeFolding ? computeRegions() : []
        regionAtLine = [:]
        for r in regions where regionAtLine[r.lineStart] == nil || regionAtLine[r.lineStart]!.hide.length < r.hide.length { regionAtLine[r.lineStart] = r }
        var reconciled: [Int: Int] = [:]
        for (s, _) in folded { if let r = regions.first(where: { $0.hide.location == s }) { reconciled[s] = NSMaxRange(r.hide) } }
        let changed = reconciled != folded
        folded = reconciled
        if changed { relayout() }
        needsDisplay = true
    }

    /// An edit is about to happen: keep folds attached to their text; an edit inside one opens it.
    func willEdit(_ range: NSRange, replacementLength: Int) {
        guard !folded.isEmpty else { return }
        let delta = replacementLength - range.length
        var next: [Int: Int] = [:]
        for (s, e) in folded {
            if range.location >= e { next[s] = e }
            else if NSMaxRange(range) <= s { next[s + delta] = e + delta }
        }
        folded = next
    }

    private func relayout() {
        guard let lm = layoutManager else { return }
        let whole = NSRange(location: 0, length: ns.length)
        lm.invalidateGlyphs(forCharacterRange: whole, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: whole, actualCharacterRange: nil)
        if let hidden = hiddenRanges.first(where: { NSLocationInRange(selectedRange().location, $0) }) { setSelectedRange(NSRange(location: hidden.location, length: 0)) }
        needsDisplay = true
    }

    private func toggleFold(_ region: FoldRegion) {
        if folded[region.hide.location] != nil { folded[region.hide.location] = nil } else { folded[region.hide.location] = NSMaxRange(region.hide) }
        relayout()
    }

    func foldAll() { for r in regions { folded[r.hide.location] = NSMaxRange(r.hide) }; relayout() }
    func unfoldAll() { folded = [:]; relayout() }

    private func computeRegions() -> [FoldRegion] {
        switch language {
        case .python, .yaml: return indentRegions()
        case .html, .xml, .markdown, .plainText: return []
        default: return braceRegions()
        }
    }

    /// `{ ... }` blocks spanning lines, skipping strings and comments.
    private func braceRegions() -> [FoldRegion] {
        let s = ns, n = s.length
        let slashComments = commentPrefix == "//"
        var out: [FoldRegion] = []
        var stack: [Int] = []
        var i = 0
        while i < n {
            let c = s.character(at: i)
            if slashComments, c == 47, i + 1 < n, s.character(at: i + 1) == 47 {
                while i < n, s.character(at: i) != 10 { i += 1 }
                continue
            }
            if slashComments, c == 47, i + 1 < n, s.character(at: i + 1) == 42 {
                i += 2
                while i + 1 < n, !(s.character(at: i) == 42 && s.character(at: i + 1) == 47) { i += 1 }
                i += 2; continue
            }
            if c == 34 || c == 39 || c == 96 {   // " ' `
                var j = i + 1
                while j < n, s.character(at: j) != c, s.character(at: j) != 10 || c == 96 { if s.character(at: j) == 92 { j += 1 }; j += 1 }
                if j < n, s.character(at: j) == c { i = j + 1; continue }
            }
            if c == 123 { stack.append(i) }
            else if c == 125, let open = stack.popLast() {
                let openLine = s.lineRange(for: NSRange(location: open, length: 0))
                if i >= NSMaxRange(openLine) {
                    let start = NSMaxRange(openLine) - 1   // the newline ending the opening line
                    out.append(FoldRegion(lineStart: openLine.location, hide: NSRange(location: start, length: i - start)))
                }
            }
            i += 1
        }
        return out
    }

    /// Indented blocks (Python, YAML): a line followed by deeper-indented lines.
    private func indentRegions() -> [FoldRegion] {
        let s = ns
        let starts = lineStarts
        func indent(_ line: Int) -> Int? {
            let r = s.lineRange(for: NSRange(location: starts[line], length: 0))
            var width = 0, i = r.location
            while i < NSMaxRange(r) {
                let c = s.character(at: i)
                if c == 32 { width += 1 } else if c == 9 { width += prefs.tabWidth } else if c == 10 || c == 13 { return nil } else { return width }
                i += 1
            }
            return nil
        }
        var out: [FoldRegion] = []
        var stack: [(line: Int, indent: Int)] = []
        var lastContent = 0
        func close(_ entry: (line: Int, indent: Int)) {
            guard lastContent > entry.line else { return }
            let open = s.lineRange(for: NSRange(location: starts[entry.line], length: 0))
            let last = s.lineRange(for: NSRange(location: starts[lastContent], length: 0))
            var end = NSMaxRange(last)
            if end > last.location, s.character(at: end - 1) == 10 { end -= 1 }
            let hideStart = NSMaxRange(open) - 1
            if end > hideStart { out.append(FoldRegion(lineStart: open.location, hide: NSRange(location: hideStart, length: end - hideStart))) }
        }
        for line in 0..<starts.count {
            guard let ind = indent(line) else { continue }
            while let top = stack.last, top.indent >= ind { close(stack.removeLast()) }
            stack.append((line, ind))
            lastContent = line
        }
        while let top = stack.popLast() { close(top) }
        return out
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let chip = chips.first(where: { $0.rect.contains(p) }), let r = regions.first(where: { $0.hide.location == chip.start }) { toggleFold(r); return }
        if codeFolding, gutterWidth > 0, p.x >= gutterWidth - 16, p.x < gutterWidth {
            let idx = characterIndexForInsertion(at: NSPoint(x: textContainerInset.width + 1, y: p.y))
            let lineStart = ns.lineRange(for: NSRange(location: min(idx, ns.length), length: 0)).location
            if let r = regionAtLine[lineStart] { toggleFold(r) }
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Editing

    /// Replaces a range as one undoable edit and leaves the selection where asked.
    private func edit(_ range: NSRange, with text: String, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    /// The whole lines the selection touches (not the next line when it ends at a line start).
    private func selectedLines() -> NSRange {
        var sel = selectedRange()
        if sel.length > 0, char(at: sel.upperBound - 1) == "\n" { sel.length -= 1 }
        return ns.lineRange(for: sel)
    }

    private func transformLines(_ transform: ([String]) -> [String]) {
        let range = selectedLines()
        let text = ns.substring(with: range)
        let trailing = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if trailing { lines.removeLast() }
        let out = transform(lines).joined(separator: "\n") + (trailing ? "\n" : "")
        edit(range, with: out, select: NSRange(location: range.location, length: (out as NSString).length - (trailing ? 1 : 0)))
    }

    override func insertNewline(_ sender: Any?) {
        guard prefs.autoIndent else { super.insertNewline(sender); return }
        let loc = selectedRange().location
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: loc, length: 0)))
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let before = char(at: loc - 1), after = char(at: loc)
        let opens = (before.map { "{([".contains($0) } ?? false) || (language == .python && before == ":")
        if let b = before, let a = after, Self.pairs[b] == a, "{([".contains(b) {
            // Between a pair: open a body line and put the closer on its own line.
            let text = "\n" + indent + unit + "\n" + indent
            edit(selectedRange(), with: text, select: NSRange(location: loc + 1 + (indent as NSString).length + (unit as NSString).length, length: 0))
        } else {
            edit(selectedRange(), with: "\n" + indent + (opens ? unit : ""))
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard prefs.autoClosePairs, let typed = string as? String, typed.count == 1, let c = typed.first, !hasMarkedText(), language != .plainText && language != .markdown else {
            super.insertText(string, replacementRange: replacementRange); return
        }
        let loc = selectedRange().location, hasSelection = selectedRange().length > 0
        // Typing a closer over the same closer just steps past it.
        if !hasSelection, char(at: loc) == c, Self.pairs.values.contains(c) {
            setSelectedRange(NSRange(location: loc + 1, length: 0)); return
        }
        if let closer = Self.pairs[c] {
            let before = char(at: loc - 1), after = char(at: loc)
            let quote = c == "\"" || c == "'" || c == "`"
            let wordBefore = before.map { $0.isLetter || $0.isNumber } ?? false
            if hasSelection {   // wrap the selection
                let sel = selectedRange()
                edit(sel, with: String(c) + ns.substring(with: sel) + String(closer), select: NSRange(location: sel.location + 1, length: sel.length)); return
            }
            if !(quote && wordBefore), after == nil || after!.isWhitespace || Self.pairs.values.contains(after!) {
                edit(selectedRange(), with: String(c) + String(closer), select: NSRange(location: loc + 1, length: 0)); return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        let loc = selectedRange().location
        if prefs.autoClosePairs, selectedRange().length == 0, let b = char(at: loc - 1), let a = char(at: loc), Self.pairs[b] == a {
            edit(NSRange(location: loc - 1, length: 2), with: "", select: NSRange(location: loc - 1, length: 0))
        } else {
            super.deleteBackward(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0, ns.substring(with: selectedRange()).contains("\n") { indent() }
        else if prefs.insertSpaces {
            let lineStart = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
            let column = selectedRange().location - lineStart
            edit(selectedRange(), with: String(repeating: " ", count: prefs.tabWidth - column % prefs.tabWidth))
        } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) { outdent() }

    private func indent() { transformLines { $0.map { $0.isEmpty ? $0 : unit + $0 } } }

    private func outdent() {
        let width = prefs.tabWidth
        transformLines { $0.map { l in
            if l.hasPrefix("\t") { return String(l.dropFirst()) }
            return String(l.dropFirst(min(width, l.prefix(while: { $0 == " " }).count)))
        } }
    }

    private func toggleComment() {
        guard let prefix = commentPrefix else { return }
        transformLines { lines in
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allCommented = !content.isEmpty && content.allSatisfy { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(prefix) }
            return lines.map { l in
                guard !l.trimmingCharacters(in: .whitespaces).isEmpty else { return l }
                let lead = l.prefix(while: { $0 == " " || $0 == "\t" })
                let rest = l.dropFirst(lead.count)
                if allCommented {
                    let r = rest.dropFirst(prefix.count)
                    return String(lead) + String(r.hasPrefix(" ") ? r.dropFirst() : r)
                }
                return String(lead) + prefix + " " + rest
            }
        }
    }

    private func duplicateLines() {
        let range = selectedLines()
        let text = ns.substring(with: range)
        let lead = text.hasSuffix("\n") ? "" : "\n"
        edit(NSRange(location: range.upperBound, length: 0), with: lead + text, select: NSRange(location: range.upperBound + lead.count, length: range.length - (text.hasSuffix("\n") ? 1 : 0)))
    }

    private func moveLines(up: Bool) {
        let block = selectedLines()
        let other: NSRange
        if up { guard block.location > 0 else { return }; other = ns.lineRange(for: NSRange(location: block.location - 1, length: 0)) }
        else { guard block.upperBound < ns.length else { return }; other = ns.lineRange(for: NSRange(location: block.upperBound, length: 0)) }
        let (a, b) = up ? (other, block) : (block, other)
        let aText = ns.substring(with: a), bText = ns.substring(with: b)
        var newA = bText, newB = aText
        if !bText.hasSuffix("\n") { newA = bText + "\n"; newB = String(aText.dropLast()) }
        let movedLength = block.length - (ns.substring(with: block).hasSuffix("\n") ? 1 : 0)
        let movedStart = up ? a.location : a.location + (newA as NSString).length
        edit(NSUnionRange(a, b), with: newA + newB, select: NSRange(location: movedStart, length: movedLength))
    }

    func promptGoToLine() {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let target = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), target > 0 else { return }
        let starts = lineStarts
        let loc = starts[min(target, starts.count) - 1]
        setSelectedRange(NSRange(location: loc, length: 0))
        scrollRangeToVisible(NSRange(location: loc, length: 0))
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers ?? ""
        switch (flags, key) {
        case ([.command], "/"): toggleComment()
        case ([.command], "]"): indent()
        case ([.command], "["): outdent()
        case ([.command, .shift], "d"), ([.command, .shift], "D"): duplicateLines()
        case ([.command], "l"): promptGoToLine()
        case ([.command, .option], "["): foldAtCaret(fold: true)
        case ([.command, .option], "]"): foldAtCaret(fold: false)
        case ([.option], String(UnicodeScalar(NSUpArrowFunctionKey)!)): moveLines(up: true)
        case ([.option], String(UnicodeScalar(NSDownArrowFunctionKey)!)): moveLines(up: false)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Fold (or unfold) the innermost block containing the caret.
    private func foldAtCaret(fold: Bool) {
        guard codeFolding else { return }
        let loc = selectedRange().location
        let containing = regions.filter { $0.hide.location <= loc && loc <= NSMaxRange($0.hide) }.sorted { $0.hide.length < $1.hide.length }
        if fold, let r = containing.first(where: { folded[$0.hide.location] == nil }) { toggleFold(r) }
        else if !fold, let r = regions.first(where: { folded[$0.hide.location] != nil && $0.lineStart == ns.lineRange(for: NSRange(location: loc, length: 0)).location }) { toggleFold(r) }
    }

    // MARK: Selection feedback

    /// Called when the selection moves: redraw the current-line band and outline the bracket pair at the caret.
    func selectionMoved() {
        needsDisplay = true
        guard let lm = layoutManager else { return }
        for r in matchedBrackets where r.upperBound <= ns.length { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
        matchedBrackets = []
        guard prefs.matchBrackets, selectedRange().length == 0 else { return }
        let loc = selectedRange().location
        for at in [loc - 1, loc] {
            guard let c = char(at: at), let match = bracketMatch(at: at, char: c) else { continue }
            for r in [NSRange(location: at, length: 1), NSRange(location: match, length: 1)] {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.3), forCharacterRange: r)
                matchedBrackets.append(r)
            }
            return
        }
    }

    private func bracketMatch(at index: Int, char c: Character) -> Int? {
        let open: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        let close: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        var depth = 0, i = index
        if let closer = open[c] {
            while i < ns.length { let x = char(at: i); if x == c { depth += 1 } else if x == closer { depth -= 1; if depth == 0 { return i } }; i += 1 }
        } else if let opener = close[c] {
            while i >= 0 { let x = char(at: i); if x == c { depth += 1 } else if x == opener { depth -= 1; if depth == 0 { return i } }; i -= 1 }
        }
        return nil
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let plain = CodeTheme.color(.plain)
        let origin = textContainerOrigin

        // Current line band.
        if prefs.highlightCurrentLine, selectedRange().length == 0, window?.firstResponder === self {
            let loc = min(selectedRange().location, ns.length)
            var band = NSRect.zero
            if ns.length == 0 || (loc == ns.length && char(at: loc - 1) == "\n") { band = lm.extraLineFragmentRect }
            else if lm.numberOfGlyphs > 0 { band = lm.lineFragmentRect(forGlyphAt: min(lm.glyphIndexForCharacter(at: loc), lm.numberOfGlyphs - 1), effectiveRange: nil) }
            if !band.isEmpty {
                plain.withAlphaComponent(0.06).setFill()
                NSRect(x: gutterWidth, y: band.minY + origin.y, width: max(bounds.width - gutterWidth, 0), height: band.height).fill()
            }
        }

        // Fold chips after the text of each folded block's first line.
        chips = []
        for start in folded.keys where start > 0 {
            guard start - 1 < ns.length, lm.numberOfGlyphs > 0 else { continue }
            let g = min(lm.glyphIndexForCharacter(at: start - 1), lm.numberOfGlyphs - 1)
            let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
            let rect = NSRect(x: used.maxX + origin.x + 8, y: used.minY + origin.y + 2, width: 26, height: max(used.height - 4, 8))
            guard rect.intersects(self.visibleRect) else { continue }
            plain.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let dots = "\u{22EF}" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: plain.withAlphaComponent(0.7)]
            let size = dots.size(withAttributes: attrs)
            dots.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            chips.append((rect, start))
        }

        // Gutter: line numbers and fold arrows.
        guard gutterWidth > 0 else { return }
        CodeTheme.gutter.setFill()
        NSRect(x: 0, y: rect.minY, width: gutterWidth, height: rect.height).fill()
        let numbersRight = gutterWidth - (codeFolding ? 16 : 0) - 4
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: max(prefs.fontSize - 3, 9), weight: .regular), .foregroundColor: plain.withAlphaComponent(0.5)]
        func drawNumber(_ number: Int, at lineRect: NSRect) {
            guard prefs.showLineNumbers else { return }
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: numbersRight - size.width, y: origin.y + lineRect.minY + (lineRect.height - size.height) / 2), withAttributes: attrs)
        }
        func drawArrow(foldedNow: Bool, at lineRect: NSRect) {
            let cx = gutterWidth - 8, cy = origin.y + lineRect.minY + lineRect.height / 2
            let path = NSBezierPath()
            if foldedNow { path.move(to: NSPoint(x: cx - 2, y: cy - 4)); path.line(to: NSPoint(x: cx + 3, y: cy)); path.line(to: NSPoint(x: cx - 2, y: cy + 4)) }
            else { path.move(to: NSPoint(x: cx - 4, y: cy - 2)); path.line(to: NSPoint(x: cx, y: cy + 3)); path.line(to: NSPoint(x: cx + 4, y: cy - 2)) }
            path.close()
            plain.withAlphaComponent(foldedNow ? 0.9 : 0.4).setFill()
            path.fill()
        }

        let area = NSRect(x: 0, y: max(0, rect.minY - origin.y), width: tc.size.width, height: rect.height)
        let glyphs = lm.glyphRange(forBoundingRect: area, in: tc)
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, glyphRange, _ in
            let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard chars.location == 0 || self.ns.character(at: chars.location - 1) == 10 else { return }
            drawNumber(self.lineIndex(of: chars.location) + 1, at: frag)
            if self.codeFolding, let r = self.regionAtLine[chars.location] { drawArrow(foldedNow: self.folded[r.hide.location] != nil, at: frag) }
        }
        // The empty line after a trailing newline.
        let extra = lm.extraLineFragmentRect
        if !extra.isEmpty, extra.intersects(area) { drawNumber(lineStarts.count, at: extra) }
    }
}

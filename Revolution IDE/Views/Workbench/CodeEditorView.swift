import SwiftUI
import Combine
import AppKit

/// A source/text file open for editing: real text editing (undo, find via Cmd+F, selection) via
/// `NSTextView`, plus this app's own syntax highlighting, code folding, a minimap and a status bar.
/// Everything visual and behavioural comes from `CodeEditorPrefs` (Settings > Code Editor).
struct CodeEditorView: View {
    @ObservedObject var box: CodeDocumentBox
    /// The file on disk, when this tab is one, enables Open in External Editor.
    var fileURL: URL? = nil
    @ObservedObject private var prefs = CodeEditorPrefs.shared
    @StateObject private var bridge = EditorBridge()
    @Environment(\.openSettings) private var openSettings
    @State private var caret = Caret()
    /// Markdown files open as a rendered preview; Edit switches to the source.
    @State private var showSource = false
    @State private var goToLineRequest = 0
    @State private var foldAllRequest = 0
    @State private var unfoldAllRequest = 0
    /// JSON/XML: the parser's complaint (nil when valid) and the outline beside the text.
    @State private var structureError: String?
    @State private var showOutline = false
    @State private var outline: [StructuredText.Node] = []

    struct Caret: Equatable { var line = 1, column = 1, selected = 0 }

    init(box: CodeDocumentBox, fileURL: URL? = nil) {
        self.box = box
        self.fileURL = fileURL
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if box.language == .markdown && !showSource {
                MarkdownView(text: box.text)
            } else {
                HStack(spacing: 0) {
                    CodeTextView(box: box, prefs: prefs, bridge: bridge, caret: $caret, goToLine: goToLineRequest, foldAll: foldAllRequest, unfoldAll: unfoldAllRequest)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if prefs.showMinimap {
                        Divider()
                        MinimapRepresentable(bridge: bridge).frame(width: 96)
                    }
                    if showOutline && StructuredText.supports(box.language) {
                        Divider()
                        List(outline, children: \.children) { node in
                            HStack(spacing: 6) {
                                Text(node.label).font(.caption.monospaced().bold())
                                Text(node.value).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .listStyle(.sidebar)
                        .frame(width: 260)
                        .overlay { if outline.isEmpty { Text(structureError == nil ? "Empty" : "Fix the error to see the outline.").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                if prefs.showStatusBar {
                    Divider()
                    statusBar
                }
            }
        }
        // Re-runs when the text changes or Outline is switched on, always off the main thread.
        .task(id: StructureKey(text: box.text, outline: showOutline)) {
            guard StructuredText.supports(box.language) else { return }
            try? await Task.sleep(for: .milliseconds(300)) // after typing pauses
            guard !Task.isCancelled else { return }
            let text = box.text, language = box.language, wantOutline = showOutline
            let (error, nodes) = await Task.detached { (StructuredText.validate(text, language), wantOutline ? StructuredText.outline(text, language) : []) }.value
            structureError = error
            if wantOutline { outline = nodes }
        }
        // Pick up edits made in an external editor, unless there are unsaved changes here.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard let fileURL, !box.isDirty, let disk = try? String(contentsOf: fileURL, encoding: .utf8), disk != box.text else { return }
            box.text = disk
        }
    }

    private struct StructureKey: Equatable { let text: String; let outline: Bool }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if box.language == .markdown {
                Picker("Mode", selection: $showSource) {
                    Text("Preview").tag(false)
                    Text("Edit").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            } else {
                Text(box.language.displayName).font(.caption.bold()).foregroundStyle(.secondary)
            }
            if StructuredText.supports(box.language) { structureControls }
            Spacer()
            // Cmd-Z stays with the text view's own typing undo; this adds the history list.
            AutoHistoryControls(initial: Data(box.text.utf8), changes: box.objectWillChange, shortcuts: false,
                                snapshot: { Data(box.text.utf8) },
                                restore: { box.text = String(decoding: $0, as: UTF8.self); box.isDirty = true })
            if let fileURL, let editor = ExternalEditorPrefs.codeEditorURL {
                Button("Open in \(editor.deletingPathExtension().lastPathComponent)") { ExternalEditorPrefs.openInCodeEditor(fileURL) }
                    .controlSize(.small).help("Edit this file in \(editor.deletingPathExtension().lastPathComponent); changes appear here when you switch back.")
            }
            Toggle("Wrap", isOn: $prefs.wordWrap).toggleStyle(.button).font(.caption)
            Stepper(value: $prefs.fontSize, in: 8...36) { Text("\(Int(prefs.fontSize))pt").font(.caption) }
                .frame(width: 90)
            Menu {
                Toggle("Minimap", isOn: $prefs.showMinimap)
                Toggle("Line Numbers", isOn: $prefs.showLineNumbers)
                Toggle("Code Folding", isOn: $prefs.codeFolding)
                Toggle("Status Bar", isOn: $prefs.showStatusBar)
                Divider()
                Button("Fold All") { foldAllRequest += 1 }.disabled(!prefs.codeFolding)
                Button("Unfold All") { unfoldAllRequest += 1 }.disabled(!prefs.codeFolding)
                Divider()
                Button("Go to Line...") { goToLineRequest += 1 }
                Button("Editor Settings...") { UserDefaults.standard.set("Code Editor", forKey: "settings.pane"); openSettings() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    @ViewBuilder private var structureControls: some View {
        if let structureError {
            Label("Invalid", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                .help(structureError)
        } else {
            Label("Valid \(box.language.displayName)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        }
        Button("Format") { reformat(StructuredText.pretty(box.text, box.language, indent: prefs.insertSpaces ? String(repeating: " ", count: prefs.tabWidth) : "\t")) }
            .controlSize(.small).disabled(structureError != nil)
            .help("Re-indent the whole file, one value or element per line. Key order is kept.")
        Button("Minify") { reformat(StructuredText.minify(box.text, box.language)) }
            .controlSize(.small).disabled(structureError != nil)
            .help("Strip the whitespace between values or elements.")
        Toggle("Outline", isOn: $showOutline).toggleStyle(.button).controlSize(.small)
            .help("Show the file's structure as a tree beside the text.")
    }

    private func reformat(_ text: String?) {
        guard let text, text != box.text else { return }
        box.text = text
        box.isDirty = true
    }

    /// Line and column, selection size and the language, like the bar at the bottom of Xcode or VS Code.
    private var statusBar: some View {
        HStack(spacing: 14) {
            Button { goToLineRequest += 1 } label: {
                Text("Ln \(caret.line), Col \(caret.column)" + (caret.selected > 0 ? " (\(caret.selected) selected)" : ""))
            }
            .buttonStyle(.plain).help("Go to Line (\u{2318}L)")
            Spacer()
            Text(prefs.insertSpaces ? "Spaces: \(prefs.tabWidth)" : "Tabs: \(prefs.tabWidth)")
            Text(box.language.displayName)
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(.bar)
    }
}

private struct CodeTextView: NSViewRepresentable {
    @ObservedObject var box: CodeDocumentBox
    @ObservedObject var prefs: CodeEditorPrefs
    let bridge: EditorBridge
    @Binding var caret: CodeEditorView.Caret
    var goToLine: Int
    var foldAll: Int
    var unfoldAll: Int

    func makeNSView(context: Context) -> NSScrollView {
        // An explicit TextKit 1 stack. The gutter, folding and minimap need the layout manager; asking a default
        // (TextKit 2) text view for it switches systems mid-draw and can leave the text blank.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        layoutManager.delegate = context.coordinator
        let textView = GutterTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        textView.isEditable = true
        textView.drawsBackground = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.language = box.language
        textView.delegate = context.coordinator
        textView.string = box.text

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        bridge.attach(textView: textView, scrollView: scrollView)
        context.coordinator.applyStyle(textView, scrollView: scrollView, force: true)
        textView.codeFolding = CodeEditorPrefs.shared.codeFolding
        textView.textChanged()
        context.coordinator.highlight(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? GutterTextView else { return }
        let c = context.coordinator
        if textView.string != box.text {
            let selected = textView.selectedRanges
            textView.string = box.text
            textView.textChanged()
            c.highlight(textView)
            textView.selectedRanges = selected
        }
        c.caret = $caret
        c.applyStyle(textView, scrollView: nsView, force: false)
        if c.lastGoToLine != goToLine { c.lastGoToLine = goToLine; if goToLine > 0 { textView.promptGoToLine() } }
        if c.lastFoldAll != foldAll { c.lastFoldAll = foldAll; textView.foldAll() }
        if c.lastUnfoldAll != unfoldAll { c.lastUnfoldAll = unfoldAll; textView.unfoldAll() }
    }

    /// Take whatever space the parent offers. Without this SwiftUI sizes the scroll view from its document
    /// (a text container is millions of points tall), which pushes the tab strip and header out of view.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    func makeCoordinator() -> Coordinator { let c = Coordinator(box: box, bridge: bridge); c.caret = $caret; return c }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var box: CodeDocumentBox
        let bridge: EditorBridge
        var lastGoToLine = 0, lastFoldAll = 0, lastUnfoldAll = 0
        var caret: Binding<CodeEditorView.Caret>?
        private var styleKey = ""
        private var pendingHighlight: DispatchWorkItem?
        private var pendingCompletion: DispatchWorkItem?
        init(box: CodeDocumentBox, bridge: EditorBridge) { self.box = box; self.bridge = bridge }

        /// Applies fonts, colours, spacing and gutter width from the preferences, re-highlighting when they changed.
        func applyStyle(_ textView: GutterTextView, scrollView: NSScrollView, force: Bool) {
            let p = CodeEditorPrefs.shared
            let key = "\(p.fontName)|\(p.fontSize)|\(p.lineSpacing)|\(p.tabWidth)|\(p.theme)|\(p.overrides.sorted { $0.key < $1.key })"
            textView.backgroundColor = CodeTheme.backgroundOrSystem
            textView.insertionPointColor = CodeTheme.color(.plain)
            textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
            scrollView.backgroundColor = CodeTheme.backgroundOrSystem
            textView.gutterWidth = (p.showLineNumbers ? 40 : 0) + (p.codeFolding ? 16 : 0)
            textView.isHorizontallyResizable = !p.wordWrap
            textView.textContainer?.widthTracksTextView = p.wordWrap
            if p.wordWrap { textView.autoresizingMask = [.width] }
            else { textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude) }
            if textView.codeFolding != p.codeFolding { textView.codeFolding = p.codeFolding; textView.textChanged() }
            textView.needsDisplay = true
            if force || key != styleKey {
                styleKey = key
                // Setting these restyles the whole text, so only when something changed, then re-highlight.
                textView.textColor = CodeTheme.color(.plain)
                textView.font = p.font
                highlight(textView)
            }
        }

        // MARK: Folding (hide the glyphs of every folded range)

        func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
            guard let textView = layoutManager.firstTextView as? GutterTextView, !textView.hiddenRanges.isEmpty else { return 0 }
            var changed = false
            var out = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
            for i in 0..<glyphRange.length where textView.hiddenRanges.contains(where: { NSLocationInRange(charIndexes[i], $0) }) {
                out[i] = .null; changed = true
            }
            guard changed else { return 0 }
            out.withUnsafeBufferPointer { layoutManager.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange) }
            return glyphRange.length
        }

        /// Keeps folds attached to their text as it is edited; an edit touching a fold opens it.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            (textView as? GutterTextView)?.willEdit(range, replacementLength: (replacementString as NSString?)?.length ?? 0)
            return true
        }

        // MARK: Completion

        /// The suggestions NSTextView's completion popup shows for the word being typed.
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange)
            index?.pointee = 0
            return CodeCompletion.candidates(prefix: partial, language: box.language, text: textView.string)
        }

        /// Pops the suggestions up as you type an identifier (two or more characters in).
        private func scheduleCompletion(_ textView: NSTextView) {
            pendingCompletion?.cancel()
            guard CodeEditorPrefs.shared.autoComplete,
                  let event = NSApp.currentEvent, event.type == .keyDown, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
                  let scalar = event.characters?.unicodeScalars.first, event.characters?.unicodeScalars.count == 1,
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" else { return }
            let work = DispatchWorkItem { [weak textView] in
                guard let textView, textView.window?.firstResponder === textView else { return }
                let range = textView.rangeForUserCompletion
                guard range.location != NSNotFound, range.length >= 2 else { return }
                textView.complete(nil)
            }
            pendingCompletion = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }

        // MARK: Selection and changes

        /// Reports the caret position and outlines the bracket next to it.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? GutterTextView else { return }
            textView.selectionMoved()
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            var line = 1, lineStart = 0
            var i = 0
            while i < min(sel.location, ns.length) { if ns.character(at: i) == 10 { line += 1; lineStart = i + 1 }; i += 1 }
            let value = CodeEditorView.Caret(line: line, column: sel.location - lineStart + 1, selected: sel.length)
            if caret?.wrappedValue != value { DispatchQueue.main.async { [weak self] in self?.caret?.wrappedValue = value } }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? GutterTextView else { return }
            box.text = textView.string
            box.isDirty = true
            textView.textChanged()
            scheduleCompletion(textView)
            pendingHighlight?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlight(textView)
            }
            pendingHighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let p = CodeEditorPrefs.shared
            let font = p.font
            let selected = textView.selectedRanges
            let attributed = NSMutableAttributedString(attributedString: SyntaxHighlighter.highlight(textView.string, language: box.language, font: font))
            let style = NSMutableParagraphStyle()
            style.defaultTabInterval = (String(repeating: " ", count: p.tabWidth) as NSString).size(withAttributes: [.font: font]).width
            style.tabStops = []
            style.lineSpacing = p.lineSpacing
            attributed.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attributed.length))
            textView.defaultParagraphStyle = style
            textView.typingAttributes = [.font: font, .foregroundColor: CodeTheme.color(.plain), .paragraphStyle: style]
            storage.beginEditing()
            storage.setAttributedString(attributed)
            storage.endEditing()
            textView.selectedRanges = selected
            bridge.contentChanged()
        }
    }
}

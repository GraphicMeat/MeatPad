import AppKit
import MeatPadKit
import STTextView
import LanguageServerProtocol

/// Owns diagnostics rendering (squiggle underlines + gutter icons) for a single editor
/// instance. Sibling of `FoldController`: `attach(to:)` on `makeNSView`, driven from
/// `Coordinator.applyHighlight` so its output always lands AFTER the syntax-highlight pass
/// (see that method's doc comment) — `applyHighlight`'s `setAttributes` does a full-range
/// reset that would otherwise wipe these underline attributes on every edit.
///
/// Fed pre-filtered diagnostics for exactly this editor's URI. `ProjectViewModel` is the
/// single reader of `LSPProjectManager.onPublishDiagnostics` — `AsyncStream` delivers each
/// element to exactly one consumer, so two editors reading the shared server handle's event
/// stream directly would race for each notification instead of both seeing it — and
/// republishes per-URI via `@Published diagnosticsByURI`, which flows down to `CodeEditor`
/// like any other SwiftUI-driven input (`reveal`, `banners`, …). This controller never talks
/// to `LSPProjectManager` itself.
@MainActor
final class LSPController {
    private weak var textView: STTextView?
    private var diagnostics: [Diagnostic] = []
    /// Gutter lines currently holding a diagnostic marker, so a stale one can be cleared
    /// before the next rebuild (`STGutterView` only removes markers by line number) — same
    /// bookkeeping shape as `FoldController.chevronLines`.
    private var markerLines: Set<Int> = []

    /// Debounce for `mouseMoved`-driven hover requests; cancelled on move/scroll/type/exit —
    /// see `mouseMoved(_:handle:fileURL:)` and `dismissHover()`.
    private var hoverDebounceTask: Task<Void, Never>?
    /// The character index hover is currently debouncing towards, or already showing for.
    /// `nil` whenever nothing is pending or displayed.
    private var trackedCharIndex: Int?
    private var hoverPanel: HoverPanel?

    func attach(to textView: STTextView) {
        self.textView = textView
    }

    /// Called from `updateNSView`/`makeNSView` with the latest diagnostics for this editor's
    /// file. No-op if unchanged (every unrelated SwiftUI update re-passes the same array).
    /// Renders immediately when changed — a fresh publish shouldn't wait for the next edit's
    /// highlight debounce to appear.
    func setDiagnostics(_ diagnostics: [Diagnostic]) {
        guard self.diagnostics != diagnostics else { return }
        self.diagnostics = diagnostics
        render()
    }

    /// Clears this controller's own gutter markers before `FoldController.refresh()` runs
    /// its own rebuild. Without this, a diagnostic marker left over from the previous pass
    /// occupies its line and silently blocks `STGutterView.addMarker` (one marker per line)
    /// from placing that line's fold chevron — even on a line whose diagnostic has since
    /// cleared. Called from `Coordinator.applyHighlight`, before `foldController.refresh()`.
    func clearGutterMarkersForFoldPass() {
        guard let gutter = textView?.gutterView else { return }
        for line in markerLines { gutter.removeMarker(lineNumber: line) }
        markerLines.removeAll()
    }

    /// Re-applies underline attributes + gutter markers for the current `diagnostics` over
    /// the live buffer. Called unconditionally at the end of `Coordinator.applyHighlight`
    /// (after both the syntax-highlight reset and `FoldController`'s chevron rebuild) and
    /// directly from `setDiagnostics` for a prompt first paint. Idempotent — safe to call
    /// redundantly.
    ///
    /// Ranges go through `LSPPositionBridge`, which already returns `nil` for a position
    /// past the current text's end — stale diagnostics computed against an older buffer
    /// version are silently dropped rather than crashing or corrupting the range.
    func render() {
        guard let textView else { return }
        let text = textView.text ?? ""
        let length = (text as NSString).length
        let full = NSRange(location: 0, length: length)

        // Unconditional self-clear before repainting: this runs both right after
        // `applyHighlight`'s own full-range `setAttributes` reset (which already wiped these)
        // AND standalone from `setDiagnostics` when a fresh publish arrives mid-debounce with
        // no edit in between — in that second case nothing else would clear a since-fixed
        // diagnostic's stale squiggle.
        textView.removeAttribute(.underlineStyle, range: full)
        textView.removeAttribute(.underlineColor, range: full)

        let newlineOffsets = text.utf16.enumerated().compactMap { $0.element == 0x0A ? $0.offset : nil }
        var severityByLine: [Int: DiagnosticSeverity] = [:]
        for diagnostic in diagnostics {
            guard let range = LSPPositionBridge.nsRange(of: diagnostic.range, in: text),
                  range.location + range.length <= length else { continue }
            let severity = diagnostic.severity ?? .error
            if range.length > 0 {
                let style: NSUnderlineStyle = [.thick, .patternDot]
                textView.addAttributes([
                    .underlineStyle: style.rawValue,
                    .underlineColor: Self.color(for: severity),
                ], range: range)
            }
            let line = Self.lineNumber(of: range.location, newlineOffsets: newlineOffsets)
            // Worse severity (lower raw value: .error == 1) wins the line's single marker.
            if severity.rawValue < (severityByLine[line]?.rawValue ?? .max) {
                severityByLine[line] = severity
            }
        }

        guard let gutter = textView.gutterView else { return }
        for line in markerLines where severityByLine[line] == nil { gutter.removeMarker(lineNumber: line) }
        for (line, severity) in severityByLine {
            // ponytail ceiling: STGutterView is one-marker-per-line — a diagnostic on a fold
            // head's line always evicts that line's chevron for as long as the diagnostic
            // stands. Cmd+Opt+Left/Right still folds/unfolds by caret position regardless
            // (the chevron click was already best-effort — see FoldController.ChevronMarkerView).
            gutter.removeMarker(lineNumber: line)
            gutter.addMarker(STGutterMarker(lineNumber: line, view: DiagnosticMarkerView(severity: severity)))
        }
        markerLines = Set(severityByLine.keys)
    }

    // MARK: - Hover (0.7 LSP plan Task 3)

    /// Called from `SnippetTextView.onHoverMouseMoved` (only wired up when a project has an
    /// `lspManager` — see that closure's doc comment) on every `mouseMoved`. `handle`/`fileURL`
    /// are re-evaluated by the caller on each call (server may still be starting), not cached
    /// here — a `nil` handle degrades silently: the debounce still tracks the character index
    /// (so a later-arriving server doesn't need the mouse to move again), but never fires a
    /// request.
    func mouseMoved(_ event: NSEvent, handle: LSPServerHandle?, fileURL: URL?) {
        guard let textView, let window = textView.window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let charIndex = textView.characterIndex(for: screenPoint)
        guard charIndex != NSNotFound else {
            dismissHover()
            return
        }
        // Resting at the same character (or drifting a pixel within the currently-shown/
        // currently-debouncing one) is a no-op — this is the "~350ms rest at same character
        // index" debounce the plan calls for, not a per-pixel one.
        guard charIndex != trackedCharIndex else { return }
        dismissHover()
        trackedCharIndex = charIndex
        guard let handle, let fileURL else { return }
        hoverDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.requestHover(charIndex: charIndex, handle: handle, fileURL: fileURL)
        }
    }

    /// Cancels any in-flight debounce/request and hides the panel if one is showing. Called on
    /// every dismiss trigger from the plan (`mouseExited`, scroll, any keystroke, editor
    /// resign) — see call sites in `CodeEditor.Coordinator` — as well as whenever `mouseMoved`
    /// itself moves off the tracked character.
    func dismissHover() {
        hoverDebounceTask?.cancel()
        hoverDebounceTask = nil
        trackedCharIndex = nil
        if let hoverPanel {
            hoverPanel.parent?.removeChildWindow(hoverPanel)
            hoverPanel.orderOut(nil)
        }
        hoverPanel = nil
    }

    /// Fires after the debounce elapses. `text` is captured fresh here (not back in
    /// `mouseMoved`) — the "current buffer generation" the request goes out against — and
    /// re-checked against `textView.text` after the response returns: an edit anywhere during
    /// the round trip (wait + request) invalidates the response, so a hover for stale content
    /// is silently dropped rather than shown. `trackedCharIndex == charIndex` is a second,
    /// cheaper guard for the common case (mouse already moved elsewhere, `dismissHover` already
    /// cancelled this Task — this just also covers the rare non-cancellation race).
    private func requestHover(charIndex: Int, handle: LSPServerHandle, fileURL: URL) async {
        guard let textView, let text = textView.text,
              let position = LSPPositionBridge.position(of: charIndex, in: text) else { return }
        let params = TextDocumentPositionParams(uri: fileURL.absoluteString, position: position)
        guard let hover = (try? await handle.hover(params: params)) ?? nil else { return }
        guard !Task.isCancelled, trackedCharIndex == charIndex, textView.text == text else { return }
        presentHover(hover, anchorCharIndex: charIndex, in: text)
    }

    /// Renders `hover` in a borderless, non-activating `NSPanel` anchored just below its
    /// token — `firstRect(forCharacterRange:actualRange:)` (STTextView's `NSTextInputClient`
    /// conformance) gives that token's screen rect directly, the same API IME candidate windows
    /// anchor against. A panel (not `NSPopover`) is the "doesn't steal focus" choice from the
    /// plan: `orderFront` never makes it key, so showing it can't itself trigger
    /// `resignFirstResponder` on the editor (which would immediately dismiss it again).
    ///
    /// ponytail: dismissed unconditionally on `mouseExited` from the text view — doesn't check
    /// whether the cursor actually landed on the popover itself. Fine for a read-only tooltip;
    /// add popover-region tracking if hover content ever needs to be selectable/copyable.
    private func presentHover(_ hover: Hover, anchorCharIndex: Int, in text: String) {
        guard let textView, let window = textView.window else { return }
        let plainText = Self.plainText(from: hover.contents)
        guard !plainText.isEmpty else { return }

        let anchorRange: NSRange
        if let range = hover.range, let nsRange = LSPPositionBridge.nsRange(of: range, in: text) {
            anchorRange = nsRange
        } else {
            anchorRange = NSRange(location: anchorCharIndex, length: 0)
        }
        let screenRect = textView.firstRect(forCharacterRange: anchorRange, actualRange: nil)

        let panel = HoverPanel(plainText: plainText)
        panel.setFrameOrigin(NSPoint(x: screenRect.minX, y: screenRect.minY - panel.frame.height - 4))
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        hoverPanel = panel
    }

    /// `MarkupContent`/`MarkedString` markdown -> plain text, first cut per the plan ("STRIP to
    /// plain text first cut... else plain"). Regex-based, not a real markdown parser — good
    /// enough to de-noise fences/emphasis/links/headers for a tooltip; a rendered/monospaced
    /// upgrade is future work, not required here.
    private static func plainText(from contents: ThreeTypeOption<MarkedString, [MarkedString], MarkupContent>) -> String {
        let raw: String
        switch contents {
        case .optionA(let marked):
            raw = marked.value
        case .optionB(let markedList):
            raw = markedList.map(\.value).joined(separator: "\n\n")
        case .optionC(let markup):
            raw = markup.kind == .markdown ? stripMarkdown(markup.value) : markup.value
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripMarkdown(_ markdown: String) -> String {
        var s = markdown
        s = s.replacingOccurrences(of: #"```[a-zA-Z0-9_+\-]*\n?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[`*_]"#, with: "", options: .regularExpression)
        return s
    }

    private static func color(for severity: DiagnosticSeverity) -> NSColor {
        switch severity {
        case .error: return .systemRed
        case .warning: return .systemYellow
        case .information, .hint: return .systemGray
        }
    }

    /// 1-based document line number of a UTF-16 offset — same newline-count/binary-search
    /// shape as `FoldController.rebuildChevrons`.
    private static func lineNumber(of offset: Int, newlineOffsets: [Int]) -> Int {
        newlineOffsets.partitioningIndex { $0 >= offset } + 1
    }
}

/// Gutter diagnostic marker: a small SF Symbol tinted by severity. `STGutterView` owns the
/// frame (see `FoldController.ChevronMarkerView`'s equivalent note); this just draws
/// centered within whatever frame it's handed.
private final class DiagnosticMarkerView: NSView {
    private let severity: DiagnosticSeverity

    init(severity: DiagnosticSeverity) {
        self.severity = severity
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let (symbolName, color): (String, NSColor)
        switch severity {
        case .error: (symbolName, color) = ("xmark.octagon.fill", .systemRed)
        case .warning: (symbolName, color) = ("exclamationmark.triangle.fill", .systemYellow)
        case .information, .hint: (symbolName, color) = ("info.circle.fill", .systemGray)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = NSSize(width: 12, height: 12)
        image.draw(in: NSRect(x: 1, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }
}

/// Borderless, non-key floating panel showing plain-text hover documentation. See
/// `LSPController.presentHover`'s doc comment for why a panel (not `NSPopover`) is used.
private final class HoverPanel: NSPanel {
    init(plainText: String) {
        let maxWidth: CGFloat = 420
        let padding: CGFloat = 8
        let attributed = NSAttributedString(string: plainText, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
        let textSize = attributed.boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let contentSize = NSSize(width: ceil(textSize.width) + padding * 2, height: ceil(textSize.height) + padding * 2)

        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true

        let textField = NSTextField(frame: NSRect(x: padding, y: padding, width: textSize.width, height: textSize.height))
        textField.attributedStringValue = attributed
        textField.isEditable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.truncatesLastVisibleLine = false

        background.addSubview(textField)
        contentView = background
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private extension Array where Element: Comparable {
    /// First index whose element satisfies `predicate` on a partitioned (sorted) array.
    /// Duplicated from `FoldController`'s private helper of the same name/shape — that one is
    /// file-private, and this is the only other call site, not worth promoting to shared.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

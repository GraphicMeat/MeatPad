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

import AppKit
import MeatPadKit
import STTextView

/// Owns code-folding state for a single editor instance.
///
/// SPIKE OUTCOME (full write-up: `.superpowers/sdd/p4-task-4-report.md`).
/// TextKit 2 on macOS 14/15 ships no public API to collapse or hide a text range, and
/// STTextView 2.3.10 is its *own* `NSTextLayoutManagerDelegate` — the one hook that could
/// return a zero-height layout fragment (`textLayoutManager(_:textLayoutFragmentFor:in:)`)
/// lives in a package extension, which Swift forbids a `SnippetTextView` subclass from
/// overriding. Reassigning the delegate to a proxy is fragile (STTextView re-asserts
/// `delegate = self` on every layout-manager reconfigure) and, worse, a hand-sized fragment
/// desyncs the layout manager's own geometry accounting (content size, hit-testing, selection
/// rects all read the real typeset height), so it does not reliably collapse. The only paths
/// to a *real* collapse are (a) mutating the buffer — which breaks find/replace + project
/// search, a binding acceptance criterion — or (b) forking the vendored STTextView. Both are
/// out of scope.
///
/// So this controller ships the honest fallback the brief authorizes: `FoldScanner`-driven
/// fold-head chevrons in the gutter + a per-instance fold set toggled by keyboard/click. The
/// buffer is never touched, so search/replace always see full text and there is nothing to
/// persist or restore. The collapse itself is a documented no-op.
///
/// ponytail: real collapse needs STTextView to expose the layout-fragment delegate as an
/// overridable seam (or TextKit 2 to ship a public fold API). When that lands, do the collapse
/// in `applyCollapse(head:folded:)` — everything else here already tracks the right state.
@MainActor
final class FoldController {
    private weak var textView: STTextView?
    private(set) var regions: [FoldRegion] = []
    /// Folded heads keyed by head-line start UTF-16 offset. Per editor instance, never
    /// persisted, so a reopened note starts fully unfolded and layout is trivially "restored".
    private var foldedHeads: Set<Int> = []
    /// Head lines we've placed a gutter chevron on, so we can clear them before a rebuild
    /// (STGutterView only removes markers by line number).
    private var chevronLines: Set<Int> = []

    func attach(to textView: STTextView) {
        self.textView = textView
    }

    /// Recompute regions from the current buffer and rebuild the gutter chevrons. Called on the
    /// editor's existing 150ms highlight debounce cadence (see `Coordinator.applyHighlight`).
    func refresh() {
        guard let textView else { return }
        let text = textView.text ?? ""
        regions = FoldScanner.regions(in: text)
        // Drop folded heads whose region an edit removed; keep the rest keyed by head offset.
        foldedHeads.formIntersection(regions.map(\.headLineRange.lowerBound))
        rebuildChevrons(text: text)
    }

    // MARK: Toggle (keyboard + click)

    /// Fold / unfold the innermost region owning the caret. Returns true if a region matched
    /// (so the key press is consumed).
    @discardableResult
    func foldAtCaret() -> Bool { toggle(head: innermostHead(containing: caretOffset()), folded: true) }
    @discardableResult
    func unfoldAtCaret() -> Bool { toggle(head: innermostHead(containing: caretOffset()), folded: false) }

    private func caretOffset() -> Int { textView?.textSelection.location ?? 0 }

    @discardableResult
    private func toggle(head: Int?, folded: Bool) -> Bool {
        guard let head else { return false }
        if folded { foldedHeads.insert(head) } else { foldedHeads.remove(head) }
        applyCollapse(head: head, folded: folded)
        if let textView { rebuildChevrons(text: textView.text ?? "") }
        return true
    }

    /// Innermost = the deepest-nested region whose head line or body contains `offset`.
    private func innermostHead(containing offset: Int) -> Int? {
        regions
            .filter { $0.headLineRange.contains(offset) || $0.bodyRange.contains(offset) || $0.headLineRange.upperBound == offset }
            .max(by: { $0.level < $1.level })?
            .headLineRange.lowerBound
    }

    /// ponytail: no-op until STTextView exposes a fragment-collapse seam (see type doc). The
    /// fold set and chevron glyph already reflect the intended state; only the visual collapse
    /// is missing.
    private func applyCollapse(head: Int, folded: Bool) {}

    // MARK: Gutter chevrons

    /// Rebuild fold-head chevrons as STGutterView markers. Markers ride STTextView's own gutter
    /// layout + scroll tracking (`layoutGutter` re-positions them on every viewport pass), so we
    /// only rebuild on region/fold-state change, not on scroll.
    private func rebuildChevrons(text: String) {
        guard let gutter = textView?.gutterView else { return }
        for line in chevronLines { gutter.removeMarker(lineNumber: line) }
        chevronLines.removeAll()

        let newlineOffsets = text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset : nil }
        for region in regions {
            let head = region.headLineRange.lowerBound
            // 1-based document line number = newlines strictly before the head + 1.
            let lineNumber = newlineOffsets.partitioningIndex { $0 >= head } + 1
            let view = ChevronMarkerView(folded: foldedHeads.contains(head)) { [weak self] in
                self?.toggle(head: head, folded: !(self?.foldedHeads.contains(head) ?? false))
            }
            gutter.addMarker(STGutterMarker(lineNumber: lineNumber, view: view))
            chevronLines.insert(lineNumber)
        }
    }
}

/// A gutter fold chevron. `⌄` when the region is expanded, `›` when folded. STGutterView owns
/// the frame (it forces width/height/origin in `layoutMarkers`), so this just draws the glyph
/// left-aligned within whatever frame it's handed and toggles on click.
///
/// ponytail: click is best-effort — STGutterView stacks the marker layer *below* the
/// line-number cells, so a click landing on a number cell is eaten by that cell. The
/// Cmd+Opt+Left / Cmd+Opt+Right keys are the reliable toggle and the primary interaction.
private final class ChevronMarkerView: NSView {
    private let folded: Bool
    private let onClick: () -> Void

    init(folded: Bool, onClick: @escaping () -> Void) {
        self.folded = folded
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let glyph = folded ? "\u{203A}" : "\u{2304}" // › : ⌄
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = glyph.size(withAttributes: attrs)
        glyph.draw(at: NSPoint(x: 1, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

private extension Array where Element: Comparable {
    /// First index whose element satisfies `predicate` on a partitioned (sorted) array; the
    /// count of elements before it. Stdlib gains this as `partitioningIndex` in newer toolchains,
    /// but it isn't available here, so this is the standard binary-search implementation.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = low + (high - low) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

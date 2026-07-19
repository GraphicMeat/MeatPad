import AppKit
import MeatPadKit
import STTextView

/// Owns code-folding state for a single editor instance.
///
/// The vendored STTextView (fork: `GraphicMeat/STTextView`, branch `meatpad`) exposes real
/// collapse as `foldedRanges: [NSTextRange]` (body ranges; the fork keeps a region's head
/// paragraph visible and hides a body paragraph once it's fully inside a folded range) plus
/// `isRangeFolded(_:)`. `FoldScanner` still does the indentation-based region scan
/// language-agnostically; this controller's job is turning "which heads are folded" into the
/// `NSTextRange`s the fork wants, and re-deriving that mapping fresh after every edit. Folds
/// don't track their content — a region an edit shifts or removes is conservatively
/// auto-unfolded (dropped from `foldedHeads`) rather than re-mapped, so an edit can never end up
/// silently hidden behind a stale fold.
///
/// `NSTextRange` is a dumb pair of locations — it doesn't track the buffer, so a range handed
/// to the fork before an edit points at the wrong text after one. The fork does not (and
/// shouldn't) know how to re-derive folds from a language-agnostic indent scan, so this
/// controller re-derives every folded range from the just-rescanned `FoldRegion`s on every
/// `refresh()` rather than ever reusing a previously-converted `NSTextRange`. See `refresh()`.
///
/// `refresh()` rides the same ≤150ms debounce as syntax highlighting (see
/// `Coordinator.applyHighlight` in CodeEditor.swift), so a folded range whose text an edit just
/// invalidated can stay applied to `textView.foldedRanges` for up to that window before the
/// auto-unfold above runs — a transient, self-correcting staleness, not a persistent one.
@MainActor
final class FoldController {
    private weak var textView: STTextView?
    private(set) var regions: [FoldRegion] = []
    /// Folded heads keyed by head-line start UTF-16 offset. Per editor instance, never
    /// persisted, so a reopened note starts fully unfolded and layout is trivially "restored".
    private var foldedHeads: Set<Int> = []
    /// The `NSTextRange` currently applied to `textView.foldedRanges` for each folded head,
    /// keyed the same way. Rebuilt wholesale on every `refresh()`; `applyCollapse` patches it
    /// incrementally between refreshes since folding never edits the buffer.
    private var collapsedRanges: [Int: NSTextRange] = [:]
    /// Head lines we've placed a gutter chevron on, so we can clear them before a rebuild
    /// (STGutterView only removes markers by line number).
    private var chevronLines: Set<Int> = []
    /// UTF-16 span touched by the buffer edit(s) since the last `refresh()` (see
    /// `Coordinator.textView(_:didChangeTextIn:replacementString:)`). Multiple edits racing
    /// ahead of the 150ms debounce widen this to their bounding span.
    private var pendingEditRange: Range<Int>?

    func attach(to textView: STTextView) {
        self.textView = textView
    }

    /// Called from the editor's edit-change delegate taps for every buffer mutation, so
    /// `refresh()` can tell whether an edit landed inside a currently-folded (and therefore
    /// hidden) region and needs to auto-unfold it.
    func noteEdit(_ range: Range<Int>) {
        guard let existing = pendingEditRange else { pendingEditRange = range; return }
        pendingEditRange = min(existing.lowerBound, range.lowerBound)..<max(existing.upperBound, range.upperBound)
    }

    /// Recompute regions from the current buffer, auto-unfold anything an edit invalidated, and
    /// rebuild the gutter chevrons. Called on the editor's existing 150ms highlight debounce
    /// cadence (see `Coordinator.applyHighlight`).
    func refresh() {
        guard let textView else { return }
        let text = textView.text ?? ""
        let editedRange = pendingEditRange
        pendingEditRange = nil

        regions = FoldScanner.regions(in: text)
        // Drop folded heads whose region an edit removed entirely, then drop any survivor
        // whose (still-existing) body was itself touched by the edit — its hidden content just
        // changed, so silently leaving it collapsed would hide the edit from the user.
        foldedHeads.formIntersection(regions.map(\.headLineRange.lowerBound))
        if let editedRange {
            for region in regions
            where foldedHeads.contains(region.headLineRange.lowerBound) && region.bodyRange.overlaps(editedRange) {
                foldedHeads.remove(region.headLineRange.lowerBound)
            }
        }

        applyFoldedHeads(text: text)
    }

    // MARK: Fold All / Unfold All

    /// Fold every top-level region (`level == 0` — regions already nested inside another
    /// folded region collapse along with it, same as a manual fold of an outer head).
    func foldAll() {
        guard let textView else { return }
        foldedHeads.formUnion(regions.filter { $0.level == 0 }.map(\.headLineRange.lowerBound))
        applyFoldedHeads(text: textView.text ?? "")
    }

    /// Clear every folded head and refresh the gutter chevrons.
    func unfoldAll() {
        guard let textView else { return }
        foldedHeads.removeAll()
        applyFoldedHeads(text: textView.text ?? "")
    }

    /// Re-derive every collapsed `NSTextRange` from the current `regions` + `foldedHeads`,
    /// apply to `textView.foldedRanges`, and rebuild the gutter chevrons. The single path
    /// `refresh()`, `foldAll()`, and `unfoldAll()` all recompute through — offsets always go
    /// stale across edits, so nothing here ever trusts a previously-converted range.
    private func applyFoldedHeads(text: String) {
        guard let textView else { return }
        let contentManager = textView.textContentManager
        collapsedRanges = Dictionary(uniqueKeysWithValues: regions.compactMap { region -> (Int, NSTextRange)? in
            let head = region.headLineRange.lowerBound
            guard foldedHeads.contains(head), let range = Self.textRange(region.bodyRange, in: contentManager) else { return nil }
            return (head, range)
        })
        textView.foldedRanges = Array(collapsedRanges.values)
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

    /// Fast path for keyboard/click toggles, which never touch the buffer so `regions` is
    /// still accurate: patch `collapsedRanges`/`textView.foldedRanges` for just this one head
    /// instead of waiting for the next debounced `refresh()`.
    private func applyCollapse(head: Int, folded: Bool) {
        guard let textView else { return }
        if folded {
            guard let region = regions.first(where: { $0.headLineRange.lowerBound == head }),
                  let range = Self.textRange(region.bodyRange, in: textView.textContentManager) else { return }
            collapsedRanges[head] = range
        } else {
            collapsedRanges.removeValue(forKey: head)
        }
        textView.foldedRanges = Array(collapsedRanges.values)
    }

    /// UTF-16 offset range → `NSTextRange`, same walk `SnippetController`/`MultiCaretController`
    /// use for their own offset conversions.
    private static func textRange(_ range: Range<Int>, in contentManager: NSTextContentManager) -> NSTextRange? {
        guard let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.lowerBound),
              let end = contentManager.location(start, offsetBy: range.count) else { return nil }
        return NSTextRange(location: start, end: end)
    }

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

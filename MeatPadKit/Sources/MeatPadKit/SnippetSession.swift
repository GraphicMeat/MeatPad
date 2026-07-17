import Foundation

/// An edit the host must apply to the buffer to keep a mirror in sync with its
/// primary. Ranges are absolute UTF-16 document offsets, already adjusted for
/// the triggering primary edit; apply them right-to-left (this array is sorted
/// descending by `range.lowerBound`) and do NOT feed them back into
/// `bufferDidChange` — they are pre-accounted for.
public struct MirrorEdit: Equatable, Sendable {
    public let range: Range<Int>
    public let replacement: String

    public init(range: Range<Int>, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Live snippet expansion with tab-stop navigation and mirror tracking.
///
/// The host inserts `insertText` at `insertionOffset`, then feeds every buffer
/// edit (`bufferDidChange`) and caret move (`caretMoved`) back while the session
/// is active. All range bookkeeping is UTF-16 offsets (matches NSRange/STTextView).
@MainActor
public final class SnippetSession {

    /// One occurrence of a tab stop in the rendered body. `start`/`length` are
    /// absolute UTF-16 offsets and shift as the buffer is edited. Nesting is
    /// tracked geometrically (a parent's range contains its children's).
    private struct Stop {
        let index: Int
        var start: Int
        var length: Int
        let isPrimary: Bool
        var text: String
        var end: Int { start + length }
    }

    private let insertionOffset: Int
    private var instances: [Stop]
    private let stopOrder: [Int]      // distinct indices in visit order: 1,2,…,0
    private var currentPos: Int       // index into stopOrder
    private var spanLength: Int       // UTF-16 length of the whole snippet region

    public let insertText: String
    public private(set) var isActive: Bool

    public init(snippet: ParsedSnippet, insertionOffset: Int) {
        self.insertionOffset = insertionOffset

        var out = ""
        var stops: [Stop] = []
        var primaryText: [Int: String] = [:]
        Self.render(snippet.nodes, base: insertionOffset, out: &out, stops: &stops, primaryText: &primaryText)

        self.insertText = out
        self.instances = stops
        self.spanLength = out.utf16.count

        let indices = Set(stops.map(\.index))
        var order = indices.filter { $0 != 0 }.sorted()
        if indices.contains(0) { order.append(0) }
        self.stopOrder = order

        self.currentPos = 0
        self.isActive = !order.isEmpty
    }

    // MARK: - Rendering

    private static func render(
        _ nodes: [SnippetNode], base: Int,
        out: inout String, stops: inout [Stop], primaryText: inout [Int: String]
    ) {
        for node in nodes {
            switch node {
            case .text(let s):
                out += s
            case .tabStop(let index, let placeholder):
                let startRel = out.utf16.count
                let isPrimary = primaryText[index] == nil
                let slot = stops.count
                stops.append(Stop(index: index, start: base + startRel, length: 0, isPrimary: isPrimary, text: ""))
                if isPrimary {
                    render(placeholder, base: base, out: &out, stops: &stops, primaryText: &primaryText)
                } else {
                    out += primaryText[index] ?? ""   // mirror renders the primary's resolved text
                }
                let endRel = out.utf16.count
                let content = String(out[Self.utf16Range(startRel, endRel, in: out)])
                stops[slot].length = endRel - startRel
                stops[slot].text = content
                if isPrimary { primaryText[index] = content }
            }
        }
    }

    // MARK: - Queries

    /// Absolute ranges for the current stop: `[0]` is the primary, the rest are
    /// mirrors in document order. Empty ranges are valid (zero-width stop).
    public var currentStopRanges: [Range<Int>] {
        let cur = stopOrder[currentPos]
        return instances
            .filter { $0.index == cur }
            .sorted { a, b in
                if a.isPrimary != b.isPrimary { return a.isPrimary }
                return a.start < b.start
            }
            .map { $0.start ..< $0.end }
    }

    // MARK: - Navigation

    @discardableResult
    public func next() -> Bool {
        guard isActive else { return false }
        let np = currentPos + 1
        if np >= stopOrder.count || stopOrder[np] == 0 {
            currentPos = min(np, stopOrder.count - 1)   // land caret on $0
            isActive = false
            return false
        }
        currentPos = np
        return true
    }

    @discardableResult
    public func previous() -> Bool {
        guard currentPos > 0 else { return false }
        currentPos -= 1
        isActive = true
        return true
    }

    // MARK: - Caret

    public func caretMoved(to offset: Int) {
        guard isActive else { return }
        if currentStopRanges.contains(where: { offset >= $0.lowerBound && offset <= $0.upperBound }) {
            return
        }
        // Jump into another stop's range (innermost wins for nested stops).
        if let inner = instances
            .filter({ offset >= $0.start && offset <= $0.end })
            .min(by: { $0.length < $1.length }),
           let pos = stopOrder.firstIndex(of: inner.index) {
            currentPos = pos
            return
        }
        if offset < insertionOffset || offset > insertionOffset + spanLength {
            isActive = false
        }
        // inside the span but on literal text: stay active, current stop unchanged
    }

    // MARK: - Buffer edits

    public func bufferDidChange(range: Range<Int>, replacement: String) -> [MirrorEdit] {
        guard isActive else { return [] }
        let cur = stopOrder[currentPos]
        guard let pSlot = instances.firstIndex(where: { $0.index == cur && $0.isPrimary }) else {
            isActive = false
            return []
        }
        let primary = instances[pSlot]
        let editStart = range.lowerBound, editEnd = range.upperBound

        // Only edits fully inside the current stop's primary range are accepted;
        // anything else (mirror edit, literal text, outside the span) ends the session.
        guard editStart >= primary.start, editEnd <= primary.end else {
            isActive = false
            return []
        }

        let delta = replacement.utf16.count - (editEnd - editStart)
        applyEdit(start: editStart, end: editEnd, replacement: replacement, delta: delta)

        // Sync mirrors of the edited stop AND every ancestor stop whose primary range
        // geometrically contains it — e.g. "${1:${2:a}} $1": editing $2 must also
        // refresh the parent $1's trailing mirror, not just $2's own mirrors.
        let curPrimary = instances[pSlot]
        // Innermost-first so each parent's newText is computed after its children synced.
        let ancestorIndices = instances
            .filter { $0.isPrimary && $0.index != cur && $0.start <= curPrimary.start && curPrimary.end <= $0.end }
            .sorted { ($0.end - $0.start) < ($1.end - $1.start) }
            .map(\.index)

        // Capture EVERY group's mirror ranges up front, in post-primary-edit coordinates —
        // before any internal mirror splice shifts them. All returned ranges then share one
        // coordinate space; sorted descending, right-to-left host application keeps each
        // leftward range valid (the same invariant as the single-level path). Capturing
        // inside the sync loop instead returned ranges already shifted by earlier groups'
        // splices — an out-of-range MirrorEdit and a host-side crash.
        let groups: [(stopIndex: Int, captures: [(slot: Int, range: Range<Int>)])] =
            ([cur] + ancestorIndices).compactMap { stopIndex in
                let mirrorSlots = instances.indices.filter { instances[$0].index == stopIndex && !instances[$0].isPrimary }
                guard !mirrorSlots.isEmpty else { return nil }
                return (stopIndex, mirrorSlots.map { ($0, instances[$0].start ..< instances[$0].end) })
            }

        var edits: [MirrorEdit] = []
        for group in groups {
            guard let primarySlot = instances.firstIndex(where: { $0.index == group.stopIndex && $0.isPrimary }) else { continue }
            let newText = instances[primarySlot].text
            edits += group.captures.map { MirrorEdit(range: $0.range, replacement: newText) }

            // Bring internal state in sync, applying this group's splices left-to-right.
            for slot in group.captures.map(\.slot).sorted(by: { instances[$0].start < instances[$1].start }) {
                let m = instances[slot]
                let dM = newText.utf16.count - m.length
                applyEdit(start: m.start, end: m.end, replacement: newText, delta: dM, skipping: slot)
                instances[slot].text = newText
                instances[slot].length = newText.utf16.count
            }
        }

        // Host applies these right-to-left, so hand them back descending.
        return edits.sorted { $0.range.lowerBound > $1.range.lowerBound }
    }

    /// Shifts/grows every instance for a replacement of `[start, end)` with text of
    /// length `end-start+delta`. Containing instances (the edited stop and its
    /// ancestors) grow and have their text spliced; instances after the edit shift.
    private func applyEdit(start: Int, end: Int, replacement: String, delta: Int, skipping skip: Int? = nil) {
        for i in instances.indices where i != skip {
            var inst = instances[i]
            if inst.start <= start && end <= inst.end {
                let range = Self.utf16Range(start - inst.start, end - inst.start, in: inst.text)
                inst.text.replaceSubrange(range, with: replacement)
                inst.length += delta
            } else if inst.start >= end {
                inst.start += delta
            }
            instances[i] = inst
        }
        spanLength += delta
    }

    // MARK: - UTF-16 helpers

    private static func utf16Range(_ lower: Int, _ upper: Int, in s: String) -> Range<String.Index> {
        String.Index(utf16Offset: lower, in: s) ..< String.Index(utf16Offset: upper, in: s)
    }
}

import SwiftUI
import AppKit
import MeatPadKit

/// A read-only label that draws its text with the URLs in it marked, and claims a click
/// **only** when the click lands on one of them.
///
/// SwiftUI's own `Text` can't do this. Its glyphs consume every click that lands on them —
/// verified by a UI-test probe: with the tap-to-edit gesture moved to a layer behind the
/// text, clicks in the empty part of the row still edited and clicks on the words did
/// nothing at all. So either links lose their click or the card stops being editable by
/// clicking its text. Owning the layout settles it: `hitTest` returns this view for a link
/// glyph and `nil` for everything else, which leaves every other click to the row's own
/// edit layer and to the card's `.draggable`, exactly as before links existed.
final class LinkLabel: NSView {
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer()
    private var links: [DetectedLink] = []
    var onOpen: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Top-down like the text it draws, so glyph coordinates and view coordinates agree.
    override var isFlipped: Bool { true }

    func apply(_ attributed: NSAttributedString, links: [DetectedLink], lineLimit: Int) {
        self.links = links
        storage.setAttributedString(attributed)
        container.maximumNumberOfLines = max(0, lineLimit)
        container.lineBreakMode = lineLimit == 0 ? .byWordWrapping : .byTruncatingTail
        invalidateIntrinsicContentSize()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Height the text needs at `width` — what the SwiftUI wrapper reports upward, so a card
    /// grows with a wrapping title the same way it did with `Text`.
    func size(fitting width: CGFloat) -> CGSize {
        layOut(width: width)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    private func layOut(width: CGFloat) {
        let size = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        if container.size != size { container.size = size }
        layout.ensureLayout(for: container)
    }

    override func draw(_ dirtyRect: NSRect) {
        layOut(width: bounds.width)
        let glyphs = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: glyphs, at: .zero)
        layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    /// The whole point of this class: only a link glyph belongs to this view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }), bounds.contains(local) else { return nil }
        return link(at: local) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if let url = link(at: convert(event.locationInWindow, from: nil))?.url { onOpen?(url) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        layOut(width: bounds.width)
        for link in links {
            let glyphs = layout.glyphRange(forCharacterRange: link.range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs,
                                           withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    /// The link under `point`, or nil. `glyphIndex(for:in:)` answers with the *nearest*
    /// glyph even when the point is past the end of a line, so the glyph's own rect has to
    /// be checked — otherwise the empty space after a URL would open it.
    private func link(at point: NSPoint) -> DetectedLink? {
        guard !links.isEmpty else { return nil }
        layOut(width: bounds.width)
        let glyphs = layout.glyphRange(for: container)
        guard glyphs.length > 0 else { return nil }
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        guard glyph < glyphs.upperBound,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point)
        else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        return links.first { NSLocationInRange(index, $0.range) }
    }
}

/// `LinkLabel` as a SwiftUI view: text in, links clickable, everything else transparent.
struct LinkableText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    /// 0 means no limit — the same shape `NSTextContainer` uses.
    var lineLimit: Int = 0

    func makeNSView(context: Context) -> LinkLabel {
        let view = LinkLabel()
        view.onOpen = { LinkOpener.open($0) }
        return view
    }

    func updateNSView(_ view: LinkLabel, context: Context) {
        let links = LinkScanner.links(in: text)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        )
        for link in links {
            attributed.addAttributes(
                [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
                range: link.range
            )
        }
        view.apply(attributed, links: links, lineLimit: lineLimit)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkLabel, context: Context) -> CGSize? {
        // An unspecified or infinite proposal means "how wide would you like to be" — a card
        // row is always given its column's width, so fall back to the width it already has.
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return nsView.size(fitting: proposed ?? max(1, nsView.bounds.width))
    }
}

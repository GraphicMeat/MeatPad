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
    /// What was last rendered into this view. `updateNSView` runs on every update SwiftUI
    /// sends down, and rebuilding the text means a markdown parse plus an `NSDataDetector`
    /// pass — per card, per pass. Unchanged input, unchanged glyphs: skip the lot.
    var rendered: Input?

    struct Input: Equatable {
        let text: String
        let font: NSFont
        let color: NSColor
        let lineLimit: Int
        let lineSpacing: CGFloat
        let markdown: Bool
        /// Part of the cache key like everything else that changes the glyphs — leave it out
        /// and a card keeps the highlight of whatever was typed when its text last changed.
        let highlight: String
    }

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
    /// Points between lines (the card line-spacing setting); 0 is the font's own spacing.
    var lineSpacing: CGFloat = 0
    /// Inline markdown on the card face — off for anything that must render exactly as typed
    /// (the live `TextField`s never set this; only the read-only face does).
    var markdown: Bool = false
    /// The board search's query, painted over every hit the way Finder and Mail mark a find.
    /// Empty paints nothing.
    var highlight: String = ""

    func makeNSView(context: Context) -> LinkLabel {
        let view = LinkLabel()
        view.onOpen = { LinkOpener.open($0) }
        return view
    }

    func updateNSView(_ view: LinkLabel, context: Context) {
        let input = LinkLabel.Input(text: text, font: font, color: color, lineLimit: lineLimit,
                                    lineSpacing: lineSpacing, markdown: markdown, highlight: highlight)
        guard view.rendered != input else { return }
        view.rendered = input
        if markdown {
            updateMarkdown(view)
        } else {
            let links = LinkScanner.links(in: text)
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            )
            for link in links {
                attributed.addAttributes(
                    [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
                    range: link.range
                )
            }
            markHits(in: attributed)
            view.apply(attributed, links: links, lineLimit: lineLimit)
        }
    }

    private var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }

    /// Paints the search hits, last so its black-on-yellow wins over a link's colour — the
    /// find highlight is what the user is looking for right now. Measured against the string
    /// actually drawn: in markdown that is the rendered text, which is shorter than the
    /// source by every `**` and `[](…)`, the same trap as the link ranges below. Same matching
    /// rule as the filter (`Card.matchRanges`), so every card the search keeps shows why.
    private func markHits(in attributed: NSMutableAttributedString) {
        for range in Card.matchRanges(of: highlight, in: attributed.string) {
            attributed.addAttributes(
                [.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black],
                range: range
            )
        }
    }

    /// Renders `text` as inline markdown. The base font/colour go on FIRST, over the whole
    /// string, so `CardMarkdown`'s own (unstyled) defaults never win over the card's type —
    /// then each run's carried traits are layered back on top of that base.
    ///
    /// Link ranges are the trap: `[a](b)` reads longer than it draws, so a range measured
    /// against the raw markdown would hit-test the wrong glyphs. Everything below is measured
    /// against `rendered`/the converted `NSAttributedString`, never against `text`.
    private func updateMarkdown(_ view: LinkLabel) {
        let rendered = CardMarkdown.attributed(text)
        let attributed = NSMutableAttributedString(rendered)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: paragraph], range: fullRange)

        var markdownLinks: [DetectedLink] = []
        for run in rendered.runs {
            let nsRange = NSRange(run.range, in: rendered)
            if let intent = run.inlinePresentationIntent {
                var runFont = font
                if intent.contains(.stronglyEmphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
                }
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                }
                if runFont !== font { attributed.addAttribute(.font, value: runFont, range: nsRange) }
                if intent.contains(.strikethrough) {
                    attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: nsRange)
                }
            }
            if let link = run.link {
                markdownLinks.append(DetectedLink(range: nsRange, url: link))
                attributed.addAttributes(
                    [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
                    range: nsRange
                )
            }
        }

        // Bare URLs the markdown parser didn't already turn into links — scanned on the
        // RENDERED plain text, and any hit already covered by a markdown link is dropped
        // rather than double-counted.
        let bareLinks = LinkScanner.links(in: attributed.string).filter { bare in
            !markdownLinks.contains { NSIntersectionRange($0.range, bare.range).length > 0 }
        }
        for link in bareLinks {
            attributed.addAttributes(
                [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
                range: link.range
            )
        }

        let links = (markdownLinks + bareLinks).sorted { $0.range.location < $1.range.location }
        markHits(in: attributed)
        view.apply(attributed, links: links, lineLimit: lineLimit)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkLabel, context: Context) -> CGSize? {
        // An unspecified or infinite proposal means "how wide would you like to be" — a card
        // row is always given its column's width, so fall back to the width it already has.
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return nsView.size(fitting: proposed ?? max(1, nsView.bounds.width))
    }
}

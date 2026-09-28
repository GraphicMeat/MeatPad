import AppKit
import MeatPadKit

/// A column's look as a menu item's icon, so "Move to" reads like the column headers it points
/// at: the column's own image, else its own emoji, else the emoji `BoardStore.suggestedEmoji`
/// would suggest for it — a same-named column on another board, else a keyword guess. Only the
/// menu shows a suggestion; it is never written to the column (the header stays as it is until
/// its owner picks "Use … as Icon"). nil when there is nothing to draw.
///
/// Rendered small and kept: a menu asks again on every open, an All Boards column has a card
/// per row asking, and an emoji or a decoded file is not free to redraw each time.
@MainActor
enum ColumnMenuIcon {
    private static let side: CGFloat = 16
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func image(for column: BoardColumn, in store: BoardStore) -> NSImage? {
        if let url = store.columnImageURL(column) {
            return cached("image:" + url.path) {
                BoardIconCache.image(at: url).map(thumbnail)
            }
        }
        guard let emoji = column.emoji ?? store.suggestedEmoji(for: column) else { return nil }
        return cached("emoji:" + emoji) { glyph(emoji) }
    }

    private static func cached(_ key: String, make: () -> NSImage?) -> NSImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let image = make() else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    private static func glyph(_ emoji: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let text = emoji as NSString
        let size = text.size(withAttributes: attributes)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2),
                      withAttributes: attributes)
            return true
        }
    }

    private static func thumbnail(_ source: NSImage) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            source.draw(in: rect)
            return true
        }
    }
}

import SwiftUI
import AppKit
import MeatPadKit

/// The kinds of icon a card shows — in its right-click menu and in its action row — so each
/// kind can have a colour of its own. A sub-item takes its category's kind (every Due Date
/// entry is `.due`): the colour says what family an action belongs to, not which action it is.
enum CardIconKind: String, CaseIterable, Identifiable {
    case move, due, labels, copy, split, notes, present, summarize, unlink, archive, delete

    var id: String { rawValue }

    /// Shown in Settings ▸ Boards, one row per kind.
    var title: LocalizedStringKey {
        switch self {
        case .move: "Move"
        case .due: "Due Date"
        case .labels: "Labels"
        case .copy: "Copy"
        case .split: "Split"
        case .notes: "Notes"
        case .present: "Present"
        case .summarize: "Summarize"
        case .unlink: "Unlink"
        case .archive: "Archive"
        case .delete: "Delete"
        }
    }

    /// The symbol of the kind itself — the category's icon in the action row, and the one the
    /// Settings row tints.
    var symbol: String {
        switch self {
        case .move: "arrow.right.circle"
        case .due: "calendar"
        case .labels: "tag"
        case .copy: "doc.on.doc"
        case .split: "rectangle.split.3x1"
        case .notes: "text.alignleft"
        case .present: "play.rectangle"
        case .summarize: "sparkles"
        case .unlink: "link.badge.minus"
        case .archive: "archivebox"
        case .delete: "trash"
        }
    }

    /// System colours, not fixed RGB: they are dynamic, so each kind keeps its hue and picks
    /// the right brightness in light and dark appearance without anyone choosing it.
    var defaultColor: NSColor {
        switch self {
        case .move: .systemBlue
        case .due: .systemRed
        case .labels: .systemPurple
        case .copy: .systemTeal
        case .split: .systemIndigo
        case .notes: .systemGray
        case .present: .systemGreen
        case .summarize: .systemPink
        case .unlink: .systemOrange
        case .archive: .systemBrown
        case .delete: .systemRed
        }
    }
}

/// The user's icon-colour settings, read once from the two `@AppStorage` strings the card
/// carries instead of eleven wrappers — one per kind would make every card observe eleven
/// keys. Only the colours the user changed are stored (kind → `#RRGGBB`); an absent kind is
/// its default, so a new default colour reaches everyone who never customised that kind.
struct CardIconPalette: Equatable {
    static let enabledKey = "board.coloredIcons"
    static let colorsKey = "board.iconColors"

    var enabled: Bool
    var custom: [CardIconKind: String]

    init(enabled: Bool, json: String) {
        self.enabled = enabled
        custom = Self.decode(json)
    }

    /// nil when colouring is off — callers then draw the plain, system-tinted look. Monochrome
    /// icons never depend on this: they are shown whatever the setting says.
    func color(for kind: CardIconKind) -> NSColor? {
        guard enabled else { return nil }
        return nsColor(for: kind)
    }

    /// The colour the Settings row shows, whether or not colouring is on.
    func nsColor(for kind: CardIconKind) -> NSColor {
        custom[kind].flatMap { RGBAColor(hex: $0) }.map { NSColor($0) } ?? kind.defaultColor
    }

    // Every card asks on every body pass with the same string; a one-entry memo keeps that
    // from being a JSON decode per card per pass.
    private static var memo: (json: String, value: [CardIconKind: String]) = ("", [:])

    static func decode(_ json: String) -> [CardIconKind: String] {
        if memo.json == json { return memo.value }
        var result: [CardIconKind: String] = [:]
        if let data = json.data(using: .utf8),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            for (key, hex) in raw {
                if let kind = CardIconKind(rawValue: key), RGBAColor(hex: hex) != nil { result[kind] = hex }
            }
        }
        memo = (json, result)
        return result
    }

    /// Sorted keys, so the same colours always write the same string and an unchanged
    /// setting never looks changed to `@AppStorage`.
    static func encode(_ custom: [CardIconKind: String]) -> String {
        let raw = Dictionary(uniqueKeysWithValues: custom.map { ($0.key.rawValue, $0.value) })
        guard !raw.isEmpty,
              let data = try? JSONEncoder.sorted.encode(raw),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    /// sRGB `#RRGGBB`, the form the setting stores.
    static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        func byte(_ component: CGFloat) -> Int { Int((component * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// The one place a card or menu icon is made. A menu item can't take a SwiftUI colour — a
/// `Label(systemImage:)` shows no icon at all in a macOS context menu — but an `Image(nsImage:)`
/// does (it is how `ColumnMenuIcon` draws "Move to"), so every entry goes through here:
///
/// - uncoloured: a template image, which the menu tints itself (and greys when disabled)
/// - coloured: a palette-tinted symbol, not a template, so the menu leaves the colour alone
@MainActor
enum CardIcon {
    private static let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func image(_ symbol: String, color: NSColor?) -> NSImage {
        // The key names the colour by its description: a dynamic system colour keeps its
        // catalogue name, so it stays one entry per kind and still re-resolves per appearance.
        let key = "\(symbol)|\(color?.description ?? "template")" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        let image: NSImage
        if let color {
            let tinted = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            image = base.withSymbolConfiguration(tinted) ?? base
            image.isTemplate = false
        } else {
            image = base.withSymbolConfiguration(configuration) ?? base
            image.isTemplate = true
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import MeatPadKit

/// What a live drag over a column would do. One case per outcome, so the column, the
/// insertion bar and a single card can each ask "is it me?" and only one of them ever says yes.
enum DropTarget: Equatable {
    case insert(column: UUID, index: Int)
    case attach(card: UUID)
    case newCard(column: UUID)
}

/// The dragged image, decoded once for the whole drag: `DropInfo` hands out item providers on
/// every mouse move, and decoding a photo per frame is exactly the "chunky" the board had.
struct DragImage {
    let change: Int
    let payload: CardDrop
    let thumbnail: NSImage
}

/// Owns the one load per drag session. A class, not `@State`, because the delegate is rebuilt
/// on every `dropUpdated` and "already loading for change N" has to outlive it.
@MainActor
final class DragImageLoader: ObservableObject {
    @Published private(set) var image: DragImage?
    private var loading: Int?

    /// Keyed by the drag pasteboard's change count, so a stale preview can never leak into
    /// the next drag.
    func load(from info: DropInfo) {
        let change = NSPasteboard(name: .drag).changeCount
        guard image?.change != change, loading != change,
              let provider = info.itemProviders(for: [.image]).first
        else { return }
        loading = change
        _ = provider.loadTransferable(type: CardDrop.self) { result in
            guard case .success(let payload) = result,
                  case .image(let data, _, _) = payload,
                  let thumbnail = Self.thumbnail(data)
            else { return }
            Task { @MainActor [weak self] in
                guard let self, self.loading == change else { return }
                self.image = DragImage(change: change, payload: payload, thumbnail: thumbnail)
            }
        }
    }

    func clear() {
        image = nil
        loading = nil
    }

    /// ImageIO rather than `NSImage(data:)`: a 12MP photo drawn at 44pt would otherwise be
    /// decoded at full size for a badge.
    nonisolated private static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: 160,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// One drop delegate per column. `dropDestination` only ever reports "somewhere in me", which
/// is why an image over a card used to highlight the column: a `DropDelegate` gets the pointer
/// position, so the column can decide between a slot, a card, and bare space itself.
struct ColumnDropDelegate: DropDelegate {
    /// nil = the all-boards "Other" pseudo-column: it has no single column to reorder into,
    /// so it takes images onto its cards and nothing else.
    let column: UUID?
    /// The visible card rows, top to bottom, in this column's coordinate space.
    let rows: [BoardDropRow]
    @Binding var target: DropTarget?
    let loader: DragImageLoader
    let attach: (UUID, CardDrop) -> Bool
    /// nil when there is no single board to put a new card on (all-boards with 0 or 2+ boards).
    let create: ((CardDrop) -> Bool)?
    let moveCards: ([String], Int) -> Bool

    private func isImage(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.image]) }

    /// Images anywhere; card ids only where a reorder means something. A non-image file has
    /// nothing to become, so it is refused outright rather than dropped into nowhere.
    func validateDrop(info: DropInfo) -> Bool {
        if isImage(info) { return true }
        return column != nil && !info.itemProviders(for: [.utf8PlainText, .plainText]).isEmpty
    }

    func dropEntered(info: DropInfo) { update(info) }

    /// Bare space that cannot become a card (the "Other" column, all-boards with several
    /// boards) says so with the cursor instead of accepting a drop that then does nothing.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        guard target != nil else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: isImage(info) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        switch target {
        case .insert(let c, _), .newCard(let c): if c == column { target = nil }
        case .attach(let card): if rows.contains(where: { $0.id == card }) { target = nil }
        case nil: break
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let placed = placement(info)
        defer { target = nil }
        guard isImage(info) else {
            guard case .insert(_, let index)? = placed,
                  let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first
            else { return false }
            _ = provider.loadTransferable(type: String.self) { result in
                guard case .success(let id) = result else { return }
                Task { @MainActor in _ = moveCards([id], index) }
            }
            return true
        }
        guard let placed else { return false }
        // The hover already decoded this image for the preview; re-decoding it on drop would
        // stall the mouse-up. The change count says it is still the same drag.
        if let cached = loader.image, cached.change == NSPasteboard(name: .drag).changeCount {
            loader.clear()
            return apply(cached.payload, to: placed)
        }
        guard let provider = info.itemProviders(for: [.image]).first else { return false }
        _ = provider.loadTransferable(type: CardDrop.self) { result in
            guard case .success(let drop) = result else { return }
            Task { @MainActor in
                loader.clear()
                _ = apply(drop, to: placed)
            }
        }
        return true
    }

    private func apply(_ drop: CardDrop, to placed: DropTarget) -> Bool {
        switch placed {
        case .attach(let card): return attach(card, drop)
        case .newCard: return create?(drop) ?? false
        case .insert: return false
        }
    }

    private func update(_ info: DropInfo) {
        if isImage(info) { loader.load(from: info) }
        target = placement(info)
    }

    private func placement(_ info: DropInfo) -> DropTarget? {
        if isImage(info) {
            if case .attach(let id) = BoardDropPlacement.forImage(at: info.location, rows: rows) {
                return .attach(card: id)
            }
            // No ants over bare space we cannot turn into a card.
            guard let column, create != nil else { return nil }
            return .newCard(column: column)
        }
        guard let column,
              case .insert(let index) = BoardDropPlacement.forCard(at: info.location.y, rows: rows)
        else { return nil }
        return .insert(column: column, index: index)
    }
}

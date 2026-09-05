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

/// The dragged file, decoded once for the whole drag: `DropInfo` hands out item providers on
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
    /// The change count of a drag that has already been dropped. Sticky for the whole session
    /// on purpose — see `ColumnDropDelegate.performDrop`.
    var dropped: Int?

    /// Keyed by the drag pasteboard's change count, so a stale preview can never leak into
    /// the next drag.
    func load(from info: DropInfo) {
        let change = NSPasteboard(name: .drag).changeCount
        guard image?.change != change, loading != change, dropped != change else { return }
        loading = change
        // A Finder drag already has its file on the pasteboard, so read it here: `CardDrop`
        // deliberately imports images only, and a PDF or a .docx has no image representation
        // to load. The badge falls back to the file's own icon.
        // ponytail: the bytes are read once per drag, on the first hover — a 2GB file dragged
        // over the board is read before it is dropped. Upgrade = keep the URL here and read in
        // performDrop, at the cost of a second pass for the drop itself.
        // ponytail: only the first file of a multi-file drag is attached; the payload is one
        // card-drop. Upgrade = make the delegate apply a list.
        if let file = AttachmentImport.files(from: NSPasteboard(name: .drag)).first {
            image = DragImage(
                change: change,
                payload: .file(file.data, ext: file.ext, name: file.name),
                thumbnail: Self.thumbnail(file.data)
                    ?? NSWorkspace.shared.icon(for: UTType(filenameExtension: file.ext) ?? .data)
            )
            return
        }
        guard let provider = info.itemProviders(for: [.image]).first else { return }
        _ = provider.loadTransferable(type: CardDrop.self) { result in
            guard case .success(let payload) = result,
                  case .file(let data, _, _) = payload,
                  let thumbnail = Self.thumbnail(data)
            else { return }
            Task { @MainActor [weak self] in
                guard let self, self.loading == change else { return }
                self.image = DragImage(change: change, payload: payload, thumbnail: thumbnail)
            }
        }
    }

    /// `dropped` is deliberately kept: the drag it names is over, and the next one arrives
    /// with a change count of its own.
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
/// is why a file over a card used to highlight the column: a `DropDelegate` gets the pointer
/// position, so the column can decide between a slot, a card, and bare space itself.
struct ColumnDropDelegate: DropDelegate {
    /// nil = the all-boards "Other" pseudo-column: it has no single column to reorder into,
    /// so it takes files onto its cards and nothing else.
    let column: UUID?
    /// The visible card rows, top to bottom, in this column's coordinate space.
    let rows: [BoardDropRow]
    @Binding var target: DropTarget?
    let loader: DragImageLoader
    let attach: (UUID, CardDrop) -> Bool
    /// nil when there is no single board to put a new card on (all-boards with 0 or 2+ boards).
    let create: ((CardDrop) -> Bool)?
    let moveCards: ([String], Int) -> Bool

    private func isFile(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL, .image]) }

    /// Files anywhere; card ids only where a reorder means something.
    func validateDrop(info: DropInfo) -> Bool {
        if isFile(info) { return true }
        return column != nil && !info.itemProviders(for: [.utf8PlainText, .plainText]).isEmpty
    }

    func dropEntered(info: DropInfo) { update(info) }

    /// Bare space that cannot become a card (the "Other" column, all-boards with several
    /// boards) says so with the cursor instead of accepting a drop that then does nothing.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        guard target != nil else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: isFile(info) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        switch target {
        case .insert(let c, _), .newCard(let c): if c == column { target = nil }
        case .attach(let card): if rows.contains(where: { $0.id == card }) { target = nil }
        case nil: break
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        // SwiftUI/AppKit still deliver a `dropEntered`/`dropUpdated` for THIS drag after the
        // drop — the synchronous store write below rebuilds the view and the delegate
        // mid-session — and there is no `dropExited` after a drop to undo it, so the ants and
        // the badge would re-arm and stay lit forever. Marking the session dropped is what
        // `update(_:)` checks; a new drag has a change count of its own.
        loader.dropped = NSPasteboard(name: .drag).changeCount
        let placed = placement(info)
        defer { target = nil }
        guard isFile(info) else {
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
        // The hover already decoded this file for the preview; re-decoding it on drop would
        // stall the mouse-up. The change count says it is still the same drag.
        if let cached = loader.image, cached.change == NSPasteboard(name: .drag).changeCount {
            loader.clear()
            return apply(cached.payload, to: placed)
        }
        // A file the hover never got to read (a drop faster than the first update) is still
        // on the drag pasteboard.
        if let file = AttachmentImport.files(from: NSPasteboard(name: .drag)).first {
            loader.clear()
            return apply(.file(file.data, ext: file.ext, name: file.name), to: placed)
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
        // Late callback for a drag that has already been dropped — see `performDrop`.
        guard loader.dropped != NSPasteboard(name: .drag).changeCount else { target = nil; return }
        if isFile(info) { loader.load(from: info) }
        target = placement(info)
    }

    private func placement(_ info: DropInfo) -> DropTarget? {
        if isFile(info) {
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

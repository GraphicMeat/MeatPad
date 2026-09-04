import SwiftUI
import UniformTypeIdentifiers

/// Everything a card cell accepts, as one `Transferable`: a view gets a single
/// `dropDestination`, and the cell needs both "a card id is being reordered" and "an image
/// is being attached". Order matters — images are matched first: a card-id drag carries no
/// image type, but an image drag (a browser image, often a Finder file too) also carries a
/// text flavour for its URL. SwiftUI binds one representation per item up front, so if the
/// plain-text proxy came first it would win for those drags, fail `UUID(uuidString:)`, and
/// throw — a silent no-op drop instead of falling through to the image representations.
enum CardDrop: Transferable {
    case card(UUID)
    /// `name` is the dropped file's stem, which names the card an image drop creates. Only a
    /// file drag has one — a browser or pasteboard image arrives as bare bytes.
    case image(Data, ext: String, name: String?)

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let type = UTType(filenameExtension: received.file.pathExtension)
            let ext = type?.preferredFilenameExtension ?? received.file.pathExtension.lowercased()
            // The received file is temporary: read it here, inside the import, or it is gone.
            return .image(try Data(contentsOf: received.file), ext: ext,
                          name: received.file.deletingPathExtension().lastPathComponent)
        }
        DataRepresentation(importedContentType: .png) { .image($0, ext: "png", name: nil) }
        DataRepresentation(importedContentType: .jpeg) { .image($0, ext: "jpeg", name: nil) }
        DataRepresentation(importedContentType: .tiff) { .image($0, ext: "tiff", name: nil) }
        ProxyRepresentation(importing: { (id: String) in
            guard let uuid = UUID(uuidString: id) else { throw CocoaError(.coderInvalidValue) }
            return CardDrop.card(uuid)
        })
    }
}

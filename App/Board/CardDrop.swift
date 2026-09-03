import SwiftUI
import UniformTypeIdentifiers

/// Everything a card cell accepts, as one `Transferable`: a view gets a single
/// `dropDestination`, and the cell needs both "a card id is being reordered" and "an image
/// is being attached". Order matters — the plain-text card id is tried first.
enum CardDrop: Transferable {
    case card(UUID)
    case image(Data, ext: String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (id: String) in
            guard let uuid = UUID(uuidString: id) else { throw CocoaError(.coderInvalidValue) }
            return CardDrop.card(uuid)
        })
        FileRepresentation(importedContentType: .image) { received in
            let type = UTType(filenameExtension: received.file.pathExtension)
            let ext = type?.preferredFilenameExtension ?? received.file.pathExtension.lowercased()
            // The received file is temporary: read it here, inside the import, or it is gone.
            return .image(try Data(contentsOf: received.file), ext: ext)
        }
        DataRepresentation(importedContentType: .png) { .image($0, ext: "png") }
        DataRepresentation(importedContentType: .jpeg) { .image($0, ext: "jpeg") }
        DataRepresentation(importedContentType: .tiff) { .image($0, ext: "tiff") }
    }
}

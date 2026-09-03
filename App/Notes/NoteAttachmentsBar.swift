import SwiftUI
import MeatPadKit

/// The note's images, above the status bar. Nothing at all when the note has none — a
/// permanent empty strip would cost every note window 60pt for a feature most never use.
struct NoteAttachmentsBar: View {
    @ObservedObject var store: NoteStore
    let noteID: UUID

    var body: some View {
        if let note = store.notes.first(where: { $0.id == noteID }), let names = note.attachments, !names.isEmpty {
            AttachmentStrip(
                urls: names.map { store.attachmentURL(id: noteID, name: $0) },
                identifier: "note.attachment",
                onRemove: { try? store.removeAttachment(id: noteID, name: names[$0]) }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

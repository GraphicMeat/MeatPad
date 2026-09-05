import SwiftUI
import QuickLook

/// A row of thumbnails with Quick Look on double-click and, when `onRemove` is given, a hover
/// ✕ per thumbnail. Shared by the card editor and the note windows so "a file on a thing"
/// looks the same everywhere. `limit` folds the overflow into a "+N" tile.
struct AttachmentStrip: View {
    let urls: [URL]
    var size: CGFloat = 56
    var limit: Int? = nil
    var identifier = "attachment"
    var onRemove: ((Int) -> Void)? = nil

    @State private var preview: URL?
    @State private var hovering: Int?

    var body: some View {
        let shown = limit.map { Array(urls.prefix($0)) } ?? urls
        HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, url in
                AttachmentThumbnail(url: url, size: size)
                    // The catcher carries the tile's identifier and label (see its doc), and
                    // sits under the remove ✕ so the button stays clickable. Nothing goes on
                    // the row: a container-level identifier pushes onto every child (this
                    // repo has hit that before) and would swallow "\(identifier).remove".
                    .overlay {
                        DoubleClickCatcher(identifier: identifier, label: String(localized: "Attachment")) { preview = url }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let onRemove, hovering == index {
                            Button { onRemove(index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(2)
                            .help(String(localized: "Remove Attachment"))
                            .accessibilityIdentifier("\(identifier).remove")
                        }
                    }
                    .onHover { hovering = $0 ? index : (hovering == index ? nil : hovering) }
                    .contextMenu {
                        Button("Quick Look") { preview = url }
                        if let onRemove { Button("Remove Attachment", role: .destructive) { onRemove(index) } }
                    }
            }
            if urls.count > shown.count {
                Text("+\(urls.count - shown.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.4)))
                    .overlay {
                        DoubleClickCatcher(identifier: "\(identifier).more", label: "+\(urls.count - shown.count)") {
                            preview = urls[shown.count]
                        }
                    }
            }
        }
        .quickLookPreview($preview)
    }
}

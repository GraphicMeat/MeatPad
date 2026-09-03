import SwiftUI
import QuickLook

/// A row of thumbnails with Quick Look on click and, when `onRemove` is given, a hover ✕
/// per thumbnail. Shared by the card editor and the note windows so "an image on a thing"
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
                    // The identifier and label go on the tile itself, before the overlay is
                    // attached — a container-level identifier pushes onto every child (this
                    // repo has hit that before), which would swallow the remove Button's own
                    // "\(identifier).remove" id and make it unresolvable to UI tests.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Image"))
                    .accessibilityIdentifier(identifier)
                    .contentShape(Rectangle())
                    .onTapGesture { preview = url }
                    .overlay(alignment: .topTrailing) {
                        if let onRemove, hovering == index {
                            Button { onRemove(index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(2)
                            .help(String(localized: "Remove Image"))
                            .accessibilityIdentifier("\(identifier).remove")
                        }
                    }
                    .onHover { hovering = $0 ? index : (hovering == index ? nil : hovering) }
                    .contextMenu {
                        Button("Quick Look") { preview = url }
                        if let onRemove { Button("Remove Image", role: .destructive) { onRemove(index) } }
                    }
            }
            if urls.count > shown.count {
                Text("+\(urls.count - shown.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.4)))
                    .onTapGesture { preview = urls[shown.count] }
            }
        }
        .quickLookPreview($preview)
    }
}

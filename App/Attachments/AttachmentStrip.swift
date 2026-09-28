import SwiftUI
import QuickLook
import QuickLookUI
import MeatPadKit

/// A row of thumbnails with Quick Look on double-click and, when `onRemove` is given, a hover
/// ✕ per thumbnail. Shared by the card editor and the note windows so "a file on a thing"
/// looks the same everywhere. `limit` folds the overflow into a "+N" tile.
struct AttachmentStrip: View {
    let urls: [URL]
    var size: CGFloat = 56
    var limit: Int? = nil
    var identifier = "attachment"
    var onRemove: ((Int) -> Void)? = nil
    /// The card or note's own title, used to name a dragged-out copy — nil draws the plain
    /// "Attachment" fallback instead.
    var dragTitle: String? = nil
    /// The card or note this strip belongs to, so each one's drag-out copies live in their own
    /// temp folder (and `ColumnDropDelegate` can tell a card's own drag-out from anyone else's).
    var owner: UUID? = nil

    @State private var preview: URL?
    @State private var hovering: Int?
    /// Set by a view that owns Quick Look for everything under it (the board) — then this
    /// strip carries no `.quickLookPreview` of its own. See `QuickLookHost`.
    @Environment(\.quickLookHost) private var host

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
                        DoubleClickCatcher(identifier: identifier, label: String(localized: "Attachment")) { open(url) }
                    }
                    // SwiftUI's own gesture recognisers claim a mouse-down before a nested
                    // AppKit view (the catcher) gets a look at it — see `DoubleClickCatcher`'s
                    // doc — which is the same reason a single click still reaches the row
                    // underneath. Whether `.onDrag` wins over the card row's own `.draggable`
                    // for a mouse-down that starts on a tile is unverified without a device run.
                    .onDrag { exportProvider(url: url, index: index) }
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
                        Button("Quick Look") { open(url) }
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
                            open(urls[shown.count])
                        }
                    }
            }
        }
        .modifier(OwnQuickLook(preview: $preview, enabled: host == nil))
    }

    /// SwiftUI doesn't always write `nil` back when the Quick Look panel goes away. A switch to
    /// another view does it, and then the next double-click on the same image assigns the same
    /// URL and nothing happens. Clearing first makes every open a real change.
    private func open(_ url: URL) {
        let name = url.lastPathComponent
        quickLookLog.debug("open \(name, privacy: .public)")
        if let host {
            host.open(url)
        } else {
            preview = nil
            DispatchQueue.main.async { preview = url }
        }
        // The last stage of the path: did the panel actually come up for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let up = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
            quickLookLog.debug("0.5s after open \(name, privacy: .public): panel \(up ? "up" : "NOT up", privacy: .public)")
        }
    }

    /// A drag out of the app never hands out the stored file directly — a Finder drop can move
    /// it, which would delete it out of the store. Each drag gets its own throwaway copy, named
    /// after the card/note instead of its on-disk uuid.
    // ponytail: temp copies are left for the OS to purge; sweep "MeatPad Drags" at launch if it
    // ever matters.
    private func exportProvider(url: URL, index: Int) -> NSItemProvider {
        let name = AttachmentExport.fileName(title: dragTitle ?? "", index: index, ext: url.pathExtension,
                                             fallback: String(localized: "Attachment"))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeatPad Drags", isDirectory: true)
            .appendingPathComponent(owner?.uuidString ?? "none", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch { return NSItemProvider() }
        return NSItemProvider(contentsOf: copy) ?? NSItemProvider()
    }
}

/// The strip's own `.quickLookPreview`, only where no ancestor hosts Quick Look instead.
private struct OwnQuickLook: ViewModifier {
    @Binding var preview: URL?
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.quickLookPreview($preview) } else { content }
    }
}

/// One `.quickLookPreview` for a whole view, handed down to every `AttachmentStrip` under it.
///
/// Per-strip modifiers broke on the board: switch the sidebar from one board to another (or
/// to All Boards) and no double-click opened Quick Look until the view changed again — the
/// tile was found and the preview was set, the panel just never came up. Proven under UI
/// test (`BoardCardFaceUITests`, the All Boards probes and the board-switch test): it failed
/// only when one set of strips left and another arrived in the SAME update. The same
/// All Boards reached by way of a note (strips leave, then arrive, in separate updates), or
/// refreshed with Compact then Full, opened every time. So the switch itself orphans the
/// arriving strips' `.quickLookPreview` — SwiftUI's internals, not ours to fix — and the way
/// out is a modifier that never leaves when the board's content swaps: this one, on the
/// board view, which keeps its identity across every board and All Boards.
struct QuickLookHost: ViewModifier {
    @StateObject private var request = QuickLookRequest()

    func body(content: Content) -> some View {
        content
            .environment(\.quickLookHost, request)
            .quickLookPreview($request.url)
    }
}

/// What a strip under a `QuickLookHost` asks to preview. A reference, so the environment
/// value handed to every strip stays the same object across renders and invalidates nothing.
final class QuickLookRequest: ObservableObject {
    @Published var url: URL?

    /// A different file is set straight through: the panel is shared by every tile on the
    /// board, and clearing it first would dismiss the image already up, whose closing then
    /// swallows the next one (probe c in `BoardCardFaceUITests`). Only the same file again
    /// takes the strip's clear-then-set, since an unchanged binding opens nothing.
    func open(_ url: URL) {
        guard self.url == url else {
            self.url = url
            return
        }
        self.url = nil
        DispatchQueue.main.async { self.url = url }
    }
}

private struct QuickLookHostKey: EnvironmentKey {
    static let defaultValue: QuickLookRequest? = nil
}

extension EnvironmentValues {
    var quickLookHost: QuickLookRequest? {
        get { self[QuickLookHostKey.self] }
        set { self[QuickLookHostKey.self] = newValue }
    }
}

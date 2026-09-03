import AppKit
import UniformTypeIdentifiers

/// One reading of a pasteboard for "images to attach": image FILES first (Finder, Photos'
/// file promise resolved to a URL), then raw image data (a browser drag, a screenshot ⌘V).
/// Extension comes from the file's type, or the data's — never from a user-typed name.
enum ImageImport {
    static func items(from pasteboard: NSPasteboard) -> [(data: Data, ext: String)] {
        var out: [(Data, String)] = []
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let ext = type.preferredFilenameExtension, let data = try? Data(contentsOf: url) else { continue }
            out.append((data, ext))
        }
        if out.isEmpty {
            if let data = pasteboard.data(forType: .png) { out.append((data, "png")) }
            else if let data = pasteboard.data(forType: .tiff) { out.append((data, "tiff")) }
        }
        return out.map { (data: $0.0, ext: $0.1) }
    }
}

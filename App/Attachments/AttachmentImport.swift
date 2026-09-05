import AppKit
import UniformTypeIdentifiers

/// One reading of a pasteboard for "files to attach": file URLs first (Finder, Photos' file
/// promise resolved to a URL), then raw image data (a browser drag, a screenshot ⌘V).
/// Extension comes from the file's type, or the data's — never from a user-typed name.
enum AttachmentImport {
    /// Every readable file on the pasteboard. A card takes anything — a PDF, a .docx, a
    /// zip — so nothing here filters by type; directories are skipped because there is no
    /// single file to store.
    static func files(from pasteboard: NSPasteboard) -> [(data: Data, ext: String, name: String)] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.compactMap { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return (data, ext(of: url), url.deletingPathExtension().lastPathComponent)
        }
    }

    /// The store keys files by extension and refuses an empty one, so a LICENSE or a Makefile
    /// is stored as data rather than silently not attaching at all.
    static func ext(of url: URL) -> String {
        let named = UTType(filenameExtension: url.pathExtension)?.preferredFilenameExtension
            ?? url.pathExtension.lowercased()
        return named.isEmpty ? "dat" : named
    }

    /// Images only — the text editor inlines what it takes, and a PDF has nothing to inline.
    static func items(from pasteboard: NSPasteboard) -> [(data: Data, ext: String)] {
        var out = files(from: pasteboard)
            .filter { UTType(filenameExtension: $0.ext)?.conforms(to: .image) ?? false }
            .map { (data: $0.data, ext: $0.ext) }
        if out.isEmpty {
            if let data = pasteboard.data(forType: .png) { out.append((data, "png")) }
            else if let data = pasteboard.data(forType: .tiff) { out.append((data, "tiff")) }
        }
        return out
    }
}

import SwiftUI
import QuickLookThumbnailing

/// A thumbnail for a fixed square, made once per URL. Quick Look rather than ImageIO: a card
/// takes any file now, and `QLThumbnailGenerator` previews images, PDFs and documents alike
/// and falls back to the file's icon — without ever decoding a 12MP photo at full size.
struct AttachmentThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    // Keyed on URL + pixel size: the face (44pt→88px) and the editor (56pt→112px) can both be
    // on screen for the same URL, and a URL-only key would let whichever decoded first win.
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.4))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url) { image = await Self.thumbnail(for: url, maxPixels: Int(size * 2)) }
    }

    private static func thumbnail(for url: URL, maxPixels: Int) async -> NSImage? {
        let key = "\(url.absoluteString)@\(maxPixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let points = CGFloat(maxPixels) / 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: points, height: points),
            scale: 2,
            representationTypes: .all
        )
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        let made = NSImage(cgImage: rep.cgImage, size: NSSize(width: rep.cgImage.width, height: rep.cgImage.height))
        cache.setObject(made, forKey: key)
        return made
    }
}

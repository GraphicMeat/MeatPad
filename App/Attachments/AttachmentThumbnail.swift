import SwiftUI
import ImageIO

/// A downsampled image for a fixed square, decoded once per URL. `CGImageSource` makes the
/// thumbnail without decoding the full bitmap — a 12MP screenshot costs a few ms and a few
/// hundred KB, not a 48MB decode per card per layout pass.
struct AttachmentThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()

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
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let made = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let made { cache.setObject(made, forKey: url as NSURL) }
        return made
    }
}

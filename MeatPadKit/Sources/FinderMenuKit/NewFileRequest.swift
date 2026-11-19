import Foundation

/// `meatpad://new-file?dir=<absolute path>&ext=<extension>`: what the Finder Sync extension
/// sends and the app acts on. Anything else (relative `dir`, an `ext` that is not already
/// clean, the wrong host) does not parse, so a hostile URL can never name a path to write.
public struct NewFileRequest: Equatable, Sendable {
    public static let scheme = "meatpad"
    public static let host = "new-file"

    public let directory: URL
    public let fileExtension: String

    public init?(directory: URL, fileExtension: String) {
        guard directory.isFileURL, directory.path.hasPrefix("/"),
              FinderMenuConfig.sanitizedExtension(fileExtension) == fileExtension
        else { return nil }
        self.directory = URL(fileURLWithPath: directory.path, isDirectory: true)
        self.fileExtension = fileExtension
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == Self.host,
              let items = components.queryItems,
              let dir = items.first(where: { $0.name == "dir" })?.value,
              let ext = items.first(where: { $0.name == "ext" })?.value
        else { return nil }
        guard dir.hasPrefix("/") else { return nil }
        self.init(directory: URL(fileURLWithPath: dir, isDirectory: true), fileExtension: ext)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        // Encoded by hand: `queryItems` leaves `&`, `=` and `+` alone, and a folder named
        // "a&b=c" would then split into extra parameters.
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "dir", value: Self.encode(directory.path)),
            URLQueryItem(name: "ext", value: Self.encode(fileExtension)),
        ]
        // Scheme, host and an encoded query always make a URL; the fallback is unreachable.
        return components.url ?? URL(string: "\(Self.scheme)://\(Self.host)")!
    }

    private static let valueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#;%")
        return set
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
    }
}

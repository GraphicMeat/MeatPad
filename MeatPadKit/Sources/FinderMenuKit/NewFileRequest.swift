import Foundation

/// `meatpad://new-file?dir=<absolute path>&ext=<extension>[&token=<finder.token>]`: what the
/// Finder Sync extension sends and the app acts on. Anything else (relative `dir`, a `dir`
/// with a `..` component, an `ext` that is not already clean, the wrong host) does not parse,
/// so a hostile URL can never name a path to write.
///
/// Parsing is not trust: the scheme is open to any app or web page. Only a request carrying
/// this install's token (`FinderToken`) may be acted on without asking — see `trust`.
public struct NewFileRequest: Equatable, Sendable {
    public static let scheme = "meatpad"
    public static let host = "new-file"

    public let directory: URL
    public let fileExtension: String
    /// The sender's `finder.token`, or nil when it sent none (an empty one counts as none).
    public let token: String?

    public init?(directory: URL, fileExtension: String, token: String? = nil) {
        guard directory.isFileURL,
              let path = Self.standardizedPath(directory.path),
              FinderMenuConfig.sanitizedExtension(fileExtension) == fileExtension
        else { return nil }
        self.directory = URL(fileURLWithPath: path, isDirectory: true)
        self.fileExtension = fileExtension
        self.token = token?.isEmpty == false ? token : nil
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == Self.host,
              let items = components.queryItems,
              let dir = items.first(where: { $0.name == "dir" })?.value,
              let ext = items.first(where: { $0.name == "ext" })?.value
        else { return nil }
        guard dir.hasPrefix("/"), Self.standardizedPath(dir) != nil else { return nil }
        let token = items.first(where: { $0.name == "token" })?.value
        self.init(directory: URL(fileURLWithPath: dir, isDirectory: true), fileExtension: ext, token: token)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        // Encoded by hand: `queryItems` leaves `&`, `=` and `+` alone, and a folder named
        // "a&b=c" would then split into extra parameters.
        var items = [
            URLQueryItem(name: "dir", value: Self.encode(directory.path)),
            URLQueryItem(name: "ext", value: Self.encode(fileExtension)),
        ]
        if let token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: Self.encode(token)))
        }
        components.percentEncodedQueryItems = items
        // Scheme, host and an encoded query always make a URL; the fallback is unreachable.
        return components.url ?? URL(string: "\(Self.scheme)://\(Self.host)")!
    }

    /// `.trusted` only when this request carries `expectedToken` and that token is usable;
    /// anything else must be confirmed by the user before a file is created.
    public func trust(expectedToken: String?) -> FinderRequestTrust {
        guard FinderToken.isUsable(expectedToken), let token, token == expectedToken else {
            return .needsConfirmation
        }
        return .trusted
    }

    /// An absolute path with "." and empty components dropped (so `/a/./b//c/` is `/a/b/c`),
    /// or nil when it is relative or has a `..` component. A name that merely contains dots
    /// (`..b`, `b..`, `...`) is an ordinary folder name. Bytes are kept as given: no Unicode
    /// normalisation, no symlink resolution.
    private static func standardizedPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !parts.contains("..") else { return nil }
        return "/" + parts.joined(separator: "/")
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

/// Whether a `NewFileRequest` may be acted on silently (see `NewFileRequest.trust`).
public enum FinderRequestTrust: Equatable, Sendable {
    case trusted
    case needsConfirmation
}

import Foundation

public enum AttachmentError: Error, Equatable {
    case invalidExtension(String)
}

/// Files that belong to a card or a note, kept beside the store that owns the record:
/// `<root>/<ownerID>/<uuid>.<ext>`. Deliberately dumb — it knows owners as UUIDs and files
/// as names, and nothing about images. The owning store keeps the name list on the record,
/// so this never has to scan a directory to answer "what does this card have".
public struct AttachmentStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Lowercase alphanumerics, 1–8 characters: an extension and never a path.
    public static func validatedExtension(_ ext: String) throws -> String {
        let lowered = ext.lowercased()
        guard (1...8).contains(lowered.count),
              lowered.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw AttachmentError.invalidExtension(ext) }
        return lowered
    }

    /// Writes `data` under a fresh name and returns it.
    public func add(_ data: Data, ext: String, to owner: UUID) throws -> String {
        let name = "\(UUID().uuidString).\(try Self.validatedExtension(ext))"
        try write(data, name: name, to: owner)
        return name
    }

    /// Writes under a name the caller already holds — how an undo puts a removed file back
    /// without the record's name list changing.
    public func write(_ data: Data, name: String, to owner: UUID) throws {
        try FileManager.default.createDirectory(at: directory(for: owner), withIntermediateDirectories: true)
        try data.write(to: url(name, for: owner), options: .atomic)
    }

    public func remove(_ name: String, from owner: UUID) throws {
        let target = url(name, for: owner)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    public func removeAll(for owner: UUID) throws {
        let dir = directory(for: owner)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    public func url(_ name: String, for owner: UUID) -> URL {
        // `name` can come from a hand-edited or corrupt sidecar; every other method routes
        // through here, so pinning it to a bare filename is what keeps all of them inside
        // the owner's own directory.
        directory(for: owner).appendingPathComponent((name as NSString).lastPathComponent)
    }

    public func data(_ name: String, for owner: UUID) -> Data? {
        try? Data(contentsOf: url(name, for: owner))
    }

    private func directory(for owner: UUID) -> URL {
        rootURL.appendingPathComponent(owner.uuidString, isDirectory: true)
    }
}

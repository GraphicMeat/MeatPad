import Foundation
import MeatPadKit

/// The user's file-tree context-menu choices (Settings ▸ File Tree). One shared instance: the
/// menu builder reads it each time a menu opens, so a change applies to the very next
/// right-click in every project window.
///
/// Stored as JSON *text* under one UserDefaults key — text rather than `Data` so a launch
/// argument (`-fileTree.menu '{…}'`) can seed it, which the UI tests rely on.
@MainActor
final class FileTreeMenuSettings: ObservableObject {
    static let shared = FileTreeMenuSettings()
    static let defaultsKey = "fileTree.menu"

    @Published var config: FileTreeMenuConfig {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = FileTreeMenuConfig.decode(defaults.string(forKey: Self.defaultsKey).map { Data($0.utf8) })
    }

    func reset() { config = FileTreeMenuConfig() }

    private func save() {
        guard let data = try? config.encoded() else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.defaultsKey)
    }
}

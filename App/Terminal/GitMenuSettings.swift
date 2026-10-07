import Foundation
import MeatPadKit

/// The terminal header's Git menu (Settings ▸ Terminal). One shared instance: every project
/// window's header reads it, so a change shows in the very next menu that opens.
///
/// Stored as JSON *text* under one UserDefaults key — text rather than `Data` so a launch
/// argument (`-terminal.gitMenu '{…}'`) can seed it, which the UI tests rely on.
@MainActor
final class GitMenuSettings: ObservableObject {
    static let shared = GitMenuSettings()
    static let defaultsKey = "terminal.gitMenu"

    @Published var config: GitMenuConfig {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = GitMenuConfig.decode(defaults.string(forKey: Self.defaultsKey).map { Data($0.utf8) })
    }

    func reset() { config = .defaults }

    private func save() {
        guard let data = try? config.encoded() else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.defaultsKey)
    }
}

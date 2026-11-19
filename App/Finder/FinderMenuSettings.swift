import Foundation
import MeatPadKit

/// The Finder right-click menu's settings (Settings ▸ Finder). The Finder Sync extension reads
/// the same `finder.menu` default straight from this app's domain each time Finder builds a
/// menu, so a change reaches the very next right-click; the app reads `afterCreate` from here
/// when a request arrives.
///
/// Stored as JSON *text* under one UserDefaults key — text rather than `Data` so a launch
/// argument (`-finder.menu '{…}'`) can seed it, which the UI tests rely on.
@MainActor
final class FinderMenuSettings: ObservableObject {
    static let shared = FinderMenuSettings()
    static let defaultsKey = FinderMenuConfig.defaultsKey

    @Published var config: FinderMenuConfig {
        didSet { save() }
    }

    /// The per-install secret the extension adds to each `meatpad://new-file` URL, so the app
    /// can tell its own extension's clicks from a request any app or web page could send.
    /// Created once and kept in `finder.token`, where the extension reads it. A usable value
    /// already there is never rewritten — including one from a launch argument
    /// (`-finder.token <64 hex>`), which the UI tests use to pin it without persisting it.
    let token: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = FinderMenuConfig.decode(defaults.string(forKey: Self.defaultsKey).map { Data($0.utf8) })
        let stored = defaults.string(forKey: FinderToken.defaultsKey)
        if let stored, FinderToken.isUsable(stored) {
            token = stored
        } else {
            let fresh = FinderToken.generate()
            defaults.set(fresh, forKey: FinderToken.defaultsKey)
            token = fresh
        }
    }

    func reset() { config = FinderMenuConfig() }

    private func save() {
        guard let data = try? config.encoded() else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.defaultsKey)
    }
}

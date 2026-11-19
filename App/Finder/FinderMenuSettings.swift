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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        config = FinderMenuConfig.decode(defaults.string(forKey: Self.defaultsKey).map { Data($0.utf8) })
    }

    func reset() { config = FinderMenuConfig() }

    private func save() {
        guard let data = try? config.encoded() else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.defaultsKey)
    }
}

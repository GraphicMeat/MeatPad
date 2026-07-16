import Foundation
import MeatPadKit

/// App-wide state: the note store and the active theme (persisted across launches as a
/// theme id string in UserDefaults).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let noteStore: NoteStore
    @Published var theme: Theme {
        didSet { UserDefaults.standard.set(theme.id, forKey: Self.themeDefaultsKey) }
    }

    private static let themeDefaultsKey = "themeID"

    private init() {
        do {
            noteStore = try NoteStore(rootURL: NoteStore.defaultRoot())
        } catch {
            fatalError("MeatPad couldn't set up its notes folder at \(NoteStore.defaultRoot().path): \(error)")
        }
        let savedID = UserDefaults.standard.string(forKey: Self.themeDefaultsKey)
        theme = savedID.flatMap { id in BuiltinThemes.all.first { $0.id == id } } ?? BuiltinThemes.defaultDark
    }
}

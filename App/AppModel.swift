import Foundation
import SwiftUI
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

    /// Bridge to SwiftUI's `openWindow` action, captured once from `MeatPadApp.body`
    /// (which runs before AppKit's `applicationDidFinishLaunching`) so the
    /// `NSApplicationDelegateAdaptor` can open windows during launch restore, where no
    /// SwiftUI environment is otherwise reachable.
    var openWindowAction: OpenWindowAction?

    private var openNoteIDs: [UUID] = []
    private var browserOpen = false
    private let sessionDebouncer = Debouncer(delay: 0.5)

    private static let themeDefaultsKey = "themeID"

    /// Sibling of the Notes directory (not inside it, so it's never mistaken for a note).
    private static var sessionURL: URL {
        NoteStore.defaultRoot().deletingLastPathComponent().appendingPathComponent("session.json")
    }

    private init() {
        do {
            noteStore = try NoteStore(rootURL: NoteStore.defaultRoot())
        } catch {
            fatalError("MeatPad couldn't set up its notes folder at \(NoteStore.defaultRoot().path): \(error)")
        }
        let savedID = UserDefaults.standard.string(forKey: Self.themeDefaultsKey)
        theme = savedID.flatMap { id in BuiltinThemes.all.first { $0.id == id } } ?? BuiltinThemes.defaultDark
    }

    // MARK: - Session tracking

    func noteWindowDidAppear(_ id: UUID) {
        if !openNoteIDs.contains(id) { openNoteIDs.append(id) }
        scheduleSessionSave()
    }

    func noteWindowDidDisappear(_ id: UUID) {
        openNoteIDs.removeAll { $0 == id }
        scheduleSessionSave()
    }

    func browserWindowDidAppear() {
        browserOpen = true
        scheduleSessionSave()
    }

    func browserWindowDidDisappear() {
        browserOpen = false
        scheduleSessionSave()
    }

    /// Called from `applicationDidFinishLaunching`: reopens whatever was open at last
    /// quit, dropping ids for notes that no longer exist on disk. Falls back to one
    /// fresh note when there's nothing valid to restore, so launch never shows zero
    /// windows.
    func restoreSession() {
        guard let openWindowAction else { return }
        let state = SessionState.load(from: Self.sessionURL)
        let idsToRestore = (state?.openNoteIDs ?? []).filter { id in noteStore.notes.contains { $0.id == id } }

        guard !idsToRestore.isEmpty || state?.browserOpen == true else {
            if let note = try? noteStore.createNote() {
                openWindowAction(value: note.id)
            }
            return
        }

        for id in idsToRestore { openWindowAction(value: id) }
        if state?.browserOpen == true { openWindowAction(id: "all-notes") }
    }

    /// Immediate, non-debounced write — used on `applicationWillTerminate` so the last
    /// window open/close right before quit isn't lost to the pending debounce.
    func saveSessionNow() {
        sessionDebouncer.cancel()
        try? SessionState(openNoteIDs: openNoteIDs, browserOpen: browserOpen).save(to: Self.sessionURL)
    }

    private func scheduleSessionSave() {
        sessionDebouncer.call { [weak self] in self?.saveSessionNow() }
    }
}

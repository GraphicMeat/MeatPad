import Foundation
import AppKit
import MeatPadKit

/// Owns one open note's editing state: loads contents on appear, debounces autosave
/// (1s) on every edit, and flushes immediately on window close / app resign-active /
/// app termination so nothing is lost. No dirty markers, no save dialogs — the file on
/// disk is always the source of truth. Closing a window whose note is empty discards
/// the note entirely instead of flushing (see `flushOrDiscardOnClose`).
@MainActor
final class NoteEditorViewModel: ObservableObject {
    let noteID: UUID
    // ponytail: `exists` only re-checks on the next save/setLanguage attempt (both
    // already guard on the store's notFound error), not via a live subscription to
    // store.notes. An idle window whose note gets trashed elsewhere won't flip to the
    // empty state until the user next types or moves the cursor. Add a Combine sink on
    // store.$notes here if that idle case needs to be instant.
    @Published private(set) var exists: Bool
    @Published var text: String = ""
    @Published private(set) var languageOverride: String?
    @Published private(set) var title: String = String(localized: "New Note")

    private let store: NoteStore
    private let debouncer = Debouncer(delay: 1)
    private let frameDebouncer = Debouncer(delay: 0.5)
    @Published private(set) var cursor: Int = 0
    /// One-shot "scroll to + select this range" target for the editor (search-result
    /// jumps). Mirrors `ProjectViewModel.revealTarget`: stays set until `CodeEditor`
    /// confirms it applied it via `revealConsumed`, so a reveal into a not-yet-rendered
    /// editor can never be lost to render-pass timing.
    @Published private(set) var revealTarget: RevealTarget?
    private var loaded = false
    private var windowObservers: [NSObjectProtocol] = []

    /// `languageOverride` wins; otherwise re-detected live from contents. Detection is
    /// cheap enough to run on every keystroke rather than debouncing it separately.
    var language: Language? {
        if let languageOverride { return Languages.byID(languageOverride) }
        return LanguageDetector.detect(filename: nil, contents: text)
    }

    init(noteID: UUID, store: NoteStore) {
        self.noteID = noteID
        self.store = store
        self.exists = store.notes.contains { $0.id == noteID }
        // Eager, not deferred to onAppear: CodeEditor reads `text`/`cursor` at its very
        // first SwiftUI render (before onAppear can fire) to restore the initial caret
        // position, so those need to be populated synchronously here. load() is a cheap
        // local read; the redundant onAppear call below stays as a no-op safety net.
        load()
    }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Loads the note's contents once. Called eagerly from init (see above); guarded by
    /// `loaded` so a repeat call from onAppear is a no-op.
    func load() {
        guard !loaded, exists else { return }
        loaded = true
        guard let note = store.notes.first(where: { $0.id == noteID }) else {
            exists = false
            return
        }
        languageOverride = note.languageID
        title = note.title
        cursor = note.cursor
        text = (try? store.contents(of: noteID)) ?? ""
    }

    func textDidChange(_ newText: String) {
        text = newText
        title = Note.title(fromContents: newText)
        scheduleSave()
    }

    func cursorDidChange(_ location: Int) {
        // No scheduleSave: every caret move (even just opening/clicking a note) would
        // otherwise bump `modified`, rewrite the file, and re-sort the recency lists.
        // The cursor rides along on the next content save/flush instead.
        cursor = location
    }

    /// Requests a one-shot scroll-to + select of `range` in this note's editor. `range`
    /// is a whole-document UTF-16 `NSRange`. A fresh token marks a new request.
    func reveal(range: NSRange) {
        revealTarget = RevealTarget(token: UUID(), range: range)
    }

    /// Called by the editor after it actually scrolled/selected the target. Token-guarded
    /// so a slow consumer can't clear a newer target.
    func revealConsumed(token: UUID) {
        if revealTarget?.token == token { revealTarget = nil }
    }

    func setLanguage(_ id: String?) {
        languageOverride = id
        do {
            try store.setLanguage(id: noteID, languageID: id)
        } catch {
            // Note was trashed elsewhere while this window was open. Fall back to the
            // empty state instead of crashing.
            exists = false
        }
    }

    /// Flushes any pending autosave immediately. Called on window close, app
    /// resign-active, and app termination — the moments an in-flight debounce could
    /// otherwise lose the last second of edits.
    func flush() {
        debouncer.flush()
        frameDebouncer.flush()
    }

    /// Hooks into this note's hosting window: restores the persisted frame once, then
    /// observes close (flush pending autosave) and move/resize (persist the new frame,
    /// debounced — window drags fire these notifications continuously).
    ///
    /// Last-attach-wins: a shared VM can outlive its standalone window (the browser's
    /// detail pane keeps it alive after that window closes), so a reopen must replace
    /// any observers left from the previous window rather than bailing out. WindowGroup
    /// dedup guarantees at most one live NoteWindow per note, so there's never a second
    /// window whose observers this would clobber.
    func attach(window: NSWindow) {
        detachWindowObservers()

        if let saved = store.notes.first(where: { $0.id == noteID })?.windowFrame {
            let frame = NSRectFromString(saved)
            // Only restore if the saved rect still lands on a connected screen — e.g. the
            // monitor it was last positioned on got disconnected. Otherwise skip setFrame
            // entirely and let the system choose default placement (re-saving that default
            // frame on the next move/resize heals the sidecar instead of persisting the
            // off-screen rect forever).
            let bestScreen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) }
            if !frame.isEmpty, let bestScreen {
                window.setFrame(window.constrainFrameRect(frame, to: bestScreen), display: true)
            }
        }

        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushOrDiscardOnClose()
                // The window is gone; drop its observers now instead of letting them
                // linger while the VM lives on in another surface.
                self?.detachWindowObservers()
            }
        })
        // didResize (not didEndLiveResize): also catches non-live resizes like the zoom
        // button; the debounce absorbs the continuous stream during a live drag.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            windowObservers.append(center.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.windowFrameDidChange(window) }
            })
        }
    }

    /// Window close: a note closed with nothing in it is junk — discard it outright
    /// (trash + permanent delete; there's no content to lose) instead of keeping an
    /// untitled empty note around. Anything non-empty flushes the pending autosave as
    /// before. Empty is literal `isEmpty`: typed whitespace counts as content.
    private func flushOrDiscardOnClose() {
        guard exists, text.isEmpty else {
            flush()
            return
        }
        debouncer.cancel()
        frameDebouncer.cancel()
        try? store.trash(id: noteID)
        try? store.delete(id: noteID)
        exists = false
    }

    /// Same cleanup deinit performs, callable while the VM is still alive (deinit keeps
    /// its own inline copy: it's nonisolated and can't call into this @MainActor method).
    private func detachWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private func windowFrameDidChange(_ window: NSWindow?) {
        guard exists else { return }
        frameDebouncer.call { [weak self, weak window] in
            guard let self, let window else { return }
            // Best-effort: a frame that fails to persist just falls back to default
            // placement next launch; never worth surfacing.
            try? self.store.setWindowFrame(id: self.noteID, frame: NSStringFromRect(window.frame))
        }
    }

    private func scheduleSave() {
        guard exists else { return }
        debouncer.call { [weak self] in self?.performSave() }
    }

    private func performSave() {
        do {
            try store.save(id: noteID, contents: text, cursor: cursor)
        } catch {
            // Trashed elsewhere while this window was open — stop trying to save it.
            exists = false
        }
    }
}

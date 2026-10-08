import CoreServices
import Foundation

/// Watches `root` recursively via FSEvents and fires `onChange` (debounced, on main) with the
/// paths that changed whenever something under it does. Paths with a component in `ignoring`
/// (e.g. `.git` churn during a checkout) are dropped, and a burst made only of those never
/// fires. Backs the project tree's auto-rescan.
@MainActor
public final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let debouncer: Debouncer
    private var onChange: (([String]) -> Void)?
    private let ignoring: Set<String>
    private var pendingPaths: Set<String> = []

    public init(root: URL, debounce: TimeInterval = 0.3, ignoring: Set<String> = [], onChange: @escaping ([String]) -> Void) {
        self.debouncer = Debouncer(delay: debounce)
        self.ignoring = ignoring
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
            watcher.handleEvent(paths)
        }

        let pathsToWatch = [root.path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            /* latency */ 0,
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    private func handleEvent(_ paths: [String]) {
        let relevant = paths.filter { path in
            ignoring.isEmpty || !URL(fileURLWithPath: path).pathComponents.contains(where: ignoring.contains)
        }
        guard !relevant.isEmpty else { return }
        pendingPaths.formUnion(relevant)
        debouncer.call { [weak self] in
            guard let self else { return }
            let changed = Array(self.pendingPaths)
            self.pendingPaths.removeAll()
            self.onChange?(changed)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        debouncer.cancel()
        pendingPaths.removeAll()
        onChange = nil
    }

    deinit {
        // deinit runs nonisolated; touch the raw stream directly rather than routing
        // through the actor-isolated stop()/debouncer.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

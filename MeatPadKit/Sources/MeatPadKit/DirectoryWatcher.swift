import CoreServices
import Foundation

/// Watches `root` recursively via FSEvents and fires `onChange` (debounced, on main)
/// whenever anything under it changes. Backs the project tree's auto-rescan.
@MainActor
public final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let debouncer: Debouncer
    private var onChange: (() -> Void)?

    public init(root: URL, debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.debouncer = Debouncer(delay: debounce)
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handleEvent()
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

    private func handleEvent() {
        debouncer.call { [weak self] in
            self?.onChange?()
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        debouncer.cancel()
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

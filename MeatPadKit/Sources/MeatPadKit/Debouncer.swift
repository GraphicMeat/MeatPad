import Foundation

/// Coalesces bursts of calls into a single action fired `delay` seconds after the last
/// call. Used for autosave: keystrokes reset the timer, `flush()` forces an immediate
/// save (window close, app resign-active, app termination).
@MainActor
public final class Debouncer {
    private let delay: TimeInterval
    private var task: Task<Void, Never>?
    private var pendingAction: (() -> Void)?

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    /// Schedules `action`, canceling any not-yet-fired action from a previous call.
    public func call(_ action: @escaping () -> Void) {
        task?.cancel()
        pendingAction = action
        task = Task { [weak self, delay] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    /// Fires the pending action immediately, if any.
    public func flush() {
        guard pendingAction != nil else { return }
        task?.cancel()
        task = nil
        fire()
    }

    /// Drops the pending action without firing it.
    public func cancel() {
        task?.cancel()
        task = nil
        pendingAction = nil
    }

    private func fire() {
        let action = pendingAction
        pendingAction = nil
        task = nil
        action?()
    }
}

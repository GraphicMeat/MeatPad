#if DEBUG
import AppKit

/// Debug-only scroll harness. MEATPAD_SCROLL_TEST=<ticks per pass> scrolls the editor down by
/// MEATPAD_SCROLL_STEP points (default 40) every 1/60s, back to the top, then repeats —
/// logging per pass how long the main thread spent in the scroll observer and in span paints.
/// Pass 1 is first-visit, pass 2 is revisit. Quits when done.
@MainActor
final class ScrollProbe {
    static let shared = ScrollProbe()
    var observerSeconds = 0.0
    var paintCalls = 0
    var paintChars = 0
    var paintSeconds = 0.0
    private var started = false

    func startIfEnabled(scrollView: NSScrollView, ready: @escaping () -> Bool) {
        let env = ProcessInfo.processInfo.environment
        guard !started, let raw = env["MEATPAD_SCROLL_TEST"], let ticks = Int(raw) else { return }
        started = true
        let step = env["MEATPAD_SCROLL_STEP"].flatMap(Double.init) ?? 40
        var pass = 0
        var tick = 0
        var last = CFAbsoluteTimeGetCurrent()
        var gaps: [Double] = []
        var work: [Double] = []
        var waiting = true
        let startFraction = env["MEATPAD_SCROLL_START"].flatMap(Double.init) ?? 0
        func jumpToStart() {
            let clip = scrollView.contentView
            let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: maxY * startFraction))
            scrollView.reflectScrolledClipView(clip)
        }
        var waited = 0.0
        NSLog("[SCROLLPROBE] armed: \(ticks) ticks x \(step)pt per pass")
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                defer { last = now }
                if waiting {
                    waited += 1.0 / 60
                    guard ready() || waited > 20 else { return }
                    waiting = false
                    NSLog("[SCROLLPROBE] ready, starting pass 1")
                    self.reset(); gaps = []; tick = 0
                    jumpToStart()
                    return
                }
                gaps.append((now - last) * 1000)
                let clip = scrollView.contentView
                let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
                let workStart = CFAbsoluteTimeGetCurrent()
                clip.scroll(to: NSPoint(x: 0, y: min(maxY, clip.bounds.origin.y + step)))
                scrollView.reflectScrolledClipView(clip)
                work.append((CFAbsoluteTimeGetCurrent() - workStart) * 1000)
                tick += 1
                if tick % 10 == 0 {
                    NSLog(String(format: "[SCROLLPROBE] pass %d tick %d observer=%.0fms paintCalls=%d paint=%.0fms", pass + 1, tick,
                                 self.observerSeconds * 1000, self.paintCalls, self.paintSeconds * 1000))
                }
                guard tick >= ticks else { return }

                let sortedWork = work.sorted()
                NSLog(String(format: "[SCROLLPROBE] pass %d scroll-call work: total=%.0fms mean=%.1fms p99=%.0fms", pass + 1,
                             work.reduce(0, +), work.reduce(0, +) / Double(max(1, work.count)),
                             sortedWork[min(sortedWork.count - 1, Int(Double(sortedWork.count) * 0.99))]))
                work = []
                let sorted = gaps.sorted()
                let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
                NSLog(String(format: "[SCROLLPROBE] pass %d: ticks=%d y=%.0f/%.0f observer=%.0fms paintCalls=%d paintChars=%d paint=%.0fms gap p99=%.0fms max=%.0fms over50ms=%d",
                             pass + 1, ticks, clip.bounds.origin.y, maxY, self.observerSeconds * 1000, self.paintCalls,
                             self.paintChars, self.paintSeconds * 1000, p99, sorted.last ?? 0, gaps.filter { $0 > 50 }.count))
                pass += 1
                if pass >= 2 {
                    timer.invalidate()
                    NSLog("[SCROLLPROBE] DONE")
                    NSApp.terminate(nil)
                    return
                }
                jumpToStart()
                self.reset(); gaps = []; work = []; tick = 0
            }
        }
    }

    private func reset() {
        observerSeconds = 0; paintCalls = 0; paintChars = 0; paintSeconds = 0
    }
}
#endif

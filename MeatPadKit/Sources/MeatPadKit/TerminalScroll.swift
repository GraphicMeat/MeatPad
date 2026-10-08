import Foundation

/// Turns a stream of wheel/trackpad deltas into whole terminal lines. A trackpad sends many
/// sub-line deltas (and a momentum tail); truncating each one (as SwiftTerm does) either
/// scrolls a full line per event or nothing, so the fraction is carried to the next event.
public struct TerminalScrollAccumulator: Equatable, Sendable {
    private var remainder = 0.0

    public init() {}

    /// - Parameters:
    ///   - delta: the event's scroll distance, positive = toward older output.
    ///   - unit: how much of `delta` is one line (the line height for pixel deltas, 1 for lines).
    /// - Returns: whole lines to scroll, same sign as `delta`; the rest stays in the accumulator.
    public mutating func lines(delta: Double, unit: Double) -> Int {
        guard unit > 0, delta.isFinite else { return 0 }
        remainder += delta / unit
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return Int(whole)
    }

    public mutating func reset() { remainder = 0 }
}

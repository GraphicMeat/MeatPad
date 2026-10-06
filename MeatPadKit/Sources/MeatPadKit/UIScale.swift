import Foundation

/// The project window's ⌘+ / ⌘− zoom: a ladder of scale factors, so each press is a visible,
/// predictable step (the way a browser's zoom works) instead of an arbitrary increment.
public enum UIScale {
    public static let actualSize = 1.0
    public static let ladder: [Double] = [0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    public static let minimum = ladder.first!
    public static let maximum = ladder.last!

    /// The next rung above `scale`; an off-ladder value (a hand-edited preference) goes to the
    /// nearest rung above it.
    public static func zoomedIn(from scale: Double) -> Double {
        let current = sanitized(scale)
        return ladder.first { $0 > current + 0.0001 } ?? maximum
    }

    public static func zoomedOut(from scale: Double) -> Double {
        let current = sanitized(scale)
        return ladder.last { $0 < current - 0.0001 } ?? minimum
    }

    /// Anything that isn't a usable scale (NaN, zero, negative) is actual size; the rest is clamped.
    public static func sanitized(_ scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return actualSize }
        return min(max(scale, minimum), maximum)
    }

    public static func label(_ scale: Double) -> String {
        "\(Int((sanitized(scale) * 100).rounded()))%"
    }
}

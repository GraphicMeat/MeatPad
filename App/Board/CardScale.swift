import SwiftUI

/// How much bigger than normal a card draws. An environment value rather than a parameter:
/// presentation mode scales a whole column of cards and the present overlay scales one, and
/// neither wants to thread a number through every row.
private struct CardScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var cardScale: CGFloat {
        get { self[CardScaleKey.self] }
        set { self[CardScaleKey.self] = newValue }
    }
}

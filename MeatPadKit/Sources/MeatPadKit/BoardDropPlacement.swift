import Foundation
import CoreGraphics

/// Where a drop over a board column would land. The arithmetic lives here, away from SwiftUI,
/// because "which slot did the pointer mean" is the part that was wrong on screen and is the
/// only part a test can see.
public enum BoardDropPlacement: Equatable, Sendable {
    /// Card reorder: the slot among the visible rows, `0...rows.count`.
    case insert(Int)
    /// An image dropped on this card.
    case attach(UUID)
    /// An image dropped on bare column space.
    case newCard
}

/// One visible card row, in the column's coordinate space.
public struct BoardDropRow: Equatable, Sendable {
    public let id: UUID
    public let frame: CGRect

    public init(id: UUID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

public extension BoardDropPlacement {
    /// The slot before the first row still more than half below the pointer; past the last
    /// row appends. Half-covered is the boundary users expect from every list that reorders.
    static func forCard(at y: CGFloat, rows: [BoardDropRow]) -> BoardDropPlacement {
        .insert(rows.firstIndex { y < $0.frame.midY } ?? rows.count)
    }

    /// An image belongs to the card it is actually over; bare space between or beside the
    /// rows becomes a new card rather than attaching to whichever row is nearest.
    static func forImage(at point: CGPoint, rows: [BoardDropRow]) -> BoardDropPlacement {
        rows.first { $0.frame.contains(point) }.map { .attach($0.id) } ?? .newCard
    }

    /// A dropped file names its own card; a pasted or browser image has no name to use.
    static func newCardTitle(fileName: String?, fallback: String) -> String {
        let trimmed = (fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (trimmed as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? fallback : stem
    }
}

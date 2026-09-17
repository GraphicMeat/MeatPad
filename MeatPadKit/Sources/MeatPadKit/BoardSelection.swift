import Foundation

/// Which board cards are selected. Finder rules: click replaces, ⌘-click toggles, ⇧-click
/// extends from the last plain/⌘ click across the board's visible order (columns left to
/// right, cards top to bottom).
public struct BoardSelection: Equatable, Sendable {
    public enum Click: Sendable { case plain, toggle, extend }
    public private(set) var ids: Set<UUID> = []
    public private(set) var anchor: UUID?

    public init() {}

    public mutating func click(_ id: UUID, _ kind: Click, order: [UUID]) {
        switch kind {
        case .plain:
            select(id)
        case .toggle:
            if ids.remove(id) == nil { ids.insert(id) }
            anchor = id
        case .extend:
            guard let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id)
            else { return select(id) }
            ids.formUnion(order[min(a, b)...max(a, b)])
        }
    }

    public mutating func select(_ id: UUID) { ids = [id]; anchor = id }
    public mutating func selectAll(_ all: [UUID]) { ids = Set(all); anchor = all.first }
    public mutating func clear() { ids = []; anchor = nil }

    public mutating func prune(keeping existing: Set<UUID>) {
        ids.formIntersection(existing)
        if let a = anchor, !existing.contains(a) { anchor = nil }
    }

    public func ordered(_ order: [UUID]) -> [UUID] { order.filter(ids.contains) }
}

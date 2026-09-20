import Foundation

/// How a sidebar list (boards, note folders) orders its rows.
public enum SidebarSort: String, CaseIterable, Sendable {
    /// Whatever order the underlying array already holds — a user drag order for boards,
    /// or `NoteStore.folders`' own order.
    case manual
    /// `localizedStandardCompare` — the Finder's rule, so "Item 2" sorts before "Item 10"
    /// and case/diacritics don't split otherwise-identical names apart.
    case name
    /// Oldest first, by the item's own creation date.
    case created
}

/// Sorts a sidebar list by `SidebarSort` without the list's own type knowing about sorting —
/// `Board` and note folder names have nothing in common except a name and an optional
/// creation date, which is all this needs.
public enum SidebarSorter {
    /// `created` sorts on `(date, originalIndex)` rather than bare `sort(by:)`: Swift's sort
    /// is not guaranteed stable, and two items with the same (or missing) date must keep
    /// their original relative order rather than jitter on every re-sort.
    public static func sort<T>(_ items: [T], by mode: SidebarSort,
                                name: (T) -> String, created: (T) -> Date?) -> [T] {
        switch mode {
        case .manual:
            return items
        case .name:
            return items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case .created:
            return items.enumerated()
                .sorted { ((created($0.element) ?? .distantPast), $0.offset) < ((created($1.element) ?? .distantPast), $1.offset) }
                .map(\.element)
        }
    }
}

import Foundation

/// One line of the flattened grouped-results list: a file header or one of its matches.
/// A single flat list with explicit ids keeps `LazyVStack` row identity stable across
/// fold/unfold (nested `ForEach` + conditional left stale blank rows behind).
public struct MatchListRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case header(Int)
        case match(Int, Int)
    }

    public let id: String
    public let kind: Kind

    public static func flatten(_ groups: [FileMatchGroup], collapsed: Set<URL>) -> [MatchListRow] {
        var rows: [MatchListRow] = []
        for (g, group) in groups.enumerated() {
            rows.append(MatchListRow(id: "h:" + group.file.path, kind: .header(g)))
            if collapsed.contains(group.file) { continue }
            for m in group.matches.indices {
                rows.append(MatchListRow(id: "m:\(group.file.path):\(m)", kind: .match(g, m)))
            }
        }
        return rows
    }
}

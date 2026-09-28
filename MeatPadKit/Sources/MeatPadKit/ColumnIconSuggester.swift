import Foundation

/// An emoji for a column that has none of its own. Only ever a suggestion: nothing here
/// writes to a column, because a board full of columns that sprouted icons nobody chose is
/// worse than one that shows none.
public enum ColumnIconSuggester {

    /// Word sets against the column name's words, first rule to match wins — so the specific
    /// ones ("blocked") sit above the general ("in progress"). English only: a column name
    /// is the user's own words, and a name no rule knows just gets no suggestion.
    private static let rules: [(words: Set<String>, emoji: String)] = [
        (["blocked", "stuck", "impeded"], "🚫"),
        (["waiting", "hold", "paused", "later", "snoozed"], "⏳"),
        (["review", "reviewing", "qa", "testing", "test", "verify", "check"], "👀"),
        (["done", "complete", "completed", "finished", "closed", "resolved"], "✅"),
        (["shipped", "released", "live", "deployed", "launched"], "🚀"),
        (["progress", "doing", "wip", "working", "active", "building"], "🚧"),
        (["bug", "bugs", "issue", "issues", "fix", "fixes"], "🐛"),
        (["idea", "ideas", "someday", "maybe", "wishlist"], "💡"),
        (["urgent", "hot", "critical", "priority"], "🔥"),
        (["inbox", "new", "incoming", "triage"], "📥"),
        (["draft", "drafts", "writing"], "✍️"),
        (["backlog", "icebox"], "🗂"),
        (["archive", "archived"], "📦"),
        (["scheduled", "upcoming", "soon", "planned", "next"], "🗓"),
        (["todo", "queue", "open"], "📋"),
    ]

    /// The keyword rule's emoji for `name`, or nil when no rule knows any of its words.
    public static func emoji(forName name: String) -> String? {
        var words = Set(name.lowercased().split { !$0.isLetter }.map(String.init))
        // "To Do" and "To-Do" are the same column as "Todo".
        if name.lowercased().filter(\.isLetter) == "todo" { words.insert("todo") }
        return rules.first { !$0.words.isDisjoint(with: words) }?.emoji
    }
}

import Foundation

/// Static reserved-word tables used for keyword completion. Language-specific
/// and hand-maintained rather than derived from `GrammarRegistry` — grammars
/// describe syntax highlighting scopes, not a flat completable word list.
public enum LanguageKeywords {

    /// Reserved words and top builtins for `languageID`, sorted and deduped.
    /// Returns `[]` for languages where keyword completion is meaningless
    /// (markdown, json, yaml, html, css — prose/data/markup, not a keyword
    /// grammar) and for any unrecognized id.
    public static func keywords(for languageID: String) -> [String] {
        table[languageID] ?? []
    }

    private static let jsTypeScript: [String] = [
        "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
        "false", "finally", "for", "function", "if", "implements", "import", "in",
        "instanceof", "interface", "let", "new", "null", "of", "package", "private",
        "protected", "public", "return", "static", "super", "switch", "this", "throw",
        "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
        // TypeScript-specific
        "abstract", "as", "asserts", "declare", "from", "infer", "is", "keyof",
        "module", "namespace", "never", "readonly", "require", "type", "unknown",
    ].sorted()

    private static let table: [String: [String]] = [
        "swift": [
            "actor", "as", "associatedtype", "async", "await", "break", "case",
            "catch", "class", "continue", "convenience", "default", "defer",
            "deinit", "didSet", "do", "dynamic", "else", "enum", "extension",
            "fallthrough", "false", "fileprivate", "final", "for", "func", "get",
            "guard", "if", "import", "in", "indirect", "infix", "init", "inout",
            "internal", "is", "lazy", "let", "mutating", "nil", "nonmutating",
            "open", "operator", "override", "postfix", "prefix", "private",
            "protocol", "public", "repeat", "required", "rethrows", "return",
            "self", "Self", "set", "some", "static", "struct", "subscript",
            "super", "switch", "throw", "throws", "true", "try", "typealias",
            "var", "weak", "where", "while", "willSet",
        ].sorted(),

        "javascript": jsTypeScript,
        "typescript": jsTypeScript,
        "tsx": jsTypeScript,

        "python": [
            "False", "None", "True", "and", "as", "assert", "async", "await",
            "break", "class", "continue", "def", "del", "elif", "else", "except",
            "finally", "for", "from", "global", "if", "import", "in", "is",
            "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "self",
            "try", "while", "with", "yield",
        ].sorted(),

        "rust": [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn",
            "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
            "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "Self", "static", "struct", "super", "trait", "true", "type",
            "unsafe", "use", "where", "while",
        ].sorted(),

        "go": [
            "break", "case", "chan", "const", "continue", "default", "defer",
            "else", "fallthrough", "false", "for", "func", "go", "goto", "if",
            "import", "interface", "iota", "map", "nil", "package", "range",
            "return", "select", "struct", "switch", "true", "type", "var",
        ].sorted(),

        "c": [
            "auto", "break", "case", "char", "const", "continue", "default", "do",
            "double", "else", "enum", "extern", "float", "for", "goto", "if",
            "inline", "int", "long", "NULL", "register", "restrict", "return",
            "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
            "union", "unsigned", "void", "volatile", "while",
        ].sorted(),

        "cpp": [
            "alignas", "alignof", "and", "auto", "bool", "break", "case", "catch",
            "char", "class", "const", "constexpr", "const_cast", "continue",
            "decltype", "default", "delete", "do", "double", "dynamic_cast",
            "else", "enum", "explicit", "export", "extern", "false", "float",
            "for", "friend", "goto", "if", "inline", "int", "long", "mutable",
            "namespace", "new", "noexcept", "nullptr", "operator", "private",
            "protected", "public", "register", "reinterpret_cast", "return",
            "short", "signed", "sizeof", "static", "static_cast", "struct",
            "switch", "template", "this", "throw", "true", "try", "typedef",
            "typeid", "typename", "union", "unsigned", "using", "virtual", "void",
            "volatile", "while",
        ].sorted(),

        "ruby": [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class",
            "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
            "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
            "rescue", "retry", "return", "self", "super", "then", "true",
            "undef", "unless", "until", "when", "while", "yield",
        ].sorted(),

        "bash": [
            "break", "case", "continue", "do", "done", "elif", "else", "esac",
            "exit", "export", "fi", "for", "function", "if", "in", "local",
            "read", "return", "select", "shift", "source", "then", "time",
            "trap", "unset", "until", "while",
        ].sorted(),

        // Deliberately empty: markup/prose/data languages have no keyword
        // grammar for a completer to draw from.
        "markdown": [],
        "json": [],
        "yaml": [],
        "html": [],
        "css": [],
    ]
}

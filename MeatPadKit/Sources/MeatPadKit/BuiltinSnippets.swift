import Foundation

/// Curated built-in snippets, defined in code (no bundle plumbing). IDs are fixed
/// UUIDs (not `UUID()`) so user overrides — and any future "revert to builtin" — can
/// reference a given builtin stably across launches.
public enum BuiltinSnippets {
    public static let all: [Snippet] = [
        // MARK: - Swift

        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5111-000000000001")!,
            name: "Function", trigger: "func", languageIDs: ["swift"],
            body: "func ${1:name}(${2:params}) {\n\t$0\n}"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5111-000000000002")!,
            name: "Guard", trigger: "guard", languageIDs: ["swift"],
            body: "guard ${1:condition} else {\n\t$0\n}"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5111-000000000003")!,
            name: "If let", trigger: "iflet", languageIDs: ["swift"],
            body: "if let ${1:name} = ${2:optional} {\n\t$0\n}"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5111-000000000004")!,
            name: "Struct", trigger: "struct", languageIDs: ["swift"],
            body: "struct ${1:Name} {\n\t$0\n}"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5111-000000000005")!,
            name: "Class", trigger: "class", languageIDs: ["swift"],
            body: "class ${1:Name} {\n\t$0\n}"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5111-000000000006")!,
            name: "Extension", trigger: "ext", languageIDs: ["swift"],
            body: "extension ${1:Type} {\n\t$0\n}"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5111-000000000007")!,
            name: "Test", trigger: "test", languageIDs: ["swift"],
            body: "func test${1:Name}() throws {\n\t$0\n}"
        ),

        // MARK: - JavaScript / TypeScript

        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5222-000000000001")!,
            name: "Function", trigger: "fn", languageIDs: ["javascript", "typescript"],
            body: "function ${1:name}(${2:params}) {\n\t$0\n}"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5222-000000000002")!,
            name: "Arrow function", trigger: "afn", languageIDs: ["javascript", "typescript"],
            body: "const ${1:name} = (${2:params}) => {\n\t$0\n};"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5222-000000000003")!,
            name: "Console log", trigger: "log", languageIDs: ["javascript", "typescript"],
            body: "console.log($1);$0"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5222-000000000004")!,
            name: "For loop", trigger: "for", languageIDs: ["javascript", "typescript"],
            body: "for (let ${1:i} = 0; $1 < ${2:length}; $1++) {\n\t$0\n}"
        ),

        // MARK: - Python

        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5333-000000000001")!,
            name: "Def", trigger: "def", languageIDs: ["python"],
            body: "def ${1:name}(${2:params}):\n\t$0"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5333-000000000002")!,
            name: "Class", trigger: "class", languageIDs: ["python"],
            body: "class ${1:Name}:\n\t$0"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5333-000000000003")!,
            name: "If main", trigger: "ifmain", languageIDs: ["python"],
            body: "if __name__ == \"__main__\":\n\t$0"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5333-000000000004")!,
            name: "For loop", trigger: "for", languageIDs: ["python"],
            body: "for ${1:item} in ${2:iterable}:\n\t$0"
        ),

        // MARK: - HTML

        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5444-000000000001")!,
            name: "HTML5 skeleton", trigger: "html5", languageIDs: ["html"],
            body: "<!DOCTYPE html>\n<html>\n<head>\n\t<title>$1</title>\n</head>\n<body>\n\t$0\n</body>\n</html>"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5444-000000000002")!,
            name: "Div", trigger: "div", languageIDs: ["html"],
            body: "<div class=\"$1\">\n\t$0\n</div>"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5444-000000000003")!,
            name: "Link", trigger: "a", languageIDs: ["html"],
            body: "<a href=\"$1\">$2</a>$0"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5444-000000000004")!,
            name: "Image", trigger: "img", languageIDs: ["html"],
            body: "<img src=\"$1\" alt=\"$2\">$0"
        ),

        // MARK: - Markdown

        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5555-000000000001")!,
            name: "Link", trigger: "link", languageIDs: ["markdown"],
            body: "[$1]($2)$0"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5555-000000000002")!,
            name: "Image", trigger: "img", languageIDs: ["markdown"],
            body: "![$1]($2)$0"
        ),
        Snippet(
            id: UUID(uuidString: "00000000-0000-4000-5555-000000000003")!,
            name: "Code block", trigger: "code", languageIDs: ["markdown"],
            body: "```$1\n$0\n```"
        ),
    ]
}

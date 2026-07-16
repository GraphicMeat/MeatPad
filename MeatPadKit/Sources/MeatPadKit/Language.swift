import Foundation

/// A supported source language. Data-only — grammar wiring happens in a later task.
public struct Language: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var extensions: [String]
    public var shebangs: [String]

    public init(id: String, name: String, extensions: [String], shebangs: [String]) {
        self.id = id
        self.name = name
        self.extensions = extensions
        self.shebangs = shebangs
    }
}

public enum Languages {
    public static let all: [Language] = [
        Language(id: "json", name: "JSON", extensions: ["json"], shebangs: []),
        Language(id: "javascript", name: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"], shebangs: ["node"]),
        Language(id: "typescript", name: "TypeScript", extensions: ["ts", "mts", "cts"], shebangs: ["ts-node"]),
        Language(id: "tsx", name: "TSX", extensions: ["tsx"], shebangs: []),
        Language(id: "html", name: "HTML", extensions: ["html", "htm"], shebangs: []),
        Language(id: "css", name: "CSS", extensions: ["css"], shebangs: []),
        Language(id: "python", name: "Python", extensions: ["py", "pyw"], shebangs: ["python", "python3"]),
        Language(id: "ruby", name: "Ruby", extensions: ["rb"], shebangs: ["ruby"]),
        Language(id: "bash", name: "Bash", extensions: ["sh", "bash"], shebangs: ["bash", "sh"]),
        Language(id: "go", name: "Go", extensions: ["go"], shebangs: []),
        Language(id: "rust", name: "Rust", extensions: ["rs"], shebangs: []),
        Language(id: "c", name: "C", extensions: ["c", "h"], shebangs: []),
        Language(id: "cpp", name: "C++", extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx"], shebangs: []),
        Language(id: "swift", name: "Swift", extensions: ["swift"], shebangs: ["swift"]),
        Language(id: "markdown", name: "Markdown", extensions: ["md", "markdown"], shebangs: []),
        Language(id: "yaml", name: "YAML", extensions: ["yaml", "yml"], shebangs: []),
    ]

    public static func byID(_ id: String) -> Language? {
        all.first { $0.id == id }
    }
}

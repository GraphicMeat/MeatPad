import Foundation
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterHTML
import TreeSitterCSS
import TreeSitterPython
import TreeSitterRuby
import TreeSitterBash
import TreeSitterGo
import TreeSitterRust
import TreeSitterC
import TreeSitterCPP
import TreeSitterYAML
import TreeSitterSwift

/// Anchor for `Bundle(for:)` so we can locate resource bundles relative to the
/// binary that statically links MeatPadKit (the .xctest bundle under `swift test`,
/// the .app under a real build).
private final class BundleMarker {}

/// Maps a language id to its tree-sitter grammar and bundled `highlights.scm` query.
///
/// Each grammar SPM package ships its queries as a resource bundle named
/// `TreeSitter<Name>_TreeSitter<Name>.bundle`. We locate that bundle and its
/// `queries` directory ourselves rather than using `LanguageConfiguration(_:name:)`,
/// because SwiftTreeSitter's macOS heuristic only checks the Xcode-style
/// `Contents/Resources/queries` layout, whereas command-line `swift test` emits a
/// flat bundle with `queries` at the top level. We handle both.
/// `tsx` is the one exception — it lives inside the TypeScript package, so its
/// bundle name is passed explicitly.
enum GrammarRegistry {
    private struct Spec {
        let function: () -> OpaquePointer?
        let name: String
        let bundleName: String?
    }

    // languageID -> grammar. Missing ids (swift, markdown) simply have no grammar wired.
    private static let specs: [String: Spec] = [
        "json":       Spec(function: tree_sitter_json,       name: "JSON",       bundleName: nil),
        "javascript": Spec(function: tree_sitter_javascript, name: "JavaScript", bundleName: nil),
        "typescript": Spec(function: tree_sitter_typescript, name: "TypeScript", bundleName: nil),
        "tsx":        Spec(function: tree_sitter_tsx,         name: "TSX",        bundleName: "TreeSitterTypeScript_TreeSitterTSX"),
        "html":       Spec(function: tree_sitter_html,       name: "HTML",       bundleName: nil),
        "css":        Spec(function: tree_sitter_css,        name: "CSS",        bundleName: nil),
        "python":     Spec(function: tree_sitter_python,     name: "Python",     bundleName: nil),
        "ruby":       Spec(function: tree_sitter_ruby,       name: "Ruby",       bundleName: nil),
        "bash":       Spec(function: tree_sitter_bash,       name: "Bash",       bundleName: nil),
        "go":         Spec(function: tree_sitter_go,         name: "Go",         bundleName: nil),
        "rust":       Spec(function: tree_sitter_rust,       name: "Rust",       bundleName: nil),
        "c":          Spec(function: tree_sitter_c,          name: "C",          bundleName: nil),
        "cpp":        Spec(function: tree_sitter_cpp,        name: "CPP",        bundleName: nil),
        "yaml":       Spec(function: tree_sitter_yaml,       name: "YAML",       bundleName: nil),
        "swift":      Spec(function: tree_sitter_swift,      name: "Swift",      bundleName: nil),
    ]

    /// A parsed grammar language paired with its highlights query, or nil if unsupported.
    static func configuration(for languageID: String) -> LanguageConfiguration? {
        guard let spec = specs[languageID], let ptr = spec.function() else { return nil }
        let bundleName = spec.bundleName ?? "TreeSitter\(spec.name)_TreeSitter\(spec.name)"
        guard let queriesURL = queriesDirectory(bundleName: bundleName) else { return nil }
        return try? LanguageConfiguration(ptr, name: spec.name, queriesURL: queriesURL)
    }

    /// Finds the `queries` directory inside `<bundleName>.bundle`, searching the
    /// directories where SPM/Xcode may have placed the resource bundle and both the
    /// flat (`queries`) and Xcode (`Contents/Resources/queries`) layouts.
    private static func queriesDirectory(bundleName: String) -> URL? {
        let fm = FileManager.default
        let anchor = Bundle(for: BundleMarker.self)

        var containers: [URL] = []
        if let url = anchor.resourceURL { containers.append(url) }
        containers.append(anchor.bundleURL.deletingLastPathComponent())
        if let url = Bundle.main.resourceURL { containers.append(url) }
        containers.append(Bundle.main.bundleURL.deletingLastPathComponent())

        for container in containers {
            let bundle = container.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
            for layout in ["queries", "Contents/Resources/queries"] {
                let dir = bundle.appendingPathComponent(layout, isDirectory: true)
                if fm.fileExists(atPath: dir.appendingPathComponent("highlights.scm").path) {
                    return dir
                }
            }
        }
        return nil
    }
}

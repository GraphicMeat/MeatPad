import Foundation

/// The outcome of importing a TextMate bundle: successfully parsed snippets/commands,
/// plus counts of entries that failed to import (missing required fields, malformed
/// plists, or snippet bodies `SnippetParser` can't handle).
public struct BundleImportResult: Equatable, Sendable {
    public var snippets: [Snippet]
    public var commands: [SavedCommand]
    public var skippedSnippets: Int
    public var skippedCommands: Int
}

public enum BundleImportError: Error, Equatable {
    case notABundle
}

/// Imports a TextMate `.tmbundle` directory's `Snippets/*.tmSnippet` and
/// `Commands/*.tmCommand` plists into MeatPadKit's native `Snippet`/`SavedCommand` types.
public enum BundleImporter {

    /// A derived-from-name trigger longer than this is considered "not short" and the
    /// snippet is skipped rather than given an unwieldy trigger.
    private static let maxDerivedTriggerLength = 20

    public static func importBundle(at url: URL) throws -> BundleImportResult {
        var isDirectory: ObjCBool = false
        let snippetsDir = url.appendingPathComponent("Snippets", isDirectory: true)
        let commandsDir = url.appendingPathComponent("Commands", isDirectory: true)
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            url.pathExtension == "tmbundle" || directoryExists(snippetsDir) || directoryExists(commandsDir)
        else {
            throw BundleImportError.notABundle
        }

        var snippets: [Snippet] = []
        var skippedSnippets = 0
        for fileURL in plistFiles(in: snippetsDir, extension: "tmSnippet") {
            if let snippet = importSnippet(at: fileURL) {
                snippets.append(snippet)
            } else {
                skippedSnippets += 1
            }
        }

        var commands: [SavedCommand] = []
        var skippedCommands = 0
        for fileURL in plistFiles(in: commandsDir, extension: "tmCommand") {
            if let command = importCommand(at: fileURL) {
                commands.append(command)
            } else {
                skippedCommands += 1
            }
        }

        return BundleImportResult(
            snippets: snippets,
            commands: commands,
            skippedSnippets: skippedSnippets,
            skippedCommands: skippedCommands
        )
    }

    /// Best-effort TextMate scope -> `Language.id` mapping, filtered to ids that
    /// actually exist in `Languages.all`. Unknown/nil scope means "all languages".
    static func scopeToLanguageIDs(_ scope: String?) -> [String] {
        guard let scope else { return [] }

        let id: String?
        if scope == "source.swift" {
            id = "swift"
        } else if scope == "source.js" {
            id = "javascript"
        } else if scope == "source.ts" {
            id = "typescript"
        } else if scope == "source.python" || scope == "source.py" {
            id = "python"
        } else if scope.hasPrefix("text.html") {
            id = "html"
        } else if scope == "text.markdown" || scope == "text.md" {
            id = "markdown"
        } else if scope == "source.c" {
            id = "c"
        } else if scope == "source.ruby" {
            id = "ruby"
        } else {
            id = nil
        }

        guard let id, Languages.all.contains(where: { $0.id == id }) else { return [] }
        return [id]
    }

    // MARK: - Private

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func plistFiles(in directory: URL, extension ext: String) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.filter { $0.pathExtension == ext }
    }

    private static func readPlist(at url: URL) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dict = plist as? [String: Any]
        else { return nil }
        return dict
    }

    /// `nil` return means "skip" (missing content, unusable trigger, or a body
    /// `SnippetParser` can't handle — e.g. a `${n/…/…/}` regex transform).
    private static func importSnippet(at url: URL) -> Snippet? {
        guard let dict = readPlist(at: url), let content = dict["content"] as? String else {
            return nil
        }
        let name = (dict["name"] as? String) ?? ""

        let trigger: String
        if let tabTrigger = dict["tabTrigger"] as? String {
            trigger = tabTrigger
        } else {
            let derived = name.lowercased().filter(\.isLetterOrNumber)
            guard !derived.isEmpty, derived.count <= maxDerivedTriggerLength else { return nil }
            trigger = derived
        }

        guard (try? SnippetParser.parse(content)) != nil else { return nil }

        return Snippet(
            name: name,
            trigger: trigger,
            languageIDs: scopeToLanguageIDs(dict["scope"] as? String),
            body: content
        )
    }

    /// `nil` return means "skip" (missing the `command` script, or a malformed plist).
    private static func importCommand(at url: URL) -> SavedCommand? {
        guard let dict = readPlist(at: url), let script = dict["command"] as? String else {
            return nil
        }
        let name = (dict["name"] as? String) ?? ""

        return SavedCommand(
            name: name,
            script: script,
            input: commandInput(dict["input"] as? String),
            output: commandOutput(dict["output"] as? String),
            languageIDs: scopeToLanguageIDs(dict["scope"] as? String)
        )
    }

    private static func commandInput(_ raw: String?) -> CommandInput {
        switch raw {
        case "selection": return .selection
        case "document", "entireDocument": return .document
        default: return .none
        }
    }

    private static func commandOutput(_ raw: String?) -> CommandOutputMode {
        switch raw {
        case "replaceSelectedText", "replaceSelection": return .replaceSelection
        case "insertAsText", "afterSelectedText": return .insertAtCaret
        case "openAsNewDocument", "createNewDocument": return .newNote
        default: return .outputPanel
        }
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}

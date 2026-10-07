import Foundation

/// One row of the terminal header's Git menu: a command, or a divider between groups.
///
/// A flat struct rather than an enum with payloads so the Settings list can bind a text field
/// and a picker straight to `command` and `runs`.
public struct GitMenuItem: Identifiable, Equatable, Sendable {
    /// Row identity for SwiftUI lists only — made fresh on every init and decode, never saved,
    /// and left out of `==`: two configs with the same rows are the same config.
    public let id: UUID
    public var command: String
    /// True: clicking runs it (⏎ is sent). False: it is only typed, for the user to finish.
    public var runs: Bool
    public let isDivider: Bool

    private init(command: String, runs: Bool, isDivider: Bool) {
        id = UUID()
        self.command = command
        self.runs = runs
        self.isDivider = isDivider
    }

    public static func command(_ command: String, runs: Bool) -> GitMenuItem {
        GitMenuItem(command: command, runs: runs, isDivider: false)
    }

    public static func divider() -> GitMenuItem {
        GitMenuItem(command: "", runs: false, isDivider: true)
    }

    public static func == (lhs: GitMenuItem, rhs: GitMenuItem) -> Bool {
        lhs.command == rhs.command && lhs.runs == rhs.runs && lhs.isDivider == rhs.isDivider
    }
}

/// The Git menu's rows, in menu order. Persisted as JSON a person can write by hand (the UI
/// tests seed it from a launch argument):
/// `{"items":[{"command":"git status","run":true},{"divider":true}]}`.
public struct GitMenuConfig: Equatable, Sendable {
    public var items: [GitMenuItem]

    public init(items: [GitMenuItem]) {
        self.items = items
    }

    public static let defaults = GitMenuConfig(items: [
        .command("git status", runs: true),
        .command("git fetch", runs: true),
        .command("git pull", runs: true),
        .command("git push", runs: true),
        .divider(),
        .command("git add -A", runs: true),
        .command("git commit -m \"\"", runs: false),
        .command("git commit --amend --no-edit", runs: false),
        .divider(),
        .command("git log --oneline -20", runs: true),
        .command("git diff", runs: true),
        .command("git stash", runs: true),
        .command("git stash pop", runs: true),
        // The space is the point: the branch name goes straight after it.
        .command("git switch -c ", runs: false),
    ])

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Stored(items: items.map(StoredItem.init)))
    }

    /// Missing or unreadable data is the defaults, never an error — a bad preference must not
    /// take the menu away. An entry that can't be read is skipped and the rest kept; an
    /// explicitly empty list stays empty (the user removed everything).
    public static func decode(_ data: Data?) -> GitMenuConfig {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .defaults }
        return GitMenuConfig(items: stored.items.compactMap(\.item))
    }

    // MARK: - JSON

    private struct Stored: Codable {
        var items: [StoredItem]

        init(items: [StoredItem]) { self.items = items }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            items = try container.decode([StoredItem].self, forKey: .items)
        }
    }

    /// One entry as written in the JSON. Its decoding never throws: an unkeyed container whose
    /// element decode throws doesn't move past that element, so one bad entry would end the
    /// whole list. Unreadable entries decode to `item == nil` instead.
    private struct StoredItem: Codable {
        let item: GitMenuItem?

        private enum CodingKeys: String, CodingKey { case command, run, divider }

        init(_ item: GitMenuItem) { self.item = item }

        init(from decoder: Decoder) {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                item = nil
                return
            }
            if (try? container.decode(Bool.self, forKey: .divider)) == true {
                item = .divider()
            } else if let command = try? container.decode(String.self, forKey: .command) {
                // No flag means type only: a hand-written entry never runs by surprise.
                item = .command(command, runs: (try? container.decode(Bool.self, forKey: .run)) ?? false)
            } else {
                item = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            guard let item else { return }
            if item.isDivider {
                try container.encode(true, forKey: .divider)
            } else {
                try container.encode(item.command, forKey: .command)
                try container.encode(item.runs, forKey: .run)
            }
        }
    }
}

/// What a Git menu click sends to the shell.
public enum GitMenuInput {
    /// ⌃U first, like `TerminalLaunch.changeDirectoryCommand`: it clears anything half-typed at
    /// the prompt, so the command never lands glued to it. A run command ends with ⏎; a typed one
    /// ending in an empty `""` or `''` gets one Left Arrow, leaving the caret between the quotes
    /// for the message. Left is `ESC O D` in application-cursor mode (zsh frameworks switch to
    /// it), `ESC [ D` otherwise.
    public static func keystrokes(for command: String, runs: Bool, applicationCursor: Bool) -> String {
        let clearLine = "\u{15}"
        if runs { return clearLine + command + "\r" }
        guard command.hasSuffix("\"\"") || command.hasSuffix("''") else { return clearLine + command }
        return clearLine + command + (applicationCursor ? "\u{1B}OD" : "\u{1B}[D")
    }
}

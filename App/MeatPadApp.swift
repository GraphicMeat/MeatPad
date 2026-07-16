import SwiftUI
import AppKit
import MeatPadKit
import STTextView

@main
struct MeatPadApp: App {
    // Temporary demo state — Task 7 replaces this WindowGroup content.
    @State private var text = MeatPadApp.sample

    var body: some Scene {
        WindowGroup {
            CodeEditor(
                text: $text,
                language: Languages.byID("python"),
                theme: BuiltinThemes.defaultDark,
                onCursorChange: { _ in }
            )
            .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            // Route Cmd+F / Cmd+G through the responder chain to STTextView's
            // NSTextFinder integration. It reads the action from the sender's tag.
            CommandGroup(after: .textEditing) {
                Button("Find…") { MeatPadApp.finder(.showFindInterface) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { MeatPadApp.finder(.nextMatch) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { MeatPadApp.finder(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }
    }

    static func finder(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(STTextView.performTextFinderAction(_:)), to: nil, from: item)
    }

    static let sample = """
    #!/usr/bin/env python3
    \"\"\"A small sample to show off syntax highlighting.\"\"\"

    import math


    def circle_area(radius: float) -> float:
        # area = pi * r^2
        if radius < 0:
            raise ValueError("radius must be non-negative")
        return math.pi * radius ** 2


    class Greeter:
        def __init__(self, name: str):
            self.name = name

        def greet(self) -> str:
            return f"Hello, {self.name}!"


    if __name__ == "__main__":
        print(circle_area(2.5))
        print(Greeter("world").greet())
    """
}

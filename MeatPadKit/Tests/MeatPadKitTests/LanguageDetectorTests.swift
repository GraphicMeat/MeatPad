import XCTest
@testable import MeatPadKit

final class LanguageDetectorTests: XCTestCase {

    // MARK: - Languages registry

    func testAllCoversRequiredIDs() {
        let requiredIDs: Set<String> = [
            "json", "javascript", "typescript", "tsx", "html", "css", "python",
            "ruby", "bash", "go", "rust", "c", "cpp", "swift", "markdown", "yaml",
        ]
        let actualIDs = Set(Languages.all.map(\.id))
        XCTAssertEqual(actualIDs, requiredIDs)
    }

    func testByIDFindsKnownLanguage() {
        XCTAssertEqual(Languages.byID("python")?.name, "Python")
    }

    func testByIDReturnsNilForUnknown() {
        XCTAssertNil(Languages.byID("cobol"))
    }

    // MARK: - Extension detection

    func testDetectsByExtension() {
        XCTAssertEqual(LanguageDetector.detect(filename: "main.py", contents: "")?.id, "python")
    }

    func testDetectsTSXByExtension() {
        XCTAssertEqual(LanguageDetector.detect(filename: "file.tsx", contents: "")?.id, "tsx")
    }

    func testExtensionMatchIsCaseInsensitive() {
        XCTAssertEqual(LanguageDetector.detect(filename: "main.PY", contents: "")?.id, "python")
    }

    func testUnknownExtensionReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(filename: "file.xyzzy", contents: ""))
    }

    func testNilFilenameAndNoHintsReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(filename: nil, contents: "just some text"))
    }

    // MARK: - Shebang detection

    func testDetectsByShebangWithNilFilename() {
        let contents = "#!/usr/bin/env python3\nprint('hi')\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "python")
    }

    func testDetectsByDirectShebang() {
        let contents = "#!/bin/bash\necho hi\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "bash")
    }

    func testShebangBeatsExtension() {
        // priority is modeline > shebang > extension, so shebang wins even with a differing extension
        let contents = "#!/usr/bin/env python3\n"
        XCTAssertEqual(LanguageDetector.detect(filename: "script.rb", contents: contents)?.id, "python")
    }

    // MARK: - Modeline detection (highest priority)

    func testVimModelineBeatsShebang() {
        let contents = "#!/usr/bin/env python3\n// vim: ft=ruby\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "ruby")
    }

    func testVimModelineSetFormBeatsShebang() {
        let contents = "#!/usr/bin/env python3\n// vim: set ft=go :\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "go")
    }

    func testVimModelineFiletypeFormBeatsShebang() {
        let contents = "#!/usr/bin/env python3\n// vim: filetype=rust\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "rust")
    }

    func testEmacsModelineWorks() {
        let contents = "-*- mode: Python -*-\nprint('hi')\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "python")
    }

    func testEmacsModelineBeatsShebang() {
        let contents = "#!/usr/bin/env ruby\n-*- mode: c++ -*-\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "cpp")
    }

    func testEmacsModeSuffixIsStripped() {
        // Emacs mode names conventionally end in "-mode" (e.g. "c++-mode").
        let contents = "-*- mode: c++-mode -*-\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "cpp")
    }

    func testVimShFiletypeMapsToBash() {
        // vim's default filetype for shell scripts is "sh", not "bash".
        let contents = "#!/bin/sh\n// vim: ft=sh\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "bash")
    }

    func testModelineIgnoresPhantomLineFromTrailingNewline() {
        // A trailing "\n" must not shift the "last 5 lines" window.
        var lines = ["#!/usr/bin/env python3"]
        for _ in 0..<20 { lines.append("// filler") }
        lines.append("// vim: ft=ruby")
        let contents = lines.joined(separator: "\n") + "\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "ruby")
    }

    func testModelineOnlyScansFirstAndLastFiveLines() {
        // modeline buried in the middle of a long file should be ignored
        var lines = ["#!/usr/bin/env python3"]
        for _ in 0..<20 { lines.append("// filler") }
        lines.insert("// vim: ft=ruby", at: 10)
        for _ in 0..<20 { lines.append("// filler") }
        let contents = lines.joined(separator: "\n")
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "python")
    }

    func testModelineInLastFiveLinesIsHonored() {
        var lines = ["#!/usr/bin/env python3"]
        for _ in 0..<20 { lines.append("// filler") }
        lines.append("// vim: ft=ruby")
        let contents = lines.joined(separator: "\n")
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "ruby")
    }

    // MARK: - Unknown

    func testUnknownFileReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(filename: "file.unknownext", contents: "no hints here"))
    }

    // MARK: - Content-heuristic tier (lowest priority)

    func testContentHeuristicDetectsPastedSwiftWithNilFilename() {
        let contents = """
        import Foundation

        func greet(name: String) -> String {
            let prefix = "Hello"
            guard !name.isEmpty else { return prefix }
            return prefix + ", " + name
        }
        """
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "swift")
    }

    func testExtensionBeatsContentHeuristic() {
        // Python filename, unambiguous Go body: extension tier must win.
        let contents = "package main\n\nimport \"fmt\"\n\nfunc main() {\n    x := 1\n    fmt.Println(x)\n}\n"
        XCTAssertEqual(LanguageDetector.detect(filename: "main.py", contents: contents)?.id, "python")
    }

    func testShebangBeatsContentHeuristic() {
        let contents = "#!/usr/bin/env python3\nfn main() {\n    let mut x = 0;\n    println!(\"{}\", x);\n}\n"
        XCTAssertEqual(LanguageDetector.detect(filename: nil, contents: contents)?.id, "python")
    }

    func testUnknownExtensionFallsThroughToContentHeuristic() {
        let contents = "package main\n\nimport \"fmt\"\n\nfunc main() {\n    x := 1\n    fmt.Println(x)\n}\n"
        XCTAssertEqual(LanguageDetector.detect(filename: "notes.xyzzy", contents: contents)?.id, "go")
    }

    func testProseStillReturnsNilThroughDetect() {
        XCTAssertNil(LanguageDetector.detect(filename: nil, contents: "meeting notes: discuss roadmap, then lunch"))
    }
}

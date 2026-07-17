import XCTest
@testable import MeatPadKit

final class ContentClassifierTests: XCTestCase {

    private func classify(_ contents: String) -> String? {
        ContentClassifier.classify(contents)?.id
    }

    // MARK: - Negatives (most important: plain text beats wrong guess)

    func testProseReturnsNil() {
        XCTAssertNil(classify("The quick brown fox jumps over the lazy dog. It was the best of times."))
    }

    func testShortAmbiguousFragmentReturnsNil() {
        XCTAssertNil(classify("x = 1"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(classify(""))
    }

    func testProseWithColonsAndURLsReturnsNil() {
        XCTAssertNil(classify("""
        Note: remember the milk.
        See https://example.com/docs for details.
        Also: call mom.
        """))
    }

    // MARK: - One positive per language

    func testSwift() {
        XCTAssertEqual(classify("""
        import Foundation

        func greet(name: String) -> String {
            let prefix = "Hello"
            guard !name.isEmpty else { return prefix }
            return prefix + ", " + name
        }

        struct Greeter {
            var count = 0
        }
        """), "swift")
    }

    func testPython() {
        XCTAssertEqual(classify("""
        import os

        def main(path):
            for name in os.listdir(path):
                print(name)

        class Walker:
            def __init__(self):
                self.count = 0
        """), "python")
    }

    func testRuby() {
        XCTAssertEqual(classify("""
        require "json"

        def load_items(path)
          data = JSON.parse(File.read(path))
          data.each do |item|
            puts item["name"]
          end
        end
        """), "ruby")
    }

    func testJavaScript() {
        XCTAssertEqual(classify("""
        const items = require("./items")

        function render(list) {
          const out = list.map((x) => x.name)
          console.log(out)
          return out === undefined ? [] : out
        }
        """), "javascript")
    }

    func testTypeScript() {
        XCTAssertEqual(classify("""
        interface User {
          name: string
          age: number
        }

        type Result = User | null

        const parse = (raw: string): Result => {
          return JSON.parse(raw)
        }
        """), "typescript")
    }

    func testTSX() {
        XCTAssertEqual(classify("""
        type Props = { label: string }

        export const Button = ({ label }: Props) => {
          return (
            <Card>
              <Label text={label} />
            </Card>
          )
        }
        """), "tsx")
    }

    func testJSON() {
        XCTAssertEqual(classify("""
        {
          "name": "meatpad",
          "version": "1.2.3",
          "private": true,
          "deps": { "sparkle": "2.9.4" }
        }
        """), "json")
    }

    func testHTML() {
        XCTAssertEqual(classify("""
        <!DOCTYPE html>
        <html>
          <head><title>Hi</title></head>
          <body>
            <p class="intro">Hello</p>
            <ul><li>One</li></ul>
          </body>
        </html>
        """), "html")
    }

    func testCSS() {
        XCTAssertEqual(classify("""
        .button {
          color: red;
          padding: 4px 8px;
        }

        @media (max-width: 600px) {
          .button { display: none; }
        }
        """), "css")
    }

    func testYAML() {
        XCTAssertEqual(classify("""
        name: meatpad
        version: 1.2.3
        targets:
          - app
          - kit
        build:
          fast: true
        """), "yaml")
    }

    func testBashWithoutShebang() {
        XCTAssertEqual(classify("""
        for f in *.log; do
          echo "processing $f"
          count=$((count + 1))
        done
        echo "total: ${count}"
        """), "bash")
    }

    func testGo() {
        XCTAssertEqual(classify("""
        package main

        import "fmt"

        func main() {
            total := 0
            for i := 0; i < 10; i++ {
                total += i
            }
            fmt.Println(total)
        }
        """), "go")
    }

    func testRust() {
        XCTAssertEqual(classify("""
        fn main() {
            let mut total = 0;
            for i in 0..10 {
                total += i;
            }
            println!("total: {}", total);
        }
        """), "rust")
    }

    func testC() {
        XCTAssertEqual(classify("""
        #include <stdio.h>

        int main(void) {
            int count = 0;
            printf("count = %d\\n", count);
            return 0;
        }
        """), "c")
    }

    func testCPP() {
        XCTAssertEqual(classify("""
        #include <vector>
        #include <iostream>

        int main() {
            std::vector<int> items = {1, 2, 3};
            for (auto item : items) {
                std::cout << item << "\\n";
            }
            return 0;
        }
        """), "cpp")
    }

    // MARK: - Discriminators

    func testCHeaderIncludeDoesNotReadAsCPP() {
        // <stdio.h> must not match the C++ bare-<vector> include pattern.
        XCTAssertNotEqual(classify("#include <stdio.h>\nint main(void) { printf(\"hi\"); return 0; }"), "cpp")
    }

    func testPlainJSDoesNotReadAsTypeScript() {
        XCTAssertEqual(classify("""
        const a = 1
        const b = (x) => x + a
        console.log(b(2))
        console.log(a === 1)
        """), "javascript")
    }

    func testIndentedCSSDoesNotReadAsYAML() {
        // "color: red;" lines are indented + semicolon-terminated — not top-level YAML keys.
        XCTAssertNotEqual(classify(".x {\n  color: red;\n  margin: 0;\n  padding: 0;\n}"), "yaml")
    }

    func testScanCapStillDetectsFromHead() {
        // Signals live in the first 8 KB; a huge plain tail must not dilute the score.
        let head = """
        package main

        import "fmt"

        func main() {
            total := 0
            fmt.Println(total)
        }
        """
        let tail = String(repeating: "filler filler filler\n", count: 5000)
        XCTAssertEqual(classify(head + "\n" + tail), "go")
    }
}

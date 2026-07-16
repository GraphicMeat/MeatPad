import XCTest
@testable import MeatPadKit

@MainActor
final class DebouncerTests: XCTestCase {

    func testFiresOnceAfterBurst() async throws {
        let debouncer = Debouncer(delay: 0.05)
        var fireCount = 0
        var lastValue = 0

        debouncer.call { fireCount += 1; lastValue = 1 }
        debouncer.call { fireCount += 1; lastValue = 2 }
        debouncer.call { fireCount += 1; lastValue = 3 }

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(fireCount, 1)
        XCTAssertEqual(lastValue, 3)
    }

    func testFlushFiresImmediately() {
        let debouncer = Debouncer(delay: 10) // long delay; flush must not wait for it
        var fired = false

        debouncer.call { fired = true }
        debouncer.flush()

        XCTAssertTrue(fired)
    }

    func testCancelDropsPending() async throws {
        let debouncer = Debouncer(delay: 0.05)
        var fired = false

        debouncer.call { fired = true }
        debouncer.cancel()

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(fired)
    }
}

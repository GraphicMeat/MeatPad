import XCTest
@testable import MeatPadKit

final class AttachmentStoreTests: XCTestCase {
    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    func testAddWritesUnderTheOwnerAndNamesByExtension() throws {
        let store = AttachmentStore(rootURL: tempDir)
        let owner = UUID()
        let name = try store.add(Data([1, 2, 3]), ext: "PNG", to: owner)
        XCTAssertTrue(name.hasSuffix(".png"))
        XCTAssertNotNil(UUID(uuidString: String(name.dropLast(4))))
        XCTAssertEqual(store.url(name, for: owner), tempDir.appendingPathComponent(owner.uuidString).appendingPathComponent(name))
        XCTAssertEqual(store.data(name, for: owner), Data([1, 2, 3]))
    }

    func testRemoveDeletesOneFileAndRemoveAllDeletesTheOwnerDirectory() throws {
        let store = AttachmentStore(rootURL: tempDir)
        let owner = UUID()
        let a = try store.add(Data([1]), ext: "png", to: owner)
        let b = try store.add(Data([2]), ext: "jpeg", to: owner)
        try store.remove(a, from: owner)
        XCTAssertNil(store.data(a, for: owner))
        XCTAssertNotNil(store.data(b, for: owner))
        try store.removeAll(for: owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(owner.uuidString).path))
    }

    func testRemovingWhatIsNotThereIsNotAnError() throws {
        let store = AttachmentStore(rootURL: tempDir)
        XCTAssertNoThrow(try store.remove("missing.png", from: UUID()))
        XCTAssertNoThrow(try store.removeAll(for: UUID()))
    }

    func testExtensionIsValidated() {
        XCTAssertEqual(try AttachmentStore.validatedExtension("HEIC"), "heic")
        XCTAssertThrowsError(try AttachmentStore.validatedExtension("../x"))
        XCTAssertThrowsError(try AttachmentStore.validatedExtension(""))
        XCTAssertThrowsError(try AttachmentStore.validatedExtension("toolongext"))
    }

    func testWriteKeepsTheGivenName() throws {
        let store = AttachmentStore(rootURL: tempDir)
        let owner = UUID()
        try store.write(Data([9]), name: "fixed.png", to: owner)
        XCTAssertEqual(store.data("fixed.png", for: owner), Data([9]))
    }
}

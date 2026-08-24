import XCTest
@testable import MeatPadKit

final class CardTextSplitTests: XCTestCase {

    func testNumberedListBecomesOneDraftPerItem() {
        let pasted = """
        1. Norėtų, kad brėžinyje būtų galima pasirinkti ne po 1, o visas naujas vieno storio pertvaras.
        2. Gyva sąmata – suvedinėjant darbus, reikia, kad galima būtų įterpti kokį nors darbą tam tikroje sąmatos vietoje. Šiuo metu prideda tik grupes darbų apačioje.
        3. Koreguojant darbą sąmatoje, pvz keičiant kiekį, suma pasikeičia tik paspaudus “išsaugoti”. Geriau to nebūtų ir užtektų enter.
        """
        let drafts = CardTextSplit.drafts(from: pasted)
        XCTAssertEqual(drafts.count, 3)
        XCTAssertTrue(drafts[0].title.hasPrefix("Norėtų, kad brėžinyje"))
        XCTAssertFalse(drafts[0].title.contains("1."))
        // Two sentences: the first is the title, the rest becomes the card's notes.
        XCTAssertTrue(drafts[1].title.hasPrefix("Gyva sąmata"))
        XCTAssertEqual(drafts[1].body, "Šiuo metu prideda tik grupes darbų apačioje.")
    }

    func testBulletsAndCRLF() {
        let drafts = CardTextSplit.drafts(from: "- first thing\r\n• second thing\r\n* third thing")
        XCTAssertEqual(drafts.map(\.title), ["first thing", "second thing", "third thing"])
    }

    func testUnmarkedLinesUnderAnItemStayWithIt() {
        let drafts = CardTextSplit.drafts(from: "1) Alpha\ndetail line\n2) Beta")
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].title, "Alpha")
        XCTAssertEqual(drafts[0].body, "detail line")
    }

    func testBlankLineParagraphsSplitWhenThereAreNoMarkers() {
        let drafts = CardTextSplit.drafts(from: "First note.\n\nSecond note.")
        XCTAssertEqual(drafts.map(\.title), ["First note.", "Second note."])
    }

    func testSingleLineIsOneDraftWithNoBody() {
        let drafts = CardTextSplit.drafts(from: "  Fix the estimate insert  ")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].title, "Fix the estimate insert")
        XCTAssertNil(drafts[0].body)
    }

    /// One dash, or a number that is really a date, must not turn prose into a list.
    func testNotEveryDashOrNumberIsAList() {
        XCTAssertEqual(CardTextSplit.drafts(from: "Call the client - urgent").count, 1)
        XCTAssertEqual(CardTextSplit.drafts(from: "2026. metai buvo geri").count, 1)
    }

    func testOverlongLeadIsTruncatedButKeepsTheFullTextAsBody() {
        let long = String(repeating: "word ", count: 60) + "end"
        let drafts = CardTextSplit.drafts(from: long)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertTrue(drafts[0].title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(drafts[0].title.count, 121)
        XCTAssertEqual(drafts[0].body, long.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testTitleNeverSpansALineBreak() {
        let drafts = CardTextSplit.drafts(from: "Heading without a period\nthe detail after it")
        XCTAssertEqual(drafts[0].title, "Heading without a period")
        XCTAssertEqual(drafts[0].body, "the detail after it")
    }
}

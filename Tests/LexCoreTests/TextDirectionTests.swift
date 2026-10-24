import XCTest
@testable import LexCore

final class TextDirectionTests: XCTestCase {
    func testReadsTheDirectionFromTheLetters() {
        XCTAssertTrue(TextDirection.isRightToLeft("סנכרון רץ אז בשלושה שלבים:"))
        XCTAssertTrue(TextDirection.isRightToLeft("Tandem מפעיל לרגע קצר את ה-CLI וקורא את רשימת הכלים."))
        XCTAssertFalse(TextDirection.isRightToLeft("Sync runs in three steps."))
        XCTAssertFalse(TextDirection.isRightToLeft("Say שלום to everyone on the team for me."))
        XCTAssertFalse(TextDirection.isRightToLeft("• 42."))
    }

    func testMarksEachParagraphWithItsDirection() {
        let text = "Tandem מפעיל את ה-CLI.\n\n•\nmcp__gmail__search_threads\r\nשלום"
        let marks = TextDirection.paragraphMarks(text)
        XCTAssertEqual(marks.map(\.offset), [0, 26, 53])
        XCTAssertEqual(marks.map(\.mark), [TextDirection.rightToLeftMark, TextDirection.leftToRightMark, TextDirection.rightToLeftMark])
    }

    func testLeavesLeftToRightTextAlone() {
        XCTAssertTrue(TextDirection.paragraphMarks("Sync runs in three steps.\n\nDiscovery first.").isEmpty)
        XCTAssertEqual(TextDirection.marked("Sync runs in three steps."), "Sync runs in three steps.")
    }

    func testMarkedTextKeepsEveryCharacter() {
        let text = "Tandem מפעיל את ה-CLI.\n\nShip it."
        XCTAssertEqual(TextDirection.marked(text), "\u{200F}Tandem מפעיל את ה-CLI.\n\n\u{200E}Ship it.")
    }
}

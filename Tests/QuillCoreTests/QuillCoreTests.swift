import XCTest
@testable import QuillCore

final class SentenceSplitterTests: XCTestCase {
    func testSplitsAndMarksCompletion() {
        let text = "I went home. Then I slept"
        let s = SentenceSplitter.split(text, caret: (text as NSString).length)
        XCTAssertEqual(s.map(\.text), ["I went home.", "Then I slept"])
        XCTAssertEqual(s.map(\.isComplete), [true, false])
    }

    func testLineBreakEndsSentence() {
        let text = "hey can you look at this\nthanks"
        let s = SentenceSplitter.split(text, caret: (text as NSString).length)
        XCTAssertEqual(s.map(\.text), ["hey can you look at this", "thanks"])
        XCTAssertEqual(s.map(\.isComplete), [true, false])
    }

    func testCaretElsewhereCompletesTrailingSentence() {
        let text = "First one. Second one without period"
        let s = SentenceSplitter.split(text, caret: 3)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.last?.isComplete, true)
    }
}

final class EditMapperTests: XCTestCase {
    func testMapsAndNarrows() {
        let sentence = "However we recieve the the letters."
        let edits = [
            AIEdit(original: "However we", replacement: "However, we", kind: .punctuation, reason: "comma after introductory word"),
            AIEdit(original: "recieve", replacement: "receive", kind: .spelling, reason: "spelling"),
            AIEdit(original: "the the", replacement: "the", kind: .grammar, reason: "repeated word"),
        ]
        let issues = EditMapper.issues(for: edits, sentence: sentence, base: 10)
        XCTAssertEqual(issues.count, 3)
        XCTAssertEqual(issues[0].original, "However")
        XCTAssertEqual(issues[0].replacements, ["However,"])
        XCTAssertEqual(issues[0].range, NSRange(location: 10, length: 7))
        XCTAssertEqual(issues[1].range, NSRange(location: 10 + 11, length: 7))
        XCTAssertEqual(issues[2].original, " the")
        XCTAssertEqual(issues[2].replacements, [""])
    }

    func testWholeSentenceRewriteSplitsIntoWordFixes() {
        let sentence = "Their going to recieve the package tomorow."
        let edits = [AIEdit(original: sentence, replacement: "They're going to receive the package tomorrow.", kind: .spelling, reason: "")]
        let issues = EditMapper.issues(for: edits, sentence: sentence, base: 0)
        XCTAssertEqual(issues.map(\.original), ["Their", "recieve", "tomorow"])
        XCTAssertEqual(issues.map { $0.replacements[0] }, ["They're", "receive", "tomorrow"])
        // Applying every piece reproduces Claude's sentence.
        var fixed = sentence as NSString
        for issue in issues.reversed() { fixed = fixed.replacingCharacters(in: issue.range, with: issue.replacements[0]) as NSString }
        XCTAssertEqual(fixed as String, "They're going to receive the package tomorrow.")
    }

    func testInsertionAnchorsToNeighbourWord() {
        let issues = EditMapper.issues(for: [AIEdit(original: "I went store", replacement: "I went to the store", kind: .grammar, reason: "")], sentence: "I went store today.", base: 0)
        XCTAssertEqual(issues.count, 1)
        var fixed = "I went store today." as NSString
        fixed = fixed.replacingCharacters(in: issues[0].range, with: issues[0].replacements[0]) as NSString
        XCTAssertEqual(fixed as String, "I went to the store today.")
    }

    func testDropsManglingEdits() {
        let sentence = "the remove fuction is not working that good"
        let bad = [
            AIEdit(original: sentence, replacement: "|", kind: .grammar, reason: ""),
            AIEdit(original: sentence, replacement: "", kind: .grammar, reason: ""),
            AIEdit(original: "remove fuction is not", replacement: "I", kind: .grammar, reason: ""),
        ]
        XCTAssertTrue(EditMapper.issues(for: bad, sentence: sentence, base: 0).isEmpty)
        let good = [AIEdit(original: "fuction", replacement: "function", kind: .spelling, reason: "")]
        XCTAssertEqual(EditMapper.issues(for: good, sentence: sentence, base: 0).count, 1)
    }

    func testDropsEditsNotInSentence() {
        let issues = EditMapper.issues(for: [AIEdit(original: "nope", replacement: "yes", kind: .grammar, reason: "")], sentence: "All good here.", base: 0)
        XCTAssertTrue(issues.isEmpty)
    }

    func testDuplicateOriginalsMapToSuccessiveOccurrences() {
        let edits = [
            AIEdit(original: "teh", replacement: "the", kind: .spelling, reason: ""),
            AIEdit(original: "teh", replacement: "the", kind: .spelling, reason: ""),
        ]
        let issues = EditMapper.issues(for: edits, sentence: "teh cat and teh dog", base: 0)
        XCTAssertEqual(issues.map(\.range.location), [0, 12])
    }
}

final class TargetTests: XCTestCase {
    func testRefinesSentenceBeforeCaret() {
        let text = "First sentence here. Second one is done. "
        let ns = text as NSString
        let r = TextTargets.refineRange(in: text, selection: NSRange(location: ns.length, length: 0), scope: .sentence)
        XCTAssertEqual(r.map { ns.substring(with: $0) }, "Second one is done.")
    }

    func testSelectionWins() {
        let text = "Alpha beta gamma."
        let r = TextTargets.refineRange(in: text, selection: NSRange(location: 6, length: 4), scope: .sentence)
        XCTAssertEqual(r, NSRange(location: 6, length: 4))
    }

    func testParagraphScope() {
        let text = "Para one. Still one.\nPara two here."
        let ns = text as NSString
        let r = TextTargets.refineRange(in: text, selection: NSRange(location: 5, length: 0), scope: .paragraph)
        XCTAssertEqual(r.map { ns.substring(with: $0) }, "Para one. Still one.")
    }

    func testWordBeingTyped() {
        XCTAssertEqual(TextTargets.wordBeingTyped(in: "hello wor", caret: 9), NSRange(location: 6, length: 3))
        XCTAssertNil(TextTargets.wordBeingTyped(in: "hello ", caret: 6))
    }
}

final class WordDiffTests: XCTestCase {
    func reconstruct(_ chunks: [DiffChunk]) -> (String, String) {
        var a = "", b = ""
        for c in chunks {
            switch c {
            case .same(let s): a += s; b += s
            case .change(let r, let add): a += r; b += add
            }
        }
        return (a, b)
    }

    func testRoundTrips() {
        let pairs = [
            ("I has a apple.", "I have an apple."),
            ("", "New text"),
            ("Old text", ""),
            ("Same.", "Same."),
            ("the cat sat", "a dog sat"),
        ]
        for (a, b) in pairs {
            let (ra, rb) = reconstruct(WordDiff.diff(a, b))
            XCTAssertEqual(ra, a)
            XCTAssertEqual(rb, b)
        }
    }

    func testCoalescesAdjacentChanges() {
        XCTAssertEqual(WordDiff.diff("the cat sat", "a dog sat"), [.change(removed: "the cat", added: "a dog"), .same(" sat")])
    }
}

final class ComposerTests: XCTestCase {
    func testAIReviewedSentenceDropsLocalFlags() {
        let text = "Pelles ships fast. Teh end."
        let local = [
            Issue(range: NSRange(location: 0, length: 6), original: "Pelles", replacements: ["Pellets"], kind: .spelling, message: "", source: .local),
            Issue(range: NSRange(location: 19, length: 3), original: "Teh", replacements: ["The"], kind: .spelling, message: "", source: .local),
        ]
        let issues = IssueComposer.compose(text: text, caret: nil, local: local, review: { s in
            s.text == "Pelles ships fast." ? AIReview(text: s.text, edits: [], complete: true) : nil
        }, ignored: [])
        XCTAssertEqual(issues.map(\.original), ["Teh"])
    }

    func testStaleReviewKeepsFixesAndHidesSeenWords() {
        // Claude reviewed "Pelles shipz fast." and flagged "shipz". The user then added a word.
        let old = AIReview(text: "Pelles shipz fast.", edits: [AIEdit(original: "shipz", replacement: "ships", kind: .spelling, reason: "")], complete: true)
        let text = "Pelles shipz realy fast."
        let local = [
            Issue(range: NSRange(location: 0, length: 6), original: "Pelles", replacements: [], kind: .spelling, message: "", source: .local),
            Issue(range: NSRange(location: 13, length: 5), original: "realy", replacements: ["really"], kind: .spelling, message: "", source: .local),
        ]
        let issues = IssueComposer.compose(text: text, caret: nil, local: local, review: { _ in old }, ignored: [])
        XCTAssertEqual(issues.map(\.original), ["shipz", "realy"])
    }

    func testShiftKeepsIssuesAfterEdit() {
        let issue = Issue(range: NSRange(location: 10, length: 3), original: "teh", replacements: ["the"], kind: .spelling, message: "", source: .local)
        let shifted = IssueComposer.shift([issue], from: "Hello all teh", to: "Hello you all teh")
        XCTAssertEqual(shifted.first?.range.location, 14)
        XCTAssertTrue(IssueComposer.shift([issue], from: "Hello all teh", to: "Hello all tex").isEmpty)
    }
}

final class ClientParsingTests: XCTestCase {
    func testParsesEditLines() {
        XCTAssertEqual(EditLineParser.parse("recieve\treceive\tspelling\ti before e"), AIEdit(original: "recieve", replacement: "receive", kind: .spelling, reason: "i before e"))
        XCTAssertEqual(EditLineParser.parse("However we\tHowever, we\tpunctuation"), AIEdit(original: "However we", replacement: "However, we", kind: .punctuation, reason: ""))
        XCTAssertEqual(EditLineParser.parse("their | there | word_choice | wrong word"), AIEdit(original: "their", replacement: "there", kind: .wordChoice, reason: "wrong word"))
        XCTAssertEqual(EditLineParser.parse("we needs<TAB>we need<TAB>grammar<TAB>\"we\" takes \"need\"")?.replacement, "we need")
        XCTAssertNil(EditLineParser.parse("Edits:"))
        XCTAssertEqual(EditLineParser.parse("fuction || function | spelling | typo")?.replacement, "function")
        XCTAssertEqual(EditLineParser.parse("very |  | clarity | redundant")?.replacement, "")
        XCTAssertNil(EditLineParser.parse("the remove fuction is not working | | grammar"))
        XCTAssertEqual(EditLineParser.parse("fuction|function|spelling|typo")?.replacement, "function")
        XCTAssertNil(EditLineParser.parse("OK"))
        XCTAssertNil(EditLineParser.parse(""))
        XCTAssertNil(EditLineParser.parse("just some prose"))
    }

    func testQuotedOriginalsStillMap() {
        let issues = EditMapper.issues(for: [AIEdit(original: "\"teh\"", replacement: "\"the\"", kind: .spelling, reason: "")], sentence: "teh end", base: 0)
        XCTAssertEqual(issues.first?.original, "teh")
        XCTAssertEqual(issues.first?.replacements, ["the"])
    }

    func testSSE() {
        XCTAssertEqual(SSEParser.parse(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#), .text("Hi"))
        XCTAssertEqual(SSEParser.parse(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}"#), .none)
        XCTAssertEqual(SSEParser.parse(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#), .stop("end_turn"))
        XCTAssertEqual(SSEParser.parse(line: "event: ping"), .none)
    }
}

final class LocalCheckerTests: XCTestCase {
    func testFindsMisspelling() {
        let issues = LocalChecker().checkNow("I will recieve the package tomorow.")
        XCTAssertTrue(issues.contains { $0.original == "recieve" && $0.replacements.contains("receive") })
        XCTAssertTrue(issues.contains { $0.original == "tomorow" })
    }
}

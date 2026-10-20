import XCTest
@testable import LexCore

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

    func testInsertionPieceHasNoEdgeSpaces() {
        let sentence = "do you have idea?"
        let issues = EditMapper.issues(for: [AIEdit(original: "have idea", replacement: "have an idea", kind: .grammar, reason: "")], sentence: sentence, base: 0)
        XCTAssertEqual(issues.map(\.original), ["have"])
        XCTAssertEqual(issues.map { $0.replacements[0] }, ["have an"])
        let fixed = (sentence as NSString).replacingCharacters(in: issues[0].range, with: issues[0].replacements[0])
        XCTAssertEqual(fixed, "do you have an idea?")
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

    func testRemovingAWordTakesOneSpace() {
        func apply(_ sentence: String, _ word: String, _ replacement: String = "") -> String {
            let issues = EditMapper.issues(for: [AIEdit(original: word, replacement: replacement, kind: .grammar, reason: "")], sentence: sentence, base: 0)
            guard let i = issues.first else { return "no issue" }
            return (sentence as NSString).replacingCharacters(in: i.range, with: i.replacements[0])
        }
        XCTAssertEqual(apply("Remove function still bla doesn't work", "bla"), "Remove function still doesn't work")
        XCTAssertEqual(apply("It works bla", "bla"), "It works")
        XCTAssertEqual(apply("We need the the plan.", "the the", "the"), "We need the plan.")
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
        // Caret at the very start still means the whole first paragraph.
        let start = TextTargets.refineRange(in: text, selection: NSRange(location: 0, length: 0), scope: .paragraph)
        XCTAssertEqual(start.map { ns.substring(with: $0) }, "Para one. Still one.")
    }

    func testCaretStaysPutAcrossEdits() {
        func at(_ p: Int) -> NSRange { NSRange(location: p, length: 0) }
        // A fix before the cursor shifts it by the change in length.
        XCTAssertEqual(CaretMapper.map(at(13), before: "I cant go now", after: "I can't go now"), at(14))
        XCTAssertEqual(CaretMapper.map(at(11), before: "the the cat", after: "the cat"), at(7))
        // A fix after the cursor leaves it alone.
        XCTAssertEqual(CaretMapper.map(at(2), before: "I cant go now", after: "I can't go now"), at(2))
        // Inside the letters that changed ("ie" → "ei"): right after the new ones.
        XCTAssertEqual(CaretMapper.map(at(7), before: "we recieve it", after: "we receive it"), at(8))
        // A period added right at the cursor: the cursor goes after it.
        XCTAssertEqual(CaretMapper.map(at(9), before: "I am here", after: "I am here."), at(10))
        // A selection keeps covering the same words.
        XCTAssertEqual(CaretMapper.map(NSRange(location: 10, length: 3), before: "I cant go now", after: "I can't go now"),
                       NSRange(location: 11, length: 3))
        // Fixes applied last-first (as Fix All does) add up.
        var caret = at(24)
        var text = "Their going to recieve it"
        for (from, to) in [("recieve", "receive"), ("Their", "They're")] {
            let next = text.replacingOccurrences(of: from, with: to)
            caret = CaretMapper.map(caret, before: text, after: next)
            text = next
        }
        XCTAssertEqual(caret, at(26))
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

    func testFixAllPicksCorrectionsLastFirstWithoutOverlaps() {
        func issue(_ loc: Int, _ len: Int, _ kind: IssueKind, _ fix: [String]) -> Issue {
            Issue(range: NSRange(location: loc, length: len), original: "x", replacements: fix, kind: kind, message: "", source: .ai)
        }
        let picked = IssueComposer.fixes([
            issue(0, 5, .spelling, ["teh"]),
            issue(10, 4, .clarity, ["shorter"]),      // style: left for the user
            issue(20, 3, .grammar, []),               // nothing to apply
            issue(30, 6, .punctuation, ["a,"]),
            issue(33, 5, .spelling, ["b"]),           // overlaps the previous one
            issue(50, 2, .wordChoice, ["there"]),
        ])
        XCTAssertEqual(picked.map(\.range.location), [50, 30, 0])
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
        XCTAssertEqual(EditLineParser.parse("bla | (remove) | grammar | stray word")?.replacement, "")
        XCTAssertEqual(EditLineParser.parse("bla | [Delete] | grammar | stray word")?.replacement, "")
        XCTAssertEqual(EditLineParser.parse("erase | remove | word_choice | better verb")?.replacement, "remove")
        XCTAssertEqual(EditLineParser.parse("fuction || function | spelling | typo")?.replacement, "function")
        XCTAssertEqual(EditLineParser.parse("very |  | clarity | redundant")?.replacement, "")
        XCTAssertNil(EditLineParser.parse("the remove fuction is not working | | grammar"))
        XCTAssertEqual(EditLineParser.parse("fuction|function|spelling|typo")?.replacement, "function")
        XCTAssertNil(EditLineParser.parse("OK"))
        XCTAssertNil(EditLineParser.parse(""))
        XCTAssertNil(EditLineParser.parse("just some prose"))
    }

    func testLaterSelfCorrectionWins() {
        let resolved = EditLineParser.resolve([
            AIEdit(original: "bla", replacement: "blah", kind: .spelling, reason: ""),
            AIEdit(original: "doesnt", replacement: "doesn't", kind: .spelling, reason: ""),
            AIEdit(original: "bla", replacement: "", kind: .grammar, reason: "stray word"),
            AIEdit(original: "doesnt", replacement: "doesn't", kind: .spelling, reason: ""),
        ])
        XCTAssertEqual(resolved.map(\.replacement), ["", "doesn't", "doesn't"])
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

final class SpeechTests: XCTestCase {
    func testCleanCollapsesSpacingAndInvisibleCharacters() {
        XCTAssertEqual(SpeechText.clean("  Hello\u{200B}   world.\n\n\n Next\u{00A0}line  "), "Hello world.\nNext line")
    }

    func testFirstChunkIsShortAndNothingIsLost() {
        let text = (1...30).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let chunks = SpeechText.chunks(text)
        XCTAssertLessThanOrEqual(chunks[0].count, 90)
        XCTAssertLessThanOrEqual(chunks[1].count, 240)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1200 })
        XCTAssertEqual(chunks.joined(separator: " "), text)
    }

    func testLongOpeningSentenceSplitsAtAClause() {
        let text = "When you finish writing a long email to the whole team, Lex can read it back so you hear how it sounds. Then you send it."
        let chunks = SpeechText.chunks(text)
        XCTAssertEqual(chunks[0], "When you finish writing a long email to the whole team,")
        XCTAssertEqual(chunks.joined(separator: " "), text)
    }

    func testVeryLongSentenceIsSplitAtPunctuation() {
        let long = Array(repeating: "word", count: 600).joined(separator: " ") + ", end."
        let chunks = SpeechText.chunks(long)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1200 })
        XCTAssertEqual(chunks.joined(separator: " ").split(separator: " ").count, long.split(separator: " ").count)
    }

    func testLanguageToGoogleLocale() {
        XCTAssertEqual(GoogleTTS.locale(for: SpeechText.language(of: "This is a perfectly ordinary English sentence.")), "en-US")
        XCTAssertEqual(GoogleTTS.locale(for: SpeechText.language(of: "זה משפט רגיל בעברית שצריך להקריא בקול.")), "he-IL")
        XCTAssertEqual(GoogleTTS.locale(for: nil), "en-US")
    }

    func testGoogleRequestAndResponse() throws {
        let body = GoogleTTS.requestBody(text: "Hi", locale: "en-US", voice: "Kore")
        XCTAssertEqual((body["voice"] as? [String: String])?["name"], "en-US-Chirp3-HD-Kore")
        XCTAssertEqual((body["audioConfig"] as? [String: String])?["audioEncoding"], "MP3")
        let response = #"{"audioContent":"SUQz"}"#
        XCTAssertEqual(try GoogleTTS.audio(from: Data(response.utf8)), Data("ID3".utf8))
        XCTAssertThrowsError(try GoogleTTS.audio(from: Data("{}".utf8)))
    }

    func testElevenLabsVoicesParse() {
        let json = #"{"voices":[{"voice_id":"abc","name":"George"},{"voice_id":"def","name":"Rachel"}]}"#
        XCTAssertEqual(ElevenLabsTTS.voices(from: Data(json.utf8)).map(\.name), ["George", "Rachel"])
        XCTAssertEqual(ElevenLabsTTS.requestBody(text: "Hi", model: .flash)["model_id"] as? String, "eleven_flash_v2_5")
    }

    func testParsesGcloudSignIn() {
        let user = #"{"client_id":"id.apps","client_secret":"s","refresh_token":"r","type":"authorized_user","quota_project_id":"my-proj"}"#
        XCTAssertEqual(GoogleADC.parse(Data(user.utf8)), GoogleADC.Credentials(clientID: "id.apps", clientSecret: "s", refreshToken: "r", quotaProject: "my-proj"))
        let service = #"{"type":"service_account","private_key":"k","client_email":"x@y"}"#
        XCTAssertNil(GoogleADC.parse(Data(service.utf8)))
        XCTAssertEqual(String(decoding: GoogleADC.form(["a": "1/x+y", "b": "z"]), as: UTF8.self), "a=1%2Fx%2By&b=z")
    }

    func testCachedAudioIsReturnedWithoutAKey() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lex-speech-test-\(UUID().uuidString)")
        let client = SpeechClient(cacheDirectory: dir, adcFile: dir.appendingPathComponent("no-sign-in.json"))
        let request = SpeechClient.Request(text: "Hi there.", provider: .google, key: "", googleLocale: "en-US", googleVoice: "Kore", elevenVoiceID: "", elevenModel: .flash)
        do {
            _ = try await client.synthesize(request)
            XCTFail("expected a missing-key error")
        } catch {
            XCTAssertEqual(error as? SpeechError, .missingKey(.google))
        }
        try Data("ID3".utf8).write(to: dir.appendingPathComponent(request.cacheKey + ".mp3"))
        let hit = try await client.synthesize(request)
        XCTAssertTrue(hit.cached)
        XCTAssertEqual(hit.audio, Data("ID3".utf8))
        try? FileManager.default.removeItem(at: dir)
    }
}

final class DictationTests: XCTestCase {
    /// Seconds of "speech" (a loud tone) or "pause" (faint noise) at 16 kHz.
    func audio(_ parts: [(Double, Bool)]) -> [Int16] {
        var out: [Int16] = []
        var phase = 0.0
        for (seconds, loud) in parts {
            for _ in 0..<Int(seconds * 16_000) {
                phase += 2 * .pi * 220 / 16_000
                out.append(loud ? Int16(8000 * sin(phase)) : Int16.random(in: -40...40))
            }
        }
        return out
    }

    func testCutsAtAPauseAfterEnoughSpeech() {
        let a = audio([(9, true), (0.8, false), (3, true)])
        let cut = PauseSegmenter().cut(a[...])
        XCTAssertNotNil(cut)
        let seconds = Double(cut!) / 16_000
        XCTAssertTrue((9.0...9.8).contains(seconds), "cut at \(seconds)s")
    }

    func testDoesNotCutShortOrUnpausedAudio() {
        XCTAssertNil(PauseSegmenter().cut(audio([(4, true), (1, false), (2, true)])[...]))  // too short
        XCTAssertNil(PauseSegmenter().cut(audio([(9, true), (0.3, false), (3, true)])[...]))  // pause too brief
    }

    func testForcesACutAtTheMaximumLength() {
        let a = audio([(47, true)])
        let cut = PauseSegmenter().cut(a[...])
        XCTAssertNotNil(cut)
        XCTAssertLessThanOrEqual(Double(cut!) / 16_000, 47)
    }

    func testSilenceDetection() {
        XCTAssertTrue(PauseSegmenter.isSilent(audio([(1.5, false)])))
        XCTAssertFalse(PauseSegmenter.isSilent(audio([(0.3, false), (1.0, true), (0.3, false)])))
    }

    func testGoogleRequestAndTranscript() throws {
        let body = GoogleSTT.requestBody(audio: PCM16(samples: [1, 2, 3]), languages: ["en-US", "iw-IL"], phrases: ["Pelles", " "])
        let config = body["config"] as? [String: Any]
        XCTAssertEqual(config?["model"] as? String, "chirp_3")
        XCTAssertEqual(config?["languageCodes"] as? [String], ["en-US", "iw-IL"])
        XCTAssertNotNil(config?["adaptation"])
        XCTAssertEqual(GoogleSTT.url(project: "p").absoluteString, "https://us-speech.googleapis.com/v2/projects/p/locations/us/recognizers/_:recognize")
        let response = #"{"results":[{"alternatives":[{"transcript":"Hello there."}]},{"alternatives":[{"transcript":" How are you?"}]}]}"#
        XCTAssertEqual(try GoogleSTT.transcript(from: Data(response.utf8)), "Hello there. How are you?")
        XCTAssertEqual(try GoogleSTT.transcript(from: Data("{}".utf8)), "")
    }

    func testCleanupIsDiscardedWhenItStrays() {
        let raw = "um so I think we should uh ship it on Tuesday no wait Wednesday"
        XCTAssertEqual(DictationText.choose(cleaned: "So I think we should ship it on Wednesday.", raw: raw), "So I think we should ship it on Wednesday.")
        XCTAssertEqual(DictationText.choose(cleaned: String(repeating: "Here is a long answer instead. ", count: 10), raw: raw), raw)
        XCTAssertEqual(DictationText.choose(cleaned: nil, raw: raw), raw)
        // A translation from Hebrew runs longer on the page; it still goes in.
        let hebrew = "אני חושב שכדאי לשחרר את זה ביום רביעי"
        let english = "I think we should ship it on Wednesday, once the team has had a look at it."
        XCTAssertEqual(DictationText.choose(cleaned: english, raw: hebrew, translated: true), english)
    }

    func testSpacingBeforeInsertedText() {
        XCTAssertEqual(DictationText.spaced("hello", after: "d"), " hello")
        XCTAssertEqual(DictationText.spaced("hello", after: " "), "hello")
        XCTAssertEqual(DictationText.spaced(", then", after: "d"), ", then")
        XCTAssertEqual(DictationText.spaced("hello", after: "("), "hello")
        XCTAssertEqual(DictationText.spaced("hello", after: nil), "hello")
    }

    func testAutoEngineFollowsTheKeyboard() {
        XCTAssertEqual(DictationEngine.auto.resolved(keyboardLanguage: "en", appleAvailable: true), .apple)
        XCTAssertEqual(DictationEngine.auto.resolved(keyboardLanguage: "he", appleAvailable: true), .google)
        XCTAssertEqual(DictationEngine.auto.resolved(keyboardLanguage: "en", appleAvailable: false), .google)
        XCTAssertEqual(DictationEngine.apple.resolved(keyboardLanguage: "he", appleAvailable: false), .google)
    }

    func testTidyOnlyWhenItHelps() {
        XCTAssertFalse(DictationText.needsTidy("Sounds good, see you at three."))
        XCTAssertTrue(DictationText.needsTidy("Um, so I think we should ship it."))
        XCTAssertTrue(DictationText.needsTidy("Ship it Tuesday, no wait, Wednesday."))
        XCTAssertTrue(DictationText.needsTidy("אממ אני חושב שכדאי"))
        XCTAssertTrue(DictationText.needsTidy(String(repeating: "word ", count: 30)))
    }

    func testDictationPrompt() {
        let user = Prompts.dictationUser(transcript: "hi", app: "Slack", before: "Thanks,", words: ["Pelles", ""])
        XCTAssertTrue(user.contains("<app>Slack</app>"))
        XCTAssertTrue(user.contains("<words>Pelles</words>"))
        XCTAssertTrue(user.hasSuffix("<transcript>hi</transcript>"))
    }
}

final class AssistTests: XCTestCase {
    func testTranslationGoesBetweenHebrewAndEnglish() {
        XCTAssertEqual(Translation.target(for: "זה משפט בעברית שצריך לתרגם לאנגלית בבקשה."), "English")
        XCTAssertEqual(Translation.target(for: "This is an ordinary English sentence to translate."), "Hebrew")
        XCTAssertTrue(Translation.action(for: "Hello there, how are you today?").instruction.contains("Hebrew"))
    }

    let snippets = [
        Snippet(name: "my calendar link", trigger: ";cal", text: "https://cal.example.com/me"),
        Snippet(name: "signature", trigger: ";sig", text: "Best,\nMatan"),
    ]

    func testSpokenSnippets() {
        XCTAssertEqual(Snippets.spokenMatch("My calendar link.", in: snippets)?.trigger, ";cal")
        XCTAssertEqual(Snippets.spokenMatch("insert my calendar link", in: snippets)?.trigger, ";cal")
        XCTAssertEqual(Snippets.spokenMatch("Paste signature!", in: snippets)?.trigger, ";sig")
        XCTAssertNil(Snippets.spokenMatch("Here is my calendar link for Tuesday", in: snippets))
    }

    func testTypedSnippets() {
        let text = "Book a slot here: ;cal "
        let hit = Snippets.typedExpansion(in: text, caret: (text as NSString).length, snippets: snippets)
        XCTAssertEqual(hit?.snippet.trigger, ";cal")
        XCTAssertEqual(hit.map { (text as NSString).substring(with: $0.range) }, ";cal")
        XCTAssertNil(Snippets.typedExpansion(in: "Book;cal ", caret: 9, snippets: snippets))    // must start a word
        XCTAssertNil(Snippets.typedExpansion(in: "here ;cal", caret: 9, snippets: snippets))    // not finished yet
        XCTAssertNotNil(Snippets.typedExpansion(in: ";sig\n", caret: 5, snippets: snippets))
    }

    func testAppStyles() {
        XCTAssertEqual(WritingContext.of(bundleID: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(WritingContext.of(bundleID: "com.apple.mail"), .email)
        XCTAssertEqual(WritingContext.of(bundleID: "company.thebrowser.dia"), .other)
    }

    func testNameLikeWords() {
        XCTAssertTrue(Learning.isNameLike("Pelles"))
        XCTAssertTrue(Learning.isNameLike("AppFab"))
        XCTAssertTrue(Learning.isNameLike("SOC"))
        XCTAssertFalse(Learning.isNameLike("recieve"))
        XCTAssertFalse(Learning.isNameLike("x"))
        XCTAssertFalse(Learning.isNameLike("Pel1es"))
        // Claude fixed "Recieve" but left "Pelles" alone: only the name is a candidate.
        let edits = [AIEdit(original: "Recieve", replacement: "Receive", kind: .spelling, reason: "")]
        XCTAssertEqual(Learning.acceptedNames(flagged: ["Pelles", "Recieve", "Pelles", "teh"], edits: edits), ["Pelles"])
    }

    func testPromptsCarryStyleVoiceAndTranslation() {
        let d = Prompts.dictationUser(transcript: "hi", app: "Slack", before: "", words: [], style: "Casual", voice: "Short sentences", translateTo: "English")
        XCTAssertTrue(d.contains("<style>Casual</style>") && d.contains("<voice>Short sentences</voice>") && d.contains("<translate>English</translate>"))
        let r = Prompts.refineUser(text: "x", context: "", instruction: "y", style: "Casual")
        XCTAssertTrue(r.hasPrefix("<style>Casual</style>"))
    }
}

/// Answers Google's token endpoint with canned statuses, counting the requests.
final class TokenStub: URLProtocol {
    static var statuses: [Int] = []
    static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests += 1
        let status = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        let body = status == 200 ? #"{"access_token":"tok","expires_in":3600}"#
            : #"{"error":"invalid_grant","error_description":"reauth related error (invalid_rapt)"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class GoogleSignInTests: XCTestCase {
    private var dir: URL!
    private var file: URL!
    private var adc: GoogleADC!
    private var changes: [Bool] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("adc.json")
        try Data(#"{"type":"authorized_user","client_id":"id","client_secret":"s","refresh_token":"r","quota_project_id":"p"}"#.utf8).write(to: file)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TokenStub.self]
        adc = GoogleADC(file: file, session: URLSession(configuration: config))
        changes = []
        adc.onExpiredChange = { [unowned self] in self.changes.append($0) }
        TokenStub.statuses = []
        TokenStub.requests = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testExpiredSignInFailsFastUntilANewOneIsSaved() async throws {
        TokenStub.statuses = [400]
        do { _ = try await adc.accessToken(); XCTFail("expected an expired sign-in") } catch {
            XCTAssertEqual(error as? SpeechError, .signInExpired)
        }
        XCTAssertTrue(adc.isExpired)
        // No new sign-in yet: fails at once, without asking Google again.
        do { _ = try await adc.accessToken(); XCTFail("expected an expired sign-in") } catch {
            XCTAssertEqual(error as? SpeechError, .signInExpired)
        }
        XCTAssertEqual(TokenStub.requests, 1)

        // gcloud saves a new sign-in: Lex asks again, and it works.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        let token = try await adc.accessToken()
        XCTAssertEqual(token.token, "tok")
        XCTAssertEqual(token.quotaProject, "p")
        XCTAssertFalse(adc.isExpired)
        XCTAssertEqual(changes, [true, false])
    }

    func testServerErrorIsNotAnExpiredSignIn() async throws {
        TokenStub.statuses = [503]
        do { _ = try await adc.accessToken(); XCTFail("expected an error") } catch {
            XCTAssertNotEqual(error as? SpeechError, .signInExpired)
        }
        XCTAssertFalse(adc.isExpired)
        // The next try goes to Google again and succeeds.
        let token = try await adc.accessToken()
        XCTAssertEqual(token.token, "tok")
        XCTAssertEqual(TokenStub.requests, 2)
        XCTAssertEqual(changes, [])
    }
}

final class ClipboardTests: XCTestCase {
    private func text(_ s: String) -> ClipData { [[ClipTypes.plainText: Data(s.utf8)]] }

    private func tempStore(retention: TimeInterval = 30 * 86400, maxItems: Int = 1000) -> (ClipboardStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (ClipboardStore(directory: dir, retention: retention, maxItems: maxItems), dir)
    }

    func testPrivateCopiesAndPasswordManagersAreSkipped() {
        XCTAssertFalse(ClipPolicy.shouldRecord(types: [ClipTypes.plainText, "org.nspasteboard.ConcealedType"], appID: "com.apple.Safari", ignoredApps: []))
        XCTAssertFalse(ClipPolicy.shouldRecord(types: [ClipTypes.plainText, "org.nspasteboard.TransientType"], appID: nil, ignoredApps: []))
        XCTAssertFalse(ClipPolicy.shouldRecord(types: [ClipTypes.plainText], appID: "com.1password.1password", ignoredApps: ClipPolicy.defaultIgnoredApps))
        XCTAssertTrue(ClipPolicy.shouldRecord(types: [ClipTypes.plainText], appID: "com.apple.Safari", ignoredApps: ClipPolicy.defaultIgnoredApps))
        XCTAssertFalse(ClipPolicy.keeps("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu"))
        XCTAssertTrue(ClipPolicy.keeps("public.rtf"))
    }

    func testKinds() {
        XCTAssertEqual(ClipPolicy.describe(text("hello"))?.kind, .text)
        XCTAssertEqual(ClipPolicy.describe(text("https://example.com/a?b=1"))?.kind, .link)
        XCTAssertEqual(ClipPolicy.describe(text("see https://example.com"))?.kind, .text)
        XCTAssertEqual(ClipPolicy.describe([[ClipTypes.png: Data([1, 2, 3])]])?.kind, .image)
        let file = ClipPolicy.describe([[ClipTypes.fileURL: Data("file:///Users/me/Report.pdf".utf8)]])
        XCTAssertEqual(file?.kind, .files)
        XCTAssertEqual(file?.text, "/Users/me/Report.pdf")
        XCTAssertNil(ClipPolicy.describe(text("   ")))
    }

    func testCopyingAgainMovesToTopInsteadOfDuplicating() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = store.add(text("one"), appID: "a", appName: "A", date: Date(timeIntervalSinceNow: -60))
        store.add(text("two"), appID: "a", appName: "A")
        store.add(text("one"), appID: "b", appName: "B")
        XCTAssertEqual(store.items.map(\.text), ["one", "two"])
        XCTAssertEqual(store.items.first?.id, first?.id)
        XCTAssertEqual(store.items.first?.appName, "B")
        // The full data comes back for pasting, rich types included.
        let rich: ClipData = [[ClipTypes.plainText: Data("bold".utf8), "public.rtf": Data("{\\rtf1 \\b bold}".utf8)]]
        let item = store.add(rich, appID: nil, appName: nil)!
        XCTAssertEqual(store.data(for: item.id)?.first?["public.rtf"], rich[0]["public.rtf"])
    }

    func testRetentionPinsAndPersistence() {
        let (store, dir) = tempStore(retention: 86400, maxItems: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = store.add(text("old"), appID: nil, appName: nil, date: Date(timeIntervalSinceNow: -2 * 86400))!
        store.togglePin(old.id)
        store.add(text("a"), appID: nil, appName: nil)
        store.add(text("b"), appID: nil, appName: nil)
        store.add(text("c"), appID: nil, appName: nil)
        store.prune()
        // Pinned survives age and the cap; only the newest two unpinned stay.
        XCTAssertEqual(store.ordered.map(\.text), ["old", "c", "b"])

        let reopened = ClipboardStore(directory: dir, retention: 86400, maxItems: 2)
        reopened.load()
        XCTAssertEqual(reopened.ordered.map(\.text), ["old", "c", "b"])
        XCTAssertNotNil(reopened.data(for: old.id))

        reopened.clear()
        XCTAssertEqual(reopened.items.map(\.text), ["old"])
    }

    func testSearch() {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.add(text("Meeting on Wednesday at the café"), appID: nil, appName: "Slack")
        store.add(text("Invoice 2026-10"), appID: nil, appName: "Mail")
        XCTAssertEqual(ClipboardStore.search(store.items, "cafe wednesday").map(\.appName), ["Slack"])
        XCTAssertEqual(ClipboardStore.search(store.items, "mail").map(\.text), ["Invoice 2026-10"])
        XCTAssertEqual(ClipboardStore.search(store.items, "").count, 2)
    }
}

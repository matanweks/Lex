import Combine
import LexCore
import UIKit

/// Typing on the Lex keyboard: pages, shift, auto-capitals, the suggestion bar (completions
/// and next-word predictions from the word lists and what you type), autocorrect, your iOS
/// text replacements and contacts' names, Claude's fixes for each sentence you finish, and
/// Claude's guess at the rest of a sentence when you pause.
@MainActor
final class Typist: ObservableObject {
    /// One slot in the suggestion bar, which is laid out like Gboard's: the best in the middle.
    struct Suggestion: Identifiable, Hashable {
        enum Kind { case keep, word }
        let text: String
        let kind: Kind
        var best = false
        var id: String { text }
    }

    /// A fix Claude suggested for a sentence you finished, kept relative to that sentence so
    /// it still applies after you type on.
    struct Fix: Identifiable, Equatable {
        let id = UUID()
        var sentence: String
        var offset: Int
        let length: Int
        let original: String
        let replacement: String
    }

    @Published private(set) var page = KeyboardPage.letters
    @Published private(set) var language: KeyboardLanguage
    @Published private(set) var shift = KeyGridView.Shift.off
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var fixes: [Fix] = []
    @Published private(set) var checking = false
    /// The rest of the sentence, as Claude guesses it (Smart Compose).
    @Published private(set) var completion: String?

    weak var controller: KeyboardViewController?
    var onLanguage: ((KeyboardLanguage) -> Void)?
    var onEmoji: (() -> Void)?
    /// Claude can be asked (Full Access and a key).
    var canCheck: () -> Bool = { false }
    /// Private mode: nothing is learned.
    var isPrivate: () -> Bool = { false }
    let settings: KeyboardSettings

    private let checker = UITextChecker()
    private var replacements: [String: String] = [:]
    /// Your contacts' names, lowercased → as written.
    private var names: [String: String] = [:]
    /// Read when the keyboard opens: the settings are in the Keychain, slower to read per key.
    private var quickModel = ClaudeModel.haiku
    private var composeTask: Task<Void, Never>?
    /// The text Claude's guess follows on from, and the guess.
    private var compose: (base: String, text: String)?
    private var lexiconsLoaded: AnyCancellable?
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast
    private var autoShifted = false
    /// Delete right after an autocorrection puts back what you typed.
    private var undoCorrection: (typed: String, original: String)?
    private var checkTask: Task<Void, Never>?
    private var checkedSentence = ""
    /// What you type, learned on this phone for suggestions (never sent anywhere).
    private var words = WordModel()
    private var unsaved = 0
    private static var wordsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("words.json")
    }

    init(settings: KeyboardSettings) {
        self.settings = settings
        language = KeyboardLanguage(rawValue: UserDefaults.standard.string(forKey: "layoutLanguage") ?? "") ?? .english
        if let data = try? Data(contentsOf: Self.wordsFile), let saved = try? JSONDecoder().decode(WordModel.self, from: data) { words = saved }
        // The bar shows the word lists' words as soon as they're read.
        lexiconsLoaded = NotificationCenter.default.publisher(for: Self.lexiconsLoadedNote).receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.afterChange()
        }
        Self.loadLexicons()
    }

    var look: KeyGridView.Look {
        let ret = controller?.returnLook ?? ("return", false)
        return KeyGridView.Look(rows: KeyboardLayout.rows(page, language, numberRow: settings.numberRow),
                                shift: page == .letters && language == .english ? shift : .off,
                                returnLabel: ret.0, returnProminent: ret.1, language: language, numberRow: settings.numberRow)
    }

    // MARK: Word lists

    /// English and Hebrew, from the files in the keyboard (made by scripts/make-words.py).
    /// Kept for as long as iOS keeps the keyboard running, since it makes a new one each time.
    private static var lexicons: [KeyboardLanguage: Lexicon] = [:]
    private static var loading = false
    private static let lexiconsLoadedNote = Notification.Name("LexWordListsLoaded")

    private var lexicon: Lexicon { Self.lexicons[language] ?? .empty }

    /// The word list for a word's own script, whichever layout typed it.
    private func lexicon(for word: String) -> Lexicon {
        if word.contains(where: { TypingRules.hebrewLetters.contains($0) }) { return Self.lexicons[.hebrew] ?? .empty }
        if word.contains(where: { $0.isASCII && $0.isLetter }) { return Self.lexicons[.english] ?? .empty }
        return lexicon
    }

    private static func loadLexicons() {
        guard !loading, lexicons.isEmpty else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let start = Date()
            for language in KeyboardLanguage.allCases {
                guard let words = Bundle.main.url(forResource: language.rawValue, withExtension: "words").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
                      let next = Bundle.main.url(forResource: language.rawValue, withExtension: "next").flatMap({ try? String(contentsOf: $0, encoding: .utf8) })
                else { continue }
                let lexicon = Lexicon(wordsFile: words, nextFile: next)
                await MainActor.run {
                    lexicons[language] = lexicon
                    NotificationCenter.default.post(name: lexiconsLoadedNote, object: nil)
                }
            }
            voiceLog.info("word lists read in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    /// True while the text field is empty: the bar shows Lex's shortcuts instead of words.
    var fieldIsEmpty: Bool { (controller?.before ?? "").isEmpty && (controller?.textDocumentProxy.documentContextAfterInput ?? "").isEmpty }

    func saveWords() {
        guard unsaved > 0, let data = try? JSONEncoder().encode(words) else { return }
        try? FileManager.default.createDirectory(at: Self.wordsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.wordsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        unsaved = 0
    }

    func forgetWords() {
        words = WordModel()
        try? FileManager.default.removeItem(at: Self.wordsFile)
        afterChange()
    }

    /// Learns the word right before the cursor as a finished word (a space or punctuation follows).
    private func learnWord(before text: String) {
        guard controller?.correctsText == true, !isPrivate() else { return }
        let word = TypingRules.currentWord(text)
        guard !word.isEmpty else { return }
        let start = TypingRules.startsSentence(String(text.dropLast(word.count)))
        words.learn(word, after: start ? nil : Predictor.previousWord(text), atSentenceStart: start)
        unsaved += 1
        if unsaved >= 15 { saveWords() }
    }

    /// When the keyboard comes up: your text replacements and contacts' names, and digits for
    /// number fields.
    func appeared() {
        quickModel = Prefs.quickModel
        controller?.requestSupplementaryLexicon { [weak self] lexicon in
            // iOS lists names (from your contacts and your own card) as entries that type themselves.
            let isName = { (entry: UILexiconEntry) in entry.userInput.lowercased() == entry.documentText.lowercased() }
            let replacements = Dictionary(lexicon.entries.filter { !isName($0) }.map { ($0.userInput.lowercased(), $0.documentText) }, uniquingKeysWith: { a, _ in a })
            let names = Dictionary(lexicon.entries.filter(isName).map { ($0.documentText.lowercased(), $0.documentText) }, uniquingKeysWith: { a, _ in a })
            Task { @MainActor in
                self?.replacements = replacements
                self?.names = names
            }
        }
        if let type = controller?.textDocumentProxy.keyboardType, [.numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad].contains(type) {
            page = .numbers
        } else {
            page = .letters
        }
        afterChange()
    }

    // MARK: Keys

    func press(_ action: KeyAction) {
        guard let c = controller else { return }
        switch action {
        case .character(let ch):
            if ",.!?;:)".contains(ch) { learnWord(before: c.before) }
            c.type(page == .letters && shift != .off ? ch.uppercased() : ch)
            undoCorrection = nil
            if shift == .on { shift = .off; autoShifted = false }
            if page != .letters, ch == "'" { page = .letters }
            if ch == "." || ch == "?" || ch == "!" { lastSpaceTap = .distantPast }
        case .space:
            space(c)
        case .returnKey:
            learnWord(before: c.before)
            c.type("\n")
            undoCorrection = nil
            sentenceMayHaveEnded()
        case .delete:
            if let undo = undoCorrection, c.before.hasSuffix(undo.typed) {
                c.deleteBackward(undo.typed.count)
                c.type(undo.original)
                undoCorrection = nil
                // You meant it: it isn't corrected again.
                if !isPrivate() { words.keep(undo.original); unsaved += 1 }
            } else {
                c.deleteBackward()
            }
        case .shift:
            let now = Date()
            if shift == .locked {
                shift = .off
            } else if now.timeIntervalSince(lastShiftTap) < 0.35 {
                shift = .locked
            } else {
                shift = shift == .on ? .off : .on
            }
            autoShifted = false
            lastShiftTap = now
            return
        case .numbers: page = .numbers
        case .symbols: page = .symbols
        case .letters: page = .letters
        case .language:
            switchLanguage()
        case .emoji:
            onEmoji?()
            return
        }
        afterChange()
    }

    func switchLanguage() {
        language = language.other
        UserDefaults.standard.set(language.rawValue, forKey: "layoutLanguage")
        page = .letters
        onLanguage?(language)
    }

    /// Types text from elsewhere on the keyboard (an emoji), like a key.
    func type(_ text: String) {
        controller?.type(text)
        undoCorrection = nil
        afterChange()
    }

    /// A long-press alternate (a digit, an accented letter): typed like its key.
    func typeAlternate(_ text: String) {
        controller?.type(text)
        undoCorrection = nil
        if shift == .on { shift = .off; autoShifted = false }
        afterChange()
    }

    /// Sliding on the space bar.
    func moveCursor(by characters: Int) {
        controller?.moveCursor(by: characters)
        undoCorrection = nil
        afterChange()
    }

    /// Held or swiped delete: whole words.
    func deleteWords(_ count: Int) {
        guard let c = controller else { return }
        let n = TypingRules.charactersToDelete(words: count, in: c.before)
        guard n > 0 else { return }
        c.deleteBackward(n)
        undoCorrection = nil
        afterChange()
    }

    private func space(_ c: KeyboardViewController) {
        let before = c.before
        // Two quick spaces after a word end the sentence.
        if Date().timeIntervalSince(lastSpaceTap) < 0.45, TypingRules.doubleSpaceMakesPeriod(before) {
            c.deleteBackward()
            c.type(". ")
            lastSpaceTap = .distantPast
            undoCorrection = nil
            sentenceMayHaveEnded()
            return
        }
        lastSpaceTap = Date()
        let word = TypingRules.currentWord(before)
        if !word.isEmpty, let fixed = replacements[word.lowercased()] ?? nameForm(word) ?? autocorrection(word) {
            c.deleteBackward(word.count)
            c.type(fixed)
            learnWord(before: c.before)
            c.type(" ")
            undoCorrection = (fixed + " ", word)
        } else {
            learnWord(before: before)
            c.type(" ")
            undoCorrection = nil
        }
        if page != .letters { page = .letters }
        sentenceMayHaveEnded()
    }

    // MARK: After each change

    /// Auto-capitals and the suggestion bar follow the text before the cursor.
    func afterChange() {
        guard let c = controller else { return }
        let before = c.before
        if language == .english, page == .letters, shift != .locked {
            let wants = c.autocapitalizes && TypingRules.startsSentence(before)
            if wants, shift == .off {
                shift = .on
                autoShifted = true
            } else if !wants, shift == .on, autoShifted {
                shift = .off
                autoShifted = false
            }
        }
        suggestions = suggestions(before)
        if let first = fixes.first, !before.contains(first.sentence) { fixes = [] }
        followCompletion(before)
    }

    /// While typing a word: the word as typed, the best completion (middle) and one more.
    /// After a space: the three likeliest next words, the best in the middle.
    private func suggestions(_ before: String) -> [Suggestion] {
        guard controller?.correctsText == true else { return [] }
        let word = TypingRules.currentWord(before)
        let start = TypingRules.startsSentence(String(before.dropLast(word.count)))
        let previous = start ? nil : Predictor.previousWord(before)
        var system: [String] = []
        var guesses: [String] = []
        let lang = language.checkerCode
        if !word.isEmpty, UITextChecker.availableLanguages.contains(lang) {
            let lower = word.lowercased()
            let range = NSRange(location: 0, length: (lower as NSString).length)
            system = checker.completions(forPartialWordRange: range, in: lower, language: lang) ?? []
            if checker.rangeOfMisspelledWord(in: lower, range: range, startingAt: 0, wrap: false, language: lang).location != NSNotFound {
                guesses = checker.guesses(forWordRange: range, in: lower, language: lang) ?? []
            }
        }
        let list = lexicon(for: word.isEmpty ? previous ?? "" : word)
        if !word.isEmpty, let fix = TypingRules.hebrewCorrection(for: word, lexicon: list) { guesses.insert(fix, at: 0) }
        if !word.isEmpty, let phrase = replacements[word.lowercased()] { guesses.insert(phrase, at: 0) }
        var picks = Predictor.suggestions(prefix: word, previous: previous, atSentenceStart: start, system: system, guesses: guesses,
                                          model: words, seed: .for(language), lexicon: list, names: names)
        if !word.isEmpty, word.first?.isUppercase == true { picks = picks.map { TypingRules.matchCase($0, to: word) } }
        guard !word.isEmpty else {
            // Gboard order: second, best, third.
            let order = [1, 0, 2].filter { $0 < picks.count }
            return order.map { Suggestion(text: picks[$0], kind: .word, best: $0 == 0) }
        }
        return [Suggestion(text: word, kind: .keep)] + picks.prefix(2).enumerated().map { Suggestion(text: $0.element, kind: .word, best: $0.offset == 0) }
    }

    /// A suggestion was tapped: it replaces the word being typed (the first keeps it as typed).
    func choose(_ suggestion: Suggestion) {
        guard let c = controller else { return }
        let word = TypingRules.currentWord(c.before)
        if suggestion.kind == .keep {
            UITextChecker.learnWord(word)
            if !isPrivate() { words.keep(word); unsaved += 1 }
        } else {
            c.deleteBackward(word.count)
            c.type(suggestion.text)
        }
        learnWord(before: c.before)
        c.type(" ")
        undoCorrection = nil
        sentenceMayHaveEnded()
        afterChange()
    }

    /// A contact's name typed in lowercase gets its capitals, unless it's also a common word
    /// ("will", "rose").
    private func nameForm(_ word: String) -> String? {
        guard let name = names[word.lowercased()], word == word.lowercased(), name != word, !lexicon(for: word).contains(word) else { return nil }
        return name
    }

    private func autocorrection(_ word: String) -> String? {
        guard let c = controller, c.correctsText, settings.autocorrect, words.count(word) < 2, names[word.lowercased()] == nil else { return nil }
        if word.contains(where: { TypingRules.hebrewLetters.contains($0) }) { return TypingRules.hebrewCorrection(for: word, lexicon: lexicon(for: word)) }
        guard language == .english else { return nil }
        guard !UITextChecker.hasLearnedWord(word), UITextChecker.availableLanguages.contains(language.checkerCode) else { return nil }
        let lower = word.lowercased()
        let range = NSRange(location: 0, length: (lower as NSString).length)
        guard checker.rangeOfMisspelledWord(in: lower, range: range, startingAt: 0, wrap: false, language: language.checkerCode).location != NSNotFound else { return nil }
        let start = TypingRules.startsSentence(String(c.before.dropLast(word.count)))
        let guesses = checker.guesses(forWordRange: range, in: lower, language: language.checkerCode) ?? []
        return TypingRules.autocorrection(for: word, guesses: guesses, atSentenceStart: start, lexicon: lexicon(for: word))
    }

    // MARK: Claude's fixes

    /// A sentence just ended: Claude checks it, and its fixes show in the suggestion bar.
    private func sentenceMayHaveEnded() {
        guard canCheck(), let c = controller, c.correctsText, settings.checkSentences else { return }
        let before = c.before
        guard let sentence = CursorEdit.justFinishedSentence(before), sentence.text != checkedSentence,
              sentence.text.split(whereSeparator: \.isWhitespace).count >= 2 else { return }
        checkedSentence = sentence.text
        let context = String((before as NSString).substring(to: sentence.range.location).suffix(400))
        checkTask?.cancel()
        checking = true
        checkTask = Task {
            let edits = (try? await LexEngine.claude.check(sentence: sentence.text, before: context, finished: true, model: quickModel)) ?? []
            guard !Task.isCancelled else { return }
            checking = false
            fixes = EditMapper.issues(for: edits, sentence: sentence.text, base: 0).map {
                Fix(sentence: sentence.text, offset: $0.range.location, length: $0.range.length,
                    original: $0.original, replacement: $0.replacements.first ?? "")
            }
            voiceLog.info("sentence check: \(edits.count) edits, \(self.fixes.count) fixes")
        }
    }

    /// Makes the chosen fixes in the text, wherever the sentence now is before the cursor.
    func apply(_ chosen: [Fix]) {
        guard let c = controller, let first = chosen.first else { return }
        let before = c.before
        let at = (before as NSString).range(of: first.sentence, options: .backwards)
        guard at.location != NSNotFound,
              let plan = CursorEdit.plan(chosen.map { TextFix(range: NSRange(location: at.location + $0.offset, length: $0.length), original: $0.original, replacement: $0.replacement) }, in: before)
        else {
            fixes = []
            return
        }
        c.deleteBackward(plan.delete)
        c.type(plan.type)
        // The rest of the fixes move with the text the chosen ones changed.
        var rest = fixes.filter { fix in !chosen.contains(fix) }
        var sentence = first.sentence as NSString
        for fix in chosen.sorted(by: { $0.offset > $1.offset }) {
            sentence = sentence.replacingCharacters(in: NSRange(location: fix.offset, length: fix.length), with: fix.replacement) as NSString
            let delta = (fix.replacement as NSString).length - fix.length
            rest = rest.map { var r = $0; if r.offset > fix.offset { r.offset += delta }; return r }
        }
        fixes = rest.map { var r = $0; r.sentence = sentence as String; return r }
        checkedSentence = sentence as String
        undoCorrection = nil
        afterChange()
    }

    func dismissFixes() { fixes = [] }

    // MARK: The rest of the sentence

    /// After a word and a space, a pause asks Claude how the sentence ends. The guess stays
    /// while what you type matches it.
    private func followCompletion(_ before: String) {
        if let guess = compose, before.hasPrefix(guess.base) {
            let typed = String(before.dropFirst(guess.base.count))
            if typed.count < guess.text.count, guess.text.hasPrefix(typed) {
                completion = String(guess.text.dropFirst(typed.count))
                return
            }
        }
        compose = nil
        completion = nil
        composeTask?.cancel()
        guard wantsCompletion(before) else { return }
        composeTask = Task {
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled, controller?.before == before else { return }
            let text = (try? await LexEngine.claude.completion(before: String(before.suffix(600)), model: quickModel)) ?? ""
            guard !Task.isCancelled, !text.isEmpty, controller?.before == before else { return }
            compose = (before, text)
            completion = text
            voiceLog.info("sentence completion: \(text.split(separator: " ").count) words")
        }
    }

    /// Right after a space that follows a word, at the end of the text, with a sentence
    /// under way.
    private func wantsCompletion(_ before: String) -> Bool {
        guard settings.completeSentences, canCheck(), let c = controller, c.correctsText, fixes.isEmpty,
              before.hasSuffix(" "), !before.hasSuffix("  "), let last = before.dropLast().last,
              last.isLetter || last.isNumber || last == "," || last == "'",
              (c.textDocumentProxy.documentContextAfterInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let sentence = before.split(whereSeparator: { ".!?\n".contains($0) }).last ?? ""
        return sentence.split(separator: " ").count >= 2
    }

    func acceptCompletion() {
        guard let c = controller, let text = completion else { return }
        compose = nil
        completion = nil
        c.type(text)
        if !(text.last?.isWhitespace ?? true) { c.type(" ") }
        undoCorrection = nil
        sentenceMayHaveEnded()
        afterChange()
    }
}

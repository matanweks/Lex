import LexCore
import UIKit

/// Typing on the Lex keyboard: pages, shift, auto-capitals, the suggestion bar, autocorrect,
/// your iOS text replacements, and Claude's fixes for each sentence you finish.
@MainActor
final class Typist: ObservableObject {
    struct Suggestion: Identifiable, Hashable {
        enum Kind { case keep, complete, correct }
        let text: String
        let kind: Kind
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

    weak var controller: KeyboardViewController?
    var onLanguage: ((KeyboardLanguage) -> Void)?
    var onEmoji: (() -> Void)?
    /// Claude can be asked (Full Access and a key).
    var canCheck: () -> Bool = { false }

    private let checker = UITextChecker()
    private var replacements: [String: String] = [:]
    private var lastShiftTap = Date.distantPast
    private var lastSpaceTap = Date.distantPast
    private var autoShifted = false
    /// Delete right after an autocorrection puts back what you typed.
    private var undoCorrection: (typed: String, original: String)?
    private var checkTask: Task<Void, Never>?
    private var checkedSentence = ""

    init() {
        language = KeyboardLanguage(rawValue: UserDefaults.standard.string(forKey: "layoutLanguage") ?? "") ?? .english
    }

    var look: KeyGridView.Look {
        let ret = controller?.returnLook ?? ("return", false)
        return KeyGridView.Look(rows: KeyboardLayout.rows(page, language),
                                shift: page == .letters && language == .english ? shift : .off,
                                returnLabel: ret.0, returnProminent: ret.1)
    }

    /// When the keyboard comes up: your text replacements, and digits for number fields.
    func appeared() {
        controller?.requestSupplementaryLexicon { [weak self] lexicon in
            Task { @MainActor in
                self?.replacements = Dictionary(lexicon.entries.map { ($0.userInput.lowercased(), $0.documentText) }, uniquingKeysWith: { a, _ in a })
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
            c.type(page == .letters && shift != .off ? ch.uppercased() : ch)
            undoCorrection = nil
            if shift == .on { shift = .off; autoShifted = false }
            if page != .letters, ch == "'" { page = .letters }
            if ch == "." || ch == "?" || ch == "!" { lastSpaceTap = .distantPast }
        case .space:
            space(c)
        case .returnKey:
            c.type("\n")
            undoCorrection = nil
            sentenceMayHaveEnded()
        case .delete:
            if let undo = undoCorrection, c.before.hasSuffix(undo.typed) {
                c.deleteBackward(undo.typed.count)
                c.type(undo.original)
                undoCorrection = nil
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
            language = language.other
            UserDefaults.standard.set(language.rawValue, forKey: "layoutLanguage")
            page = .letters
            onLanguage?(language)
        case .emoji:
            onEmoji?()
            return
        }
        afterChange()
    }

    /// Types text from elsewhere on the keyboard (an emoji), like a key.
    func type(_ text: String) {
        controller?.type(text)
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
        if !word.isEmpty, let fixed = replacements[word.lowercased()] ?? autocorrection(word) {
            c.deleteBackward(word.count)
            c.type(fixed + " ")
            undoCorrection = (fixed + " ", word)
        } else {
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
        suggestions = suggestions(for: TypingRules.currentWord(before))
        if let first = fixes.first, !before.contains(first.sentence) { fixes = [] }
    }

    private func suggestions(for word: String) -> [Suggestion] {
        guard !word.isEmpty, controller?.correctsText == true else { return [] }
        var found: [String] = []
        if let phrase = replacements[word.lowercased()] { found.append(phrase) }
        let lang = language.checkerCode
        var misspelled = false
        if UITextChecker.availableLanguages.contains(lang) {
            let range = NSRange(location: 0, length: (word as NSString).length)
            misspelled = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: lang).location != NSNotFound
            if misspelled { found += checker.guesses(forWordRange: range, in: word, language: lang) ?? [] }
            found += checker.completions(forPartialWordRange: range, in: word, language: lang) ?? []
        }
        var seen: Set<String> = [word.lowercased()]
        let picks = found.map { TypingRules.matchCase($0, to: word) }.filter { seen.insert($0.lowercased()).inserted }.prefix(2)
        return [Suggestion(text: word, kind: .keep)] + picks.map { Suggestion(text: $0, kind: misspelled ? .correct : .complete) }
    }

    /// A suggestion was tapped: it replaces the word being typed (the first keeps it as typed).
    func choose(_ suggestion: Suggestion) {
        guard let c = controller else { return }
        let word = TypingRules.currentWord(c.before)
        if suggestion.kind == .keep {
            UITextChecker.learnWord(word)
            c.type(" ")
        } else {
            c.deleteBackward(word.count)
            c.type(suggestion.text + " ")
        }
        undoCorrection = nil
        sentenceMayHaveEnded()
        afterChange()
    }

    private func autocorrection(_ word: String) -> String? {
        guard language == .english, let c = controller, c.correctsText, UserDefaults.standard.object(forKey: "autocorrect") as? Bool ?? true,
              !UITextChecker.hasLearnedWord(word), UITextChecker.availableLanguages.contains(language.checkerCode) else { return nil }
        let lower = word.lowercased()
        let range = NSRange(location: 0, length: (lower as NSString).length)
        guard checker.rangeOfMisspelledWord(in: lower, range: range, startingAt: 0, wrap: false, language: language.checkerCode).location != NSNotFound else { return nil }
        let start = TypingRules.startsSentence(String(c.before.dropLast(word.count)))
        return TypingRules.autocorrection(for: word, guesses: checker.guesses(forWordRange: range, in: lower, language: language.checkerCode) ?? [], atSentenceStart: start)
    }

    // MARK: Claude's fixes

    /// A sentence just ended: Claude checks it, and its fixes show in the suggestion bar.
    private func sentenceMayHaveEnded() {
        guard canCheck(), let c = controller, c.correctsText, UserDefaults.standard.object(forKey: "checkSentences") as? Bool ?? true else { return }
        let before = c.before
        guard let sentence = CursorEdit.justFinishedSentence(before), sentence.text != checkedSentence,
              sentence.text.split(whereSeparator: \.isWhitespace).count >= 2 else { return }
        checkedSentence = sentence.text
        let context = String((before as NSString).substring(to: sentence.range.location).suffix(400))
        checkTask?.cancel()
        checking = true
        checkTask = Task {
            let edits = (try? await LexEngine.claude.check(sentence: sentence.text, before: context, finished: true, model: Prefs.current.quickModel)) ?? []
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
}

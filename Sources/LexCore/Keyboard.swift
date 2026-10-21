import Foundation

// MARK: Layouts

/// What a key on the iPhone keyboard does.
public enum KeyAction: Equatable, Hashable, Sendable {
    /// Types the text (letters follow shift).
    case character(String)
    case shift, delete, space, returnKey
    /// Page switches: digits and punctuation, more symbols, back to letters.
    case numbers, symbols, letters
    case emoji, language
}

public struct KeyCap: Equatable, Hashable, Sendable {
    public let action: KeyAction
    public let label: String
    /// In letter-key widths; a row is centred when it adds up to less than the widest.
    public let width: Double

    public init(_ action: KeyAction, _ label: String, width: Double = 1) {
        self.action = action
        self.label = label
        self.width = width
    }

    public static func letters(_ s: String) -> [KeyCap] {
        s.map { KeyCap(.character(String($0)), String($0)) }
    }

    /// Letters and digits react to shift and get the press preview; other keys don't.
    public var isCharacter: Bool {
        if case .character = action { return true }
        return false
    }
}

public enum KeyboardPage: Equatable, Sendable { case letters, numbers, symbols }

public enum KeyboardLanguage: String, CaseIterable, Sendable {
    case english = "en", hebrew = "he"

    /// The language key shows the one it switches to.
    public var other: KeyboardLanguage { self == .english ? .hebrew : .english }
    public var keyLabel: String { self == .english ? "EN" : "עב" }
    /// For the spelling checker's completions and guesses.
    public var checkerCode: String { self == .english ? "en_US" : "he_IL" }
}

/// The key rows, the way iPhone keyboards lay them out (Hebrew as Gboard does: no shift,
/// delete on the top row).
public enum KeyboardLayout {
    public static let unitsPerRow = 10.0

    public static func rows(_ page: KeyboardPage, _ language: KeyboardLanguage) -> [[KeyCap]] {
        let bottom: [KeyCap] = [
            KeyCap(page == .letters ? .numbers : .letters, page == .letters ? "123" : (language == .english ? "ABC" : "אבג"), width: 1.3),
            KeyCap(.emoji, "😊", width: 1.1),
            KeyCap(.language, language.other.keyLabel, width: 1.1),
            // Like Gboard, the space bar names the language.
            KeyCap(.space, language == .english ? "English" : "עברית", width: language == .hebrew && page == .letters ? 3.6 : 4.6),
        ] + (language == .hebrew && page == .letters ? [KeyCap(.character("."), ".")] : []) + [
            KeyCap(.returnKey, "return", width: 1.9),
        ]
        switch (page, language) {
        case (.letters, .english):
            return [
                KeyCap.letters("qwertyuiop"),
                KeyCap.letters("asdfghjkl"),
                [KeyCap(.shift, "shift", width: 1.4)] + KeyCap.letters("zxcvbnm") + [KeyCap(.delete, "delete", width: 1.4)],
                bottom,
            ]
        case (.letters, .hebrew):
            return [
                KeyCap.letters("קראטוןםפ") + [KeyCap(.delete, "delete", width: 1.4)],
                KeyCap.letters("שדגכעיחלךף"),
                KeyCap.letters("זסבהנמצתץ"),
                bottom,
            ]
        case (.numbers, _):
            return [
                KeyCap.letters("1234567890"),
                KeyCap.letters(language == .hebrew ? "-/:;()₪&@\"" : "-/:;()$&@\""),
                [KeyCap(.symbols, "#+=", width: 1.4)] + punctuation + [KeyCap(.delete, "delete", width: 1.4)],
                bottom,
            ]
        case (.symbols, _):
            return [
                KeyCap.letters("[]{}#%^*+="),
                KeyCap.letters("_\\|~<>€£¥•"),
                [KeyCap(.numbers, "123", width: 1.4)] + punctuation + [KeyCap(.delete, "delete", width: 1.4)],
                bottom,
            ]
        }
    }

    static let punctuation: [KeyCap] = [".", ",", "?", "!", "'"].map { KeyCap(.character($0), $0, width: 1.4) }
}

// MARK: Typing

/// The small rules that make typing feel like an iPhone keyboard. Text is what the keyboard
/// can see before the cursor.
public enum TypingRules {
    static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]

    /// The word being typed: the letters, digits and apostrophes right before the cursor.
    public static func currentWord(_ before: String) -> String {
        String(before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }.reversed())
    }

    /// The next letter starts a sentence: nothing before it, a line break, or a sentence end
    /// and a space.
    public static func startsSentence(_ before: String) -> Bool {
        guard let last = before.last else { return true }
        if last.isNewline { return true }
        guard last == " " else { return false }
        let rest = before.dropLast().reversed().drop { $0 == " " }
        guard let previous = rest.first else { return true }
        return sentenceEnds.contains(previous) || previous.isNewline
    }

    /// A second space right after a word ends the sentence: "word " + space → "word. ".
    public static func doubleSpaceMakesPeriod(_ before: String) -> Bool {
        guard before.hasSuffix(" "), !before.hasSuffix("  ") else { return false }
        guard let previous = before.dropLast().last else { return false }
        return previous.isLetter || previous.isNumber || previous == ")" || previous == "\"" || previous == "'"
    }

    /// The fix to make when a space ends `word`, or nil: a lowercase word of at least three
    /// letters with a spelling-checker guess one edit away (a typo, not a name or a
    /// different word). At the start of a sentence the first letter may be a capital.
    /// `guesses` are for the word in lowercase.
    public static func autocorrection(for word: String, guesses: [String], atSentenceStart: Bool = false) -> String? {
        let lower = word.lowercased()
        let capitalizedStart = atSentenceStart && word.first?.isUppercase == true && word.dropFirst().allSatisfy(\.isLowercase)
        guard word.count >= 3, word == lower || capitalizedStart, lower.allSatisfy(\.isLetter) else { return nil }
        guard let guess = guesses.first(where: { $0.lowercased() == $0 && $0 != lower && editDistance(lower, $0) == 1 }) else { return nil }
        return capitalizedStart ? matchCase(guess, to: word) : guess
    }

    /// Edits between two words, counting a swap of neighbouring letters as one.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var d = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[x.count][y.count]
    }

    /// Keeps the typed word's capitalisation on a suggestion ("Recieve" → "Receive").
    public static func matchCase(_ suggestion: String, to word: String) -> String {
        if word.count > 1, word == word.uppercased(), word != word.lowercased() { return suggestion.uppercased() }
        if let first = word.first, first.isUppercase { return suggestion.prefix(1).uppercased() + suggestion.dropFirst() }
        return suggestion
    }
}

// MARK: Fixing what was typed

/// The keyboard can only type and delete at the cursor, so a fix earlier in the text is made
/// by deleting back to it and typing the rest again.
public struct TextFix: Equatable, Sendable {
    /// UTF-16, in the text before the cursor.
    public let range: NSRange
    public let original: String
    public let replacement: String

    public init(range: NSRange, original: String, replacement: String) {
        self.range = range
        self.original = original
        self.replacement = replacement
    }
}

public enum CursorEdit {
    /// How to replace `range` (UTF-16, in `before`) with `replacement`: the characters to
    /// delete before the cursor and the text to type. Nil when `range` no longer holds
    /// `original`.
    public static func plan(replacing range: NSRange, original: String, with replacement: String, in before: String) -> (delete: Int, type: String)? {
        plan([TextFix(range: range, original: original, replacement: replacement)], in: before)
    }

    /// Several fixes in one go: delete back to the first and type the rest with all of them
    /// made. Nil when any fix no longer matches the text, or two overlap.
    public static func plan(_ fixes: [TextFix], in before: String) -> (delete: Int, type: String)? {
        let ns = before as NSString
        let sorted = fixes.sorted { $0.range.location < $1.range.location }
        guard let first = sorted.first else { return nil }
        for (i, fix) in sorted.enumerated() {
            guard fix.range.location >= 0, fix.range.end <= ns.length, ns.substring(with: fix.range) == fix.original else { return nil }
            if i > 0, sorted[i - 1].range.end > fix.range.location { return nil }
        }
        guard Range(NSRange(location: first.range.location, length: 0), in: before) != nil else { return nil }
        let tail = ns.substring(from: first.range.location)
        var typed = tail as NSString
        for fix in sorted.reversed() {
            typed = typed.replacingCharacters(in: NSRange(location: fix.range.location - first.range.location, length: fix.range.length), with: fix.replacement) as NSString
        }
        return (tail.count, typed as String)
    }

    /// The sentence the writer just finished: the last complete one, if the cursor is right
    /// after it (with at most a space or line break between).
    public static func justFinishedSentence(_ before: String) -> Sentence? {
        let ns = before as NSString
        guard let last = SentenceSplitter.split(before, caret: ns.length).last, last.isComplete else { return nil }
        let gap = ns.substring(from: last.range.end)
        return gap.count <= 2 && gap.allSatisfy(\.isWhitespace) ? last : nil
    }
}

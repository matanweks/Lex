import Foundation

// MARK: What you type, learned

/// The words you type and which word follows which, learned on the phone so suggestions
/// get personal (names, your phrases, Hebrew). Never sent anywhere.
public struct WordModel: Codable, Equatable, Sendable {
    /// Lowercased word → how often you typed it.
    public private(set) var words: [String: Int] = [:]
    /// Previous word ("" at a sentence start) → next word → count.
    public private(set) var pairs: [String: [String: Int]] = [:]
    /// How a word is written when it isn't all lowercase ("Dana", "iPhone").
    public private(set) var forms: [String: String] = [:]

    public static let maxWords = 20_000
    public static let maxPairs = 40_000

    public init() {}

    public var isEmpty: Bool { words.isEmpty }

    /// Learns `word`, typed after `previous` (nil at the start of a sentence).
    public mutating func learn(_ word: String, after previous: String?, atSentenceStart: Bool) {
        let lower = word.lowercased()
        guard Self.isWord(lower) else { return }
        words[lower, default: 0] += 1
        pairs[previous?.lowercased() ?? "", default: [:]][lower, default: 0] += 1
        // A capital mid-sentence means a name or brand: keep it as written.
        if word != lower, !atSentenceStart || word.dropFirst().contains(where: \.isUppercase) { forms[lower] = word }
        if words.count > Self.maxWords + Self.maxWords / 10 { prune() }
    }

    /// How `lower` should be shown.
    public func form(of lower: String) -> String { forms[lower] ?? lower }

    public func count(_ word: String) -> Int { words[word.lowercased()] ?? 0 }

    public func count(_ word: String, after previous: String?) -> Int {
        pairs[previous?.lowercased() ?? ""]?[word.lowercased()] ?? 0
    }

    /// Words you typed that start with `prefix` (lowercased).
    public func words(startingWith prefix: String) -> [(word: String, count: Int)] {
        let p = prefix.lowercased()
        return words.compactMap { $0.key.hasPrefix(p) && $0.key != p ? ($0.key, $0.value) : nil }
    }

    /// The words you usually type after `previous`.
    public func next(after previous: String?) -> [(word: String, count: Int)] {
        (pairs[previous?.lowercased() ?? ""] ?? [:]).map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    /// Keeps the words and pairs you use most.
    mutating func prune() {
        let keep = Set(words.sorted { $0.value > $1.value }.prefix(Self.maxWords).map(\.key))
        words = words.filter { keep.contains($0.key) }
        forms = forms.filter { keep.contains($0.key) }
        let all = pairs.flatMap { previous, nexts in nexts.map { (previous, $0.key, $0.value) } }
        guard all.count > Self.maxPairs else { return }
        var kept: [String: [String: Int]] = [:]
        for (previous, next, count) in all.sorted(by: { $0.2 > $1.2 }).prefix(Self.maxPairs) { kept[previous, default: [:]][next] = count }
        pairs = kept
    }

    /// Letters (any script), with an apostrophe or hyphen inside: no numbers, links or codes.
    static func isWord(_ s: String) -> Bool {
        guard s.count >= 1, s.count <= 30, let first = s.first, first.isLetter, let last = s.last, last.isLetter else { return false }
        return s.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
    }
}

// MARK: Built-in hints

/// A small starting vocabulary, so suggestions help before Lex has learned your words.
public struct WordSeed: Sendable {
    /// Common words, most used first.
    public let common: [String]
    /// Likely next words after a word.
    public let next: [String: [String]]
    /// Likely first words of a message.
    public let starters: [String]

    public static func `for`(_ language: KeyboardLanguage) -> WordSeed { language == .english ? english : hebrew }

    public static let english = WordSeed(
        common: "the I to and a you it of is in that for on my me this be have are not with we just so but do was can if at what your it's all will get like know no I'm good about up out there one how time see now don't they think when then go want from need here back yes great thanks today tomorrow morning meeting work please sorry sure okay really love could would should also because some more much any going make let call send day week let's maybe right still well already".split(separator: " ").map(String.init),
        next: [
            "i": ["am", "think", "have", "will", "can", "don't", "was", "need", "just", "love"],
            "i'm": ["not", "going", "sure", "on", "in", "here", "so"],
            "you": ["can", "are", "have", "know", "for", "need", "want", "too"],
            "thank": ["you"], "thanks": ["for", "again", "so"],
            "the": ["same", "best", "meeting", "first", "other", "end", "time", "way"],
            "a": ["lot", "good", "few", "great", "bit", "new", "quick"],
            "to": ["the", "be", "get", "do", "see", "make", "go", "have"],
            "of": ["the", "course", "my", "this", "it"],
            "in": ["the", "a", "my", "touch", "this", "case"],
            "for": ["the", "you", "your", "a", "me", "now", "sure"],
            "on": ["the", "my", "it", "your", "this", "Monday"],
            "is": ["a", "the", "it", "not", "there", "that", "going"],
            "it": ["is", "was", "would", "will", "works", "looks"],
            "it's": ["a", "not", "the", "fine", "good", "ok"],
            "will": ["be", "send", "do", "check", "have", "let"],
            "can": ["you", "we", "I", "be", "do", "help"],
            "let": ["me", "us", "you"], "let's": ["go", "talk", "do", "meet"],
            "me": ["know", "a", "to", "if", "the"],
            "know": ["if", "what", "how", "that", "when"],
            "see": ["you", "the", "it", "what", "if"],
            "how": ["are", "about", "is", "was", "much", "do"],
            "what": ["do", "is", "time", "about", "are", "you"],
            "do": ["you", "it", "not", "we", "this"],
            "are": ["you", "we", "the", "not", "there"],
            "we": ["can", "are", "will", "need", "have", "should"],
            "have": ["a", "to", "you", "been", "the", "any"],
            "good": ["morning", "luck", "night", "idea", "job", "to"],
            "looking": ["forward", "for", "at"], "forward": ["to"],
            "at": ["the", "home", "work", "least"],
            "with": ["the", "you", "me", "a", "my"],
            "that": ["is", "the", "you", "it", "we", "sounds"],
            "this": ["is", "week", "morning", "one", "time"],
            "please": ["let", "send", "find", "check"],
            "just": ["a", "to", "wanted", "the", "now", "checking"],
            "so": ["much", "I", "we", "it", "far"],
            "not": ["sure", "a", "to", "yet", "the"],
            "be": ["a", "there", "able", "ready", "the"],
            "get": ["the", "it", "back", "a", "to"],
            "if": ["you", "it", "we", "I", "there"],
            "and": ["the", "I", "we", "then", "a"],
            "but": ["I", "the", "it", "we", "not"],
            "sounds": ["good", "great", "like"],
            "no": ["problem", "worries", "need", "one"],
            "talk": ["to", "soon", "later"],
            "would": ["be", "like", "you", "love"],
            "like": ["to", "a", "the", "it"],
            "want": ["to", "a", "you"], "need": ["to", "a", "help", "the"],
            "going": ["to", "on", "home"],
            "send": ["you", "it", "me", "the"],
            "next": ["week", "time", "Monday"], "last": ["week", "night", "time"],
            "all": ["the", "good", "right", "of"], "as": ["well", "soon", "a", "the"],
            "about": ["the", "it", "this", "that"], "there": ["is", "are", "was"],
            "happy": ["to", "birthday"], "my": ["phone", "best", "own", "mind"],
        ],
        starters: ["I", "The", "Thanks", "Hi", "Can", "We"])

    public static let hebrew = WordSeed(
        common: "של את על זה לא אני הוא היא עם כל גם אבל מה אם יש כי רק אז לי אתה אין הם שלי כמו עוד אחד טוב כן היום מחר תודה בסדר שלום אנחנו להיות צריך יכול רוצה אפשר עכשיו פה איך למה מתי איפה מי הזה הזאת אותו אותי אותך לך לו לה לנו שלך שלו שלה שלנו הרבה קצת מאוד יותר אחרי לפני תמיד פעם שוב בבקשה סליחה בוקר ערב לילה יום שבוע שעה זמן בית עבודה פגישה הודעה טלפון אוקיי אחלה מעולה יופי סבבה ברור בטח נכון אולי בדיוק כבר עדיין באמת ממש משהו כולם חדש עושה הולך יודע חושב שולח אשלח אעדכן נדבר נתראה מצוין רבה מבין צריכה יכולה רוצים".split(separator: " ").map(String.init),
        next: [
            "תודה": ["רבה", "על", "לך"], "בוקר": ["טוב"], "ערב": ["טוב"], "לילה": ["טוב"],
            "מה": ["שלומך", "קורה", "נשמע", "זה", "אתה", "את"],
            "אני": ["לא", "רוצה", "צריך", "חושב", "יכול", "בדרך", "אשלח"],
            "זה": ["לא", "בסדר", "נשמע", "מעולה", "היה"],
            "לא": ["יודע", "צריך", "בטוח", "יכול", "משנה"],
            "אפשר": ["לדבר", "לקבל", "לשלוח"], "יש": ["לי", "לך", "לנו", "בעיה"],
            "אין": ["בעיה", "לי", "צורך"], "נדבר": ["מחר", "בהמשך", "אחר"],
            "אשלח": ["לך", "מחר", "עכשיו"], "אעדכן": ["אותך", "מחר"],
            "בסדר": ["גמור", "תודה"], "שבוע": ["טוב", "הבא"], "שבת": ["שלום"],
            "יום": ["טוב", "הולדת", "שני", "ראשון"], "רוצה": ["לדבר", "לבוא", "לשאול"],
            "צריך": ["לדבר", "עזרה", "לבדוק"], "אתה": ["יכול", "צריך", "רוצה", "בא"],
            "בדרך": ["הביתה", "אליך"], "ממש": ["טוב", "תודה", "מצטער"],
            "סליחה": ["על"], "איך": ["אתה", "את", "היה", "הולך"],
        ],
        starters: ["היי", "אני", "תודה", "מה", "אפשר", "בוקר"])
}

// MARK: Suggestions

/// The suggestion bar's words: completions of the word you're typing, or the next word once
/// you've typed a space. Your own words come first, then the spelling checker's and the
/// built-in hints.
public enum Predictor {
    /// Best first.
    public static func suggestions(prefix: String, previous: String?, atSentenceStart: Bool,
                                   system: [String], guesses: [String], model: WordModel, seed: WordSeed, limit: Int = 3) -> [String] {
        var scores: [String: Double] = [:]
        func add(_ word: String, _ score: Double) {
            let lower = word.lowercased()
            guard !lower.isEmpty, lower != prefix.lowercased() else { return }
            scores[lower, default: 0] += score
        }
        let p = prefix.lowercased()
        if p.isEmpty {
            for (i, (word, count)) in model.next(after: previous).prefix(12).enumerated() { add(word, 4 * log(1 + Double(count)) + 1 - Double(i) * 0.05) }
            for (i, word) in (seed.next[previous?.lowercased() ?? ""] ?? []).enumerated() { add(word, 3 - Double(i) * 0.3) }
            if previous == nil || atSentenceStart { for (i, word) in seed.starters.enumerated() { add(word, 2.5 - Double(i) * 0.3) } }
        } else {
            for (word, count) in model.words(startingWith: p) {
                add(word, 2 * log(1 + Double(count)) + 4 * log(1 + Double(model.count(word, after: previous))))
            }
            for (i, word) in (seed.next[previous?.lowercased() ?? ""] ?? []).enumerated() where word.lowercased().hasPrefix(p) { add(word, 3 - Double(i) * 0.2) }
            for (i, word) in seed.common.enumerated() where word.lowercased().hasPrefix(p) { add(word, 2 * (1 - Double(i) / Double(seed.common.count))) }
            for (i, word) in system.prefix(8).enumerated() { add(word, 2.5 - Double(i) * 0.15) }
            for (i, word) in guesses.prefix(4).enumerated() { add(word, 3.5 - Double(i) * 0.3) }
        }
        // Like Gboard, the bar always has words: after a space with nothing better, the most
        // common ones.
        if p.isEmpty, scores.count < limit {
            for (i, word) in seed.common.prefix(limit * 3).enumerated() where scores[word.lowercased()] == nil { add(word, 0.2 - Double(i) * 0.01) }
        }
        let best = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
        return best.map { word in
            let shown = model.form(of: word) != word ? model.form(of: word) : seedForm(word, seed)
            return atSentenceStart || prefix.first?.isUppercase == true ? shown.prefix(1).uppercased() + shown.dropFirst() : shown
        }
    }

    /// The hints keep "I" and names capitalised.
    static func seedForm(_ lower: String, _ seed: WordSeed) -> String {
        if lower == "i" { return "I" }
        if lower.hasPrefix("i'") { return "I" + lower.dropFirst() }
        // Not the starters: those are capitalised only because they begin a message.
        for list in [seed.common] + seed.next.values.map({ $0 }) {
            if let found = list.first(where: { $0.lowercased() == lower && $0 != lower }) { return found }
        }
        return lower
    }

    /// The word before the one being typed, or nil at the start of a sentence (or of the text).
    public static func previousWord(_ before: String) -> String? {
        let current = TypingRules.currentWord(before)
        let rest = before.dropLast(current.count)
        let trimmed = rest.reversed().drop { $0 == " " }
        guard let last = trimmed.first, last.isLetter || last == "'" || last == "’" else { return nil }
        let word = String(String(trimmed).prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
        return word.isEmpty ? nil : word
    }
}

// MARK: Keys

/// What a long press on a key offers, and the hint drawn in its corner (Gboard's digits).
public enum KeyAlternates {
    static let englishTopRow: [Character: String] = ["q": "1", "w": "2", "e": "3", "r": "4", "t": "5", "y": "6", "u": "7", "i": "8", "o": "9", "p": "0"]
    static let accents: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å"], "e": ["é", "è", "ê", "ë"], "i": ["í", "ì", "î", "ï"],
        "o": ["ó", "ò", "ô", "ö", "õ", "ø"], "u": ["ú", "ù", "û", "ü"], "c": ["ç"], "n": ["ñ"], "s": ["ß"], "y": ["ÿ"],
        ".": [",", "?", "!", "'", "\"", ":", ";", "-", "…"], "-": ["–", "—", "_"], "'": ["’", "‘", "\""], "\"": ["”", "“", "«", "»"],
        "$": ["₪", "€", "£", "¥", "¢"], "₪": ["$", "€", "£", "¥"], "?": ["¿"], "!": ["¡"], "&": ["§"], "/": ["\\"],
    ]

    /// The first is what a plain long press types.
    public static func alternates(for key: String, _ language: KeyboardLanguage) -> [String] {
        let lower = key.lowercased()
        var out: [String] = []
        if language == .english, key.count == 1, let digit = englishTopRow[Character(lower)] { out.append(digit) }
        out += (accents[lower] ?? []).map { key == lower ? $0 : $0.uppercased() }
        return out
    }

    /// The small label in the key's corner.
    public static func hint(for key: String, _ language: KeyboardLanguage) -> String? {
        guard language == .english, key.count == 1 else { return nil }
        return englishTopRow[Character(key.lowercased())]
    }
}

extension TypingRules {
    /// How many characters deleting `words` words back from the cursor removes: the spaces
    /// before each word, then the word (or a run of punctuation).
    public static func charactersToDelete(words: Int, in before: String) -> Int {
        let chars = Array(before)
        var count = 0
        func at(_ i: Int) -> Character { chars[chars.count - 1 - i] }
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }
        for _ in 0..<max(words, 0) {
            while count < chars.count, at(count).isWhitespace { count += 1 }
            guard count < chars.count else { break }
            if isWordChar(at(count)) {
                while count < chars.count, isWordChar(at(count)) { count += 1 }
            } else {
                while count < chars.count, !isWordChar(at(count)), !at(count).isWhitespace { count += 1 }
            }
        }
        return count
    }
}

import Foundation

// MARK: What you type, learned

/// The words you type and which word follows which, learned on the phone so suggestions
/// get personal (names, your phrases, Hebrew). Never sent anywhere.
public struct WordModel: Codable, Equatable, Sendable {
    /// Lowercased word → how often you typed it.
    public private(set) var words: [String: Int] = [:]
    /// Previous word ("" at a sentence start) → next word → count.
    public private(set) var pairs: [String: [String: Int]] = [:]
    /// The two words before ("see you") → next word → count.
    public private(set) var triples: [String: [String: Int]] = [:]
    /// How a word is written when it isn't all lowercase ("Dana", "iPhone").
    public private(set) var forms: [String: String] = [:]
    /// For a word in `forms`: the times you wrote it that way after another word, less the
    /// times you wrote it in lowercase. Below zero, the form is forgotten.
    private var capitals: [String: Int] = [:]

    public static let maxWords = 20_000
    public static let maxPairs = 40_000
    public static let maxTriples = 20_000

    public init() {}

    private enum CodingKeys: String, CodingKey { case words, pairs, triples, forms, capitals }

    /// Reads what older versions of Lex saved too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.decodeIfPresent([String: Int].self, forKey: .words) ?? [:]
        pairs = try c.decodeIfPresent([String: [String: Int]].self, forKey: .pairs) ?? [:]
        triples = try c.decodeIfPresent([String: [String: Int]].self, forKey: .triples) ?? [:]
        forms = try c.decodeIfPresent([String: String].self, forKey: .forms) ?? [:]
        capitals = try c.decodeIfPresent([String: Int].self, forKey: .capitals) ?? [:]
    }

    public var isEmpty: Bool { words.isEmpty }

    /// Learns `word`, typed after `previous` and `earlier` (the word before that). `previous`
    /// is nil at the start of a sentence, and when what came before isn't a word (an emoji,
    /// a number, a quote).
    public mutating func learn(_ word: String, after previous: String?, earlier: String? = nil, atSentenceStart: Bool) {
        let lower = word.lowercased()
        guard Self.isWord(lower) else { return }
        words[lower, default: 0] += 1
        if previous != nil || atSentenceStart { pairs[previous?.lowercased() ?? "", default: [:]][lower, default: 0] += 1 }
        if let previous, let earlier { triples[Self.key(previous, earlier), default: [:]][lower, default: 0] += 1 }
        if word == lower {
            // Written in lowercase: maybe the capital isn't always meant.
            if forms[lower] != nil {
                let left = (capitals[lower] ?? 0) - 1
                if left < 0 { forms[lower] = nil; capitals[lower] = nil } else { capitals[lower] = left }
            }
        } else if word.dropFirst().contains(where: \.isUppercase) || (previous != nil && !atSentenceStart) {
            // A capital right after a word means a name or brand ("Dana"), and so does one
            // inside a word ("iPhone"). After an emoji or a quote it may only start a sentence.
            forms[lower] = word
            capitals[lower, default: 0] += 1
        }
        if words.count > Self.maxWords + Self.maxWords / 10 || triples.count > Self.maxTriples + Self.maxTriples / 10 { prune() }
    }

    static func key(_ previous: String, _ earlier: String) -> String { earlier.lowercased() + " " + previous.lowercased() }

    /// A word you kept as typed (put back after autocorrect, or tapped as typed): it's yours
    /// from now on, so it isn't corrected again.
    public mutating func keep(_ word: String) {
        let lower = word.lowercased()
        guard Self.isWord(lower) else { return }
        words[lower, default: 0] += 2
    }

    /// How `lower` should be shown.
    public func form(of lower: String) -> String { forms[lower] ?? lower }

    public func count(_ word: String) -> Int { words[word.lowercased()] ?? 0 }

    public func count(_ word: String, after previous: String?) -> Int {
        pairs[previous?.lowercased() ?? ""]?[word.lowercased()] ?? 0
    }

    public func count(_ word: String, after previous: String, earlier: String) -> Int {
        triples[Self.key(previous, earlier)]?[word.lowercased()] ?? 0
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

    /// The words you usually type after `earlier` `previous`.
    public func next(after previous: String, earlier: String) -> [(word: String, count: Int)] {
        (triples[Self.key(previous, earlier)] ?? [:]).map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    /// Keeps the words, pairs and triples you use most.
    mutating func prune() {
        if words.count > Self.maxWords {
            let keep = Set(words.sorted { $0.value > $1.value }.prefix(Self.maxWords).map(\.key))
            words = words.filter { keep.contains($0.key) }
            forms = forms.filter { keep.contains($0.key) }
            capitals = capitals.filter { keep.contains($0.key) }
        }
        pairs = Self.top(pairs, Self.maxPairs)
        triples = Self.top(triples, Self.maxTriples)
    }

    private static func top(_ table: [String: [String: Int]], _ limit: Int) -> [String: [String: Int]] {
        let all = table.flatMap { before, nexts in nexts.map { (before, $0.key, $0.value) } }
        guard all.count > limit else { return table }
        var kept: [String: [String: Int]] = [:]
        for (before, next, count) in all.sorted(by: { $0.2 > $1.2 }).prefix(limit) { kept[before, default: [:]][next] = count }
        return kept
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
    /// Likely next words after a word, or after two ("see you").
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
            // Messages' phrases, which the word list's example sentences rarely have.
            "see you": ["soon", "later", "tomorrow", "there"], "to you": ["soon", "later"],
            "talk to": ["you"], "on my": ["way"], "i'm on": ["my", "it"], "let me": ["know"],
            "have a": ["good", "great", "nice"], "a great": ["day", "time", "weekend"],
            "a good": ["day", "time", "one", "night"], "are you": ["free", "around", "ok", "coming", "sure"],
            "thank you": ["so", "for", "very"], "thanks for": ["the", "your", "letting"],
            "can you": ["send", "please", "help", "call", "check"], "i will": ["send", "be", "check", "let"],
            "what time": ["is", "do", "are"], "how was": ["your", "it", "the"], "how's": ["it", "your", "the"],
            "sounds good": ["to"], "good to": ["know", "hear", "see"], "in a": ["bit", "few", "minute"],
            "be there": ["in", "soon", "at"], "running late": ["sorry"], "i'm running": ["late"],
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
/// you've typed a space. Your own words and your contacts' names come first, then the word
/// list's, the spelling checker's and the built-in hints.
public enum Predictor {
    /// Best first. `earlier` is the word before `previous`. `names` are your contacts' names,
    /// lowercased → as written.
    public static func suggestions(prefix: String, previous: String?, earlier: String? = nil, atSentenceStart: Bool,
                                   system: [String], guesses: [String], model: WordModel, seed: WordSeed,
                                   lexicon: Lexicon = .empty, names: [String: String] = [:], limit: Int = 3) -> [String] {
        var scores: [String: Double] = [:]
        func add(_ word: String, _ score: Double) {
            let lower = word.lowercased()
            guard !lower.isEmpty, lower != prefix.lowercased() else { return }
            scores[lower, default: 0] += score
        }
        let p = prefix.lowercased()
        // The sentence start's next words are the ones sentences usually begin with.
        let after = previous?.lowercased() ?? ""
        // The two words before say more than one: "like to" → do, go, be.
        let two = previous.flatMap { previous in earlier.map { (previous, $0) } }
        let afterTwo = two.map { WordModel.key($0.0, $0.1) }
        if p.isEmpty {
            if let two {
                for (i, (word, count)) in model.next(after: two.0, earlier: two.1).prefix(12).enumerated() { add(word, 4 * log(1 + Double(count)) + 2 - Double(i) * 0.05) }
            }
            if let afterTwo {
                for (i, word) in (seed.next[afterTwo] ?? []).enumerated() { add(word, 3.6 - Double(i) * 0.3) }
                for (i, word) in (lexicon.next[afterTwo] ?? []).enumerated() { add(word, 3.4 - Double(i) * 0.3) }
            }
            // When the two words before are known, the last one alone counts for less.
            let one = scores.isEmpty ? 1 : 0.3
            for (i, (word, count)) in model.next(after: previous).prefix(12).enumerated() { add(word, one * (4 * log(1 + Double(count)) + 1 - Double(i) * 0.05)) }
            for (i, word) in (seed.next[after] ?? []).enumerated() { add(word, one * (3 - Double(i) * 0.3)) }
            // The word list's sentence starters come from example sentences, not messages: a hint only.
            let weight = after.isEmpty ? 1.6 : 2.6
            for (i, word) in (lexicon.next[after] ?? []).enumerated() { add(word, one * (weight - Double(i) * 0.25)) }
            if previous == nil || atSentenceStart { for (i, word) in seed.starters.enumerated() { add(word, 2.5 - Double(i) * 0.3) } }
        } else {
            for (word, count) in model.words(startingWith: p) {
                let afterTwo = two.map { model.count(word, after: $0.0, earlier: $0.1) } ?? 0
                add(word, 2 * log(1 + Double(count)) + 4 * log(1 + Double(model.count(word, after: previous))) + 4 * log(1 + Double(afterTwo)))
            }
            for (lower, _) in names where lower.hasPrefix(p) { add(lower, 3.2) }
            if let afterTwo {
                for (i, word) in (seed.next[afterTwo] ?? []).enumerated() where word.lowercased().hasPrefix(p) { add(word, 3.3 - Double(i) * 0.2) }
                for (i, word) in (lexicon.next[afterTwo] ?? []).enumerated() where word.hasPrefix(p) { add(word, 3.2 - Double(i) * 0.2) }
            }
            for (i, word) in (seed.next[after] ?? []).enumerated() where word.lowercased().hasPrefix(p) { add(word, 3 - Double(i) * 0.2) }
            for (i, word) in (lexicon.next[after] ?? []).enumerated() where word.hasPrefix(p) { add(word, 2.8 - Double(i) * 0.2) }
            for (word, _) in lexicon.completions(p, limit: 10) { add(word, 2.6 * lexicon.commonness(word)) }
            for (i, word) in seed.common.enumerated() where word.lowercased().hasPrefix(p) { add(word, 2 * (1 - Double(i) / Double(seed.common.count))) }
            // The spelling checker's completions include rare words; the word list ranks better.
            let systemWeight = lexicon.isEmpty ? 2.5 : 1.4
            for (i, word) in system.prefix(8).enumerated() { add(word, systemWeight - Double(i) * 0.15) }
            for (i, word) in guesses.prefix(4).enumerated() { add(word, 3.5 - Double(i) * 0.3) }
        }
        // Like Gboard, the bar always has words: after a space with nothing better, the most
        // common ones.
        if p.isEmpty, scores.count < limit {
            for (i, word) in seed.common.prefix(limit * 3).enumerated() where scores[word.lowercased()] == nil { add(word, 0.2 - Double(i) * 0.01) }
        }
        let best = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
        let common = Set(seed.common.map { $0.lowercased() })
        return best.map { word in
            let shown = form(of: word, model: model, seed: seed, common: common, lexicon: lexicon, names: names)
            return atSentenceStart || prefix.first?.isUppercase == true ? shown.prefix(1).uppercased() + shown.dropFirst() : shown
        }
    }

    /// How a suggested word is written: a contact's name or a word you capitalise as you do
    /// ("Dana", "iPhone"), but a common word stays lowercase even if a contact or a slip
    /// capitalised it ("will", not "Will"; "the", not "The"), unless it's "I".
    static func form(of word: String, model: WordModel, seed: WordSeed, common: Set<String>, lexicon: Lexicon, names: [String: String]) -> String {
        func onlyCapitalised(_ form: String) -> Bool { form == form.prefix(1).uppercased() + word.dropFirst() }
        if let name = names[word], !(onlyCapitalised(name) && (common.contains(word) || lexicon.commonness(word) >= 0.5)) { return name }
        let learned = model.form(of: word)
        if learned != word, !(onlyCapitalised(learned) && common.contains(word)) { return learned }
        return seedForm(word, seed)
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
        previousWords(before, count: 1).first
    }

    /// The words before the one being typed, nearest first, up to `count`: back to the start
    /// of the sentence, a comma, or anything else that isn't a word.
    public static func previousWords(_ before: String, count: Int = 2) -> [String] {
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c == "'" || c == "’" }
        var rest = Substring(before.dropLast(TypingRules.currentWord(before).count))
        var found: [String] = []
        while found.count < count {
            let trimmed = rest.reversed().drop { $0 == " " }
            guard let last = trimmed.first, isWordCharacter(last) else { break }
            let word = String(String(trimmed.prefix(while: isWordCharacter)).reversed())
            // A word with a digit in it ("mp3") isn't one to predict from.
            let start = rest.index(rest.endIndex, offsetBy: -(rest.reversed().prefix { $0 == " " }.count + word.count))
            if start > rest.startIndex, let before = rest[..<start].last, before.isNumber { break }
            found.append(word)
            rest = rest[..<start]
        }
        return found
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

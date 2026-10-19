import Foundation

/// Which languages dictation listens for. Google's Chirp 3 picks between the listed ones.
public enum DictationLanguages: String, CaseIterable, Identifiable, Sendable {
    case englishHebrew = "en-he"
    case english = "en"
    case hebrew = "he"
    case auto = "auto"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .englishHebrew: return "English and Hebrew"
        case .english: return "English"
        case .hebrew: return "Hebrew"
        case .auto: return "Any language (auto-detect)"
        }
    }

    /// Chirp 3 language codes. Hebrew is listed by Google as iw-IL.
    public var googleCodes: [String] {
        switch self {
        case .englishHebrew: return ["en-US", "iw-IL"]
        case .english: return ["en-US"]
        case .hebrew: return ["iw-IL"]
        case .auto: return ["auto"]
        }
    }

    public var appleOnDeviceWorks: Bool { self == .english }
}

public enum DictationEngine: String, CaseIterable, Identifiable, Sendable {
    case auto
    case google
    case apple

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Auto: Apple for English, Google for Hebrew (picks by your keyboard)"
        case .google: return "Google Chirp 3 always: about $0.016 per minute"
        case .apple: return "Apple on-device always: free and private, English only"
        }
    }

    /// Which engine actually runs. Auto follows the keyboard: a Hebrew layout means Hebrew
    /// speech, which only Google handles; otherwise Apple's on-device English is faster and free.
    public func resolved(keyboardLanguage: String?, appleAvailable: Bool) -> DictationEngine {
        switch self {
        case .auto:
            let hebrew = keyboardLanguage.map { $0.hasPrefix("he") || $0.hasPrefix("iw") } ?? false
            return hebrew || !appleAvailable ? .google : .apple
        case .apple:
            return appleAvailable ? .apple : .google
        case .google:
            return .google
        }
    }
}

/// 16 kHz mono 16-bit audio, the format both engines get.
public struct PCM16: Sendable {
    public static let sampleRate = 16_000
    public var samples: [Int16]

    public init(samples: [Int16] = []) { self.samples = samples }

    public var seconds: Double { Double(samples.count) / Double(Self.sampleRate) }

    public var data: Data { samples.withUnsafeBufferPointer { Data(buffer: $0) } }
}

/// Finds natural pauses so long dictation can be sent to the recognizer in pieces while
/// the speaker is still talking: by the time they let go, most of it is already transcribed.
public struct PauseSegmenter: Sendable {
    public static let frame = 480  // 30 ms at 16 kHz

    public var minSegment: Double = 8      // don't send pieces shorter than this
    public var maxSegment: Double = 45     // stay well under Google's one-minute limit
    public var pauseNeeded: Double = 0.6   // a breath, not a hesitation

    public init() {}

    /// RMS loudness of each 30 ms frame, 0...1.
    public static func levels(_ samples: ArraySlice<Int16>) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(samples.count / frame + 1)
        var i = samples.startIndex
        while i + frame <= samples.endIndex {
            var sum: Float = 0
            for s in samples[i..<(i + frame)] { let f = Float(s) / 32768; sum += f * f }
            out.append((sum / Float(frame)).squareRoot())
            i += frame
        }
        return out
    }

    /// Where to cut `pending` (samples not yet sent), or nil to keep listening.
    /// Cuts in the middle of a long-enough pause after at least `minSegment` seconds,
    /// or at the quietest moment once a piece reaches `maxSegment`.
    public func cut(_ pending: ArraySlice<Int16>) -> Int? {
        let seconds = Double(pending.count) / Double(PCM16.sampleRate)
        guard seconds >= minSegment else { return nil }
        let lv = Self.levels(pending)
        guard !lv.isEmpty else { return nil }
        let sorted = lv.sorted()
        // Background noise is the quietest moment; a pause is anything near it, and never
        // louder than a quarter of typical speech.
        let floor = sorted[0]
        let median = sorted[sorted.count / 2]
        let threshold = min(max(floor * 2.5, 0.008), max(median * 0.25, 0.008))
        let need = Int(pauseNeeded / 0.03)
        let minFrame = Int(minSegment / 0.03)
        var run = 0
        var best: Int?
        for (i, v) in lv.enumerated() {
            if v < threshold {
                run += 1
                if run >= need, i - run / 2 >= minFrame { best = i - run / 2 }
            } else {
                run = 0
            }
        }
        if let best { return pending.startIndex + best * Self.frame }
        if seconds >= maxSegment {
            // No pause: cut at the quietest frame in the last five seconds.
            let tail = lv.suffix(Int(5 / 0.03))
            let offset = lv.count - tail.count
            let quietest = tail.enumerated().min { $0.element < $1.element }.map { $0.offset + offset } ?? lv.count - 1
            return pending.startIndex + quietest * Self.frame
        }
        return nil
    }

    /// True when there's hardly any speech in the audio (a stray tap of the key).
    public static func isSilent(_ samples: [Int16]) -> Bool {
        let lv = levels(samples[...])
        guard lv.count >= 8 else { return true }
        let sorted = lv.sorted()
        let floor = sorted[sorted.count / 10]
        let loud = lv.filter { $0 > max(floor * 3, 0.02) }.count
        return Double(loud) * 0.03 < 0.25
    }
}

public enum GoogleSTT {
    /// Chirp 3 runs in the us and eu multi-regions.
    public static func url(project: String, region: String = "us") -> URL {
        URL(string: "https://\(region)-speech.googleapis.com/v2/projects/\(project)/locations/\(region)/recognizers/_:recognize")!
    }

    public static func requestBody(audio: PCM16, languages: [String], phrases: [String]) -> [String: Any] {
        var config: [String: Any] = [
            "explicitDecodingConfig": ["encoding": "LINEAR16", "sampleRateHertz": PCM16.sampleRate, "audioChannelCount": 1],
            "languageCodes": languages,
            "model": "chirp_3",
            "features": ["enableAutomaticPunctuation": true],
        ]
        let hints = phrases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(200)
        if !hints.isEmpty {
            config["adaptation"] = ["phraseSets": [["inlinePhraseSet": ["phrases": hints.map { ["value": $0, "boost": 10] }]]]]
        }
        return ["config": config, "content": audio.data.base64EncodedString()]
    }

    /// The transcript, joining results in order.
    public static func transcript(from data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SpeechError.badResponse }
        let results = obj["results"] as? [[String: Any]] ?? []
        let parts = results.compactMap { ($0["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum DictationText {
    /// Joins transcribed pieces in order.
    public static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The cleaned text, unless the clean-up changed it so much it can't be trusted (an
    /// answer instead of a transcript, a dropped half): then the raw transcript.
    public static func choose(cleaned: String?, raw: String) -> String {
        guard let cleaned = cleaned?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return raw }
        let ratio = Double(cleaned.count) / Double(max(raw.count, 1))
        return (0.4...1.6).contains(ratio) || raw.count < 25 ? cleaned : raw
    }

    /// Whether a transcript is worth a Claude pass: anything long, or with fillers or a
    /// spoken correction. Short clean ones go straight in, a second sooner.
    public static func needsTidy(_ raw: String) -> Bool {
        let words = raw.split(whereSeparator: \.isWhitespace)
        if words.count > 25 { return true }
        let lower = " " + raw.lowercased().replacingOccurrences(of: "[,.!?]", with: " ", options: .regularExpression) + " "
        let markers = [" um ", " uh ", " uhm ", " er ", " hmm ", " no wait ", " actually ", " i mean ", " scratch that ", " sorry ",
                       " new line ", " new paragraph ", " bullet ", " comma ", " period ", " question mark ",
                       "אממ", "אה ", " רגע", " בעצם", " כלומר", " סליחה", " שורה חדשה"]
        return markers.contains { lower.contains($0) }
    }

    /// Adds a space before inserted text when it would otherwise glue onto the previous word.
    public static func spaced(_ text: String, after previous: Character?) -> String {
        guard let previous, !previous.isWhitespace, let first = text.first else { return text }
        if ".,;:!?)]}%".contains(first) { return text }
        if "([{\"'“‘/-".contains(previous) { return text }
        return " " + text
    }
}

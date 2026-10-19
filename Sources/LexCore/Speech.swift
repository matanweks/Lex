import CryptoKit
import Foundation
import NaturalLanguage

public enum SpeechProvider: String, CaseIterable, Identifiable, Sendable {
    case google
    case elevenLabs = "elevenlabs"
    case system

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .google: return "Google Chirp 3 HD (recommended)"
        case .elevenLabs: return "ElevenLabs"
        case .system: return "macOS voice (free, offline)"
        }
    }

    /// List price per 1,000 characters, for the usage line in Settings. Checked 2026-10-19.
    public func pricePer1k(model: ElevenLabsTTS.Model) -> Double {
        switch self {
        case .google: return 0.03
        case .elevenLabs: return model.pricePer1k
        case .system: return 0
        }
    }

    /// Characters per month that cost nothing (Google's Chirp 3 HD free tier).
    public var freeCharactersPerMonth: Int {
        switch self {
        case .google: return 1_000_000
        case .elevenLabs: return 0
        case .system: return .max
        }
    }
}

public enum SpeechText {
    /// Selected text as it should be spoken: no zero-width characters, collapsed spacing,
    /// line breaks kept as sentence breaks.
    public static func clean(_ s: String) -> String {
        let zeroWidth = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00AD}")
        let scalars = s.unicodeScalars.filter { !zeroWidth.contains($0) }
        var t = String(String.UnicodeScalarView(scalars))
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " *\\n[\\n ]*", with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into chunks along sentence boundaries, small first and growing: the
    /// first chunk is short so audio starts quickly (Google takes ~0.5 s plus ~8 ms per
    /// character), and each chunk plays longer than the next one takes to fetch. Every chunk
    /// stays well under Google's 5,000-byte limit, even for 3-byte characters.
    public static func chunks(_ text: String, ramp: [Int] = [90, 240, 600], max: Int = 1200) -> [String] {
        var sentences = SentenceSplitter.split(text, caret: nil).flatMap { split(long: $0.text, max: max) }
        // A long opening sentence is split at a clause boundary, where a pause sounds natural.
        if let first = sentences.first, first.count > ramp[0], let (a, b) = splitClause(first, near: ramp[0]) {
            sentences.replaceSubrange(0...0, with: [a, b])
        }
        var out: [String] = []
        var current = ""
        func limit() -> Int { out.count < ramp.count ? ramp[out.count] : max }
        for s in sentences {
            if current.isEmpty {
                current = s
            } else if current.count + 1 + s.count <= limit() {
                current += " " + s
            } else {
                out.append(current)
                current = s
            }
            if out.isEmpty, current.count >= ramp[0] {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The opening clause of a long sentence: up to the last comma, semicolon, colon or dash
    /// that leaves at least 25 characters on each side, near `near` characters in.
    static func splitClause(_ s: String, near: Int) -> (String, String)? {
        let chars = Array(s)
        let upper = Swift.min(chars.count - 25, near + near / 2)
        guard upper > 25 else { return nil }
        for i in stride(from: upper, through: 25, by: -1) where ",;:—".contains(chars[i]) {
            let head = String(chars[...i]).trimmingCharacters(in: .whitespaces)
            let tail = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
            guard !tail.isEmpty else { return nil }
            return (head, tail)
        }
        return nil
    }

    /// Breaks a sentence longer than `max` at the last comma, semicolon or space before it.
    static func split(long s: String, max: Int) -> [String] {
        guard s.count > max else { return [s] }
        var rest = Substring(s)
        var parts: [String] = []
        while rest.count > max {
            let window = rest.prefix(max)
            let cut = window.lastIndex(where: { ",;:".contains($0) }).map { rest.index(after: $0) }
                ?? window.lastIndex(of: " ")
                ?? window.endIndex
            parts.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts.filter { !$0.isEmpty }
    }

    /// The text's main language as a BCP-47 code (e.g. "en", "he"), or nil if unsure.
    public static func language(of text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(2000)))
        return r.dominantLanguage?.rawValue
    }
}

public enum GoogleTTS {
    public static let endpoint = URL(string: "https://texttospeech.googleapis.com/v1/text:synthesize")!

    /// Chirp 3 HD voices. The same names exist in every Chirp 3 HD locale.
    public static let voices: [(name: String, description: String)] = [
        ("Kore", "Female, firm"), ("Aoede", "Female, breezy"), ("Leda", "Female, youthful"), ("Zephyr", "Female, bright"),
        ("Charon", "Male, informative"), ("Fenrir", "Male, excitable"), ("Orus", "Male, firm"), ("Puck", "Male, upbeat"),
    ]

    /// Chirp 3 HD locale for a detected language; English when unknown.
    public static func locale(for language: String?) -> String {
        switch language {
        case "he": return "he-IL"
        case "es": return "es-ES"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "it": return "it-IT"
        case "pt": return "pt-BR"
        case "nl": return "nl-NL"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "ru": return "ru-RU"
        case "ar": return "ar-XA"
        case "hi": return "hi-IN"
        case "tr": return "tr-TR"
        case "pl": return "pl-PL"
        case "zh-Hans", "zh-Hant": return "cmn-CN"
        default: return "en-US"
        }
    }

    public static func requestBody(text: String, locale: String, voice: String) -> [String: Any] {
        [
            "input": ["text": text],
            "voice": ["languageCode": locale, "name": "\(locale)-Chirp3-HD-\(voice)"],
            "audioConfig": ["audioEncoding": "MP3"],
        ]
    }

    public static func audio(from data: Data) throws -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = obj["audioContent"] as? String, let audio = Data(base64Encoded: b64) else {
            throw SpeechError.badResponse
        }
        return audio
    }
}

/// Google sign-in for organisations that block API keys: Application Default Credentials,
/// as written by `gcloud auth application-default login`. Lex reads the saved refresh token
/// and trades it for short-lived access tokens itself, so gcloud isn't needed at run time.
public final class GoogleADC: @unchecked Sendable {
    public struct Credentials: Equatable, Sendable {
        public let clientID: String
        public let clientSecret: String
        public let refreshToken: String
        public let quotaProject: String?
    }

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gcloud/application_default_credentials.json")
    }

    private let file: URL
    private let session: URLSession
    private let lock = NSLock()
    private var token: (value: String, expires: Date, fileDate: Date?)?

    public init(file: URL = GoogleADC.defaultFile, session: URLSession = .shared) {
        self.file = file
        self.session = session
    }

    /// The signed-in user's credentials, if gcloud has saved them (user accounts only).
    public func credentials() -> Credentials? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return Self.parse(data)
    }

    public static func parse(_ data: Data) -> Credentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "authorized_user",
              let id = obj["client_id"] as? String, let secret = obj["client_secret"] as? String,
              let refresh = obj["refresh_token"] as? String else { return nil }
        return Credentials(clientID: id, clientSecret: secret, refreshToken: refresh, quotaProject: obj["quota_project_id"] as? String)
    }

    /// A valid access token, refreshed when it's within a minute of expiring or when gcloud
    /// has saved a new sign-in since.
    public func accessToken() async throws -> (token: String, quotaProject: String?) {
        guard let creds = credentials() else { throw SpeechError.missingKey(.google) }
        let fileDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock()
        if let t = token, t.expires > Date().addingTimeInterval(60), t.fileDate == fileDate {
            lock.unlock()
            return (t.value, creds.quotaProject)
        }
        lock.unlock()

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        req.httpBody = Self.form([
            "client_id": creds.clientID, "client_secret": creds.clientSecret,
            "refresh_token": creds.refreshToken, "grant_type": "refresh_token",
        ])
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj["access_token"] as? String else {
            throw SpeechError.signInExpired
        }
        let lifetime = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        lock.lock()
        token = (value, Date().addingTimeInterval(lifetime), fileDate)
        lock.unlock()
        return (value, creds.quotaProject)
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/")
        let body = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

public enum ElevenLabsTTS {
    public enum Model: String, CaseIterable, Identifiable, Sendable {
        case flash = "eleven_flash_v2_5"
        case multilingual = "eleven_multilingual_v2"
        case v3 = "eleven_v3"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .flash: return "Flash v2.5: fastest, $0.04 per 1,000 characters"
            case .multilingual: return "Multilingual v2: richer, $0.08 per 1,000 characters"
            case .v3: return "v3: most expressive, $0.08 per 1,000 characters"
            }
        }

        public var pricePer1k: Double { self == .flash ? 0.04 : 0.08 }
    }

    /// George, from ElevenLabs' default library; replaced by the user's pick in Settings.
    public static let defaultVoiceID = "JBFqnCBsd6RMkjVDRZzb"

    public static func url(voiceID: String) -> URL {
        URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=mp3_44100_128")!
    }

    public static func requestBody(text: String, model: Model) -> [String: Any] {
        ["text": text, "model_id": model.rawValue]
    }

    /// Parses GET /v1/voices into (id, name) pairs.
    public static func voices(from data: Data) -> [(id: String, name: String)] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["voices"] as? [[String: Any]] else { return [] }
        return list.compactMap { v in
            guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
            return (id, name)
        }
    }
}

public enum SpeechError: LocalizedError, Equatable {
    case missingKey(SpeechProvider)
    case signInExpired
    case http(SpeechProvider, Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey(let p): return p == .google
            ? "Sign in with gcloud or add a Google API key in Settings › Read aloud."
            : "Add your ElevenLabs API key in Settings."
        case .signInExpired: return "Your Google sign-in has expired. Run: gcloud auth application-default login"
        case .http(let p, let code, let message):
            let name = p == .google ? "Google" : "ElevenLabs"
            if p == .google, code == 403 || code == 400 && message.contains("API key") {
                return "Google refused the request. Enable the Cloud Text-to-Speech API (with billing) on your project, and set it as your quota project: gcloud auth application-default set-quota-project PROJECT_ID. \(message)"
            }
            return "\(name) error \(code): \(message)"
        case .badResponse: return "The speech service sent back no audio."
        }
    }
}

/// Turns text into MP3 audio through Google or ElevenLabs, with a disk cache so the same
/// sentence read twice is paid for once.
public final class SpeechClient: @unchecked Sendable {
    private let session: URLSession
    private let cacheDir: URL?
    public let adc: GoogleADC

    /// Google works with an API key or with a gcloud sign-in.
    public var googleSignedIn: Bool { adc.credentials() != nil }

    public init(cacheDirectory: URL?, adcFile: URL = GoogleADC.defaultFile) {
        adc = GoogleADC(file: adcFile)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        session = URLSession(configuration: config)
        cacheDir = cacheDirectory
        if let cacheDirectory { try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true) }
    }

    public struct Request: Sendable {
        public let text: String
        public let provider: SpeechProvider
        public let key: String
        public let googleLocale: String
        public let googleVoice: String
        public let elevenVoiceID: String
        public let elevenModel: ElevenLabsTTS.Model

        public init(text: String, provider: SpeechProvider, key: String, googleLocale: String, googleVoice: String, elevenVoiceID: String, elevenModel: ElevenLabsTTS.Model) {
            self.text = text
            self.provider = provider
            self.key = key
            self.googleLocale = googleLocale
            self.googleVoice = googleVoice
            self.elevenVoiceID = elevenVoiceID
            self.elevenModel = elevenModel
        }

        var cacheKey: String {
            let id = provider == .google ? "g|\(googleLocale)|\(googleVoice)" : "e|\(elevenVoiceID)|\(elevenModel.rawValue)"
            let digest = SHA256.hash(data: Data((id + "|" + text).utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Audio for one chunk, and whether it came from the cache (cached audio is free).
    public func synthesize(_ r: Request) async throws -> (audio: Data, cached: Bool) {
        let file = cacheDir?.appendingPathComponent(r.cacheKey + ".mp3")
        if let file, let data = try? Data(contentsOf: file), !data.isEmpty { return (data, true) }
        guard !r.key.isEmpty || (r.provider == .google && googleSignedIn) else { throw SpeechError.missingKey(r.provider) }

        var req: URLRequest
        switch r.provider {
        case .google:
            req = URLRequest(url: GoogleTTS.endpoint)
            if !r.key.isEmpty {
                req.setValue(r.key, forHTTPHeaderField: "x-goog-api-key")
            } else {
                let (token, project) = try await adc.accessToken()
                req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
                if let project { req.setValue(project, forHTTPHeaderField: "x-goog-user-project") }
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: GoogleTTS.requestBody(text: r.text, locale: r.googleLocale, voice: r.googleVoice))
        case .elevenLabs:
            req = URLRequest(url: ElevenLabsTTS.url(voiceID: r.elevenVoiceID))
            req.setValue(r.key, forHTTPHeaderField: "xi-api-key")
            req.setValue("audio/mpeg", forHTTPHeaderField: "accept")
            req.httpBody = try JSONSerialization.data(withJSONObject: ElevenLabsTTS.requestBody(text: r.text, model: r.elevenModel))
        case .system:
            throw SpeechError.badResponse
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SpeechError.http(r.provider, status, Self.message(from: data)) }
        let audio = r.provider == .google ? try GoogleTTS.audio(from: data) : data
        guard !audio.isEmpty else { throw SpeechError.badResponse }
        if let file { try? audio.write(to: file) }
        return (audio, false)
    }

    /// Transcribes up to about a minute of 16 kHz audio with Google's Chirp 3, through the
    /// gcloud sign-in (billed to its quota project).
    public func transcribe(_ audio: PCM16, languages: [String], phrases: [String]) async throws -> String {
        guard let project = adc.credentials()?.quotaProject else { throw SpeechError.missingKey(.google) }
        let (token, _) = try await adc.accessToken()
        var req = URLRequest(url: GoogleSTT.url(project: project))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue(project, forHTTPHeaderField: "x-goog-user-project")
        req.httpBody = try JSONSerialization.data(withJSONObject: GoogleSTT.requestBody(audio: audio, languages: languages, phrases: phrases))
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = Self.message(from: data)
            if status == 403, message.contains("disabled") || message.contains("not been used") {
                throw SpeechError.http(.google, 403, "Turn on Speech-to-Text for project \(project): gcloud services enable speech.googleapis.com --project \(project)")
            }
            throw SpeechError.http(.google, status, message)
        }
        return try GoogleSTT.transcript(from: data)
    }

    /// The voices on an ElevenLabs account, for the picker in Settings.
    public func elevenLabsVoices(key: String) async -> [(id: String, name: String)] {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        guard let (data, response) = try? await session.data(for: req), (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return ElevenLabsTTS.voices(from: data)
    }

    /// Keeps the cache under `limit` bytes by deleting the oldest files.
    public func trimCache(limit: Int = 200_000_000) {
        guard let cacheDir, let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let info = files.compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = info.reduce(0) { $0 + $1.2 }
        for (url, _, size) in info where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    static func message(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }  // Google
            if let d = obj["detail"] as? [String: Any], let m = d["message"] as? String { return m }  // ElevenLabs
            if let d = obj["detail"] as? String { return d }
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? "no details"
    }
}

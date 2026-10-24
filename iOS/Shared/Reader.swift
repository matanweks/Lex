import AVFoundation
import LexCore
import SwiftUI

/// Reads text aloud with the iPhone's own voice, or Google's or ElevenLabs' when a key is set.
/// Cloud audio is fetched a chunk or two ahead, like on the Mac, so the first sentence plays
/// quickly and stopping early doesn't pay for audio nobody hears.
@MainActor
final class Reader: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    enum Phase { case idle, loading, playing, paused }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var voice = ""
    @Published private(set) var note: String?
    /// How fast it reads; changing it applies at once and becomes the default (Settings › Read aloud).
    @Published private(set) var speed: Double = Reader.allowed(SharedDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1.0)

    static let speeds: [Double] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// Within the speeds offered (the setting, or a rate from the lock screen, could be anything).
    static func allowed(_ value: Double) -> Double {
        value.isFinite ? min(max(value, speeds[0]), speeds[speeds.count - 1]) : 1.0
    }
    /// What the skip buttons jump by.
    static let skipSeconds = 15.0

    private let client = SpeechClient(cacheDirectory: LocalStore.folder.appendingPathComponent("Speech", isDirectory: true))
    private let synth = AVSpeechSynthesizer()
    private var chunks: [String] = []
    private var audio: [Int: Data] = [:]
    private var fetching = Set<Int>()
    private var current = 0
    private var player: AVAudioPlayer?
    private var template: SpeechClient.Request?
    private var run = UUID()
    private var language: String?
    private var failedFrom: Int?
    /// The iPhone voice's text, where the current utterance starts in it (UTF-16), and the word
    /// it's saying, so it can skip and change speed mid-way.
    private var spokenText: NSString = ""
    private var spokenStart = 0
    private var spokenAt = 0
    /// A pause asked for before the iPhone voice started; it takes effect once it does.
    private var pendingPause = false

    override init() {
        super.init()
        synth.delegate = self
    }

    var isActive: Bool { phase != .idle }

    func read(_ raw: String) {
        let text = SpeechText.clean(raw)
        guard !text.isEmpty else { return }
        stop()
        run = UUID()
        note = nil
        language = SpeechText.language(of: text)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        let d = SharedDefaults.standard
        let provider = SpeechProvider(rawValue: d.string(forKey: "speechProvider") ?? "") ?? .system
        let key = provider == .google ? Keychain.read(Keychain.google) ?? "" : provider == .elevenLabs ? Keychain.read(Keychain.elevenLabs) ?? "" : ""
        guard provider != .system, !key.isEmpty else {
            if provider != .system { note = "Add a key in Settings › Read aloud for the \(provider == .google ? "Google" : "ElevenLabs") voice." }
            speakWithSystemVoice(text)
            return
        }
        let googleVoice = d.string(forKey: "googleVoice") ?? "Charon"
        chunks = SpeechText.chunks(text)
        voice = provider == .google ? googleVoice : "ElevenLabs"
        phase = .loading
        template = SpeechClient.Request(text: "", provider: provider, key: key, googleLocale: GoogleTTS.locale(for: language),
                                        googleVoice: googleVoice, elevenVoiceID: ElevenLabsTTS.defaultVoiceID, elevenModel: .flash)
        fetch(0)
        fetch(1)
    }

    func stop() {
        run = UUID()
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        chunks = []
        audio = [:]
        fetching = []
        failedFrom = nil
        pendingPause = false
        current = 0
        phase = .idle
    }

    func togglePause() {
        switch phase {
        case .playing:
            if let player { player.pause() } else { synth.pauseSpeaking(at: .word) }
            phase = .paused
        case .paused:
            if let player { player.play() } else if pendingPause { pendingPause = false } else { synth.continueSpeaking() }
            phase = .playing
        default:
            break
        }
    }

    func setSpeed(_ value: Double) {
        speed = Self.allowed(value)
        SharedDefaults.standard.set(speed, forKey: "speechSpeed")
        if let player {
            player.rate = Float(speed)
        } else if synth.isSpeaking {
            // The iPhone voice's rate is set per utterance: go on from the word it's at.
            speakSystem(from: spokenAt, paused: phase == .paused)
        }
    }

    /// Forward (positive) or back by about `seconds`, across parts of the audio.
    func skip(_ seconds: Double) {
        if let player {
            let target = player.currentTime + seconds
            let paused = phase == .paused
            if target >= player.duration {
                guard current + 1 < chunks.count else { return stop() }
                player.stop()
                self.player = nil
                play(current + 1, from: target - player.duration, paused: paused)
            } else if target < 0, current > 0, audio[current - 1] != nil {
                player.stop()
                self.player = nil
                // Negative: that far before the end of the part before.
                play(current - 1, from: target, paused: paused)
            } else {
                player.currentTime = max(0, target)
            }
        } else if synth.isSpeaking {
            // The iPhone voice says about 15 characters a second at 1×.
            let move = Int(min(max(seconds * 15 * speed, -1_000_000), 1_000_000))
            speakSystem(from: wordStart(near: spokenAt + move), paused: phase == .paused)
        }
    }

    private func fetch(_ i: Int) {
        guard i < chunks.count, audio[i] == nil, !fetching.contains(i), let template else { return }
        fetching.insert(i)
        let id = run
        let request = SpeechClient.Request(text: chunks[i], provider: template.provider, key: template.key, googleLocale: template.googleLocale,
                                           googleVoice: template.googleVoice, elevenVoiceID: template.elevenVoiceID, elevenModel: template.elevenModel)
        Task { [client] in
            do {
                let (data, _) = try await client.synthesize(request)
                guard self.run == id else { return }
                self.fetching.remove(i)
                self.audio[i] = data
                if i == self.current, self.player == nil, self.phase == .loading { self.play(i) }
            } catch {
                guard self.run == id else { return }
                self.fetching.remove(i)
                self.note = error.localizedDescription
                self.failedFrom = min(self.failedFrom ?? i, i)
                // Waiting on this very chunk: switch voices now. Otherwise when it's due.
                if i == self.current, self.player == nil { self.fallBack(from: i) }
            }
        }
    }

    /// Don't leave the user in silence: read the rest with the iPhone's voice.
    private func fallBack(from i: Int) {
        let rest = chunks.indices.contains(i) ? chunks[i...].joined(separator: " ") : ""
        player?.stop()
        player = nil
        chunks = []
        audio = [:]
        if rest.isEmpty { stop() } else { speakWithSystemVoice(rest) }
    }

    /// `offset` seconds into part `i`; a negative one counts back from its end.
    private func play(_ i: Int, from offset: Double = 0, paused: Bool = false) {
        if let failedFrom, i >= failedFrom, audio[i] == nil {
            fallBack(from: i)
            return
        }
        guard let data = audio[i] else {
            current = i
            phase = .loading
            fetch(i)
            fetch(i + 1)
            return
        }
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.enableRate = true
            p.rate = Float(speed)
            if offset != 0 { p.currentTime = offset > 0 ? min(offset, max(p.duration - 0.2, 0)) : max(0, p.duration + offset) }
            if paused { p.prepareToPlay() } else { p.play() }
            player = p
            current = i
            phase = paused ? .paused : .playing
            fetch(i + 1)
            fetch(i + 2)
        } catch {
            note = error.localizedDescription
            stop()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard p === self.player else { return }
            self.player = nil
            let next = self.current + 1
            if next < self.chunks.count { self.play(next) } else { self.stop() }
        }
    }

    private func speakWithSystemVoice(_ text: String) {
        spokenText = text as NSString
        speakSystem(from: 0)
    }

    /// The iPhone voice, from `location` (UTF-16) in its text.
    private func speakSystem(from location: Int, paused: Bool = false) {
        let start = min(max(location, 0), spokenText.length)
        guard start < spokenText.length else { return stop() }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        spokenStart = start
        spokenAt = start
        let utterance = AVSpeechUtterance(string: spokenText.substring(from: start))
        let prefix = language ?? "en"
        utterance.voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: prefix)
        // The synthesizer's rate isn't linear; this keeps 1× natural and 2× brisk but clear.
        utterance.rate = Float(min(max(0.5 + (speed - 1) * 0.2, 0.35), 0.7))
        voice = utterance.voice?.name ?? "iPhone voice"
        phase = .playing
        synth.speak(utterance)
        if paused {
            // Pausing does nothing until the utterance has begun: do it then.
            pendingPause = true
            phase = .paused
        }
    }

    private func applyPendingPause() {
        guard pendingPause else { return }
        pendingPause = false
        synth.pauseSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.applyPendingPause() }
    }

    /// The start of the word at `location`, so a skip doesn't begin mid-word.
    private func wordStart(near location: Int) -> Int {
        var i = min(max(location, 0), spokenText.length)
        while i > 0, i < spokenText.length, let c = Unicode.Scalar(spokenText.character(at: i - 1)), !CharacterSet.whitespacesAndNewlines.contains(c) { i -= 1 }
        return i
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.spokenAt = self.spokenStart + range.location
            self.applyPendingPause()
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.player == nil { self.stop() } }
    }
}

/// A play/stop button for reading text aloud, with the voice's name while it plays.
struct ReadAloudButton: View {
    @ObservedObject var reader: Reader
    let text: String

    var body: some View {
        Button {
            reader.isActive ? reader.stop() : reader.read(text)
        } label: {
            switch reader.phase {
            case .idle: Label("Read aloud", systemImage: "speaker.wave.2")
            case .loading: Label("Loading…", systemImage: "hourglass")
            case .playing, .paused: Label("Stop", systemImage: "stop.fill")
            }
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !reader.isActive)
    }
}

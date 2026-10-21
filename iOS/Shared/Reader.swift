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

    private let client = SpeechClient(cacheDirectory: AppGroup.container.appendingPathComponent("Speech", isDirectory: true))
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

        let d = AppGroup.defaults
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
        current = 0
        phase = .idle
    }

    func togglePause() {
        switch phase {
        case .playing:
            if let player { player.pause() } else { synth.pauseSpeaking(at: .word) }
            phase = .paused
        case .paused:
            if let player { player.play() } else { synth.continueSpeaking() }
            phase = .playing
        default:
            break
        }
    }

    private var speed: Double { AppGroup.defaults.object(forKey: "speechSpeed") as? Double ?? 1.0 }

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

    private func play(_ i: Int) {
        if let failedFrom, i >= failedFrom, audio[i] == nil {
            fallBack(from: i)
            return
        }
        guard let data = audio[i] else {
            current = i
            phase = .loading
            return
        }
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.enableRate = true
            p.rate = Float(speed)
            p.play()
            player = p
            current = i
            phase = .playing
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
        let utterance = AVSpeechUtterance(string: text)
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

import AVFoundation
import AppKit
import LexCore
import SwiftUI

final class ReaderModel: ObservableObject {
    enum Phase { case idle, loading, playing, paused }
    @Published var phase: Phase = .idle
    @Published var voice = ""
    @Published var index = 0
    @Published var count = 0
    @Published var speed = 1.0
}

/// Reads text aloud. Cloud voices are fetched sentence-group by sentence-group: the first
/// short chunk starts playing as soon as it arrives, and at most two chunks are fetched ahead,
/// so stopping early doesn't pay for audio nobody hears.
final class Reader: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let speeds = [1.0, 1.25, 1.5, 1.75, 2.0, 0.8]

    let model = ReaderModel()
    private let settings: AppSettings
    private let client: SpeechClient
    private lazy var hud = ReaderHUD(model: model, onPause: { [weak self] in self?.togglePause() }, onStop: { [weak self] in self?.stop() }, onSpeed: { [weak self] in self?.cycleSpeed() })
    private var chunks: [String] = []
    private var audio: [Int: Data] = [:]
    private var fetching = Set<Int>()
    private var current = 0
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var run = UUID()
    private var template: SpeechClient.Request?
    private var language: String?
    private var toldAboutFallback = false
    private var failedFrom: Int?

    var isActive: Bool { model.phase != .idle }

    init(settings: AppSettings, client: SpeechClient) {
        self.settings = settings
        self.client = client
        super.init()
        synth.delegate = self
    }

    func read(_ raw: String) {
        let text = SpeechText.clean(raw)
        guard !text.isEmpty else { return }
        stop()
        run = UUID()
        language = SpeechText.language(of: text)
        model.speed = settings.speechSpeed
        model.index = 0

        var provider = settings.speechProvider
        let key = settings.speechKey(for: provider) ?? ""
        let signedIn = provider == .google && client.googleSignedIn
        if provider != .system, key.isEmpty, !signedIn {
            provider = .system
            if !toldAboutFallback {
                toldAboutFallback = true
                Toast.show("Reading with the macOS voice. Sign in to Google in Settings › Read aloud for a natural one.")
            }
        }
        if provider == .system {
            speakWithSystemVoice(text)
            return
        }

        chunks = SpeechText.chunks(text)
        model.count = chunks.count
        model.voice = provider == .google ? settings.googleVoice : "ElevenLabs"
        model.phase = .loading
        template = SpeechClient.Request(
            text: "", provider: provider, key: key,
            googleLocale: GoogleTTS.locale(for: language), googleVoice: settings.googleVoice,
            elevenVoiceID: settings.elevenVoiceID, elevenModel: settings.elevenModel)
        hud.show()
        Log.info("read aloud: \(text.count) chars in \(chunks.count) chunks via \(provider.rawValue)")
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
        model.phase = .idle
        hud.hide()
    }

    func togglePause() {
        switch model.phase {
        case .playing:
            if let player { player.pause() } else { synth.pauseSpeaking(at: .word) }
            model.phase = .paused
        case .paused:
            if let player { player.play() } else { synth.continueSpeaking() }
            model.phase = .playing
        default:
            break
        }
    }

    func cycleSpeed() {
        let i = Self.speeds.firstIndex(where: { abs($0 - model.speed) < 0.01 }) ?? 0
        model.speed = Self.speeds[(i + 1) % Self.speeds.count]
        settings.speechSpeed = model.speed
        player?.rate = Float(model.speed)
    }

    // MARK: Cloud voices

    private func fetch(_ i: Int) {
        guard i < chunks.count, audio[i] == nil, !fetching.contains(i), let template else { return }
        fetching.insert(i)
        let id = run
        let text = chunks[i]
        let request = SpeechClient.Request(
            text: text, provider: template.provider, key: template.key,
            googleLocale: template.googleLocale, googleVoice: template.googleVoice,
            elevenVoiceID: template.elevenVoiceID, elevenModel: template.elevenModel)
        let started = Date()
        Task { [client] in
            do {
                let (data, cached) = try await client.synthesize(request)
                await MainActor.run {
                    guard self.run == id else { return }
                    self.fetching.remove(i)
                    self.audio[i] = data
                    if !cached { self.settings.addSpeechUsage(text.count, for: request.provider) }
                    if i == 0 { Log.info("first audio in \(Int(Date().timeIntervalSince(started) * 1000)) ms\(cached ? " (cached)" : "")") }
                    if i == self.current, self.player == nil, self.model.phase == .loading { self.play(i) }
                }
            } catch {
                await MainActor.run {
                    guard self.run == id else { return }
                    self.fetching.remove(i)
                    Log.info("speech failed: \(error.localizedDescription)")
                    Toast.show(error.localizedDescription)
                    self.failedFrom = min(self.failedFrom ?? i, i)
                    // Waiting on this very chunk: switch voices now. Otherwise the current
                    // chunk finishes first and the switch happens when this one is due.
                    if i == self.current, self.player == nil { self.fallBack(from: i) }
                }
            }
        }
    }

    /// Don't leave the user in silence: read the rest with the macOS voice.
    private func fallBack(from i: Int) {
        let rest = chunks.indices.contains(i) ? chunks[i...].joined(separator: " ") : ""
        player?.stop()
        player = nil
        chunks = []
        audio = [:]
        guard !rest.isEmpty else { finish(); return }
        speakWithSystemVoice(rest)
    }

    private func play(_ i: Int) {
        if let failedFrom, i >= failedFrom, audio[i] == nil {
            fallBack(from: i)
            return
        }
        guard let data = audio[i] else {
            current = i
            model.phase = .loading
            return
        }
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.enableRate = true
            p.rate = Float(model.speed)
            p.prepareToPlay()
            p.play()
            player = p
            current = i
            model.index = i
            model.phase = .playing
            audio[i - 1] = nil
            fetch(i + 1)
            fetch(i + 2)
        } catch {
            Log.info("couldn't play chunk \(i): \(error.localizedDescription)")
            stop()
        }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        guard p === player else { return }
        player = nil
        let next = current + 1
        if next < chunks.count {
            current = next
            play(next)
        } else {
            finish()
        }
    }

    // MARK: macOS voice

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        let prefix = language ?? "en"
        utterance.voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: prefix)
        // The synthesizer's rate isn't linear; this keeps 1× natural and 2× brisk but clear.
        utterance.rate = Float(min(max(0.5 + (model.speed - 1) * 0.2, 0.35), 0.7))
        model.voice = utterance.voice?.name ?? "macOS"
        Log.info("read aloud: \(text.count) chars via macOS voice \(model.voice) (quality \(utterance.voice?.quality.rawValue ?? 0))")
        model.count = 1
        model.index = 0
        model.phase = .playing
        hud.show()
        synth.speak(utterance)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    private func finish() {
        run = UUID()
        player = nil
        chunks = []
        audio = [:]
        model.phase = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if self?.model.phase == .idle { self?.hud.hide() }
        }
    }
}

// MARK: Mini player

struct ReaderHUDView: View {
    @ObservedObject var model: ReaderModel
    let onPause: () -> Void
    let onStop: () -> Void
    let onSpeed: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.16, green: 0.62, blue: 0.40))
                .symbolEffect(.variableColor.iterative, isActive: model.phase == .playing)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.phase == .loading ? "Getting audio…" : model.phase == .paused ? "Paused" : "Reading aloud")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.count > 1 ? "\(model.voice) · \(model.index + 1) of \(model.count)" : model.voice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: onSpeed) {
                Text(Self.speedLabel(model.speed))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 34)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Speed")
            Button(action: onPause) {
                Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill").frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .loading)
            Button(action: onStop) {
                Image(systemName: "stop.fill").frame(width: 18)
            }
            .buttonStyle(.plain)
            .help("Stop (or press the shortcut again)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 300)
        .panelBackground(radius: 14)
    }

    static func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s)
    }
}

final class ReaderHUD {
    private let panel = FloatingPanel(level: .statusBar)

    init(model: ReaderModel, onPause: @escaping () -> Void, onStop: @escaping () -> Void, onSpeed: @escaping () -> Void) {
        panel.contentView = FirstMouseHostingView(rootView: ReaderHUDView(model: model, onPause: onPause, onStop: onStop, onSpeed: onSpeed))
    }

    /// Bottom centre of the screen you're working on, clear of the Dock.
    func show() {
        guard !panel.isVisible else { return }
        let size = panel.contentView?.fittingSize ?? CGSize(width: 300, height: 48)
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.minY + 40, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// MARK: Getting the text

enum TextGrabber {
    /// The selected text in the frontmost app. Falls back to copying the selection (web pages,
    /// PDFs, Mail), then to the paragraph at the caret when nothing is selected in a text field.
    /// Never reads password fields.
    static func grab(_ tracker: FocusTracker, completion: @escaping (String?) -> Void) {
        tracker.selection { result in
            switch result {
            case .secure:
                completion(nil)
            case .selected(let text):
                completion(text)
            case .caret(let text, let selection):
                completion(TextTargets.refineRange(in: text, selection: selection, scope: .paragraph)
                    .map { (text as NSString).substring(with: $0) })
            case .unknown:
                copySelection { copied in completion(copied) }
            }
        }
    }

    /// Copies with ⌘C, reads the clipboard, and puts the user's clipboard back.
    static func copySelection(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved = Paster.snapshot()
        let before = pb.changeCount
        Keys.press(0x08, flags: .maskCommand)  // ⌘C
        var waited = 0.0
        func poll() {
            if pb.changeCount != before {
                let text = pb.string(forType: .string)
                Paster.restore(saved)
                completion(text?.isEmpty == false ? text : nil)
            } else if waited >= 0.5 {
                completion(nil)
            } else {
                waited += 0.03
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
    }
}

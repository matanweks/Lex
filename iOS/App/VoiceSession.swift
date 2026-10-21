import AVFoundation
import LexCore
import SwiftUI

/// The app's side of the keyboard's mic. The keyboard opens Lex (lex://listen) to start the
/// microphone, which iOS only allows while Lex is in front, and Lex keeps it running in the
/// background while you dictate. The mic goes off the moment you tap Done or Cancel, as soon
/// as iOS says the phone is locked, on a phone call, and after two minutes of listening.
/// Audio is kept only between the keyboard's start and stop.
@MainActor
final class VoiceSession: ObservableObject {
    static let shared = VoiceSession()
    /// The longest dictation: then Lex types what it heard and lets go of the mic.
    static let longest: TimeInterval = 120

    @Published private(set) var isOn = false
    @Published private(set) var listening = false
    @Published private(set) var liveText = ""
    @Published private(set) var problem: String?

    private let recorder = Recorder()
    private let feed = FeedBox()
    private var transcriber: LiveTranscriber?
    private var request: VoiceLink.Request?
    private var listener: VoiceLink.Listener?
    private var limitTask: Task<Void, Never>?
    private var guards: [NSObjectProtocol] = []
    private var lastWrite = Date.distantPast
    #if DEBUG
    /// The running microphone is what keeps Lex awake in the background; with no microphone
    /// in test mode, silent audio does that instead.
    private var keepAwake: AVAudioEngine?
    #endif

    private init() {
        listener = VoiceLink.Listener([.start, .stop, .cancel]) { signal in
            Task { @MainActor in VoiceSession.shared.handle(signal) }
        }
    }

    /// At launch: a dictation from before Lex last quit can't finish, so tell the keyboard.
    func clearLeftovers() {
        guard !isOn, let state = VoiceLink.state, state.phase == .listening || state.phase == .finishing || state.readyUntil > Date() else { return }
        VoiceLink.state = VoiceLink.State(phase: .ready, request: state.request, readyUntil: .distantPast)
        VoiceLink.post(.changed)
    }

    /// Opened from the keyboard: hold the mic, and start on the keyboard's request.
    func begin() async {
        problem = nil
        if !isOn, !Self.simulated {
            guard await AVAudioApplication.requestRecordPermission() else {
                return fail("Lex needs the microphone to dictate. Allow it in Settings › Apps › Lex.")
            }
            do {
                recorder.collecting = false
                recorder.onChunk = { [feed] chunk in feed.current?.feed(chunk) }
                try recorder.start(alongsideOtherAudio: true)
            } catch {
                return fail("Couldn't start the microphone: \(error.localizedDescription)")
            }
        }
        #if DEBUG
        if Self.simulated, keepAwake == nil { keepAwake = Self.silentEngine() }
        #endif
        if !isOn { watchForLockAndCalls() }
        isOn = true
        startListening()
    }

    /// The mic closes when the phone locks (iOS tells apps when its protected data goes away,
    /// within seconds of locking) and when a call or another app takes the audio.
    private func watchForLockAndCalls() {
        let center = NotificationCenter.default
        guards = [
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in VoiceSession.shared.end() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                if began { Task { @MainActor in VoiceSession.shared.end() } }
            },
        ]
    }

    /// Lets go of the mic and tells the keyboard.
    func end() {
        guard isOn else { return }
        transcriber?.cancel()
        transcriber = nil
        feed.current = nil
        listening = false
        releaseMic()
        write(.ready)
    }

    /// Turns the microphone off. A transcriber that's finishing keeps what it was given.
    private func releaseMic() {
        guard isOn else { return }
        for observer in guards { NotificationCenter.default.removeObserver(observer) }
        guards = []
        limitTask?.cancel()
        if !Self.simulated { recorder.stop() }
        #if DEBUG
        keepAwake?.stop()
        keepAwake = nil
        #endif
        isOn = false
    }

    private func handle(_ signal: VoiceLink.Signal) {
        voiceLog.info("app got \(signal.rawValue, privacy: .public), on \(self.isOn), listening \(self.listening)")
        switch signal {
        case .start: if isOn { startListening() }
        case .stop: Task { await finish() }
        case .cancel: cancel()
        case .changed: break
        }
    }

    private func startListening() {
        guard let request = VoiceLink.request, request.id != self.request?.id || !listening else { return }
        transcriber?.cancel()
        self.request = request
        let live = LiveTranscriber()
        live.onText = { text in VoiceSession.shared.heard(text) }
        live.start(language: request.language)
        transcriber = live
        recorder.reset()
        recorder.collecting = true
        feed.current = live
        liveText = ""
        listening = true
        write(.listening)
        limitTask?.cancel()
        let id = request.id
        limitTask = Task {
            try? await Task.sleep(for: .seconds(Self.longest))
            guard !Task.isCancelled, self.request?.id == id else { return }
            await self.finish()
        }
    }

    private func heard(_ text: String) {
        guard listening else { return }
        liveText = text
        // The keyboard reads this from the Keychain; a few updates a second is plenty.
        guard Date().timeIntervalSince(lastWrite) > 0.15 else { return }
        write(.listening, text: text)
    }

    private func finish() async {
        guard listening, let live = transcriber, let request else { return }
        limitTask?.cancel()
        listening = false
        recorder.collecting = false
        feed.current = nil
        let silent = !Self.simulated && PauseSegmenter.isSilent(recorder.samples)
        // The mic goes off now. Writing the text down takes a moment more, which iOS allows
        // an app in the background as a background task.
        releaseMic()
        let background = UIApplication.shared.beginBackgroundTask(withName: "Lex dictation")
        defer { UIApplication.shared.endBackgroundTask(background) }
        write(.finishing, text: liveText)
        let raw: String
        do {
            raw = try await live.finish()
        } catch {
            transcriber = nil
            return write(.failed, error: "Speech recognition didn't work (\(error.localizedDescription)). The first time, iPhone downloads its speech model: try again in a minute, online.")
        }
        transcriber = nil
        guard !silent, !raw.isEmpty else {
            return write(.failed, error: "Didn't catch that. Try again a little closer to the mic.")
        }
        let text = await DictationTidy.finish(raw, before: request.before, useClaude: request.privately != true)
        voiceLog.info("app finished: \(raw.count) chars heard, \(text.count) typed")
        write(.done, text: text)
    }

    private func cancel() {
        guard listening else { return }
        recorder.collecting = false
        end()
    }

    private func fail(_ message: String) {
        problem = message
        write(.failed, error: message)
    }

    private func write(_ phase: VoiceLink.State.Phase, text: String = "", error: String? = nil) {
        lastWrite = Date()
        // `readyUntil` tells the keyboard the app is still working on its dictation; once the
        // mic is off and the text is done, the next dictation opens Lex again.
        let until = isOn ? Date().addingTimeInterval(Self.longest) : phase == .finishing ? Date().addingTimeInterval(30) : .distantPast
        VoiceLink.state = VoiceLink.State(phase: phase, text: text, error: error, request: request?.id, readyUntil: until)
        VoiceLink.post(.changed)
    }

    #if DEBUG
    private static func silentEngine() -> AVAudioEngine? {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return nil }
        silence.frameLength = silence.frameCapacity
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard (try? engine.start()) != nil else { return nil }
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()
        return engine
    }
    #endif

    /// The Simulator has no speech models; with the Claude stub on, Lex "hears" a fixed
    /// sentence instead of opening the microphone.
    private static var simulated: Bool {
        #if DEBUG
        StubClaude.isOn
        #else
        false
        #endif
    }
}

/// The transcriber the audio thread feeds, swapped safely from the main thread.
private final class FeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LiveTranscriber?

    var current: LiveTranscriber? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// What Lex shows after the keyboard opens it to start the mic.
struct ListeningView: View {
    @ObservedObject var session: VoiceSession
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "mic.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Circle().fill(session.listening ? Brand.orange : Brand.indigo))
            Text(session.listening ? "Lex is listening" : "The mic is ready")
                .font(.title2.bold())
            if let problem = session.problem {
                Text(problem).foregroundStyle(.red).multilineTextAlignment(.center)
            } else {
                Text("Go back to where you were typing: tap ◀ at the top left of the screen. Your words show up in the Lex keyboard.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            if !session.liveText.isEmpty {
                Text(session.liveText)
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
            }
            Spacer()
            Text("Lex turns the mic off as soon as you tap Done or Cancel, and when you lock the phone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Stop the Mic", role: .destructive) {
                session.end()
                onClose()
            }
            .buttonStyle(.bordered)
            Button("Done", action: onClose)
        }
        .padding(28)
    }
}

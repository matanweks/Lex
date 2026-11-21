import AVFoundation
import LexCore
import SwiftUI

/// The app's side of the keyboard's mic. The keyboard opens Lex (lex://listen) to start the
/// microphone, which iOS only allows while Lex is in front, and Lex keeps it running in the
/// background. After a dictation it stays on for a few minutes (Settings › Dictation), keeping
/// nothing, so the next one starts right from the keyboard without opening Lex, as Wispr Flow
/// and Granola do. The mic goes off when that time is up, when you tap Stop the Mic, as soon
/// as iOS says the phone is locked, on a phone call, and when something else takes the audio.
/// Audio is kept only between the keyboard's start and stop.
@MainActor
final class VoiceSession: ObservableObject {
    static let shared = VoiceSession()
    /// The longest dictation: then Lex types what it heard and lets go of the mic.
    static let longest: TimeInterval = 120
    /// How long the mic stays ready after a dictation; 0 turns it off the moment you finish.
    static var readyFor: TimeInterval { TimeInterval(Prefs.micReadyMinutes * 60) }

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
    private var idleTask: Task<Void, Never>?
    /// When the mic goes off if no dictation starts before.
    private var readyUntil = Date.distantPast
    private var guards: [NSObjectProtocol] = []
    private var lastWrite = Date.distantPast
    /// `begin()` is under way (the keyboard can open Lex twice while it asks for the mic).
    private var starting = false
    /// A dictation the keyboard cancelled while it was being written down: dropped, not kept.
    private var cancelledID: UUID?
    #if DEBUG
    /// The running microphone is what keeps Lex awake in the background; with no microphone
    /// in test mode, silent audio does that instead.
    private var keepAwake: AVAudioEngine?
    #endif

    private init() {
        listener = VoiceLink.Listener([.start, .stop, .cancel, .micOff]) { signal in
            Task { @MainActor in VoiceSession.shared.handle(signal) }
        }
    }

    /// At launch: a dictation from before Lex last quit can't finish, so tell the keyboard.
    func clearLeftovers() {
        if !isOn { MicActivity.end() }
        guard !isOn, let state = VoiceLink.state, state.phase == .listening || state.phase == .finishing || state.readyUntil > Date() else { return }
        VoiceLink.state = VoiceLink.State(phase: .ready, request: state.request, readyUntil: .distantPast)
        VoiceLink.post(.changed)
    }

    /// Opened from the keyboard: hold the mic, and start on the keyboard's request.
    func begin() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
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
                recorder.stop()
                return fail("Couldn't start the microphone: \(error.localizedDescription)")
            }
        }
        #if DEBUG
        if Self.simulated, keepAwake == nil { keepAwake = Self.silentEngine() }
        #endif
        if !isOn { watchForLockAndCalls() }
        isOn = true
        // At least a minute for the keyboard's request, even with the setting off.
        keepReady(for: max(Self.readyFor, 60))
        startListening()
    }

    /// Keeps the mic on, keeping nothing, until `seconds` from now unless a dictation starts.
    private func keepReady(for seconds: TimeInterval) {
        idleTask?.cancel()
        guard seconds > 0 else { return releaseMic() }
        readyUntil = Date().addingTimeInterval(seconds)
        MicActivity.show(listening: false, until: readyUntil)
        idleTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, !self.listening else { return }
            voiceLog.info("mic ready time is up")
            self.end()
        }
    }

    /// The mic closes when the phone locks (iOS tells apps when its protected data goes away,
    /// within seconds of locking), when a call or another app takes the audio, and when the
    /// recorder stops by itself.
    private func watchForLockAndCalls() {
        let center = NotificationCenter.default
        guards = [
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in VoiceSession.shared.stopNow() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue
                if began { Task { @MainActor in VoiceSession.shared.stopNow() } }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { _ in
                Task { @MainActor in VoiceSession.shared.audioChanged() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in VoiceSession.shared.audioChanged() }
            },
        ]
    }

    /// Reading aloud in Lex, or a headset coming or going, can stop the recorder without a
    /// word. Then the mic is let go, so the next dictation opens Lex and starts it afresh
    /// instead of hearing nothing; a dictation under way keeps what it heard.
    private func audioChanged() {
        guard isOn, !Self.simulated else { return }
        let category = AVAudioSession.sharedInstance().category
        guard !recorder.isRunning || (category != .playAndRecord && category != .record) else { return }
        voiceLog.info("the recorder stopped by itself")
        stopNow()
    }

    /// The phone locked, a call came in, or the recorder stopped: the mic goes off now, and a
    /// dictation under way is written down with what was heard so far.
    private func stopNow() {
        if listening { Task { await finish(keepMic: false) } } else { end() }
    }

    /// Lets go of the mic and tells the keyboard. A dictation still being heard is dropped;
    /// one already being written down finishes.
    func end() {
        guard isOn else { return }
        if listening {
            transcriber?.cancel()
            transcriber = nil
            feed.current = nil
            listening = false
            recorder.collecting = false
            recorder.reset()
        }
        releaseMic()
        guard transcriber == nil else { return }
        // A result the keyboard hasn't typed yet stays, for a keyboard still waiting for it.
        if var state = VoiceLink.state, state.request == request?.id, state.phase == .done || state.phase == .failed {
            state.readyUntil = .distantPast
            VoiceLink.state = state
            VoiceLink.post(.changed)
        } else {
            write(.ready)
        }
    }

    /// Turns the microphone off. A transcriber that's finishing keeps what it was given.
    private func releaseMic() {
        guard isOn else { return }
        for observer in guards { NotificationCenter.default.removeObserver(observer) }
        guards = []
        limitTask?.cancel()
        idleTask?.cancel()
        readyUntil = .distantPast
        MicActivity.end()
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
        case .cancel: if listening { cancel() } else { cancelledID = request?.id }
        case .micOff: stopNow()
        case .changed: break
        }
    }

    private func startListening() {
        // A request is heard once: one already finished or cancelled isn't started again.
        guard let request = VoiceLink.request, request.id != self.request?.id else { return }
        idleTask?.cancel()
        transcriber?.cancel()
        self.request = request
        let live = LiveTranscriber()
        let id = request.id
        live.onText = { text in VoiceSession.shared.heard(text, for: id) }
        live.start(language: request.language)
        transcriber = live
        recorder.reset()
        recorder.collecting = true
        feed.current = live
        liveText = ""
        listening = true
        MicActivity.show(listening: true, until: Date().addingTimeInterval(Self.longest))
        write(.listening)
        limitTask?.cancel()
        limitTask = Task {
            try? await Task.sleep(for: .seconds(Self.longest))
            guard !Task.isCancelled, self.request?.id == id else { return }
            await self.finish()
        }
    }

    private func heard(_ text: String, for id: UUID) {
        guard listening, request?.id == id else { return }
        liveText = text
        // The keyboard reads this from the Keychain; a few updates a second is plenty.
        guard Date().timeIntervalSince(lastWrite) > 0.15 else { return }
        write(.listening, text: text)
    }

    /// `keepMic` false turns the mic off now, whatever the setting.
    private func finish(keepMic: Bool = true) async {
        guard listening, let live = transcriber, let request else { return }
        limitTask?.cancel()
        listening = false
        recorder.collecting = false
        feed.current = nil
        let silent = !Self.simulated && PauseSegmenter.isSilent(recorder.samples)
        recorder.reset()
        // The mic stays ready for the next dictation (or goes off now). Writing the text down
        // takes a moment more, which iOS allows an app in the background as a background task.
        if keepMic { keepReady(for: Self.readyFor) } else { releaseMic() }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Lex dictation")
        defer { UIApplication.shared.endBackgroundTask(background) }
        write(.finishing, text: liveText)
        // A newer dictation can start while this one is written down (the keyboard gave up
        // waiting, or was opened again): then this one's result goes nowhere.
        let raw: String
        do {
            raw = try await live.finish()
        } catch {
            guard transcriber === live else { return }
            transcriber = nil
            return write(.failed, error: "Speech recognition didn't work (\(error.localizedDescription)). The first time, iPhone downloads its speech model: try again in a minute, online.")
        }
        guard transcriber === live else { return }
        transcriber = nil
        guard !silent, !raw.isEmpty else {
            return write(.failed, error: "Didn't catch that. Try again a little closer to the mic.")
        }
        let text = await DictationTidy.finish(raw, before: request.before, useClaude: request.privately != true)
        guard cancelledID != request.id else { return }
        // Kept even if a newer dictation started while Claude tidied it: it can still be typed
        // from the history.
        if request.privately != true { ClipboardLog.saveDictation(text) }
        guard self.request?.id == request.id else { return }
        voiceLog.info("app finished: \(raw.count) chars heard, \(text.count) typed")
        write(.done, text: text)
    }

    /// The keyboard's Cancel: drops what was heard and keeps the mic ready.
    private func cancel() {
        guard listening else { return }
        limitTask?.cancel()
        transcriber?.cancel()
        transcriber = nil
        feed.current = nil
        listening = false
        recorder.collecting = false
        recorder.reset()
        keepReady(for: Self.readyFor)
        write(.ready)
    }

    /// The mic didn't start: the keyboard waiting on its request shows why.
    private func fail(_ message: String) {
        problem = message
        write(.failed, error: message, for: VoiceLink.request?.id)
    }

    /// `id`: the request this answers, the one being heard unless given.
    private func write(_ phase: VoiceLink.State.Phase, text: String = "", error: String? = nil, for id: UUID? = nil) {
        lastWrite = Date()
        // `readyUntil` tells the keyboard the mic is ready, or the app is still working on its
        // dictation; once the mic is off and the text is done, the next dictation opens Lex.
        let until = listening ? Date().addingTimeInterval(Self.longest)
            : isOn ? readyUntil
            : phase == .finishing ? Date().addingTimeInterval(30) : .distantPast
        VoiceLink.state = VoiceLink.State(phase: phase, text: text, error: error, request: id ?? request?.id, readyUntil: until)
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
                Text("Go back to where you were typing: tap ◀ at the top left of the screen, or swipe right along the bottom edge. Your words show up in the Lex keyboard.")
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
            Text(VoiceSession.readyFor > 0
                 ? "The mic stays on for \(Int(VoiceSession.readyFor / 60)) min after you dictate, keeping nothing, so the next dictation starts right from the keyboard. Stop it from the Dynamic Island; locking the phone turns it off too."
                 : "Lex turns the mic off as soon as you tap Done or Cancel, and when you lock the phone.")
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

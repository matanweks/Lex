import AVFoundation
import AppKit
import Carbon
import LexCore
import Speech
import SwiftUI

// MARK: Microphone

/// Captures the microphone as 16 kHz mono 16-bit audio, with a live level for the HUD.
final class Recorder {
    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCM16.sampleRate), channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var buffer: [Int16] = []
    var onLevel: ((Float) -> Void)?

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    func start() throws {
        lock.lock(); buffer = []; lock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] b, _ in self?.process(b) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }

    func samples(from start: Int, to end: Int? = nil) -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        let stop = min(end ?? buffer.count, buffer.count)
        return start < stop ? Array(buffer[start..<stop]) : []
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / input.format.sampleRate + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = out.int16ChannelData, out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        lock.lock(); buffer.append(contentsOf: chunk); lock.unlock()
        var sum: Float = 0
        for s in chunk { let f = Float(s) / 32768; sum += f * f }
        let level = (sum / Float(chunk.count)).squareRoot()
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}

// MARK: The key you hold

enum DictationKey: String, CaseIterable, Identifiable {
    case rightOption, fn, rightCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: return "Hold Right ⌥ (Option)"
        case .fn: return "Hold fn 🌐"
        case .rightCommand: return "Hold Right ⌘ (Command)"
        }
    }

    var short: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .fn: return "fn"
        case .rightCommand: return "Right ⌘"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .fn: return 63
        case .rightCommand: return 54
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .fn: return .function
        case .rightCommand: return .command
        }
    }
}

/// Watches one modifier key held on its own. Using it with another key (⌥-typing a special
/// character, a ⌘ shortcut) reports `onCombo` instead, so ordinary typing never dictates.
///
/// Uses a listen-only event tap at the head of the session's queue: other keyboard tools
/// (Wispr Flow and the like) can swallow modifier events before AppKit's global monitors see
/// them. Listen-only means Lex never blocks or changes a keystroke.
final class HoldKeyMonitor {
    var key: DictationKey
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCombo: (() -> Void)?
    var onEscape: (() -> Void)?
    private var isDown = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fallback: [Any] = []

    init(key: DictationKey) {
        self.key = key
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<HoldKeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(mask), callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.info("dictation: key tap installed")
        } else {
            Log.info("dictation: key tap unavailable, using AppKit monitors")
            let handler: (NSEvent) -> Void = { [weak self] e in
                guard let cg = e.cgEvent else { return }
                self?.handle(type: e.type == .keyDown ? .keyDown : .flagsChanged, event: cg)
            }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) { fallback.append(m) }
        }
    }

    private var keyMask: CGEventFlags {
        switch key {
        case .rightOption: return .maskAlternate
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if code == key.keyCode {
                let down = flags.contains(keyMask)
                if down, !isDown {
                    // Another modifier already held means it's a shortcut, not dictation.
                    let others = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).subtracting(keyMask)
                    guard others.isEmpty else { return }
                    isDown = true
                    onPress?()
                } else if !down, isDown {
                    isDown = false
                    onRelease?()
                }
            } else if isDown {
                onCombo?()
            }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { onEscape?() }
            if isDown { onCombo?() }
        default:
            break
        }
    }
}

// MARK: Apple on-device

enum AppleTranscription {
    /// English transcription on this Mac with Apple's SpeechTranscriber (macOS 26+). Free and
    /// private; downloads the language model once if it's missing.
    static func transcribe(_ audio: PCM16) async throws -> String {
        guard #available(macOS 26.0, *) else { throw SpeechError.badResponse }
        return try await run(audio)
    }

    @available(macOS 26.0, *)
    private static func run(_ audio: PCM16) async throws -> String {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCM16.sampleRate), channels: 1, interleaved: true)!
        let wanted = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? source
        guard let pcm = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(audio.samples.count)) else { throw SpeechError.badResponse }
        pcm.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { src in pcm.int16ChannelData![0].update(from: src.baseAddress!, count: src.count) }
        let input = try convert(pcm, to: wanted)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = Task { () -> String in
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text
        }
        try await analyzer.start(inputSequence: stream)
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate + 64)) else {
            throw SpeechError.badResponse
        }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }
}

// MARK: The flow

final class DictationModel: ObservableObject {
    enum Phase { case idle, listening, locked, transcribing, polishing }
    @Published var phase: Phase = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: 24)
    @Published var keyLabel = "Right ⌥"
}

/// Hold the key, talk, let go: Lex records, transcribes, tidies the text with Claude and
/// types it at the cursor. Double-tap the key for hands-free; tap again to finish.
final class DictationController {
    let model = DictationModel()
    private let settings: AppSettings
    private let claude: ClaudeClient
    private let speech: SpeechClient
    private let tracker: FocusTracker
    private let recorder = Recorder()
    private let segmenter = PauseSegmenter()
    private lazy var hud = DictationHUD(model: model) { [weak self] in self?.cancel(silently: false) }
    private var monitor: HoldKeyMonitor?
    private var pressedAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var revealWork: DispatchWorkItem?
    private var segmentTimer: Timer?
    private var sentUpTo = 0
    private var pieces: [Task<String, Error>] = []
    private var run = UUID()
    private var holding = false
    private var engineNow: DictationEngine = .google
    private(set) var lastDictation: String?

    var isActive: Bool { model.phase != .idle || holding }

    init(settings: AppSettings, claude: ClaudeClient, speech: SpeechClient, tracker: FocusTracker) {
        self.settings = settings
        self.claude = claude
        self.speech = speech
        self.tracker = tracker
        recorder.onLevel = { [weak self] level in
            guard let self, self.model.phase == .listening || self.model.phase == .locked else { return }
            self.model.levels.removeFirst()
            self.model.levels.append(min(level * 6, 1))
        }
    }

    func start() {
        guard monitor == nil else { return }
        let m = HoldKeyMonitor(key: settings.dictationKey)
        m.onPress = { [weak self] in self?.pressed() }
        m.onRelease = { [weak self] in self?.released() }
        m.onCombo = { [weak self] in self?.combo() }
        m.onEscape = { [weak self] in
            guard let self, self.model.phase != .idle || self.holding else { return }
            self.cancel(silently: false)
        }
        monitor = m
        model.keyLabel = settings.dictationKey.short
        // Watching a key held in other apps needs Input Monitoring, on top of Accessibility.
        let listening = Self.keyMonitoringAllowed
        if !listening { CGRequestListenEventAccess() }
        Log.info("dictation ready: \(settings.dictationKey.label), engine \(settings.dictationEngine.rawValue), mic \(Recorder.permission.rawValue), input monitoring \(listening)")
    }

    static var keyMonitoringAllowed: Bool { CGPreflightListenEventAccess() }

    func keyChanged() {
        monitor?.key = settings.dictationKey
        model.keyLabel = settings.dictationKey.short
    }

    // MARK: Key handling

    private func pressed() {
        Log.info("dictation: key down (phase \(model.phase), holding \(holding))")
        if model.phase == .locked { finish(); return }
        guard model.phase == .idle, !holding else { return }
        let doubleTap = Date().timeIntervalSince(lastTapAt) < 0.4
        holding = true
        pressedAt = Date()
        guard begin() else { holding = false; return }
        if doubleTap {
            model.phase = .locked
            hud.show()
        } else {
            // Only show the HUD once it's clearly a hold, not a tap.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.holding, self.model.phase == .idle else { return }
                self.model.phase = .listening
                self.hud.show()
            }
            revealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func released() {
        Log.info("dictation: key up after \(Int(Date().timeIntervalSince(pressedAt) * 1000)) ms")
        guard holding else { return }
        holding = false
        revealWork?.cancel()
        switch model.phase {
        case .idle:
            // A tap: discard, and remember it in case a second tap locks hands-free mode.
            stopRecording()
            lastTapAt = Date()
        case .listening:
            finish()
        default:
            break  // releasing the second tap of a double-tap; keep listening
        }
    }

    private func combo() {
        guard holding, model.phase == .idle || model.phase == .listening else { return }
        holding = false
        cancel(silently: true)
    }

    // MARK: Recording

    private func begin() -> Bool {
        Log.info("dictation: microphone permission \(Recorder.permission.rawValue)")
        switch Recorder.permission {
        case .authorized:
            break
        case .notDetermined:
            Recorder.requestPermission { ok in
                if ok { Toast.show("Microphone allowed. Hold \(self.settings.dictationKey.short) and talk.") }
            }
            return false
        default:
            Toast.show("Allow Lex to use the microphone in System Settings › Privacy & Security › Microphone.")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return false
        }
        run = UUID()
        pieces = []
        sentUpTo = 0
        if #available(macOS 26.0, *) {
            engineNow = settings.dictationEngine.resolved(keyboardLanguage: Self.keyboardLanguage(), appleAvailable: true)
        } else {
            engineNow = settings.dictationEngine.resolved(keyboardLanguage: Self.keyboardLanguage(), appleAvailable: false)
        }
        Log.info("dictation: listening with \(engineNow.rawValue) (keyboard \(Self.keyboardLanguage() ?? "?"))")
        model.levels = Array(repeating: 0, count: model.levels.count)
        do {
            try recorder.start()
        } catch {
            Toast.show("Couldn't start the microphone: \(error.localizedDescription)")
            return false
        }
        // Long dictation: send finished pieces to Google while you're still talking.
        if engineNow == .google {
            segmentTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.sendFinishedPiece() }
        }
        return true
    }

    private func stopRecording() {
        segmentTimer?.invalidate()
        segmentTimer = nil
        recorder.stop()
    }

    private func sendFinishedPiece() {
        let pending = recorder.samples(from: sentUpTo)
        guard let cut = segmenter.cut(pending[...]) else { return }
        let piece = Array(pending[..<cut])
        sentUpTo += cut
        pieces.append(transcribeTask(piece))
        Log.info("dictation: sent a \(String(format: "%.1f", Double(piece.count) / 16000)) s piece early")
    }

    private func transcribeTask(_ samples: [Int16]) -> Task<String, Error> {
        let audio = PCM16(samples: samples)
        let languages = settings.dictationLanguages.googleCodes
        let phrases = settings.dictationWordList
        let speech = self.speech
        let settings = self.settings
        return Task {
            let text = try await speech.transcribe(audio, languages: languages, phrases: phrases)
            await MainActor.run { settings.addDictationSeconds(audio.seconds) }
            return text
        }
    }

    // MARK: Finishing

    private func finish() {
        let id = run
        stopRecording()
        let all = recorder.samples(from: 0)
        guard !PauseSegmenter.isSilent(all) else {
            Log.info("dictation: nothing heard")
            reset()
            return
        }
        model.phase = .transcribing
        hud.show()
        let started = Date()
        let engine = engineNow
        let tail = Array(all[min(sentUpTo, all.count)...])
        let parts = engine == .google ? pieces + (tail.isEmpty ? [] : [transcribeTask(tail)]) : []
        let polish = settings.dictationPolish && settings.hasAPIKey
        let words = settings.dictationWordList
        let cleanupModel = settings.liveModel ?? .haiku
        let claude = self.claude
        let audioSeconds = Double(all.count) / 16000

        tracker.selection { [weak self] selection in
            guard let self, self.run == id else { return }
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            var before = ""
            if case .caret(let value, let range) = selection {
                before = (value as NSString).substring(to: min(range.location, (value as NSString).length))
            }
            Task {
                do {
                    let raw: String
                    if engine == .apple {
                        raw = try await AppleTranscription.transcribe(PCM16(samples: all))
                    } else {
                        var texts: [String] = []
                        for part in parts { texts.append(try await part.value) }
                        raw = DictationText.join(texts)
                    }
                    let heard = Date().timeIntervalSince(started)
                    guard !raw.isEmpty else {
                        await MainActor.run {
                            guard self.run == id else { return }
                            Toast.show("Didn't catch that. Try again a little closer to the mic.")
                            self.reset()
                        }
                        return
                    }
                    var final = raw
                    let tidy = polish && DictationText.needsTidy(raw)
                    if tidy {
                        await MainActor.run { if self.run == id { self.model.phase = .polishing } }
                        let cleaned = try? await claude.cleanDictation(raw, app: app, before: before, words: words, model: cleanupModel)
                        final = DictationText.choose(cleaned: cleaned, raw: raw)
                    }
                    let total = Date().timeIntervalSince(started)
                    await MainActor.run {
                        guard self.run == id else { return }
                        Log.info("dictation: \(String(format: "%.1f", audioSeconds)) s of audio via \(engine.rawValue), transcript after \(Int(heard * 1000)) ms, typed after \(Int(total * 1000)) ms (\(parts.count) pieces, tidied \(tidy))")
                        self.insert(final, before: before)
                    }
                } catch {
                    await MainActor.run {
                        guard self.run == id else { return }
                        Log.info("dictation failed: \(error.localizedDescription)")
                        Toast.show(error.localizedDescription)
                        self.reset()
                    }
                }
            }
        }
    }

    /// The current keyboard layout's language ("en", "he"), the hint Auto uses.
    static func keyboardLanguage() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
        return languages?.first
    }

    private func insert(_ text: String, before: String) {
        let typed = DictationText.spaced(text, after: before.last)
        lastDictation = typed
        reset()
        _ = Paster.paste(typed)
    }

    func cancel(silently: Bool) {
        let wasActive = model.phase != .idle
        stopRecording()
        reset()
        if wasActive, !silently { Toast.show("Dictation cancelled") }
    }

    private func reset() {
        run = UUID()
        revealWork?.cancel()
        pieces.forEach { $0.cancel() }
        pieces = []
        model.phase = .idle
        hud.hide()
    }
}

// MARK: HUD

struct DictationHUDView: View {
    @ObservedObject var model: DictationModel
    let onCancel: () -> Void
    private let green = Color(red: 0.16, green: 0.62, blue: 0.40)

    var body: some View {
        HStack(spacing: 10) {
            if model.phase == .listening || model.phase == .locked {
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                        Capsule().fill(green).frame(width: 3, height: 4 + CGFloat(level) * 20)
                    }
                }
                .frame(height: 24)
                .animation(.easeOut(duration: 0.08), value: model.levels)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Cancel (esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize()
        .panelBackground(radius: 20)
    }

    private var label: String {
        switch model.phase {
        case .listening: return "Listening"
        case .locked: return "Listening. Tap \(model.keyLabel) to finish"
        case .transcribing: return "Transcribing…"
        case .polishing: return "Tidying up…"
        case .idle: return ""
        }
    }
}

final class DictationHUD {
    private let panel = FloatingPanel(level: .statusBar)
    private let hosting: FirstMouseHostingView<DictationHUDView>
    private var sizeObserver: Any?

    init(model: DictationModel, onCancel: @escaping () -> Void) {
        hosting = FirstMouseHostingView(rootView: DictationHUDView(model: model, onCancel: onCancel))
        panel.contentView = hosting
    }

    func show() {
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        // Wide enough for the longest label so it doesn't jump as the phase changes.
        let width = max(size.width, 300)
        panel.setFrame(CGRect(x: screen.midX - width / 2, y: screen.minY + 40, width: width, height: size.height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// MARK: Test support

enum PCMDecoder {
    /// Decodes compressed audio (e.g. MP3) into 16 kHz mono 16-bit samples.
    static func decode(_ data: Data) throws -> PCM16 {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lex-\(UUID().uuidString).mp3")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw SpeechError.badResponse }
        try file.read(into: input)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCM16.sampleRate), channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: input.format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / input.format.sampleRate + 64)) else {
            throw SpeechError.badResponse
        }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return PCM16(samples: Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength))))
    }
}

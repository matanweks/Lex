import AVFoundation
import LexCore
import Speech
import SwiftUI

// MARK: Microphone

/// Captures the microphone as 16 kHz mono 16-bit audio, with a live level for the meter.
final class Recorder {
    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCM16.sampleRate), channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var buffer: [Int16] = []
    var onLevel: ((Float) -> Void)?
    /// Each converted chunk, on the audio thread (for live transcription).
    var onChunk: (([Int16]) -> Void)?

    func start() throws {
        lock.lock(); buffer = []; lock.unlock()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var samples: [Int16] { lock.lock(); defer { lock.unlock() }; return buffer }

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
        onChunk?(chunk)
        var sum: Float = 0
        for s in chunk { let f = Float(s) / 32768; sum += f * f }
        let level = (sum / Float(chunk.count)).squareRoot()
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }
}

// MARK: Apple on-device speech

/// Apple's on-device speech recognition, fed while you talk so the words show up as you say
/// them. English uses the newer SpeechTranscriber; Hebrew uses DictationTranscriber, the
/// same recognizer as the keyboard's mic. Free and private.
final class LiveTranscriber {
    private let (chunks, feeder) = AsyncStream<[Int16]>.makeStream()
    private var task: Task<String, Error>?
    /// The words so far (settled plus still-changing), on the main thread.
    var onText: ((String) -> Void)?

    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self { case .unsupported(let language): return "\(language) dictation isn't available on this iPhone." }
        }
    }

    func start(language: String) {
        let chunks = self.chunks
        task = Task { [weak self] in
            let module = try await Self.module(for: language)
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await install.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [module])
            let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCM16.sampleRate), channels: 1, interleaved: true)!
            let wanted = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) ?? source
            let converter = wanted == source ? nil : AVAudioConverter(from: source, to: wanted)
            let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let collector = Task { () -> String in
                var settled = ""
                func heard(_ text: String, final: Bool) async {
                    if final { settled += text }
                    let shown = (final ? settled : settled + text).trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run { self?.onText?(shown) }
                }
                if let english = module as? SpeechTranscriber {
                    for try await result in english.results { await heard(String(result.text.characters), final: result.isFinal) }
                } else if let dictation = module as? DictationTranscriber {
                    for try await result in dictation.results { await heard(String(result.text.characters), final: result.isFinal) }
                }
                return settled
            }
            try await analyzer.start(inputSequence: input)
            for await chunk in chunks {
                guard let buffer = Self.buffer(chunk, format: source) else { continue }
                if let converter {
                    guard let converted = Self.convert(buffer, with: converter, to: wanted) else { continue }
                    continuation.yield(AnalyzerInput(buffer: converted))
                } else {
                    continuation.yield(AnalyzerInput(buffer: buffer))
                }
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Called from the audio thread.
    func feed(_ chunk: [Int16]) { feeder.yield(chunk) }

    /// Stops feeding and returns the final text.
    func finish() async throws -> String {
        feeder.finish()
        guard let task else { return "" }
        return try await task.value
    }

    func cancel() {
        feeder.finish()
        task?.cancel()
    }

    private static func module(for language: String) async throws -> any SpeechModule {
        if language == "he" {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "he-IL")) else {
                throw Failure.unsupported("Hebrew")
            }
            return DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        }
        let english = Locale(identifier: "en-US")
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: english) {
            return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: english) else { throw Failure.unsupported("English") }
        return DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    }

    private static func buffer(_ samples: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in pcm.int16ChannelData![0].update(from: src.baseAddress!, count: src.count) }
        return pcm
    }

    /// Streaming conversion: the converter keeps its state between chunks.
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

// MARK: The flow

/// Tap to talk, tap to stop: the words show while you speak, then Claude tidies them (fillers,
/// self-corrections, punctuation) like on the Mac, and they go in where your cursor is.
@MainActor
final class DictationModel: ObservableObject {
    enum Phase { case idle, starting, listening, transcribing, polishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveText = ""
    @Published private(set) var level: Float = 0
    @Published var problem: String?

    private let recorder = Recorder()
    private var session: LiveTranscriber?

    var isBusy: Bool { phase != .idle }

    func start(language: String) async {
        guard phase == .idle else { return }
        problem = nil
        liveText = ""
        phase = .starting
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Lex needs the microphone to dictate. Allow it in Settings › Apps › Lex."
            phase = .idle
            return
        }
        let live = LiveTranscriber()
        live.onText = { [weak self] text in self?.liveText = text }
        live.start(language: language)
        session = live
        recorder.onChunk = { [weak live] chunk in live?.feed(chunk) }
        recorder.onLevel = { [weak self] level in self?.level = level }
        do {
            try recorder.start()
            phase = .listening
        } catch {
            live.cancel()
            session = nil
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            phase = .idle
        }
    }

    /// Stops listening and returns the text to type, or nil when nothing was said.
    func stop(before: String) async -> String? {
        guard phase == .listening else { return nil }
        recorder.stop()
        recorder.onChunk = nil
        let audio = recorder.samples
        guard !PauseSegmenter.isSilent(audio) else {
            session?.cancel()
            session = nil
            phase = .idle
            return nil
        }
        return await complete(before: before)
    }

    func cancel() {
        if phase == .listening { recorder.stop() }
        recorder.onChunk = nil
        session?.cancel()
        session = nil
        phase = .idle
    }

    private func complete(before: String) async -> String? {
        phase = .transcribing
        let raw: String
        do {
            raw = try await session?.finish() ?? ""
        } catch {
            // The first dictation in a language downloads Apple's speech model.
            problem = "Speech recognition didn't work (\(error.localizedDescription)). The first time, iPhone downloads its speech model: try again in a minute, online."
            session = nil
            phase = .idle
            return nil
        }
        session = nil
        guard !raw.isEmpty else {
            problem = "Didn't catch that. Try again a little closer to the mic."
            phase = .idle
            return nil
        }
        let prefs = Prefs.current
        // Saying a snippet's name types the snippet.
        if let snippet = Snippets.spokenMatch(raw, in: prefs.snippets) {
            phase = .idle
            return snippet.text
        }
        var final = raw
        let translateTo = prefs.dictationTranslateHebrew && SpeechText.language(of: raw) == "he" ? "English" : nil
        if LexEngine.claude.hasKey, translateTo != nil || (prefs.dictationPolish && DictationText.needsTidy(raw)) {
            phase = .polishing
            let cleaned = try? await LexEngine.claude.cleanDictation(raw, app: "Notes", before: before, words: prefs.dictationWords,
                                                                    model: prefs.quickModel, style: prefs.style, voice: prefs.voice,
                                                                    translateTo: translateTo)
            final = DictationText.choose(cleaned: cleaned, raw: raw, translated: translateTo != nil)
        }
        phase = .idle
        return final
    }

    #if DEBUG
    /// Test support: dictates an audio file as if it were spoken, at real-time speed.
    func dictate(file: URL, language: String, before: String) async -> String? {
        guard phase == .idle, let audio = try? AVAudioFile(forReading: file) else { problem = "Can't read \(file.lastPathComponent)"; return nil }
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCM16.sampleRate), channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: audio.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: input)) != nil,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(audio.length) * target.sampleRate / audio.processingFormat.sampleRate + 64))
        else { problem = "Can't decode \(file.lastPathComponent)"; return nil }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        let samples = Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
        liveText = ""
        let live = LiveTranscriber()
        live.onText = { [weak self] text in self?.liveText = text }
        live.start(language: language)
        session = live
        phase = .listening
        var i = 0
        while i < samples.count {
            let chunk = Array(samples[i..<min(i + 1600, samples.count)])
            live.feed(chunk)
            i += 1600
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await complete(before: before)
    }
    #endif
}

/// The bar over the keyboard while you dictate: what's heard so far, and Stop.
struct DictationBar: View {
    @ObservedObject var model: DictationModel
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Brand.orange)
                .frame(width: 12, height: 12)
                .scaleEffect(1 + CGFloat(min(model.level * 6, 0.8)))
                .animation(.easeOut(duration: 0.1), value: model.level)
            Text(status)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("dictation-text")
            if model.phase == .listening {
                Button("Cancel", action: onCancel).buttonStyle(.bordered)
                Button("Done", action: onStop).buttonStyle(.borderedProminent).accessibilityIdentifier("dictation-done")
            } else {
                ProgressView()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }

    private var status: String {
        switch model.phase {
        case .starting: return "Getting ready…"
        case .listening: return model.liveText.isEmpty ? "Listening…" : model.liveText
        case .transcribing: return model.liveText.isEmpty ? "Writing it down…" : model.liveText
        case .polishing: return "Tidying up…"
        case .idle: return ""
        }
    }
}

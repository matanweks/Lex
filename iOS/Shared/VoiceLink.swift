import Foundation
import os

/// Steps and timings only, never what was said.
let voiceLog = Logger(subsystem: "dev.lex.ios", category: "voice")

/// How the Lex keyboard dictates. iOS doesn't give keyboards the microphone, so the app
/// listens for it: the keyboard asks with a Darwin notification, the app records and
/// transcribes (in the background, once started), and the words come back through Keychain
/// items both can read. Neither needs the app group, so this works with any signing team.
enum VoiceLink {
    struct State: Codable, Equatable {
        enum Phase: String, Codable { case ready, listening, finishing, done, failed }
        var phase: Phase
        /// The words so far while listening; the text to type when done.
        var text = ""
        var error: String?
        /// The request this answers.
        var request: UUID?
        /// The app keeps the mic ready until then; after that the keyboard opens the app again.
        var readyUntil: Date
    }

    struct Request: Codable, Equatable {
        var id = UUID()
        var language: String
        /// The text before the cursor, so the tidy-up continues it naturally.
        var before: String
    }

    enum Signal: String, CaseIterable {
        case start = "dev.lex.voice.start"
        case stop = "dev.lex.voice.stop"
        case cancel = "dev.lex.voice.cancel"
        case changed = "dev.lex.voice.changed"
    }

    static let listenURL = URL(string: "lex://listen")!

    // MARK: Shared state

    static var state: State? {
        get { Keychain.readData("voice-state").flatMap { try? JSONDecoder().decode(State.self, from: $0) } }
        set { Keychain.writeData(newValue.flatMap { try? JSONEncoder().encode($0) }, "voice-state") }
    }

    static var request: Request? {
        get { Keychain.readData("voice-request").flatMap { try? JSONDecoder().decode(Request.self, from: $0) } }
        set { Keychain.writeData(newValue.flatMap { try? JSONEncoder().encode($0) }, "voice-request") }
    }

    /// The app is holding the mic and will answer a start signal right away.
    static var appIsReady: Bool {
        guard let state else { return false }
        return state.readyUntil > Date() && state.phase != .listening && state.phase != .finishing
    }

    // MARK: Signals

    static func post(_ signal: Signal) {
        voiceLog.info("post \(signal.rawValue, privacy: .public)")
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(signal.rawValue as CFString), nil, nil, true)
    }

    /// Calls `handler` on the main thread for each signal it's given, until it's released.
    final class Listener {
        private let handler: (Signal) -> Void

        init(_ signals: [Signal], handler: @escaping (Signal) -> Void) {
            self.handler = handler
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let me = Unmanaged.passUnretained(self).toOpaque()
            for signal in signals {
                CFNotificationCenterAddObserver(center, me, { _, observer, name, _, _ in
                    guard let observer, let raw = name?.rawValue as String?, let signal = Signal(rawValue: raw) else { return }
                    let listener = Unmanaged<Listener>.fromOpaque(observer).takeUnretainedValue()
                    DispatchQueue.main.async { listener.handler(signal) }
                }, signal.rawValue as CFString, nil, .deliverImmediately)
            }
        }

        deinit {
            CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        }
    }
}

import ActivityKit
import AppIntents
import Foundation

/// The Live Activity while the Lex keyboard's mic is on, in the Dynamic Island and on the Lock
/// Screen, with a button that turns the mic off without opening Lex. Built into the app (which
/// starts it) and the widget extension (which draws it).
struct MicActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Hearing a dictation now; otherwise the mic is ready, keeping nothing.
        var listening: Bool
        /// When the mic goes off by itself.
        var until: Date
    }
}

/// The Live Activity's Stop button. iOS runs it in the app, which turns the mic off; a
/// dictation under way is written down with what was heard.
struct StopMicIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Off the Keyboard's Mic"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        // The app's VoiceSession listens for this (VoiceLink's micOff signal).
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("dev.lex.voice.micoff" as CFString), nil, nil, true)
        // Gone at once, even if Lex wasn't running to hear it.
        for activity in Activity<MicActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

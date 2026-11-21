import AVFoundation
import AppIntents
import LexCore
import UIKit

/// Lex in Shortcuts, Siri and Spotlight, and on the Action button: run an action on any text,
/// or on the clipboard and put the result back.
enum LexActionChoice: String, AppEnum {
    case fix, improve, shorter, clearer, friendlier, formal, direct, tone, translate, summary, keyPoints, reply

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Lex Action"
    static let caseDisplayRepresentations: [LexActionChoice: DisplayRepresentation] = [
        .fix: "Fix Mistakes", .improve: "Improve", .shorter: "Make Shorter", .clearer: "Make Clearer",
        .friendlier: "Make Friendlier", .formal: "Make Formal", .direct: "Make Direct", .tone: "Better Tone",
        .translate: "Translate (Hebrew ↔ English)", .summary: "Summarize", .keyPoints: "Key Points", .reply: "Draft a Reply",
    ]

    func action(for text: String) -> LexAction {
        switch self {
        case .fix: return .fix
        case .improve: return .improve
        case .shorter: return .shorter
        case .clearer: return .clearer
        case .friendlier: return .friendlier
        case .formal: return .formal
        case .direct: return .direct
        case .tone: return .tone
        case .translate: return .translate(text)
        case .summary: return .summary
        case .keyPoints: return .keyPoints
        case .reply: return .reply
        }
    }
}

enum LexIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noText
    case locked, noMicPermission, noLiveActivities, micFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noText: return "There's no text on the clipboard."
        case .locked: return "Unlock your iPhone first: Lex keeps the mic off while it's locked."
        case .noMicPermission: return "Open Lex and dictate once from its keyboard, to allow the microphone."
        case .noLiveActivities: return "Allow Live Activities for Lex in Settings › Apps › Lex: iOS keeps the mic on in the background only while one shows."
        case .micFailed(let why): return "\(why)"
        }
    }
}

/// For the Action Button (or Shortcuts, Back Tap, Siri): turns the Lex keyboard's mic on, so
/// dictations start right in the keyboard without the trip to Lex, even the first; or off when
/// it's on. iOS lets an app start the mic from the background only for an audio-recording
/// intent, and keeps it on only while a Live Activity shows.
struct KeyboardMicIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Turn the Keyboard Mic On or Off"
    static let description = IntentDescription("Turns the Lex keyboard's mic on, so dictations start right in the keyboard, or off when it's on. Made for the Action Button.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let voice = VoiceSession.shared
        if voice.isOn {
            voiceLog.info("mic button: turning the mic off")
            voice.stopNow()
            return .result()
        }
        guard UIApplication.shared.isProtectedDataAvailable else {
            voiceLog.info("mic button: locked")
            throw LexIntentError.locked
        }
        guard VoiceSession.simulated || AVAudioApplication.shared.recordPermission == .granted else {
            voiceLog.info("mic button: no mic permission")
            throw LexIntentError.noMicPermission
        }
        // The Live Activity first, then the mic.
        guard MicActivity.show(listening: false, until: Date().addingTimeInterval(max(VoiceSession.readyFor, 60))) else {
            voiceLog.info("mic button: Live Activities are off")
            throw LexIntentError.noLiveActivities
        }
        await voice.begin(listen: false)
        guard voice.isOn else {
            voiceLog.info("mic button: the mic didn't start")
            MicActivity.end()
            throw LexIntentError.micFailed(voice.problem ?? "The mic didn't start.")
        }
        voiceLog.info("mic button: the mic is on")
        return .result()
    }
}

enum LexIntents {
    /// Runs `choice` on `text`, or on the clipboard when `text` is empty, and copies the
    /// result when asked.
    static func run(_ choice: LexActionChoice, text: String?, copy: Bool) async throws -> String {
        var input = text ?? ""
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            input = await MainActor.run { UIPasteboard.general.string } ?? ""
        }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LexIntentError.noText }
        let result = try await LexEngine.run(choice.action(for: input), on: input)
        if copy { await ClipboardLog.copy(result) }
        return result
    }
}

struct RunLexActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Lex Action"
    static let description = IntentDescription("Fixes, rewrites, translates or summarizes text with Claude. Leave Text empty to use the clipboard.")

    @Parameter(title: "Action", default: .fix)
    var action: LexActionChoice

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String?

    @Parameter(title: "Copy the Result", default: true)
    var copyResult: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) on \(\.$text)") {
            \.$copyResult
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await LexIntents.run(action, text: text, copy: copyResult))
    }
}

struct FixClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Fix My Clipboard"
    static let description = IntentDescription("Fixes spelling, grammar and punctuation in the text on the clipboard and copies it back.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await LexIntents.run(.fix, text: nil, copy: true)
        return .result(value: result, dialog: "Fixed and copied.")
    }
}

struct TranslateClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate My Clipboard"
    static let description = IntentDescription("Translates the clipboard between Hebrew and English and copies the translation.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await LexIntents.run(.translate, text: nil, copy: true)
        return .result(value: result, dialog: "Translated and copied.")
    }
}

struct SummarizeClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize My Clipboard"
    static let description = IntentDescription("Summarizes the text on the clipboard in a few sentences.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await LexIntents.run(.summary, text: nil, copy: false)
        return .result(value: result, dialog: "\(result)")
    }
}

struct LexShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FixClipboardIntent(), phrases: ["Fix my clipboard with \(.applicationName)", "\(.applicationName) fix my clipboard"],
                    shortTitle: "Fix My Clipboard", systemImageName: "checkmark.circle")
        AppShortcut(intent: TranslateClipboardIntent(), phrases: ["Translate my clipboard with \(.applicationName)"],
                    shortTitle: "Translate Clipboard", systemImageName: "character.bubble")
        AppShortcut(intent: SummarizeClipboardIntent(), phrases: ["Summarize my clipboard with \(.applicationName)"],
                    shortTitle: "Summarize Clipboard", systemImageName: "text.append")
        AppShortcut(intent: KeyboardMicIntent(), phrases: ["Turn on the \(.applicationName) mic", "Turn off the \(.applicationName) mic"],
                    shortTitle: "Keyboard Mic", systemImageName: "mic")
    }
}

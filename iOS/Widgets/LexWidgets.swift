import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LexWidgets: WidgetBundle {
    var body: some Widget {
        MicLiveActivity()
    }
}

/// The keyboard mic's Live Activity: a mic in the Dynamic Island (orange while listening) with
/// the time until it goes off, and Stop when expanded and on the Lock Screen.
struct MicLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MicActivityAttributes.self) { context in
            HStack(spacing: 12) {
                MicIcon(listening: context.state.listening).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard mic").font(.headline)
                    MicStatus(state: context.state, stale: context.isStale).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StopButton()
            }
            .padding(16)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MicIcon(listening: context.state.listening).font(.title2).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text("Lex keyboard mic").font(.headline)
                        MicStatus(state: context.state, stale: context.isStale).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StopButton().padding(.top, 4)
                }
            } compactLeading: {
                MicIcon(listening: context.state.listening)
            } compactTrailing: {
                if context.state.listening {
                    Image(systemName: "waveform").foregroundStyle(LiveColors.orange)
                } else {
                    Text(timerInterval: Date.now...max(context.state.until, .now), countsDown: true)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                }
            } minimal: {
                MicIcon(listening: context.state.listening)
            }
        }
    }
}

private enum LiveColors {
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let indigo = Color(red: 0.45, green: 0.40, blue: 1.0)
}

private struct MicIcon: View {
    let listening: Bool

    var body: some View {
        Image(systemName: "mic.fill").foregroundStyle(listening ? LiveColors.orange : LiveColors.indigo)
    }
}

/// "Listening", or "Ready · off in 4:12".
private struct MicStatus: View {
    let state: MicActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        if stale {
            Text("Off")
        } else if state.listening {
            Text("Listening")
        } else {
            Text("Ready · off in ") + Text(timerInterval: Date.now...max(state.until, .now), countsDown: true)
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopMicIntent()) {
            Label("Stop", systemImage: "mic.slash.fill").font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }
}

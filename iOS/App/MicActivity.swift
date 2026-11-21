import ActivityKit
import Foundation

/// Shows, updates and ends the keyboard mic's Live Activity (see `MicActivityAttributes`).
/// iOS lets an app start one only while it's in front, which Lex is when the keyboard opens it
/// to turn the mic on; updates and the end work from the background.
@MainActor
enum MicActivity {
    private static var current: Activity<MicActivityAttributes>?

    static func show(listening: Bool, until: Date) {
        let content = ActivityContent(state: MicActivityAttributes.ContentState(listening: listening, until: until),
                                      staleDate: until.addingTimeInterval(5))
        if let current, current.activityState == .active {
            Task { await current.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        current = try? Activity.request(attributes: MicActivityAttributes(), content: content)
    }

    /// The mic is off. Also ends any left from before Lex last quit.
    static func end() {
        current = nil
        for activity in Activity<MicActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

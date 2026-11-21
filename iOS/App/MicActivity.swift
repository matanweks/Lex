import ActivityKit
import Foundation

/// Shows, updates and ends the keyboard mic's Live Activity (see `MicActivityAttributes`).
/// iOS lets an app start one only while it's in front (the keyboard opens Lex to turn the mic
/// on) or from the Action Button's intent; updates and the end work from the background.
@MainActor
enum MicActivity {
    private static var current: Activity<MicActivityAttributes>?

    /// False when it can't show (Live Activities are off for Lex).
    @discardableResult
    static func show(listening: Bool, until: Date) -> Bool {
        let content = ActivityContent(state: MicActivityAttributes.ContentState(listening: listening, until: until),
                                      staleDate: until.addingTimeInterval(5))
        if let current, current.activityState == .active {
            Task { await current.update(content) }
            return true
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        current = try? Activity.request(attributes: MicActivityAttributes(), content: content)
        return current != nil
    }

    /// The mic is off. Also ends any left from before Lex last quit.
    static func end() {
        current = nil
        for activity in Activity<MicActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

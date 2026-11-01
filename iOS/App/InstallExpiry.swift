import SwiftUI
import UserNotifications

/// When this install of Lex stops opening. An app installed with a free Apple developer account
/// is signed for 7 days, and the date is in the provisioning profile inside the app. The Mac
/// renews it (scripts/install-iphone.sh) only while Xcode is signed in and the phone is within
/// reach, so Lex warns ahead of time: notifications 2 days, 1 day and 3 hours before, and a
/// banner in its last 3 days.
enum InstallExpiry {
    /// Nil in the Simulator and for builds without a profile (App Store, TestFlight).
    static let date: Date? = {
        #if DEBUG
        // Test support: -LexFakeExpiryHours 30 pretends the install ends in 30 hours.
        let hours = UserDefaults.standard.double(forKey: "LexFakeExpiryHours")
        if hours != 0 { return Date().addingTimeInterval(hours * 3600) }
        #endif
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // The profile is a signed property list: the plist sits in the middle, as text.
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    /// In its last 3 days: time to renew.
    static var endsSoon: Bool {
        guard let date else { return false }
        return date.timeIntervalSinceNow < 3 * 86400
    }

    /// "today at 10:46", "tomorrow at 10:46", "on Saturday at 10:46".
    static func when(_ date: Date, relative: Bool = true) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if relative, Calendar.current.isDateInToday(date) { return "today at \(time)" }
        if relative, Calendar.current.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        return "on \(date.formatted(.dateTime.weekday(.wide))) at \(time)"
    }

    /// The reminders for this install, replacing the last install's. Asks once for permission
    /// to notify.
    static func scheduleReminders() async {
        guard let date else { return }
        let center = UNUserNotificationCenter.current()
        let reminders: [(id: String, before: TimeInterval)] = [("lex.expiry.2d", 2 * 86400), ("lex.expiry.1d", 86400), ("lex.expiry.3h", 3 * 3600)]
        center.removePendingNotificationRequests(withIdentifiers: reminders.map(\.id))
        guard date.timeIntervalSinceNow > 0, (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for reminder in reminders {
            let fire = date.addingTimeInterval(-reminder.before).timeIntervalSinceNow
            guard fire > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Lex needs renewing"
            // Not "tomorrow": the day it's shown may not be the day it was written.
            content.body = "Lex stops opening \(when(date, relative: false)). Connect your iPhone to your Mac, with Xcode signed in, so it can renew Lex."
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content,
                                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire, repeats: false)))
        }
    }
}

/// The notice over the tab bar in Lex's last days.
struct ExpiryBanner: View {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
            Text("Lex stops opening \(InstallExpiry.when(date)). Connect your iPhone to your Mac to renew it.")
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 14)
        .accessibilityIdentifier("expiry-banner")
    }
}

/// Puts the notice over the tab bar, where it doesn't cover any tab's own buttons (iOS 26.1 and
/// later; before that the notifications and Settings say it).
struct ExpiryAccessory: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: InstallExpiry.endsSoon) {
                if let date = InstallExpiry.date { ExpiryBanner(date: date) }
            }
        } else {
            content
        }
    }
}

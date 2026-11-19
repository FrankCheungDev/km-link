import Foundation
import UserNotifications

/// Best-effort local notifications. Ad-hoc signed apps may be denied by the
/// system; callers must treat delivery as optional.
enum Notifications {
    private static var authorized = false

    static func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            authorized = granted
        }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

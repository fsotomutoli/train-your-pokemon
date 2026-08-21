import AppKit
import UserNotifications

/// Posts notifications as this app rather than through osascript.
///
/// osascript attributes its notifications to Script Editor, which on this
/// machine delivered the sound but never showed a banner. Going through
/// UNUserNotificationCenter means the notification carries this app's name and
/// icon, and macOS asks for permission once instead of silently dropping it.
enum Notifier {
    private static var authorized = false

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                authorized = granted
                if let error {
                    NSLog("[poketrainer] notification auth failed: \(error.localizedDescription)")
                } else {
                    NSLog("[poketrainer] notification auth granted: \(granted)")
                }
            }
    }

    static func post(title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = nil  // the Pokemon's own cry plays instead

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[poketrainer] notification failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Keeps banners in front of the user even while the app is frontmost, and
/// gives UNUserNotificationCenter the delegate it needs to deliver them.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .list])
    }
}

import Foundation
import UserNotifications

/// UNUserNotificationCenter wrapper (§4.5): authorization is requested lazily
/// on the first post; notification clicks route back to the app via a
/// NotificationCenter notification carrying the task id.
public enum NotificationPoster {
    public static let openTaskNotification = NSNotification.Name("workshopOpenTask")

    /// UNUserNotificationCenter requires a signed bundle; in `swift run` dev
    /// builds the center throws, so posting is best-effort there.
    private static var usable: Bool { Bundle.main.bundleIdentifier != nil }

    public static func post(taskID: String, title: String, body: String) {
        guard usable else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Workshop"
        content.subtitle = title
        content.body = body
        content.userInfo = ["task_id": taskID]
        center.add(UNNotificationRequest(
            identifier: taskID + "-" + body,
            content: content, trigger: nil))
    }

    /// Delivers clicks on Workshop notifications; install once at launch.
    public final class Delegate: NSObject, UNUserNotificationCenterDelegate,
                                 @unchecked Sendable {
        public func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            if let taskID = response.notification.request.content
                .userInfo["task_id"] as? String {
                NotificationCenter.default.post(name: openTaskNotification,
                                                object: taskID)
            }
        }

        // Banners also show while the app is frontmost.
        public func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }
    }
}

import UserNotifications

/// Local notification shown when iOS ends the Live Activity (after 8 hours). Tapping it opens the app, and only
/// a foreground app may start a new activity.
enum ResumeNotification {
    private static let identifier = "resume-live-activity"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in DiagnosticsLog.write("notification permission: \(granted)") }
        }
    }

    static func post() {
        let content = UNMutableNotificationContent()
        content.title = "Lyrics stopped"
        content.body = "iOS ends the Lock Screen lyrics after 8 hours. Tap to bring them back."
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        Task { @MainActor in DiagnosticsLog.write("posted resume notification") }
    }

    static func remove() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

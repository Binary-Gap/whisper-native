import AppKit
import UserNotifications
import WhisperNativeCore

/// Posts a macOS notification when a model download the user started
/// finishes while the app isn't frontmost (frontmost, the model row already
/// shows it). Notification permission is requested the first time one is
/// needed; once denied, nothing is posted.
@MainActor
enum DownloadNotifier {
    static func notifyModelDownloaded(_ modelName: String, detail: String? = nil) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(modelName) downloaded"
        if let detail { content.body = detail }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                // Returns the stored answer without prompting after the first time.
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    AppLogger.shared.log(.info, "Download notification skipped: notifications not allowed")
                    return
                }
                try await center.add(request)
            } catch {
                AppLogger.shared.log(.warning, "Download notification failed: \(error)")
            }
        }
    }
}

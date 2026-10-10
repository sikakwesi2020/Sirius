import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler {
    private let center = UNUserNotificationCenter.current()

    func execute(_ call: GeminiLiveClient.ToolCall) async throws -> String {
        switch call.name {
        case "check_notification_permission": return await permissionStatus()
        case "schedule_activity_notifications": return try await schedule(call)
        default: throw NotificationToolError.unsupported
        }
    }

    private func permissionStatus() async -> String {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "Notification permission is available."
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                return granted ? "Notification permission is available." : "Notification permission was declined."
            } catch { return "Notification permission could not be requested: \(error.localizedDescription)" }
        case .denied: return "Notification permission is disabled. Ask the learner to enable it in iOS Settings."
        @unknown default: return "Notification permission status is unavailable."
        }
    }

    private func schedule(_ call: GeminiLiveClient.ToolCall) async throws -> String {
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            throw NotificationToolError.permission
        }
        let activityID = try required("activity_id", call)
        let kind = try required("activity_type", call)
        let title = try required("title", call)
        let starts: [String] = try decode(try required("start_times", call))
        let material = try required("material_id", call)
        let section = try required("section_id", call)
        guard ["quiz", "lesson"].contains(kind) else { throw NotificationToolError.invalidPayload }
        var components = URLComponents()
        components.scheme = "sirius"
        components.host = kind
        components.queryItems = [URLQueryItem(name: "activity_id", value: activityID),
                                 URLQueryItem(name: "material_id", value: material),
                                 URLQueryItem(name: "section_id", value: section)]
        guard let link = components.url else { throw NotificationToolError.invalidPayload }

        center.removePendingNotificationRequests(withIdentifiers: starts.indices.map { "sirius.\(kind).\(activityID).\($0)" })
        var scheduled = 0
        for (index, value) in starts.enumerated() {
            guard let start = Self.iso.date(from: value) else { throw NotificationToolError.invalidDate }
            let fireDate = start.addingTimeInterval(-120)
            guard fireDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = kind == "quiz" ? "Quiz time is almost here" : "Your lesson starts soon"
            content.body = "\(title) begins in 2 minutes. Tap to continue with Sirius."
            content.sound = .default
            content.userInfo = ["deep_link": link.absoluteString, "activity_id": activityID, "activity_type": kind]
            let date = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let request = UNNotificationRequest(identifier: "sirius.\(kind).\(activityID).\(index)",
                                                content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: false))
            try await center.add(request)
            scheduled += 1
        }
        return "Scheduled \(scheduled) two-minute study reminders linked to this exact \(kind)."
    }

    private func required(_ key: String, _ call: GeminiLiveClient.ToolCall) throws -> String {
        guard let value = call.args[key], !value.isEmpty else { throw NotificationToolError.missing(key) }
        return value
    }

    private func decode(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else { throw NotificationToolError.invalidPayload }
        return try JSONDecoder().decode([String].self, from: data)
    }

    private static let iso = ISO8601DateFormatter()
}

private enum NotificationToolError: LocalizedError {
    case unsupported, permission, invalidPayload, invalidDate, missing(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: "That notification tool is not supported."
        case .permission: "Notification permission is not available."
        case .invalidPayload: "The notification request is incomplete."
        case .invalidDate: "A notification time is invalid."
        case .missing(let field): "The notification request is missing \(field)."
        }
    }
}

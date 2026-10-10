import EventKit
import Foundation
import Combine
import CoreData

@MainActor
final class CalendarScheduler: ObservableObject {
    private let store = EKEventStore()
    private var context: NSManagedObjectContext?
    private struct Proposal { let starts: Set<String>; let duration: Int; let createdAt: Date }
    private var proposals: [String: Proposal] = [:]
    private var completedOperations: [String: String] = [:]

    func configure(context: NSManagedObjectContext) { self.context = context }

    func execute(_ call: GeminiLiveClient.ToolCall) async throws -> String {
        switch call.name {
        case "check_calendar_permission":
            return try await checkPermission()
        case "find_study_slots":
            return try await findSlots(call)
        case "schedule_study_plan":
            return try await schedule(call)
        default:
            throw CalendarToolError.unsupported
        }
    }

    private func checkPermission() async throws -> String {
        var status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            _ = try await store.requestFullAccessToEvents()
            status = EKEventStore.authorizationStatus(for: .event)
        }
        switch status {
        case .fullAccess: return "Calendar permission is available. You may now call find_study_slots."
        case .writeOnly: return "Calendar is write-only. Sirius can create reminders but cannot inspect busy times."
        case .denied, .restricted: return "Calendar permission is unavailable. Ask the learner to enable Full Access in iOS Settings."
        case .notDetermined: return "Calendar permission has not been decided."
        @unknown default: return "Calendar permission status is unavailable."
        }
    }

    private func findSlots(_ call: GeminiLiveClient.ToolCall) async throws -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarToolError.permission
        }
        let start = try parseDate(required("not_before", call))
        let deadline = try parseDate(required("deadline", call), endOfDay: true)
        let duration = max(15, min(Int(call.args["duration_minutes"] ?? "30") ?? 30, 240))
        let perDay = max(1, min(Int(call.args["sessions_per_day"] ?? "1") ?? 1, 4))
        guard deadline > start else { throw CalendarToolError.invalidDate }

        let calendar = Calendar.current
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: deadline, calendars: nil))
        let existingStudyEvents: [[String: Any]] = events.compactMap { event in
            guard event.url?.scheme?.lowercased() == "sirius" else { return nil }
            return [
                "title": event.title ?? "Sirius study session",
                "start": Self.iso.string(from: event.startDate),
                "end": Self.iso.string(from: event.endDate),
                "activity_type": event.url?.host ?? "study",
                "deep_link": event.url?.absoluteString ?? ""
            ]
        }
        var slots: [String] = []
        var day = calendar.startOfDay(for: start)
        while day <= deadline && slots.count < 30 {
            let windowStart = max(start, calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day)
            let windowEnd = min(deadline, calendar.date(bySettingHour: 21, minute: 0, second: 0, of: day) ?? day)
            var candidate = windowStart
            var foundToday = 0
            while candidate.addingTimeInterval(TimeInterval(duration * 60)) <= windowEnd && foundToday < perDay {
                let end = candidate.addingTimeInterval(TimeInterval(duration * 60))
                let busy = events.contains { $0.startDate < end && $0.endDate > candidate }
                if !busy {
                    slots.append(Self.iso.string(from: candidate))
                    foundToday += 1
                    candidate = end.addingTimeInterval(30 * 60)
                } else {
                    candidate = candidate.addingTimeInterval(30 * 60)
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? deadline.addingTimeInterval(1)
        }
        let studyDays = Dictionary(grouping: existingStudyEvents) { event in
            String((event["start"] as? String ?? "").prefix(10))
        }.mapValues { $0.count }
        let proposalID = UUID().uuidString
        proposals[proposalID] = Proposal(starts: Set(slots), duration: duration, createdAt: Date())
        let data = try JSONSerialization.data(withJSONObject: [
            "proposal_id": proposalID,
            "duration_minutes": duration,
            "available_start_times": slots,
            "existing_sirius_study_events": existingStudyEvents,
            "existing_study_sessions_by_day": studyDays,
            "instruction": existingStudyEvents.isEmpty
                ? "No existing Sirius study sessions were found in this range."
                : "Tell the learner about existing Sirius sessions on relevant days and ask whether to place the new work on the same day before scheduling."
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func schedule(_ call: GeminiLiveClient.ToolCall) async throws -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .writeOnly else { throw CalendarToolError.permission }
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarToolError.noCalendar }
        let requestedTitle = try required("title", call)
        let proposalID = try required("proposal_id", call)
        let operationID = try required("operation_id", call)
        if let previous = completedOperations[operationID] { return previous }
        guard let proposal = proposals[proposalID], Date().timeIntervalSince(proposal.createdAt) < 15 * 60 else {
            throw CalendarToolError.expiredProposal
        }
        let duration = max(15, min(Int(call.args["duration_minutes"] ?? "30") ?? 30, 240))
        let starts: [String] = try decode(try required("start_times", call))
        let type = try required("activity_type", call)
        let activityID = try required("activity_id", call)
        let saved = try savedActivity(id: activityID, kind: type)
        let title = saved.title.isEmpty ? requestedTitle : saved.title
        let material = saved.materialID
        let section = saved.sectionID
        let subject = saved.subject
        let itemCount = saved.itemCount
        guard ["quiz", "lesson"].contains(type), !starts.isEmpty,
              duration == proposal.duration, Set(starts).isSubset(of: proposal.starts) else {
            throw CalendarToolError.unapprovedTimes
        }
        var components = URLComponents()
        components.scheme = "sirius"
        components.host = type
        components.queryItems = [URLQueryItem(name: "material_id", value: material),
                                 URLQueryItem(name: "section_id", value: section),
                                 URLQueryItem(name: "activity_id", value: activityID)]
        guard let deepLink = components.url else { throw CalendarToolError.invalidDate }

        let parsedStarts = try starts.map { try parseDate($0) }
        for start in parsedStarts {
            let end = start.addingTimeInterval(TimeInterval(duration * 60))
            let conflicts = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .contains { $0.startDate < end && $0.endDate > start }
            guard !conflicts else { throw CalendarToolError.slotNoLongerAvailable }
        }
        for start in parsedStarts {
            let end = start.addingTimeInterval(TimeInterval(duration * 60))
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = title
            event.startDate = start
            event.endDate = end
            event.notes = """
            Sirius study session

            Open this \(type) in Sirius:
            \(deepLink.absoluteString)
            """
            event.url = deepLink
            event.addAlarm(EKAlarm(relativeOffset: -15 * 60))
            try store.save(event, span: .thisEvent, commit: false)
        }
        try store.commit()
        SharedStudyActivityStore.replaceActivity(id: activityID, kind: type, title: title,
                                                 subject: subject, itemCount: itemCount,
                                                 starts: parsedStarts, deepLink: deepLink)
        let result = "Scheduled \(starts.count) approved study sessions. Each event opens this exact \(type)."
        completedOperations[operationID] = result
        proposals.removeValue(forKey: proposalID)
        return result
    }

    private func savedActivity(id: String, kind: String) throws ->
        (title: String, subject: String, materialID: String, sectionID: String, itemCount: Int) {
        guard let context, let uuid = UUID(uuidString: id) else { throw CalendarToolError.activityNotFound }
        if kind == "lesson" {
            let request = SavedLesson.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            request.fetchLimit = 1
            guard let lesson = try context.fetch(request).first else { throw CalendarToolError.activityNotFound }
            return (lesson.title ?? "Lesson", lesson.subjectName ?? "", lesson.materialID ?? "",
                    lesson.sectionID ?? "", (lesson.items as? Set<LessonItem>)?.count ?? 0)
        }
        if kind == "quiz" {
            let request = QuizSet.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            request.fetchLimit = 1
            guard let quiz = try context.fetch(request).first else { throw CalendarToolError.activityNotFound }
            return (quiz.title ?? "Quiz", quiz.subjectName ?? "", quiz.materialID ?? "",
                    quiz.sectionID ?? "", (quiz.questions as? Set<QuizQuestion>)?.count ?? 0)
        }
        throw CalendarToolError.activityNotFound
    }

    private func required(_ key: String, _ call: GeminiLiveClient.ToolCall) throws -> String {
        guard let value = call.args[key], !value.isEmpty else { throw CalendarToolError.missing(key) }
        return value
    }

    private func decode(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8) else { throw CalendarToolError.invalidDate }
        return try JSONDecoder().decode([String].self, from: data)
    }

    private func parseDate(_ value: String, endOfDay: Bool = false) throws -> Date {
        if let date = Self.iso.date(from: value) { return date }
        if let day = Self.day.date(from: value) {
            return endOfDay ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day : day
        }
        throw CalendarToolError.invalidDate
    }

    private static let iso = ISO8601DateFormatter()
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private enum CalendarToolError: LocalizedError {
    case permission, invalidDate, noCalendar, missing(String), unsupported
    case expiredProposal, unapprovedTimes, slotNoLongerAvailable, activityNotFound
    var errorDescription: String? {
        switch self {
        case .permission: "Calendar access is required before checking availability or creating study sessions."
        case .invalidDate: "The calendar dates or start times were invalid."
        case .noCalendar: "No writable calendar is available on this device."
        case .missing(let key): "The calendar request is missing \(key)."
        case .unsupported: "That calendar tool is not supported."
        case .expiredProposal: "That availability proposal expired. Check the calendar again before scheduling."
        case .unapprovedTimes: "Only times from the learner-approved availability proposal may be scheduled."
        case .slotNoLongerAvailable: "One of those times is no longer free. Check availability again."
        case .activityNotFound: "That lesson or quiz is not saved in the Library, so it cannot be scheduled or shown in the widget. Save it first."
        }
    }
}

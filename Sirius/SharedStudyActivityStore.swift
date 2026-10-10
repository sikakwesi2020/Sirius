import Foundation
import CoreData
#if canImport(WidgetKit)
import WidgetKit
#endif

struct SharedStudyActivity: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let title: String
    let subject: String
    let itemCount: Int
    let startsAt: Date
    let deepLink: String
}

enum SharedStudyActivityStore {
    static let appGroup = "group.fobia.readme.Maximus.Sirius"
    private static let storageKey = "scheduled-study-activities-v1"

    static func upcoming(now: Date = Date()) -> [SharedStudyActivity] {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([SharedStudyActivity].self, from: data) else { return [] }
        return values.filter { $0.startsAt >= now.addingTimeInterval(-15 * 60) }.sorted { $0.startsAt < $1.startsAt }
    }

    static func replaceActivity(id: String, kind: String, title: String, subject: String,
                                itemCount: Int, starts: [Date], deepLink: URL) {
        var values = upcoming().filter { !($0.id == id && $0.kind == kind) }
        values += starts.map {
            SharedStudyActivity(id: id, kind: kind, title: title, subject: subject,
                                itemCount: itemCount, startsAt: $0, deepLink: deepLink.absoluteString)
        }
        guard let data = try? JSONEncoder().encode(values.sorted { $0.startsAt < $1.startsAt }) else { return }
        UserDefaults(suiteName: appGroup)?.set(data, forKey: storageKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "SiriusStudyWidget")
        #endif
    }

    @MainActor
    static func reconcile(context: NSManagedObjectContext) {
        let values = upcoming()
        let valid = values.filter { activity in
            guard let uuid = UUID(uuidString: activity.id) else { return false }
            if activity.kind == "lesson" {
                let request = SavedLesson.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                request.fetchLimit = 1
                return ((try? context.count(for: request)) ?? 0) > 0
            }
            if activity.kind == "quiz" {
                let request = QuizSet.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                request.fetchLimit = 1
                return ((try? context.count(for: request)) ?? 0) > 0
            }
            return false
        }
        guard valid != values, let data = try? JSONEncoder().encode(valid) else { return }
        UserDefaults(suiteName: appGroup)?.set(data, forKey: storageKey)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "SiriusStudyWidget")
        #endif
    }
}

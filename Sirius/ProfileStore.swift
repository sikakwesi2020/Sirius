import Combine
import CoreData
import Foundation

struct SubjectSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let lastStudiedAt: Date
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var username: String?
    @Published private(set) var subjects: [SubjectSummary] = []
    @Published var errorMessage: String?

    private var context: NSManagedObjectContext?
    private var learner: LearnerProfile?

    func load(context: NSManagedObjectContext) {
        self.context = context
        do {
            let request = LearnerProfile.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            request.fetchLimit = 1
            learner = try context.fetch(request).first
            username = learner?.username
            reloadSubjects()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createLearner(username rawName: String) {
        guard let context else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let profile = learner ?? LearnerProfile(context: context)
        if profile.id == nil { profile.id = UUID() }
        if profile.createdAt == nil { profile.createdAt = Date() }
        profile.username = name
        do {
            try context.save()
            learner = profile
            username = name
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    func execute(_ call: GeminiLiveClient.ToolCall) throws -> String {
        switch call.name {
        case "list_subjects":
            let values = subjects.map {
                ["subject_id": $0.id.uuidString, "name": $0.name,
                 "last_studied_at": ISO8601DateFormatter().string(from: $0.lastStudiedAt)]
            }
            let data = try JSONSerialization.data(withJSONObject: ["subjects": values])
            return String(decoding: data, as: UTF8.self)
        case "select_subject":
            guard let requested = call.args["subject"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let existing = subjects.first(where: {
                      $0.name.compare(requested, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                  }) else { throw ProfileError.subjectNotFound }
            guard let selected = selectOrCreateSubject(named: existing.name) else { throw ProfileError.subjectNotFound }
            let data = try JSONSerialization.data(withJSONObject: [
                "status": "selected", "subject_id": selected.id.uuidString, "subject": selected.name
            ])
            return String(decoding: data, as: UTF8.self)
        default:
            throw ProfileError.unsupportedTool
        }
    }

    @discardableResult
    func selectOrCreateSubject(named rawName: String) -> SubjectSummary? {
        guard let context, let learner else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let now = Date()

        let existing = subjects.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let object: SubjectProfile
        if let existing, let stored = subjectObject(for: existing.id, context: context) {
            object = stored
        } else {
            object = SubjectProfile(context: context)
            object.id = UUID()
            object.name = name
            object.createdAt = now
            object.learner = learner
        }
        object.lastStudiedAt = now

        do {
            try context.save()
            reloadSubjects()
            guard let id = object.id, let storedName = object.name else { return nil }
            return SubjectSummary(id: id, name: storedName, lastStudiedAt: now)
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func resetEverything() {
        guard let context else { return }
        do {
            let materials = try context.fetch(StudyMaterial.fetchRequest())
            for material in materials {
                if let path = material.localPath, let url = try? StoredFileLocator.resolve(path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let learners = try context.fetch(LearnerProfile.fetchRequest())
            learners.forEach(context.delete)
            let orphanSubjects = try context.fetch(SubjectProfile.fetchRequest())
            orphanSubjects.forEach(context.delete)
            let orphanMaterials = try context.fetch(StudyMaterial.fetchRequest())
            orphanMaterials.forEach(context.delete)
            try context.fetch(QuizSet.fetchRequest()).forEach(context.delete)
            try context.fetch(SavedLesson.fetchRequest()).forEach(context.delete)
            try context.fetch(StudyCheckpoint.fetchRequest()).forEach(context.delete)
            try context.fetch(QuestionAttempt.fetchRequest()).forEach(context.delete)
            try context.fetch(GenerationOperation.fetchRequest()).forEach(context.delete)
            let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
            if let lessonAudio = support?.appendingPathComponent("LessonAudio", isDirectory: true) {
                try? FileManager.default.removeItem(at: lessonAudio)
            }
            try context.save()
            learner = nil
            username = nil
            subjects = []
            errorMessage = nil
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func reloadSubjects() {
        guard let context, let learner else { subjects = []; return }
        let request = SubjectProfile.fetchRequest()
        request.predicate = NSPredicate(format: "learner == %@", learner)
        request.sortDescriptors = [NSSortDescriptor(key: "lastStudiedAt", ascending: false)]
        do {
            subjects = try context.fetch(request).compactMap {
                guard let id = $0.id, let name = $0.name else { return nil }
                return SubjectSummary(id: id, name: name, lastStudiedAt: $0.lastStudiedAt ?? .distantPast)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func subjectObject(for id: UUID, context: NSManagedObjectContext) -> SubjectProfile? {
        let request = SubjectProfile.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }
}

private enum ProfileError: LocalizedError {
    case subjectNotFound, unsupportedTool
    var errorDescription: String? {
        switch self {
        case .subjectNotFound: "That class is not currently saved. Ask whether the learner wants to create it."
        case .unsupportedTool: "That profile tool is not supported."
        }
    }
}

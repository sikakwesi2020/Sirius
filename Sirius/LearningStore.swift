import Combine
import CoreData
import Foundation
import AVFoundation

struct QuizQuestionState: Identifiable, Equatable {
    let id: NSManagedObjectID
    let prompt: String
    let type: String
    let options: [String]
    let difficulty: Int
    let hintContext: String
    let answered: Bool
    let correct: Bool
    let selectedAnswers: Set<String>
    let explanation: String
}

struct QuizState: Identifiable, Equatable {
    let id: NSManagedObjectID
    let title: String
    let subject: String
    let currentIndex: Int
    let score: Int
    let materialID: String
    let sectionID: String
    let questions: [QuizQuestionState]
    var currentQuestion: QuizQuestionState? { questions.indices.contains(currentIndex) ? questions[currentIndex] : nil }
    var isComplete: Bool { currentIndex >= questions.count }
}

struct LessonItemState: Identifiable, Equatable {
    let id: NSManagedObjectID
    let title: String
    let script: String
    let style: String
    let audioURL: URL?
    let completed: Bool
}

struct LessonState: Identifiable, Equatable {
    let id: NSManagedObjectID
    let title: String
    let subject: String
    let progress: Double
    let items: [LessonItemState]
}

@MainActor
final class LearningStore: NSObject, ObservableObject {
    @Published private(set) var activeQuiz: QuizState?
    @Published private(set) var savedLessonCount = 0
    @Published private(set) var activeLesson: LessonState?
    @Published private(set) var isGeneratingLesson = false
    @Published private(set) var lessonGenerationProgress = "Preparing your chapter"
    @Published private(set) var playingLessonItemID: NSManagedObjectID?
    @Published private(set) var lessonPlaybackTime: TimeInterval = 0
    @Published private(set) var lessonPlaybackDuration: TimeInterval = 0
    @Published private(set) var isRemediationRound = false
    @Published var errorMessage: String?

    private var context: NSManagedObjectContext?
    private var activeQuizObject: QuizSet?
    private let elevenLabs = ElevenLabsClient()
    private let elevenLabsKeys = ElevenLabsKeyStore()
    private var activeLessonObject: SavedLesson?
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private let playbackObserver = LessonPlaybackObserver()
    private var firstPassQuestionIDs: Set<NSManagedObjectID> = []
    private var missedQuestionIDs: Set<NSManagedObjectID> = []
    private var hintedQuestionIDs: Set<NSManagedObjectID> = []

    override init() {
        super.init()
        playbackObserver.onFinish = { [weak self] itemID in
            Task { @MainActor in self?.finishPlayback(of: itemID) }
        }
    }

    func configure(context: NSManagedObjectContext) {
        self.context = context
        migrateStoredAudioPaths(context: context)
        // A cold launch always starts with Sirius at home. Saved activities remain in Library.
        activeQuizObject = nil
        activeQuiz = nil
        savedLessonCount = (try? context.count(for: SavedLesson.fetchRequest())) ?? 0
        activeLessonObject = nil
        activeLesson = nil
    }

    func execute(_ call: GeminiLiveClient.ToolCall) async throws -> String {
        switch call.name {
        case "create_quiz":
            let operationID = try required("operation_id", call)
            if let result = generationResult(for: operationID) { return result }
            let result = try createQuiz(from: required("quiz", call))
            try recordGeneration(operationID: operationID, kind: "quiz", result: result)
            return result
        case "list_learning_activities": return try listLearningActivities(subject: call.args["subject"], kind: call.args["kind"])
        case "get_learning_activity": return try getLearningActivity(
            id: required("activity_id", call), kind: required("kind", call)
        )
        case "get_resume_context": return try resumeContext()
        case "open_learning_activity": return try openLearningActivity(
            id: required("activity_id", call), kind: required("kind", call)
        )
        case "save_lesson":
            let operationID = try required("operation_id", call)
            if let result = generationResult(for: operationID) { return result }
            isGeneratingLesson = true
            lessonGenerationProgress = "Preparing your chapter"
            defer { isGeneratingLesson = false }
            let result = try await saveLesson(from: required("lesson", call))
            try recordGeneration(operationID: operationID, kind: "lesson", result: result)
            return result
        default: throw LearningError.unsupportedTool(call.name)
        }
    }

    private func generationResult(for operationID: String) -> String? {
        guard let context else { return nil }
        let request = GenerationOperation.fetchRequest()
        request.predicate = NSPredicate(format: "operationID == %@", operationID)
        request.fetchLimit = 1
        return try? context.fetch(request).first?.resultJSON
    }

    private func recordGeneration(operationID: String, kind: String, result: String) throws {
        guard let context else { throw LearningError.invalidPayload }
        let operation = GenerationOperation(context: context)
        operation.operationID = operationID
        operation.kind = kind
        operation.resultJSON = result
        operation.createdAt = Date()
        try context.save()
    }

    private func listLearningActivities(subject: String?, kind: String?) throws -> String {
        guard let context else { throw LearningError.invalidPayload }
        let lessonRequest = SavedLesson.fetchRequest()
        if let subject, !subject.isEmpty {
            lessonRequest.predicate = NSPredicate(format: "subjectName =[cd] %@", subject)
        }
        lessonRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        lessonRequest.fetchLimit = 12
        let quizRequest = QuizSet.fetchRequest()
        if let subject, !subject.isEmpty {
            quizRequest.predicate = NSPredicate(format: "subjectName =[cd] %@", subject)
        }
        quizRequest.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        quizRequest.fetchLimit = 12
        let lessons: [[String: Any]] = try context.fetch(lessonRequest).map { lesson in
            let items = sortedLessonItems(lesson)
            return activitySummary(
                id: lesson.id, title: lesson.title, subject: lesson.subjectName, kind: "lesson",
                materialID: lesson.materialID, sectionID: lesson.sectionID, createdAt: lesson.createdAt,
                completedAt: lesson.completedAt, current: items.filter(\.completed).count,
                total: items.count, score: nil
            )
        }
        let quizzes: [[String: Any]] = try context.fetch(quizRequest).map { quiz in
            activitySummary(
                id: quiz.id, title: quiz.title, subject: quiz.subjectName, kind: "quiz",
                materialID: quiz.materialID, sectionID: quiz.sectionID, createdAt: quiz.createdAt,
                completedAt: quiz.completedAt, current: Int(quiz.currentIndex),
                total: sortedQuestions(quiz).count, score: Int(quiz.score)
            )
        }
        let filteredLessons = kind == nil || kind == "lesson" ? lessons : []
        let filteredQuizzes = kind == nil || kind == "quiz" ? quizzes : []
        let data = try JSONSerialization.data(withJSONObject: ["activities": filteredLessons + filteredQuizzes])
        return String(decoding: data, as: UTF8.self)
    }

    private func getLearningActivity(id: String, kind: String) throws -> String {
        guard let context, let uuid = UUID(uuidString: id) else { throw LearningError.invalidPayload }
        let value: [String: Any]
        if kind == "quiz" {
            let request = QuizSet.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            request.fetchLimit = 1
            guard let quiz = try context.fetch(request).first else { throw LearningError.activityNotFound }
            let questions = sortedQuestions(quiz)
            let attemptsRequest = QuestionAttempt.fetchRequest()
            attemptsRequest.predicate = NSPredicate(format: "quizID == %@", quiz.id?.uuidString ?? "")
            let attempts = try context.fetch(attemptsRequest)
            value = activitySummary(
                id: quiz.id, title: quiz.title, subject: quiz.subjectName, kind: "quiz",
                materialID: quiz.materialID, sectionID: quiz.sectionID, createdAt: quiz.createdAt,
                completedAt: quiz.completedAt, current: Int(quiz.currentIndex), total: questions.count,
                score: Int(quiz.score)
            ).merging([
                "question_prompts": questions.map { $0.prompt ?? "" },
                "attempt_summary": ["total_attempts": attempts.count,
                                    "incorrect_attempts": attempts.filter { !$0.correct }.count,
                                    "hinted_attempts": attempts.filter(\.hintUsed).count]
            ]) { _, new in new }
        } else if kind == "lesson" {
            let request = SavedLesson.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            request.fetchLimit = 1
            guard let lesson = try context.fetch(request).first else { throw LearningError.activityNotFound }
            let items = sortedLessonItems(lesson)
            value = activitySummary(
                id: lesson.id, title: lesson.title, subject: lesson.subjectName, kind: "lesson",
                materialID: lesson.materialID, sectionID: lesson.sectionID, createdAt: lesson.createdAt,
                completedAt: lesson.completedAt, current: items.filter(\.completed).count,
                total: items.count, score: nil
            ).merging(["items": items.map { ["title": $0.title ?? "", "style": $0.style ?? "", "completed": $0.completed] }]) { _, new in new }
        } else {
            throw LearningError.invalidPayload
        }
        let data = try JSONSerialization.data(withJSONObject: ["activity": value])
        return String(decoding: data, as: UTF8.self)
    }

    private func activitySummary(id: UUID?, title: String?, subject: String?, kind: String,
                                 materialID: String?, sectionID: String?, createdAt: Date?,
                                 completedAt: Date?, current: Int, total: Int, score: Int?) -> [String: Any] {
        var value: [String: Any] = [
            "activity_id": id?.uuidString ?? "", "title": title ?? kind.capitalized,
            "subject": subject ?? "", "kind": kind, "material_id": materialID ?? "",
            "section_id": sectionID ?? "", "completed": completedAt != nil,
            "completed_count": current, "total_count": total,
            "progress_percent": total == 0 ? 0 : Int((Double(current) / Double(total)) * 100),
            "deep_link": "sirius://\(kind)?activity_id=\(id?.uuidString ?? "")&material_id=\(materialID ?? "")&section_id=\(sectionID ?? "")"
        ]
        if let createdAt { value["created_at"] = ISO8601DateFormatter().string(from: createdAt) }
        if let completedAt { value["completed_at"] = ISO8601DateFormatter().string(from: completedAt) }
        if let score { value["score"] = score }
        return value
    }

    private func resumeContext() throws -> String {
        guard let context else { throw LearningError.invalidPayload }
        let request = StudyCheckpoint.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchLimit = 1
        let checkpoint = try context.fetch(request).first
        let activityData = try listLearningActivities(subject: nil, kind: nil)
        let activitiesRoot = activityData.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var result: [String: Any] = [
            "recent_choices": Array((activitiesRoot?["activities"] as? [[String: Any]] ?? []).prefix(6)),
            "instruction": "Offer the previous checkpoint and a few named choices. Ask what the learner wants; never open or choose one automatically."
        ]
        if let checkpoint {
            result["previous_session"] = [
                "subject": checkpoint.subjectName ?? "", "activity_id": checkpoint.activityID ?? "",
                "activity_type": checkpoint.activityType ?? "", "material_id": checkpoint.materialID ?? "",
                "section_id": checkpoint.sectionID ?? "", "item_id": checkpoint.itemID ?? "",
                "playback_position_seconds": checkpoint.playbackPosition,
                "summary": checkpoint.summary ?? "", "next_action": checkpoint.nextAction ?? "",
                "updated_at": Self.iso.string(from: checkpoint.updatedAt ?? .distantPast)
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return String(decoding: data, as: UTF8.self)
    }

    private func openLearningActivity(id: String, kind: String) throws -> String {
        guard let context, let uuid = UUID(uuidString: id) else { throw LearningError.activityNotFound }
        if kind == "quiz" {
            let request = QuizSet.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            request.fetchLimit = 1
            guard let quiz = try context.fetch(request).first else { throw LearningError.activityNotFound }
            openQuiz(quiz.objectID)
            return "Opened quiz ‘\(quiz.title ?? "Quiz")’ at its saved progress. End the general voice setup so the student can continue."
        }
        if kind == "lesson" {
            let request = SavedLesson.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            request.fetchLimit = 1
            guard let lesson = try context.fetch(request).first else { throw LearningError.activityNotFound }
            openLesson(lesson.objectID)
            return "Opened lesson ‘\(lesson.title ?? "Lesson")’ at its saved progress. End the general voice setup; the student can wake Sirius inside the lesson."
        }
        throw LearningError.invalidPayload
    }

    private func recordAttempt(question: QuizQuestion, quiz: QuizSet, answers: Set<String>, correct: Bool) {
        guard let context, let questionID = question.id?.uuidString, let quizID = quiz.id?.uuidString else { return }
        let request = QuestionAttempt.fetchRequest()
        request.predicate = NSPredicate(format: "questionID == %@", questionID)
        let attempt = QuestionAttempt(context: context)
        attempt.id = UUID()
        attempt.createdAt = Date()
        attempt.quizID = quizID
        attempt.questionID = questionID
        attempt.selectedAnswersJSON = encodeStrings(Array(answers).sorted())
        attempt.correct = correct
        attempt.hintUsed = hintedQuestionIDs.remove(question.objectID) != nil
        attempt.attemptNumber = Int32(((try? context.count(for: request)) ?? 0) + 1)
    }

    private func saveCheckpoint(for quiz: QuizSet, summary: String, nextAction: String) {
        saveCheckpoint(subject: quiz.subjectName, activityID: quiz.id?.uuidString, type: "quiz",
                       materialID: quiz.materialID, sectionID: quiz.sectionID, itemID: nil,
                       playback: 0, summary: summary, nextAction: nextAction)
    }

    private func saveCheckpoint(for lesson: SavedLesson, summary: String, nextAction: String) {
        var currentItemID: String?
        if let context, let objectID = playbackObserver.itemID,
           let object = try? context.existingObject(with: objectID), let item = object as? LessonItem {
            currentItemID = item.id?.uuidString
        }
        saveCheckpoint(subject: lesson.subjectName, activityID: lesson.id?.uuidString, type: "lesson",
                       materialID: lesson.materialID, sectionID: lesson.sectionID,
                       itemID: currentItemID,
                       playback: lessonPlaybackTime, summary: summary, nextAction: nextAction)
    }

    private func saveLessonCheckpoint() {
        guard let lesson = activeLessonObject else { return }
        saveCheckpoint(for: lesson, summary: "Paused during this lesson.", nextAction: "Offer to continue the saved lesson position or choose another activity.")
    }

    private func resumePosition(for itemObjectID: NSManagedObjectID) -> TimeInterval? {
        guard let context, let object = try? context.existingObject(with: itemObjectID),
              let item = object as? LessonItem, let itemID = item.id?.uuidString else { return nil }
        let request = StudyCheckpoint.fetchRequest()
        request.predicate = NSPredicate(format: "activityType == %@ AND itemID == %@", "lesson", itemID)
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.fetchLimit = 1
        return try? context.fetch(request).first?.playbackPosition
    }

    private func saveCheckpoint(subject: String?, activityID: String?, type: String, materialID: String?,
                                sectionID: String?, itemID: String?, playback: Double,
                                summary: String, nextAction: String) {
        guard let context else { return }
        let request = StudyCheckpoint.fetchRequest()
        request.fetchLimit = 1
        let checkpoint = (try? context.fetch(request).first) ?? StudyCheckpoint(context: context)
        if checkpoint.id == nil { checkpoint.id = UUID() }
        checkpoint.updatedAt = Date()
        checkpoint.subjectName = subject
        checkpoint.activityID = activityID
        checkpoint.activityType = type
        checkpoint.materialID = materialID
        checkpoint.sectionID = sectionID
        checkpoint.itemID = itemID
        checkpoint.playbackPosition = playback
        checkpoint.summary = summary
        checkpoint.nextAction = nextAction
        try? context.save()
    }

    private static let iso = ISO8601DateFormatter()

    @discardableResult
    func answer(_ answers: Set<String>) -> Bool {
        guard let context, let quiz = activeQuizObject,
              let question = sortedQuestions(quiz).dropFirst(Int(quiz.currentIndex)).first else { return false }
        let correct = Set(decodeStrings(question.correctAnswersJSON)) == answers
        question.selectedAnswersJSON = encodeStrings(Array(answers).sorted())
        question.answered = true
        question.correct = correct
        quiz.score += correct ? 1 : 0
        recordAttempt(question: question, quiz: quiz, answers: answers, correct: correct)
        saveCheckpoint(for: quiz, summary: correct ? "Answered the current question correctly." : "Needs another attempt on the current question.",
                       nextAction: correct ? "Continue to the next quiz question." : "Retry this question with a different explanation.")
        try? context.save()
        reloadQuiz()
        return correct
    }

    func advance() {
        guard let context, let quiz = activeQuizObject else { return }
        let questions = sortedQuestions(quiz)
        guard questions.indices.contains(Int(quiz.currentIndex)) else { return }
        let question = questions[Int(quiz.currentIndex)]
        firstPassQuestionIDs.remove(question.objectID)
        if question.correct {
            missedQuestionIDs.remove(question.objectID)
            quiz.currentIndex += 1
        } else {
            missedQuestionIDs.insert(question.objectID)
            question.orderIndex = (questions.map(\.orderIndex).max() ?? 0) + 1
            question.answered = false
            question.correct = false
            question.selectedAnswersJSON = nil
        }
        isRemediationRound = firstPassQuestionIDs.isEmpty && !missedQuestionIDs.isEmpty
        if quiz.currentIndex >= questions.count { quiz.completedAt = Date() }
        saveCheckpoint(for: quiz,
                       summary: quiz.completedAt == nil ? "Advanced to the next quiz question." : "Completed this quiz set.",
                       nextAction: quiz.completedAt == nil ? "Continue from the active question." : "Review the result, retry missed material, or generate a fresh set.")
        try? context.save()
        reloadQuiz()
    }

    func closeQuiz() {
        activeQuizObject = nil
        activeQuiz = nil
    }

    func markHintUsed(for questionID: NSManagedObjectID) { hintedQuestionIDs.insert(questionID) }

    func retryQuiz() {
        guard let context, let quiz = activeQuizObject else { return }
        quiz.currentIndex = 0
        quiz.score = 0
        quiz.completedAt = nil
        for question in sortedQuestions(quiz) {
            question.answered = false
            question.correct = false
            question.selectedAnswersJSON = nil
        }
        prepareQuizAttempt(quiz)
        saveCheckpoint(for: quiz, summary: "Restarted this quiz set.", nextAction: "Continue from question one.")
        try? context.save()
        reloadQuiz()
    }

    func playLessonItem(_ item: LessonItemState) {
        guard let url = item.audioURL else {
            errorMessage = "This narration file is no longer available locally. Regenerate the lesson to restore its audio."
            return
        }
        do {
            if playbackObserver.itemID == item.id, let player = audioPlayer {
                if player.isPlaying {
                    player.pause()
                    playingLessonItemID = nil
                    syncPlaybackClock()
                    stopPlaybackTimer()
                    saveLessonCheckpoint()
                } else {
                    if player.currentTime >= max(player.duration - 0.1, 0) { player.currentTime = 0 }
                    guard player.play() else { throw LearningError.audioPlayback }
                    playingLessonItemID = item.id
                    syncPlaybackClock()
                    startPlaybackTimer()
                }
                return
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            playbackObserver.itemID = item.id
            player.delegate = playbackObserver
            player.prepareToPlay()
            if let stored = resumePosition(for: item.id), stored < player.duration { player.currentTime = stored }
            guard player.play() else { throw LearningError.audioPlayback }
            audioPlayer = player
            playingLessonItemID = item.id
            syncPlaybackClock()
            startPlaybackTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pauseLessonPlayback() {
        audioPlayer?.pause()
        playingLessonItemID = nil
        syncPlaybackClock()
        stopPlaybackTimer()
        saveLessonCheckpoint()
    }

    func saveCurrentProgress() { saveLessonCheckpoint() }

    func seekLesson(by seconds: TimeInterval) {
        seekLesson(to: lessonPlaybackTime + seconds)
    }

    func seekLesson(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = min(max(time, 0), player.duration)
        syncPlaybackClock()
        saveLessonCheckpoint()
    }

    func completeLessonItem(_ item: LessonItemState) {
        guard let context, let lesson = activeLessonObject,
              let stored = try? context.existingObject(with: item.id) as? LessonItem else { return }
        stored.completed = true
        let items = sortedLessonItems(lesson)
        let completed = items.filter(\.completed).count
        lesson.progress = items.isEmpty ? 0 : Double(completed) / Double(items.count)
        if completed == items.count { lesson.completedAt = Date() }
        saveCheckpoint(for: lesson,
                       summary: completed == items.count ? "Completed every segment in this lesson." : "Completed \(stored.title ?? "a lesson segment").",
                       nextAction: completed == items.count ? "Review the lesson, ask grounded questions, or schedule a follow-up." : "Continue with the next lesson segment.")
        try? context.save()
        reloadLesson()
    }

    func closeLesson() {
        saveLessonCheckpoint()
        audioPlayer?.stop()
        stopPlaybackTimer(reset: true)
        playingLessonItemID = nil
        activeLessonObject = nil
        activeLesson = nil
    }

    func openLesson(_ objectID: NSManagedObjectID) {
        guard let context, let lesson = try? context.existingObject(with: objectID) as? SavedLesson else { return }
        activeLessonObject = lesson
        reloadLesson()
        saveCheckpoint(for: lesson, summary: "Opened this saved lesson.", nextAction: "Ask which lesson segment to continue.")
    }

    func openQuiz(_ objectID: NSManagedObjectID) {
        guard let context, let quiz = try? context.existingObject(with: objectID) as? QuizSet else { return }
        activeQuizObject = quiz
        prepareQuizAttempt(quiz)
        reloadQuiz()
        saveCheckpoint(for: quiz, summary: "Opened this saved quiz.", nextAction: quiz.completedAt == nil ? "Continue the quiz." : "Offer retry or a new set.")
    }

    func openDeepLink(_ url: URL) {
        guard url.scheme == "sirius", let context,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        if let activityID = values["activity_id"] {
            _ = try? openLearningActivity(id: activityID, kind: url.host ?? "")
            return
        }
        guard let materialID = values["material_id"], let sectionID = values["section_id"] else { return }
        if url.host == "quiz" {
            let request = QuizSet.fetchRequest()
            request.predicate = NSPredicate(format: "materialID == %@ AND sectionID == %@", materialID, sectionID)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            request.fetchLimit = 1
            if let quiz = try? context.fetch(request).first { openQuiz(quiz.objectID) }
        } else if url.host == "lesson" {
            let request = SavedLesson.fetchRequest()
            request.predicate = NSPredicate(format: "materialID == %@ AND sectionID == %@", materialID, sectionID)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
            request.fetchLimit = 1
            if let lesson = try? context.fetch(request).first { openLesson(lesson.objectID) }
        }
    }

    func deleteLesson(_ objectID: NSManagedObjectID) {
        guard let context, let lesson = try? context.existingObject(with: objectID) as? SavedLesson else { return }
        let audioURLs = sortedLessonItems(lesson).compactMap(\.audioPath).compactMap { try? StoredFileLocator.resolve($0) }
        if activeLessonObject?.objectID == objectID { closeLesson() }
        context.delete(lesson)
        do {
            try context.save()
            savedLessonCount = (try? context.count(for: SavedLesson.fetchRequest())) ?? 0
            removeLessonAudio(at: audioURLs)
        } catch {
            context.rollback()
            errorMessage = "That lesson could not be removed. \(error.localizedDescription)"
        }
    }

    func deleteQuiz(_ objectID: NSManagedObjectID) {
        guard let context, let quiz = try? context.existingObject(with: objectID) as? QuizSet else { return }
        if activeQuizObject?.objectID == objectID { closeQuiz() }
        context.delete(quiz)
        do {
            try context.save()
        } catch {
            context.rollback()
            errorMessage = "That quiz could not be removed. \(error.localizedDescription)"
        }
    }

    func resetState() {
        activeQuizObject = nil
        activeQuiz = nil
        savedLessonCount = 0
        activeLessonObject = nil
        activeLesson = nil
        audioPlayer?.stop()
        stopPlaybackTimer(reset: true)
        playingLessonItemID = nil
        errorMessage = nil
        isGeneratingLesson = false
    }

    private func createQuiz(from json: String) throws -> String {
        guard let context, let data = json.data(using: .utf8) else { throw LearningError.invalidPayload }
        let payload = try JSONDecoder().decode(QuizPayload.self, from: data)
        guard payload.questions.count == 15 else { throw LearningError.questionCount }
        let allowed = Set(["multiple_choice", "yes_no", "checkbox"])
        guard payload.questions.allSatisfy({ allowed.contains($0.type) }) else { throw LearningError.invalidType }
        let difficulties = payload.questions.map(\.difficulty)
        guard difficulties == difficulties.sorted(), difficulties.allSatisfy({ (1...5).contains($0) }) else {
            throw LearningError.difficultyOrder
        }
        guard payload.questions.allSatisfy({ question in
            !question.prompt.isEmpty && !question.options.isEmpty && !question.correctAnswers.isEmpty &&
            Set(question.correctAnswers).isSubset(of: Set(question.options)) &&
            (question.type == "checkbox" || question.correctAnswers.count == 1)
        }) else { throw LearningError.invalidQuestion }

        let quiz = QuizSet(context: context)
        quiz.id = UUID()
        quiz.title = payload.title
        quiz.subjectName = payload.subject
        quiz.materialID = payload.materialID
        quiz.sectionID = payload.sectionID
        quiz.createdAt = Date()
        quiz.currentIndex = 0
        quiz.score = 0

        for (index, value) in payload.questions.enumerated() {
            let question = QuizQuestion(context: context)
            question.id = UUID()
            question.orderIndex = Int32(index)
            question.prompt = value.prompt
            question.type = value.type
            question.optionsJSON = encodeStrings(value.options)
            question.correctAnswersJSON = encodeStrings(value.correctAnswers)
            question.difficulty = Int16(value.difficulty)
            question.hintContext = value.sourceExcerpt
            question.explanation = value.explanation
            question.materialID = payload.materialID
            question.sectionID = payload.sectionID
            question.answered = false
            question.correct = false
            question.quiz = quiz
        }
        try context.save()
        activeQuizObject = quiz
        prepareQuizAttempt(quiz)
        reloadQuiz()
        let result = ["status": "saved", "activity_id": quiz.id?.uuidString ?? "", "kind": "quiz",
                      "title": quiz.title ?? payload.title, "material_id": payload.materialID,
                      "section_id": payload.sectionID, "question_count": payload.questions.count] as [String: Any]
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    }

    private func saveLesson(from json: String) async throws -> String {
        guard let context, let data = json.data(using: .utf8) else { throw LearningError.invalidPayload }
        let payload = try JSONDecoder().decode(LessonPayload.self, from: data)
        let allowedStyles = Set(["overview", "concept_definition", "deep_dive", "formula_lab",
                                 "worked_example", "keyword_review", "recap"])
        guard (6...16).contains(payload.items.count),
              payload.items.allSatisfy({ allowedStyles.contains($0.style) && $0.script.wordCount >= 90 }),
              Set(payload.items.map(\.style)).count >= 3 else { throw LearningError.invalidLesson }
        guard let apiKey = elevenLabsKeys.load(), !apiKey.isEmpty else { throw LearningError.missingElevenLabsKey }
        let lessonID = UUID()
        let audioDirectory = try lessonAudioDirectory(id: lessonID)
        let lesson = SavedLesson(context: context)
        lesson.id = lessonID
        lesson.title = payload.title
        lesson.content = payload.items.map(\.script).joined(separator: "\n\n")
        lesson.subjectName = payload.subject
        lesson.materialID = payload.materialID
        lesson.sectionID = payload.sectionID
        lesson.createdAt = Date()
        lesson.progress = 0
        do {
            for (index, value) in payload.items.enumerated() {
                lessonGenerationProgress = "Narrating \(index + 1) of \(payload.items.count)"
                let itemID = UUID()
                let audio = try await elevenLabs.synthesize(
                    text: value.narrationText,
                    apiKey: apiKey,
                    voiceID: ElevenLabsConfiguration.voiceID
                )
                let audioURL = audioDirectory.appendingPathComponent("\(itemID.uuidString).mp3")
                try audio.write(to: audioURL, options: .atomic)

                let item = LessonItem(context: context)
                item.id = itemID
                item.orderIndex = Int32(index)
                item.title = value.title
                item.script = value.script
                item.style = value.style
                item.audioPath = StoredFileLocator.relativePath(for: audioURL)
                item.completed = false
                item.materialID = payload.materialID
                item.sectionID = payload.sectionID
                item.lesson = lesson
            }
            try context.save()
            savedLessonCount += 1
            activeLessonObject = lesson
            reloadLesson()
            let result = ["status": "saved", "activity_id": lesson.id?.uuidString ?? "", "kind": "lesson",
                          "title": lesson.title ?? payload.title, "material_id": payload.materialID,
                          "section_id": payload.sectionID, "item_count": payload.items.count] as [String: Any]
            return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        } catch {
            context.rollback()
            try? FileManager.default.removeItem(at: audioDirectory)
            throw error
        }
    }

    private func reloadQuiz() {
        guard let quiz = activeQuizObject else { activeQuiz = nil; return }
        let questions = sortedQuestions(quiz).map { question in
            QuizQuestionState(
                id: question.objectID,
                prompt: question.prompt ?? "",
                type: question.type ?? "multiple_choice",
                options: decodeStrings(question.optionsJSON),
                difficulty: Int(question.difficulty),
                hintContext: question.hintContext ?? "",
                answered: question.answered,
                correct: question.correct,
                selectedAnswers: Set(decodeStrings(question.selectedAnswersJSON)),
                explanation: question.explanation ?? ""
            )
        }
        activeQuiz = QuizState(id: quiz.objectID, title: quiz.title ?? "Quiz", subject: quiz.subjectName ?? "",
                               currentIndex: Int(quiz.currentIndex), score: Int(quiz.score),
                               materialID: quiz.materialID ?? "", sectionID: quiz.sectionID ?? "",
                               questions: questions)
    }

    private func reloadLesson() {
        guard let lesson = activeLessonObject else { activeLesson = nil; return }
        activeLesson = LessonState(
            id: lesson.objectID,
            title: lesson.title ?? "Lesson",
            subject: lesson.subjectName ?? "",
            progress: lesson.progress,
            items: sortedLessonItems(lesson).map {
                LessonItemState(id: $0.objectID, title: $0.title ?? "Lesson item", script: $0.script ?? "",
                                style: $0.style ?? "deep_dive",
                                audioURL: $0.audioPath.flatMap { try? StoredFileLocator.resolve($0) }, completed: $0.completed)
            }
        )
    }

    private func sortedLessonItems(_ lesson: SavedLesson) -> [LessonItem] {
        (lesson.items as? Set<LessonItem> ?? []).sorted { $0.orderIndex < $1.orderIndex }
    }

    private func sortedQuestions(_ quiz: QuizSet) -> [QuizQuestion] {
        (quiz.questions as? Set<QuizQuestion> ?? []).sorted { $0.orderIndex < $1.orderIndex }
    }

    private func prepareQuizAttempt(_ quiz: QuizSet) {
        let questions = sortedQuestions(quiz)
        firstPassQuestionIDs = Set(questions.dropFirst(Int(quiz.currentIndex)).map(\.objectID))
        missedQuestionIDs = []
        isRemediationRound = false
    }

    private func required(_ key: String, _ call: GeminiLiveClient.ToolCall) throws -> String {
        guard let value = call.args[key] else { throw LearningError.invalidPayload }
        return value
    }

    private func encodeStrings(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeStrings(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func lessonAudioDirectory(id: UUID) throws -> URL {
        let base = try StoredFileLocator.applicationSupport()
        let directory = base.appendingPathComponent("LessonAudio/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeLessonAudio(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        let directory = urls[0].deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }

    private func migrateStoredAudioPaths(context: NSManagedObjectContext) {
        guard let items = try? context.fetch(LessonItem.fetchRequest()) else { return }
        var changed = false
        for item in items {
            guard let path = item.audioPath, path.hasPrefix("/") else { continue }
            item.audioPath = StoredFileLocator.relativePath(for: URL(fileURLWithPath: path))
            changed = true
        }
        if changed { try? context.save() }
    }

    private func finishPlayback(of itemID: NSManagedObjectID) {
        guard playingLessonItemID == itemID, let lesson = activeLessonObject else { return }
        stopPlaybackTimer()
        lessonPlaybackTime = lessonPlaybackDuration
        let items = sortedLessonItems(lesson)
        guard let index = items.firstIndex(where: { $0.objectID == itemID }) else { return }
        completeLessonItem(LessonItemState(
            id: itemID,
            title: items[index].title ?? "Lesson item",
            script: items[index].script ?? "",
            style: items[index].style ?? "deep_dive",
            audioURL: items[index].audioPath.flatMap { try? StoredFileLocator.resolve($0) },
            completed: items[index].completed
        ))
        guard items.indices.contains(index + 1),
              let next = activeLesson?.items.first(where: { $0.id == items[index + 1].objectID }) else {
            playingLessonItemID = nil
            return
        }
        playLessonItem(next)
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(playbackTimerFired),
            userInfo: nil,
            repeats: true
        )
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlaybackTimer(reset: Bool = false) {
        playbackTimer?.invalidate()
        playbackTimer = nil
        if reset {
            lessonPlaybackTime = 0
            lessonPlaybackDuration = 0
        }
    }

    private func syncPlaybackClock() {
        guard let player = audioPlayer else { return }
        lessonPlaybackTime = player.currentTime.isFinite ? player.currentTime : 0
        lessonPlaybackDuration = player.duration.isFinite ? player.duration : 0
    }

    @objc private func playbackTimerFired() { syncPlaybackClock() }
}

private struct QuizPayload: Decodable {
    let title, subject, materialID, sectionID: String
    let questions: [Question]
    struct Question: Decodable {
        let type, prompt: String
        let options, correctAnswers: [String]
        let difficulty: Int
        let explanation, sourceExcerpt: String
        enum CodingKeys: String, CodingKey {
            case type, prompt, options, difficulty, explanation
            case correctAnswers = "correct_answers"
            case sourceExcerpt = "source_excerpt"
        }
    }
    enum CodingKeys: String, CodingKey {
        case title, subject, questions
        case materialID = "material_id"
        case sectionID = "section_id"
    }
}

private struct LessonPayload: Decodable {
    let title, subject, materialID, sectionID: String
    let items: [Item]
    struct Item: Decodable {
        let title, style, script: String

        var narrationText: String {
            let direction: String
            switch style {
            case "overview": direction = "[warm, inviting, curious]"
            case "concept_definition": direction = "[clear, thoughtful, deliberate]"
            case "formula_lab": direction = "[precise, patient, analytical]"
            case "worked_example": direction = "[engaging, step-by-step, encouraging]"
            case "keyword_review": direction = "[focused, rhythmic, confident]"
            case "recap": direction = "[energetic, reassuring, memorable]"
            default: direction = "[curious, explanatory, conversational]"
            }
            return "\(direction) \(script)"
        }
    }
    enum CodingKeys: String, CodingKey {
        case title, subject, items
        case materialID = "material_id"
        case sectionID = "section_id"
    }
}

enum LearningError: LocalizedError {
    case invalidPayload, questionCount, invalidType, difficultyOrder, invalidQuestion, invalidLesson
    case missingElevenLabsKey, audioPlayback, activityNotFound, unsupportedTool(String)
    var errorDescription: String? {
        switch self {
        case .invalidPayload: "The generated learning activity was malformed."
        case .questionCount: "A comprehensive quiz set must contain exactly 15 questions."
        case .invalidType: "Only multiple-choice, yes/no, and checkbox questions are supported."
        case .difficultyOrder: "Questions must be ordered from easiest to hardest with difficulty 1 through 5."
        case .invalidQuestion: "One or more generated questions has invalid options or answers."
        case .invalidLesson: "A chapter lesson needs 6–16 substantial podcast segments, at least 90 words each, using at least three teaching styles."
        case .missingElevenLabsKey: "Add an ElevenLabs API key in Settings before creating narrated lessons."
        case .audioPlayback: "The saved lesson audio could not be played."
        case .activityNotFound: "That saved learning activity could not be found."
        case .unsupportedTool(let name): "Unsupported learning tool: \(name)."
        }
    }
}

private final class LessonPlaybackObserver: NSObject, AVAudioPlayerDelegate {
    var itemID: NSManagedObjectID?
    var onFinish: ((NSManagedObjectID) -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag, let itemID else { return }
        onFinish?(itemID)
    }
}

private extension String {
    var wordCount: Int { split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
}

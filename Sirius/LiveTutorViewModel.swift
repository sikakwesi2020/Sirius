import AVFoundation
import Combine
import SwiftUI

struct StudyMessage: Identifiable, Equatable {
    enum Role { case student, tutor }
    let id = UUID()
    let role: Role
    var text: String
}

struct AgentToolActivity: Identifiable, Equatable {
    enum Status: Equatable { case running, succeeded, failed }
    let id: UUID
    let toolName: String
    let title: String
    var detail: String
    var status: Status
}

private enum TutorHarnessError: LocalizedError {
    case invalidGenerationContext, incompleteExtraction, subjectMismatch, activityChoiceRequired
    var errorDescription: String? {
        switch self {
        case .invalidGenerationContext: "Generation is missing its verified book and section context."
        case .incompleteExtraction: "Retrieve every PDF chunk for this exact section before generating the activity."
        case .subjectMismatch: "The generated activity does not match the currently selected class."
        case .activityChoiceRequired: "Offer the saved activity choices and wait for the learner to choose one before opening it."
        }
    }
}

struct LessonAssistanceContext: Equatable {
    let lessonTitle: String
    let subject: String
    let segmentTitle: String
    let style: String
    let groundedScript: String
}

struct AgentConfirmation: Identifiable, Equatable {
    enum Kind: Equatable { case learnerName, subject }
    let call: GeminiLiveClient.ToolCall
    let kind: Kind
    var id: String { call.id }
    var heardValue: String { call.proposedValue ?? "" }
}

enum LiveSessionState: Equatable {
    case disconnected, connecting, listening, speaking

    var isActive: Bool { self != .disconnected }
    var canSend: Bool { self == .listening || self == .speaking }
    var title: String {
        switch self {
        case .disconnected: "Ready to study"
        case .connecting: "Connecting…"
        case .listening: "Listening"
        case .speaking: "Sirius is explaining"
        }
    }
    var detail: String {
        switch self {
        case .disconnected: "Start a session to talk with Gemini Live"
        case .connecting: "Opening a secure live session"
        case .listening: "Ask a question or explain what you're learning"
        case .speaking: "You can interrupt at any time"
        }
    }
    var symbol: String {
        switch self {
        case .disconnected: "graduationcap.fill"
        case .connecting: "network"
        case .listening: "waveform"
        case .speaking: "speaker.wave.2.fill"
        }
    }
    var color: Color {
        switch self {
        case .disconnected: .indigo
        case .connecting: .orange
        case .listening: .green
        case .speaking: .purple
        }
    }
}

@MainActor
final class LiveTutorViewModel: ObservableObject {
    private enum SessionMode: Equatable { case standard, quizHint, lessonHelp }
    @Published private(set) var state: LiveSessionState = .disconnected
    @Published private(set) var messages: [StudyMessage] = []
    @Published var showSettings = false
    @Published var showError = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingConfirmation: AgentConfirmation?
    @Published private(set) var pendingMaterialRequest: GeminiLiveClient.ToolCall?
    @Published private(set) var toolActivity: AgentToolActivity?

    private let keyStore = APIKeyStore()
    private let elevenLabsKeyStore = ElevenLabsKeyStore()
    private let client = GeminiLiveClient()
    private var audio: AudioPipeline?
    private var eventTask: Task<Void, Never>?
    private var studentTranscript = ""
    private var tutorTranscript = ""
    private var toolHandler: ((GeminiLiveClient.ToolCall) async throws -> String)?
    private var sessionMode: SessionMode = .standard
    private var sessionSubject: String?
    private var didListSubjects = false
    private var listedMaterialsSubject: String?
    private var extractedChunks: [String: Set<Int>] = [:]
    private var expectedChunks: [String: Int] = [:]
    private var didLoadResumeContext = false
    private var learnerRespondedToResumeOffer = false
    private var toolFailureCounts: [String: Int] = [:]

    var savedAPIKey: String? { keyStore.load() }
    var savedElevenLabsKey: String? { elevenLabsKeyStore.load() }

    func configureToolHandler(_ handler: @escaping (GeminiLiveClient.ToolCall) async throws -> String) {
        toolHandler = handler
    }

    func saveAPIKey(_ key: String) {
        do { try keyStore.save(key) } catch { present(error) }
    }

    func saveElevenLabsKey(_ key: String) {
        do { try elevenLabsKeyStore.save(key) } catch { present(error) }
    }

    func resetCredentials() {
        keyStore.delete()
        elevenLabsKeyStore.delete()
        ElevenLabsConfiguration.reset()
    }

    func start(learnerName: String?, subjectName: String?,
               assistanceQuestion: QuizQuestionState? = nil,
               lessonAssistance: LessonAssistanceContext? = nil) async {
        guard let key = savedAPIKey, !key.isEmpty else { showSettings = true; return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            present(message: "Microphone access is required for a live voice session. You can enable it in Settings.")
            return
        }
        state = .connecting
        sessionMode = assistanceQuestion != nil ? .quizHint
            : lessonAssistance != nil ? .lessonHelp : .standard
        sessionSubject = subjectName
        didListSubjects = false
        listedMaterialsSubject = nil
        extractedChunks = [:]
        expectedChunks = [:]
        didLoadResumeContext = false
        learnerRespondedToResumeOffer = false
        toolFailureCounts = [:]
        toolActivity = nil
        let identity = learnerName.map { "The saved learner name is \($0)." } ?? "No learner name has been saved yet."
        let subject = subjectName.map { "The active study subject is \($0)." } ?? "No study subject has been saved for this session yet."
        var context = "\(identity) \(subject) Begin and remain in English unless the learner explicitly asks to use a named language during this session. Query saved classes and learning activities with tools; they are intentionally not embedded here. Use profile tools only when missing data is genuinely learned."
        if let question = assistanceQuestion {
            context += """

            HINT MODE: The learner is currently answering this question: \(question.prompt)
            Options shown: \(question.options.joined(separator: " | "))
            Learner's current selection, if any: \(question.selectedAnswers.sorted().joined(separator: " | "))
            Grounding excerpt: \(question.hintContext)
            Give incremental hints only. Never state, spell out, or strongly imply the correct answer. Ask a
            guiding question and wait. Continue naturally across multiple turns until the learner disconnects,
            submits, or changes questions. Do not call profile, material, quiz, or lesson tools in hint mode.
            """
        }
        if let lesson = lessonAssistance {
            context += """

            LESSON HELP MODE: The learner paused this exact lesson segment to ask questions.
            Course: \(lesson.subject)
            Lesson: \(lesson.lessonTitle)
            Current segment: \(lesson.segmentTitle)
            Teaching style: \(lesson.style)
            Sole grounding source:
            ---
            \(lesson.groundedScript)
            ---
            Answer only from this supplied lesson segment. You may explain, rephrase, give a new analogy, ask
            checking questions, and work through ideas already present, but never introduce outside facts or
            pretend the source says something it does not. If the answer is not in this segment, say so plainly.
            Keep the conversation open for multiple back-and-forth turns. Do not call any tools in this mode.
            """
        }
        let stream = await client.connect(apiKey: key, sessionContext: context)
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        audio?.stop()
        audio = nil
        pendingConfirmation = nil
        pendingMaterialRequest = nil
        sessionMode = .standard
        sessionSubject = nil
        didListSubjects = false
        listedMaterialsSubject = nil
        extractedChunks = [:]
        expectedChunks = [:]
        didLoadResumeContext = false
        learnerRespondedToResumeOffer = false
        toolFailureCounts = [:]
        toolActivity = nil
        await client.disconnect()
        state = .disconnected
        finalizeTranscripts()
    }

    func send(_ text: String) async {
        guard state.canSend else { return }
        messages.append(StudyMessage(role: .student, text: text))
        do { try await client.sendText(text) } catch { present(error); await stop() }
    }

    private func handle(_ event: GeminiLiveClient.Event) async {
        switch event {
        case .ready:
            do {
                let pipeline = AudioPipeline()
                pipeline.onAudio = { [client] data in Task { try? await client.sendAudio(data) } }
                try pipeline.start()
                audio = pipeline
                state = .listening
                let opening: String
                switch sessionMode {
                case .quizHint:
                    opening = "The learner woke you for help on the current quiz question. Offer one grounded hint without giving the answer."
                case .lessonHelp:
                    opening = "The learner tapped Sirius while studying this segment. Briefly say you are ready, then ask what part they want to understand better."
                case .standard:
                    opening = "Use English. Call list_subjects, list_learning_activities, and get_resume_context before speaking. Briefly offer the previous session and a few named alternatives, then ask what the learner wants. Do not open or choose anything until they answer."
                }
                try? await client.sendText(opening)
            } catch { present(error); await stop() }
        case .inputTranscript(let text):
            studentTranscript += text
            if didLoadResumeContext, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                learnerRespondedToResumeOffer = true
            }
            if state == .speaking {
                audio?.interruptPlayback()
                state = .listening
            }
        case .outputTranscript(let text): tutorTranscript += text
        case .audio(let data):
            state = .speaking
            audio?.play(data)
        case .interrupted:
            audio?.interruptPlayback()
            finalizeTutorTranscript()
            state = .listening
        case .turnComplete:
            finalizeTranscripts()
            state = .listening
        case .toolCall(let call):
            if sessionMode == .lessonHelp || sessionMode == .quizHint {
                try? await client.sendToolResponse(call: call, result: "Tools are disabled during in-activity Q&A. Continue the grounded conversation without changing app data.", status: "error")
                return
            }
            switch call.name {
            case "propose_learner_name", "propose_subject":
                guard pendingConfirmation == nil else { return }
                let kind: AgentConfirmation.Kind = call.name == "propose_learner_name" ? .learnerName : .subject
                guard await validateProfileProposal(call, kind: kind) else { return }
                audio?.setInputEnabled(false)
                pendingConfirmation = AgentConfirmation(call: call, kind: kind)
            case "request_pdf_material":
                guard validateMaterialRequest(call) else { return }
                audio?.setInputEnabled(false)
                pendingMaterialRequest = call
            case "finish_study_setup":
                try? await client.sendToolResponse(call: call, result: "Study setup finished. The app is ready.")
                await stop()
            case "list_subjects", "select_subject", "list_materials", "get_pdf_outline", "extract_pdf_section", "list_learning_activities", "get_learning_activity", "get_resume_context", "open_learning_activity",
                 "check_calendar_permission", "find_study_slots", "schedule_study_plan",
                 "check_notification_permission", "schedule_activity_notifications",
                 "create_quiz", "save_lesson":
                await executeDeterministicTool(call)
            default:
                try? await client.sendToolResponse(call: call, result: "Unsupported tool: \(call.name)", status: "error")
            }
        case .closed(let reason):
            if let reason { present(message: reason) }
            audio?.stop()
            audio = nil
            state = .disconnected
            finalizeTranscripts()
        }
    }

    func completeConfirmation(with savedValue: String) async {
        guard let confirmation = pendingConfirmation else { return }
        do {
            try await client.sendToolResponse(call: confirmation.call, result: savedValue)
            if confirmation.kind == .subject { sessionSubject = savedValue }
            pendingConfirmation = nil
            audio?.setInputEnabled(true)
            state = .listening
        } catch {
            present(error)
            await stop()
        }
    }

    func completeMaterialImport(result: String) async {
        guard let call = pendingMaterialRequest else { return }
        do {
            try await client.sendToolResponse(call: call, result: result)
            pendingMaterialRequest = nil
            audio?.setInputEnabled(true)
            state = .listening
        } catch {
            present(error)
            await stop()
        }
    }

    func failMaterialImport(_ message: String) async {
        guard let call = pendingMaterialRequest else { return }
        try? await client.sendToolResponse(call: call, result: message, status: "error")
        pendingMaterialRequest = nil
        audio?.setInputEnabled(true)
        state = .listening
    }

    private func executeDeterministicTool(_ call: GeminiLiveClient.ToolCall) async {
        let activityID = beginToolActivity(call)
        guard let toolHandler else {
            let result = failureResult(call: call, message: "Local tool harness is unavailable.", retryAllowed: false)
            finishToolActivity(id: activityID, succeeded: false, detail: "Tool harness unavailable")
            try? await client.sendToolResponse(call: call, result: result, status: "error")
            return
        }
        do {
            if call.name == "open_learning_activity", didLoadResumeContext, !learnerRespondedToResumeOffer {
                throw TutorHarnessError.activityChoiceRequired
            }
            if call.name == "create_quiz" || call.name == "save_lesson" {
                try validateCompleteExtraction(for: call)
            }
            let result = try await toolHandler(call)
            let partialFailure = resultIndicatesFailure(result)
            try await client.sendToolResponse(call: call, result: result, status: partialFailure ? "error" : "success")
            finishToolActivity(
                id: activityID,
                succeeded: !partialFailure,
                detail: partialFailure ? "Saved with an incomplete step" : "Completed successfully"
            )
            if partialFailure { return }
            toolFailureCounts[toolSignature(call)] = nil
            if call.name == "list_subjects" { didListSubjects = true }
            if call.name == "select_subject", let selected = call.args["subject"] {
                sessionSubject = selected
                listedMaterialsSubject = nil
                extractedChunks = [:]
                expectedChunks = [:]
            }
            if call.name == "list_materials" { listedMaterialsSubject = call.args["subject"] ?? sessionSubject }
            if call.name == "extract_pdf_section" { recordExtraction(result) }
            if call.name == "get_resume_context" {
                didLoadResumeContext = true
                learnerRespondedToResumeOffer = false
            }
            if call.name == "open_learning_activity" { await stop(); return }
        } catch {
            present(error)
            let signature = toolSignature(call)
            let failures = toolFailureCounts[signature, default: 0] + 1
            toolFailureCounts[signature] = failures
            let retryAllowed = failures < 2
            let result = failureResult(call: call, message: error.localizedDescription, retryAllowed: retryAllowed)
            finishToolActivity(id: activityID, succeeded: false,
                               detail: retryAllowed ? "Failed — Sirius can retry once" : "Failed — retry limit reached")
            try? await client.sendToolResponse(call: call, result: result, status: "error")
        }
    }

    private func beginToolActivity(_ call: GeminiLiveClient.ToolCall) -> UUID {
        let id = UUID()
        toolActivity = AgentToolActivity(id: id, toolName: call.name, title: toolTitle(call.name),
                                         detail: "Working…", status: .running)
        return id
    }

    private func finishToolActivity(id: UUID, succeeded: Bool, detail: String) {
        guard toolActivity?.id == id else { return }
        toolActivity?.status = succeeded ? .succeeded : .failed
        toolActivity?.detail = detail
        guard succeeded else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard self?.toolActivity?.id == id else { return }
            self?.toolActivity = nil
        }
    }

    private func resultIndicatesFailure(_ result: String) -> Bool {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let success = object["success"] as? Bool, !success { return true }
        if let complete = object["audio_complete"] as? Bool, !complete { return true }
        if let status = object["status"] as? String,
           status.localizedCaseInsensitiveContains("error") || status.localizedCaseInsensitiveContains("failed") { return true }
        return false
    }

    private func failureResult(call: GeminiLiveClient.ToolCall, message: String, retryAllowed: Bool) -> String {
        let value: [String: Any] = [
            "status": "failed", "tool": call.name, "error": message,
            "retry_allowed": retryAllowed,
            "instruction": retryAllowed
                ? "Acknowledge the failure briefly and retry this exact action at most once if it is safe. Do not claim it is still running."
                : "Stop this action, tell the learner what failed, and ask how they want to proceed. Do not claim it is still running or completed."
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return message }
        return String(decoding: data, as: UTF8.self)
    }

    private func toolSignature(_ call: GeminiLiveClient.ToolCall) -> String {
        "\(call.name)|\(call.args.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))"
    }

    private func toolTitle(_ name: String) -> String {
        switch name {
        case "list_subjects": "Checking your classes"
        case "select_subject": "Selecting your class"
        case "list_materials": "Checking your books"
        case "get_pdf_outline": "Reading the book outline"
        case "extract_pdf_section": "Retrieving the study section"
        case "create_quiz": "Saving your quiz"
        case "save_lesson": "Saving and narrating your lesson"
        case "list_learning_activities", "get_learning_activity", "get_resume_context": "Checking your study progress"
        case "open_learning_activity": "Opening your activity"
        case "check_calendar_permission": "Checking calendar access"
        case "find_study_slots": "Finding available study times"
        case "schedule_study_plan": "Scheduling your study plan"
        case "check_notification_permission": "Checking notification access"
        case "schedule_activity_notifications": "Scheduling study reminders"
        default: "Sirius is performing an action"
        }
    }

    private func finalizeTranscripts() {
        let student = studentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !student.isEmpty { messages.append(StudyMessage(role: .student, text: student)) }
        studentTranscript = ""
        finalizeTutorTranscript()
    }

    private func finalizeTutorTranscript() {
        let tutor = tutorTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tutor.isEmpty { messages.append(StudyMessage(role: .tutor, text: tutor)) }
        tutorTranscript = ""
    }

    private func validateMaterialRequest(_ call: GeminiLiveClient.ToolCall) -> Bool {
        let requested = call.args["subject"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let sessionSubject, !requested.isEmpty,
              requested.compare(sessionSubject, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
            Task {
                try? await client.sendToolResponse(
                    call: call,
                    result: "Confirm the class conversationally before requesting a PDF.",
                    status: "error"
                )
            }
            return false
        }
        guard let listedMaterialsSubject,
              listedMaterialsSubject.compare(requested, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
            Task {
                try? await client.sendToolResponse(
                    call: call,
                    result: "Call list_materials for the confirmed class before requesting a PDF.",
                    status: "error"
                )
            }
            return false
        }
        return true
    }

    private func recordExtraction(_ result: String) {
        guard let data = result.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let material = value["material_id"] as? String, let section = value["section_id"] as? String,
              let index = value["chunk_index"] as? Int, let total = value["total_chunks"] as? Int else { return }
        let key = "\(material)|\(section)"
        extractedChunks[key, default: []].insert(index)
        expectedChunks[key] = total
    }

    private func validateCompleteExtraction(for call: GeminiLiveClient.ToolCall) throws {
        let field = call.name == "create_quiz" ? "quiz" : "lesson"
        guard let json = call.args[field], let data = json.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let material = value["material_id"] as? String, let section = value["section_id"] as? String else {
            throw TutorHarnessError.invalidGenerationContext
        }
        let key = "\(material)|\(section)"
        guard let total = expectedChunks[key], extractedChunks[key] == Set(0..<total) else {
            throw TutorHarnessError.incompleteExtraction
        }
        if let subject = value["subject"] as? String, let sessionSubject,
           subject.compare(sessionSubject, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            throw TutorHarnessError.subjectMismatch
        }
    }

    private func validateProfileProposal(_ call: GeminiLiveClient.ToolCall,
                                         kind: AgentConfirmation.Kind) async -> Bool {
        let value = call.proposedValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = value.lowercased()
        let conversationalFragments = kind == .subject
            ? ["we're studying", "we are studying", "i'm studying", "i am studying", "i want to study",
               "my class is", "the class is", "my subject is", "the subject is"]
            : ["my name is", "i am called", "i'm called", "you can call me", "call me"]
        let looksLikeSentence = conversationalFragments.contains { normalized.contains($0) }
            || value.contains(".") || value.contains("!") || value.contains("?")
            || value.split(whereSeparator: \.isWhitespace).count > (kind == .subject ? 10 : 5)
        guard !value.isEmpty, !looksLikeSentence else {
            let field = kind == .subject ? "course or subject name" : "person's name"
            try? await client.sendToolResponse(
                call: call,
                result: "Extract only the concise \(field) from the learner's answer and call this tool again. Do not include the surrounding sentence.",
                status: "error"
            )
            return false
        }
        if kind == .subject, !didListSubjects {
            try? await client.sendToolResponse(
                call: call,
                result: "Call list_subjects before proposing a new class. A missing active class is not evidence that the class is new.",
                status: "error"
            )
            return false
        }
        if kind == .subject, let toolHandler {
            let lookup = GeminiLiveClient.ToolCall(id: UUID().uuidString, name: "list_subjects", args: [:])
            if let result = try? await toolHandler(lookup),
               let data = result.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let subjects = root["subjects"] as? [[String: Any]],
               let existing = subjects.compactMap({ $0["name"] as? String }).first(where: {
                   $0.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
               }) {
                try? await client.sendToolResponse(
                    call: call,
                    result: "\(existing) already exists. Call select_subject for it; do not request creation confirmation.",
                    status: "error"
                )
                return false
            }
        }
        return true
    }

    private func present(_ error: Error) { present(message: error.localizedDescription) }
    private func present(message: String) { errorMessage = message; showError = true }
}

import SceneKit
import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct ContentView: View {
    fileprivate enum AppTab { case agent, library }
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var tutor = LiveTutorViewModel()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var materials = MaterialLibrary()
    @StateObject private var learning = LearningStore()
    @StateObject private var calendar = CalendarScheduler()
    private let notifications = NotificationScheduler()
    @State private var activeSubject: String?
    @State private var showFileImporter = false
    // Temporary review mode: remove after the folder-back visual is approved.
    @State private var previewFolderState = false
    @State private var selectedTab: AppTab = .agent
    @State private var regeneratingQuizID: NSManagedObjectID?
    @State private var regeneratingQuizTitle = ""
    @State private var quizRegenerationTask: Task<Void, Never>?
    @State private var sessionStartTask: Task<Void, Never>?
    @Namespace private var mascotTransition

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if selectedTab == .agent {
                    agentScreen
                } else {
                    LibraryView(
                        namespace: mascotTransition,
                        onSettings: { tutor.showSettings = true },
                        onOpenLesson: learning.openLesson,
                        onOpenQuiz: learning.openQuiz,
                        onDeleteLesson: learning.deleteLesson,
                        onDeleteQuiz: learning.deleteQuiz
                    )
                }
            }

            VStack {
                Spacer()
                CustomTabBar(selected: $selectedTab)
            }
            .ignoresSafeArea(.keyboard)

            if let confirmation = tutor.pendingConfirmation {
                Color.black.opacity(0.72).ignoresSafeArea()
                    .transition(.opacity)
                AgentConfirmationView(confirmation: confirmation) { value in
                    confirm(confirmation, value: value)
                }
                .padding(24)
                .transition(.scale(scale: 0.82).combined(with: .opacity))
            }

            if let quiz = learning.activeQuiz {
                QuizPlayerView(
                    quiz: quiz,
                    isRemediationRound: learning.isRemediationRound,
                    agentState: tutor.state,
                    onAnswer: learning.answer,
                    onAdvance: learning.advance,
                    onRetry: learning.retryQuiz,
                    onRegenerate: regenerateQuiz,
                    onClose: closeQuiz,
                    onGoLibrary: returnToLibrary,
                    onWakeAgent: wakeAgentForQuestion
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(5)
            }

            if learning.activeQuiz == nil, let lesson = learning.activeLesson {
                LessonPlayerView(lesson: lesson, onPlay: learning.playLessonItem,
                                 playingItemID: learning.playingLessonItemID,
                                 playbackTime: learning.lessonPlaybackTime,
                                 playbackDuration: learning.lessonPlaybackDuration,
                                 onSeek: { learning.seekLesson(to: $0) },
                                 onSeekRelative: { learning.seekLesson(by: $0) },
                                 agentState: tutor.state,
                                 onWakeAgent: wakeAgentForLesson,
                                 onSelectItem: selectLessonItem,
                                 onClose: closeLesson)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(5)
            }

            if learning.isGeneratingLesson {
                VStack {
                    HStack(spacing: 13) {
                        ElevenLabsMark()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ELEVENLABS NARRATION")
                                .font(.system(size: 10, weight: .black, design: .monospaced)).tracking(1.5)
                            Text(learning.lessonGenerationProgress)
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        }
                        Spacer()
                        ProgressView().tint(.white)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.16)))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(8)
            }

            if regeneratingQuizID != nil {
                QuizRegenerationOverlay(title: regeneratingQuizTitle) {
                    quizRegenerationTask?.cancel()
                    quizRegenerationTask = nil
                    regeneratingQuizID = nil
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: tutor.pendingConfirmation)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: regeneratingQuizID)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $tutor.showSettings) {
            APIKeyView(tutor: tutor, onReset: resetEverything)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            handleFileSelection(result)
        }
        .alert("Sirius couldn't connect", isPresented: $tutor.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(tutor.errorMessage ?? "An unknown error occurred.")
        }
        .alert("Profile couldn't be saved", isPresented: Binding(
            get: { profiles.errorMessage != nil },
            set: { if !$0 { profiles.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { profiles.errorMessage = nil }
        } message: {
            Text(profiles.errorMessage ?? "An unknown error occurred.")
        }
        .alert("Lesson audio error", isPresented: Binding(
            get: { learning.errorMessage != nil },
            set: { if !$0 { learning.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { learning.errorMessage = nil }
        } message: {
            Text(learning.errorMessage ?? "The lesson audio could not be prepared.")
        }
        .task {
            profiles.load(context: viewContext)
            materials.configure(context: viewContext)
            learning.configure(context: viewContext)
            calendar.configure(context: viewContext)
            tutor.configureToolHandler { call in
                switch call.name {
                case "list_subjects", "select_subject":
                    let result = try profiles.execute(call)
                    if call.name == "select_subject" { activeSubject = call.args["subject"] }
                    return result
                case "create_quiz", "save_lesson", "list_learning_activities", "get_learning_activity",
                     "get_resume_context", "open_learning_activity":
                    return try await learning.execute(call)
                case "check_calendar_permission", "find_study_slots", "schedule_study_plan":
                    return try await calendar.execute(call)
                case "check_notification_permission", "schedule_activity_notifications":
                    return try await notifications.execute(call)
                default:
                    return try materials.execute(call)
                }
            }
        }
        .onOpenURL(perform: handleDeepLink)
        .onReceive(NotificationCenter.default.publisher(for: SiriusAppDelegate.deepLinkNotification)) { note in
            guard let url = note.object as? URL else { return }
            handleDeepLink(url)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { learning.saveCurrentProgress() }
        }
        .onChange(of: learning.activeQuiz?.id) { _, newID in
            guard let regeneratingQuizID, let newID, newID != regeneratingQuizID else { return }
            self.regeneratingQuizID = nil
        }
        .onChange(of: learning.errorMessage) { _, message in
            if message != nil { regeneratingQuizID = nil }
        }
    }

    private func handleDeepLink(_ url: URL) {
        if url.host == "home" {
            if tutor.state.isActive { Task { await tutor.stop() } }
            learning.closeLesson()
            learning.closeQuiz()
            selectedTab = .agent
            return
        }
        selectedTab = .library
        learning.openDeepLink(url)
    }

    private var agentScreen: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 20)
            ZStack {
                StreamingWaveLine(isActive: tutor.state == .speaking)
                    .frame(height: 120)
                    .padding(.horizontal, -28)
                    .accessibilityHidden(true)
                CubeMascotView(state: tutor.state, isRequestingMaterial: previewFolderState || tutor.pendingMaterialRequest != nil)
                    .frame(maxWidth: .infinity)
                    .frame(height: 330)
                    .matchedGeometryEffect(id: "sirius-mascot", in: mascotTransition)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handleCubeTap)
                    .accessibilityLabel(tutor.pendingMaterialRequest == nil ? "Wake Sirius" : "Import requested PDF")
                    .accessibilityAddTraits(.isButton)
            }
            .frame(height: 330)
            stateLabel
            Spacer()
            Color.clear.frame(height: 76)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SIRIUS")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .tracking(5)
                Text("STUDY COMPANION")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.gray)
                if let username = profiles.username {
                    Text(username.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
    }

    private var stateLabel: some View {
        VStack(spacing: 8) {
            Text((previewFolderState ? "Drawer preview" : tutor.pendingMaterialRequest == nil ? tutor.state.mascotTitle : "Bring me the book").uppercased())
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .tracking(3)
            Text(previewFolderState ? "Tap the cube when you're ready to wake Sirius." : tutor.pendingMaterialRequest == nil ? tutor.state.mascotDetail : "Tap the open drawer to choose the PDF for this subject.")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }
        .animation(.easeInOut, value: tutor.state)
    }

    private func confirm(_ confirmation: AgentConfirmation, value: String) {
        switch confirmation.kind {
        case .learnerName:
            profiles.createLearner(username: value)
        case .subject:
            guard profiles.selectOrCreateSubject(named: value) != nil else { return }
            activeSubject = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard profiles.errorMessage == nil else { return }
        Task { await tutor.completeConfirmation(with: value) }
    }

    private func handleCubeTap() {
        if tutor.pendingMaterialRequest != nil {
            showFileImporter = true
            return
        }
        if tutor.state.isActive {
            Task { await tutor.stop(); activeSubject = nil }
            return
        }
        previewFolderState = false
        beginSession()
    }

    private func beginSession() {
        previewFolderState = false
        guard tutor.savedAPIKey != nil else { tutor.showSettings = true; return }
        activeSubject = nil
        sessionStartTask?.cancel()
        sessionStartTask = Task {
            await tutor.start(
                learnerName: profiles.username,
                subjectName: nil
            )
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        guard let request = tutor.pendingMaterialRequest else { return }
        do {
            let url = try result.get().first
            guard let url else { return }
            guard let subject = request.args["subject"], !subject.isEmpty else {
                Task { await tutor.failMaterialImport("A confirmed subject is required before importing a book.") }
                return
            }
            let importResult = try materials.importPDF(from: url, subjectName: subject)
            activeSubject = subject
            Task { await tutor.completeMaterialImport(result: importResult) }
        } catch {
            Task { await tutor.failMaterialImport(error.localizedDescription) }
        }
    }

    private func resetEverything() {
        quizRegenerationTask?.cancel()
        sessionStartTask?.cancel()
        Task {
            await tutor.stop()
            profiles.resetEverything()
            learning.resetState()
            activeSubject = nil
            previewFolderState = false
        }
    }

    private func wakeAgentForQuestion(_ question: QuizQuestionState) {
        if tutor.state.isActive {
            Task { await tutor.stop() }
            return
        }
        guard tutor.savedAPIKey != nil else { tutor.showSettings = true; return }
        learning.markHintUsed(for: question.id)
        Task {
            await tutor.start(
                learnerName: profiles.username,
                subjectName: learning.activeQuiz?.subject,
                assistanceQuestion: question
            )
        }
    }

    private func wakeAgentForLesson(_ item: LessonItemState) {
        if tutor.state.isActive {
            Task { await tutor.stop() }
            return
        }
        startAgentForLesson(item)
    }

    private func startAgentForLesson(_ item: LessonItemState) {
        guard tutor.savedAPIKey != nil else { tutor.showSettings = true; return }
        guard let lesson = learning.activeLesson else { return }
        learning.pauseLessonPlayback()
        let context = LessonAssistanceContext(
            lessonTitle: lesson.title,
            subject: lesson.subject,
            segmentTitle: item.title,
            style: item.style,
            groundedScript: item.script
        )
        Task {
            await tutor.start(
                learnerName: profiles.username,
                subjectName: lesson.subject,
                lessonAssistance: context
            )
        }
    }

    private func selectLessonItem(_ item: LessonItemState) {
        let shouldMoveActiveAgent = tutor.state.isActive
        Task {
            if shouldMoveActiveAgent { await tutor.stop() }
            learning.playLessonItem(item)
            if shouldMoveActiveAgent { startAgentForLesson(item) }
        }
    }

    private func closeLesson() {
        learning.closeLesson()
        if tutor.state.isActive { Task { await tutor.stop() } }
    }

    private func closeQuiz() {
        learning.closeQuiz()
        if tutor.state.isActive { Task { await tutor.stop() } }
    }

    private func returnToLibrary() {
        closeQuiz()
        selectedTab = .library
    }

    private func regenerateQuiz() {
        guard let quiz = learning.activeQuiz else { return }
        guard let apiKey = tutor.savedAPIKey, !apiKey.isEmpty else {
            tutor.showSettings = true
            return
        }
        regeneratingQuizID = quiz.id
        regeneratingQuizTitle = quiz.title
        quizRegenerationTask?.cancel()
        quizRegenerationTask = Task {
            if tutor.state.isActive { await tutor.stop() }
            do {
                var chunks: [String] = []
                var chunkIndex = 0
                var totalChunks = 1
                repeat {
                    let call = GeminiLiveClient.ToolCall(
                        id: UUID().uuidString,
                        name: "extract_pdf_section",
                        args: ["material_id": quiz.materialID, "section_id": quiz.sectionID,
                               "chunk_index": String(chunkIndex)]
                    )
                    let result = try materials.execute(call)
                    guard let data = result.data(using: .utf8),
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let content = object["content"] as? String else {
                        throw GeminiQuizGenerator.GenerationError.invalidResponse
                    }
                    chunks.append(content)
                    totalChunks = object["total_chunks"] as? Int ?? 1
                    chunkIndex += 1
                } while chunkIndex < totalChunks

                let quizJSON = try await GeminiQuizGenerator().generate(
                    apiKey: apiKey,
                    title: quiz.title,
                    subject: quiz.subject,
                    materialID: quiz.materialID,
                    sectionID: quiz.sectionID,
                    source: chunks.joined(separator: "\n\n"),
                    previousPrompts: quiz.questions.map(\.prompt)
                )
                try Task.checkCancellation()
                _ = try await learning.execute(GeminiLiveClient.ToolCall(
                    id: UUID().uuidString,
                    name: "create_quiz",
                    args: ["quiz": quizJSON]
                ))
                quizRegenerationTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                quizRegenerationTask = nil
                regeneratingQuizID = nil
                learning.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct QuizRegenerationOverlay: View {
    let title: String
    let onCancel: () -> Void
    @State private var orbit = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.68).ignoresSafeArea()
            VStack(spacing: 18) {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 5).frame(width: 74, height: 74)
                    Circle().trim(from: 0.08, to: 0.72)
                        .stroke(Color(red: 0.08, green: 0.28, blue: 0.58),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 74, height: 74)
                        .rotationEffect(.degrees(orbit ? 360 : 0))
                    Image(systemName: "questionmark")
                        .font(.system(size: 25, weight: .black))
                }
                VStack(spacing: 6) {
                    Text("BUILDING A NEW SET")
                        .font(.system(size: 11, weight: .black, design: .monospaced)).tracking(2)
                    Text(title)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Text("Reading the source and creating 15 fresh questions…")
                        .font(.caption).foregroundStyle(.gray).multilineTextAlignment(.center)
                }
                Button("CANCEL", action: onCancel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 30).padding(.vertical, 28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.13)))
            .shadow(color: .black.opacity(0.65), radius: 32, y: 16)
            .padding(.horizontal, 32)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) { orbit = true }
        }
    }
}

private struct CustomTabBar: View {
    @Binding var selected: ContentView.AppTab

    var body: some View {
        HStack(spacing: 8) {
            tab(.agent, title: "SIRIUS", icon: "cube.fill")
            tab(.library, title: "LIBRARY", icon: "books.vertical.fill")
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
        .padding(.bottom, 12)
    }

    private func tab(_ tab: ContentView.AppTab, title: String, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { selected = tab }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.2)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .foregroundStyle(selected == tab ? .black : .white.opacity(0.65))
                .background(selected == tab ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct StreamingWaveLine: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { timeline in
            Canvas { context, size in
                let phase: CGFloat = isActive ? CGFloat(timeline.date.timeIntervalSinceReferenceDate * 3.2) : 0
                var path = Path()
                let midY = size.height / 2
                let amplitude: CGFloat = isActive ? 26 : 3
                let points = max(Int(size.width / 3), 2)
                for index in 0...points {
                    let x = CGFloat(index) / CGFloat(points) * size.width
                    let normalized = x / max(size.width, 1)
                    let envelope = sin(.pi * normalized)
                    let primary = sin(normalized * .pi * 5 + phase)
                    let detail = sin(normalized * .pi * 13 - phase * 1.35) * 0.28
                    let y = midY + amplitude * envelope * (primary + detail)
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .linearGradient(
                    Gradient(colors: [.clear, .white.opacity(isActive ? 0.32 : 0.12), .white.opacity(isActive ? 0.7 : 0.2), .white.opacity(isActive ? 0.32 : 0.12), .clear]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)
                ), lineWidth: isActive ? 2 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isActive)
    }
}

private struct LibraryView: View {
    private enum DeletionTarget: Identifiable {
        case lesson(NSManagedObjectID, String)
        case quiz(NSManagedObjectID, String)

        var id: NSManagedObjectID {
            switch self {
            case .lesson(let id, _), .quiz(let id, _): id
            }
        }

        var name: String {
            switch self {
            case .lesson(_, let name), .quiz(_, let name): name
            }
        }
    }

    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "importedAt", ascending: false)])
    private var books: FetchedResults<StudyMaterial>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: false)])
    private var lessons: FetchedResults<SavedLesson>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: false)])
    private var quizzes: FetchedResults<QuizSet>
    let namespace: Namespace.ID
    let onSettings: () -> Void
    let onOpenLesson: (NSManagedObjectID) -> Void
    let onOpenQuiz: (NSManagedObjectID) -> Void
    let onDeleteLesson: (NSManagedObjectID) -> Void
    let onDeleteQuiz: (NSManagedObjectID) -> Void
    @State private var deletionTarget: DeletionTarget?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LIBRARY").font(.system(size: 30, weight: .black, design: .rounded)).tracking(4)
                        Text("Your books and saved learning activities").foregroundStyle(.gray)
                    }
                    Spacer()
                    CubeMascotView(state: .disconnected, isRequestingMaterial: false, slowlySpinning: true)
                        .frame(width: 62, height: 58)
                        .matchedGeometryEffect(id: "sirius-mascot", in: namespace)
                        .accessibilityHidden(true)
                }
                Button(action: onSettings) {
                    AISetupLibraryCard()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open AI setup")
                librarySection("BOOKS", count: books.count) {
                    ForEach(books) { book in
                        LibraryCard(icon: "book.closed.fill", accent: .blue, title: book.title ?? "PDF",
                                    subtitle: "\(book.subject?.name ?? "Subject") · \(book.pageCount) pages", progress: nil)
                    }
                }
                librarySection("LESSONS", count: lessons.count) {
                    ForEach(lessons) { lesson in
                        Button { onOpenLesson(lesson.objectID) } label: {
                            LibraryCard(icon: "headphones", accent: .yellow, title: lesson.title ?? "Lesson",
                                        subtitle: lesson.subjectName ?? "Subject", progress: lesson.progress)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Lesson", systemImage: "trash", role: .destructive) {
                                deletionTarget = .lesson(lesson.objectID, lesson.title ?? "Lesson")
                            }
                        }
                    }
                }
                librarySection("QUIZZES", count: quizzes.count) {
                    ForEach(quizzes) { quiz in
                        Button { onOpenQuiz(quiz.objectID) } label: {
                            let total = (quiz.questions as? Set<QuizQuestion>)?.count ?? 0
                            let progress = total == 0 ? 0 : Double(quiz.currentIndex) / Double(total)
                            LibraryCard(icon: "checkmark.square.fill", accent: .green, title: quiz.title ?? "Quiz",
                                        subtitle: "\(quiz.subjectName ?? "Subject") · \(quiz.score)/\(total) correct", progress: progress)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Quiz", systemImage: "trash", role: .destructive) {
                                deletionTarget = .quiz(quiz.objectID, quiz.title ?? "Quiz")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 110)
        }
        .confirmationDialog(
            "Remove \(deletionTarget?.name ?? "this item")?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard let target = deletionTarget else { return }
                switch target {
                case .lesson(let id, _): onDeleteLesson(id)
                case .quiz(let id, _): onDeleteQuiz(id)
                }
                deletionTarget = nil
            }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("This permanently removes it and its saved progress.")
        }
    }

    private func librarySection<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 11, weight: .black, design: .monospaced)).tracking(2).foregroundStyle(.gray)
                Spacer()
                Text("\(count)").font(.caption.bold()).foregroundStyle(.gray)
            }
            if count == 0 {
                Text("Nothing here yet").foregroundStyle(.white.opacity(0.35)).padding(.vertical, 12)
            } else { content() }
        }
    }
}

private struct AISetupLibraryCard: View {
    var body: some View {
        HStack(spacing: 15) {
            HStack(spacing: 5) {
                GeminiMark()
                ElevenLabsMark()
            }
            .frame(width: 72, height: 48)

            VStack(alignment: .leading, spacing: 6) {
                Text("AI Setup").font(.headline).foregroundStyle(.white)
                Text("Gemini Live, ElevenLabs, and voice settings")
                    .font(.caption).foregroundStyle(.gray).lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.bold()).foregroundStyle(.white.opacity(0.35))
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08)))
    }
}

private struct GeminiMark: View {
    var body: some View {
        CubicIconBadge(size: 38, accent: .white) {
            Image(systemName: "sparkle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 0.20, green: 0.48, blue: 0.98),
                                 Color(red: 0.58, green: 0.32, blue: 0.88),
                                 Color(red: 0.94, green: 0.38, blue: 0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .accessibilityLabel("Gemini")
    }
}

private struct ElevenLabsMark: View {
    var body: some View {
        CubicIconBadge(size: 38, accent: .white) {
            HStack(spacing: 3) {
                Capsule().fill(.black).frame(width: 3, height: 18)
                Capsule().fill(.black).frame(width: 3, height: 18)
            }
        }
        .accessibilityLabel("ElevenLabs")
    }
}

private struct CubicIconBadge<Content: View>: View {
    let size: CGFloat
    let accent: Color
    @ViewBuilder let content: Content

    init(size: CGFloat, accent: Color, @ViewBuilder content: () -> Content) {
        self.size = size
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let edge = proxy.size.width * 0.16
            let face = proxy.size.width - edge
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: edge, y: 0))
                    path.addLine(to: CGPoint(x: face, y: 0))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: edge))
                    path.addLine(to: CGPoint(x: edge * 2, y: edge))
                    path.closeSubpath()
                }
                .fill(accent.opacity(0.78))

                Path { path in
                    path.move(to: CGPoint(x: face, y: 0))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: edge))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: face))
                    path.addLine(to: CGPoint(x: face, y: proxy.size.height))
                    path.closeSubpath()
                }
                .fill(accent.opacity(0.52))

                RoundedRectangle(cornerRadius: size * 0.20)
                    .fill(accent)
                    .frame(width: face, height: face)
                    .offset(x: 0, y: edge)
                    .overlay {
                        content
                            .frame(width: face, height: face)
                            .offset(y: edge)
                    }
            }
            .shadow(color: accent.opacity(0.2), radius: 7, y: 4)
        }
        .frame(width: size, height: size)
    }
}

private struct LibraryCard: View {
    let icon: String
    let accent: Color
    let title: String
    let subtitle: String
    let progress: Double?

    var body: some View {
        HStack(spacing: 15) {
            CubicIconBadge(size: 48, accent: accent) {
                Image(systemName: icon).font(.title3).foregroundStyle(.black)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.gray)
                if let progress { ProgressView(value: progress).tint(accent) }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.3))
        }
        .padding(15).background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct QuizPlayerView: View {
    let quiz: QuizState
    let isRemediationRound: Bool
    let agentState: LiveSessionState
    let onAnswer: (Set<String>) -> Bool
    let onAdvance: () -> Void
    let onRetry: () -> Void
    let onRegenerate: () -> Void
    let onClose: () -> Void
    let onGoLibrary: () -> Void
    let onWakeAgent: (QuizQuestionState) -> Void
    @State private var showCompletionConfetti = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if quiz.isComplete {
                completion
            } else if let question = quiz.currentQuestion {
                QuizQuestionView(question: question, number: quiz.currentIndex + 1,
                                 total: quiz.questions.count, title: quiz.title, subject: quiz.subject,
                                 isRemediationRound: isRemediationRound,
                                 agentState: agentState, onAnswer: onAnswer,
                                 onAdvance: onAdvance, onGoLibrary: onGoLibrary,
                                 onWakeAgent: onWakeAgent)
                    .id(question.id)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var completion: some View {
        let percentage = quiz.questions.isEmpty ? 0 : Double(quiz.score) / Double(quiz.questions.count)
        return ZStack {
            VStack(spacing: 22) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 58))
                .foregroundStyle(.yellow)
            Text("SET COMPLETE")
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .tracking(3)
            Text("\(quiz.score) / \(quiz.questions.count)")
                .font(.system(size: 54, weight: .black, design: .rounded))
            Text(feedback(for: percentage))
                .font(.title2.bold())
            Text("Your results and progress have been saved.").foregroundStyle(.gray)
            HStack(spacing: 12) {
                completionButton("RETRY", icon: "arrow.counterclockwise", primary: true) {
                    QuizFeedbackPlayer.shared.play(.progress)
                    onRetry()
                }
                completionButton("NEW SET", icon: "sparkles", primary: false) {
                    QuizFeedbackPlayer.shared.play(.progress)
                    onRegenerate()
                }
            }
            Button("RETURN TO SIRIUS", action: onClose)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.2).foregroundStyle(.gray).padding(.top, 4)
            }
            .padding(.horizontal, 24)
            if showCompletionConfetti { ConfettiBurst(correct: true) }
        }
        .onAppear {
            showCompletionConfetti = true
            QuizFeedbackPlayer.shared.play(percentage >= 0.8 ? .success : .progress)
        }
    }

    private func feedback(for percentage: Double) -> String {
        switch percentage {
        case ..<0.5: "NOT GOOD ENOUGH — LET'S TRY AGAIN"
        case ..<0.8: "GOOD JOB"
        default: "NAILED IT"
        }
    }

    private func completionButton(_ title: String, icon: String, primary: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .foregroundStyle(primary ? .black : .white)
                .background(primary ? Color.white : Color.white.opacity(0.1), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(primary ? 0 : 0.22)))
        }
    }
}

private struct LessonPlayerView: View {
    let lesson: LessonState
    let onPlay: (LessonItemState) -> Void
    let playingItemID: NSManagedObjectID?
    let playbackTime: TimeInterval
    let playbackDuration: TimeInterval
    let onSeek: (TimeInterval) -> Void
    let onSeekRelative: (TimeInterval) -> Void
    let agentState: LiveSessionState
    let onWakeAgent: (LessonItemState) -> Void
    let onSelectItem: (LessonItemState) -> Void
    let onClose: () -> Void
    @State private var selectedIndex = 0
    @State private var notesExpanded = true

    private var current: LessonItemState? {
        lesson.items.indices.contains(selectedIndex) ? lesson.items[selectedIndex] : nil
    }

    private var rounds: [[LessonItemState]] {
        guard !lesson.items.isEmpty else { return [] }
        let count = Int(ceil(Double(lesson.items.count) / 4.0))
        let base = lesson.items.count / count
        let extra = lesson.items.count % count
        var cursor = 0
        return (0..<count).map { index in
            let size = base + (index < extra ? 1 : 0)
            defer { cursor += size }
            return Array(lesson.items[cursor..<(cursor + size)])
        }
    }

    private var activeRound: Int {
        rounds.firstIndex(where: { round in round.contains(where: { $0.id == current?.id }) }) ?? 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    LessonJourneyMap(rounds: rounds, activeRound: activeRound,
                                     agentState: agentState,
                                     onWakeAgent: { if let current { onWakeAgent(current) } }) { round in
                        guard rounds.indices.contains(round),
                              let target = rounds[round].first(where: { !$0.completed }) ?? rounds[round].first,
                              let index = lesson.items.firstIndex(where: { $0.id == target.id }) else { return }
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { selectedIndex = index }
                        onSelectItem(target)
                    }
                    .frame(height: 455)

                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "chevron.down").font(.headline).frame(width: 42, height: 42)
                        }
                        Spacer()
                        VStack(spacing: 2) {
                            Text("").font(.system(size: 9, weight: .black, design: .monospaced)).tracking(2)
                        }
                        Spacer()
                        Image(systemName: "ellipsis").frame(width: 42, height: 42).foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                .background(Color(red: 0.035, green: 0.075, blue: 0.09))
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.72), .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 105)
                        .allowsHitTesting(false)
                }

                if let current {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ROUND \(activeRound + 1)")
                                    .font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1.8)
                                    .foregroundStyle(.gray)
                                Text(lesson.subject.uppercased())
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundStyle(.gray)
                                Text(current.title).font(.title2.bold()).lineLimit(2)
                                Text(oneLineDescription(for: current))
                                    .font(.subheadline).foregroundStyle(.gray).lineLimit(1)
                                Text(current.style.replacingOccurrences(of: "_", with: " ").uppercased())
                                    .font(.system(size: 8, weight: .black, design: .monospaced)).tracking(1.2)
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(.white, in: Capsule())
                            }
                            Spacer()
                            Image(systemName: current.completed ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(current.completed ? .green : .gray)
                        }
                    }
                    .padding(.horizontal, 24)

                    VStack(spacing: 5) {
                        Slider(
                            value: Binding(get: { playbackTime }, set: onSeek),
                            in: 0...max(playbackDuration, 1)
                        )
                        .tint(.white)
                        .disabled(playbackDuration <= 0)
                        HStack {
                            Text(formatTime(playbackTime))
                            Spacer()
                            Text("-\(formatTime(max(playbackDuration - playbackTime, 0)))")
                        }
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.gray)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                    HStack(spacing: 21) {
                        playerButton("backward.end.fill", enabled: selectedIndex > 0) { selectItem(at: selectedIndex - 1) }
                        playerButton("gobackward.10", enabled: playbackDuration > 0) { onSeekRelative(-10) }
                        Button { onPlay(current) } label: {
                            Image(systemName: playingItemID == current.id ? "pause.fill" : "play.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.black).frame(width: 72, height: 72).background(.white, in: Circle())
                        }
                        playerButton("goforward.10", enabled: playbackDuration > 0) { onSeekRelative(10) }
                        playerButton("forward.end.fill", enabled: selectedIndex < lesson.items.count - 1) { selectItem(at: selectedIndex + 1) }
                    }.padding(.top, 14).padding(.bottom, 8)

                    DisclosureGroup("LESSON NOTES", isExpanded: $notesExpanded) {
                        ScrollView { Text(current.script).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white.opacity(0.75)).lineSpacing(4).padding(.top, 12) }
                            .frame(maxHeight: 125)
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.gray)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                }
                Spacer(minLength: 12)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let playingItemID,
               let playingIndex = lesson.items.firstIndex(where: { $0.id == playingItemID }) {
                selectedIndex = playingIndex
            } else {
                selectedIndex = lesson.items.firstIndex(where: { !$0.completed }) ?? 0
            }
        }
        .onChange(of: playingItemID) { _, itemID in
            guard let itemID, let index = lesson.items.firstIndex(where: { $0.id == itemID }) else { return }
            withAnimation(.easeInOut(duration: 0.3)) { selectedIndex = index }
        }
    }

    private func oneLineDescription(for item: LessonItemState) -> String {
        let sentence = item.script.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? item.script
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectItem(at index: Int) {
        guard lesson.items.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { selectedIndex = index }
        onSelectItem(lesson.items[index])
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "0:00" }
        let seconds = max(Int(interval.rounded(.down)), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func playerButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 23, weight: .semibold)).frame(width: 44, height: 44) }
            .disabled(!enabled).opacity(enabled ? 1 : 0.3)
    }
}

private struct LessonJourneyMap: View {
    let rounds: [[LessonItemState]]
    let activeRound: Int
    let agentState: LiveSessionState
    let onWakeAgent: () -> Void
    let onSelectRound: (Int) -> Void

    private var nodeCount: Int { max(10, rounds.count + 4) }
    private var contentHeight: CGFloat { CGFloat(nodeCount) * 132 + 100 }
    private let navy = Color(red: 0.035, green: 0.15, blue: 0.31)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                GeometryReader { geometry in
                    let points = positions(width: geometry.size.width)
                    ZStack {
                        Canvas { context, _ in
                            guard points.count > 1 else { return }
                            for index in 0..<(points.count - 1) {
                                let completedConnection = rounds.indices.contains(index)
                                    && rounds[index].allSatisfy(\.completed)
                                let path = connectionPath(from: points[index], to: points[index + 1])
                                context.stroke(
                                    path,
                                    with: .color(completedConnection ? .red : .white.opacity(0.16)),
                                    style: StrokeStyle(
                                        lineWidth: completedConnection ? 7 : 6,
                                        lineCap: .round,
                                        dash: completedConnection ? [1, 13] : [1, 16]
                                    )
                                )
                            }
                        }
                        .allowsHitTesting(false)

                        ForEach(0..<nodeCount, id: \.self) { index in
                            let unlocked = rounds.indices.contains(index)
                            JourneyRoundNode(
                                number: index + 1,
                                completed: unlocked && rounds[index].allSatisfy(\.completed),
                                active: unlocked && index == activeRound,
                                locked: !unlocked
                            )
                            .id(index)
                            .position(points[index])
                            .contentShape(Circle())
                            .zIndex(10)
                            .onTapGesture {
                                guard unlocked else {
                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                    return
                                }
                                onSelectRound(index)
                            }
                        }

                        if points.indices.contains(activeRound) {
                            Button(action: onWakeAgent) {
                                ZStack(alignment: .bottomTrailing) {
                                    CubeMascotView(state: agentState.isActive ? agentState : .listening,
                                                   isRequestingMaterial: false,
                                                   slowlySpinning: !agentState.isActive)
                                        .frame(width: 72, height: 66)
                                        .allowsHitTesting(false)
                                    Circle()
                                        .fill(agentState.isActive ? navy : Color.white)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            Image(systemName: agentStatusIcon)
                                                .font(.system(size: 11, weight: .black))
                                                .foregroundStyle(agentState.isActive ? .white : .black)
                                        }
                                        .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 2))
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 78, height: 72)
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .position(x: points[activeRound].x, y: points[activeRound].y - 82)
                            .zIndex(5)
                            .transition(.scale.combined(with: .opacity))
                            .animation(.spring(response: 0.55, dampingFraction: 0.7), value: activeRound)
                            .accessibilityLabel(agentState.isActive ? "Disconnect Sirius lesson help" : "Ask Sirius about this lesson")
                        }
                    }
                }
                .frame(height: contentHeight)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                DispatchQueue.main.async {
                    scroll(to: activeRound, using: proxy, animated: false)
                }
            }
            .onChange(of: activeRound) { _, round in scroll(to: round, using: proxy, animated: true) }
        }
    }

    private var agentStatusIcon: String {
        switch agentState {
        case .disconnected: "waveform"
        case .connecting: "ellipsis"
        case .listening: "waveform"
        case .speaking: "stop.fill"
        }
    }

    private func positions(width: CGFloat) -> [CGPoint] {
        (0..<nodeCount).map { index in
            let phase = CGFloat(index) * 1.28
            let x = width * (0.5 + 0.29 * sin(phase))
            // Keep the opening node above the player blend so its ring, glow,
            // and incoming footsteps remain completely visible.
            let y = contentHeight - 154 - CGFloat(index) * 132
            return CGPoint(x: x, y: y)
        }
    }

    private func connectionPath(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let middleY = (start.y + end.y) / 2
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x, y: middleY),
            control2: CGPoint(x: end.x, y: middleY)
        )
        return path
    }

    private func scroll(to round: Int, using proxy: ScrollViewProxy, animated: Bool) {
        let action = { proxy.scrollTo(min(max(round, 0), nodeCount - 1), anchor: .center) }
        if animated { withAnimation(.easeInOut(duration: 0.5), action) } else { action() }
    }
}

private struct JourneyRoundNode: View {
    let number: Int
    let completed: Bool
    let active: Bool
    let locked: Bool
    @State private var pulse = false
    private let navy = Color(red: 0.035, green: 0.15, blue: 0.31)

    var body: some View {
        ZStack {
            if completed {
                Circle().stroke(navy.opacity(pulse ? 0.05 : 0.9), lineWidth: 4)
                    .frame(width: 70, height: 70)
                    .scaleEffect(pulse ? 1.34 : 1)
                    .allowsHitTesting(false)
            }
            Circle().fill(Color.black.opacity(0.45)).frame(width: 76, height: 76).offset(y: 7)
            Circle()
                .fill(locked ? Color(white: 0.10) : completed ? navy : active ? navy : Color(white: 0.20))
                .frame(width: 76, height: 76)
                .overlay(Circle().stroke(.white.opacity(completed || active ? 0.75 : 0.14), lineWidth: 3))
            VStack(spacing: 2) {
                Image(systemName: locked ? "lock.fill" : completed ? "checkmark" : "headphones")
                    .font(.system(size: 24, weight: .black))
                Text("\(number)").font(.system(size: 9, weight: .black, design: .monospaced))
            }
            .foregroundStyle(locked ? .gray : .white)
        }
        .frame(width: 94, height: 94)
        .scaleEffect(active ? 1.08 : 1)
        .shadow(color: completed || active ? navy.opacity(0.8) : .clear, radius: 18)
        .onAppear { if completed { startCompletionPulse() } }
        .onChange(of: completed) { _, isCompleted in
            guard isCompleted else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            startCompletionPulse()
        }
        .accessibilityLabel("Lesson round \(number)\(locked ? ", locked" : completed ? ", completed" : active ? ", current" : "")")
    }

    private func startCompletionPulse() {
        pulse = false
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

private struct RewardChestView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color.orange).frame(height: 28).offset(y: 7)
            RoundedRectangle(cornerRadius: 8).fill(Color.yellow).frame(height: 17).offset(y: -7)
            Rectangle().fill(Color.brown).frame(width: 8, height: 34).offset(y: 4)
            Circle().fill(.white).frame(width: 8, height: 8).offset(y: 4)
        }
        .shadow(color: .orange.opacity(0.35), radius: 8, y: 5)
        .accessibilityHidden(true)
    }
}

private struct PowerUpView: View {
    var body: some View {
        ZStack {
            CubicIconBadge(size: 38, accent: .purple) {
                Image(systemName: "bolt.fill").foregroundStyle(.white).font(.system(size: 16, weight: .black))
            }
        }
        .shadow(color: .purple.opacity(0.5), radius: 10)
        .accessibilityHidden(true)
    }
}

private struct QuizJourneyMap: View {
    let total: Int
    let activeIndex: Int
    let answered: Bool
    let correct: Bool
    let agentState: LiveSessionState
    let onWakeAgent: () -> Void

    private let navy = Color(red: 0.035, green: 0.15, blue: 0.31)
    private var contentHeight: CGFloat { CGFloat(max(total, 1)) * 118 + 150 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                GeometryReader { geometry in
                    let points = positions(width: geometry.size.width)
                    ZStack {
                        SpaceStarField().allowsHitTesting(false)
                        Canvas { context, _ in
                            guard points.count > 1 else { return }
                            for index in 0..<(points.count - 1) {
                                context.stroke(
                                    connectionPath(from: points[index], to: points[index + 1]),
                                    with: .color(.white.opacity(0.72)),
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [1, 15])
                                )
                            }
                        }
                        .allowsHitTesting(false)

                        ForEach(0..<total, id: \.self) { index in
                            QuizPathNode(number: index + 1,
                                         completed: index < activeIndex || (index == activeIndex && answered),
                                         correct: index < activeIndex || (index == activeIndex && answered && correct),
                                         active: index == activeIndex,
                                         locked: index > activeIndex)
                                .id(index)
                                .position(points[index])
                        }

                        if points.indices.contains(activeIndex) {
                            Button(action: onWakeAgent) {
                                ZStack(alignment: .bottomTrailing) {
                                    CubeMascotView(state: agentState.isActive ? agentState : .listening,
                                                   isRequestingMaterial: false,
                                                   slowlySpinning: !agentState.isActive)
                                        .frame(width: 67, height: 61)
                                        .allowsHitTesting(false)
                                    Circle().fill(agentState.isActive ? navy : .white)
                                        .frame(width: 27, height: 27)
                                        .overlay(Image(systemName: agentState.isActive ? "stop.fill" : "waveform")
                                            .font(.system(size: 10, weight: .black))
                                            .foregroundStyle(agentState.isActive ? .white : .black))
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 74, height: 68)
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .position(x: points[activeIndex].x, y: points[activeIndex].y - 75)
                            .accessibilityLabel(agentState.isActive ? "Stop Sirius hint" : "Ask Sirius for a hint")
                        }
                    }
                }
                .frame(height: contentHeight)
            }
            .background(Color(red: 0.015, green: 0.035, blue: 0.075))
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.7), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90).allowsHitTesting(false)
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(activeIndex, anchor: .center) } }
            .onChange(of: activeIndex) { _, value in
                withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    private func positions(width: CGFloat) -> [CGPoint] {
        (0..<total).map { index in
            CGPoint(x: width * (0.5 + 0.29 * sin(CGFloat(index) * 1.24)),
                    y: contentHeight - 105 - CGFloat(index) * 118)
        }
    }

    private func connectionPath(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let middleY = (start.y + end.y) / 2
        path.addCurve(to: end, control1: CGPoint(x: start.x, y: middleY),
                      control2: CGPoint(x: end.x, y: middleY))
        return path
    }
}

private struct SpaceStarField: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<90 {
                let x = CGFloat((index * 73) % 997) / 997 * size.width
                let y = CGFloat((index * 151 + 47) % 991) / 991 * size.height
                let radius = CGFloat(index % 4 == 0 ? 1.7 : 0.8)
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                             with: .color(.white.opacity(index % 5 == 0 ? 0.55 : 0.22)))
            }
        }
    }
}

private struct QuizPathNode: View {
    let number: Int
    let completed: Bool
    let correct: Bool
    let active: Bool
    let locked: Bool
    private let navy = Color(red: 0.035, green: 0.15, blue: 0.31)

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.5)).frame(width: 68, height: 68).offset(y: 6)
            Circle().fill(nodeColor)
                .frame(width: 68, height: 68)
                .overlay(Circle().stroke(.white.opacity(active ? 0.8 : 0.2), lineWidth: 3))
            if active {
                Text("\(number)").font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 82, height: 82)
        .scaleEffect(active ? 1.08 : 1)
        .shadow(color: active ? navy.opacity(0.9) : .clear, radius: 17)
        .accessibilityLabel("Question \(number)\(locked ? ", locked" : completed ? ", completed" : active ? ", current" : "")")
    }

    private var nodeColor: Color {
        if active && completed && !correct { return .red }
        if completed && correct { return .green }
        if active { return navy }
        return Color(white: 0.11)
    }
}

private struct QuizResultBurst: View {
    let correct: Bool
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: correct ? "star.fill" : "arrow.counterclockwise")
                .font(.system(size: 56, weight: .black))
            Text(correct ? "BRILLIANT!" : "KEEP GOING!")
                .font(.system(size: 20, weight: .black, design: .monospaced)).tracking(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 34).padding(.vertical, 28)
        .background(correct ? Color.green.opacity(0.94) : Color.red.opacity(0.94),
                    in: RoundedRectangle(cornerRadius: 26))
        .shadow(color: (correct ? Color.green : Color.red).opacity(0.65), radius: 30)
    }
}

private struct ConfettiBurst: View {
    let correct: Bool
    @State private var exploded = false
    private let colors: [Color] = [.green, .yellow, .cyan, .orange, .pink, .white]

    var body: some View {
        ZStack {
            ForEach(0..<thirtyTwo, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(colors[index % colors.count])
                    .frame(width: 6, height: 11)
                    .rotationEffect(.degrees(exploded ? Double((index * 53) % 360) : 0))
                    .offset(x: exploded ? cos(Double(index) * 1.7) * 145 : 0,
                            y: exploded ? sin(Double(index) * 1.7) * 190 : 0)
                    .opacity(exploded ? 0 : 1)
                    .animation(.easeOut(duration: 0.9).delay(Double(index % 5) * 0.025), value: exploded)
            }
        }
        .onAppear { exploded = true }
        .allowsHitTesting(false)
    }

    private var thirtyTwo: Int { correct ? 32 : 24 }
}

private struct QuizQuestionView: View {
    let question: QuizQuestionState
    let number, total: Int
    let title: String
    let subject: String
    let isRemediationRound: Bool
    let agentState: LiveSessionState
    let onAnswer: (Set<String>) -> Bool
    let onAdvance: () -> Void
    let onGoLibrary: () -> Void
    let onWakeAgent: (QuizQuestionState) -> Void
    @State private var selection: Set<String> = []
    @State private var resultPulse = false
    @State private var showCelebration = false
    @State private var focusedOption: Int? = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                QuizJourneyMap(total: total, activeIndex: number - 1, answered: question.answered,
                               correct: question.correct, agentState: agentState) {
                    onWakeAgent(question)
                }
                .frame(height: 350)

                GeometryReader { lowerGeometry in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            if isRemediationRound {
                                Label("LET'S FIX A FEW THINGS", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .tracking(1.4)
                                    .foregroundStyle(.orange)
                            }
                            Text("QUESTION \(number) OF \(total)")
                                .font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1.8)
                                .foregroundStyle(.gray)
                            Text(subject.uppercased())
                                .font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1.2)
                                .foregroundStyle(.gray)
                            Text(markdownPrompt)
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .tint(.cyan)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 7) {
                                ForEach(1...5, id: \.self) { level in
                                    Capsule().fill(level <= question.difficulty ? Color.white : Color.white.opacity(0.15))
                                        .frame(width: 18, height: 4)
                                }
                                Text("LEVEL \(question.difficulty)")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.gray)
                            }

                            if question.answered && question.correct {
                                correctAnswerCard
                                actionButton(number == total ? "SEE RESULTS" : "CONTINUE", action: advance)
                            } else {
                                answerCarousel(height: optionCardHeight(maximum: lowerGeometry.size.height * 0.43))
                            }

                            if !question.answered {
                                HStack(spacing: 12) {
                                    Button(action: onGoLibrary) {
                                        Image(systemName: "books.vertical.fill")
                                            .font(.system(size: 15, weight: .bold))
                                            .frame(width: 52, height: 52)
                                            .foregroundStyle(.white)
                                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                                    }
                                    Spacer(minLength: 8)
                                    actionButton("SUBMIT ANSWER") { submit() }
                                        .frame(maxWidth: 220)
                                        .disabled(selection.isEmpty)
                                        .opacity(selection.isEmpty ? 0.38 : 1)
                                }
                            } else if !question.correct {
                                feedback
                                actionButton(number == total ? "SEE RESULTS" : "CONTINUE", action: advance)
                            }
                        }
                        .frame(minHeight: max(lowerGeometry.size.height - 42, 0), alignment: .bottom)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .padding(.bottom, 24)
                    }
                    .background(Color.black)
                }
            }

            if showCelebration {
                ZStack {
                    ConfettiBurst(correct: question.correct)
                    QuizResultBurst(correct: question.correct)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear { selection = question.selectedAnswers }
        .sensoryFeedback(question.correct ? .success : .error, trigger: resultPulse)
    }

    private func answerCarousel(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 13) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            choice(option, index: index)
                                .containerRelativeFrame(.horizontal, count: 1, spacing: 13)
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $focusedOption)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                HStack {
                    carouselArrow("chevron.left", enabled: (focusedOption ?? 0) > 0) {
                        moveOption(by: -1, proxy: proxy)
                    }
                    Spacer()
                    carouselArrow("chevron.right", enabled: (focusedOption ?? 0) < question.options.count - 1) {
                        moveOption(by: 1, proxy: proxy)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: height)
        }
    }

    private func carouselArrow(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .frame(width: 32, height: 52)
                .foregroundStyle(.white)
                .background(.black.opacity(0.42), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.16)))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.22)
    }

    private func moveOption(by offset: Int, proxy: ScrollViewProxy) {
        let next = min(max((focusedOption ?? 0) + offset, 0), max(question.options.count - 1, 0))
        focusedOption = next
        withAnimation(.easeInOut(duration: 0.28)) { proxy.scrollTo(next, anchor: .center) }
    }

    private func optionCardHeight(maximum: CGFloat) -> CGFloat {
        let longest = question.options.map(\.count).max() ?? 0
        let estimatedLines = max(2, Int(ceil(Double(longest) / 31.0)))
        let desired = 92 + CGFloat(estimatedLines * 23)
        return min(max(desired, 150), max(maximum, 150))
    }

    private var correctAnswerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("CORRECT ANSWER", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.2)
            Text(question.selectedAnswers.sorted().joined(separator: " • "))
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.green.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }

    private var markdownPrompt: AttributedString {
        (try? AttributedString(markdown: question.prompt)) ?? AttributedString(question.prompt)
    }

    private func choice(_ option: String, index: Int) -> some View {
        let selected = selection.contains(option) || question.selectedAnswers.contains(option)
        return Button {
            guard !question.answered else { return }
            if question.type == "checkbox" {
                if selected { selection.remove(option) } else { selection.insert(option) }
            } else {
                selection = [option]
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(String(UnicodeScalar(65 + index)!))
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .frame(width: 31, height: 31)
                        .background(selected ? Color.white : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(selected ? .black : .white)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                }
                Text(option)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(selected ? Color(red: 0.035, green: 0.15, blue: 0.31) : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 19))
        }.buttonStyle(.plain)
    }

    private var feedback: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: question.correct ? "checkmark.circle.fill" : "xmark.circle.fill").font(.title)
            VStack(alignment: .leading, spacing: 5) {
                Text(question.correct ? "NICE WORK" : "NOT QUITE")
                    .font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1.5)
                Text(question.explanation).font(.subheadline)
            }
        }
        .foregroundStyle(question.correct ? Color.green : Color.red)
        .padding(17).frame(maxWidth: .infinity, alignment: .leading)
        .background((question.correct ? Color.green : Color.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: question.answered)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .black, design: .monospaced)).tracking(1.5)
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .foregroundStyle(.black).background(.white, in: RoundedRectangle(cornerRadius: 13))
        }
    }

    private func submit() {
        let isCorrect = onAnswer(selection)
        resultPulse.toggle()
        UINotificationFeedbackGenerator().notificationOccurred(isCorrect ? .success : .error)
        QuizFeedbackPlayer.shared.play(isCorrect ? .success : .error)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.62)) { showCelebration = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            withAnimation(.easeOut(duration: 0.25)) { showCelebration = false }
        }
    }

    private func advance() {
        QuizFeedbackPlayer.shared.play(.progress)
        onAdvance()
    }
}

private struct CubeMascotView: UIViewRepresentable {
    let state: LiveSessionState
    let isRequestingMaterial: Bool
    var slowlySpinning = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.scene = context.coordinator.scene
        view.isUserInteractionEnabled = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        context.coordinator.update(for: state, isRequestingMaterial: isRequestingMaterial, slowlySpinning: slowlySpinning)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(for: state, isRequestingMaterial: isRequestingMaterial, slowlySpinning: slowlySpinning)
    }

    final class Coordinator {
        let scene = SCNScene()
        private let cube = SCNNode()
        private let face = SCNNode()
        private let openEyes = SCNNode()
        private let closedEyes = SCNNode()
        private let folder = SCNNode()
        private let drawerCavity = SCNNode()
        private var currentState: LiveSessionState?
        private var currentMaterialRequest = false
        private var currentSlowSpin = false

        init() {
            let box = SCNBox(width: 2.25, height: 2.25, length: 2.25, chamferRadius: 0.18)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.white
            material.metalness.contents = 0.05
            material.roughness.contents = 0.28
            box.materials = [material]
            cube.geometry = box
            cube.eulerAngles = SCNVector3(-0.38, 0.62, 0.08)
            scene.rootNode.addChildNode(cube)
            addFace()
            addFolderBack()

            let key = SCNLight()
            key.type = .omni
            key.intensity = 1_100
            key.color = UIColor.white
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.position = SCNVector3(-3, 4, 5)
            scene.rootNode.addChildNode(keyNode)

            let rim = SCNLight()
            rim.type = .omni
            rim.intensity = 650
            rim.color = UIColor(white: 0.45, alpha: 1)
            let rimNode = SCNNode()
            rimNode.light = rim
            rimNode.position = SCNVector3(4, -2, -3)
            scene.rootNode.addChildNode(rimNode)

            let camera = SCNCamera()
            camera.fieldOfView = 38
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0, 7.8)
            scene.rootNode.addChildNode(cameraNode)
        }

        private func addFace() {
            for x: Float in [-0.43, 0.43] {
                let eye = SCNNode(geometry: SCNSphere(radius: 0.19))
                eye.geometry?.firstMaterial?.diffuse.contents = UIColor.black
                eye.scale = SCNVector3(1, 1.18, 0.22)
                eye.position = SCNVector3(x, 0.28, 1.13)
                openEyes.addChildNode(eye)

                let sparkle = SCNNode(geometry: SCNSphere(radius: 0.045))
                sparkle.geometry?.firstMaterial?.diffuse.contents = UIColor.white
                sparkle.position = SCNVector3(x - 0.045, 0.34, 1.175)
                openEyes.addChildNode(sparkle)

                let lidGeometry = SCNCapsule(capRadius: 0.035, height: 0.42)
                lidGeometry.firstMaterial?.diffuse.contents = UIColor.black
                let lid = SCNNode(geometry: lidGeometry)
                lid.scale = SCNVector3(1, 1, 0.3)
                lid.eulerAngles.z = .pi / 2
                lid.position = SCNVector3(x, 0.24, 1.145)
                closedEyes.addChildNode(lid)
            }
            face.addChildNode(openEyes)
            face.addChildNode(closedEyes)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: -0.38, y: 0.08))
            path.addCurve(to: CGPoint(x: 0.38, y: 0.08), controlPoint1: CGPoint(x: -0.20, y: -0.31), controlPoint2: CGPoint(x: 0.20, y: -0.31))
            path.addLine(to: CGPoint(x: 0.38, y: 0))
            path.addCurve(to: CGPoint(x: -0.38, y: 0), controlPoint1: CGPoint(x: 0.18, y: -0.20), controlPoint2: CGPoint(x: -0.18, y: -0.20))
            path.close()
            let mouthGeometry = SCNShape(path: path, extrusionDepth: 0.028)
            mouthGeometry.firstMaterial?.diffuse.contents = UIColor.black
            let mouth = SCNNode(geometry: mouthGeometry)
            mouth.position = SCNVector3(0, -0.38, 1.14)
            face.addChildNode(mouth)
            cube.addChildNode(face)
        }

        private func addFolderBack() {
            let folderYellow = UIColor(red: 1.0, green: 0.76, blue: 0.20, alpha: 1)
            let folderBlue = UIColor(red: 0.26, green: 0.68, blue: 0.96, alpha: 1)
            let cavity = SCNBox(width: 1.72, height: 1.0, length: 0.10, chamferRadius: 0.12)
            cavity.firstMaterial?.diffuse.contents = UIColor(red: 0.035, green: 0.09, blue: 0.13, alpha: 1)
            let cavityNode = SCNNode(geometry: cavity)
            cavityNode.position = SCNVector3(0, -0.30, -1.16)
            drawerCavity.addChildNode(cavityNode)
            drawerCavity.opacity = 0
            cube.addChildNode(drawerCavity)

            let base = SCNBox(width: 1.52, height: 0.12, length: 0.94, chamferRadius: 0.04)
            base.firstMaterial?.diffuse.contents = folderBlue
            let baseNode = SCNNode(geometry: base)
            baseNode.position = SCNVector3(0, -0.76, -1.52)
            folder.addChildNode(baseNode)

            for x: Float in [-0.70, 0.70] {
                let side = SCNBox(width: 0.10, height: 0.72, length: 0.94, chamferRadius: 0.035)
                side.firstMaterial?.diffuse.contents = folderBlue
                let sideNode = SCNNode(geometry: side)
                sideNode.position = SCNVector3(x, -0.43, -1.52)
                folder.addChildNode(sideNode)
            }

            let front = SCNBox(width: 1.68, height: 0.66, length: 0.14, chamferRadius: 0.10)
            front.firstMaterial?.diffuse.contents = folderYellow
            front.firstMaterial?.metalness.contents = 0.06
            front.firstMaterial?.roughness.contents = 0.28
            let frontNode = SCNNode(geometry: front)
            frontNode.position = SCNVector3(0, -0.48, -2.0)
            folder.addChildNode(frontNode)

            let handle = SCNBox(width: 0.50, height: 0.12, length: 0.10, chamferRadius: 0.05)
            handle.firstMaterial?.diffuse.contents = folderBlue
            let handleNode = SCNNode(geometry: handle)
            handleNode.position = SCNVector3(0, -0.40, -2.10)
            folder.addChildNode(handleNode)

            let fileColors: [UIColor] = [
                UIColor(red: 0.98, green: 0.42, blue: 0.35, alpha: 1),
                UIColor(red: 0.42, green: 0.84, blue: 0.68, alpha: 1),
                UIColor(red: 0.55, green: 0.58, blue: 0.98, alpha: 1),
                UIColor(red: 0.98, green: 0.70, blue: 0.35, alpha: 1)
            ]
            for (index, color) in fileColors.enumerated() {
                let file = SCNBox(width: 0.24, height: 0.72 + CGFloat(index % 2) * 0.10, length: 0.055, chamferRadius: 0.025)
                file.firstMaterial?.diffuse.contents = color
                let fileNode = SCNNode(geometry: file)
                fileNode.position = SCNVector3(-0.47 + Float(index) * 0.31, -0.34, -1.52 + Float(index % 2) * 0.08)
                fileNode.eulerAngles.x = -.pi / 12
                folder.addChildNode(fileNode)
            }
            folder.opacity = 0
            cube.addChildNode(folder)
        }

        func update(for state: LiveSessionState, isRequestingMaterial: Bool, slowlySpinning: Bool) {
            guard currentState != state || currentMaterialRequest != isRequestingMaterial || currentSlowSpin != slowlySpinning else { return }
            // Once the drawer is open, voice state updates must not restart its
            // opening animation. Gemini can still emit speaking/turn-complete
            // events around a material tool call, which previously made the
            // files repeatedly disappear into the cavity and slide back out.
            if isRequestingMaterial, currentMaterialRequest, currentSlowSpin == slowlySpinning {
                currentState = state
                return
            }
            currentState = state
            currentMaterialRequest = isRequestingMaterial
            currentSlowSpin = slowlySpinning
            cube.removeAllActions()
            face.removeAllActions()
            folder.removeAllActions()

            if isRequestingMaterial {
                face.runAction(.fadeOut(duration: 0.22))
                drawerCavity.runAction(.fadeIn(duration: 0.22))
                folder.opacity = 1
                folder.position = SCNVector3(0, 0, 0.54)
                folder.eulerAngles = SCNVector3(-0.08, 0.10, -0.025)
                cube.runAction(.sequence([
                    .rotateTo(x: -0.12, y: .pi - 0.18, z: 0.035, duration: 0.65, usesShortestUnitArc: true),
                    .run { [weak self] _ in
                        self?.folder.runAction(.move(to: SCNVector3(0, 0, -0.16), duration: 0.6))
                    }
                ]))
                return
            }

            face.opacity = 1
            folder.opacity = 0
            drawerCavity.opacity = 0
            folder.position = SCNVector3Zero
            folder.eulerAngles = SCNVector3Zero
            openEyes.opacity = state == .disconnected ? 0 : 1
            closedEyes.opacity = state == .disconnected ? 1 : 0
            cube.scale = SCNVector3(1, 1, 1)

            if slowlySpinning {
                openEyes.opacity = 1
                closedEyes.opacity = 0
                cube.eulerAngles = SCNVector3(-0.28, 0.3, 0.03)
                cube.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 12)))
                return
            }

            switch state {
            case .disconnected:
                cube.eulerAngles = SCNVector3(-0.38, 0.62, 0.08)
                cube.runAction(.repeatForever(.sequence([
                    .moveBy(x: 0, y: 0.13, z: 0, duration: 1.8),
                    .moveBy(x: 0, y: -0.13, z: 0, duration: 1.8)
                ])))
            case .connecting:
                cube.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 1.6)))
            case .listening:
                cube.runAction(.repeatForever(.sequence([
                    .rotateTo(x: -0.3, y: 0.78, z: 0.04, duration: 1.2, usesShortestUnitArc: true),
                    .rotateTo(x: -0.4, y: 0.52, z: -0.04, duration: 1.2, usesShortestUnitArc: true)
                ])))
            case .speaking:
                cube.runAction(.repeatForever(.sequence([
                    .scale(to: 1.1, duration: 0.22), .scale(to: 0.96, duration: 0.22), .scale(to: 1.04, duration: 0.22)
                ])))
            }
        }
    }
}

private struct AgentConfirmationView: View {
    let confirmation: AgentConfirmation
    let onSave: (String) -> Void
    @State private var value: String
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    init(confirmation: AgentConfirmation, onSave: @escaping (String) -> Void) {
        self.confirmation = confirmation
        self.onSave = onSave
        _value = State(initialValue: confirmation.heardValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: confirmation.kind == .learnerName ? "person.fill" : "books.vertical.fill")
                Text(confirmation.kind == .learnerName ? "PLAYER PROFILE" : "NEW SUBJECT")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(2)
                Spacer()
                Text("SIRIUS EXTRACTED")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.5))
            }
            .foregroundStyle(.black)
            .padding(18)
            .background(.white)

            VStack(spacing: 22) {
                Text(confirmation.kind == .learnerName ? "Is this your name?" : "Study this subject?")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.gray)

                if isEditing {
                    TextField(confirmation.kind == .learnerName ? "Your name" : "Subject", text: $value)
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isFocused)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(.white).frame(height: 2) }
                        .onSubmit(save)
                } else {
                    Text(value)
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                }

                if isEditing {
                    Button(action: save) {
                        Label(confirmation.kind == .learnerName ? "SAVE PROFILE" : "SAVE SUBJECT", systemImage: "checkmark")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .tracking(1.5)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .foregroundStyle(.black)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(trimmedValue.isEmpty)
                } else {
                    HStack(spacing: 12) {
                        Button {
                            isEditing = true
                            DispatchQueue.main.async { isFocused = true }
                        } label: {
                            Text("NOT QUITE")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                                .tracking(1.2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 17)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.5), lineWidth: 1.5))
                        }
                        Button(action: save) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 20, weight: .black))
                                .frame(width: 62, height: 50)
                                .foregroundStyle(.black)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(24)
            .background(Color(white: 0.075))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.3), lineWidth: 1))
        .shadow(color: .white.opacity(0.12), radius: 30)
    }

    private var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func save() { guard !trimmedValue.isEmpty else { return }; onSave(trimmedValue) }
}

private struct APIKeyView: View {
    @ObservedObject var tutor: LiveTutorViewModel
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var elevenLabsKey = ""
    @State private var elevenLabsVoiceID = ""
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Paste your API key", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Gemini developer key")
                } footer: {
                    Text("For development only. Production builds should use short-lived tokens from your backend.")
                }
                Section("Model") { Text(LiveAPIConfiguration.model).foregroundStyle(.secondary) }
                Section {
                    SecureField("Paste your ElevenLabs API key", text: $elevenLabsKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("ElevenLabs key")
                } footer: {
                    Text("Stored securely for the upcoming narrated lesson and quiz audio system.")
                }
                Section("ElevenLabs voice") {
                    TextField("Voice ID", text: $elevenLabsVoiceID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Button("Reset Sirius", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Deletes learner data, subjects, imported PDFs, lessons, quizzes, indexes, and progress. API keys are preserved.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Gemini Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        tutor.saveAPIKey(apiKey)
                        tutor.saveElevenLabsKey(elevenLabsKey)
                        let voice = elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
                        ElevenLabsConfiguration.voiceID = voice.isEmpty ? ElevenLabsConfiguration.defaultVoiceID : voice
                        dismiss()
                    }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                apiKey = tutor.savedAPIKey ?? ""
                elevenLabsKey = tutor.savedElevenLabsKey ?? ""
                elevenLabsVoiceID = ElevenLabsConfiguration.voiceID
            }
            .alert("Reset everything?", isPresented: $confirmReset) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    onReset()
                    dismiss()
                }
            } message: {
                Text("This permanently deletes local profiles, study materials, lessons, quizzes, indexes, and progress. Your API keys remain saved.")
            }
        }
        .preferredColorScheme(.dark)
    }
}

private extension LiveSessionState {
    var mascotTitle: String {
        switch self {
        case .disconnected: "Ready?"
        case .connecting: "Waking up"
        case .listening: "I'm listening"
        case .speaking: "Thinking aloud"
        }
    }

    var mascotDetail: String {
        switch self {
        case .disconnected: "Tap the cube and tell me what you want to learn."
        case .connecting: "Connecting to your study session…"
        case .listening: "Talk naturally. Ask a question, or explain an idea to me."
        case .speaking: "I'll pause after one clear thought, then listen again."
        }
    }
}

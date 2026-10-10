import Foundation

enum LiveAPIConfiguration {
    nonisolated static let model = "gemini-3.8-live"
    nonisolated static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    nonisolated static let systemInstruction = """
    Your name is Sirius. You are a warm, rigorous study coach inside a voice-first learning harness.
    LANGUAGE POLICY: Always speak and write in English by default. Stay in English even if you hear an accent,
    background speech, a name, an isolated foreign word, a mistranscribed fragment, or source material containing
    another language. Never switch languages merely to mirror the learner or because automatic language detection
    suggests another language. You may switch only when the learner directly and explicitly asks you to use a named
    language. That request applies only to the current live session; a new session begins in English again. If the
    learner's language request is unclear, ask for clarification in English and remain in English.
    Help the student reason instead of merely giving answers.
    Ask one focused question at a time, adapt to their level, use short explanations and concrete examples,
    and check understanding before moving on. Never claim the student understands without evidence.
    If a request is unrelated to learning, remain helpful but gently keep the session focused.
    Keep each spoken turn concise. Never repeat a sentence or restart an explanation unless the student asks.
    After answering or asking one question, stop speaking and wait for the student.
    Make studying lively. Offer grounded explanations, live question-and-answer practice, teach-back, worked
    examples from the material, and quick checks. In live Q&A, ask one meaningful question, listen to the
    learner's reasoning, respond to what they actually said, and continue until they choose to stop.
    At the start of every general session, before speaking about classes, call list_subjects,
    list_learning_activities, and get_resume_context. The app deliberately does not inject the whole database
    into the prompt. Never automatically select or open the latest activity. Briefly name the previous session
    and two or three relevant choices, then ask what the learner wants: continue one, study a different topic,
    ask live questions, generate work, or schedule study. Wait for their answer. Only then call
    open_learning_activity for the exact activity they chose.
    Saved activity records are authoritative context. When the learner refers to an existing quiz or lesson,
    resolve it with list_learning_activities and get_learning_activity instead of asking them to repeat its book,
    class, or section. Use its material_id and section_id for calendar deep links and source extraction. For a
    requested new quiz set, retrieve every chunk of that saved activity's section and call create_quiz with 15
    fresh questions that avoid the prior question_prompts. Never wake a second voice session to regenerate work.
    Profile information must be gathered conversationally, never through a form. If the learner's name is
    not present in session context, introduce yourself as Sirius and ask what you should call them. Once they
    answer in a subsequent learner turn, extract only the person's name and call propose_learner_name with
    that clean name. Do not pass their whole sentence. Asking and
    proposing are always two separate turns: never ask a profile question and call its proposal tool in the
    same response. Do not claim it was saved until the tool succeeds. A missing active subject does not mean
    there are no saved classes. Check list_subjects first. If the learner names or clearly refers to a saved
    class, call select_subject silently; never call propose_subject and never show creation confirmation for an
    existing class. If their request is ambiguous among several saved classes, ask which saved class they mean.
    If exactly one saved class exists and the request clearly concerns their saved work, select it without asking
    them to create or confirm it. Only when the learner clearly supplies a genuinely new class that is absent
    from list_subjects may you call propose_subject. The subject argument must be the concise canonical name—not a
    transcript, conversational lead-in, or generic category when a specific course is present. For example,
    from “we're studying some computer science class, Principles of Programming Languages,” extract only
    “Principles of Programming Languages.” From “you can call me Max,” extract only “Max.” Never include text
    such as “we're studying,” “my class is,” “I want to study,” or “you can call me” in a proposal. Never infer
    a class from a chapter number, book request, or prior general context.
    You must teach strictly from the learner's imported materials, never from your general knowledge. Before
    teaching, identify the correct saved subject. If exactly one subject is supplied, use it; if there are none
    or several and the learner's request is ambiguous, ask which subject. Call list_materials before choosing a
    book. A material with available=false is missing locally and must not be selected. You must call
    list_materials for the confirmed subject before request_pdf_material. If the needed
    book is missing, briefly tell the learner that you need their PDF, then call request_pdf_material and wait
    for the import result. Verbally
    confirm the book with the learner. For a requested subsection, obtain both chapter and section; ask for the
    missing chapter rather than guessing. Use get_pdf_outline to resolve the exact bookmark, then
    extract_pdf_section. If it reports more than one content chunk, call it again for every chunk_index before
    creating a lesson; never build a supposedly complete chapter lesson from partial or truncated content.
    Inspect its title, pages, and content to verify it matches. Give the learner a very
    short, grounded preview using only that extracted content, then verbally confirm the topic. Only after the
    learner approves, ask whether they want curated lessons, quizzes, or both. Do not generate either yet.
    After the learner chooses, use save_lesson and/or create_quiz with a new unique operation_id for each intended
    activity. Reuse that same operation_id if a tool response must be retried; this prevents duplicate saved work.
    Before creating a quiz, retrieve every chunk
    of the selected bookmark. When the selected bookmark is a chapter or parent section, use its outline and
    extracted content to cover and combine concepts across its individual subsections rather than sampling only
    the opening pages. Every quiz set must contain exactly 15 substantial questions, rely only on extracted
    content, progress from easiest to hardest, and use a useful mix of multiple_choice, yes_no, and checkbox.
    Distribute the questions across all major concepts, definitions, formulas, examples, and subsection
    relationships in the selected material. Write each question prompt in concise Markdown when emphasis,
    inline code, a formula, or a short list improves clarity. Include a short source excerpt with each question
    for grounded hint assistance. Do not begin answering quiz questions conversationally after creation; finish
    any approved scheduling, call finish_study_setup, and let the dedicated quiz interface take over.
    Before generating the chosen lesson or quiz, offer to schedule it. If the learner wants scheduling, ask for
    their target date or deadline, desired study minutes per session, and sessions per day—one missing detail at
    a time. Call check_calendar_permission before any other calendar tool. Only after permission succeeds, call
    find_study_slots using the learner's constraints, verbally offer a concise selection of available times, and
    report any existing_sirius_study_events on the requested day or date range. If a day already contains a
    Sirius lesson or quiz, name it and ask whether the learner wants the new activity placed on that same day
    or on a different available day. Never silently stack study work. Wait for explicit approval of the proposed
    schedule. Keep the returned proposal_id. Generate and save the approved quiz or lesson, then use the returned
    activity_id with schedule_study_plan, the proposal_id, a unique operation_id, only approved times, and the
    exact source IDs, subject, and returned question_count or item_count. This ensures calendar links and the
    home-screen widget open the exact activity. Never create calendar events before approval. After the calendar
    schedule succeeds, ask whether the learner also wants a reminder two minutes before each approved session.
    Do not request notification permission or schedule reminders unless they explicitly say yes. If approved,
    call check_notification_permission and then schedule_activity_notifications with the exact same start times
    and activity metadata. After generation and any approved scheduling are complete, call finish_study_setup so voice turns
    off and the student can use the lesson or quiz. If scheduling is declined, generate and then finish setup.
    A saved lesson is a substantial, podcast-style chapter course—not a short summary. It must contain 6 to 16
    ordered segments, with at least 90 spoken words per segment. Cover the complete extracted chapter: learning
    goals, every major concept, all defined terms and keywords, every formula and variable (explained in words),
    assumptions, worked examples from the material, common confusions, connections between ideas, and a final
    synthesis. Do not omit formulas merely because they are awkward to narrate. Never invent content missing
    from the extracted material. Vary segment styles across at least three of: overview, concept_definition,
    deep_dive, formula_lab, worked_example, keyword_review, and recap. Each item needs a display title, one of
    those styles, and a clean narration script written to be spoken aloud. Expand symbols into natural speech,
    avoid markdown, and teach one coherent part of the chapter deeply. Every lesson and every quiz question must
    preserve the resolved material_id and section_id so it remains attached to its parent book and chapter.
    """
}

enum LiveAPIMessage {
    nonisolated static func setup(sessionContext: String? = nil) -> [String: Any] {
        let instruction = [LiveAPIConfiguration.systemInstruction, sessionContext]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return ["setup": [
            "model": "models/\(LiveAPIConfiguration.model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": "Kore"]]]
            ],
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "disabled": false,
                    "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                    "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH",
                    "prefixPaddingMs": 120,
                    "silenceDurationMs": 500
                ],
                "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                "turnCoverage": "TURN_INCLUDES_ONLY_ACTIVITY"
            ],
            "systemInstruction": ["parts": [["text": instruction]]],
            "tools": [["functionDeclarations": [
                [
                    "name": "list_subjects",
                    "description": "List the learner's saved classes. Always call this at general-session startup and before deciding a class is new.",
                    "parameters": ["type": "OBJECT", "properties": [:]]
                ],
                [
                    "name": "select_subject",
                    "description": "Select an existing saved class without showing a creation confirmation. The subject must exactly match a name returned by list_subjects.",
                    "parameters": ["type": "OBJECT", "properties": ["subject": ["type": "STRING"]], "required": ["subject"]]
                ],
                [
                    "name": "propose_learner_name",
                    "description": "Confirm and save only the learner's extracted name. Return a clean name, never their full spoken sentence.",
                    "parameters": [
                        "type": "OBJECT",
                        "properties": ["name": ["type": "STRING", "description": "Only the person's name, e.g. Max—not 'you can call me Max'."]],
                        "required": ["name"]
                    ]
                ],
                [
                    "name": "propose_subject",
                    "description": "Confirm and save only the concise canonical course or subject extracted from the learner's answer.",
                    "parameters": [
                        "type": "OBJECT",
                        "properties": ["subject": ["type": "STRING", "description": "Only the specific course name, e.g. Principles of Programming Languages—not the learner's full sentence or a broad category such as computer science."]],
                        "required": ["subject"]
                    ]
                ],
                [
                    "name": "request_pdf_material",
                    "description": "Show the learner a folder control to import a missing PDF for the confirmed subject.",
                    "parameters": ["type": "OBJECT", "properties": ["subject": ["type": "STRING"]], "required": ["subject"]]
                ],
                [
                    "name": "list_materials",
                    "description": "List imported PDF books, optionally filtered to a subject.",
                    "parameters": ["type": "OBJECT", "properties": ["subject": ["type": "STRING"]]]
                ],
                [
                    "name": "list_learning_activities",
                    "description": "List saved lessons and quizzes with stable activity IDs, source material/section IDs, completion progress, scores, and deep links. Use this before discussing existing work.",
                    "parameters": ["type": "OBJECT", "properties": [
                        "subject": ["type": "STRING", "description": "Optional exact subject filter."],
                        "kind": ["type": "STRING", "enum": ["quiz", "lesson"], "description": "Optional activity type filter."]
                    ]]
                ],
                [
                    "name": "get_learning_activity",
                    "description": "Get one saved quiz or lesson in detail. Quiz details include prior prompts for non-repetitive new-set generation; lesson details include its segments and progress.",
                    "parameters": ["type": "OBJECT", "properties": [
                        "activity_id": ["type": "STRING"],
                        "kind": ["type": "STRING", "enum": ["quiz", "lesson"]]
                    ], "required": ["activity_id", "kind"]]
                ],
                [
                    "name": "get_resume_context",
                    "description": "Return the previous study checkpoint and recent activities. Present choices and wait; never choose or open one automatically.",
                    "parameters": ["type": "OBJECT", "properties": [:]]
                ],
                [
                    "name": "open_learning_activity",
                    "description": "Open the exact saved lesson or quiz only after the learner explicitly chooses it.",
                    "parameters": ["type": "OBJECT", "properties": [
                        "activity_id": ["type": "STRING"],
                        "kind": ["type": "STRING", "enum": ["quiz", "lesson"]]
                    ], "required": ["activity_id", "kind"]]
                ],
                [
                    "name": "get_pdf_outline",
                    "description": "Get all bookmark chapters and nested sections with IDs and page ranges for one imported PDF.",
                    "parameters": ["type": "OBJECT", "properties": ["material_id": ["type": "STRING"]], "required": ["material_id"]]
                ],
                [
                    "name": "extract_pdf_section",
                    "description": "Extract one numbered content chunk for an exact bookmark section. Retrieve every chunk before generating a complete lesson.",
                    "parameters": ["type": "OBJECT", "properties": [
                        "material_id": ["type": "STRING"], "section_id": ["type": "STRING"],
                        "chunk_index": ["type": "INTEGER", "description": "Zero-based content chunk. Begin with 0, then retrieve through total_chunks minus one."]
                    ], "required": ["material_id", "section_id"]]
                ],
                [
                    "name": "check_calendar_permission",
                    "description": "Check calendar access and request iOS permission when it has not been decided. Always call this before calendar availability or scheduling tools.",
                    "parameters": ["type": "OBJECT", "properties": [:]]
                ],
                [
                    "name": "find_study_slots",
                    "description": "Read the learner's calendar and return genuinely free study start times between 8 AM and 9 PM, plus existing Sirius lessons and quizzes in the date range. Read existing study events back before proposing a schedule.",
                    "parameters": ["type": "OBJECT", "properties": [
                        "not_before": ["type": "STRING", "description": "ISO 8601 timestamp or YYYY-MM-DD"],
                        "deadline": ["type": "STRING", "description": "ISO 8601 timestamp or YYYY-MM-DD"],
                        "duration_minutes": ["type": "INTEGER"],
                        "sessions_per_day": ["type": "INTEGER"]
                    ], "required": ["not_before", "deadline", "duration_minutes", "sessions_per_day"]]
                ],
                [
                    "name": "schedule_study_plan",
                    "description": "Create the learner-approved study sessions with Sirius deep links in their calendar.",
                    "parameters": ["type": "OBJECT", "properties": [
                        "title": ["type": "STRING"],
                        "start_times": ["type": "ARRAY", "items": ["type": "STRING"]],
                        "duration_minutes": ["type": "INTEGER"],
                        "activity_type": ["type": "STRING", "enum": ["quiz", "lesson"]],
                        "material_id": ["type": "STRING"],
                        "section_id": ["type": "STRING"],
                        "subject": ["type": "STRING"], "item_count": ["type": "INTEGER"],
                        "activity_id": ["type": "STRING"], "proposal_id": ["type": "STRING"],
                        "operation_id": ["type": "STRING"]
                    ], "required": ["title", "start_times", "duration_minutes", "activity_type", "material_id", "section_id", "subject", "item_count", "activity_id", "proposal_id", "operation_id"]]
                ],
                [
                    "name": "check_notification_permission",
                    "description": "Check or request local notification permission only after the learner explicitly approves two-minute reminders.",
                    "parameters": ["type": "OBJECT", "properties": [:]]
                ],
                [
                    "name": "schedule_activity_notifications",
                    "description": "Schedule a local notification two minutes before each approved study time. Every notification opens the exact saved activity.",
                    "parameters": ["type": "OBJECT", "properties": [
                        "title": ["type": "STRING"],
                        "start_times": ["type": "ARRAY", "items": ["type": "STRING"]],
                        "activity_type": ["type": "STRING", "enum": ["quiz", "lesson"]],
                        "material_id": ["type": "STRING"], "section_id": ["type": "STRING"],
                        "activity_id": ["type": "STRING"]
                    ], "required": ["title", "start_times", "activity_type", "material_id", "section_id", "activity_id"]]
                ],
                [
                    "name": "create_quiz",
                    "description": "Save exactly 15 comprehensive grounded questions spanning all retrieved chunks and subsections, then enter offline interactive quiz mode.",
                    "parameters": ["type": "OBJECT", "properties": ["operation_id": ["type": "STRING"], "quiz": [
                        "type": "OBJECT",
                        "properties": [
                            "title": ["type": "STRING"], "subject": ["type": "STRING"],
                            "material_id": ["type": "STRING"], "section_id": ["type": "STRING"],
                            "questions": ["type": "ARRAY", "items": ["type": "OBJECT", "properties": [
                                "type": ["type": "STRING", "enum": ["multiple_choice", "yes_no", "checkbox"]],
                                "prompt": ["type": "STRING"],
                                "options": ["type": "ARRAY", "items": ["type": "STRING"]],
                                "correct_answers": ["type": "ARRAY", "items": ["type": "STRING"]],
                                "difficulty": ["type": "INTEGER"], "explanation": ["type": "STRING"],
                                "source_excerpt": ["type": "STRING"]
                            ], "required": ["type", "prompt", "options", "correct_answers", "difficulty", "explanation", "source_excerpt"]]]
                        ], "required": ["title", "subject", "material_id", "section_id", "questions"]
                    ]], "required": ["operation_id", "quiz"]]
                ],
                [
                    "name": "save_lesson",
                    "description": "Save a comprehensive grounded chapter course as varied podcast-style segments and generate ElevenLabs audio for each segment.",
                    "parameters": ["type": "OBJECT", "properties": ["operation_id": ["type": "STRING"], "lesson": [
                        "type": "OBJECT", "properties": [
                            "title": ["type": "STRING"], "subject": ["type": "STRING"],
                            "material_id": ["type": "STRING"], "section_id": ["type": "STRING"],
                            "items": ["type": "ARRAY", "items": ["type": "OBJECT", "properties": [
                                "title": ["type": "STRING"],
                                "style": ["type": "STRING", "enum": ["overview", "concept_definition", "deep_dive", "formula_lab", "worked_example", "keyword_review", "recap"]],
                                "script": ["type": "STRING"]
                            ], "required": ["title", "style", "script"]]]
                        ], "required": ["title", "subject", "material_id", "section_id", "items"]
                    ]], "required": ["operation_id", "lesson"]]
                ],
                [
                    "name": "finish_study_setup",
                    "description": "End the live setup session after generation and any approved calendar scheduling are complete.",
                    "parameters": ["type": "OBJECT", "properties": [:]]
                ]
            ]]],
            "inputAudioTranscription": [
                "languageCodes": ["en-US"],
                "customVocabulary": ["Sirius", "chapter", "section", "subsection", "quiz", "quizlet"],
                "mode": "SMART"
            ],
            "outputAudioTranscription": [:]
        ]]
    }

    nonisolated static func text(_ text: String) -> [String: Any] {
        ["clientContent": [
            "turns": [["role": "user", "parts": [["text": text]]]],
            "turnComplete": true
        ]]
    }

    nonisolated static func audio(_ base64: String) -> [String: Any] {
        ["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": base64]]]
    }

    nonisolated static let audioStreamEnd: [String: Any] = ["realtimeInput": ["audioStreamEnd": true]]
}

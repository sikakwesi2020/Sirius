# Sirius

Sirius is an open-source, voice-first study companion for iPhone and iPad. It turns a student's own PDF textbooks into grounded podcast-style lessons and interactive quizzes, then helps them return through calendar plans, local notifications, deep links, and a Home Screen widget.

There is no conventional chat box. Students wake the Sirius cube and speak naturally. Gemini Live handles the conversation while deterministic local tools manage profiles, materials, bookmarks, learning progress, scheduling, and navigation.

## Highlights

- Native Gemini Live voice conversation with interruption support
- On-device learner, class, lesson, quiz, and progress persistence using Core Data
- PDF bookmark extraction with exact chapter, subsection, and page ranges
- Source-grounded generation from imported materials
- Podcast-style lesson courses with ElevenLabs narration and background playback
- Fifteen-question quiz sets ordered from easiest to hardest
- Multiple choice, yes/no, and checkbox questions with remediation rounds
- Contextual lesson Q&A and question hints without revealing answers
- Calendar availability checks and approved study-plan creation
- Two-minute local notifications linked to exact activities
- Home Screen widget showing the next scheduled lesson or quiz
- `sirius://` deep links for lessons, quizzes, calendar events, widgets, and notifications

## Requirements

- Xcode 26 or newer and the iOS 26 SDK
- An Apple development team for device builds, App Groups, notifications, and calendar access
- A [Gemini API key](https://aistudio.google.com/apikey)
- An ElevenLabs API key and voice ID for narrated lessons

## Getting started

1. Clone and open the project:

   ```bash
   git clone https://github.com/sikakwesi2020/Sirius.git
   cd Sirius
   open Sirius.xcodeproj
   ```

2. In Xcode, select your development team for both `Sirius` and `SiriusWidget`.
3. Under **Signing & Capabilities**, verify both targets share `group.fobia.readme.Maximus.Sirius`.
4. Run the `Sirius` scheme on an iPhone or iPad.
5. Open **Library → AI Setup** and save your Gemini and ElevenLabs credentials.

Credentials are stored in the device Keychain and are never written into source files or UserDefaults. For production distribution, use short-lived, server-issued credentials rather than permanent provider keys in the client.

## Learning flow

1. Sirius checks saved classes and recent study checkpoints.
2. The student chooses whether to continue an existing activity or begin something new.
3. Sirius resolves the exact class, PDF, chapter, and subsection conversationally.
4. The local harness extracts and verifies every required PDF chunk.
5. The student chooses lessons, quizzes, or both.
6. Sirius optionally finds calendar availability and waits for explicit approval.
7. The generated activity is saved with stable source and activity identifiers.
8. Approved calendar events, notifications, and widget entries link back to that exact activity.

## Architecture

| Area | Key files |
| --- | --- |
| Gemini Live transport | `GeminiLiveClient.swift`, `LiveAPIConfiguration.swift` |
| Voice and orchestration | `AudioPipeline.swift`, `LiveTutorViewModel.swift` |
| Profiles and persistence | `ProfileStore.swift`, `LearningStore.swift`, `Persistence.swift` |
| PDF tools | `PDFSectionExtractor.swift`, `MaterialLibrary.swift`, `StoredFileLocator.swift` |
| Narrated lessons | `ElevenLabsClient.swift` |
| Scheduling | `CalendarScheduler.swift`, `NotificationScheduler.swift` |
| Widget data | `SharedStudyActivityStore.swift`, `SiriusWidget/` |
| Main interface | `ContentView.swift` |

The AI does not receive the full local database in its system prompt. It discovers saved classes and activities through narrow tools, retrieves source sections deterministically, and receives only the context needed for the current interaction.

## Privacy

- Imported PDFs, generated audio, profiles, and progress remain in the app's local container.
- API credentials are stored in Keychain.
- Calendar events and notifications are created only after user approval.
- Resetting study data preserves API credentials unless the user removes them separately.
- The app currently talks directly to Gemini and ElevenLabs; review provider privacy terms before using real student data.

## Deep links

```text
sirius://lesson?activity_id=<UUID>&material_id=<UUID>&section_id=<UUID>
sirius://quiz?activity_id=<UUID>&material_id=<UUID>&section_id=<UUID>
```

These exact activity links are used by calendar events, notifications, and the widget.

## Building and testing

```bash
xcodebuild \
  -project Sirius.xcodeproj \
  -scheme Sirius \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

Microphone capture, calendar authorization, notifications, widgets, background audio, and deep links should also be tested on a physical device.

## Contributing

Issues and pull requests are welcome. Keep generated activities grounded in student-provided materials, preserve explicit confirmation before persistent or external changes, and include tests for deterministic tools where practical.

## License

Sirius is available under the [MIT License](LICENSE).

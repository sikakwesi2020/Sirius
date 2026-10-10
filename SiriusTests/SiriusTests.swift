import Foundation
import PDFKit
import Testing
import UIKit
@testable import Sirius

struct SiriusTests {
    @Test func setupUsesLiveModelAndAudioModality() throws {
        let setup = try #require(LiveAPIMessage.setup()["setup"] as? [String: Any])
        #expect(setup["model"] as? String == "models/\(LiveAPIConfiguration.model)")
        let generation = try #require(setup["generationConfig"] as? [String: Any])
        #expect(generation["responseModalities"] as? [String] == ["AUDIO"])
        #expect(setup["inputAudioTranscription"] != nil)
        #expect(setup["outputAudioTranscription"] != nil)
        #expect(JSONSerialization.isValidJSONObject(LiveAPIMessage.setup()))
    }

    @Test func setupDeclaresConfirmedProfileTools() throws {
        let setup = try #require(LiveAPIMessage.setup()["setup"] as? [String: Any])
        let tools = try #require(setup["tools"] as? [[String: Any]])
        let declarations = try #require(tools.first?["functionDeclarations"] as? [[String: Any]])
        let names = declarations.compactMap { $0["name"] as? String }
        #expect(names.contains("propose_learner_name"))
        #expect(names.contains("propose_subject"))
        #expect(names.contains("list_subjects"))
        #expect(names.contains("list_learning_activities"))
        #expect(names.contains("get_resume_context"))
        #expect(names.contains("open_learning_activity"))
        #expect(names.contains("get_learning_activity"))
        #expect(names.contains("check_calendar_permission"))
        #expect(names.contains("find_study_slots"))
        #expect(names.contains("schedule_study_plan"))
        #expect(names.contains("finish_study_setup"))
        #expect(names.contains("create_quiz"))
        #expect(names.contains("save_lesson"))
        let instruction = try #require(setup["systemInstruction"] as? [String: Any])
        let parts = try #require(instruction["parts"] as? [[String: Any]])
        #expect((parts.first?["text"] as? String)?.contains("Your name is Sirius") == true)
        #expect((parts.first?["text"] as? String)?.contains("never automatically open") == true)
        #expect((parts.first?["text"] as? String)?.contains("Always speak and write in English by default") == true)
        #expect((parts.first?["text"] as? String)?.contains("two or three closely related") == true)
        #expect((parts.first?["text"] as? String)?.contains("Never ask more than three") == true)
        let transcription = try #require(setup["inputAudioTranscription"] as? [String: Any])
        #expect(transcription["languageCodes"] as? [String] == ["en-US"])
        #expect(transcription["mode"] as? String == "SMART")
    }

    @Test func textPromptCompletesAUserTurn() throws {
        let root = LiveAPIMessage.text("Teach me fractions")
        let content = try #require(root["clientContent"] as? [String: Any])
        #expect(content["turnComplete"] as? Bool == true)
        let turns = try #require(content["turns"] as? [[String: Any]])
        #expect(turns.first?["role"] as? String == "user")
    }

    @Test func audioUsesGeminisRequiredInputRate() throws {
        let root = LiveAPIMessage.audio(Data([0, 1, 2]).base64EncodedString())
        let realtime = try #require(root["realtimeInput"] as? [String: Any])
        let audio = try #require(realtime["audio"] as? [String: Any])
        #expect(audio["mimeType"] as? String == "audio/pcm;rate=16000")
    }

    @Test func pdfBookmarksProduceChapterAndSubsectionRanges() throws {
        let url = try makeBookmarkedPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let sections = try PDFSectionExtractor().tableOfContents(from: url)
        #expect(sections.map(\.title) == ["Chapter 1", "Chapter 2"])
        #expect(sections[0].startPage == 1)
        #expect(sections[0].endPage == 4)
        #expect(sections[0].children[0].title == "Section 1.1")
        #expect(sections[0].children[0].startPage == 2)
        #expect(sections[0].children[0].endPage == 4)
        #expect(sections[1].startPage == 5)
        #expect(sections[1].endPage == 6)
    }

    private func makeBookmarkedPDF() throws -> URL {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { context in
            for page in 1...6 {
                context.beginPage()
                ("Page \(page)" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: nil)
            }
        }
        let document = try #require(PDFDocument(data: data))
        let root = PDFOutline()
        let chapterOne = outline("Chapter 1", page: 0, document: document)
        chapterOne.insertChild(outline("Section 1.1", page: 1, document: document), at: 0)
        root.insertChild(chapterOne, at: 0)
        root.insertChild(outline("Chapter 2", page: 4, document: document), at: 1)
        document.outlineRoot = root

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sirius-outline-\(UUID().uuidString).pdf")
        try #require(document.dataRepresentation()).write(to: output)
        return output
    }

    private func outline(_ title: String, page index: Int, document: PDFDocument) -> PDFOutline {
        let outline = PDFOutline()
        outline.label = title
        outline.destination = PDFDestination(page: document.page(at: index)!, at: .zero)
        return outline
    }
}

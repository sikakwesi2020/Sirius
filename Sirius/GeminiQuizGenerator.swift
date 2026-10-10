import Foundation

struct GeminiQuizGenerator {
    enum GenerationError: LocalizedError {
        case invalidEndpoint, invalidResponse, emptyResponse, server(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "The quiz generation endpoint is invalid."
            case .invalidResponse: "Gemini returned an unreadable quiz response."
            case .emptyResponse: "Gemini did not return a quiz. Please try again."
            case .server(let message): "Gemini could not generate the quiz. \(message)"
            }
        }
    }

    func generate(apiKey: String, title: String, subject: String, materialID: String,
                  sectionID: String, source: String, previousPrompts: [String]) async throws -> String {
        guard var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        ) else { throw GenerationError.invalidEndpoint }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw GenerationError.invalidEndpoint }

        let prompt = """
        Create a fresh replacement quiz strictly from the supplied study material.
        Return exactly 15 substantial questions, ordered easiest to hardest, with difficulty values from 1 to 5.
        Use a useful mixture of multiple_choice, yes_no, and checkbox questions. Cover the complete section:
        definitions, keywords, concepts, formulas, examples, and relationships between subsections. Use concise
        Markdown in prompts when it improves clarity. Every correct answer must exactly match one option. Include
        a short verbatim source excerpt and a grounded explanation for every question. Avoid substantially repeating
        these previous prompts: \(previousPrompts.joined(separator: " | ")).

        Quiz metadata (copy these values exactly):
        title: \(title) — New Set
        subject: \(subject)
        material_id: \(materialID)
        section_id: \(sectionID)

        SOURCE MATERIAL:
        ---
        \(source)
        ---
        """

        let questionSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "type": ["type": "STRING", "enum": ["multiple_choice", "yes_no", "checkbox"]],
                "prompt": ["type": "STRING"],
                "options": ["type": "ARRAY", "items": ["type": "STRING"]],
                "correct_answers": ["type": "ARRAY", "items": ["type": "STRING"]],
                "difficulty": ["type": "INTEGER"],
                "explanation": ["type": "STRING"],
                "source_excerpt": ["type": "STRING"]
            ],
            "required": ["type", "prompt", "options", "correct_answers", "difficulty", "explanation", "source_excerpt"]
        ]
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "title": ["type": "STRING"], "subject": ["type": "STRING"],
                "material_id": ["type": "STRING"], "section_id": ["type": "STRING"],
                "questions": ["type": "ARRAY", "minItems": 15, "maxItems": 15, "items": questionSchema]
            ],
            "required": ["title", "subject", "material_id", "section_id", "questions"]
        ]
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0.75,
                "responseMimeType": "application/json",
                "responseSchema": schema
            ]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = root?["error"] as? [String: Any]
            throw GenerationError.server(error?["message"] as? String ?? "HTTP \(http.statusCode)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first,
              !text.isEmpty else { throw GenerationError.emptyResponse }
        return text
    }
}

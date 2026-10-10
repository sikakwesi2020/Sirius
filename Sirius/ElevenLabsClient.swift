import Foundation

actor ElevenLabsClient {
    func synthesize(text: String, apiKey: String, voiceID: String) async throws -> Data {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVoiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !cleanVoiceID.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ElevenLabsError.invalidConfiguration
        }
        guard var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(cleanVoiceID)") else {
            throw ElevenLabsError.invalidConfiguration
        }
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        guard let url = components.url else { throw ElevenLabsError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cleanKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": "eleven_v4",
            "voice_settings": ["stability": 0.55, "similarity_boost": 0.78]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ElevenLabsError.requestFailed(status: 0, detail: "The server returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ElevenLabsError.requestFailed(status: http.statusCode, detail: Self.errorDetail(from: data))
        }
        guard !data.isEmpty else { throw ElevenLabsError.emptyAudio }
        return data
    }

    private static func errorDetail(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "Unknown response"
        }
        if let detail = object["detail"] as? [String: Any] {
            return (detail["message"] as? String) ?? String(describing: detail)
        }
        return (object["detail"] as? String) ?? (object["message"] as? String) ?? "Unknown response"
    }
}

enum ElevenLabsError: LocalizedError {
    case invalidConfiguration, requestFailed(status: Int, detail: String), emptyAudio
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The ElevenLabs voice configuration is invalid."
        case .requestFailed(let status, let detail): "ElevenLabs request failed (HTTP \(status)): \(detail)"
        case .emptyAudio: "ElevenLabs returned an empty audio file."
        }
    }
}

enum ElevenLabsConfiguration {
    static let defaultVoiceID = "JBFqnCBsd6RMkjVDRZzb"
    static var voiceID: String {
        get { UserDefaults.standard.string(forKey: "elevenlabs-voice-id") ?? defaultVoiceID }
        set { UserDefaults.standard.set(newValue, forKey: "elevenlabs-voice-id") }
    }
    static func reset() { UserDefaults.standard.removeObject(forKey: "elevenlabs-voice-id") }
}

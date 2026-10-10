import Foundation

actor GeminiLiveClient {
    struct ToolCall: Sendable, Equatable {
        let id: String
        let name: String
        let args: [String: String]

        var proposedValue: String? { args["name"] ?? args["subject"] }
    }

    enum Event: Sendable {
        case ready
        case inputTranscript(String)
        case outputTranscript(String)
        case audio(Data)
        case interrupted
        case turnComplete
        case toolCall(ToolCall)
        case closed(String?)
    }

    private var socket: URLSessionWebSocketTask?
    private var continuation: AsyncStream<Event>.Continuation?

    func connect(apiKey: String, sessionContext: String? = nil) -> AsyncStream<Event> {
        let events = AsyncStream<Event> { continuation = $0 }
        guard var components = URLComponents(string: LiveAPIConfiguration.endpoint) else {
            continuation?.yield(.closed("Invalid Gemini endpoint."))
            return events
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            continuation?.yield(.closed("Invalid Gemini endpoint."))
            return events
        }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        Task {
            do {
                try await sendJSON(LiveAPIMessage.setup(sessionContext: sessionContext))
                await receiveLoop()
            } catch {
                continuation?.yield(.closed(Self.friendly(error)))
                continuation?.finish()
            }
        }
        return events
    }

    func sendText(_ text: String) async throws { try await sendJSON(LiveAPIMessage.text(text)) }
    func sendAudio(_ data: Data) async throws { try await sendJSON(LiveAPIMessage.audio(data.base64EncodedString())) }
    func sendToolResponse(call: ToolCall, result: String, status: String = "ok") async throws {
        try await sendJSON(["toolResponse": ["functionResponses": [[
            "id": call.id,
            "name": call.name,
            "response": ["status": status, "result": result]
        ]]]])
    }

    func disconnect() async {
        try? await sendJSON(LiveAPIMessage.audioStreamEnd)
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation?.finish()
        continuation = nil
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.data(data))
    }

    private func receiveLoop() async {
        do {
            while let socket {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                parse(data)
            }
        } catch {
            continuation?.yield(.closed(Self.friendly(error)))
            continuation?.finish()
        }
    }

    private func parse(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if root["setupComplete"] != nil { continuation?.yield(.ready) }
        if let toolCall = root["toolCall"] as? [String: Any],
           let calls = toolCall["functionCalls"] as? [[String: Any]] {
            for call in calls {
                guard let id = call["id"] as? String, let name = call["name"] as? String,
                      let arguments = call["args"] as? [String: Any] else { continue }
                let stringArguments = arguments.reduce(into: [String: String]()) { result, item in
                    if let value = item.value as? String { result[item.key] = value }
                    else if let value = item.value as? NSNumber { result[item.key] = value.stringValue }
                    else if JSONSerialization.isValidJSONObject(item.value),
                            let data = try? JSONSerialization.data(withJSONObject: item.value),
                            let value = String(data: data, encoding: .utf8) { result[item.key] = value }
                }
                continuation?.yield(.toolCall(ToolCall(id: id, name: name, args: stringArguments)))
            }
        }
        guard let content = root["serverContent"] as? [String: Any] else { return }
        if let transcript = content["inputTranscription"] as? [String: Any], let text = transcript["text"] as? String {
            continuation?.yield(.inputTranscript(text))
        }
        if let transcript = content["outputTranscription"] as? [String: Any], let text = transcript["text"] as? String {
            continuation?.yield(.outputTranscript(text))
        }
        if let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inline = part["inlineData"] as? [String: Any], let encoded = inline["data"] as? String,
                   let audio = Data(base64Encoded: encoded) { continuation?.yield(.audio(audio)) }
                if let text = part["text"] as? String { continuation?.yield(.outputTranscript(text)) }
            }
        }
        if content["interrupted"] as? Bool == true { continuation?.yield(.interrupted) }
        if content["turnComplete"] as? Bool == true { continuation?.yield(.turnComplete) }
    }

    private static func friendly(_ error: Error) -> String? {
        let nsError = error as NSError
        if nsError.code == URLError.cancelled.rawValue { return nil }
        return error.localizedDescription
    }
}

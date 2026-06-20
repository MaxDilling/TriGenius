import Foundation

// MARK: - Gemini REST Backend

final class GeminiBackend: LLMBackend {
    let displayName = "Gemini"
    let supportsTools = true
    let isAvailable = true

    private let apiKey: String
    private(set) var model: String

    init(apiKey: String, model: String = "gemini-2.5-flash") {
        self.apiKey = apiKey
        self.model = model
    }

    func complete(
        systemPrompt: String,
        turns: [ConversationTurn],
        tools: [ToolDefinition]
    ) async throws -> LLMCompletion {
        let request = try makeRequest(
            streaming: false,
            systemPrompt: systemPrompt,
            turns: turns,
            tools: tools
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
            throw GeminiError.apiError(statusCode: http.statusCode, body: bodyStr)
        }

        return try parseResponse(data: data)
    }

    func completeStreaming(
        systemPrompt: String,
        turns: [ConversationTurn],
        tools: [ToolDefinition]
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(
                        streaming: true,
                        systemPrompt: systemPrompt,
                        turns: turns,
                        tools: tools
                    )

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var bodyStr = ""
                        for try await line in bytes.lines { bodyStr += line }
                        throw GeminiError.apiError(
                            statusCode: http.statusCode,
                            body: bodyStr.isEmpty ? "no body" : bodyStr
                        )
                    }

                    var fullText = ""
                    var toolCalls: [ToolCallRecord] = []

                    // Gemini SSE: each event is a line `data: {<partial response>}`.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }

                        let (text, calls) = Self.parseParts(from: data)
                        if !text.isEmpty {
                            fullText += text
                            continuation.yield(.text(text))
                        }
                        toolCalls.append(contentsOf: calls)
                    }

                    continuation.yield(.completed(LLMCompletion(
                        text: fullText.isEmpty ? nil : fullText,
                        toolCalls: toolCalls
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request building

    private func makeRequest(
        streaming: Bool,
        systemPrompt: String,
        turns: [ConversationTurn],
        tools: [ToolDefinition]
    ) throws -> URLRequest {
        let endpoint = streaming ? "streamGenerateContent" : "generateContent"
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(endpoint)"
        guard var urlComponents = URLComponents(string: urlString) else {
            throw GeminiError.invalidURL
        }
        var queryItems = [URLQueryItem(name: "key", value: apiKey)]
        // `alt=sse` switches the stream endpoint from a JSON array to
        // Server-Sent Events, so we can parse it incrementally line by line.
        if streaming { queryItems.append(URLQueryItem(name: "alt", value: "sse")) }
        urlComponents.queryItems = queryItems
        guard let url = urlComponents.url else { throw GeminiError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Thinking models (Gemini 3.x) can take well over a minute to respond.
        request.timeoutInterval = 180

        var body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": turns.map(geminiContent(from:))
        ]

        if !tools.isEmpty {
            body["tools"] = [
                ["function_declarations": tools.map(geminiToolDict(from:))]
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    // MARK: - Encoding helpers

    private func geminiContent(from turn: ConversationTurn) -> [String: Any] {
        let role = turn.role == .user ? "user" : "model"
        let parts: [[String: Any]] = turn.parts.compactMap { part in
            switch part {
            case .text(let text):
                return ["text": text]
            case .toolCall(let call):
                var part: [String: Any] = [
                    "functionCall": ["name": call.name, "args": call.arguments]
                ]
                // Echo back the thought signature so Gemini 3.x thinking
                // models can validate the function call (required, else 400).
                if let signature = call.thoughtSignature {
                    part["thoughtSignature"] = signature
                }
                return part
            case .toolResult(let result):
                return [
                    "functionResponse": [
                        "name": result.name,
                        "response": ["result": result.result]
                    ]
                ]
            }
        }
        return ["role": role, "parts": parts]
    }

    private func geminiToolDict(from tool: ToolDefinition) -> [String: Any] {
        return [
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.parameters
        ]
    }

    // MARK: - Decoding helpers

    private func parseResponse(data: Data) throws -> LLMCompletion {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["candidates"] is [[String: Any]]
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.invalidResponse(raw: raw)
        }

        let (text, toolCalls) = Self.parseParts(from: data)
        return LLMCompletion(
            text: text.isEmpty ? nil : text,
            toolCalls: toolCalls
        )
    }

    /// Extracts text and tool calls from a Gemini response payload — either a
    /// full `generateContent` body or a single `streamGenerateContent` SSE
    /// chunk; both share the `candidates[0].content.parts` shape. Returns empty
    /// values for chunks without usable parts (e.g. metadata-only events).
    private static func parseParts(from data: Data) -> (text: String, toolCalls: [ToolCallRecord]) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            return ("", [])
        }

        var textAccum = ""
        var toolCalls: [ToolCallRecord] = []

        for part in parts {
            if let text = part["text"] as? String {
                textAccum += text
            } else if let fc = part["functionCall"] as? [String: Any],
                      let name = fc["name"] as? String {
                let args = fc["args"] as? [String: Any] ?? [:]
                let signature = part["thoughtSignature"] as? String
                toolCalls.append(ToolCallRecord(name: name, arguments: args, thoughtSignature: signature))
            }
        }

        return (textAccum, toolCalls)
    }
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case invalidURL
    case apiError(statusCode: Int, body: String)
    case invalidResponse(raw: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Gemini API URL."
        case .apiError(let code, let body):
            return "Gemini API error \(code): \(body)"
        case .invalidResponse(let raw):
            return "Invalid response from Gemini: \(raw.prefix(200))"
        }
    }
}

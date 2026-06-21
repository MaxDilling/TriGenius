import Foundation

// MARK: - LM Studio Backend
//
// Talks to a local LM Studio server over its OpenAI-compatible REST API
// (`POST {baseURL}/chat/completions`). Stateless and CoachBrain-driven, exactly
// like `GeminiBackend`: CoachBrain owns the transcript and the tool-call loop.
//
// LM Studio runs the model on the user's own Mac, so there's no API key — just a
// base URL (default `http://localhost:1234/v1`) and the loaded model's id.
//
// Tool-call plumbing: the OpenAI schema matches tool results to calls by an
// opaque `tool_call_id`. We stash the id LM Studio returns in
// `ToolCallRecord.thoughtSignature` (its purpose: a backend token echoed back on
// the next turn) and re-pair it with the matching `ToolResultRecord` by position,
// since CoachBrain appends results in the same order as the calls.

final class LMStudioBackend: LLMBackend {
    let displayName = "LM Studio"
    let supportsTools = true
    let isAvailable = true

    private let baseURL: String
    private(set) var model: String

    /// `baseURL` should include the `/v1` suffix LM Studio serves under.
    init(baseURL: String = "http://localhost:1234/v1", model: String = "local-model") {
        // Trim a trailing slash so endpoint joins are predictable.
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.model = model.isEmpty ? "local-model" : model
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
            throw LMStudioError.apiError(statusCode: http.statusCode, body: bodyStr)
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
                        throw LMStudioError.apiError(
                            statusCode: http.statusCode,
                            body: bodyStr.isEmpty ? "no body" : bodyStr
                        )
                    }

                    var fullText = ""
                    // Tool calls stream in fragments keyed by `index`; accumulate
                    // name + argument-string deltas until the stream ends.
                    var toolAccum: [Int: StreamingToolCall] = [:]

                    // OpenAI SSE: each event is a line `data: {<chunk>}`, ending
                    // with the sentinel `data: [DONE]`.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty else { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }

                        let delta = Self.parseStreamDelta(from: data)
                        if let text = delta.text, !text.isEmpty {
                            fullText += text
                            continuation.yield(.text(text))
                        }
                        for fragment in delta.toolFragments {
                            var entry = toolAccum[fragment.index] ?? StreamingToolCall()
                            if let id = fragment.id { entry.id = id }
                            if let name = fragment.name { entry.name = name }
                            if let args = fragment.argumentsDelta { entry.arguments += args }
                            toolAccum[fragment.index] = entry
                        }
                    }

                    let toolCalls = Self.finalize(toolAccum)
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
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LMStudioError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Local models can be slow on first load / long contexts.
        request.timeoutInterval = 300

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        messages.append(contentsOf: openAIMessages(from: turns))

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": streaming
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map(openAIToolDict(from:))
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    // MARK: - Encoding helpers

    /// Maps our conversation model onto OpenAI chat messages. Each assistant
    /// tool-call message needs an `id`; the following `tool` messages must echo it
    /// back as `tool_call_id`. We re-pair them by order using a FIFO queue, since
    /// CoachBrain appends tool results in the same order as the calls.
    private func openAIMessages(from turns: [ConversationTurn]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var pendingCallIDs: [String] = []
        var fallbackCounter = 0

        for turn in turns {
            let texts = turn.parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }
            let toolCalls = turn.parts.compactMap { part -> ToolCallRecord? in
                if case .toolCall(let c) = part { return c }
                return nil
            }
            let toolResults = turn.parts.compactMap { part -> ToolResultRecord? in
                if case .toolResult(let r) = part { return r }
                return nil
            }

            if !toolCalls.isEmpty {
                // Assistant turn issuing tool calls.
                var message: [String: Any] = ["role": "assistant"]
                // OpenAI requires `content` present; text is usually empty here.
                message["content"] = texts.joined()
                message["tool_calls"] = toolCalls.map { call -> [String: Any] in
                    let id: String
                    if let signature = call.thoughtSignature, !signature.isEmpty {
                        id = signature
                    } else {
                        fallbackCounter += 1
                        id = "call_\(fallbackCounter)"
                    }
                    pendingCallIDs.append(id)
                    let argsJSON = (try? JSONSerialization.data(withJSONObject: call.arguments))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return [
                        "id": id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": argsJSON]
                    ]
                }
                messages.append(message)
            } else if !toolResults.isEmpty {
                // Tool results — one `tool` message each, paired to a pending id.
                for result in toolResults {
                    let id = pendingCallIDs.isEmpty ? "" : pendingCallIDs.removeFirst()
                    messages.append([
                        "role": "tool",
                        "tool_call_id": id,
                        "content": result.result
                    ])
                }
            } else {
                // Plain text turn.
                let role = turn.role == .user ? "user" : "assistant"
                messages.append(["role": role, "content": texts.joined()])
            }
        }

        return messages
    }

    private func openAIToolDict(from tool: ToolDefinition) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parameters
            ]
        ]
    }

    // MARK: - Decoding helpers

    private func parseResponse(data: Data) throws -> LLMCompletion {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw LMStudioError.invalidResponse(raw: raw)
        }

        let text = message["content"] as? String
        var toolCalls: [ToolCallRecord] = []

        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                guard
                    let function = raw["function"] as? [String: Any],
                    let name = function["name"] as? String
                else { continue }
                let argsString = function["arguments"] as? String ?? "{}"
                let args = Self.parseArguments(argsString)
                let id = raw["id"] as? String
                toolCalls.append(ToolCallRecord(name: name, arguments: args, thoughtSignature: id))
            }
        }

        return LLMCompletion(
            text: (text?.isEmpty ?? true) ? nil : text,
            toolCalls: toolCalls
        )
    }

    /// One streaming SSE chunk decoded into a text delta and any tool-call
    /// fragments (`choices[0].delta`).
    private static func parseStreamDelta(from data: Data) -> StreamDelta {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let delta = first["delta"] as? [String: Any]
        else {
            return StreamDelta(text: nil, toolFragments: [])
        }

        let text = delta["content"] as? String
        var fragments: [ToolFragment] = []

        if let rawCalls = delta["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                let index = raw["index"] as? Int ?? 0
                let id = raw["id"] as? String
                let function = raw["function"] as? [String: Any]
                fragments.append(ToolFragment(
                    index: index,
                    id: id,
                    name: function?["name"] as? String,
                    argumentsDelta: function?["arguments"] as? String
                ))
            }
        }

        return StreamDelta(text: text, toolFragments: fragments)
    }

    private static func finalize(_ accum: [Int: StreamingToolCall]) -> [ToolCallRecord] {
        accum.sorted { $0.key < $1.key }.compactMap { _, call in
            guard let name = call.name else { return nil }
            let args = parseArguments(call.arguments)
            return ToolCallRecord(name: name, arguments: args, thoughtSignature: call.id)
        }
    }

    /// Tool arguments arrive as a JSON *string*; decode to a dictionary.
    private static func parseArguments(_ string: String) -> [String: Any] {
        guard
            let data = string.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }
}

// MARK: - Streaming accumulation

private struct StreamDelta {
    let text: String?
    let toolFragments: [ToolFragment]
}

private struct ToolFragment {
    let index: Int
    let id: String?
    let name: String?
    let argumentsDelta: String?
}

private struct StreamingToolCall {
    var id: String?
    var name: String?
    var arguments: String = ""
}

// MARK: - Errors

enum LMStudioError: LocalizedError {
    case invalidURL
    case apiError(statusCode: Int, body: String)
    case invalidResponse(raw: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid LM Studio server URL."
        case .apiError(let code, let body):
            return "LM Studio error \(code): \(body)"
        case .invalidResponse(let raw):
            return "Invalid response from LM Studio: \(raw.prefix(200))"
        }
    }
}

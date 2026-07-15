import Foundation

// MARK: - Web search tool (OpenRouter-backed)
//
// The coach decides when to search and formulates a self-contained query with
// full conversation context — unlike a per-request search plugin, which derives
// its query from the athlete's latest message alone, so a bare follow-up like
// "are there still tickets?" searches without the event. The handler runs a
// one-shot nested OpenRouter call with the `web` plugin attached (same API key,
// no extra provider) and returns a condensed summary plus the `url_citation`
// sources, which also feed the chat bubble's globe badge via `onCitations`.
// Registered only while the active backend is OpenRouter (Settings toggle), so
// no query leaves the device on the on-device backend.

@MainActor
final class WebSearchToolHandler: CoachToolHandler {
    private let onCitations: ([WebCitation]) -> Void

    init(onCitations: @escaping ([WebCitation]) -> Void) {
        self.onCitations = onCitations
    }

    var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: "web_search",
                description: "Search the live web for current real-world information: event dates, registration/ticket availability, race results, gear. Returns a factual summary plus source links. The query must be self-contained — include every detail from the conversation (event name, year, location); never pronouns or a bare follow-up like 'tickets?'.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Self-contained search query, e.g. 'Challenge Roth 2026 registration still open'."
                        ]
                    ],
                    "required": ["query"]
                ]
            )
        ]
    }

    func execute(name: String, arguments: [String: Any]) async throws -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return "Error: web_search requires a non-empty 'query'."
        }
        guard let key = KeychainStore.string(for: KeychainStore.openRouterAPIKey), !key.isEmpty else {
            return "Error: web search unavailable (no OpenRouter API key)."
        }
        let backend = OpenAICompatibleBackend(
            displayName: "OpenRouter web search",
            baseURL: OpenAICompatibleBackend.openRouterBaseURL,
            apiKey: key,
            extraHeaders: OpenAICompatibleBackend.openRouterHeaders,
            model: AppSettings.storedOpenRouterModel(),
            webSearch: true,
            timeout: 60
        )
        let today = Date().formatted(.iso8601.year().month().day())
        let completion = try await backend.complete(
            systemPrompt: "You condense web search results. Today is \(today). Report only the facts relevant to the query — concrete dates, numbers, availability — with their source links. If the results don't answer the query, state briefly what they cover instead. No filler.",
            turns: [.user(query)],
            tools: []
        )
        onCitations(completion.webCitations)
        let payload: [String: Any] = [
            "summary": completion.text ?? "",
            "sources": completion.webCitations.map { citation -> [String: Any] in
                var source: [String: Any] = ["url": citation.url]
                if let title = citation.title { source["title"] = title }
                return source
            }
        ]
        return String(compactJSON: payload)
    }
}

import SwiftUI

// MARK: - Tool Runner (Debug Mode)
//
// A developer screen that lists every tool registered for the active data source
// and lets you invoke each one by hand to inspect its raw result — without going
// through the coach. Arguments are edited as JSON, pre-filled with a skeleton
// generated from the tool's JSON-Schema `parameters`, so even deeply nested
// tools (e.g. `add_workout`) are runnable. Calls go through the same safe path
// the coach uses, so Debug Mode logging fires too.

struct ToolDebugView: View {
    let brain: CoachBrain

    var body: some View {
        List {
            Section {
                ForEach(brain.registeredTools.sorted(by: { $0.name < $1.name }), id: \.name) { tool in
                    NavigationLink {
                        ToolRunnerView(brain: brain, tool: tool)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(.system(.body, design: .monospaced))
                            Text(tool.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } header: {
                Text("\(brain.registeredTools.count) tools · source: \(brain.dataSource.displayName)")
            } footer: {
                Text("Invoke any coach tool by hand and see its raw result. Calls run exactly as the coach would run them.")
            }
        }
        .navigationTitle("Tool Runner")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Single Tool Runner

struct ToolRunnerView: View {
    let brain: CoachBrain
    let tool: ToolDefinition

    @State private var argumentsJSON: String = ""
    @State private var result: String?
    @State private var parseError: String?
    @State private var isRunning = false
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tool.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Parameter schema (for reference)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Schema")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(prettyJSON(tool.parameters))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }

                // Editable arguments
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Arguments (JSON)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") { argumentsJSON = Self.skeleton(for: tool.parameters) }
                            .font(.caption)
                    }
                    TextEditor(text: $argumentsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #endif
                }

                if let parseError {
                    Label(parseError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button {
                    Task { await run() }
                } label: {
                    if isRunning {
                        HStack { ProgressView(); Text("Running…") }
                    } else {
                        Label("Run \(tool.name)", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)

                if let result {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Result")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                copyToClipboard(result)
                                didCopy = true
                            } label: {
                                Label(didCopy ? "Copied" : "Copy",
                                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
                                    .font(.caption)
                            }
                        }
                        Text(result)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding()
        }
        .navigationTitle(tool.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if argumentsJSON.isEmpty { argumentsJSON = Self.skeleton(for: tool.parameters) }
        }
    }

    // MARK: - Run

    private func run() async {
        parseError = nil
        didCopy = false
        let arguments: [String: Any]
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            arguments = [:]
        } else if let data = trimmed.data(using: .utf8),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            arguments = parsed
        } else {
            parseError = "Arguments must be a valid JSON object."
            return
        }

        isRunning = true
        result = nil
        let output = await brain.debugRunTool(name: tool.name, arguments: arguments)
        result = output
        isRunning = false
    }

    // MARK: - JSON helpers

    private func prettyJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Build an editable JSON skeleton from a tool's JSON-Schema parameters, with
    /// a placeholder value per property so nested/required fields are obvious.
    static func skeleton(for schema: [String: Any]) -> String {
        let value = sampleValue(for: schema)
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    /// Recursively produce a placeholder value for a JSON-Schema node.
    private static func sampleValue(for schema: [String: Any]) -> Any {
        let type = schema["type"] as? String
        if let enumValues = schema["enum"] as? [Any], let first = enumValues.first {
            return first
        }
        switch type {
        case "object":
            var obj: [String: Any] = [:]
            if let properties = schema["properties"] as? [String: Any] {
                for (key, raw) in properties {
                    if let propSchema = raw as? [String: Any] {
                        obj[key] = sampleValue(for: propSchema)
                    }
                }
            }
            return obj
        case "array":
            if let items = schema["items"] as? [String: Any] {
                return [sampleValue(for: items)]
            }
            return []
        case "integer", "number":
            return 0
        case "boolean":
            return false
        default:
            return ""
        }
    }
}

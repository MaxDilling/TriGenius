import Foundation
import FoundationModels

// MARK: - JSON Schema → GenerationSchema
//
// The coach tools (CoachTools.swift) describe their parameters as dynamic
// JSON-Schema dictionaries — the same shape the OpenAI-compatible backends
// consume. FoundationModels
// instead wants a `GenerationSchema`. This builder converts one to the other at
// runtime so we don't have to hand-write a `@Generable` struct per tool.

@available(iOS 27.0, macOS 27.0, *)
nonisolated enum JSONSchemaToGenerationSchema {

    /// Build a `GenerationSchema` from a tool's JSON-Schema `parameters` object.
    /// The root is always the parameter object (`type: "object"`).
    static func build(toolName: String, parameters: [String: Any]) throws -> GenerationSchema {
        let root = node(name: schemaName(toolName), schema: parameters)
        // All nested objects are inlined, so there are no named dependencies.
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Recursively translate a JSON-Schema node into a `DynamicGenerationSchema`.
    private static func node(name: String, schema: [String: Any]) -> DynamicGenerationSchema {
        let type = schema["type"] as? String ?? "string"
        let description = schema["description"] as? String

        switch type {
        case "object":
            let props = schema["properties"] as? [String: Any] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            let properties: [DynamicGenerationSchema.Property] = props.map { key, value in
                let childSchema = value as? [String: Any] ?? ["type": "string"]
                let child = node(name: "\(name)_\(key)", schema: childSchema)
                return DynamicGenerationSchema.Property(
                    name: key,
                    description: childSchema["description"] as? String,
                    schema: child,
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(name: name, description: description, properties: properties)

        case "array":
            let items = schema["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: node(name: "\(name)_item", schema: items))

        case "string":
            if let enumValues = schema["enum"] as? [String] {
                return DynamicGenerationSchema(name: name, description: description, anyOf: enumValues)
            }
            return DynamicGenerationSchema(type: String.self)

        case "integer":
            return DynamicGenerationSchema(type: Int.self)

        case "number":
            return DynamicGenerationSchema(type: Double.self)

        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)

        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    /// Schema object names must be valid identifiers; sanitize tool names.
    private static func schemaName(_ toolName: String) -> String {
        let cleaned = toolName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return "Args_" + String(cleaned)
    }
}

// MARK: - Generic Tool bridge
//
// One `CoachToolBridge` per `ToolDefinition`. It exposes the dynamically built
// schema to the model and, when the model invokes the tool, forwards the
// arguments (as a JSON string — Sendable, identical in shape to the
// CoachBrain-driven path) to the executor closure, which runs the real handler
// on the MainActor.

@available(iOS 27.0, macOS 27.0, *)
nonisolated final class CoachToolBridge: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    var includesSchemaInInstructions: Bool { true }

    private let executor: @Sendable (String, String) async -> String

    init(definition: ToolDefinition,
         executor: @escaping @Sendable (String, String) async -> String) throws {
        self.name = definition.name
        self.description = definition.description
        self.parameters = try JSONSchemaToGenerationSchema.build(
            toolName: definition.name,
            parameters: definition.parameters
        )
        self.executor = executor
    }

    func call(arguments: GeneratedContent) async throws -> String {
        // `jsonString` is the canonical JSON for the generated arguments.
        // The executor parses it on the MainActor and runs the handler.
        await executor(name, arguments.jsonString)
    }
}

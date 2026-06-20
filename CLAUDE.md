# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TriGenius is a SwiftUI multiplatform app (iOS / macOS / visionOS) — an evidence-based AI triathlon coach. It's a native Swift port of `TriGenius_python`; many files are 1:1 ports and call that out in their header comments. JSON keys and tool schemas use **snake_case** to stay compatible with the Python memory/data format.

UI strings are **English**; code comments, the system prompt, and tool descriptions are also **English**; coach replies go back to the user in their language (the system prompt instructs the model to "respond in the athlete's language").

## Build & run

Single Xcode project, single target/scheme (`TriGenius`), no test target. Requires **Xcode-beta** (deployment targets are iOS 27+/macOS 27+; the Apple Intelligence backend needs the iOS/macOS 26 FoundationModels framework).

```bash
# Build for a simulator
xcodebuild -project TriGenius.xcodeproj -scheme TriGenius \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Build for macOS
xcodebuild -project TriGenius.xcodeproj -scheme TriGenius \
  -destination 'platform=macOS' build
```

Prefer building/running through Xcode; everyday work is usually faster via the IDE. There are no automated tests to run.

The project uses Xcode **synchronized groups** (`PBXFileSystemSynchronizedRootGroup`, `objectVersion = 90`): the `TriGenius/` folder tree maps directly to the build target. New `.swift` files added anywhere under it are picked up automatically — **do not** edit `project.pbxproj` to register them.

## Architecture

The app has two pluggable axes that meet in `CoachBrain`: **LLM backend** (who answers) and **data source** (where athlete data comes from). Both are swapped at runtime from Settings without touching the coach logic.

### CoachBrain (`Coach/CoachBrain.swift`) — the orchestrator
- `@MainActor @Observable`, owns the `SYSTEM_PROMPT_TEMPLATE`, conversation history, tool registry, and the active backend.
- Builds the system prompt each turn by injecting current date/time, `memory.contextSummary`, and a data-source-specific section.
- Two execution paths depending on the backend:
  - **CoachBrain-driven** (Gemini): `runLoop()` drives the tool-call loop manually — stream a turn, if it has tool calls execute them and append results as a synthetic user turn, repeat (max `maxToolIterations = 8`).
  - **Self-managing** (Apple FM): backend owns its transcript and runs tools internally; CoachBrain just feeds the latest user message and hands the backend a tool executor closure via `setBackend` → `setToolExecutor`.

### LLM backends (`LLM/`) — `LLMBackend` protocol (`LLM/LLMService.swift`)
- The protocol's `managesOwnConversation` flag is the key fork. Default extension implementations let stateless backends ignore the self-managing methods.
- **GeminiBackend** (`GeminiService.swift`): stateless REST (`gemini-2.5-flash` default), CoachBrain-driven. Note `ToolCallRecord.thoughtSignature` — an opaque token Gemini "thinking" models require to be echoed back.
- **AppleFoundationModelBackend** (`AppleFoundationModelService.swift`): on-device Apple Intelligence, `@available(iOS 26)`, self-managing via a persistent `LanguageModelSession`. `CoachToolBridge.swift` converts each tool's dynamic JSON-Schema `parameters` into a FoundationModels `GenerationSchema` at runtime (so tools are defined once, in JSON-Schema form, for both backends).
- `BackendFactory` / `BackendType` select the implementation.

### Tools (`Coach/CoachTools.swift`) — `CoachToolHandler` + `CoachToolRegistry`
- All handlers are `@MainActor`. The registry maps tool name → handler.
- **The data-source abstraction lives here**: `HealthKitToolHandler` and `GarminToolHandler` both register `get_health_metrics` / `get_activities` under the same names, so only one is active at a time and the coach is source-agnostic. Garmin additionally exposes workout scheduling (`add_workout`, `move_workout`, `delete_workout`, `get_calendar`), `get_power_curve`, `get_training_status`, and `sync_user_settings`.
- `ProfileToolHandler` is always registered (profile read/write + `read_knowledge`). The coaching knowledge base is **embedded** as Swift string constants (`CoachKnowledge`) in this file.
- Tool parameters are dictionaries literally shaped like JSON Schema — that same dict feeds Gemini's API directly and `CoachToolBridge` for Apple FM.

### Data sources (`DataManagement/`)
- **HealthKit** (`HealthKit/HealthKitService.swift`): read-only Apple Health.
- **Garmin** (`DataManagement/Garmin/`): native port of the Python Garmin stack, layered — `GarminAuth` (SSO/MFA → OAuth token), `GarminClient` (low-level connectapi), `GarminService` (high-level orchestration, returns ToolResult-style JSON strings), `GarminTransformations` (pure response-shaping), `GarminWorkoutBuilder` (builds workout payloads), `GarminMappings` (lookup tables). Garmin can both read and write (schedule workouts, sync settings back into memory).

### Memory (`Coach/CoachMemory.swift`)
- `ObservableObject` persisting athlete profile, preferences, weekly structure, training plan, sport progress, and feedback as a JSON file (`coach_memory.json`) in Application Support. Mirrors the Python `coach_memory.json` structure — keys are snake_case and each model has `init(from: [String: Any])` / `toDict()`.
- `contextSummary` is what gets injected into the system prompt; when it contains "FEHLENDE INFORMATIONEN", the prompt drives an onboarding flow.

### App entry & settings
- `App/TriGeniusApp.swift`: builds `CoachBrain` once, re-applies backend + data source whenever settings change (`applyBackend`). Tab UI in `RootTabView`.
- `Features/Settings/SettingsView.swift`: `AppSettings` (`ObservableObject`) + `DataSource` enum. Persists Gemini API key, selected backend/model, data source, and Garmin email via `UserDefaults`. `makeBackend()` is the single place backends are constructed.

## Conventions when extending

- **Adding a tool**: define it as a JSON-Schema dict in a `CoachToolHandler` — it then works for *both* backends automatically. Keep parameter names snake_case.
- **Adding a data source**: implement a `CoachToolHandler` that registers the same `get_health_metrics` / `get_activities` names, and wire it into `CoachBrain.configureTools()` + the `DataSource` enum.
- **Backend behavior differences** belong behind the `LLMBackend` protocol, not in `CoachBrain` — keep the orchestrator source/backend-agnostic.

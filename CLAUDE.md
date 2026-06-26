# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

TriGenius is a SwiftUI multiplatform app (iOS / iPadOS / macOS) — an evidence-based AI triathlon coach. JSON keys and tool schemas use **snake_case** throughout the memory/data format.

UI strings are **English**; code comments, the system prompt, and tool descriptions are also **English**; coach replies go back to the user in their language (the system prompt instructs the model to "respond in the athlete's language").

## Build & run

Single Xcode project, single target/scheme (`TriGenius`), no test target. Requires **Xcode-beta** (deployment targets are iOS 27+/macOS 27+; the Apple Intelligence backend with tool calls needs the iOS/macOS 27 FoundationModels framework).

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
- **The data-source abstraction lives here**: `HealthKitToolHandler` and `GarminToolHandler` both register `get_health_metrics` / `get_activities` under the same names, so only one is active at a time and the coach is source-agnostic. Garmin additionally exposes workout management (`get_workouts`, `add_workouts`, `modify_workout`, `move_workout`, `delete_workout`), `get_power_curve`, `get_training_status`, and `sync_user_settings`.
- `ProfileToolHandler` is always registered (profile read/write + `read_knowledge`). The coaching knowledge base lives in Markdown files under `TriGenius/Assets/Knowledge/` (`CYCLING.md`, `RUNNING.md`, `SWIMMING.md`, `INJURIES.MD`, `WORKOUTS.md`), loaded from the app bundle at runtime via the `knowledgeFiles` map.
- Tool parameters are dictionaries literally shaped like JSON Schema — that same dict feeds Gemini's API directly and `CoachToolBridge` for Apple FM.

### Data sources (`DataManagement/`)
- **HealthKit** (`HealthKit/HealthKitService.swift`): read-only Apple Health.
- **Garmin** (`DataManagement/Garmin/`): layered — `GarminAuth` (SSO/MFA → OAuth token), `GarminClient` (low-level connectapi), `GarminService` (high-level orchestration, returns ToolResult-style JSON strings), `GarminTransformations` (pure response-shaping), `GarminWorkoutBuilder` (builds workout payloads), `GarminMappings` (lookup tables). Garmin can both read and write (schedule workouts, sync settings back into memory).
  - **Reference only — `ref/garmin_health_data/`**: a vendored Python Garmin Connect client (not part of the build) kept as a worked example of the Garmin Connect API. Useful for understanding endpoint URLs, request/response shapes, the OAuth/DI token exchange, and the five-strategy login fallback when extending the Swift Garmin layer. Start with `garmin_client/api.py` (endpoint → method mapping), `garmin_client/constants.py` (URL templates), and `garmin_client/client.py` (auth + token refresh). Do not import or ship it — port behavior into the Swift `Garmin/` layer.

### Memory (`Coach/CoachMemory.swift`)
- `ObservableObject` persisting athlete profile, preferences, weekly structure, training plan, sport progress, and feedback as a JSON file (`coach_memory.json`) in Application Support. Keys are snake_case and each model has `init(from: [String: Any])` / `toDict()`.
- `contextSummary` is what gets injected into the system prompt; when it contains "FEHLENDE INFORMATIONEN", the prompt drives an onboarding flow.

### App entry & settings
- `App/TriGeniusApp.swift`: builds `CoachBrain` once, re-applies backend + data source whenever settings change (`applyBackend`). Tab UI in `RootTabView`.
- `Features/Settings/SettingsView.swift`: `AppSettings` (`ObservableObject`) + `DataSource` enum. Persists Gemini API key, selected backend/model, data source, and Garmin email via `UserDefaults`. `makeBackend()` is the single place backends are constructed.

## Design

UI work follows **`DESIGN.md`** (the normative design system) — modern, compact, data-dense, "Silent AI", and Apple's real Liquid Glass (`glassEffect`, not hand-rolled materials). Tokens and surfaces are code-backed in `TriGenius/Shared/DesignSystem/` (`Theme.swift`, `Color+App.swift`, `Surfaces.swift`): use `Theme.Spacing` / `Theme.Radius` / `Theme.Palette` and `.cardSurface()` / `.glassSurface(tint:)` / `.coachAccent(_:)` instead of magic numbers or raw materials. **`DESIGN_CHANGES.md`** is the rollout checklist. (Accessibility is intentionally deferred for now.)

## Conventions when extending

- **Quality over speed**: this app is meant to grow — the goal is to be *TrainingPeaks for individual athletes with an AI coach*. Write clean code without technical debt or boilerplate, even if it takes longer; favour maintainable, well-factored solutions over quick fixes.
- **Before changing the architecture or data flow**: whenever data is missing, or a change requires touching the data flow or the architecture, **check with the user first** — discuss how the architecture should be adjusted and whether the change should be generalized rather than handled as a one-off, before implementing.
- **UI / styling**: pull spacing, radius and status colors from `Theme`; use the `Surfaces.swift` modifiers. Content goes on the opaque `.cardSurface()` layer, glass is reserved for the floating control/nav layer. See `DESIGN.md`.
- **Adding a tool**: define it as a JSON-Schema dict in a `CoachToolHandler` — it then works for *both* backends automatically. Keep parameter names snake_case.
- **Adding a data source**: implement a `CoachToolHandler` that registers the same `get_health_metrics` / `get_activities` names, and wire it into `CoachBrain.configureTools()` + the `DataSource` enum.
- **Backend behavior differences** belong behind the `LLMBackend` protocol, not in `CoachBrain` — keep the orchestrator source/backend-agnostic.

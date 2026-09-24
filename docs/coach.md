# Coach: brain, backends, tools, memory

Detail doc for `Coach/`, `LLM/`. Index: `CLAUDE.md` → Components.

## CoachBrain (`Coach/CoachBrain.swift`)

`@MainActor @Observable` orchestrator; owns `SYSTEM_PROMPT_TEMPLATE`, conversation history, tool registry, active backend. Rebuilds the system prompt each turn from: date/time, `memory.contextSummary`, PMC/load/ATP sections (`ProactiveCoach.promptSection`/`loadPromptSection`, `ATPToolHandler.promptSection`), and a data/devices section listing active sources + target. `setSources(read:write:)` rebuilds the registry via `configureTools`.

Template is tuned for a ~70B model: explicit PRIORITY ORDER resolves rule conflicts; caveats render *conditionally* (CTL warm-up note only under 42 days of history, onboarding only while incomplete); week-in-progress load is framed "week to date, day N of 7" against absolute baselines, never a %-drop vs complete weeks; `ATPToolHandler.reducedVolumePlanned()` marks recovery/taper/race weeks so low volume reads as intentional. Deep reference material (stagnation triage) lives in the knowledge base, not the prompt.

Two execution paths, forked on the backend's `managesOwnConversation`:
- **CoachBrain-driven**: `runLoop()` drives the tool loop manually — stream a turn → execute tool calls → append results as a synthetic user turn → repeat, max `maxToolIterations = 8`.
- **Self-managing** (Apple FM): backend owns its transcript and runs tools internally; CoachBrain feeds the latest user message plus a tool-executor closure.

## LLM backends (`LLM/`)

`LLMBackend` protocol (`LLM/LLMService.swift`); `managesOwnConversation` is the fork, default extensions let stateless backends ignore the self-managing methods. `AppSettings.makeBackend()` builds the impl for the chosen `BackendType`.

- **`OpenAICompatibleBackend`** (`OpenAICompatibleService.swift`) — one stateless, CoachBrain-driven client for every OpenAI chat-completions backend. **OpenRouter** (hosted, `Bearer` key + `X-Title`, default cloud backend) and **LM Studio** (local, keyless) are configs of it: base URL / api key / extra headers / timeout / OpenRouter `web` plugin. The `web` plugin is set **only** by the `web_search` tool's nested one-shot call, never on the coach conversation. `url_citation` annotations ride `LLMCompletion.webCitations` → globe badge on the chat bubble, hover/tap popover lists sources. Streamed `reasoning` deltas surface in Debug Mode as a collapsed per-turn thinking row. Tool-call ids ride in `ToolCallRecord.thoughtSignature`, re-paired to results by position. Key in Keychain (`openRouterAPIKey`).
- **`AppleFoundationModelBackend`** (`AppleFoundationModelService.swift`) — on-device, `@available(iOS 26)`, self-managing via a persistent `LanguageModelSession`. `CoachToolBridge.swift` converts each tool's JSON-Schema `parameters` into a FoundationModels `GenerationSchema` at runtime, so tools are defined once for both backends.

## Tools (`Coach/CoachTools.swift`)

`CoachToolHandler` + `CoachToolRegistry`, all `@MainActor`. Parameters are dicts literally shaped like JSON Schema — the same dict feeds the wire API and `CoachToolBridge`. All tool results serialize through `String(compactJSON:)` (`Shared/CompactJSON.swift`) — single-line, clean numbers, no IEEE float artifacts; human-facing debug/copy UIs keep `String(prettyJSON:)`.

### `ActivityReadToolHandler` (always on) — reads are source-agnostic
- `get_power_curve` — from the stored per-ride curves (`PowerCurve.aggregate`, same aggregation as the Statistics chart), subsampled to ~9 coach-relevant durations + the longest effort.
- `get_metric_history` — from `TrainingDataStore.metricHistory`; the one metric read for both capacity markers and recovery/wellness (any `PerformanceMetric.all` key, several per call). Output is token-lean: a period-independent `current` line ("since" = start of the value's run), a `summary` (first→last + delta + per-month rate for capacity markers; mean/low/high for recovery), and a `history` of compact "YYYY-MM-DD value" pairs with consecutive display-equal repeats dropped (first/last always kept; flat windows collapse to "unchanged in this period"). Recovery markers switch to labelled weekly means past 14 days and default to a 14-day window when requested alone. Wellness comes from the single `metrics_source`, not both.
- `set_performance_metric` — writes an athlete-reported measurement onto the same `setManualMetric` path as the Statistics manual-entry UI (`source: "manual"`, outranks synced values on its day, visible/editable in the metric detail view). Keys/units/pace-parsing shared via the `PerformanceMetric` catalog.

### `WorkoutSchedulingToolHandler` (always on) — writes go through one API → the active target
Owns `get_workouts`/`add_workouts`/`modify_workout`/`move_workout`/`delete_workout`, but only schema + parsing + reply formatting; the writes are `DataSyncCoordinator`'s plan CRUD (`addPlan`/`updatePlan`/`movePlan`/`deletePlan`), shared with the calendar's workout editor.

`get_workouts` is the **single unified read for completed and planned work** (it replaced a separate `get_activities`): a `status` filter (`completed`/`planned`/`all`) picks the sections, so completed rows never arrive via two tools. Completed rows are projected to a lean, TL-focused view by `CoachActivityProjection` (`detailed:true` adds the per-lap breakdown, capped to 5); a recorded strength session's sets are condensed to one line per exercise (`StrengthSets.coachLines`, e.g. `back_squat: 5×60kg, 4×62.5kg`) — what the coach progresses weights from. `get_exercises` answers the strength library as one plain-text line per exercise (`exercise_id — loads + also loads · timed`), not JSON, to keep the ~70-exercise catalogue cheap.

Each successful mutation emits a **`ChatCard`** (`Shared/ChatCards/` — model, `WorkoutDiff` differ, card views) through `CoachBrain.chatCardHandler` as its own tappable chat row; modify/move diff the *stored* before/after `workout_data` (`DataSyncCoordinator.plannedSnapshot`), never the tool arguments. The coach can also embed cards via a fenced ```` ```card ```` token (one single-line JSON object — workout ref or chart; grammar in the prompt's RICH CARDS section) that `MarkdownText` parses in place: malformed tokens degrade to a visible code block, an unterminated fence mid-stream shows a placeholder. A strength plan's card lists its exercises (`StrengthSets.blocks`). Workout cards push `TrainingDetailView`/`PlannedWorkoutDetailView` on the chat's own stack via `ChatCardDestination` (completed-first lookup: `store.activity(id:)`); chart cards load through the same builders as Dashboard/Statistics (`CLTrendModel.around`, `RampRate.weeklySeries`, `SportShareModel.make`, `ZoneDistribution.aggregate`, `metricHistory`). Status in `CHAT_TODO.md`.

### `ProfileToolHandler` (always on)
`update_athlete_profile` (name/goals/motivation/weekly structure/preferences/feedback), `update_sport_profile` (`sport` schema-required — level/focus/abilities/equipment/limitations/injuries), `read_knowledge`. There is **no profile read tool** — the athlete context in the system prompt is the read, and every removable entry renders a stable 4-hex content-hash handle (`MemoryRef.id`, e.g. `[3f2a]`) that the `remove_*` fields take, so no get-before-set round-trip. Knowledge base: Markdown in `TriGenius/Assets/Knowledge/` (`CYCLING.md`, `RUNNING.md`, `SWIMMING.md`, `INJURIES.MD`, `WORKOUTS.md`), loaded from the bundle via `knowledgeFiles`.

### `ATPToolHandler` (`Coach/ATPTools.swift`, always on)
The coach's window onto the season plan, composable so each call touches one concern (the engine re-periodizes after any change):
- `get_atp` — config, events **with ids**, pinned weeks, current period + this week's TL, next-A projection; `detail:true` adds the week-by-week upcoming schedule.
- `set_atp` — merge-update the methodology/volume config only.
- `set_atp_event` — upsert one race (omit `event_id` to add; merge-update). `delete_atp_event` removes.
- `pin_atp_week`/`unpin_atp_week` — write/clear an `ATPWeekOverride` locking a week's TL (`tl 0` = rest).

All read/write `TrainingDataStore`'s ATP API; the coach supplies events + params, never weekly numbers. `get_atp` returns JSON; mutating tools return the same state plus a `message`. `promptSection()` injects a compact ATP summary each turn. The ATP is the **single** source of truth for season planning — no separate phase model.

### Conditional handlers
- **`GarminToolHandler`** — only when Garmin is a read source; carries the Garmin-specific `sync_user_settings`.
- **`WebSearchToolHandler`** (`Coach/WebSearchTool.swift`) — only while the backend is OpenRouter *and* the Settings web-search toggle is on (`CoachBrain.setWebSearch`; the on-device backend never leaks queries to the cloud). `web_search` takes a **self-contained query the coach formulates with conversation context** — the point of the tool, since a per-request search plugin would derive its query from the athlete's bare last message — and runs a nested one-shot OpenRouter call (same key, `AppSettings.storedOpenRouterModel()` read at execute time, `web` plugin, `max_results: 3`) returning `{summary, sources}`. Citations also feed `lastReplyWebCitations` → globe badge. The matching prompt bullet renders only while the tool is registered (`{web_search_tool}`).

## Memory (`Coach/CoachMemory.swift`)

A `@MainActor ObservableObject` **façade over the SwiftData coach-memory rows** (`CoachMemoryModels.swift`), assembling them into profile / preferences / weekly-structure / sport-progress / feedback value structs and writing mutations back. It is the sole writer, so the in-memory copy is authoritative. Snake_case keys; each value struct keeps `init(from:)`/`toDict()` so a `coach_memory.json` round-trips through the debug JSON view's manual import/export. No season plan here (that's the ATP); `WeeklyStructure` carries the ATP sport-split `sport_ratio`/`sport_floors`.

Two tiers of authority: **HARD LIMITS** (sport limitations + injuries + the strength areas to work around — the prompt marks them binding) vs **PREFERENCES** (`AthletePreferences.trainingPreferences`, the *one* uniform free-text list via `add_preference`/`remove_preference` — honored by default, overridable; legacy structured fields like morning-workouts/indoor-trainer/no-X-days fold in as plain entries on read, and the next save clears the legacy row fields so a removed entry can't resurrect). `UserProfile.motivation` rides on the goals line.

The **strength profile** (`StrengthProfile`, handoff flow 7) is the one structured part of a sport profile: `trainingPlace` and `excludedAreas` on the `strength` row, exact enum values rather than free text, because code filters on them (`get_exercises`, the exercise picker) — not only the model. Written by Settings → Strength profile (`StrengthProfileView`) and by `update_sport_profile`'s `training_place`/`excluded_areas`; experience is the same row's `level`. The prompt renders the place under SPORT NOTES and each area as a HARD LIMIT.

`contextSummary(history:)` is injected into the system prompt: markers annotated with their as-of-3-months-ago value (`(was …)`, step-function reads from `PerformanceHistory`, never interpolated; Garmin running power deliberately not rendered), every removable entry tagged with its `MemoryRef` handle, and feedback windowed to the last 8 weeks (`feedbackWindowWeeks` — rows persist, only the prompt forgets; the MEMORY prompt section tells the coach to promote durable facts to the profile). "MISSING INFORMATION" drives onboarding — that prompt section renders exactly while key info is missing (no completion flag).

## ProactiveCoach (`Coach/ProactiveCoach.swift`)

Evaluates current state (PMC/form) and emits proactive signals; split from the chat loop so one evaluation feeds two sinks (a system-prompt section now, push notifications later).

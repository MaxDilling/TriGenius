# App entry, Settings & Siri

Detail doc for `App/`, `Features/Settings/`, `AppIntents/`. Index: `CLAUDE.md` → Components.

## `App/TriGeniusApp.swift`

Builds `CoachBrain` once; `applyBackend` re-applies backend + `setSources` + `reconcileWriteTarget` on any settings change. Launch does `syncAll(readSources)` then `reconcileWriteTarget`. Tab UI in `RootTabView`; the season plan (`ATPView`) is no tab — it is pushed from the dashboard's plan line and the Fitness plan / Weekly Target cards.

## Live strength workout (`Features/LiveStrength/`)

A planned strength session worked through in the app, set by set — started from "Start workout" on `PlannedWorkoutDetailView` (only a plan with exercises; one session at a time, the button resumes a running one). `RootTabView` presents it over every tab: a full-screen cover that collapses into a `tabViewBottomAccessory` mini bar on iOS/iPadOS, a sheet on the Mac.

- **`StrengthSession`** (`Analytics/`, pinned by `StrengthSessionTests`) is the pure state: the plan's blocks as units (a circuit unrolled round by round), each set carrying the rest after it; every phase anchored on a `Date`, so a relaunch or a backgrounded app reads exactly. Reordering, "Do now", "Later" (current unit to the end — introduced once by a TipKit tip, `Tips.configure()` in `TriGeniusApp.init`), swapping and adding change the session's record only, never the plan.
- **`LiveStrengthController`** owns the one running session: every change goes through `update`, which writes `live_strength.json` (Application Support, device-local — a killed app resumes), re-arms the next deadline (5 s before a rest ends, its end, a hold's end — which logs the hold) as a haptic `cue`, and disables auto-lock while a session runs. The athlete keeps the phone unlocked; there is no notification or Live Activity (see `FEATURES.md`).
- **Save** → `DataSyncCoordinator.saveLiveStrength` (see `docs/store.md`); **Discard** drops the file and leaves the plan untouched. Nothing is written to Apple Health.
- The exercise demo and form cues are placeholders until the library carries media.

## Activities (`Features/Activities/`)

The Activities tab: every completed workout, read-only, newest first in training weeks. `TrainingDataStore.activityListItems()` fetches only the row columns (never streams or curves) into `ActivityListItem`s; `ActivityList` (`Analytics/`, pinned by `ActivityListTests`) searches them — every word must appear in name, sports or month + year — filters them (`ActivityFilter`: one sport, or multisport sessions only) and totals each week. Search is `searchable` on the Mac and a field in the header on iOS, where the navigation bar is hidden. Under a sport filter a multisport session is listed whole, but the week totals count only that sport's legs (`sportContributions`, as in `TrainingVolume`). A row opens `WorkoutDetailDestination`. `CoachRouter.openWorkout(id:)` pushes the same page from outside the tab (`openedWorkoutID`) — the target of a tapped notification that carries a `workout_id`, which today is the post-workout feedback question `BackgroundCoordinator.askForWorkoutFeedback` posts. After a foreground sync (launch, stale return) the same question comes up as a sheet instead (`router.feedbackWorkoutID` → `WorkoutFeedbackPrompt`); both go through `workoutAwaitingFeedback`/`markFeedbackAsked`, so a workout is asked about once. Rows are the shared `WorkoutRow`, as in the Dashboard's Up Next.

## `App/SparkleUpdater.swift` (macOS only)

Sparkle auto-update for the **Developer-ID** build — the one `Scripts/release.sh` publishes to GitHub Releases, **not** App-Store-compatible (guideline 2.4.5). `SPUStandardUpdaterController` + a "Check for Updates…" app-menu command.

`release.sh` EdDSA-signs the DMG and attaches a single-item `appcast.xml` to each release (Sparkle's SPM-bundled `generate_appcast`; the private key lives in the login Keychain via `generate_keys`); `SUFeedURL` resolves it through `releases/latest/download/`. `SUPublicEDKey`/`SUFeedURL`/`SUEnableInstallerLauncherService` sit in the root `Info.plist`; the sandbox needs the `-spks`/`-spki` mach-lookup exceptions in **both** entitlements files.

The Sparkle SPM dependency is the one thing that *does* live in `project.pbxproj` (macOS-only `platformFilters` on the link step — iOS/iPadOS builds don't carry it).

## `Features/Settings/SettingsView.swift`

`AppSettings` (`ObservableObject`) + the `DataSource`/`WriteTarget` enums. Persists API key, backend/model, `read_sources` (≥1 always on), `metrics_source` (clamped to an enabled read source), `write_target` (Apple Watch hidden on macOS), Garmin email, and `cloud_ai_consent`; `AppSettings.stored*()` expose them to non-SwiftUI callers. `makeBackend()` is the single place backends are built; `makeSummaryBackend()` is the same backend for the dashboard AI summary, on its own OpenRouter model (`availableSummaryModels`, each OpenRouter model a fixed `(model, reasoningEffort)` pair).

Backend defaults to on-device **Apple Intelligence**; the cloud **OpenRouter** backend is gated behind an explicit consent sheet (`CloudAIConsentView`, `cloudAIConsent` → `isConfigured`).

`SettingsView` itself is a **hub**: every root row names a sub-page and shows that page's current state (or what still needs setting up, in the warning colour); nothing is configured on the root. Groups, in the order a new athlete sets up:

- **Connect** — **`ConnectionsView`**: the "Import from" toggles + "Metrics from" picker, one section per enabled source with Garmin login and a `ReadSourceSyncSection` "Re-sync" → `resync(source:)`, the ignored workouts (`IgnoredWorkoutsView`), and the "Send workouts to" picker. `CalendarSettingsView`: calendar access + which calendars the coach considers.
- **Athlete** — `AthleteProfileView` (name/goals as the coach keeps them, reset). **`PerformanceSettingsView`**: every physiological marker as one row by discipline — current value plus a `MetricSource` mark (calculated / synced / entered) — each opening the shared `MetricDetailView`. That detail page carries `MetricCalculationSection` for the markers in `MetricCalculation` (the opt-in switch, source, method, inputs, 80 % range; the running threshold factor on the LT-pace page), so the switch is the same from Settings and from Statistics; it reads `AppSettings` from the environment (`TriGeniusApp` injects it at the root). `HistoryRecompute` is the one "Recompute history" control. **`WeeklyTargetsView`**: swim/bike/run percentage sliders that rebalance to 100 % and write `WeeklyStructure.sportRatio` via `CoachMemory` (the ATP's sport split and, at 0 %, the gate that removes a discipline's weekly-target ring), plus the cross-training-credit slider. `StrengthProfileView`.
- **Coach** — `AIModelSettingsView` (backend picker, per-backend fields, consent sheet) and `NotificationSettingsView` (form alerts, quiet hours, reminders).
- **App** — **`DashboardLayoutView`** (per-section visibility + drag order, `dashboardLayout`).
- **Privacy & Data** — privacy-policy link (`privacyPolicyURL`), **`FeedbackView`** (the chat's reply ratings and the pain reports listed, the feedback export, delete of all chat ratings — see `docs/coach.md`), the medical disclaimer, and **"Delete all my data"** — a full personal-data + consent erase (`deleteTrainingAndATP` + `CoachMemory.reset` + `ReplyRatingStore.deleteAll` + `PainReportStore.deleteAll` + `IgnoredWorkouts.clearAll` + Garmin logout + key/consent clear).

The **Developer** section is `#if DEBUG`-only. A first-launch `MedicalDisclaimerView` gate (`AppStorage("medical_disclaimer_accepted")`) shows from `RootTabView`.

## Siri / App Intents (`AppIntents/`)

Siri AI's window onto the training plan (iOS + macOS). The intents live in the app target and run in the app's own process, so store/Keychain/coordinator access just works.

`PlannedWorkoutEntity`/`PlannedWorkoutQuery` snapshot open plans — next 14 days as `suggestedEntities`, which is what "my Thursday ride" resolves against. `WorkoutIntents.swift` carries get/schedule/move/delete: reads via `TrainingDataStore.openScheduledWorkouts`, writes via `DataSyncCoordinator`'s plan CRUD — so a Siri write gets the identical `WorkoutNormalizer` plausibility rejection (relayed as the intent's error dialog) and write-target push as a coach write. Delete asks Siri-side confirmation first.

`ScheduleWorkoutIntent` is deliberately simple (sport/day/duration/optional name, no step structure — structured workouts stay the coach's job). `TriGeniusAppShortcuts` publishes the zero-setup phrases.

TriGenius Implementation Goals

This document outlines the linear feature roadmap for transitioning TriGenius into a comprehensive TrainingPeaks-style platform. The tasks are written as isolated, actionable steps for AI-assisted implementation.

[x] Implement Local Time-Series Database: Add SwiftData (or SQLite) models to persistently store historical activity data, specifically focusing on extracting and saving the Garmin Training Stress Score (TSS) for fast local access. Keep coach_memory.json untouched for the coach's prompt context.

[x] Implement On-Launch Data Sync: Build a loading mechanism on app startup that actively synchronizes the latest activities from Garmin/Apple Health into the local database, ensuring 100% data freshness before the user interacts with the app.

[ ] Add Chat Debug Mode Toggle: Add a "Debug Mode" toggle to the Settings tab and bind it to the global app state.

[ ] Render Hidden Tool Calls in Chat UI: Modify the Chat view to intercept and display AI tool calls (like get_health_metrics(), add_workout()) as visible system messages in the conversation stream whenever Debug Mode is enabled. Also return all relevant information, like prompts send to the ai, to the console in debug mode. 

[ ] Implement Local PMC (Performance Management Chart) Engine: Write Swift logic to calculate CTL (Fitness, 42-day EWMA), ATL (Fatigue, 7-day EWMA), and TSB (Form) based on the daily TSS values stored in the local database.

[ ] Build Visual Weekly Dashboard: Populate the Health tab with charts and summaries showing the calculated PMC metrics (CTL, ATL, TSB), week-to-date compliance, and recent TSS trends for the past 7 days and the upcoming week. Keep Workoutlist.

[ ] Implement Proactive PMC Coach Triggers: Add logic that evaluates the PMC state and injects a proactive warning into the coach's chat/context if ATL is dangerously high (overtraining risk) or too low (detraining/loss of form).

[ ] Integrate EventKit Calendar View: Request EventKit permissions and visually overlay the user's private/work calendar events (from the native iOS/macOS Calendar) onto the training plan within a new Dashboard view.

[ ] Add AI Tool for Calendar Availability (read_calendar_availability): Create a new tool handler that allows the LLM backend to query the user's EventKit calendar, enabling the coach to schedule workouts specifically in available free time slots.

[ ] Implement Reactive Drag-and-Drop Rescheduling: Allow users to manually move scheduled workouts within the visual calendar/dashboard, automatically triggering a recalculation of the projected weekly load without requiring the AI to move the events.

[ ] Add Proactive Weekly Planning Trigger: Implement a local push notification or a prominent in-app prompt (e.g., triggered every Sunday) that encourages the user to open the app and initiate the weekly planning chat with the AI Coach.
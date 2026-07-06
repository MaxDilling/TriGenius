# TriGenius

An evidence-based AI triathlon coach for iOS, iPadOS, and macOS, built with SwiftUI — TrainingPeaks-style training management (TSS, PMC, annual training plan) with a conversational coach on top.

- **Data sources:** Apple Health and Garmin Connect (read in parallel), planned workouts pushed to Garmin or Apple Watch
- **Analytics:** TSS scoring, CTL/ATL/TSB performance management, power curves, zone distribution, season periodization
- **Coach:** on-device Apple Intelligence by default, optional cloud backends via OpenRouter
- **Sync:** private CloudKit database, so your data follows you across devices

## Requirements

Xcode beta with the iOS/macOS 27 SDK (the on-device coach uses the FoundationModels framework).

## Status

This is a **private project**, built for my own training — no support, no roadmap, no guarantees. That said, feel free to build it and use it for your own personal training.

# TriGenius UI/UX Design System

This document defines the visual language and the SwiftUI implementation rules for TriGenius. Follow it whenever you create or modify UI.

The design system is **code-backed**: tokens and surfaces live in `TriGenius/Shared/DesignSystem/` (`Theme.swift`, `Color+App.swift`, `Surfaces.swift`). Use those instead of hand-rolling values.

## Goals

Modern, compact, data-dense — and deliberately **not** "AI-looking". We integrate AI deeply but signal it quietly. The look is **native and adaptive** (light + dark), not a force-dark neon dashboard.

## 1. Liquid Glass — the real thing

"Liquid Glass" here means **Apple's system API** (`glassEffect(_:in:)`, `GlassEffectContainer`, `.buttonStyle(.glass)`), available on our iOS 26+ / macOS 27 deployment target. We use it — we do **not** reimplement glass with stacked `Material` + blurred color blobs.

**Two layers, kept separate:**

| Layer | What | How |
|---|---|---|
| **Content** | Data-dense content: metrics, lists, detail rows, cards | Opaque grouped backgrounds via `.cardSurface()` (→ `Color.appSecondaryBackground`). Most of the UI is here. |
| **Control / Navigation** | Floating, grouping chrome: toolbars, the coach chat bubble, a day-column container | Real glass via `.glassSurface(tint:)`. |

Rules:
- **Never stack glass on glass**, and never put dense data straight on glass — it muddies contrast. Glass is the floating control layer, not the content layer.
- Prefer **one** glass container over many glass cards (e.g. a whole day column as a single `GlassEffectContainer`, not N glass boxes).
- **No manual ambient blobs / `.blur(radius: 100)` behind glass.** System glass refracts the real content behind it; use `backgroundExtensionEffect()` if you need bleed.
- App background is the **adaptive system background** (`Color.appBackground`), not forced `Color.black`.

## 2. Typography & contrast

- Information density matters — favor tight layouts (`VStack(spacing: Theme.Spacing.xs)`) for metric lists.
- Use the standard type hierarchy (`.largeTitle`, `.title2`, `.subheadline`, `.caption`). **Avoid `.font(.system(size:))`** with fixed sizes.
- **Never apply opacity/translucency to text or data metrics.** The container may be translucent; the numbers on it stay opaque and sharp for outdoor legibility.

## 3. The "Silent AI" approach

We avoid AI-UI clichés. **No** ✨/spark icons, **no** "AI Generated" tags, **no** pulsing/animated glows.

To mark an element the CoachBrain created or modified, use `.coachAccent(_:)` — a **static** tinted hairline border around the surface. That's the whole signal.

**Coach chat:** coach/system replies use a translucent **glass** bubble (`.glassSurface()`); the user's own messages use a **solid** flat color. The material difference is what separates AI insight from user input.

## 4. Layout paradigms (Calendar & Workouts)

- **Reduce vertical scrolling.** Prefer compact horizontal rows over bulky vertical cards in lists; separate entries with thin translucent dividers.
- **Color tinting over icons.** Don't use large discipline icons (swim/bike/run). Use a small icon and lightly **tint** the row/glass with the discipline color.
- **Life vs. training.** Non-training calendar events (Work, Uni) must be visually subordinate: colorless, flat, minimal height — so colored training sessions stand out as the day's anchors.
- **Hero metrics.** In detail views, lift the 2–3 most important metrics (TSS, Duration, IF/TE) into a prominent hero capsule at the top; keep secondary metrics in a compact list below.

## 5. Tokens (`Theme.swift`)

Resolve every spacing / radius / status color to a token — no magic numbers.

- **Spacing:** `Theme.Spacing` — `xs 4 · s 8 · m 12 · l 16 · xl 24`. Favor the tight end.
- **Radius:** `Theme.Radius` — `s 8 · m 12 · l 16` (continuous corners, applied by the surface modifiers).
- **Status colors:** `Theme.Palette` — `warning · success · info · danger` instead of raw `.orange` / `.green` / `.red`.
- **Surfaces:** `.cardSurface()`, `.glassSurface(tint:)`, `.coachAccent(_:)` from `Surfaces.swift`.
- **System colors:** `Color.appBackground` / `appSecondaryBackground` / `appTertiaryBackground` / `appTertiaryLabel` (cross-platform, in `Color+App.swift`).

## 6. Cross-platform (macOS)

The app is multiplatform. Glass, sidebars and window backgrounds behave differently on macOS — the `Color.app*` helpers already map to AppKit equivalents. Don't assume iOS-only chrome; test the macOS destination for any new surface.

## Summary for UI code generation

- Default content to **`.cardSurface()`** (opaque); reserve **`.glassSurface()`** for the floating control/nav layer.
- Use **real `glassEffect`**, never hand-rolled material+blob glass.
- Pull every value from **`Theme`**; never hardcode spacing/radius/status colors.
- Keep it **adaptive** (light + dark), compact, and data-dense.
- Signal AI with a **static** `.coachAccent()` hairline — never a badge or a pulse.

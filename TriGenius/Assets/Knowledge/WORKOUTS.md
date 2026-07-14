# Building Structured Workouts (`add_workouts`)

This document is the contract for the `add_workouts` tool. Read it before creating any
structured session. `add_workouts` takes a list of workouts (`workouts: [ { workout_data, date } ]`)
— **one session is a one-element list, a whole week is several in a single call.** The app
normalizes each item — it fills defaults, builds a step structure if you don't, and widens single
intensity values into sensible bands — and reports every adjustment back to you per item. **Relay the
actual scheduled targets to the athlete, not the single value you sent.**

To list, edit, move, or delete existing workouts, use `get_workouts` (it returns the `workout_id`),
`modify_workout`, `move_workout`, `delete_workout` — see §6–§7.

## 1. Required fields (per workout item)

- `workout_data.name` — short, descriptive (e.g. "Threshold 3×12 min").
- `workout_data.sport` — `running` | `cycling` | `swimming` | `strength` | `yoga` | `cardio` | `other`.
- `date` — `YYYY-MM-DD` (alongside `workout_data`, not inside it).

Plus **at least one** of: `workout_data.duration_minutes` (time goal),
`workout_data.distance_meters` (distance goal, e.g. a 10 km run), or explicit `workout_data.steps`.
You can combine duration and distance. With no steps, the app synthesizes a simple structure from
whichever you give (distance → one distance interval; duration → warm-up / main / cool-down).

## 2. Steps

`workout_data.steps` is optional but strongly preferred for real sessions.

- **Omit `steps`** → the app synthesizes warm-up / main / cool-down from `duration_minutes`
  (warm-up & cool-down ~10%, capped at 5 min each). Fine for "easy 60 min Z2" type sessions.
- **Provide `steps`** for anything structured.

Each step:

| field | meaning |
|-------|---------|
| `type` | `warmup` \| `interval` \| `main` \| `recovery` \| `rest` \| `cooldown` \| `repeat` |
| `end_condition` | `time` \| `distance` \| `lap_button` \| `fixed_rest` — inferred if omitted (distance when `distance_meters` set, `fixed_rest` for timed rests, else time) |
| `duration_seconds` | for time/rest steps |
| `distance_meters` | for distance steps |
| `target_type` + `target_low` | intensity target (see §3) |
| `stroke` | swimming only: `free` \| `breaststroke` \| `backstroke` \| `butterfly` \| `drill` \| `im` |

**Interval sets** use a `repeat` step:

- `repeat_count` — number of iterations (default 4).
- `repeat_steps` — the child steps repeated each iteration (typically one work + one recovery).
- `skip_last_rest` — drop the trailing recovery (default true).

## 3. Targets — units & ranges

**Units (get these exactly right):**

| `target_type` | unit |
|---------------|------|
| `pace` | seconds per km (running/cycling) or per 100 m (swimming). 5:00/km = `300`, 4:00/km = `240`, 1:40/100m = `100` |
| `heart_rate` | bpm |
| `power` | watts |
| `cadence` | rpm |

**Ranges — pass ONE value.** Put the target in `target_low` and leave `target_high` empty.
The app expands it into a band automatically:

| target | band |
|--------|------|
| pace | −20 / +10 s/km (e.g. `300` → 4:40–5:10/km) |
| heart_rate | ±3 bpm |
| power | ±5 % |
| cadence | ±3 rpm |

Only send a distinct `target_low`/`target_high` pair when you deliberately want to override
the automatic band. **Never** send the same value for both — that creates a useless zero-width
zone.

## 4. Defaults the app fills

These are applied automatically and listed back in the result:

- `include_warmup` / `include_cooldown` = true (only when no explicit steps)
- `repeat_count` = 4
- `pool_length` = 50 m (swimming)
- `skip_last_rest` = true

## 5. Worked example — a week in one `add_workouts` call

This is the exact tool **argument object**. The `workouts` array holds one item per session; a single
add is just a one-element array. The items below cover the patterns you'll reuse: minimal (no steps),
pace target (sec/km, distance end), power target (watts, time end), swim (sec/100m, stroke +
fixed_rest), and strength (timed, no targets).

```json
{
  "workouts": [
    {
      "workout_data": { "name": "Easy Z2", "sport": "running", "duration_minutes": 60 },
      "date": "2026-06-23"
    },
    {
      "workout_data": { "name": "Long run 15 km", "sport": "running", "distance_meters": 15000 },
      "date": "2026-06-28"
    },
    {
      "workout_data": {
        "name": "Threshold 5×1000 m",
        "sport": "running",
        "duration_minutes": 50,
        "steps": [
          { "type": "warmup", "duration_seconds": 600 },
          { "type": "repeat", "repeat_count": 5, "repeat_steps": [
              { "type": "interval", "distance_meters": 1000, "target_type": "pace", "target_low": 300 },
              { "type": "recovery", "duration_seconds": 90 }
          ]},
          { "type": "cooldown", "duration_seconds": 300 }
        ]
      },
      "date": "2026-06-24"
    },
    {
      "workout_data": {
        "name": "Sweet-spot 3×12",
        "sport": "cycling",
        "duration_minutes": 60,
        "steps": [
          { "type": "warmup", "duration_seconds": 600 },
          { "type": "repeat", "repeat_count": 3, "repeat_steps": [
              { "type": "interval", "duration_seconds": 720, "target_type": "power", "target_low": 230 },
              { "type": "recovery", "duration_seconds": 300 }
          ]},
          { "type": "cooldown", "duration_seconds": 600 }
        ]
      },
      "date": "2026-06-25"
    },
    {
      "workout_data": {
        "name": "CSS 8×100",
        "sport": "swimming",
        "duration_minutes": 30,
        "pool_length": 25,
        "steps": [
          { "type": "warmup", "distance_meters": 200, "stroke": "free" },
          { "type": "repeat", "repeat_count": 8, "repeat_steps": [
              { "type": "interval", "distance_meters": 100, "stroke": "free", "target_type": "pace", "target_low": 100 },
              { "type": "rest", "duration_seconds": 15, "end_condition": "fixed_rest" }
          ]},
          { "type": "cooldown", "distance_meters": 100, "stroke": "free" }
        ]
      },
      "date": "2026-06-26"
    },
    {
      "workout_data": { "name": "Core & mobility", "sport": "strength", "duration_minutes": 30 },
      "date": "2026-06-27"
    }
  ]
}
```

The result reports each item (`✓ Scheduled 5/5 …`) with the defaults/bands applied to it.

## 6. Editing an existing workout (`modify_workout`)

To change a session that is already scheduled, use `modify_workout` — don't delete and recreate.

1. Call `get_workouts` for the date range. Each `planned[]` item already has a `workout_id` and a
   `workout_data` object — you can pass that object straight back into `modify_workout`.
2. Call `modify_workout` with that `workout_id` and a `workout_data` object containing your changes:
   - **Replace the structure:** include a full `steps` array (same rules as §2–§4; single targets get
     banded automatically). Optionally also change `name`, `duration_minutes`, etc.
   - **Tweak only top-level fields:** omit `steps` and pass just what changes (e.g. `description`
     or `name`). The existing steps are kept intact.

The date is **not** changed by `modify_workout` — to reschedule, use `move_workout`.

Example — retarget an existing run to 6×800 m @ 4:30/km:
```json
{
  "workout_id": "1606973348",
  "workout_data": {
    "name": "VO2 6×800 m",
    "sport": "running",
    "duration_minutes": 45,
    "steps": [
      { "type": "warmup", "duration_seconds": 600 },
      { "type": "repeat", "repeat_count": 6, "repeat_steps": [
          { "type": "interval", "distance_meters": 800, "target_type": "pace", "target_low": 270 },
          { "type": "recovery", "duration_seconds": 120 }
      ]},
      { "type": "cooldown", "duration_seconds": 300 }
    ]
  }
}
```

Example — fix just the description, keep the steps:
```json
{ "workout_id": "1606973348", "workout_data": { "description": "Easier than planned — back off if HR drifts." } }
```

## 7. Planning a week

1. The ATP is the high-level plan: `set_atp` sets the methodology + volume, `set_atp_event` adds/edits
   each race, `delete_atp_event` removes one, and `pin_atp_week`/`unpin_atp_week` lock a specific
   week's TSS (e.g. a vacation = 0). The engine periodizes the weekly TSS + CTL projection. `get_atp`
   reads the current period and this week's TSS target to size the week's sessions.
2. `read_calendar_availability` shows the athlete's real-world busy/free days so you place sessions
   on days that work.
3. `add_workouts` — build the whole week's sessions and schedule them in **one** call (see §5).
4. Adjust later: `get_workouts` to see what's scheduled and get each `workout_id`, then
   `modify_workout` (change content), `move_workout` (change date), or `delete_workout`.

`get_workouts` returns training workouts (all sources merged); `read_calendar_availability` returns
the device calendar (meetings, life) — they are different tools, don't confuse them.

## 8. Reminders

- Respect any sport-specific limitation the athlete has stated (e.g. "no freestyle", knee injury).
- Confirm with the athlete before scheduling, then call `add_workouts`.
- After scheduling, read the result's per-item defaults/adjustments and tell the athlete the real
  targets (e.g. "I set the reps to a 4:40–5:10/km window").

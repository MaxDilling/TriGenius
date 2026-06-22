# Building Structured Workouts (`add_workout`)

This document is the contract for the `add_workout` tool. Read it before creating any
structured session. The app normalizes your input — it fills defaults, builds a step
structure if you don't, and widens single intensity values into sensible bands — and it
reports every adjustment back to you in the tool result. **Relay the actual scheduled
targets to the athlete, not the single value you sent.**

## 1. Required fields

- `workout_data.name` — short, descriptive (e.g. "Threshold 3×12 min").
- `workout_data.sport` — `running` | `cycling` | `swimming` | `strength` | `yoga` | `cardio` | `other`.
- `workout_data.duration_minutes` — total session minutes.
- `date` — `YYYY-MM-DD`.

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
- `pool_length` = 25 m (swimming)
- `skip_last_rest` = true

## 5. Worked examples

**Run — 5×1000 m @ 5:00/km, 90 s jog recovery**
```
warmup       : duration_seconds 600
repeat ×5 of :
  interval   : distance_meters 1000, target_type pace, target_low 300
  recovery   : duration_seconds 90
cooldown     : duration_seconds 300
```

**Bike — sweet-spot 3×12 min @ 230 W, 5 min easy between**
```
warmup       : duration_seconds 600
repeat ×3 of :
  interval   : duration_seconds 720, target_type power, target_low 230
  recovery   : duration_seconds 300
cooldown     : duration_seconds 600
```

**Swim — CSS 8×100 m @ 1:40/100m, 15 s rest (pool_length 25)**
```
warmup       : distance_meters 200, stroke free
repeat ×8 of :
  interval   : distance_meters 100, target_type pace, target_low 100, stroke free
  rest       : duration_seconds 15, end_condition fixed_rest
cooldown     : distance_meters 100, stroke free
```

**Strength** — just `duration_minutes`, no targets; Garmin records it as a timed session.

## 6. Reminders

- Respect any sport-specific limitation the athlete has stated (e.g. "no freestyle", knee injury).
- Confirm with the athlete before scheduling, then call `add_workout`.
- After scheduling, read the result's "Applied defaults & adjustments" block and tell the
  athlete the real targets (e.g. "I set the reps to a 4:40–5:10/km window").

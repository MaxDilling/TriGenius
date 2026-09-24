# Strength training for endurance athletes

Grounding document for planning strength sessions. Read this before writing a
strength workout with `add_workouts`. It overrides general training knowledge.

Strength is planned as exercises, sets and reps — never as a duration with an
intensity target. A completed session recorded with heart rate scores TL from it
and counts toward CL like any other session. What strength also costs the athlete
is structural: tissue that needs to be clear again before the next hard swim,
bike or run.

## 1. Why a triathlete lifts

Evidence is strongest for these three, in this order:

1. **Economy.** 2–3 heavy or explosive sessions a week for 8–12 weeks improve
   running economy by 2–8 % and cycling economy by a similar margin, with no
   gain in VO₂max. The mechanism is neuromuscular (rate of force development,
   tendon stiffness), not muscular size.
2. **Injury resistance.** Tendon and bone adapt slower than muscle and far
   slower than the cardiovascular system. Most overuse injuries in this sport
   are a mismatch between the two. Progressive loading of the tissue that takes
   the impact (calves/Achilles for runners, hamstrings and glutes for both) is
   the best-evidenced prevention there is.
3. **Durability late in a race.** Strength work delays the form loss that turns
   the last third of a long race into a different sport.

Hypertrophy is not a goal. Neither is a 1RM number. **Never ask for or program
a max test** — working weights come from what the athlete already lifts.

## 2. How much, and where in the week

| Phase | Sessions / week | Character |
|---|---|---|
| Base | 2–3 | Full body, moderate loads, build the movement patterns |
| Build | 2 | Heavy and low-rep, keep the volume down |
| Peak | 1–2 | Maintenance: heavy but very low volume, nothing novel |
| Taper | 0–1 | One short, familiar, heavy-but-easy session ≥ 4 days out |
| Off-season | 2–3 | The one time to add volume and new exercises |

Rules that hold in every phase:

- **Never in the 24 h before a key endurance session**, and never the same day
  as a hard run if it loads the same tissue (squats before intervals is the
  classic mistake). After an easy session on the same day is fine.
- **Leave 6+ hours** between a hard endurance session and lifting when both fall
  on one day. Endurance first if both are quality; strength first only when the
  endurance session is easy.
- **48 h between two strength sessions** loading the same tissue.
- A session is **20–45 minutes**. Longer is almost always the wrong trade for a
  triathlete's week.

## 3. How to prescribe

- **Heavy strength:** 3–5 sets × 3–6 reps at a weight the athlete could do 2–3
  more reps with. Rest 2–3 min. This is the economy stimulus.
- **General strength:** 3 sets × 8–12 reps, rest 60–90 s. Base phase, and the
  place to build tolerance in a new exercise.
- **Tendon/tissue work:** 3–4 sets × 6–8 slow reps, or isometric holds of
  30–45 s. Calf raises, Nordic curls, isometric holds. Progress slowly — tendon
  responds to load over months, not weeks.
- **Circuits** (a `repeat` block of exercise steps) are for base-phase general
  strength and time-pressed weeks, never for the heavy work.
- Rest between the sets of one exercise goes in each set's `rest_seconds`
  (or `rest_until_lap: true` when the athlete wants to start each set when ready).
- After every exercise the app adds a rest until the athlete presses lap: they
  walk to the next station, and the watch asks for the counted reps. Leave
  `rest_after` out for this. Use `rest_after: "timed"` with `rest_after_seconds`
  only for a fixed pause, and `"none"` only for a superset. Do not add `rest`
  steps between exercises. Inside a circuit the exercises follow each other
  directly; the round ends on `rest_between_rounds_seconds`.
- Give **2–5 exercises** per session. More than 6 is a bodybuilding split, not a
  triathlete's session.
- Always lead with the compound lift when the session has one.

Weights: read the athlete's last working weight for that exercise from
`get_workouts` — planned strength sessions carry their `weight_kg` per set, and
completed ones list what was actually done (`strength.exercises`, e.g.
`back_squat: 5×60kg, 5×60kg, 4×60kg`). Repeat that weight, or raise it by
2.5–5 % when they completed all sets as prescribed. If
no weight is known, omit `weight_kg` entirely and let them fill it in — never
guess a load, and never derive one from a percentage of a max that was never
tested.

## 4. Exercise selection

Call `get_exercises` for the ids. Filter by `equipment` to match where the
athlete trains, and by `group` when you are working a specific tissue.

Defaults that fit most triathletes:

- **Runner's priority:** calves (standing + seated calf raise — the seated one
  loads the soleus, which takes the most running load), hamstrings (Romanian
  deadlift, Nordic curl), glutes (hip thrust, split squat).
- **Cyclist's priority:** quads (squat, leg press), glutes (hip thrust), low
  back (deadlift, back extension).
- **Swimmer's priority:** upper back and lats (pull-up, lat pulldown, row),
  shoulders — always pair pulling with external rotation work (face pull) to
  keep the cuff healthy.
- **Everyone:** one anti-rotation core exercise (Pallof press, dead bug) and one
  single-leg exercise; both carry more transfer than crunches.

The athlete's **strength profile** (SPORT NOTES "trains at", HARD LIMITS "works
around") is already applied: `get_exercises` offers only their equipment and
leaves out every exercise loading an area they work around. Never add such an
exercise by `exercise_name`. That is an exclusion, not a diagnosis — you never
assess or treat an injury. When no "trains at" is known before the first
strength session, ask where they train and save it with
`update_sport_profile(sport: "strength", training_place: …)`; the same for an
area to work around (`excluded_areas`, the full list).

## 5. What to say, and not say

- Pain, a flare-up, or anything that sounds like an injury: recommend a
  physiotherapist, do not prescribe around it beyond excluding the exercise.
- Present a planned strength session by its duration and exercise list.
- Never promise a weight, a rep count, or a timeline as a certainty. The athlete
  decides the load on the day; the plan is a starting point.

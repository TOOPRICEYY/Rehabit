# Rehabit

A workout tracker with rehab tooling layered on top. Two parts live here:

- `service/`: the data model and the load model in Python, run over exported history so
  the rules can be judged against what actually happened. It also serves the MCP tools.
- `app/`: the iPhone app. `app/RehabitCore` is a Swift package with everything that is
  not a screen and nothing from Apple beyond Foundation; `app/Rehabit` is the SwiftUI app.

Nothing here is clinical advice. The numbers are starting values, labelled as settings.

## The app

`RehabitCore` holds the records and every rule that is not a screen:

- **Logging.** Workouts, sets for each side, isometric holds timed from the clock, warm-ups,
  drop sets and sets to failure, tempo, pain and its kind on a set, rest timers that wait
  for both sides of a round, supersets, plate loading, units for each exercise.
- **Starting points.** Routines (with a prescribed count and tempo where a therapist set
  one), repeating a finished workout, loads prefilled from the same set last time.
- **Injuries.** An injury names tissues and a side. Sessions that load it are followed by
  pain questions (right after, that evening, next morning, 24 and 48 hours) and one daily
  check. An unanswered question stays missing; it is never stored as zero. An injury can
  carry a plan: pain limits, milestones, the next visit. Sessions are counted against the
  limits as within, over or unknown.
- **Load.** The tissue ledger turns sets, daily steps and recorded activities (minutes x a
  rate for the type x a heart-rate intensity) into effective reps for each tissue and side,
  against that side's own usual weight. It is a port of `service/rehabit/
  ledger.py`, and a fixture written by the service holds the two to the same numbers.
- **Reading it back.** Exercise history, records, left against right, a week's summary,
  session effort, a calendar, an injury timeline and a report in Markdown for a therapist,
  recovery readings (heart-rate variability, resting heart rate, sleep, steps) against the
  person's own last four weeks. These describe; none of them scores or advises.
- **Data.** SQLite storage, a JSON snapshot two devices can merge (the newer change wins,
  deletions included), Hevy and Garmin import, a spreadsheet export, deleted workouts kept
  for 30 days, and inbox files prepared on the Mac that the person imports with a tap.
  A session a watch and the phone both recorded is shown as a proposal to review, never
  merged by rule.

    cd app/RehabitCore && swift test          # macOS or Linux (needs libsqlite3-dev)

    brew install xcodegen                     # the app itself needs a Mac with Xcode 15+
    cd app/Rehabit && xcodegen && open Rehabit.xcodeproj

To send a build to TestFlight from a Mac: copy `app/Rehabit/Config/Local.example.xcconfig`
to `Local.xcconfig`, fill in the team (that file is not committed),
then run `app/Rehabit/scripts/testflight.sh`.

After changing the exercise library or the ledger in the service, run
`python3 -m rehabit.cli export-shared` from `service/` to rewrite the app's copy.

Not built yet: a rest timer on the lock screen, load flags on the phone (the service computes them), and Health Connect for
Android.

## What the service does

1. **Schema** (`service/rehabit/schema.sql`). One SQLite file: sessions, sets (with side,
   load convention, reps or isometric hold, pain), injuries, daily metrics, dose events,
   and the derived tables.
2. **Importers** (`service/rehabit/importers/`). Hevy CSV export, Garmin activity
   listings, and a DoesTrack backup. Every imported row names its source, and anything
   inferred (a side, a hold) is marked as inferred.
3. **Tissue ledger** (`ledger.py`). Each set is turned into a dose per tissue and side:

       dose = share x n x (load / reference load) ^ k

   `share` is how much of the exercise that tissue carries (1.0 for a prime mover, see
   `library.py`). `n` is reps, or hold seconds divided by 5. The reference load is the
   heaviest load for that exercise and side in the previous 28 days. `k` is 2, so a
   heavier load costs more than the same percentage of extra reps. At the usual weight a
   dose reads as "effective reps".
4. **Named flags** (`flags.py`). Plain rules with a visible reason: load after 21 days
   with none, a load 10 percent over the 28-day heaviest, back-to-back days, five loaded
   days in nine, a load frozen for six sessions, a session 1.5 times the 28-day longest,
   and so on. The weekly spike (this week against the mean of the previous four) is a
   percentile rule: it fires when the ratio is in the top 5 percent of that tissue's own
   ratios over the trailing year, leaving out the latest fortnight. A fixed 1.5 line
   fired in up to two thirds of ordinary fortnights.
5. **Recovery and steps** (`importers/garmin_daily.py`, `flags.py`). Overnight heart rate
   variability, resting heart rate, sleep and daily steps are stored per day, and missing
   days stay missing. Each is judged as the last 7 days against the 28 days before them,
   so the baseline is the person's own and moves with season or medication. Flags: HRV
   ratio in its own bottom 5 percent, resting heart rate rise or step ratio in its own
   top 5 percent, three short nights in seven, and training while HRV or heart rate is
   flagged. Percentile rules stay silent until there are 30 earlier values.
   Recovery flags apply to every injury; step flags only to hip, thigh, knee and lower leg.
   Steps also count as tissue dose (`ledger.py`, "walking"): each leg takes half the day's
   steps and every 100 steps on a leg count as one effective rep, mostly on the calf and
   Achilles with small shares for the thigh and hip. The weekly spike sees training and
   walking together; the flags about sessions (density, re-entry, compensation) see
   training only, since walking happens every day.
   Recorded activities (a ride, a row, a run, yoga) count as dose too:

       effective reps = minutes x rate(type) x intensity

   The rate (`library.ACTIVITIES`, with how each was worked out) is effective reps a
   minute at a moderate effort, measured in the same unit as walking. For running,
   hiking, stairs and sports it is only what they add beyond their steps, which the
   step count already holds. Intensity is the heart-rate reserve used against that of a
   moderate effort (half), kept between 0.5 and 2, and 1 when a heart rate is unknown.
   A type with no rate adds nothing: an "indoor cardio" recording is often a sauna. What
   the person says a recording was (`counts_as`, "none" for no load) wins over its type.
6. **Replay** (`replay.py`). For each injury with a known onset, lists the flags that
   fired in the two weeks before it, next to the base rate: the share of all comparable
   two-week windows in which the same flag fired. A flag that fires before an injury but
   also fires in most ordinary fortnights tells you nothing.
7. **Read-only MCP server** (`mcp_server.py`). Eleven tools an agent can use to read the
   history, loads and flags. It opens the database read-only and `run_query` accepts a
   single SELECT only.

## Running it

    cd service
    python3 -m rehabit.cli build --db ../data/rehabit.db --profile ../data/profile.json \
        --hevy ../data/hevy.csv --garmin ../data/garmin/*.txt \
        --garmin-daily ../data/garmin_daily/*.json --doestrack ../data/doestrack.json
    python3 -m rehabit.cli replay --db ../data/rehabit.db
    python3 -m rehabit.cli replay --db ../data/rehabit.db --lookback 28 --json

    pip install "mcp>=2"            # only needed for the server
    python3 -m rehabit.cli mcp --db ../data/rehabit.db

    python3 -m pytest               # tests use synthetic data only

The build and replay need nothing beyond the Python standard library (3.10 or later).
`service/profile.example.json` shows the profile format: body weight, which session
titles are rehab sessions, which side each rehab exercise is on, and the injuries.

## Personal data

Exports, the profile and the database live in `data/`, which is ignored by git. No
training or health data belongs in this repository's history, and the tests use made-up
fixtures.

## Known limits

- Garmin listings give per-exercise totals, not sets, and many rows are named "unknown".
  Those rows are kept but carry no tissue load.
- Tissue shares are estimates, stored with `estimate_source = 'default'`.
- Sides for older rehab sessions are inferred from notes and the profile's rules.
- Recovery does not yet change the dose. In the replay it did not separate the run-up to
  an injury from an ordinary fortnight, so it is reported, not acted on.
- A percentile rule cannot fire for a tissue that is loaded too rarely to build a history.
- Step counts include steps taken during runs, so steps and run minutes overlap, and a
  running step is counted like a walking step though it loads the calf far harder.
- 100 steps per effective rep is a starting value, not a measurement.
- Activity rates are worked out from cadence and rough force ratios, not measured. Heart
  rate measures the whole body's work: heat, a poor night or a medicine raise it with no
  extra load on any tissue, and the maximum is the highest one recorded, not tested.
- The replay checks rules against a handful of injuries. That is enough to reject a rule
  that fires all the time, and not enough to tune thresholds without fitting noise.

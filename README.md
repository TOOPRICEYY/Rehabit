# Rehabit

A workout tracker with rehab tooling layered on top. This repository currently holds
phase 0: the data model and the load model, run over exported history before any app
exists, so the rules can be judged against what actually happened.

Nothing here is clinical advice. The numbers are starting values, labelled as settings.

## What phase 0 does

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
4. **Named flags** (`flags.py`). Plain rules with a visible reason: a week 1.5 times the
   mean of the previous four, load after 21 days with none, a load 10 percent over the
   28-day heaviest, back-to-back days, five loaded days in nine, a load frozen for six
   sessions, a session 1.5 times the 28-day longest, and so on.
5. **Replay** (`replay.py`). For each injury with a known onset, lists the flags that
   fired in the two weeks before it, next to the base rate: the share of all comparable
   two-week windows in which the same flag fired. A flag that fires before an injury but
   also fires in most ordinary fortnights tells you nothing.
6. **Read-only MCP server** (`mcp_server.py`). Ten tools an agent can use to read the
   history, loads and flags. It opens the database read-only and `run_query` accepts a
   single SELECT only.

## Running it

    cd service
    python3 -m rehabit.cli build --db ../data/rehabit.db --profile ../data/profile.json \
        --hevy ../data/hevy.csv --garmin ../data/garmin/*.txt --doestrack ../data/doestrack.json
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
- The replay checks rules against a handful of injuries. That is enough to reject a rule
  that fires all the time, and not enough to tune thresholds without fitting noise.

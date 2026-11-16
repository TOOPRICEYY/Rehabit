"""Command line: build the database from exports, replay the flags, serve MCP."""

from __future__ import annotations

import argparse
import json

from . import db, flags, ledger, library, profile as profile_mod, replay as replay_mod
from .importers import doestrack, garmin, hevy


def build(args) -> None:
    con = db.connect(args.db)
    db.init(con)
    library.seed(con)
    prof = profile_mod.load(args.profile)
    summary = {"injuries": profile_mod.seed_injuries(con, prof)}
    if args.hevy:
        summary["hevy"] = hevy.import_csv(con, args.hevy, prof)
    if args.garmin:
        summary["garmin"] = garmin.import_listing(con, args.garmin, prof)
        summary["garmin_sides_paired"] = garmin.pair_sides(con)
    if args.doestrack:
        summary["doestrack"] = doestrack.import_backup(con, args.doestrack)
    summary["ledger"] = ledger.compute(con)
    summary["flags"] = flags.compute(con)
    print(json.dumps(summary, indent=2))


def replay(args) -> None:
    con = db.connect(args.db, read_only=True)
    results = replay_mod.replay(con, args.lookback)
    print(json.dumps(results, indent=2) if args.json else replay_mod.format_report(results))


def serve(args) -> None:
    from .mcp_server import build_server
    build_server(args.db).run(transport="stdio")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="rehabit")
    sub = parser.add_subparsers(required=True)

    b = sub.add_parser("build", help="import exports and compute the ledger and flags")
    b.add_argument("--db", required=True)
    b.add_argument("--profile")
    b.add_argument("--hevy")
    b.add_argument("--garmin", nargs="*")
    b.add_argument("--doestrack")
    b.set_defaults(func=build)

    r = sub.add_parser("replay", help="check the flags against known injury dates")
    r.add_argument("--db", required=True)
    r.add_argument("--lookback", type=int, default=14)
    r.add_argument("--json", action="store_true")
    r.set_defaults(func=replay)

    s = sub.add_parser("mcp", help="serve the read-only MCP tools over stdio")
    s.add_argument("--db", required=True)
    s.set_defaults(func=serve)

    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()

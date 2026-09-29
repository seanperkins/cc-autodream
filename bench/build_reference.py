"""Build, adjudicate and apply the frozen L1 reference (Phase 2). Stdlib only.

  python3 bench/build_reference.py build    majority-vote the reference runs into reference.jsonl
  python3 bench/build_reference.py sheet    write the adjudication sheet (splits + spot checks)
  python3 bench/build_reference.py apply    read your rulings back into reference.jsonl
  python3 bench/build_reference.py status   counts

The reference models are the labels in config.json's `reference.models`; run each one first with
bench/runner.py under that label (for example `--label ref-opus`), then build. The judge (clustering
what the models said) is `reference.judge.model`, with a disk cache so reruns are free.
"""
import argparse
import sys
from collections import Counter
from pathlib import Path

import reference as ref
from common import DATA_DIR, load_config, read_jsonl
from judge import Judge


def _paths(a):
    d = Path(a.ref_dir)
    return d / "reference.jsonl", d / "adjudicate.md", d / "judge-cache.jsonl"


def _has_rulings(rows):
    return any((r.get("adjudication") or {}).get("ruling") for r in rows)


def cmd_build(a, cfg):
    order = [m["label"] for m in cfg["reference"]["models"]]
    run_dirs = {label: Path(a.runs) / label for label in order}
    missing = [l for l, d in run_dirs.items() if not (d / "results.jsonl").is_file()]
    if missing:
        print(f"missing reference runs: {', '.join(missing)} (run bench/runner.py with those labels first)",
              file=sys.stderr)
        return 2
    out, sheet, cache = _paths(a)
    if out.is_file() and _has_rulings(list(read_jsonl(out))) and not a.force:
        print(f"{out} already holds your rulings; rebuilding would discard them. Pass --force to rebuild.",
              file=sys.stderr)
        return 2
    j = cfg["reference"]["judge"]
    judge = Judge(j["model"], j["effort"], cache, claude_bin=a.claude_bin, workers=j.get("workers", 3))
    rows = ref.build_all(list(read_jsonl(a.cases)), run_dirs, judge, order)
    ref.save_reference(rows, out)
    print(f"built {len(rows)} reference rows -> {out}")
    print(f"judge {judge.model}: {judge.calls} calls, {judge.hits} cached, {judge.errors} failed")
    return cmd_status(a, cfg)


def cmd_sheet(a, cfg):
    out, sheet, _ = _paths(a)
    rows = list(read_jsonl(out))
    if not rows:
        print(f"no reference at {out}; run `build` first", file=sys.stderr)
        return 2
    if sheet.is_file() and any(l.startswith("RULING:") and l[len("RULING:"):].strip()
                               for l in sheet.read_text(encoding="utf-8").splitlines()) and not a.force:
        print(f"{sheet} already holds your rulings; regenerating would discard them. Pass --force.", file=sys.stderr)
        return 2
    order = [m["label"] for m in cfg["reference"]["models"]]
    run_dirs = {label: Path(a.runs) / label for label in order}
    spot = ref.pick_spotchecks(rows, cfg["reference"]["spotchecks"], cfg["reference"]["seed"])
    rows = ref.write_sheet(rows, list(read_jsonl(a.cases)), run_dirs, order, spot, sheet)
    ref.save_reference(rows, out)
    splits = sum(1 for r in rows if r["outcome_status"] == "split")
    print(f"wrote {sheet}: {splits} outcome splits and {len(spot)} spot checks to rule on")
    return 0


def cmd_apply(a, cfg):
    out, sheet, _ = _paths(a)
    rows = list(read_jsonl(out))
    if not sheet.is_file() or not rows:
        print("need both reference.jsonl and adjudicate.md; run `build` and `sheet` first", file=sys.stderr)
        return 2
    stats = ref.apply_rulings(rows, ref.parse_sheet(sheet))
    ref.save_reference(rows, out)
    checked = stats["spot_ok"] + stats["spot_bad"]
    ok_rate = f"{stats['spot_ok']}/{checked} OK" if checked else "none ruled yet"
    print(f"applied: splits resolved {stats['split_resolved']}, unresolved {stats['split_unresolved']}; "
          f"spot checks {ok_rate}, pending {stats['spot_pending']}")
    return cmd_status(a, cfg)


def cmd_status(a, cfg):
    out, _, _ = _paths(a)
    rows = list(read_jsonl(out))
    if not rows:
        print(f"no reference at {out}", file=sys.stderr)
        return 2
    st = Counter(r["outcome_status"] for r in rows)
    fnd = [f for r in rows for f in r["findings"]]
    print(f"reference: {len(rows)} cases | outcome {dict(st)} | excluded {sum(1 for r in rows if r['excluded'])}"
          f" | confirmed findings {sum(1 for f in fnd if f['confirmed'])}, unconfirmed {sum(1 for f in fnd if not f['confirmed'])}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("command", choices=["build", "sheet", "apply", "status"])
    ap.add_argument("--runs", default=str(DATA_DIR / "runs"))
    ap.add_argument("--cases", default=str(DATA_DIR / "cases.jsonl"))
    ap.add_argument("--ref-dir", default=str(DATA_DIR / "reference"))
    ap.add_argument("--config", default=None)
    ap.add_argument("--claude-bin", default="claude")
    ap.add_argument("--force", action="store_true", help="overwrite a reference or sheet that holds your rulings")
    a = ap.parse_args(argv)
    return {"build": cmd_build, "sheet": cmd_sheet, "apply": cmd_apply, "status": cmd_status}[a.command](a, load_config(a.config))


if __name__ == "__main__":
    sys.exit(main())

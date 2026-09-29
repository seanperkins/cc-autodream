"""Pick and freeze the L1 benchmark case set. Stdlib only.

Scans historical L1 findings, keeps sessions whose transcript still exists, picks a
stratified sample, and freezes the exact bytes each candidate will read (slimmed the
way production slims them) plus the stats sidecar, into bench/data/. Frozen inputs
hold session content: bench/data/ is gitignored and never committed.

Gated sessions (below the noise gate) and error stubs are excluded: production never
sends them to an L1 model, so they measure nothing.

Usage: python3 bench/sample_cases.py [--n 60] [--seed 7] [--findings-root DIR] [--out DIR]
"""
import argparse
import json
import random
import shutil
import subprocess
import sys
from pathlib import Path

from common import DATA_DIR, REPO, read_jsonl, session_hash  # noqa: F401

SKIP_NAMES = ("memory-candidates.json",)
DEFAULT_ROOT = Path.home() / ".claude" / "autodream" / "findings"
SLIM_BYTES = 262144  # AUTODREAM_SLIM_BYTES default in bin/run.sh


def size_bucket(nbytes):
    if nbytes < 64 * 1024:
        return "lt64k"
    if nbytes < 256 * 1024:
        return "lt256k"
    if nbytes < 1024 * 1024:
        return "lt1m"
    return "ge1m"


def iter_findings(root):
    """Yield (date, findings_path, obj) for every per-session findings JSON under root."""
    for day in sorted(Path(root).glob("20*")):
        if not day.is_dir():
            continue
        for f in sorted(day.glob("*.json")):
            if f.name.endswith(".stats.json") or f.name in SKIP_NAMES or f.name.startswith("skill-backfill"):
                continue
            try:
                obj = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if isinstance(obj, dict):
                yield day.name, f, obj


def build_records(root):
    """One record per session (latest findings file wins). Eligible only when the file is
    a real triage (no error/skipped), the transcript exists, and the stats sidecar exists."""
    latest = {}
    for date, f, obj in iter_findings(root):
        sp = obj.get("session_path")
        if not isinstance(sp, str) or "error" in obj or "skipped" in obj:
            continue
        stats = f.with_name(f.stem + ".stats.json")
        if not Path(sp).is_file() or not stats.is_file():
            continue
        prev = latest.get(sp)
        if prev is not None and prev["date"] > date:
            continue
        outcome = obj.get("outcome")
        findings = obj.get("findings") if isinstance(obj.get("findings"), list) else []
        size = Path(sp).stat().st_size
        project = obj.get("project") or "unknown"
        latest[sp] = {
            "case_id": session_hash(sp),
            "date": date,
            "session_path": sp,
            "stats_src": str(stats),
            "findings_src": str(f),
            "project": project,
            "size_bytes": size,
            "stratum": "|".join([project, size_bucket(size), str(outcome), "F" if findings else "-"]),
            "hist": {"outcome": outcome, "underlying_goal": obj.get("underlying_goal"),
                     "findings": findings},
        }
    return list(latest.values())


def select(records, n, seed):
    """Round-robin over strata (deterministic for a seed) until n sessions are chosen."""
    rng = random.Random(seed)
    strata = {}
    for r in sorted(records, key=lambda r: r["case_id"]):
        strata.setdefault(r["stratum"], []).append(r)
    for rows in strata.values():
        rng.shuffle(rows)
    keys = sorted(strata)
    chosen = []
    while len(chosen) < n and any(strata[k] for k in keys):
        for k in keys:
            if strata[k] and len(chosen) < n:
                chosen.append(strata[k].pop())
    return chosen


def freeze(chosen, out_dir, slim_script, slim_bytes=SLIM_BYTES):
    """Copy (or slim) each transcript and copy its stats sidecar into out_dir/inputs/.
    Writes out_dir/cases.jsonl and returns the rows."""
    out_dir = Path(out_dir)
    inputs = out_dir / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    rows = []
    for r in chosen:
        cid = r["case_id"]
        dst = inputs / f"{cid}.jsonl"
        slimmed = False
        if r["size_bytes"] > slim_bytes and Path(slim_script).is_file():
            cp = subprocess.run([str(slim_script), r["session_path"], str(dst)],
                                capture_output=True)
            slimmed = cp.returncode == 0 and dst.is_file() and dst.stat().st_size > 0
        if not slimmed:  # production reads the original when slimming fails
            shutil.copyfile(r["session_path"], dst)
        shutil.copyfile(r["stats_src"], inputs / f"{cid}.stats.json")
        rows.append({
            "case_id": cid, "session_path": r["session_path"],
            "transcript": f"inputs/{cid}.jsonl", "stats": f"inputs/{cid}.stats.json",
            "project": r["project"], "size_bytes": r["size_bytes"], "slimmed": slimmed,
            "stratum": r["stratum"], "hist": r["hist"], "findings_src": r["findings_src"],
        })
    with (out_dir / "cases.jsonl").open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--findings-root", default=str(DEFAULT_ROOT))
    ap.add_argument("--out", default=str(DATA_DIR))
    ap.add_argument("--slim-script", default=str(REPO / "bin" / "slim-transcript.sh"))
    a = ap.parse_args(argv)
    records = build_records(a.findings_root)
    if not records:
        print(f"no eligible sessions under {a.findings_root}", file=sys.stderr)
        return 2
    chosen = select(records, a.n, a.seed)
    rows = freeze(chosen, a.out, a.slim_script)
    print(f"{len(records)} eligible sessions; froze {len(rows)} into {a.out}/cases.jsonl "
          f"({sum(1 for r in rows if r['slimmed'])} slimmed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

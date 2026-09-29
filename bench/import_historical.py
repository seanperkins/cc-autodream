"""Import the historical L1 outputs for the frozen cases as a benchmark run. Stdlib only.

No model calls: it copies the findings each case already has on disk into a run directory,
so the grader can be calibrated on real production output before any subscription usage
is spent. Its `abstain_excess` is 0 by construction (it is the stand-in reference).

Usage: python3 bench/import_historical.py [--cases PATH] [--out DIR] [--label historical]
"""
import argparse
import json
import shutil
import sys
from pathlib import Path

from common import DATA_DIR, append_jsonl, read_jsonl
from runner import findings_status


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cases", default=str(DATA_DIR / "cases.jsonl"))
    ap.add_argument("--out", default=str(DATA_DIR / "runs"))
    ap.add_argument("--label", default="historical")
    a = ap.parse_args(argv)
    run_dir = Path(a.out) / a.label
    (run_dir / "findings").mkdir(parents=True, exist_ok=True)
    (run_dir / "results.jsonl").write_text("", encoding="utf-8")
    (run_dir / "run.json").write_text(json.dumps(
        {"model": "historical", "effort": "", "label": a.label, "reps": 1}), encoding="utf-8")
    n = 0
    for case in read_jsonl(a.cases):
        src = Path(case.get("findings_src", ""))
        if not src.is_file():
            continue
        dst = run_dir / "findings" / f"{case['case_id']}_rep0.json"
        shutil.copyfile(src, dst)
        append_jsonl(run_dir / "results.jsonl", {
            "case_id": case["case_id"], "rep": 0, "requested_model": "historical", "effort": "",
            "served_model": None, "served_verified": None, "status": findings_status(dst),
            "findings_path": str(dst.relative_to(run_dir)), "usage": {}, "api_cost_usd": None,
            "latency_s": None, "retries": 0})
        n += 1
    print(f"imported {n} historical outputs into {run_dir}")
    return 0 if n else 2


if __name__ == "__main__":
    sys.exit(main())

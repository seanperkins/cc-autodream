"""Render graded L1 runs as a markdown comparison table. Stdlib only.

No blended score: quality checks, latency, tokens and API-equivalent cost stay in
separate columns. Gate-passers are listed first; Phase 1 has no quality ranking beyond
the gate (Phase 2 adds agreement with the reference).

Usage: python3 bench/report.py [--runs DIR ...] [--out PATH]
"""
import argparse
import json
import sys
from pathlib import Path

from common import DATA_DIR

NOTES = [
    "`abstain_excess` is measured against Haiku's historical outcome for the same session "
    "(the Phase 1 stand-in for the reference), so a Haiku candidate scores 0 by construction.",
    "Rates show a 95% Wilson interval and the denominator. Differences smaller than the "
    "interval are within noise.",
    "Evidence is graded in tiers: verbatim quote, else anchored (its quoted commands and identifiers "
    "appear in the transcript), else unverifiable (nothing checkable) or ungrounded. Only ungrounded "
    "counts as hallucinated. Production L1 mostly paraphrases, so verbatim is informational.",
    "Cost is the CLI's API-equivalent list cost, shown for information: runs use the subscription.",
]


def fmt_rate(r):
    if r is None or r["rate"] is None:
        return "n/a"
    lo, hi = r["ci"]
    return f"{r['rate'] * 100:.0f}% ({lo * 100:.0f}-{hi * 100:.0f}, n={r['n']})"


def fmt_num(v, digits=1, prefix=""):
    return "n/a" if v is None else f"{prefix}{v:.{digits}f}"


def row(s):
    m, p = s["metrics"], s["perf"]
    gate = m["gate"]
    errs = ", ".join(f"{k}:{v}" for k, v in sorted(p["errors"].items())) or "0"
    tokens = "n/a"
    if p["mean_input_tokens"] is not None:
        tokens = (f"{p['mean_input_tokens'] + (p['mean_cache_creation_tokens'] or 0):.0f} in / "
                  f"{p['mean_output_tokens']:.0f} out")
    return "| " + " | ".join([
        s["label"],
        "PASS" if gate["pass"] else "FAIL: " + ", ".join(gate["failed"]),
        str(s["rows"]),
        fmt_rate(m["validity"]), fmt_rate(m["authoritative"]), fmt_rate(m["hallucination"]),
        fmt_rate(m["verbatim"]), fmt_rate(m["abstain_excess"]), fmt_rate(m["header_only"]),
        f"{fmt_num(p['latency_p50_s'])} / {fmt_num(p['latency_p95_s'])} s",
        tokens, fmt_num(p["api_cost_usd_per_case"], 3, "$"), errs,
        str(p["unverified_served_model"]),
    ]) + " |"


REF_NOTES = [
    "Agreement is measured against the frozen reference (majority of the reference models, adjudicated by "
    "you). Findings: recall is the share of the reference's confirmed findings the candidate reported; "
    "precision (strict) counts a candidate finding only if it matches a confirmed one, precision (lenient) "
    "also accepts findings only one reference model reported.",
    "Goal and finding matches are judged by a model that is never the candidate. `unjudged` counts "
    "comparisons whose judge call failed; they are excluded, never guessed.",
]


def _pct(r):
    return "n/a" if r is None or r["rate"] is None else f"{r['rate'] * 100:.0f}% (n={r['n']})"


def ref_row(s):
    m = s["reference_metrics"]
    d = m["outcome_distance"]
    return "| " + " | ".join([
        s["label"], str(m["cases_scored"]), _pct(m["outcome_match"]),
        "n/a" if d["mean"] is None else f"{d['mean']:.2f} (n={d['n']})",
        _pct(m["goal_same"]), _pct(m["goal_same_or_partial"]), _pct(m["finding_recall"]),
        f"{_pct(m['finding_precision_strict'])} / {_pct(m['finding_precision_lenient'])}",
        _pct(m["instruction_recall"]), _pct(m["instruction_precision"]), str(m["unjudged"]),
    ]) + " |"


def render_reference(summaries):
    graded = [s for s in summaries if s.get("reference_metrics")]
    if not graded:
        return []
    head = ("| candidate | cases scored | outcome match | mean outcome distance | goal same | "
            "goal same or partial | finding recall | finding precision (strict / lenient) | "
            "instruction recall | instruction precision | unjudged |")
    lines = ["", "## Agreement with the reference", "", head, "|" + "---|" * 11]
    lines += [ref_row(s) for s in sorted(graded, key=lambda s: s["label"])]
    lines += [""] + [f"- {n}" for n in REF_NOTES]
    return lines


def render(summaries):
    order = sorted(summaries, key=lambda s: (not s["metrics"]["gate"]["pass"], s["label"]))
    head = ("| candidate | gate | rows | validity | authoritative | hallucinated evidence | "
            "verbatim evidence | abstain_excess | header-only | latency p50 / p95 | tokens per case | "
            "API-equiv $/case | errors | unverified model |")
    sep = "|" + "---|" * 14
    lines = ["# L1 benchmark (Phase 1: objective checks)", "", head, sep]
    lines += [row(s) for s in order]
    notes = list(NOTES)
    if summaries and all(s.get("abstain_source") == "reference" for s in summaries):
        notes[0] = ("`abstain_excess` is measured against the frozen reference outcome for the same session "
                    "(cases the reference left undecided or excluded are not counted).")
    lines += render_reference(summaries)
    lines += ["", "## Notes", ""] + [f"- {n}" for n in notes]
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--runs", nargs="*", default=None)
    ap.add_argument("--out", default=str(DATA_DIR / "report.md"))
    a = ap.parse_args(argv)
    runs = [Path(r) for r in a.runs] if a.runs else sorted((DATA_DIR / "runs").glob("*"))
    summaries = []
    for r in runs:
        f = r / "summary.json"
        if f.is_file():
            summaries.append(json.loads(f.read_text(encoding="utf-8")))
        else:
            print(f"skipping {r}: no summary.json (run grade_l1.py first)", file=sys.stderr)
    if not summaries:
        print("nothing to report", file=sys.stderr)
        return 2
    Path(a.out).write_text(render(summaries), encoding="utf-8")
    print(f"wrote {a.out} ({len(summaries)} candidates)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

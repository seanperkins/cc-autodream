"""Objective grading of L1 triage output (Phase 1). Stdlib only.

Four reference-free checks per output, then rates per candidate and an eligibility gate:
  1. validity           schema, enums, caps, retired category, zeroed satisfaction_signals
  2. authoritative      fields the prompt says to copy must equal the stats sidecar
  3. grounding          every finding's evidence must be checkable in the frozen transcript:
                        verbatim match, else its quoted/identifier fragments (Haiku paraphrases)
  4. depth              abstain_excess: says unclear_from_transcript where the historical
                        stand-in (Haiku, Phase 1) decided an outcome; header-only phrases

Usage: python3 bench/grade_l1.py --run bench/data/runs/<label> [--cases PATH] [--config PATH]
"""
import argparse
import difflib
import json
import re
import statistics
import sys
from pathlib import Path

from common import DATA_DIR, load_config, rate, read_jsonl

CATEGORIES = {
    "missed_skill", "wrong_skill", "sandbox_friction", "memory_miss", "tool_loop",
    "permission_prompt", "fabricated_id", "stop_projection", "drift_after_compaction",
    "buggy_code_shipped",
}
SEVERITIES = {"high", "medium", "low"}
OUTCOMES = ("fully_achieved", "mostly_achieved", "partially_achieved", "not_achieved",
            "unclear_from_transcript")
DECIDED = set(OUTCOMES[:4])
AUTHORITATIVE = ("turn_count", "tool_call_count", "tools_used", "skills_invoked",
                 "models_used", "compliance_markers")
LIST_KEYS = {"tools_used", "skills_invoked", "models_used"}
HEADER_ONLY = re.compile(
    r"(?:only|just)[^.;]{0,40}\bheader\b|not reviewed|not summari[sz]ed|transcript body not",
    re.I)


def check_validity(obj):
    """List of problems; empty means valid."""
    if not isinstance(obj, dict):
        return ["not an object"]
    problems = []
    if "error" in obj:
        problems.append("error object")
    if not isinstance(obj.get("session_path"), str):
        problems.append("session_path missing")
    if obj.get("outcome") not in OUTCOMES:
        problems.append(f"outcome {obj.get('outcome')!r}")
    findings = obj.get("findings")
    if not isinstance(findings, list):
        problems.append("findings not a list")
    else:
        if len(findings) > 10:
            problems.append("more than 10 findings")
        for i, f in enumerate(findings):
            if not isinstance(f, dict):
                problems.append(f"finding {i} not an object")
                continue
            cat = f.get("category")
            if cat == "assumption_unsurfaced":
                problems.append("retired category assumption_unsurfaced")
            elif cat not in CATEGORIES:
                problems.append(f"finding {i} category {cat!r}")
            if f.get("severity") not in SEVERITIES:
                problems.append(f"finding {i} severity {f.get('severity')!r}")
            for k in ("what", "evidence_excerpt", "proposed_rule"):
                v = f.get(k)
                if not isinstance(v, str) or not v.strip():
                    problems.append(f"finding {i} {k} missing")
    sat = obj.get("satisfaction_signals")
    if not isinstance(sat, dict) or any(v != 0 for v in sat.values()):
        problems.append("satisfaction_signals not all zero")
    ig = obj.get("instructions_given")
    if not isinstance(ig, list) or len(ig) > 3 or not all(isinstance(x, str) for x in ig):
        problems.append("instructions_given invalid")
    return problems


def _norm_list(v):
    if isinstance(v, list):
        try:
            return sorted(v)
        except TypeError:
            return v
    return v


def check_authoritative(obj, stats):
    """Names of authoritative fields that differ from the stats sidecar."""
    bad = []
    for k in AUTHORITATIVE:
        if k not in stats:
            continue
        a, b = obj.get(k), stats[k]
        if k in LIST_KEYS:
            a, b = _norm_list(a), _norm_list(b)
        if a != b:
            bad.append(k)
    return bad


def normalize(s):
    return re.sub(r"\s+", " ", s).strip().lower()


def _collect_strings(v, out):
    """Strings, dict keys and scalar values (so `"is_error": true` is searchable)."""
    if isinstance(v, str):
        out.append(v)
    elif isinstance(v, dict):
        for k, x in v.items():
            out.append(str(k))
            _collect_strings(x, out)
    elif isinstance(v, list):
        for x in v:
            _collect_strings(x, out)
    elif v is not None:
        out.append(json.dumps(v))


def transcript_text(path):
    """All string content of a JSONL transcript, joined and normalized for matching."""
    parts = []
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            _collect_strings(json.loads(line), parts)
        except json.JSONDecodeError:
            parts.append(line)
    return normalize(" ".join(parts))


def is_grounded(excerpt, haystack, min_ratio=0.85):
    ex = normalize(excerpt)
    if not ex:
        return False
    if ex in haystack:
        return True
    ex = ex.strip(" .…\"'`")
    if not ex or ex in haystack:
        return bool(ex)
    if len(ex) < 12:
        return False
    n = len(ex)
    step = max(1, n // 4)
    sm = difflib.SequenceMatcher(autojunk=False)
    sm.set_seq2(ex)
    for i in range(0, max(1, len(haystack) - n + 1), step):
        sm.set_seq1(haystack[i:i + n])
        if (sm.real_quick_ratio() >= min_ratio and sm.quick_ratio() >= min_ratio
                and sm.ratio() >= min_ratio):
            return True
    return False


# Single quotes only count when they wrap a span (not contractions or stray apostrophes).
QUOTED = re.compile(r"(?<![a-z0-9])'([^']{4,200}?)'(?![a-z0-9])|\"([^\"]{4,200}?)\"|`([^`]{3,200}?)`")
SPECIAL = re.compile(r"[a-z0-9_.\-/:]{6,}")


def compact(s):
    """Lowercase alphanumerics only: matching that ignores spacing and punctuation."""
    return re.sub(r"[^a-z0-9]", "", s.lower())


def anchors(excerpt):
    """Checkable fragments of an excerpt: quoted spans, and tokens containing _ / . or :
    (commands, paths, identifiers). Production L1 often paraphrases with line references
    instead of quoting verbatim, so these are what can still be checked. Fragments with
    no letters (line references such as 84/88/93) are not checkable and are skipped."""
    ex = normalize(excerpt)
    found = [next(g for g in m.groups() if g) for m in QUOTED.finditer(ex)]
    for w in SPECIAL.findall(ex):
        w = w.strip(".:-/")
        if any(c in w for c in "_/.:"):
            found.append(w)
    out, seen = [], set()
    for a in found:
        c = compact(a)
        if len(c) >= 4 and re.search(r"[a-z]", c) and c not in seen:
            seen.add(c)
            out.append(a)
    return out


def ground_finding(excerpt, haystack, min_ratio=0.85, hay_compact=None):
    """'verbatim' (fuzzy match of the whole excerpt), 'anchored' (at least half of its
    quoted/identifier fragments appear in the transcript), 'unverifiable' (nothing
    checkable to look for), or 'ungrounded' (checkable fragments, most of them absent)."""
    if is_grounded(excerpt, haystack, min_ratio):
        return "verbatim"
    a = anchors(excerpt)
    if not a:
        return "unverifiable"
    hc = hay_compact if hay_compact is not None else compact(haystack)
    hits = sum(1 for x in a if compact(x) in hc)
    return "anchored" if hits * 2 >= len(a) else "ungrounded"


def depth_flags(obj, hist_outcome):
    ni = " ".join(x for x in (obj.get("notable_initiatives") or []) if isinstance(x, str))
    return {
        "decided_ref": hist_outcome in DECIDED,
        "abstained": obj.get("outcome") == "unclear_from_transcript",
        "header_only": bool(HEADER_ONLY.search(ni)),
    }


def grade_row(row, case, obj, stats, haystack, cfg):
    """Grade one result row. obj is the parsed findings JSON (or None)."""
    g = {"case_id": row["case_id"], "rep": row["rep"], "status": row["status"],
         "valid": False, "problems": [], "authoritative_ok": None, "auth_mismatch": [],
         "findings_n": 0, "ungrounded_n": 0, "grounding": None, "depth": None}
    if row["status"] != "ok" or obj is None:
        g["problems"] = [row["status"] if row["status"] != "ok" else "unreadable"]
        return g
    g["problems"] = check_validity(obj)
    g["valid"] = not g["problems"]
    if not g["valid"]:
        return g
    g["auth_mismatch"] = check_authoritative(obj, stats)
    g["authoritative_ok"] = not g["auth_mismatch"]
    ratio = cfg["grounding"]["min_ratio"]
    findings = obj["findings"]
    g["findings_n"] = len(findings)
    hc = compact(haystack)
    tiers = [ground_finding(f["evidence_excerpt"], haystack, ratio, hc) for f in findings]
    g["grounding"] = {k: tiers.count(k) for k in ("verbatim", "anchored", "unverifiable", "ungrounded")}
    g["ungrounded_n"] = g["grounding"]["ungrounded"]
    g["depth"] = depth_flags(obj, (case.get("hist") or {}).get("outcome"))
    return g


def evaluate_gate(m, cfg):
    t, failed = cfg["gate"], []
    v = m["validity"]["rate"]
    if v is None or v < t["validity_min"]:
        failed.append("validity")
    a = m["authoritative"]["rate"]
    if a is None or a < t["authoritative_min"]:
        failed.append("authoritative")
    h = m["hallucination"]["rate"]
    if h is not None and h > t["hallucination_max"]:
        failed.append("hallucination")
    x = m["abstain_excess"]["rate"]
    if x is None:
        failed.append("abstain_excess_unmeasured")
    elif x > t["abstain_excess_max"]:
        failed.append("abstain_excess")
    return {"pass": not failed, "failed": failed}


def aggregate(graded, cfg):
    """Rates with Wilson intervals, then the gate. graded = list of grade_row dicts."""
    valid = [g for g in graded if g["valid"]]
    decided = [g for g in valid if g["depth"]["decided_ref"]]
    m = {
        "validity": rate(len(valid), len(graded)),
        "authoritative": rate(sum(1 for g in valid if g["authoritative_ok"]), len(valid)),
        "hallucination": rate(sum(g["ungrounded_n"] for g in valid),
                              sum(g["findings_n"] for g in valid)),
        "abstain_excess": rate(sum(1 for g in decided if g["depth"]["abstained"]), len(decided)),
        "header_only": rate(sum(1 for g in valid if g["depth"]["header_only"]), len(valid)),
        "verbatim": rate(sum(g["grounding"]["verbatim"] for g in valid),
                         sum(g["findings_n"] for g in valid)),
    }
    m["gate"] = evaluate_gate(m, cfg)
    return m


def perf_summary(rows, errors):
    lat = sorted(r["latency_s"] for r in rows if r.get("latency_s") is not None)

    def pct(p):
        return lat[min(len(lat) - 1, int(p * len(lat)))] if lat else None

    def mean_of(key):
        vals = [r["usage"].get(key, 0) for r in rows if r.get("usage")]
        return statistics.mean(vals) if vals else None
    costs = [r["api_cost_usd"] for r in rows if r.get("api_cost_usd") is not None]
    by_class = {}
    for e in errors:
        by_class[e["failure_class"]] = by_class.get(e["failure_class"], 0) + 1
    return {
        "latency_p50_s": pct(0.5), "latency_p95_s": pct(0.95),
        "mean_input_tokens": mean_of("input_tokens"), "mean_output_tokens": mean_of("output_tokens"),
        "mean_cache_creation_tokens": mean_of("cache_creation_input_tokens"),
        "api_cost_usd_per_case": statistics.mean(costs) if costs else None,
        "api_cost_usd_total": sum(costs) if costs else None,
        "errors": by_class, "unverified_served_model": sum(1 for r in rows if r.get("served_verified") is None),
    }


def grade_run(run_dir, cases_path, cfg):
    run_dir = Path(run_dir)
    cases = {c["case_id"]: c for c in read_jsonl(cases_path)}
    data = Path(cases_path).parent
    rows = {}
    for r in read_jsonl(run_dir / "results.jsonl"):
        rows[(r["case_id"], r["rep"])] = r
    errors = list(read_jsonl(run_dir / "errors.jsonl"))
    hay, stats_cache, graded = {}, {}, []
    for (cid, rep), row in sorted(rows.items()):
        case = cases.get(cid)
        if case is None:
            continue
        obj = None
        if row["status"] == "ok":
            try:
                obj = json.loads((run_dir / row["findings_path"]).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                obj = None
        if cid not in stats_cache:
            stats_cache[cid] = json.loads((data / case["stats"]).read_text(encoding="utf-8"))
            hay[cid] = transcript_text(data / case["transcript"])
        graded.append(grade_row(row, case, obj, stats_cache[cid], hay[cid], cfg))
    meta = {}
    if (run_dir / "run.json").exists():
        meta = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    summary = {"label": run_dir.name, "model": meta.get("model"), "effort": meta.get("effort"),
               "rows": len(graded), "metrics": aggregate(graded, cfg),
               "perf": perf_summary(list(rows.values()), errors)}
    with (run_dir / "graded.jsonl").open("w", encoding="utf-8") as f:
        for g in graded:
            f.write(json.dumps(g, ensure_ascii=False) + "\n")
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--run", required=True)
    ap.add_argument("--cases", default=str(DATA_DIR / "cases.jsonl"))
    ap.add_argument("--config", default=None)
    a = ap.parse_args(argv)
    s = grade_run(a.run, a.cases, load_config(a.config))
    gate = s["metrics"]["gate"]
    print(f"{s['label']}: {s['rows']} rows, gate {'PASS' if gate['pass'] else 'FAIL ' + ','.join(gate['failed'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

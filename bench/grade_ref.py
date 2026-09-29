"""Score candidates against the frozen reference (Phase 2). Stdlib only.

For every valid candidate output, against the reference row for the same case:
  outcome        exact match, and distance on the ordered scale fully..not_achieved
  goal           judged same / partial / different (skipped when the reference has no goal)
  findings       recall of the reference's confirmed findings; precision of the candidate's
                 findings against confirmed ones (strict) and confirmed + unconfirmed (lenient)
  instructions   the same recall and precision
Excluded reference rows (unresolved splits, spot-check BAD, too few outputs) are not scored.

`abstain_excess` is recomputed against the reference outcome in place of the historical
Haiku stand-in. A failed judge call is counted as unjudged and never guessed.

Usage: python3 bench/grade_ref.py --run bench/data/runs/<label> [--reference PATH]
"""
import argparse
import json
import statistics
import sys
from pathlib import Path

import grade_l1
from common import DATA_DIR, load_config, rate
from judge import Judge, pick_judge
from reference import item_text, load_reference

SCALE = list(grade_l1.OUTCOMES[:4])  # ordered, best to worst; unclear_from_transcript is off-scale


def outcome_score(cand, ref):
    dist = abs(SCALE.index(cand) - SCALE.index(ref)) if cand in SCALE and ref in SCALE else None
    return {"match": cand == ref, "distance": dist}


def match_items(cands, clusters, judge, kind):
    """Match each candidate item to the first reference cluster of the same category it is
    judged the same as (confirmed clusters first). Returns (cluster index | None per item,
    unjudged count)."""
    order = sorted(range(len(clusters)), key=lambda i: (not clusters[i]["confirmed"], i))
    pairs = [(c["text"], clusters[i]["text"]) for c in cands for i in order
             if clusters[i]["category"] == c["category"]]
    judge.prefetch(kind, pairs)
    matches, unjudged = [], 0
    for c in cands:
        hit = None
        for i in order:
            if clusters[i]["category"] != c["category"]:
                continue
            v = judge.compare(kind, c["text"], clusters[i]["text"])["verdict"]
            if v is None:
                unjudged += 1
            elif v == "same":
                hit = i
                break
        matches.append(hit)
    return matches, unjudged


def score_list(cands, clusters, judge, kind):
    matches, unjudged = match_items(cands, clusters, judge, kind)
    confirmed = {i for i, c in enumerate(clusters) if c["confirmed"]}
    matched = {m for m in matches if m is not None}
    return {"ref_confirmed": len(confirmed), "recalled": len(matched & confirmed), "cand": len(cands),
            "strict": sum(1 for m in matches if m in confirmed),
            "lenient": sum(1 for m in matches if m is not None), "unjudged": unjudged}


def score_case(obj, ref, judge):
    """None when the reference row is excluded or has no outcome."""
    if ref["excluded"] or ref.get("outcome") is None:
        return None
    res = {"outcome": outcome_score(obj["outcome"], ref["outcome"]), "goal": None, "goal_unjudged": 0}
    if ref.get("goal"):
        # The L1 prompt sets underlying_goal to null when it would duplicate the top initiative, so a
        # null goal means "the goal is the initiative" and that text is what gets compared.
        cg = obj.get("underlying_goal") or next(
            (x for x in obj.get("notable_initiatives") or [] if isinstance(x, str) and x.strip()), None)
        if not cg:
            res["goal"] = "different"  # no goal and no initiative where the reference has one: a miss, no call needed
        else:
            v = judge.compare("goal", cg, ref["goal"])["verdict"]
            res["goal"], res["goal_unjudged"] = v, int(v is None)
    res["findings"] = score_list(
        [{"text": item_text("finding", f), "category": f["category"]} for f in obj["findings"]],
        ref["findings"], judge, "finding")
    res["instructions"] = score_list(
        [{"text": item_text("instruction", s), "category": None} for s in obj.get("instructions_given", [])],
        ref["instructions"], judge, "instruction")
    return res


def aggregate_ref(scores):
    scores = [s for s in scores if s is not None]
    outcomes = [s["outcome"] for s in scores]
    dists = [o["distance"] for o in outcomes if o["distance"] is not None]
    goals = [s["goal"] for s in scores if s["goal"] is not None]

    def total(kind, key):
        return sum(s[kind][key] for s in scores)
    return {
        "cases_scored": len(scores),
        "outcome_match": rate(sum(1 for o in outcomes if o["match"]), len(outcomes)),
        "outcome_distance": {"mean": statistics.mean(dists) if dists else None, "n": len(dists)},
        "goal_same": rate(sum(1 for g in goals if g == "same"), len(goals)),
        "goal_same_or_partial": rate(sum(1 for g in goals if g in ("same", "partial")), len(goals)),
        "finding_recall": rate(total("findings", "recalled"), total("findings", "ref_confirmed")),
        "finding_precision_strict": rate(total("findings", "strict"), total("findings", "cand")),
        "finding_precision_lenient": rate(total("findings", "lenient"), total("findings", "cand")),
        "instruction_recall": rate(total("instructions", "recalled"), total("instructions", "ref_confirmed")),
        "instruction_precision": rate(total("instructions", "strict"), total("instructions", "cand")),
        "unjudged": total("findings", "unjudged") + total("instructions", "unjudged")
                    + sum(s["goal_unjudged"] for s in scores),
    }


def grade_run_ref(run_dir, cases_path, reference, judge, cfg):
    """Phase 1 grading with the reference as the depth baseline, plus reference metrics."""
    run_dir = Path(run_dir)
    summary = grade_l1.grade_run(run_dir, cases_path, cfg, reference=reference)
    scores = []
    for line in (run_dir / "graded.jsonl").read_text(encoding="utf-8").splitlines():
        g = json.loads(line)
        ref = reference.get(g["case_id"])
        if not g["valid"] or ref is None:
            continue
        obj = json.loads((run_dir / f"findings/{g['case_id']}_rep{g['rep']}.json").read_text(encoding="utf-8"))
        scores.append(score_case(obj, ref, judge))
    summary["reference_metrics"] = aggregate_ref(scores)
    summary["reference_metrics"]["cases_excluded"] = sum(1 for r in reference.values() if r["excluded"])
    summary["judge"] = {"model": judge.model, "calls": judge.calls, "cache_hits": judge.hits,
                        "errors": judge.errors}
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--run", required=True)
    ap.add_argument("--reference", default=str(DATA_DIR / "reference" / "reference.jsonl"))
    ap.add_argument("--cases", default=str(DATA_DIR / "cases.jsonl"))
    ap.add_argument("--cache", default=str(DATA_DIR / "reference" / "judge-cache.jsonl"))
    ap.add_argument("--config", default=None)
    ap.add_argument("--claude-bin", default="claude")
    a = ap.parse_args(argv)
    cfg = load_config(a.config)
    run_dir = Path(a.run)
    meta = json.loads((run_dir / "run.json").read_text(encoding="utf-8")) if (run_dir / "run.json").exists() else {}
    jcfg = cfg["reference"]["judge"]
    judge = Judge(pick_judge(meta.get("model", ""), jcfg), jcfg["effort"], a.cache, claude_bin=a.claude_bin,
                  workers=jcfg.get("workers", 3))
    s = grade_run_ref(run_dir, a.cases, load_reference(a.reference), judge, cfg)
    m, gate = s["reference_metrics"], s["metrics"]["gate"]
    print(f"{s['label']}: {m['cases_scored']} cases scored against the reference, "
          f"gate {'PASS' if gate['pass'] else 'FAIL ' + ','.join(gate['failed'])} "
          f"(judge {judge.model}: {judge.calls} calls, {judge.hits} cached, {judge.errors} failed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

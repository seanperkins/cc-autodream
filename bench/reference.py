"""Build the frozen L1 reference by majority vote across reference models (Phase 2). Stdlib only.

Each reference model triages every frozen case once (bench/runner.py, labels from
config.json). This module turns those outputs into one reference row per case:

  outcome       majority of the models; three-way (or 1-1) splits go to the user
  goal          the first goal that another model's goal is judged 'same' as, else none
  findings      clusters of findings judged the same pattern (same category first);
                confirmed = reported by at least two models, otherwise unconfirmed
  instructions  clustered the same way

Rows are then adjudicated by the user through a markdown sheet: outcome splits, plus a
random spot-check sample marked OK or BAD (BAD rows are excluded from scoring).
"""
import json
import random
import re
from collections import Counter
from pathlib import Path

import grade_l1
from common import read_jsonl


def load_outputs(run_dirs, case_id):
    """{label: findings object} for every reference run holding a valid output for the case."""
    outs = {}
    for label, d in run_dirs.items():
        d = Path(d)
        row = next((r for r in read_jsonl(d / "results.jsonl")
                    if r["case_id"] == case_id and r["rep"] == 0), None)
        if not row or row["status"] != "ok":
            continue
        try:
            obj = json.loads((d / row["findings_path"]).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not grade_l1.check_validity(obj):
            outs[label] = obj
    return outs


def majority_outcome(outcomes):
    """(outcome | None, status) with status unanimous / majority / split / insufficient."""
    if len(outcomes) < 2:
        return None, "insufficient"
    value, n = Counter(outcomes.values()).most_common(1)[0]
    if n < 2:
        return None, "split"
    return value, ("unanimous" if n == len(outcomes) else "majority")


def item_text(kind, item):
    if kind == "finding":
        return f"[{item['category']}] {item['what']} (evidence: {item['evidence_excerpt'][:200]})"
    return str(item)


def pick_goal(goals, judge, order):
    """First goal (in label order) that another model's goal is judged the same as."""
    present = [(label, goals[label]) for label in order if goals.get(label)]
    pairs = [(present[i][1], present[j][1]) for i in range(len(present)) for j in range(i + 1, len(present))]
    if not pairs:
        return None, "none"
    judge.prefetch("goal", pairs)
    for a, b in pairs:
        if judge.compare("goal", a, b)["verdict"] == "same":
            return a, "agreed"
    return None, "none"


def cluster(items, judge, kind):
    """items: [{'label', 'text', 'category'}]. Different-model items of the same category are
    judged; 'same' links them. Returns (clusters, unjudged) where a cluster is
    {'category', 'text', 'labels', 'confirmed'} and 'labels' lists distinct models."""
    n = len(items)
    pairs = [(i, j) for i in range(n) for j in range(i + 1, n)
             if items[i]["label"] != items[j]["label"] and items[i]["category"] == items[j]["category"]]
    judge.prefetch(kind, [(items[i]["text"], items[j]["text"]) for i, j in pairs])
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    unjudged = 0
    for i, j in pairs:
        v = judge.compare(kind, items[i]["text"], items[j]["text"])["verdict"]
        if v is None:
            unjudged += 1
        elif v == "same":
            parent[find(j)] = find(i)
    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)
    out = []
    for members in groups.values():
        labels = []
        for i in members:
            if items[i]["label"] not in labels:
                labels.append(items[i]["label"])
        out.append({"category": items[members[0]]["category"], "text": items[members[0]]["text"],
                    "labels": labels, "confirmed": len(labels) >= 2})
    return out, unjudged


def build_row(case, outputs, judge, order):
    row = {"case_id": case["case_id"], "project": case.get("project"), "sources": [l for l in order if l in outputs],
           "outcome": None, "outcome_status": "insufficient", "outcome_votes": {}, "goal": None,
           "goal_status": "none", "findings": [], "instructions": [], "unjudged": 0,
           "excluded": True, "excluded_reason": "fewer than 2 usable reference outputs",
           "adjudication": None}
    if len(outputs) < 2:
        return row
    votes = {label: outputs[label]["outcome"] for label in order if label in outputs}
    outcome, status = majority_outcome(votes)
    row.update(outcome=outcome, outcome_status=status, outcome_votes=votes)
    if status == "split":
        row.update(excluded=True, excluded_reason="unresolved outcome split",
                   adjudication={"kind": "split", "ruling": None})
    else:
        row.update(excluded=False, excluded_reason=None)
    row["goal"], row["goal_status"] = pick_goal(
        {label: outputs[label].get("underlying_goal") for label in outputs}, judge, order)
    f_items = [{"label": label, "text": item_text("finding", f), "category": f["category"]}
               for label in order if label in outputs for f in outputs[label]["findings"]]
    row["findings"], u1 = cluster(f_items, judge, "finding")
    i_items = [{"label": label, "text": item_text("instruction", s), "category": None}
               for label in order if label in outputs for s in outputs[label].get("instructions_given", [])]
    row["instructions"], u2 = cluster(i_items, judge, "instruction")
    row["unjudged"] = u1 + u2
    return row


def build_all(cases, run_dirs, judge, order):
    return [build_row(c, load_outputs(run_dirs, c["case_id"]), judge, order) for c in cases]


def pick_spotchecks(rows, n, seed):
    eligible = sorted(r["case_id"] for r in rows if not r["excluded"])
    return sorted(random.Random(seed).sample(eligible, min(n, len(eligible))))


SHEET_HEAD = """# Reference adjudication

Fill in every `RULING:` line, save, then run `python3 bench/build_reference.py apply`.

- **Outcome splits**: the reference models disagree three ways. Write one of
  `fully_achieved`, `mostly_achieved`, `partially_achieved`, `not_achieved`,
  `unclear_from_transcript`. A blank ruling leaves the case out of scoring.
- **Spot checks**: a random sample of cases where the models mostly agree. Write `OK` if the
  reference outcome, goal and findings look right, or `BAD: <why>` to drop the case. The OK
  rate tells you how far the reference can be trusted.

Session paths are listed so you can open a transcript when a summary is not enough.
"""


def _model_line(label, obj):
    ni = "; ".join(x for x in (obj.get("notable_initiatives") or []) if isinstance(x, str))[:160]
    return (f"- {label}: outcome={obj['outcome']} | goal={str(obj.get('underlying_goal'))[:100]} "
            f"| findings={len(obj['findings'])} | initiatives={ni}")


def write_sheet(rows, cases, run_dirs, order, spot_ids, path):
    """Write the adjudication sheet and mark the spot-check rows. Returns the updated rows."""
    by_case = {c["case_id"]: c for c in cases}
    spot = set(spot_ids)
    out = [SHEET_HEAD, "## Outcome splits\n"]
    splits = [r for r in rows if r["outcome_status"] == "split"]
    if not splits:
        out.append("None.\n")
    for r in splits:
        c = by_case.get(r["case_id"], {})
        outs = load_outputs(run_dirs, r["case_id"])
        out.append(f"### case {r['case_id']}  [split]\nproject: {r['project']}\nsession: {c.get('session_path')}")
        out += [_model_line(label, outs[label]) for label in order if label in outs]
        out.append("RULING: \n")
    out.append("## Spot checks\n")
    for r in rows:
        if r["case_id"] not in spot:
            continue
        r["adjudication"] = {"kind": "spotcheck", "ruling": None}
        c = by_case.get(r["case_id"], {})
        out.append(f"### case {r['case_id']}  [spot check]\nproject: {r['project']}\nsession: {c.get('session_path')}")
        out.append(f"reference: outcome={r['outcome']} ({r['outcome_status']}) | goal={str(r['goal'])[:120]}")
        for f in r["findings"]:
            out.append(f"  - {'confirmed' if f['confirmed'] else 'unconfirmed'} finding: {f['text'][:200]}")
        for s in r["instructions"]:
            out.append(f"  - {'confirmed' if s['confirmed'] else 'unconfirmed'} instruction: {s['text'][:160]}")
        out.append("RULING: \n")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text("\n".join(out), encoding="utf-8")
    return rows


def parse_sheet(path):
    """{case_id: ruling text} from the filled-in sheet."""
    rulings, current = {}, None
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        m = re.match(r"### case (\w+)", line)
        if m:
            current = m.group(1)
        elif line.startswith("RULING:") and current:
            rulings[current] = line[len("RULING:"):].strip()
    return rulings


def apply_rulings(rows, rulings):
    """Apply the user's rulings in place. Returns counts for the status line."""
    stats = {"split_resolved": 0, "split_unresolved": 0, "spot_ok": 0, "spot_bad": 0, "spot_pending": 0}
    for r in rows:
        adj = r.get("adjudication")
        if not adj:
            continue
        v = rulings.get(r["case_id"], "").strip()
        if adj["kind"] == "split":
            if v in grade_l1.OUTCOMES:
                r.update(outcome=v, outcome_status="adjudicated", excluded=False, excluded_reason=None)
                adj["ruling"] = v
                stats["split_resolved"] += 1
            else:
                stats["split_unresolved"] += 1
        else:
            if v.upper() == "OK":
                adj["ruling"] = "OK"
                stats["spot_ok"] += 1
            elif v.upper().startswith("BAD"):
                adj["ruling"] = v
                r.update(excluded=True, excluded_reason="spot-check: " + v)
                stats["spot_bad"] += 1
            else:
                stats["spot_pending"] += 1
    return stats


def load_reference(path):
    return {r["case_id"]: r for r in read_jsonl(path)}


def save_reference(rows, path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with Path(path).open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import reference as ref  # noqa: E402
from common import append_jsonl  # noqa: E402
from fakes import FakeJudge  # noqa: E402

ORDER = ["ref-opus", "ref-fable", "ref-astra"]
BASE = {
    "session_path": "/s/x.jsonl", "project": "-p", "started_at": "2026-09-27", "turn_count": 5,
    "tool_call_count": 2, "tools_used": ["Bash"], "skills_invoked": [], "models_used": [],
    "notable_initiatives": ["did a thing"], "compliance_markers": {},
    "underlying_goal": "deploy app store", "outcome": "fully_achieved",
    "satisfaction_signals": {"happy": 0, "satisfied": 0, "dissatisfied": 0, "frustrated": 0},
    "instructions_given": [], "findings": [],
}


def finding(category, what, ev="quote"):
    return {"category": category, "severity": "low", "what": what, "evidence_excerpt": ev,
            "proposed_rule": "fix it"}


def out(**kw):
    o = copy.deepcopy(BASE)
    o.update(kw)
    return o


class Outcome(unittest.TestCase):
    def test_unanimous_majority_split_insufficient(self):
        m = ref.majority_outcome
        self.assertEqual(m({"a": "x", "b": "x", "c": "x"}), ("x", "unanimous"))
        self.assertEqual(m({"a": "x", "b": "y", "c": "x"}), ("x", "majority"))
        self.assertEqual(m({"a": "x", "b": "y", "c": "z"}), (None, "split"))
        self.assertEqual(m({"a": "x", "b": "y"}), (None, "split"))
        self.assertEqual(m({"a": "x", "b": "x"}), ("x", "unanimous"))
        self.assertEqual(m({"a": "x"}), (None, "insufficient"))
        self.assertEqual(m({}), (None, "insufficient"))


class Goal(unittest.TestCase):
    def test_first_agreeing_goal_wins_in_label_order(self):
        goals = {"ref-opus": "ship android app", "ref-fable": "publish ios build", "ref-astra": "ship android release"}
        self.assertEqual(ref.pick_goal(goals, FakeJudge(), ORDER), ("ship android app", "agreed"))

    def test_no_agreement_means_no_goal(self):
        goals = {"ref-opus": "alpha one", "ref-fable": "beta two", "ref-astra": "gamma three"}
        self.assertEqual(ref.pick_goal(goals, FakeJudge(), ORDER), (None, "none"))

    def test_null_goals_are_ignored_and_one_goal_is_not_enough(self):
        self.assertEqual(ref.pick_goal({"ref-opus": None, "ref-fable": "x y", "ref-astra": ""}, FakeJudge(), ORDER), (None, "none"))
        self.assertEqual(ref.pick_goal({}, FakeJudge(), ORDER), (None, "none"))

    def test_a_failed_comparison_means_no_agreement(self):
        goals = {"ref-opus": "same words", "ref-fable": "same words"}
        self.assertEqual(ref.pick_goal(goals, FakeJudge(errors=["same words"]), ORDER), (None, "none"))


class Cluster(unittest.TestCase):
    def item(self, label, text, cat="tool_loop"):
        return {"label": label, "text": text, "category": cat}

    def test_same_pattern_from_two_models_is_confirmed(self):
        cs, unj = ref.cluster([self.item("ref-opus", "retry curl loop"), self.item("ref-fable", "retry curl again")],
                              FakeJudge(), "finding")
        self.assertEqual(len(cs), 1)
        self.assertEqual((cs[0]["labels"], cs[0]["confirmed"], unj), (["ref-opus", "ref-fable"], True, 0))
        self.assertEqual(cs[0]["text"], "retry curl loop")

    def test_a_single_model_finding_is_unconfirmed(self):
        cs, _ = ref.cluster([self.item("ref-opus", "lonely pattern here")], FakeJudge(), "finding")
        self.assertEqual((cs[0]["labels"], cs[0]["confirmed"]), (["ref-opus"], False))

    def test_the_same_model_twice_does_not_confirm_itself(self):
        j = FakeJudge()
        cs, _ = ref.cluster([self.item("ref-opus", "retry curl loop"), self.item("ref-opus", "retry curl loop")], j, "finding")
        self.assertEqual(len(cs), 2)
        self.assertFalse(any(c["confirmed"] for c in cs))
        self.assertEqual(j.log, [])

    def test_different_categories_are_never_compared(self):
        j = FakeJudge()
        cs, _ = ref.cluster([self.item("ref-opus", "retry curl loop", "tool_loop"),
                             self.item("ref-fable", "retry curl loop", "memory_miss")], j, "finding")
        self.assertEqual(len(cs), 2)
        self.assertEqual(j.log, [])

    def test_agreement_is_transitive_across_three_models(self):
        items = [self.item("ref-opus", "retry curl loop"), self.item("ref-fable", "retry curl again"),
                 self.item("ref-astra", "retry curl thrice")]
        cs, _ = ref.cluster(items, FakeJudge(), "finding")
        self.assertEqual((len(cs), cs[0]["labels"]), (1, ["ref-opus", "ref-fable", "ref-astra"]))

    def test_failed_comparisons_are_counted_and_do_not_link(self):
        cs, unj = ref.cluster([self.item("ref-opus", "retry curl loop"), self.item("ref-fable", "retry curl again")],
                              FakeJudge(errors=["retry curl again"]), "finding")
        self.assertEqual((len(cs), unj), (2, 1))

    def test_instructions_cluster_without_a_category(self):
        cs, _ = ref.cluster([self.item("ref-opus", "always run tests", None), self.item("ref-fable", "always run tests first", None)],
                            FakeJudge(), "instruction")
        self.assertEqual((len(cs), cs[0]["confirmed"]), (1, True))


class Rows(unittest.TestCase):
    CASE = {"case_id": "c1", "project": "-p"}

    def test_majority_row_with_confirmed_and_unconfirmed_findings(self):
        outs = {
            "ref-opus": out(findings=[finding("tool_loop", "retry curl loop"), finding("memory_miss", "forgot fix")]),
            "ref-fable": out(findings=[finding("tool_loop", "retry curl again")], instructions_given=["always run tests"]),
            "ref-astra": out(outcome="partially_achieved"),
        }
        r = ref.build_row(self.CASE, outs, FakeJudge(), ORDER)
        self.assertEqual((r["outcome"], r["outcome_status"], r["excluded"]), ("fully_achieved", "majority", False))
        self.assertEqual(r["sources"], ORDER)
        confirmed = [f for f in r["findings"] if f["confirmed"]]
        self.assertEqual(len(confirmed), 1)
        self.assertEqual(sum(1 for f in r["findings"] if not f["confirmed"]), 1)
        self.assertEqual([s["confirmed"] for s in r["instructions"]], [False])
        self.assertEqual(r["goal"], "deploy app store")

    def test_a_three_way_split_is_excluded_until_adjudicated(self):
        outs = {"ref-opus": out(outcome="fully_achieved"), "ref-fable": out(outcome="not_achieved"),
                "ref-astra": out(outcome="partially_achieved")}
        r = ref.build_row(self.CASE, outs, FakeJudge(), ORDER)
        self.assertEqual((r["outcome"], r["outcome_status"], r["excluded"]), (None, "split", True))
        self.assertEqual(r["adjudication"], {"kind": "split", "ruling": None})

    def test_fewer_than_two_outputs_is_excluded(self):
        r = ref.build_row(self.CASE, {"ref-opus": out()}, FakeJudge(), ORDER)
        self.assertEqual((r["outcome_status"], r["excluded"]), ("insufficient", True))
        self.assertEqual(ref.build_row(self.CASE, {}, FakeJudge(), ORDER)["sources"], [])

    def test_two_outputs_that_agree_are_enough(self):
        r = ref.build_row(self.CASE, {"ref-opus": out(), "ref-astra": out()}, FakeJudge(), ORDER)
        self.assertEqual((r["outcome_status"], r["excluded"], r["sources"]), ("unanimous", False, ["ref-opus", "ref-astra"]))


class LoadOutputs(unittest.TestCase):
    def test_only_valid_ok_outputs_count(self):
        with tempfile.TemporaryDirectory() as d:
            runs = {}
            for label, status, obj in (("ref-opus", "ok", out()), ("ref-fable", "ok", {"error": "x", "findings": []}),
                                       ("ref-astra", "no_output", None)):
                rd = Path(d) / label
                (rd / "findings").mkdir(parents=True)
                if obj is not None:
                    (rd / "findings" / "c1_rep0.json").write_text(json.dumps(obj))
                append_jsonl(rd / "results.jsonl", {"case_id": "c1", "rep": 0, "status": status,
                                                    "findings_path": "findings/c1_rep0.json"})
                runs[label] = rd
            self.assertEqual(list(ref.load_outputs(runs, "c1")), ["ref-opus"])
            self.assertEqual(ref.load_outputs(runs, "missing-case"), {})
            self.assertEqual(ref.load_outputs({"gone": Path(d) / "nope"}, "c1"), {})


class Adjudication(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = {}
        outcomes = {"s1": ["fully_achieved", "not_achieved", "partially_achieved"],
                    "k1": ["fully_achieved"] * 3, "k2": ["fully_achieved"] * 3, "k3": ["not_achieved"] * 3}
        for label in ORDER:
            rd = Path(self.tmp.name) / label
            (rd / "findings").mkdir(parents=True)
            for cid, vals in outcomes.items():
                (rd / "findings" / f"{cid}_rep0.json").write_text(json.dumps(out(outcome=vals[ORDER.index(label)])))
                append_jsonl(rd / "results.jsonl", {"case_id": cid, "rep": 0, "status": "ok",
                                                    "findings_path": f"findings/{cid}_rep0.json"})
            self.runs[label] = rd
        self.cases = [{"case_id": c, "project": "-p", "session_path": f"/s/{c}.jsonl"} for c in outcomes]
        self.rows = ref.build_all(self.cases, self.runs, FakeJudge(), ORDER)
        self.sheet = Path(self.tmp.name) / "adjudicate.md"

    def tearDown(self):
        self.tmp.cleanup()

    def test_build_all_marks_the_split(self):
        self.assertEqual({r["case_id"]: r["outcome_status"] for r in self.rows},
                         {"s1": "split", "k1": "unanimous", "k2": "unanimous", "k3": "unanimous"})

    def test_spotchecks_are_deterministic_bounded_and_skip_excluded_rows(self):
        a = ref.pick_spotchecks(self.rows, 2, seed=7)
        self.assertEqual(a, ref.pick_spotchecks(self.rows, 2, seed=7))
        self.assertEqual(len(a), 2)
        self.assertNotIn("s1", a)
        self.assertEqual(ref.pick_spotchecks(self.rows, 99, seed=7), ["k1", "k2", "k3"])

    def fill(self, mapping):
        lines, cur, out_lines = self.sheet.read_text().splitlines(), None, []
        for line in lines:
            if line.startswith("### case "):
                cur = line.split()[2]
            if line.startswith("RULING:") and cur in mapping:
                line = "RULING: " + mapping[cur]
            out_lines.append(line)
        self.sheet.write_text("\n".join(out_lines))

    def test_sheet_round_trip_applies_every_kind_of_ruling(self):
        rows = ref.write_sheet(self.rows, self.cases, self.runs, ORDER, ["k1", "k2", "k3"], self.sheet)
        text = self.sheet.read_text()
        for cid in ("s1", "k1", "k2", "k3"):
            self.assertIn(f"### case {cid}", text)
        self.assertIn("ref-opus: outcome=fully_achieved", text)
        self.fill({"s1": "mostly_achieved", "k1": "OK", "k2": "BAD: goal is wrong", "k3": ""})
        stats = ref.apply_rulings(rows, ref.parse_sheet(self.sheet))
        self.assertEqual(stats, {"split_resolved": 1, "split_unresolved": 0, "spot_ok": 1, "spot_bad": 1, "spot_pending": 1})
        by = {r["case_id"]: r for r in rows}
        self.assertEqual((by["s1"]["outcome"], by["s1"]["outcome_status"], by["s1"]["excluded"]), ("mostly_achieved", "adjudicated", False))
        self.assertEqual((by["k1"]["excluded"], by["k1"]["adjudication"]["ruling"]), (False, "OK"))
        self.assertEqual((by["k2"]["excluded"], by["k2"]["excluded_reason"]), (True, "spot-check: BAD: goal is wrong"))
        self.assertEqual((by["k3"]["excluded"], by["k3"]["adjudication"]["ruling"]), (False, None))

    def test_an_unfilled_or_invalid_split_ruling_stays_excluded(self):
        rows = ref.write_sheet(self.rows, self.cases, self.runs, ORDER, [], self.sheet)
        self.assertEqual(ref.apply_rulings(rows, ref.parse_sheet(self.sheet))["split_unresolved"], 1)
        self.fill({"s1": "kinda achieved"})
        stats = ref.apply_rulings(rows, ref.parse_sheet(self.sheet))
        self.assertEqual(stats["split_unresolved"], 1)
        self.assertTrue({r["case_id"]: r for r in rows}["s1"]["excluded"])

    def test_save_and_load_round_trip(self):
        p = Path(self.tmp.name) / "ref" / "reference.jsonl"
        ref.save_reference(self.rows, p)
        self.assertEqual(ref.load_reference(p)["k1"]["outcome"], "fully_achieved")
        self.assertEqual(len(ref.load_reference(p)), 4)


if __name__ == "__main__":
    unittest.main()

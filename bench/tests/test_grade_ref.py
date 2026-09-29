import copy
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import grade_ref as gr  # noqa: E402
import reference as ref  # noqa: E402
from common import append_jsonl, load_config  # noqa: E402
from fakes import FakeJudge  # noqa: E402
from test_reference import BASE, finding, out  # noqa: E402

FAKE_JUDGE_CLI = str(Path(__file__).resolve().parent / "fake_claude_judge.sh")
ORDER = ["ref-opus", "ref-fable", "ref-astra"]


def ref_row(**kw):
    row = {"case_id": "c1", "outcome": "mostly_achieved", "outcome_status": "majority", "goal": "deploy app store",
           "findings": [], "instructions": [], "excluded": False, "excluded_reason": None}
    row.update(kw)
    return row


def cluster(text, confirmed=True, category="tool_loop"):
    return {"category": category, "text": text, "labels": ["ref-opus", "ref-fable"] if confirmed else ["ref-opus"],
            "confirmed": confirmed}


class Outcome(unittest.TestCase):
    def test_match_and_distance_on_the_ordered_scale(self):
        s = gr.outcome_score
        self.assertEqual(s("fully_achieved", "fully_achieved"), {"match": True, "distance": 0})
        self.assertEqual(s("fully_achieved", "partially_achieved"), {"match": False, "distance": 2})
        self.assertEqual(s("not_achieved", "fully_achieved"), {"match": False, "distance": 3})

    def test_unclear_is_off_the_scale(self):
        s = gr.outcome_score
        self.assertEqual(s("unclear_from_transcript", "fully_achieved"), {"match": False, "distance": None})
        self.assertEqual(s("fully_achieved", "unclear_from_transcript"), {"match": False, "distance": None})
        self.assertEqual(s("unclear_from_transcript", "unclear_from_transcript"), {"match": True, "distance": None})


class Lists(unittest.TestCase):
    def cand(self, text, cat="tool_loop"):
        return {"text": text, "category": cat}

    def test_confirmed_clusters_are_preferred_over_unconfirmed(self):
        clusters = [cluster("retry curl lonely", confirmed=False), cluster("retry curl shared", confirmed=True)]
        matches, _ = gr.match_items([self.cand("retry curl anything")], clusters, FakeJudge(), "finding")
        self.assertEqual(matches, [1])

    def test_only_same_category_clusters_are_compared(self):
        j = FakeJudge()
        matches, _ = gr.match_items([self.cand("retry curl loop", "tool_loop")],
                                    [cluster("retry curl loop", category="memory_miss")], j, "finding")
        self.assertEqual((matches, j.log), ([None], []))

    def test_recall_and_precision_counts(self):
        clusters = [cluster("alpha one", True), cluster("beta two", False)]
        s = gr.score_list([self.cand("alpha one x"), self.cand("alpha one y"), self.cand("beta two z"), self.cand("gamma three")],
                          clusters, FakeJudge(), "finding")
        self.assertEqual(s, {"ref_confirmed": 1, "recalled": 1, "cand": 4, "strict": 2, "lenient": 3, "unjudged": 0})

    def test_no_candidate_items_recall_zero_and_nothing_to_be_precise_about(self):
        s = gr.score_list([], [cluster("alpha one")], FakeJudge(), "finding")
        self.assertEqual((s["ref_confirmed"], s["recalled"], s["cand"]), (1, 0, 0))

    def test_failed_comparisons_are_counted_not_guessed(self):
        s = gr.score_list([self.cand("alpha one x")], [cluster("alpha one y")], FakeJudge(errors=["alpha one y"]), "finding")
        self.assertEqual((s["lenient"], s["unjudged"]), (0, 1))


class Case(unittest.TestCase):
    def test_excluded_reference_rows_are_not_scored(self):
        self.assertIsNone(gr.score_case(out(), ref_row(excluded=True), FakeJudge()))
        self.assertIsNone(gr.score_case(out(), ref_row(outcome=None), FakeJudge()))

    def test_goal_is_judged_skipped_or_a_miss(self):
        j = FakeJudge()
        self.assertEqual(gr.score_case(out(underlying_goal="deploy app store"), ref_row(), j)["goal"], "same")
        self.assertIsNone(gr.score_case(out(), ref_row(goal=None), j)["goal"])
        calls = j.calls
        self.assertEqual(gr.score_case(out(underlying_goal=None), ref_row(), j)["goal"], "different")
        self.assertEqual(j.calls, calls)  # a missing goal needs no judge call

    def test_a_failed_goal_judgement_is_unjudged(self):
        s = gr.score_case(out(underlying_goal="deploy app store"), ref_row(goal="deploy app x"),
                          FakeJudge(errors=["deploy app store"]))
        self.assertEqual((s["goal"], s["goal_unjudged"]), (None, 1))

    def test_oracle_scores_full_marks(self):
        f = [finding("tool_loop", "retry curl loop")]
        reference = ref.build_row({"case_id": "c1"}, {l: out(findings=f, instructions_given=["always run tests"], outcome="mostly_achieved") for l in ORDER},
                                  FakeJudge(), ORDER)
        agg = gr.aggregate_ref([gr.score_case(out(findings=f, instructions_given=["always run tests"], outcome="mostly_achieved"),
                                              reference, FakeJudge())])
        for k in ("outcome_match", "goal_same", "finding_recall", "finding_precision_strict", "instruction_recall", "instruction_precision"):
            self.assertEqual(agg[k]["rate"], 1.0, k)
        self.assertEqual(agg["outcome_distance"]["mean"], 0)

    def test_null_candidate_scores_nothing(self):
        f = [finding("tool_loop", "retry curl loop")]
        reference = ref.build_row({"case_id": "c1"}, {l: out(findings=f, outcome="mostly_achieved") for l in ORDER}, FakeJudge(), ORDER)
        null = out(outcome="unclear_from_transcript", underlying_goal=None, findings=[], instructions_given=[])
        agg = gr.aggregate_ref([gr.score_case(null, reference, FakeJudge())])
        self.assertEqual((agg["outcome_match"]["rate"], agg["goal_same"]["rate"], agg["finding_recall"]["rate"]), (0.0, 0.0, 0.0))
        self.assertIsNone(agg["finding_precision_strict"]["rate"])


class Aggregate(unittest.TestCase):
    def test_rates_distances_and_exclusions(self):
        j = FakeJudge()
        a = gr.score_case(out(outcome="mostly_achieved", underlying_goal="deploy app store"), ref_row(), j)
        b = gr.score_case(out(outcome="not_achieved", underlying_goal="other thing"), ref_row(), j)
        agg = gr.aggregate_ref([a, b, None])
        self.assertEqual(agg["cases_scored"], 2)
        self.assertEqual((agg["outcome_match"]["k"], agg["outcome_match"]["n"]), (1, 2))
        self.assertEqual(agg["outcome_distance"], {"mean": 1.0, "n": 2})
        self.assertEqual((agg["goal_same"]["k"], agg["goal_same_or_partial"]["k"], agg["goal_same"]["n"]), (1, 1, 2))

    def test_empty_input_has_no_rates(self):
        agg = gr.aggregate_ref([])
        self.assertEqual(agg["cases_scored"], 0)
        self.assertIsNone(agg["outcome_match"]["rate"])
        self.assertIsNone(agg["outcome_distance"]["mean"])


class Run(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.data, self.run = base / "data", base / "runs" / "cand@x"
        (self.data / "inputs").mkdir(parents=True)
        (self.run / "findings").mkdir(parents=True)
        self.cases = self.data / "cases.jsonl"
        cand = {"c1": out(outcome="unclear_from_transcript", underlying_goal=None),
                "c2": out(outcome="fully_achieved"), "c3": out(outcome="unclear_from_transcript"),
                "c4": out(outcome="fully_achieved")}
        for cid, obj in cand.items():
            (self.data / "inputs" / f"{cid}.jsonl").write_text('{"m":"hello"}\n')
            (self.data / "inputs" / f"{cid}.stats.json").write_text(json.dumps(
                {k: BASE[k] for k in ("turn_count", "tool_call_count", "tools_used", "skills_invoked", "models_used")}))
            append_jsonl(self.cases, {"case_id": cid, "transcript": f"inputs/{cid}.jsonl", "stats": f"inputs/{cid}.stats.json",
                                      "hist": {"outcome": "fully_achieved"}})
            (self.run / "findings" / f"{cid}_rep0.json").write_text(json.dumps(obj))
            append_jsonl(self.run / "results.jsonl", {"case_id": cid, "rep": 0, "status": "ok", "usage": {},
                                                      "findings_path": f"findings/{cid}_rep0.json"})
        (self.run / "run.json").write_text(json.dumps({"model": "claude-haiku-4-5", "effort": ""}))
        self.reference = {
            "c1": ref_row(case_id="c1", outcome="partially_achieved"),  # candidate abstains where the reference decided
            "c2": ref_row(case_id="c2", outcome="fully_achieved"),
            "c3": ref_row(case_id="c3", outcome="unclear_from_transcript"),  # reference abstains too: not decided
            "c4": ref_row(case_id="c4", excluded=True, excluded_reason="spot-check: BAD"),
        }
        self.cfg = load_config()

    def tearDown(self):
        self.tmp.cleanup()

    def test_reference_replaces_the_historical_baseline_for_depth(self):
        s = gr.grade_run_ref(self.run, self.cases, self.reference, FakeJudge(), self.cfg)
        self.assertEqual(s["abstain_source"], "reference")
        ae = s["metrics"]["abstain_excess"]
        # decided by the reference: c1 (partially) and c2 (fully); c3 is unclear, c4 excluded
        self.assertEqual((ae["k"], ae["n"]), (1, 2))
        self.assertIn("abstain_excess", s["metrics"]["gate"]["failed"])

    def test_reference_metrics_skip_excluded_rows_and_record_the_judge(self):
        s = gr.grade_run_ref(self.run, self.cases, self.reference, FakeJudge(), self.cfg)
        m = s["reference_metrics"]
        self.assertEqual(m["cases_scored"], 3)
        self.assertEqual(m["cases_excluded"], 1)
        self.assertEqual((m["outcome_match"]["k"], m["outcome_match"]["n"]), (2, 3))
        self.assertEqual(s["judge"]["model"], "fake-judge")
        self.assertEqual(json.loads((self.run / "summary.json").read_text())["abstain_source"], "reference")

    def test_cli_end_to_end_with_the_fake_judge_cli(self):
        rpath = Path(self.tmp.name) / "reference.jsonl"
        ref.save_reference(list(self.reference.values()), rpath)
        argv = ["--run", str(self.run), "--reference", str(rpath), "--cases", str(self.cases),
                "--cache", str(Path(self.tmp.name) / "cache.jsonl"), "--claude-bin", FAKE_JUDGE_CLI]
        with mock.patch.dict(os.environ, {"FAKE_JUDGE_MODE": "good", "FAKE_JUDGE_VERDICT": "same"}):
            self.assertEqual(gr.main(argv), 0)
        s = json.loads((self.run / "summary.json").read_text())
        self.assertEqual(s["judge"]["model"], "claude-fable-5-1")  # the candidate is haiku
        self.assertGreater(s["judge"]["calls"], 0)
        self.assertEqual(s["judge"]["errors"], 0)


if __name__ == "__main__":
    unittest.main()

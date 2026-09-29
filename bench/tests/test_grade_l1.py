import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import grade_l1 as g  # noqa: E402
from common import load_config  # noqa: E402

CFG = load_config()
# Pin the gate logic to fixed thresholds so tuning bench/config.json never breaks these tests.
CFG["gate"] = {"validity_min": 0.98, "authoritative_min": 1.0,
               "hallucination_max": 0.02, "abstain_excess_max": 0.10}
STATS = {"turn_count": 5, "tool_call_count": 2, "tools_used": ["Bash", "Read"],
         "skills_invoked": [], "models_used": ["claude-opus-5-5"],
         "compliance_markers": {"RETRY-BUDGET": 0, "FETCH-PIVOT": 0, "DELEGATED": 0, "DIRECT-OK": 0}}
GOOD = {
    "session_path": "/s/x.jsonl", "project": "-p", "started_at": "2026-09-27",
    "turn_count": 5, "tool_call_count": 2, "tools_used": ["Read", "Bash"],
    "skills_invoked": [], "models_used": ["claude-opus-5-5"],
    "notable_initiatives": ["Fix the flaky deploy"],
    "compliance_markers": dict(STATS["compliance_markers"]),
    "underlying_goal": "ship the deploy", "outcome": "fully_achieved",
    "satisfaction_signals": {"happy": 0, "satisfied": 0, "dissatisfied": 0, "frustrated": 0},
    "instructions_given": ["always run tests"],
    "findings": [{"category": "tool_loop", "severity": "low", "what": "retried curl",
                  "evidence_excerpt": "curl -s http://localhost:8080/health returned 503",
                  "proposed_rule": "stop after 2 retries"}],
}
HAY = g.normalize("The assistant ran curl -s http://localhost:8080/health returned 503 again and again. "
                  '{"is_error": true}')
FABRICATED = "ran `rm -rf /srv/prod_data` and then executed deploy_everything.sh on the box"


def variant(**kw):
    o = copy.deepcopy(GOOD)
    o.update(kw)
    return o


class Validity(unittest.TestCase):
    def test_good_is_valid(self):
        self.assertEqual(g.check_validity(GOOD), [])

    def test_null_outputs_are_invalid(self):
        for bad in (None, [], "done", {}, {"error": "x", "findings": []}):
            self.assertTrue(g.check_validity(bad), bad)

    def test_specific_violations(self):
        self.assertTrue(g.check_validity(variant(outcome="great")))
        self.assertTrue(g.check_validity(variant(findings="none")))
        self.assertTrue(g.check_validity(variant(instructions_given=["a", "b", "c", "d"])))
        self.assertTrue(g.check_validity(variant(satisfaction_signals={"happy": 1})))
        self.assertTrue(g.check_validity(variant(findings=[dict(GOOD["findings"][0], category="assumption_unsurfaced")])))
        self.assertTrue(g.check_validity(variant(findings=[dict(GOOD["findings"][0], severity="urgent")])))
        self.assertTrue(g.check_validity(variant(findings=[GOOD["findings"][0]] * 11)))

    def test_empty_findings_is_valid(self):
        self.assertEqual(g.check_validity(variant(findings=[])), [])


class Authoritative(unittest.TestCase):
    def test_list_order_is_ignored(self):
        self.assertEqual(g.check_authoritative(GOOD, STATS), [])

    def test_mismatches_are_named(self):
        bad = variant(turn_count=6, tools_used=["Bash"])
        self.assertEqual(sorted(g.check_authoritative(bad, STATS)), ["tools_used", "turn_count"])

    def test_keys_absent_from_stats_are_skipped(self):
        self.assertEqual(g.check_authoritative(GOOD, {"turn_count": 5}), [])


class Grounding(unittest.TestCase):
    def test_exact_and_whitespace_insensitive(self):
        self.assertTrue(g.is_grounded("curl -s   http://localhost:8080/health\nreturned 503", HAY))

    def test_fuzzy_survives_small_edits(self):
        self.assertTrue(g.is_grounded("curl -s http://localhost:8080/health returned 5O3", HAY))

    def test_fabricated_is_not_grounded(self):
        self.assertFalse(g.is_grounded("the user said this deploy will definitely never work", HAY))

    def test_empty_and_tiny_are_not_grounded(self):
        self.assertFalse(g.is_grounded("", HAY))
        self.assertFalse(g.is_grounded("zzqx", HAY))

    def test_transcript_text_flattens_json_strings(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.jsonl"
            p.write_text(json.dumps({"message": {"content": [{"text": 'said "hello"\nworld'}]}}) + "\nplain line\n")
            text = g.transcript_text(p)
            self.assertIn('said "hello" world', text)
            self.assertIn("plain line", text)


class GroundingTiers(unittest.TestCase):
    """Production L1 often paraphrases with line references instead of quoting verbatim."""

    def tier(self, excerpt):
        return g.ground_finding(excerpt, HAY)

    def test_verbatim(self):
        self.assertEqual(self.tier("curl -s http://localhost:8080/health returned 503"), "verbatim")

    def test_paraphrase_with_a_real_quoted_command_is_anchored(self):
        self.assertEqual(self.tier("Line 12: agent ran `curl -s http://localhost:8080/health` repeatedly, no pivot"), "anchored")

    def test_matching_ignores_spacing_and_punctuation(self):
        self.assertEqual(self.tier("Lines 84/88/93 returned is_error:true results with no pivot strategy"), "anchored")

    def test_contractions_are_not_quotes_but_wrapped_spans_are(self):
        self.assertEqual(g.anchors("it doesn't work and they can't tell what's wrong"), [])
        self.assertEqual(g.anchors("it said 'sandbox blocks writes to the sibling repo' twice"),
                         ["sandbox blocks writes to the sibling repo"])

    def test_line_references_and_bare_words_are_not_anchors(self):
        self.assertEqual(g.anchors("Lines 84/88/93 and 121/125, the marker. was missing"), [])

    def test_paraphrase_with_nothing_checkable_is_unverifiable_not_hallucinated(self):
        self.assertEqual(self.tier("the agent kept retrying the same thing without changing approach"), "unverifiable")

    def test_checkable_fragments_that_are_absent_are_ungrounded(self):
        self.assertEqual(self.tier(FABRICATED), "ungrounded")

    def test_half_of_the_anchors_present_is_enough(self):
        self.assertEqual(self.tier("ran `curl -s http://localhost:8080/health` then `rm -rf /srv/prod_data`"), "anchored")

    def test_anchors_are_deduplicated_and_lowercased(self):
        a = g.anchors("ran `Deploy_Prod.sh` then deploy_prod.sh again")
        self.assertEqual(len(a), 1)

    def test_transcript_text_includes_keys_and_scalars(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.jsonl"
            p.write_text(json.dumps({"is_error": True, "n": 3}) + "\n")
            text = g.transcript_text(p)
            self.assertIn("is_error", text)
            self.assertIn("true", text)


class Depth(unittest.TestCase):
    def test_flags(self):
        d = g.depth_flags(variant(outcome="unclear_from_transcript"), "fully_achieved")
        self.assertEqual(d, {"decided_ref": True, "abstained": True, "header_only": False})

    def test_no_historical_outcome_is_not_decided(self):
        self.assertFalse(g.depth_flags(GOOD, None)["decided_ref"])
        self.assertFalse(g.depth_flags(GOOD, "unclear_from_transcript")["decided_ref"])

    def test_header_only_phrases(self):
        for phrase in ("Long session (only session header read; transcript body not reviewed)",
                       "content not reviewed in detail", "only the opening hook lines were read, header"):
            self.assertTrue(g.depth_flags(variant(notable_initiatives=[phrase]), "fully_achieved")["header_only"], phrase)
        self.assertFalse(g.depth_flags(GOOD, "fully_achieved")["header_only"])


def grade(obj, hist="fully_achieved", status="ok"):
    row = {"case_id": "c1", "rep": 0, "status": status}
    return g.grade_row(row, {"hist": {"outcome": hist}}, obj, STATS, HAY, CFG)


class Rows(unittest.TestCase):
    def test_good_row(self):
        r = grade(GOOD)
        self.assertTrue(r["valid"] and r["authoritative_ok"])
        self.assertEqual((r["findings_n"], r["ungrounded_n"]), (1, 0))

    def test_hallucinated_evidence_is_counted(self):
        bad = variant(findings=[dict(GOOD["findings"][0], evidence_excerpt=FABRICATED)])
        r = grade(bad)
        self.assertEqual(r["ungrounded_n"], 1)
        self.assertEqual(r["grounding"]["ungrounded"], 1)

    def test_findings_copied_from_another_session_fail_grounding(self):
        other = g.normalize("A different session entirely: the user asked about pasta recipes.")
        row = {"case_id": "c1", "rep": 0, "status": "ok"}
        r = g.grade_row(row, {"hist": {"outcome": "fully_achieved"}}, GOOD, STATS, other, CFG)
        self.assertEqual(r["grounding"]["ungrounded"], 1)

    def test_failed_statuses_are_invalid(self):
        for status in ("no_output", "invalid_json"):
            r = grade(None, status=status)
            self.assertFalse(r["valid"])
            self.assertEqual(r["problems"], [status])

    def test_invalid_object_skips_downstream_checks(self):
        r = grade(variant(outcome="great"))
        self.assertFalse(r["valid"])
        self.assertIsNone(r["depth"])


class Gate(unittest.TestCase):
    def rows(self, n_ok, n_abstain, hist="fully_achieved"):
        out = [grade(GOOD, hist) for _ in range(n_ok)]
        out += [grade(variant(outcome="unclear_from_transcript"), hist) for _ in range(n_abstain)]
        return out

    def test_oracle_passes(self):
        m = g.aggregate(self.rows(20, 0), CFG)
        self.assertTrue(m["gate"]["pass"], m["gate"])

    def test_null_fails(self):
        m = g.aggregate([grade(None, status="no_output") for _ in range(20)], CFG)
        self.assertFalse(m["gate"]["pass"])
        self.assertIn("validity", m["gate"]["failed"])

    def test_the_2026_09_28_sonnet_failure_is_caught(self):
        # 18 of 20 sessions came back unclear_from_transcript
        m = g.aggregate(self.rows(2, 18), CFG)
        self.assertAlmostEqual(m["abstain_excess"]["rate"], 0.9)
        self.assertEqual(m["gate"]["failed"], ["abstain_excess"])

    def test_abstaining_where_reference_did_not_decide_is_not_penalised(self):
        m = g.aggregate(self.rows(0, 20, hist=None), CFG)
        self.assertIsNone(m["abstain_excess"]["rate"])
        self.assertIn("abstain_excess_unmeasured", m["gate"]["failed"])

    def test_authoritative_must_be_exact(self):
        rows = self.rows(19, 0) + [grade(variant(turn_count=99))]
        m = g.aggregate(rows, CFG)
        self.assertIn("authoritative", m["gate"]["failed"])

    def test_hallucination_ceiling(self):
        bad = variant(findings=[dict(GOOD["findings"][0], evidence_excerpt=FABRICATED)])
        m = g.aggregate([grade(bad)] + self.rows(10, 0), CFG)
        self.assertIn("hallucination", m["gate"]["failed"])

    def test_zero_findings_everywhere_does_not_divide_by_zero(self):
        rows = [grade(variant(findings=[])) for _ in range(20)]
        m = g.aggregate(rows, CFG)
        self.assertIsNone(m["hallucination"]["rate"])
        self.assertTrue(m["gate"]["pass"])


class Perf(unittest.TestCase):
    def test_summary(self):
        rows = [{"latency_s": s, "usage": {"input_tokens": 10, "output_tokens": 5}, "api_cost_usd": 0.1,
                 "served_verified": True} for s in (1, 2, 3, 4)]
        rows[0]["served_verified"] = None
        p = g.perf_summary(rows, [{"failure_class": "timeout"}, {"failure_class": "timeout"}])
        self.assertEqual(p["latency_p50_s"], 3)
        self.assertEqual(p["errors"], {"timeout": 2})
        self.assertEqual(p["unverified_served_model"], 1)
        self.assertAlmostEqual(p["api_cost_usd_total"], 0.4)

    def test_empty(self):
        p = g.perf_summary([], [])
        self.assertIsNone(p["latency_p50_s"])
        self.assertIsNone(p["api_cost_usd_per_case"])


if __name__ == "__main__":
    unittest.main()

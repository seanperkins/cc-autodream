import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runner  # noqa: E402
from common import append_jsonl, read_jsonl  # noqa: E402

FAKE = str(Path(__file__).resolve().parent / "fake_claude.sh")


class Pure(unittest.TestCase):
    def test_served_model_matches_dated_ids(self):
        cli = {"modelUsage": {"claude-haiku-4-5-20251001": {"inputTokens": 5}}}
        self.assertEqual(runner.served_model_check(cli, "claude-haiku-4-5"), ("claude-haiku-4-5-20251001", True))

    def test_served_model_mismatch_and_dominance(self):
        cli = {"modelUsage": {"claude-haiku-4-5": {"inputTokens": 3}, "claude-opus-5-5": {"inputTokens": 900}}}
        self.assertEqual(runner.served_model_check(cli, "claude-haiku-4-5"), ("claude-opus-5-5", False))

    def test_served_model_prefix_is_not_a_substring_match(self):
        cli = {"modelUsage": {"claude-opus-5-55": {"inputTokens": 1}}}
        self.assertFalse(runner.served_model_check(cli, "claude-opus-5-5")[1])

    def test_unverified_when_no_model_usage(self):
        self.assertEqual(runner.served_model_check({}, "m"), (None, None))
        self.assertEqual(runner.served_model_check(None, "m"), (None, None))

    def test_classify(self):
        c = runner.classify_failure
        self.assertEqual(c(0, "", {"stop_reason": "end_turn"}, False), None)
        self.assertEqual(c(1, "429 rate limit", None, False), "rate_limit")
        self.assertEqual(c(1, "usage limit reached", None, False), "rate_limit")
        self.assertEqual(c(1, "boom", None, False), "cli_error")
        self.assertEqual(c(0, "", {"stop_reason": "refusal"}, False), "refusal")
        self.assertEqual(c(0, "", {}, True), "timeout")

    def test_findings_status(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "f.json"
            self.assertEqual(runner.findings_status(p), "no_output")
            p.write_text("")
            self.assertEqual(runner.findings_status(p), "no_output")
            p.write_text("nope")
            self.assertEqual(runner.findings_status(p), "invalid_json")
            p.write_text("[1]")
            self.assertEqual(runner.findings_status(p), "invalid_json")
            p.write_text('{"a":1}')
            self.assertEqual(runner.findings_status(p), "ok")


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.data = Path(self.tmp.name) / "data"
        (self.data / "inputs").mkdir(parents=True)
        self.cases = self.data / "cases.jsonl"
        for cid in ("c1", "c2"):
            (self.data / "inputs" / f"{cid}.jsonl").write_text('{"type":"user"}\n')
            (self.data / "inputs" / f"{cid}.stats.json").write_text("{}")
            append_jsonl(self.cases, {"case_id": cid, "transcript": f"inputs/{cid}.jsonl",
                                      "stats": f"inputs/{cid}.stats.json"})
        self.out = Path(self.tmp.name) / "runs"

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, *extra, mode="good", env=None):
        argv = ["--model", "claude-haiku-4-5", "--cases", str(self.cases), "--out", str(self.out),
                "--claude-bin", FAKE, "--backoff-base", "0", "--label", "t", *extra]
        with mock.patch.dict(os.environ, dict({"FAKE_MODE": mode}, **(env or {}))):
            return runner.main(argv)

    def rows(self, name):
        return list(read_jsonl(self.out / "t" / name))

    def test_dry_run_and_missing_confirm_make_no_calls(self):
        self.assertEqual(self.run_main("--dry-run"), 0)
        self.assertEqual(self.run_main(), 2)
        self.assertFalse((self.out / "t" / "results.jsonl").exists())

    def test_good_run_records_model_usage_cost_and_latency(self):
        self.assertEqual(self.run_main("--confirm"), 0)
        rows = self.rows("results.jsonl")
        self.assertEqual(sorted(r["case_id"] for r in rows), ["c1", "c2"])
        r = rows[0]
        self.assertEqual((r["status"], r["served_model"], r["served_verified"]), ("ok", "claude-haiku-4-5", True))
        self.assertEqual(r["usage"]["cache_creation_input_tokens"], 100)
        self.assertEqual(r["api_cost_usd"], 0.01)
        self.assertGreater(r["latency_s"], 0)
        self.assertTrue((self.out / "t" / r["findings_path"]).is_file())

    def test_resume_skips_finished_and_does_not_duplicate(self):
        self.run_main("--confirm")
        self.run_main("--confirm")
        self.assertEqual(len(self.rows("results.jsonl")), 2)

    def test_resume_tolerates_a_truncated_last_line(self):
        self.run_main("--confirm", "--limit", "1")
        with (self.out / "t" / "results.jsonl").open("a") as f:
            f.write('{"case_id":"c2","rep":')
        self.run_main("--confirm")
        self.assertEqual(sorted(r["case_id"] for r in self.rows("results.jsonl")), ["c1", "c2"])

    def test_reps_are_separate_slots(self):
        self.run_main("--confirm", "--reps", "2")
        self.assertEqual(len(self.rows("results.jsonl")), 4)

    def test_no_output_and_bad_json_are_results_not_errors(self):
        self.run_main("--confirm", mode="nooutput")
        self.assertEqual({r["status"] for r in self.rows("results.jsonl")}, {"no_output"})
        self.assertEqual(self.rows("errors.jsonl"), [])

    def test_bad_json_status(self):
        self.run_main("--confirm", mode="badjson")
        self.assertEqual({r["status"] for r in self.rows("results.jsonl")}, {"invalid_json"})

    def test_cli_error_goes_to_errors_only(self):
        self.run_main("--confirm", mode="cli_error")
        self.assertEqual(self.rows("results.jsonl"), [])
        self.assertEqual({e["failure_class"] for e in self.rows("errors.jsonl")}, {"cli_error"})

    def test_refusal_is_classified(self):
        self.run_main("--confirm", mode="refusal")
        self.assertEqual({e["failure_class"] for e in self.rows("errors.jsonl")}, {"refusal"})

    def test_served_model_mismatch_fails_the_attempt(self):
        self.run_main("--confirm", mode="wrongmodel")
        self.assertEqual(self.rows("results.jsonl"), [])
        errs = self.rows("errors.jsonl")
        self.assertEqual({e["failure_class"] for e in errs}, {"model_mismatch"})
        self.assertEqual(errs[0]["served_model"], "claude-sonnet-5-5")

    def test_missing_model_usage_is_recorded_as_unverified(self):
        self.run_main("--confirm", mode="nomodelusage")
        rows = self.rows("results.jsonl")
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(r["served_verified"] is None for r in rows))

    def test_rate_limit_retries_with_backoff_then_succeeds(self):
        counter = Path(self.tmp.name) / "n"
        self.run_main("--confirm", "--limit", "1", mode="rate_limit_then_good",
                      env={"FAKE_COUNTER": str(counter), "FAKE_FAIL_FIRST": "2"})
        rows = self.rows("results.jsonl")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["retries"], 2)
        self.assertEqual(self.rows("errors.jsonl"), [])

    def test_rate_limit_gives_up_after_max_attempts(self):
        self.run_main("--confirm", "--limit", "1", mode="always_rate_limit")
        errs = self.rows("errors.jsonl")
        self.assertEqual([e["failure_class"] for e in errs], ["rate_limit"])
        self.assertEqual((errs[0]["attempts"], errs[0]["retries"]), (3, 2))

    def test_timeout_kills_the_whole_process_group(self):
        self.run_main("--confirm", "--limit", "1", "--timeout", "1", mode="hang")
        errs = self.rows("errors.jsonl")
        self.assertEqual([e["failure_class"] for e in errs], ["timeout"])
        self.assertEqual(self.rows("results.jsonl"), [])


if __name__ == "__main__":
    unittest.main()

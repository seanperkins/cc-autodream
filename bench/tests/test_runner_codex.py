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

FAKE = str(Path(__file__).resolve().parent / "fake_codex.sh")


class Events(unittest.TestCase):
    def write(self, lines):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        p = Path(d.name) / "events.jsonl"
        p.write_text("\n".join(lines) + "\n")
        return p

    def test_usage_comes_from_the_last_turn_completed_event(self):
        p = self.write([
            "warning: not json",
            json.dumps({"type": "turn.completed", "usage": {"input_tokens": 1, "output_tokens": 2}}),
            json.dumps({"type": "turn.completed", "usage": {
                "input_tokens": 1000, "cached_input_tokens": 400, "cache_write_input_tokens": 7,
                "output_tokens": 50}}),
        ])
        self.assertEqual(runner.load_codex_events(p)["usage"], {
            "input_tokens": 1000, "output_tokens": 50,
            "cache_read_input_tokens": 400, "cache_creation_input_tokens": 7})

    def test_no_usage_event_or_missing_file_is_none(self):
        self.assertIsNone(runner.load_codex_events(self.write(['{"type":"turn.started"}'])))
        self.assertIsNone(runner.load_codex_events("/nonexistent/events.jsonl"))

    def test_load_cli_dispatches_on_harness(self):
        p = self.write([json.dumps({"type": "turn.started"}),
                        json.dumps({"type": "turn.completed", "usage": {"input_tokens": 3}})])
        self.assertEqual(runner.load_cli(p, "codex")["usage"]["input_tokens"], 3)
        self.assertIsNone(runner.load_cli(p, "claude"))  # an event stream is not one JSON object


class CodexRuns(unittest.TestCase):
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
        argv = ["--model", "gpt-6-astra", "--effort", "high", "--harness", "codex",
                "--codex-bin", FAKE, "--cases", str(self.cases), "--out", str(self.out),
                "--backoff-base", "0", "--label", "t", *extra]
        with mock.patch.dict(os.environ, dict({"FAKE_MODE": mode}, **(env or {}))):
            return runner.main(argv)

    def rows(self, name):
        return list(read_jsonl(self.out / "t" / name))

    def test_good_run_records_usage_and_marks_the_served_model_unverified(self):
        self.assertEqual(self.run_main("--confirm"), 0)
        rows = self.rows("results.jsonl")
        self.assertEqual(sorted(r["case_id"] for r in rows), ["c1", "c2"])
        r = rows[0]
        self.assertEqual((r["status"], r["harness"], r["served_model"], r["served_verified"]),
                         ("ok", "codex", None, None))
        self.assertEqual(r["usage"], {"input_tokens": 1000, "output_tokens": 50,
                                      "cache_read_input_tokens": 400, "cache_creation_input_tokens": 0})
        self.assertIsNone(r["api_cost_usd"])

    def test_findings_are_copied_out_of_the_codex_workspace(self):
        self.run_main("--confirm", "--limit", "1")
        r = self.rows("results.jsonl")[0]
        obj = json.loads((self.out / "t" / r["findings_path"]).read_text())
        self.assertEqual(obj["outcome"], "fully_achieved")

    def test_the_prompt_keeps_the_header_on_lines_1_and_2_then_carries_the_worker_preamble(self):
        cap = Path(self.tmp.name) / "prompt.txt"
        self.run_main("--confirm", "--limit", "1", env={"FAKE_CAPTURE": str(cap)})
        lines = cap.read_text().splitlines()
        self.assertTrue(lines[0].startswith("Session transcript to analyze (literal absolute path): /"))
        self.assertTrue(lines[1].startswith("Write your findings JSON to this literal absolute path: /"))
        self.assertEqual(lines[2], "")
        # the same worker instructions production gives claude, plus the one codex-specific sentence
        self.assertTrue(lines[3].startswith("Headless triage worker."))
        self.assertIn("cut off mid-JSON", lines[3])
        self.assertIn("never an error", lines[3])
        self.assertEqual(lines[4], "")
        self.assertTrue(lines[5].startswith("# Session Triage"))
        self.assertIn("## Precomputed session stats (authoritative", cap.read_text())

    def test_claude_rows_carry_their_harness_too(self):
        # the default harness is unchanged and is recorded
        fake_claude = str(Path(__file__).resolve().parent / "fake_claude.sh")
        argv = ["--model", "claude-haiku-4-5", "--claude-bin", fake_claude, "--cases", str(self.cases),
                "--out", str(self.out), "--backoff-base", "0", "--label", "t", "--confirm", "--limit", "1"]
        with mock.patch.dict(os.environ, {"FAKE_MODE": "good"}):
            runner.main(argv)
        self.assertEqual(self.rows("results.jsonl")[0]["harness"], "claude")

    def test_no_output_is_a_result_not_an_error(self):
        self.run_main("--confirm", mode="nooutput")
        self.assertEqual({r["status"] for r in self.rows("results.jsonl")}, {"no_output"})
        self.assertEqual(self.rows("errors.jsonl"), [])

    def test_cli_error_goes_to_errors_only(self):
        self.run_main("--confirm", mode="cli_error")
        self.assertEqual(self.rows("results.jsonl"), [])
        self.assertEqual({e["failure_class"] for e in self.rows("errors.jsonl")}, {"cli_error"})

    def test_rate_limit_gives_up_after_max_attempts(self):
        self.run_main("--confirm", "--limit", "1", mode="always_rate_limit")
        errs = self.rows("errors.jsonl")
        self.assertEqual([e["failure_class"] for e in errs], ["rate_limit"])
        self.assertEqual((errs[0]["attempts"], errs[0]["retries"]), (3, 2))

    def test_timeout_kills_the_whole_process_group(self):
        self.run_main("--confirm", "--limit", "1", "--timeout", "1", mode="hang")
        self.assertEqual([e["failure_class"] for e in self.rows("errors.jsonl")], ["timeout"])


if __name__ == "__main__":
    unittest.main()

"""sample -> run -> grade -> report, end to end, against the fake claude."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import grade_l1  # noqa: E402
import import_historical  # noqa: E402
import report  # noqa: E402
import runner  # noqa: E402
import sample_cases  # noqa: E402
from common import load_config, session_hash  # noqa: E402

FAKE = str(Path(__file__).resolve().parent / "fake_claude.sh")


def make_findings_tree(root, sessions, n):
    for i in range(n):
        sp = sessions / f"s{i}.jsonl"
        sp.write_text('{"type":"user","message":{"content":"hello"}}\n')
        h = session_hash(str(sp))
        day = root / "2026-09-01"
        day.mkdir(parents=True, exist_ok=True)
        (day / f"{h}.json").write_text(json.dumps({
            "session_path": str(sp), "project": f"-p{i % 3}", "outcome": "fully_achieved",
            "underlying_goal": None, "findings": []}))
        (day / f"{h}.stats.json").write_text("{}")  # no authoritative keys: nothing to copy


class Pipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.findings, self.sessions = base / "findings", base / "sessions"
        self.sessions.mkdir()
        make_findings_tree(self.findings, self.sessions, 6)
        self.data, self.runs = base / "data", base / "runs"
        self.assertEqual(sample_cases.main(["--n", "6", "--findings-root", str(self.findings),
                                            "--out", str(self.data), "--slim-script", "/nonexistent"]), 0)
        self.cfg = load_config()

    def tearDown(self):
        self.tmp.cleanup()

    def candidate(self, label, mode):
        argv = ["--model", "claude-haiku-4-5", "--label", label, "--cases", str(self.data / "cases.jsonl"),
                "--out", str(self.runs), "--claude-bin", FAKE, "--confirm", "--backoff-base", "0"]
        with mock.patch.dict(os.environ, {"FAKE_MODE": mode}):
            self.assertEqual(runner.main(argv), 0)
        return grade_l1.grade_run(self.runs / label, self.data / "cases.jsonl", self.cfg)

    def test_a_good_candidate_passes_the_gate(self):
        s = self.candidate("good", "good")
        self.assertEqual(s["rows"], 6)
        self.assertTrue(s["metrics"]["gate"]["pass"], s["metrics"]["gate"])
        self.assertEqual(s["metrics"]["abstain_excess"]["k"], 0)
        self.assertEqual(s["metrics"]["abstain_excess"]["n"], 6)

    def test_a_header_only_abstaining_candidate_fails_on_depth(self):
        s = self.candidate("shallow", "unclear")
        self.assertEqual(s["metrics"]["gate"]["failed"], ["abstain_excess"])
        self.assertEqual(s["metrics"]["abstain_excess"]["rate"], 1.0)
        self.assertEqual(s["metrics"]["header_only"]["rate"], 1.0)

    def test_an_empty_candidate_fails_on_validity(self):
        s = self.candidate("empty", "nooutput")
        self.assertIn("validity", s["metrics"]["gate"]["failed"])

    def test_report_lists_every_graded_run(self):
        for label, mode in (("good", "good"), ("shallow", "unclear")):
            self.candidate(label, mode)
        out = Path(self.tmp.name) / "report.md"
        self.assertEqual(report.main(["--runs", str(self.runs / "good"), str(self.runs / "shallow"),
                                      "--out", str(out)]), 0)
        md = out.read_text()
        self.assertLess(md.index("good"), md.index("shallow"))
        self.assertIn("FAIL: abstain_excess", md)

    def test_historical_import_creates_a_gradable_run_without_model_calls(self):
        self.assertEqual(import_historical.main(["--cases", str(self.data / "cases.jsonl"),
                                                 "--out", str(self.runs)]), 0)
        run = self.runs / "historical"
        rows = [json.loads(l) for l in (run / "results.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 6)
        self.assertEqual({r["status"] for r in rows}, {"ok"})
        s = grade_l1.grade_run(run, self.data / "cases.jsonl", self.cfg)
        self.assertEqual(s["rows"], 6)
        self.assertEqual(s["metrics"]["abstain_excess"]["k"], 0)

    def test_historical_import_with_no_sources_reports_failure(self):
        cases = self.data / "empty.jsonl"
        cases.write_text(json.dumps({"case_id": "x", "findings_src": "/nonexistent"}) + "\n")
        self.assertEqual(import_historical.main(["--cases", str(cases), "--out", str(self.runs)]), 2)

    def test_grade_writes_graded_rows_and_summary(self):
        self.candidate("good", "good")
        rows = [json.loads(l) for l in (self.runs / "good" / "graded.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 6)
        self.assertTrue((self.runs / "good" / "summary.json").is_file())
        self.assertEqual(grade_l1.main(["--run", str(self.runs / "good"),
                                        "--cases", str(self.data / "cases.jsonl")]), 0)


if __name__ == "__main__":
    unittest.main()

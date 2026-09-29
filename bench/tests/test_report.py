import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import report  # noqa: E402
from common import rate  # noqa: E402


def summary(label, passed, failed=()):
    return {
        "label": label, "model": label.split("@")[0], "effort": label.split("@")[1], "rows": 20,
        "metrics": {
            "validity": rate(20, 20), "authoritative": rate(20, 20), "hallucination": rate(0, 15), "verbatim": rate(0, 15),
            "abstain_excess": rate(1, 18), "header_only": rate(0, 20),
            "gate": {"pass": passed, "failed": list(failed)},
        },
        "perf": {"latency_p50_s": 12.3, "latency_p95_s": 40.0, "mean_input_tokens": 10,
                 "mean_output_tokens": 500, "mean_cache_creation_tokens": 8000,
                 "api_cost_usd_per_case": 0.0421, "api_cost_usd_total": 0.84,
                 "errors": {"timeout": 1}, "unverified_served_model": 0},
    }


class Render(unittest.TestCase):
    def test_gate_passers_come_first_and_failures_are_named(self):
        md = report.render([summary("b@low", False, ["abstain_excess"]), summary("a@high", True)])
        self.assertLess(md.index("a@high"), md.index("b@low"))
        self.assertIn("FAIL: abstain_excess", md)
        self.assertIn("PASS", md)

    def test_absolute_numbers_and_rates_with_intervals(self):
        md = report.render([summary("a@high", True)])
        self.assertIn("12.3 / 40.0 s", md)
        self.assertIn("$0.042", md)
        self.assertIn("8010 in / 500 out", md)
        self.assertIn("100% (84-100, n=20)", md)
        self.assertIn("timeout:1", md)

    def test_no_blended_score_column(self):
        self.assertNotIn("score", report.render([summary("a@high", True)]).split("## Notes")[0].lower())

    def test_rows_are_identified_by_run_label_not_model(self):
        a, b = summary("m@low", True), summary("m@high", True)
        a["model"] = b["model"] = "same-model"
        md = report.render([a, b])
        self.assertIn("m@low", md)
        self.assertIn("m@high", md)

    def test_empty_rates_render_as_na(self):
        s = summary("a@high", True)
        s["metrics"]["abstain_excess"] = rate(0, 0)
        self.assertIn("n/a", report.render([s]))

    def test_main_writes_file_and_skips_ungraded_runs(self):
        with tempfile.TemporaryDirectory() as d:
            runs = Path(d) / "runs"
            (runs / "a@high").mkdir(parents=True)
            (runs / "a@high" / "summary.json").write_text(json.dumps(summary("a@high", True)))
            (runs / "ungraded").mkdir()
            out = Path(d) / "report.md"
            self.assertEqual(report.main(["--runs", str(runs / "a@high"), str(runs / "ungraded"), "--out", str(out)]), 0)
            self.assertIn("a@high", out.read_text())
            self.assertEqual(report.main(["--runs", str(runs / "ungraded"), "--out", str(out)]), 2)


if __name__ == "__main__":
    unittest.main()

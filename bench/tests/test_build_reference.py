import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_reference as br  # noqa: E402
import reference as ref  # noqa: E402
from common import append_jsonl, read_jsonl  # noqa: E402
from test_reference import out  # noqa: E402

FAKE_JUDGE_CLI = str(Path(__file__).resolve().parent / "fake_claude_judge.sh")
LABELS = ["ref-opus", "ref-fable", "ref-astra"]


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.runs, self.ref_dir, self.cases = base / "runs", base / "reference", base / "cases.jsonl"
        outcomes = {"s1": ["fully_achieved", "not_achieved", "partially_achieved"],
                    "k1": ["fully_achieved"] * 3, "k2": ["not_achieved"] * 3}
        for i, label in enumerate(LABELS):
            rd = self.runs / label
            (rd / "findings").mkdir(parents=True)
            for cid, vals in outcomes.items():
                (rd / "findings" / f"{cid}_rep0.json").write_text(json.dumps(out(outcome=vals[i])))
                append_jsonl(rd / "results.jsonl", {"case_id": cid, "rep": 0, "status": "ok",
                                                    "findings_path": f"findings/{cid}_rep0.json"})
        for cid in outcomes:
            append_jsonl(self.cases, {"case_id": cid, "project": "-p", "session_path": f"/s/{cid}.jsonl"})

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args):
        argv = [*args, "--runs", str(self.runs), "--cases", str(self.cases), "--ref-dir", str(self.ref_dir),
                "--claude-bin", FAKE_JUDGE_CLI]
        with mock.patch.dict(os.environ, {"FAKE_JUDGE_MODE": "good", "FAKE_JUDGE_VERDICT": "same"}):
            return br.main(argv)

    def rows(self):
        return {r["case_id"]: r for r in read_jsonl(self.ref_dir / "reference.jsonl")}

    def fill(self, mapping):
        sheet = self.ref_dir / "adjudicate.md"
        cur, lines = None, []
        for line in sheet.read_text().splitlines():
            if line.startswith("### case "):
                cur = line.split()[2]
            if line.startswith("RULING:") and cur in mapping:
                line = "RULING: " + mapping[cur]
            lines.append(line)
        sheet.write_text("\n".join(lines))

    def test_full_flow_build_sheet_rule_apply(self):
        self.assertEqual(self.run_cli("build"), 0)
        self.assertEqual({k: r["outcome_status"] for k, r in self.rows().items()},
                         {"s1": "split", "k1": "unanimous", "k2": "unanimous"})
        self.assertEqual(self.run_cli("sheet"), 0)
        self.fill({"s1": "mostly_achieved", "k1": "OK", "k2": "BAD: wrong"})
        self.assertEqual(self.run_cli("apply"), 0)
        rows = self.rows()
        self.assertEqual((rows["s1"]["outcome"], rows["s1"]["excluded"]), ("mostly_achieved", False))
        self.assertEqual((rows["k1"]["excluded"], rows["k2"]["excluded"]), (False, True))
        self.assertEqual(self.run_cli("status"), 0)

    def test_build_refuses_when_a_reference_run_is_missing(self):
        import shutil
        shutil.rmtree(self.runs / "ref-astra")
        self.assertEqual(self.run_cli("build"), 2)
        self.assertFalse((self.ref_dir / "reference.jsonl").exists())

    def test_build_and_sheet_refuse_to_discard_rulings_without_force(self):
        self.run_cli("build")
        self.run_cli("sheet")
        self.fill({"s1": "mostly_achieved"})
        self.assertEqual(self.run_cli("sheet"), 2)  # the sheet holds a ruling
        self.run_cli("apply")
        self.assertEqual(self.run_cli("build"), 2)  # the reference holds a ruling
        self.assertEqual(self.run_cli("build", "--force"), 0)
        self.assertEqual(self.rows()["s1"]["outcome_status"], "split")

    def test_sheet_apply_status_need_a_reference_first(self):
        self.assertEqual(self.run_cli("sheet"), 2)
        self.assertEqual(self.run_cli("apply"), 2)
        self.assertEqual(self.run_cli("status"), 2)

    def test_judge_cache_makes_a_rebuild_free(self):
        self.run_cli("build")
        cache = self.ref_dir / "judge-cache.jsonl"
        before = cache.read_text().splitlines()
        self.assertGreater(len(before), 0)
        self.run_cli("build")
        self.assertEqual(cache.read_text().splitlines(), before)


if __name__ == "__main__":
    unittest.main()

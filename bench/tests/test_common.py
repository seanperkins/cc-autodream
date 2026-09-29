import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common  # noqa: E402


class SessionHash(unittest.TestCase):
    def test_matches_run_sh_derivation(self):
        path = "/Users/x/.claude/projects/-p/abc.jsonl"
        expect = subprocess.run(
            ["bash", "-c", 'printf "%s" "$1" | shasum -a 1 | cut -c1-12', "_", path],
            capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(common.session_hash(path), expect)


class Jsonl(unittest.TestCase):
    def test_skips_garbage_and_missing_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "r.jsonl"
            self.assertEqual(list(common.read_jsonl(p)), [])
            p.write_text('{"a":1}\n\nnot json\n[1,2]\n{"b":2}\n{"c":')
            self.assertEqual(list(common.read_jsonl(p)), [{"a": 1}, {"b": 2}])

    def test_append_after_truncated_line_does_not_glue(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "r.jsonl"
            p.write_text('{"a":1}\n{"trunc":')
            common.append_jsonl(p, {"b": 2})
            self.assertEqual(list(common.read_jsonl(p)), [{"a": 1}, {"b": 2}])

    def test_append_creates_parent_dirs(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x" / "y" / "r.jsonl"
            common.append_jsonl(p, {"ok": True})
            self.assertEqual(json.loads(p.read_text()), {"ok": True})


class Wilson(unittest.TestCase):
    def test_empty_is_none(self):
        self.assertEqual(common.wilson(0, 0), (None, None))
        self.assertIsNone(common.rate(0, 0)["rate"])

    def test_half(self):
        lo, hi = common.wilson(50, 100)
        self.assertAlmostEqual(lo, 0.404, places=2)
        self.assertAlmostEqual(hi, 0.596, places=2)

    def test_zero_successes_lower_bound_is_zero(self):
        lo, hi = common.wilson(0, 10)
        self.assertAlmostEqual(lo, 0.0, places=6)
        self.assertGreater(hi, 0.2)


if __name__ == "__main__":
    unittest.main()

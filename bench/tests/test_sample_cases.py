import json
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sample_cases as sc  # noqa: E402


def make_tree(root, sessions_dir):
    """findings/<date>/<hash>.json (+ .stats.json) for a mix of eligible/ineligible sessions."""
    def add(date, name, size, findings_obj, stats=True, transcript=True):
        sp = sessions_dir / f"{name}.jsonl"
        if transcript:
            sp.write_text("x" * size)
        obj = dict(findings_obj, session_path=str(sp))
        h = sc.session_hash(str(sp))
        d = root / date
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{h}.json").write_text(json.dumps(obj))
        if stats:
            (d / f"{h}.stats.json").write_text(json.dumps({"turn_count": 3}))
        return str(sp)
    ok = {"project": "-p-a", "outcome": "fully_achieved", "findings": []}
    add("2026-09-01", "a", 100, ok)
    add("2026-09-02", "b", 100, dict(ok, project="-p-b", outcome="not_achieved", findings=[{"category": "tool_loop"}]))
    add("2026-09-02", "c", 300_000, dict(ok, project="-p-a"))
    add("2026-09-02", "err", 100, {"project": "-p-a", "error": "boom", "findings": []})
    add("2026-09-02", "gated", 100, {"project": "-p-a", "skipped": "below_noise_gate", "findings": []})
    add("2026-09-02", "nostats", 100, ok, stats=False)
    add("2026-09-02", "notranscript", 100, ok, transcript=False)
    # same session triaged on two dates: the later date must win
    sp = add("2026-09-01", "dup", 100, dict(ok, outcome="not_achieved"))
    add("2026-09-03", "dup", 100, dict(ok, outcome="fully_achieved"))
    return sp


class Sampling(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "findings"
        self.sess = Path(self.tmp.name) / "sessions"
        self.sess.mkdir()
        self.dup = make_tree(self.root, self.sess)

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_real_triages_with_transcript_and_stats(self):
        recs = sc.build_records(self.root)
        names = sorted(Path(r["session_path"]).stem for r in recs)
        self.assertEqual(names, ["a", "b", "c", "dup"])

    def test_latest_findings_file_wins_for_a_session(self):
        recs = {Path(r["session_path"]).stem: r for r in sc.build_records(self.root)}
        self.assertEqual(recs["dup"]["hist"]["outcome"], "fully_achieved")
        self.assertEqual(recs["dup"]["date"], "2026-09-03")

    def test_size_buckets(self):
        self.assertEqual(sc.size_bucket(10), "lt64k")
        self.assertEqual(sc.size_bucket(100_000), "lt256k")
        self.assertEqual(sc.size_bucket(500_000), "lt1m")
        self.assertEqual(sc.size_bucket(5_000_000), "ge1m")

    def test_select_is_deterministic_and_bounded(self):
        recs = sc.build_records(self.root)
        a = [r["case_id"] for r in sc.select(recs, 3, seed=1)]
        b = [r["case_id"] for r in sc.select(recs, 3, seed=1)]
        self.assertEqual(a, b)
        self.assertEqual(len(a), 3)
        self.assertEqual(len(sc.select(recs, 99, seed=1)), len(recs))

    def test_select_spreads_across_strata(self):
        recs = sc.build_records(self.root)
        chosen = sc.select(recs, 3, seed=5)
        self.assertEqual(len({r["stratum"] for r in chosen}), 3)

    def test_freeze_copies_small_and_slims_large(self):
        slim = Path(self.tmp.name) / "slim.sh"
        slim.write_text('#!/bin/bash\nprintf SLIMMED > "$2"\n')
        slim.chmod(slim.stat().st_mode | stat.S_IEXEC)
        recs = sc.build_records(self.root)
        out = Path(self.tmp.name) / "data"
        rows = {Path(r["session_path"]).stem: r
                for r in sc.freeze(recs, out, slim, slim_bytes=200_000)}
        self.assertFalse(rows["a"]["slimmed"])
        self.assertTrue(rows["c"]["slimmed"])
        self.assertEqual((out / rows["c"]["transcript"]).read_text(), "SLIMMED")
        self.assertEqual(len((out / rows["a"]["transcript"]).read_text()), 100)
        self.assertEqual(json.loads((out / rows["a"]["stats"]).read_text()), {"turn_count": 3})
        self.assertTrue(Path(rows["a"]["findings_src"]).is_file())
        written = [json.loads(l) for l in (out / "cases.jsonl").read_text().splitlines()]
        self.assertEqual(len(written), 4)

    def test_freeze_falls_back_to_original_when_slim_fails(self):
        slim = Path(self.tmp.name) / "slim.sh"
        slim.write_text("#!/bin/bash\nexit 1\n")
        slim.chmod(slim.stat().st_mode | stat.S_IEXEC)
        recs = [r for r in sc.build_records(self.root) if Path(r["session_path"]).stem == "c"]
        rows = sc.freeze(recs, Path(self.tmp.name) / "data", slim, slim_bytes=200_000)
        self.assertFalse(rows[0]["slimmed"])
        self.assertEqual(rows[0]["size_bytes"], 300_000)


if __name__ == "__main__":
    unittest.main()

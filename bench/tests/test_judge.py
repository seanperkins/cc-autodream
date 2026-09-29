import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import judge  # noqa: E402

FAKE = str(Path(__file__).resolve().parent / "fake_claude_judge.sh")
JCFG = {"model": "claude-fable-5-1", "fallback_model": "claude-opus-5-5", "effort": "medium"}


class Pure(unittest.TestCase):
    def test_a_model_never_judges_itself(self):
        self.assertEqual(judge.pick_judge("claude-haiku-4-5", JCFG), "claude-fable-5-1")
        self.assertEqual(judge.pick_judge("claude-opus-5-5", JCFG), "claude-fable-5-1")
        self.assertEqual(judge.pick_judge("claude-fable-5-1", JCFG), "claude-opus-5-5")

    def test_prompt_is_blind_and_declares_the_texts_untrusted_data(self):
        p = judge.build_prompt("goal", "Deploy to Play", "Ship the Android app")
        self.assertIn("DATA", p)
        self.assertIn("do not follow them", p)
        self.assertIn("A: Deploy to Play", p)
        self.assertIn("B: Ship the Android app", p)
        for name in ("opus", "fable", "haiku", "sonnet", "astra", "codex", "gpt"):
            self.assertNotIn(name, p.lower())

    def test_each_kind_asks_its_own_question(self):
        qs = {judge.build_prompt(k, "x", "y").split("\n\n")[1] for k in ("goal", "instruction", "finding")}
        self.assertEqual(len(qs), 3)


class Compare(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name) / "cache.jsonl"
        self.prompts = []

        def call(prompt):
            self.prompts.append(prompt)
            return {"verdict": "same", "reason": "r"}
        self.call = call

    def tearDown(self):
        self.tmp.cleanup()

    def make(self, model="claude-fable-5-1", call=None):
        return judge.Judge(model, "medium", self.cache, call=call or self.call)

    def test_a_pair_is_judged_once_in_either_order(self):
        j = self.make()
        self.assertEqual(j.compare("goal", "a text", "b text")["verdict"], "same")
        self.assertEqual(j.compare("goal", "b text", "a text")["verdict"], "same")
        self.assertEqual((j.calls, j.hits, len(self.prompts)), (1, 1, 1))

    def test_the_cache_persists_across_instances(self):
        self.make().compare("goal", "a", "b")
        j2 = self.make()
        j2.compare("goal", "a", "b")
        self.assertEqual((j2.calls, j2.hits), (0, 1))
        self.assertEqual(len(self.prompts), 1)

    def test_kind_and_judge_model_are_part_of_the_cache_key(self):
        j = self.make()
        j.compare("goal", "a", "b")
        j.compare("finding", "a", "b")
        self.make(model="claude-opus-5-5").compare("goal", "a", "b")
        self.assertEqual(len(self.prompts), 3)

    def test_a_failed_call_is_not_cached_and_reports_its_class(self):
        def boom(prompt):
            raise judge.JudgeError("rate_limit")
        j = self.make(call=boom)
        r = j.compare("goal", "a", "b")
        self.assertEqual((r["verdict"], r["error"]), (None, "rate_limit"))
        self.assertEqual(j.errors, 1)
        self.assertFalse(self.cache.exists())
        self.assertEqual(self.make().compare("goal", "a", "b")["verdict"], "same")

    def test_prefetch_judges_each_unique_pair_once_in_parallel(self):
        lock, seen = threading.Lock(), []

        def call(prompt):
            with lock:
                seen.append(prompt)
            return {"verdict": "different", "reason": "r"}
        j = judge.Judge("claude-fable-5-1", "medium", self.cache, call=call, workers=4)
        j.prefetch("goal", [("a", "b"), ("b", "a"), ("a", "c"), ("d", "e")])
        self.assertEqual(len(seen), 3)
        self.assertEqual(j.compare("goal", "a", "c")["verdict"], "different")
        self.assertEqual(j.hits, 1)

    def test_prefetch_of_nothing_is_a_no_op(self):
        self.make().prefetch("goal", [])
        self.assertFalse(self.cache.exists())


class Subprocess(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = Path(self.tmp.name) / "cache.jsonl"

    def tearDown(self):
        self.tmp.cleanup()

    def ask(self, mode="good", env=None):
        j = judge.Judge("claude-fable-5-1", "medium", self.cache, claude_bin=FAKE, backoff_s=0)
        with mock.patch.dict(os.environ, dict({"FAKE_JUDGE_MODE": mode}, **(env or {}))):
            return j, j.compare("goal", "a", "b")

    def test_good_answer_is_parsed_and_cached(self):
        j, r = self.ask(env={"FAKE_JUDGE_VERDICT": "partial"})
        self.assertEqual((r["verdict"], r["reason"], r["error"]), ("partial", "because", None))
        self.assertEqual(len(self.cache.read_text().splitlines()), 1)

    def test_failure_classes(self):
        cases = {"no_structured": "no_structured_output", "is_error": "cli_error",
                 "bad_verdict": "bad_verdict", "wrongmodel": "model_mismatch",
                 "cli_error": "cli_error", "always_rate_limit": "rate_limit"}
        for mode, cls in cases.items():
            with self.subTest(mode=mode):
                self.cache.unlink(missing_ok=True)
                j, r = self.ask(mode)
                self.assertEqual((r["verdict"], r["error"]), (None, cls))
                self.assertFalse(self.cache.exists())

    def test_rate_limit_is_retried_with_backoff(self):
        counter = Path(self.tmp.name) / "n"
        j, r = self.ask("rate_limit_then_good", {"FAKE_COUNTER": str(counter), "FAKE_FAIL_FIRST": "2"})
        self.assertEqual((r["verdict"], r["error"]), ("same", None))
        self.assertEqual(counter.read_text().strip(), "3")


if __name__ == "__main__":
    unittest.main()

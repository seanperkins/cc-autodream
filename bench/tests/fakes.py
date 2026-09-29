"""Test doubles shared by the Phase 2 tests."""


class FakeJudge:
    """Judges two texts 'same' when their first two words match, 'partial' when they share any
    word, else 'different'. A text in `errors` makes the comparison fail (verdict None)."""

    model, hits, errors = "fake-judge", 0, 0

    def __init__(self, errors=()):
        self.log, self.bad_texts = [], set(errors)

    @property
    def calls(self):
        return len(self.log)

    def prefetch(self, kind, pairs):
        pass

    def compare(self, kind, a, b):
        self.log.append((kind, a, b))
        if a in self.bad_texts or b in self.bad_texts:
            return {"verdict": None, "reason": "", "error": "cli_error"}
        wa, wb = a.lower().split(), b.lower().split()
        verdict = "same" if wa[:2] == wb[:2] else ("partial" if set(wa) & set(wb) else "different")
        return {"verdict": verdict, "reason": "fake", "error": None}

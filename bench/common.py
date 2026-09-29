"""Shared helpers for the autodream model benchmark. Stdlib only."""
import hashlib
import json
import math
import os
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
REPO = BENCH_DIR.parent
DATA_DIR = BENCH_DIR / "data"


def session_hash(session_path):
    """The 12-hex id run.sh derives for a session: first 12 chars of sha1(path)."""
    return hashlib.sha1(session_path.encode()).hexdigest()[:12]


def read_jsonl(path):
    """Yield dict rows from a JSONL file. Skips blank lines and any line that is not
    valid JSON (a crash can leave a truncated last line)."""
    p = Path(path)
    if not p.exists():
        return
    with p.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict):
                yield row


def append_jsonl(path, row):
    """Append one row. If the file ends in a partial line (crash mid-write), start on a
    fresh line so the new row is not glued onto the garbage."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    prefix = ""
    if p.exists() and p.stat().st_size:
        with p.open("rb") as f:
            f.seek(-1, os.SEEK_END)
            if f.read(1) != b"\n":
                prefix = "\n"
    with p.open("a", encoding="utf-8") as f:
        f.write(prefix + json.dumps(row, ensure_ascii=False) + "\n")
        f.flush()
        os.fsync(f.fileno())


def wilson(successes, n, z=1.96):
    """Wilson score interval as (lo, hi); (None, None) when n == 0."""
    if n == 0:
        return (None, None)
    p = successes / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    m = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, (c - m) / d), min(1.0, (c + m) / d))


def rate(k, n):
    """{'k','n','rate','ci'} with a Wilson interval; rate/ci are None when n == 0."""
    lo, hi = wilson(k, n)
    return {"k": k, "n": n, "rate": (k / n) if n else None, "ci": [lo, hi]}


def load_config(path=None):
    p = Path(path) if path else BENCH_DIR / "config.json"
    return json.loads(p.read_text(encoding="utf-8"))

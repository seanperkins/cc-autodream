"""Candidate runner for the L1 benchmark. Stdlib only.

Runs one candidate (model, effort) over every frozen case through the production L1
invocation (bin/l1-invoke.sh via bench/run-one-l1.sh, on your CLI subscription). One row
is written per finished (case, rep); resume is idempotent on that key. Infrastructure
failures (timeout, rate limit, refusal, CLI error, served-model mismatch) go to
errors.jsonl and never occupy a result slot.

Usage: python3 bench/runner.py --model M [--effort E] [--reps N] [--dry-run | --confirm]
"""
import argparse
import json
import os
import random
import re
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from common import BENCH_DIR, DATA_DIR, append_jsonl, load_config, read_jsonl

DRIVERS = {"claude": BENCH_DIR / "run-one-l1.sh", "codex": BENCH_DIR / "run-one-l1-codex.sh"}
RATE_LIMIT = re.compile(r"rate.?limit|usage limit|overloaded|\b429\b|\b529\b", re.I)
USAGE_KEYS = ("input_tokens", "output_tokens", "cache_creation_input_tokens",
              "cache_read_input_tokens")


def _matches(requested, served):
    return served == requested or served.startswith(requested + "-")


def served_model_check(cli, requested):
    """(dominant served model or None, ok). ok is None when the CLI gave no modelUsage
    (unverified), True when the dominant model is the requested one, else False."""
    mu = cli.get("modelUsage") if isinstance(cli, dict) else None
    if not isinstance(mu, dict) or not mu:
        return None, None

    def weight(v):
        if not isinstance(v, dict):
            return 0
        return sum(v.get(k) or 0 for k in ("inputTokens", "outputTokens",
                                          "cacheReadInputTokens", "cacheCreationInputTokens"))
    dominant = max(mu, key=lambda m: weight(mu[m]))
    info = mu[dominant] if isinstance(mu[dominant], dict) else {}
    canon = info.get("canonicalModel")
    ok = _matches(requested, dominant) or (isinstance(canon, str) and _matches(requested, canon))
    return dominant, ok


def classify_failure(rc, stderr, cli, timed_out):
    """One of timeout / refusal / rate_limit / cli_error, or None when the call succeeded."""
    if timed_out:
        return "timeout"
    if isinstance(cli, dict) and cli.get("stop_reason") == "refusal":
        return "refusal"
    is_err = isinstance(cli, dict) and cli.get("is_error")
    if rc != 0 or is_err:
        blob = (stderr or "") + " " + (json.dumps(cli)[:2000] if cli else "")
        return "rate_limit" if RATE_LIMIT.search(blob) else "cli_error"
    return None


def findings_status(path):
    p = Path(path)
    if not p.is_file() or p.stat().st_size == 0:
        return "no_output"
    try:
        obj = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return "invalid_json"
    return "ok" if isinstance(obj, dict) else "invalid_json"


def _load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def load_codex_events(path):
    """Fold `codex exec --json` events into a CLI-result-shaped dict. Codex reports token
    usage in the last turn.completed event and no served model, so the caller marks the
    served model unverified. Returns None when there is no usable usage event."""
    usage = None
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for line in lines:
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(e, dict) and e.get("type") == "turn.completed" and isinstance(e.get("usage"), dict):
            usage = e["usage"]
    if usage is None:
        return None
    return {"usage": {
        "input_tokens": usage.get("input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
        "cache_read_input_tokens": usage.get("cached_input_tokens", 0),
        "cache_creation_input_tokens": usage.get("cache_write_input_tokens", 0),
    }}


def load_cli(path, harness):
    return load_codex_events(path) if harness == "codex" else _load_json(path)


class Ctx:
    def __init__(self, a, data_dir, run_dir, cfg):
        self.model, self.effort = a.model, a.effort
        self.reps, self.timeout = a.reps, a.timeout
        self.claude_bin = a.claude_bin
        self.harness, self.codex_bin = a.harness, a.codex_bin
        self.max_attempts = cfg["run"]["max_attempts"]
        self.backoff_base = a.backoff_base
        self.data, self.run_dir = data_dir, run_dir
        self.lock = threading.Lock()

    def backoff(self, retries):
        return min(self.backoff_base * 2 ** (retries - 1), 600) * (0.5 + random.random())

    def write(self, name, row):
        with self.lock:
            append_jsonl(self.run_dir / name, row)


def run_attempt(ctx, case, rep):
    cid = case["case_id"]
    findings = ctx.run_dir / "findings" / f"{cid}_rep{rep}.json"
    cli_json = ctx.run_dir / "cli" / f"{cid}_rep{rep}.json"
    for p in (findings, cli_json):
        p.parent.mkdir(parents=True, exist_ok=True)
        p.unlink(missing_ok=True)
    cmd = ["bash", str(DRIVERS[ctx.harness]), ctx.model, ctx.effort, str(findings),
           str(ctx.data / case["transcript"]), str(ctx.data / case["stats"]), str(cli_json)]
    env = dict(os.environ, CLAUDE_BIN=ctx.claude_bin, CODEX_BIN=ctx.codex_bin)
    t0 = time.monotonic()
    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    timed_out = False
    try:
        _, err = proc.communicate(timeout=ctx.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(proc.pid, signal.SIGKILL)  # the whole group: bash, the CLI, its children
        _, err = proc.communicate()
    latency = time.monotonic() - t0
    cli = load_cli(cli_json, ctx.harness)
    failure = classify_failure(proc.returncode, err or "", cli, timed_out)
    served, ok = (None, None) if ctx.harness == "codex" else served_model_check(cli, ctx.model)
    if failure is None and ok is False:
        failure = "model_mismatch"
    return {"failure": failure, "cli": cli, "latency_s": round(latency, 2), "served": served,
            "served_ok": ok, "findings": findings, "detail": (err or "")[-300:]}


def run_job(ctx, case, rep):
    cid, attempts, retries = case["case_id"], 0, 0
    while True:
        attempts += 1
        a = run_attempt(ctx, case, rep)
        if a["failure"] is None:
            break
        if a["failure"] == "rate_limit" and attempts < ctx.max_attempts:
            retries += 1
            time.sleep(ctx.backoff(retries))
            continue
        cli = a["cli"] if isinstance(a["cli"], dict) else {}
        ctx.write("errors.jsonl", {
            "case_id": cid, "rep": rep, "failure_class": a["failure"], "attempts": attempts,
            "retries": retries, "requested_model": ctx.model, "served_model": a["served"],
            "usage": {k: (cli.get("usage") or {}).get(k, 0) for k in USAGE_KEYS} if cli else None,
            "latency_s": a["latency_s"], "detail": a["detail"]})
        return
    cli = a["cli"] if isinstance(a["cli"], dict) else {}
    ctx.write("results.jsonl", {
        "case_id": cid, "rep": rep, "requested_model": ctx.model, "effort": ctx.effort,
        "harness": ctx.harness, "served_model": a["served"], "served_verified": a["served_ok"],
        "status": findings_status(a["findings"]),
        "findings_path": str(a["findings"].relative_to(ctx.run_dir)),
        "usage": {k: (cli.get("usage") or {}).get(k, 0) for k in USAGE_KEYS},
        "api_cost_usd": cli.get("total_cost_usd"), "latency_s": a["latency_s"],
        "retries": retries})


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    cfg = load_config()
    ap.add_argument("--model", required=True)
    ap.add_argument("--effort", default="")
    ap.add_argument("--label", default=None)
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--concurrency", type=int, default=cfg["run"]["concurrency"])
    ap.add_argument("--timeout", type=int, default=cfg["run"]["timeout_s"])
    ap.add_argument("--backoff-base", type=float, default=cfg["run"]["backoff_base_s"])
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--cases", default=str(DATA_DIR / "cases.jsonl"))
    ap.add_argument("--out", default=str(DATA_DIR / "runs"))
    ap.add_argument("--claude-bin", default=os.environ.get("CLAUDE_BIN") or str(Path.home() / ".local/bin/claude"))
    ap.add_argument("--harness", choices=["claude", "codex"], default="claude")
    ap.add_argument("--codex-bin", default=os.environ.get("CODEX_BIN") or "codex")
    ap.add_argument("--dry-run", action="store_true", help="print the plan; make no calls")
    ap.add_argument("--confirm", action="store_true", help="required to make real calls")
    return ap.parse_args(argv)


def main(argv=None):
    a = parse_args(argv)
    cfg = load_config()
    cases = list(read_jsonl(a.cases))
    if a.limit:
        cases = cases[:a.limit]
    if not cases:
        print(f"no cases in {a.cases}; run bench/sample_cases.py first", file=sys.stderr)
        return 2
    label = a.label or f"{a.model}@{a.effort or 'default'}"
    run_dir = Path(a.out) / label
    ctx = Ctx(a, Path(a.cases).parent, run_dir, cfg)
    done = {(r["case_id"], r["rep"]) for r in read_jsonl(run_dir / "results.jsonl")}
    todo = [(c, rep) for c in cases for rep in range(a.reps) if (c["case_id"], rep) not in done]
    print(f"plan: {a.harness}/{a.model} effort={a.effort or 'default'} | {len(cases)} cases x {a.reps} reps"
          f" = {len(cases) * a.reps} calls, {len(todo)} to run ({len(done)} already done)"
          f" | concurrency {a.concurrency}, timeout {a.timeout}s")
    print("These calls run on your Claude subscription and count against its usage cap.")
    if a.dry_run:
        return 0
    if not a.confirm:
        print("Not running: pass --confirm to make real calls (or --dry-run).", file=sys.stderr)
        return 2
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "run.json").write_text(json.dumps({
        "model": a.model, "effort": a.effort, "label": label, "reps": a.reps,
        "started_at": datetime.now(timezone.utc).isoformat()}, indent=2), encoding="utf-8")
    with ThreadPoolExecutor(max_workers=a.concurrency) as pool:
        list(pool.map(lambda job: run_job(ctx, *job), todo))
    ok = sum(1 for _ in read_jsonl(run_dir / "results.jsonl"))
    err = sum(1 for _ in read_jsonl(run_dir / "errors.jsonl"))
    print(f"done: {ok} result rows, {err} error rows in {run_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

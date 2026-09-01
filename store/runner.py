#!/usr/bin/env python3
"""
Substrate runner: the thing that was missing.

Everything else was in place: a goal decomposes, a plan gets approved, tasks
reach the frontier. And then nothing happened, because every task had to be
launched by hand. This closes that gap.

The loop is small on purpose:

    look at the frontier
    if a task is there that AI can genuinely do, run it and wait
    otherwise sleep, and say plainly what it is waiting for

Two rules it will not break:

1. It only touches goals a person has approved. A goal sitting in `waiting`
   is invisible to it. Approval is the consent, exactly as designed.
2. It never takes a task whose exit criterion needs a human. Those are left
   for a person and named as such, rather than being guessed at by an AI.

It writes a heartbeat next to the database every few seconds so the pages can
tell the truth about whether work is running, instead of assuming it is.

Usage:  python3 runner.py            run until stopped
        python3 runner.py --once     do one task and exit
"""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

STORE = "http://localhost:8040"
HERE = Path(__file__).parent
BEAT = HERE / "runner.beat"
IDLE_SLEEP = 6

# Same test the AI worker uses: if the exit criterion names a person deciding,
# no agent should be pretending to satisfy it.
HUMAN = re.compile(
    r"approved by|chosen by|marked as chosen|decides|decision required|"
    r"sign.?off|human decision|ladan (approves|decides|picks|chooses)", re.I)


def api(path):
    with urllib.request.urlopen(STORE + path, timeout=10) as r:
        return json.loads(r.read())


def beat(note, task=None):
    BEAT.write_text(json.dumps({
        "at": datetime.now(timezone.utc).timestamp(),
        "note": note,
        "task": task,
    }))


def pick():
    """The first frontier task an AI can honestly attempt, or a reason why not."""
    tree = api("/tree")
    nodes = {n["id"]: n for n in tree["nodes"]}
    frontier = api("/frontier")
    tasks = [nodes[i] for i in frontier if nodes[i].get("parent")]
    if not tasks:
        waiting = [n for n in tree["nodes"] if not n.get("parent") and n["state"] == "waiting"]
        if waiting:
            return None, f"{len(waiting)} plan(s) waiting for you to approve"
        return None, "nothing on the frontier"
    for t in tasks:
        if t.get("runbook"):
            continue
        if HUMAN.search(t["exit_criterion"] + " " + t["intent"]):
            continue
        return t, None
    return None, f"{len(tasks)} task(s) on the frontier, all need a person"


def run_one(task, model):
    print(f"[runner] taking {task['id']}: {task['title']}", flush=True)
    beat(f"working on {task['title']}", task["id"])
    proc = subprocess.run(
        ["python3", str(HERE / "worker_ai.py"), "--task", task["id"], "--model", model],
        capture_output=True, text=True, timeout=900)
    out = (proc.stdout or "").strip().splitlines()
    print(f"[runner] {task['id']} finished: {out[-1] if out else 'no output'}", flush=True)
    if proc.returncode != 0:
        print(f"[runner] {(proc.stderr or '').strip()[:300]}", flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--once", action="store_true")
    p.add_argument("--model", default="sonnet")
    args = p.parse_args()

    print("[runner] watching the frontier; approved work gets picked up here", flush=True)
    last_note = None
    while True:
        try:
            task, why = pick()
        except (urllib.error.URLError, OSError) as e:
            beat("store not reachable")
            print(f"[runner] store not reachable: {e}", flush=True)
            time.sleep(IDLE_SLEEP)
            continue

        if task:
            run_one(task, args.model)
            last_note = None
            if args.once:
                beat("stopped after one task")
                return
            continue

        beat(why)
        if why != last_note:
            print(f"[runner] idle: {why}", flush=True)
            last_note = why
        if args.once:
            return
        time.sleep(IDLE_SLEEP)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        beat("stopped")
        sys.exit(0)

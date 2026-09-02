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
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).parent
BEAT = HERE / "runner.beat"
IDLE_SLEEP = 6

# Same test the AI worker uses: if the exit criterion names a person deciding,
# no agent should be pretending to satisfy it.
HUMAN = re.compile(
    r"approved by|chosen by|marked as chosen|decides|decision required|"
    r"sign.?off|human decision|\w+ (approves|decides|picks|chooses)", re.I)


sys.path.insert(0, str(HERE))
import substrate_store as store  # noqa: E402


def api(path):
    # Straight to the database file. No server has to be running first.
    return store.call(path)


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
        # Say what the person has to do, and name it. Reporting an unrelated
        # unapproved plan while the goal they are watching sits stuck reads
        # like the wrong answer to the question they are asking.
        yours = [n for n in tree["nodes"] if n.get("parent") and n["state"] == "waiting"]
        if yours:
            names = ", ".join(t["id"].split("/")[-1] for t in yours[:3])
            more = f" +{len(yours) - 3} more" if len(yours) > 3 else ""
            return None, (f"nothing left for an agent. {len(yours)} task"
                          f"{'' if len(yours) == 1 else 's'} need you: "
                          f"{names}{more}")
        waiting = [n for n in tree["nodes"] if not n.get("parent") and n["state"] == "waiting"]
        if waiting:
            names = ", ".join(n["id"] for n in waiting[:3])
            return None, f"no approved work. Waiting for your approval: {names}"
        return None, "nothing on the frontier"
    for t in tasks:
        if t.get("runbook"):
            continue
        if HUMAN.search(t["exit_criterion"] + " " + t["intent"]):
            continue
        return t, None
    n = len(tasks)
    names = ", ".join(t["id"].split("/")[-1] for t in tasks[:3])
    return None, (f"{n} task{'' if n == 1 else 's'} need a person, not an agent: {names}")


def run_one(task, model):
    print(f"[runner] taking {task['id']}: {task['title']}", flush=True)
    beat(f"working on {task['title']}", task["id"])
    proc = subprocess.run(
        ["python3", str(HERE / "worker_ai.py"), "--task", task["id"], "--model", model],
        capture_output=True, text=True, timeout=900)
    out = (proc.stdout or "").strip().splitlines()
    # The worker ends with its one-line summary, so echo that.
    print(f"[runner] {task['id']}: {out[-1] if out else 'no output'}", flush=True)
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
        except (sqlite3.Error, OSError) as e:
            # The database is a file now, not a service, so the only way this
            # fails is the file itself: locked by a long write, or gone.
            beat("cannot read the database")
            print(f"[runner] cannot read the database: {e}", flush=True)
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

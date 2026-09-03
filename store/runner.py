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


def runnable(skip=()):
    """Every frontier task an AI can honestly attempt, best first.

    Returns a list now rather than one task, because several agents can be
    working at the same time and each needs its own.
    """
    tree = api("/tree")
    nodes = {n["id"]: n for n in tree["nodes"]}
    frontier = api("/frontier")
    tasks = [nodes[i] for i in frontier if nodes[i].get("parent") and i not in skip]
    ok = [t for t in tasks
          if not t.get("runbook")
          and not HUMAN.search(t["exit_criterion"] + " " + t["intent"])]
    return ok, tasks, tree


def why_idle(tasks, tree, busy, lost=0):
    if busy:
        return None
    if lost:
        # Tried to take work and something else already had it. Saying "needs a
        # person" here would send the reader to look at a task that is fine.
        return (f"{lost} task{'' if lost == 1 else 's'} already taken by another "
                f"runner")
    if tasks:
        names = ", ".join(t["id"].split("/")[-1] for t in tasks[:3])
        n = len(tasks)
        verb = "needs" if n == 1 else "need"
        return f"{n} task{'' if n == 1 else 's'} {verb} a person, not an agent: {names}"
    yours = [n for n in tree["nodes"] if n.get("parent") and n["state"] == "waiting"]
    if yours:
        names = ", ".join(t["id"].split("/")[-1] for t in yours[:3])
        more = f" +{len(yours) - 3} more" if len(yours) > 3 else ""
        n = len(yours)
        return (f"nothing left for an agent. {n} task{'' if n == 1 else 's'} "
                f"need you: {names}{more}")
    waiting = [n for n in tree["nodes"] if not n.get("parent") and n["state"] == "waiting"]
    if waiting:
        return "no approved work. Waiting for your approval: " + ", ".join(
            n["id"] for n in waiting[:3])
    return "nothing on the frontier"


def start(task, model, agent):
    """Claim the task for one agent, then run a worker on it in the background."""
    if not store.call("/claim", {"node": task["id"], "actor": agent})["ok"]:
        return None                       # somebody else got there first
    print(f"[{agent}] taking {task['id']}: {task['title']}", flush=True)
    return subprocess.Popen(
        ["python3", str(HERE / "worker_ai.py"), "--task", task["id"],
         "--model", model, "--actor", agent, "--claimed"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def finish(agent, task_id, proc):
    out, err = proc.communicate()
    last = (out or "").strip().splitlines()
    print(f"[{agent}] {task_id}: {last[-1] if last else 'no output'}", flush=True)
    if proc.returncode != 0 and err:
        print(f"[{agent}] {err.strip()[:300]}", flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--once", action="store_true", help="one task, then stop")
    p.add_argument("--agents", type=int, default=2,
                   help="how many tasks to work at the same time (default 2)")
    p.add_argument("--model", default="sonnet")
    args = p.parse_args()
    n_agents = max(1, args.agents)

    print(f"[runner] watching the frontier, up to {n_agents} at a time", flush=True)
    busy = {}          # agent name -> (task id, Popen)
    last_note = None
    started_any = False

    while True:
        # Anything that finished gets reported and its agent freed.
        for agent, (tid, proc) in list(busy.items()):
            if proc.poll() is not None:
                finish(agent, tid, proc)
                busy.pop(agent)

        try:
            free = [f"agent {i + 1}" for i in range(n_agents)
                    if f"agent {i + 1}" not in busy]
            ok, all_tasks, tree = runnable(skip={t for t, _ in busy.values()})
        except (sqlite3.Error, OSError) as e:
            beat("cannot read the database")
            print(f"[runner] cannot read the database: {e}", flush=True)
            time.sleep(IDLE_SLEEP)
            continue

        # --once means one round of work, not one task: fill every free agent,
        # let them all finish, then stop. Stopping after the first start would
        # make the flag mean something different when several agents exist.
        lost = 0
        for task in ok:
            if not free:
                break
            agent = free.pop(0)
            proc = start(task, args.model, agent)
            if proc:
                busy[agent] = (task["id"], proc)
                started_any = True
            else:
                lost += 1
                free.insert(0, agent)        # that agent is still free

        if busy:
            names = ", ".join(t.split("/")[-1] for t, _ in busy.values())
            beat(f"{len(busy)} running: {names}", list(busy.values())[0][0])
            last_note = None
            time.sleep(1)
            continue

        if args.once and started_any:
            beat("stopped after one round")
            return

        note = why_idle(all_tasks, tree, busy, lost)
        beat(note)
        if note != last_note:
            print(f"[runner] idle: {note}", flush=True)
            last_note = note
        if args.once:
            return
        time.sleep(IDLE_SLEEP)


if __name__ == "__main__":
    main()

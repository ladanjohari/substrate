#!/usr/bin/env python3
"""
Substrate AI worker v1: slice ai-worker-core of v0.2.

Where worker.py executes runbooks (shell commands), this worker executes
plain-language tasks by thinking: it reads a task's intent and exit criterion
from the store, calls Claude once, saves the full result to
store/outputs/<task>.md, and reports home with evidence.

Honesty rules built in:
- It only takes a task named with --task, or, with --auto, a frontier task
  whose exit criterion the AI itself judges deliverable as text. Tasks that
  need a human decision (the exit names a person) are never taken.
- "done" is only claimed when the result is non-empty; the full output is
  saved so a human can check the exit criterion against it.

Usage:
  python3 worker_ai.py --task <node-id>     execute one specific task
  python3 worker_ai.py --auto               take the first AI-suitable frontier task
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / "outputs"
sys.path.insert(0, str(HERE))
import substrate_store as store  # noqa: E402

PROMPT = """You are a worker agent inside a goal-tracking system. Execute this task and output ONLY the deliverable, no preamble.

The goal this task belongs to: {goal_title}
Goal intent: {goal_intent}

Task: {title}
Intent: {intent}
Exit criterion (what a checker will test): {exit}

Produce the deliverable as plain text/markdown, complete enough that a stranger could check it against the exit criterion.

Never use an em dash (the long dash) anywhere in what you write. Use a comma, a colon, or two sentences instead."""

CHECK_PROMPT = """You are a checker. You did not write this deliverable and you gain nothing by passing it.

For each criterion below, decide whether the deliverable ALREADY satisfies it. Mark met only if you can quote or point to the specific part of the deliverable that shows it. If it is partly done, close, or promised rather than delivered, it is not met.

Criteria (id: text):
{criteria}

Deliverable:
---
{deliverable}
---

Output ONLY a JSON array, no prose: [{{"id": <criterion id>, "met": true|false, "evidence": "<the specific thing in the deliverable that shows it, or why it falls short>"}}]"""


def api(path, payload=None):
    # Straight to the database file. No server has to be running first.
    return store.call(path, payload)


def human_task(t):
    return bool(re.search(r"approved by|chosen by|marked as chosen|decides|decision required|sign.?off|human decision|\w+ (approves|decides|picks|chooses)",
                          (t["exit_criterion"] + " " + t["intent"]).lower()))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--task")
    p.add_argument("--auto", action="store_true")
    p.add_argument("--actor", default="worker-ai-1")
    p.add_argument("--claimed", action="store_true",
                   help="the runner already claimed this task for me")
    p.add_argument("--model", default="sonnet")
    # What the person wants changed about the last attempt. Without this there
    # was no way to iterate: a result was either accepted or abandoned.
    p.add_argument("--note", default="")
    args = p.parse_args()

    tree = api("/tree")
    nodes = {n["id"]: n for n in tree["nodes"]}
    frontier = api("/frontier")

    if args.task:
        if args.task not in nodes:
            raise SystemExit("unknown task: " + args.task)
        task = nodes[args.task]
        if human_task(task):
            raise SystemExit("refusing: this task's exit needs a human decision")
    elif args.auto:
        candidates = [nodes[i] for i in frontier
                      if nodes[i].get("parent") and not human_task(nodes[i])
                      and not nodes[i].get("runbook")]
        if not candidates:
            print("no AI-suitable task on the frontier")
            return
        task = candidates[0]
    else:
        raise SystemExit("pass --task <id> or --auto")

    if args.claimed:
        # The runner already took it on this agent's behalf.
        print(f"working {task['id']}: {task['title']}")
    else:
        print(f"claiming {task['id']}: {task['title']}")
        if not api("/claim", {"node": task["id"], "actor": args.actor})["ok"]:
            print(f"stood down: {task['id']} was taken by someone else")
            return

    prompt = PROMPT.format(
        goal_title=(nodes.get(task.get("parent")) or {}).get("title", "unknown"),
        goal_intent=(nodes.get(task.get("parent")) or {}).get("intent", ""),
        title=task["title"], intent=task["intent"],
        exit=task["exit_criterion"])
    if args.note:
        previous = OUT / (task["id"].replace("/", "__") + ".md")
        prompt += ("\n\nThis is a second attempt. Your previous version is below."
                   " The person who asked for it wants this changed:\n\n"
                   f"{args.note}\n\nPrevious version:\n---\n"
                   f"{previous.read_text()[:8000] if previous.exists() else '(none)'}\n---")

    t0 = time.time()
    proc = subprocess.run(
        ["claude", "-p", prompt, "--model", args.model],
        capture_output=True, text=True, timeout=300,
    )
    dt = time.time() - t0
    result = proc.stdout.strip()

    if proc.returncode != 0 or not result:
        api("/event", {"node": task["id"], "to": "error", "actor": args.actor,
                       "note": f"AI call failed after {dt:.0f}s: {proc.stderr.strip()[:120]}"})
        raise SystemExit("failed: " + proc.stderr[:300])

    OUT.mkdir(exist_ok=True)
    outfile = OUT / (task["id"].replace("/", "__") + ".md")
    outfile.write_text(f"# {task['title']}\n\n*Produced by {args.actor} in {dt:.0f}s. "
                       f"Check against exit criterion: {task['exit_criterion']}*\n\n{result}\n")

    # The checker is not the doer. A separate call reads the deliverable against
    # each criterion, one at a time, and can only mark one met by quoting the
    # evidence for it. Anything it cannot evidence stays unmet, and the task goes
    # to waiting for a human instead of quietly closing.
    checked = check_criteria(task["id"], result, args)
    still_open = [c for c in api(f"/criteria/{task['id']}") if c["state"] != "met"]

    if still_open:
        n = len(still_open)
        word = "criterion" if n == 1 else "criteria"
        api("/event", {"node": task["id"], "to": "waiting", "actor": args.actor,
                       "note": f"AI-executed in {dt:.0f}s; deliverable at "
                               f"store/outputs/{outfile.name}. {n} {word} could not "
                               f"be evidenced, so this needs a person"})
        # Detail first, summary last: the runner echoes the final line.
        print(f"    executed in {dt:.0f}s, deliverable at {outfile}")
        for c in still_open:
            print(f"    still open: {c['text']}")
        print(f"waiting for a person, {n} {word} could not be evidenced")
        return

    api("/event", {"node": task["id"], "to": "done", "actor": args.actor,
                   "note": f"AI-executed in {dt:.0f}s; every criterion met with evidence "
                           f"({checked} checked); deliverable at store/outputs/{outfile.name}"})
    print(f"done in {dt:.0f}s -> {outfile}")


def check_criteria(node, deliverable, args):
    """Judge each criterion against the deliverable; mark only what can be evidenced."""
    crits = [c for c in api(f"/criteria/{node}") if c["state"] != "met"]
    if not crits:
        return 0
    listing = "\n".join(f"{c['id']}: {c['text']}" for c in crits)
    proc = subprocess.run(
        ["claude", "-p", CHECK_PROMPT.format(criteria=listing, deliverable=deliverable[:12000]),
         "--model", args.model],
        capture_output=True, text=True, timeout=180)
    m = re.search(r"\[.*\]", proc.stdout, re.S)
    if proc.returncode != 0 or not m:
        print("checker did not answer; leaving every criterion unmet")
        return 0
    try:
        verdicts = json.loads(m.group(0))
    except json.JSONDecodeError:
        print("checker output was not readable; leaving every criterion unmet")
        return 0
    for v in verdicts:
        if v.get("met") and v.get("evidence"):
            api("/criterion/set", {"criterion": v["id"], "to": "met",
                                   "actor": args.actor + " (checker)",
                                   "evidence": v["evidence"][:400]})
    return len(verdicts)


if __name__ == "__main__":
    main()

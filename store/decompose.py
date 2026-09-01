#!/usr/bin/env python3
"""
Substrate decomposer v0, slice C of plan v1.

Goal in, proposed tree out. Takes one sentence, asks Claude (via the local
`claude` CLI, headless) to restate the intent and break the goal into
tracer-bullet tasks with declared exit criteria and blocking edges, then
writes the proposal into the store.

The new goal arrives in state `waiting`, waiting for a person. Nothing runs
until the plan is negotiated and approved (stage 3 of the nine). Approval is
slice F; until it exists, approval is an explicit /event POST.

AI is used exactly once per goal, here. Storing, displaying, and checking the
plan afterwards costs nothing.

Usage: python3 decompose.py "the goal, in one sentence"
"""

import json
import re
import subprocess
import sys
import urllib.request

STORE = "http://localhost:8040"

PROMPT = """You are the decomposer inside a goal-tracking system. A person typed this goal:

"{goal}"

Produce ONLY a JSON object, no other text, with this exact shape:
{{
  "goal": {{"id": "<short-kebab-slug>", "title": "<the goal, titled>",
            "intent": "<what the person means, restated in plain words>",
            "exit_criterion": "<one testable sentence that decides the goal is done>"}},
  "tasks": [
    {{"id": "<slug>", "title": "<short imperative>",
      "intent": "<what this piece is for>",
      "exit_criterion": "<one testable sentence, the headline>",
      "criteria": ["<each separately checkable condition, 1 to 3 of them>"],
      "blocked_by": ["<task ids that must finish first, [] if none>"]}}
  ]
}}

Rules: 4 to 8 tasks. Each task is a vertical slice, a complete, demoable piece,
not a layer. Edges form a DAG: parallel tasks share no edge; merge points list
several blockers. Exit criteria must be checkable by a stranger.

Criteria are the heart of this: split a task's exit into the separate conditions
that can be checked and evidenced one at a time, so partial progress is visible
instead of hidden inside one all-or-nothing sentence. Each is a single fact a
stranger could confirm or refute by looking. Plain language, no jargon, the
reader may not be technical.

Never use an em dash (the long dash) anywhere in your output. Use a comma, a
colon, or two sentences instead."""


def api(path, payload=None):
    req = urllib.request.Request(STORE + path)
    if payload is not None:
        req.data = json.dumps(payload).encode()
        req.method = "POST"
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def think(goal_sentence):
    out = subprocess.run(
        ["claude", "-p", PROMPT.format(goal=goal_sentence), "--model", "sonnet"],
        capture_output=True, text=True, timeout=300,
    )
    if out.returncode != 0:
        sys.exit("claude CLI failed: " + out.stderr[:400])
    m = re.search(r"\{.*\}", out.stdout, re.DOTALL)
    if not m:
        sys.exit("no JSON in model output:\n" + out.stdout[:400])
    return json.loads(m.group(0))


def store_proposal(plan):
    import sqlite3
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent))
    import substrate_store as s

    conn = s.db()
    g = plan["goal"]
    gid = g["id"]
    if conn.execute("SELECT 1 FROM nodes WHERE id=?", (gid,)).fetchone():
        sys.exit(f"goal id already exists: {gid}")
    conn.execute(
        "INSERT INTO nodes (id,title,intent,exit_criterion,state) VALUES (?,?,?,?, 'idle')",
        (gid, g["title"], g["intent"], g["exit_criterion"]),
    )
    conn.execute("INSERT INTO criteria (node, ord, text) VALUES (?,0,?)",
                 (gid, g["exit_criterion"]))
    for t in plan["tasks"]:
        tid = f"{gid}/{t['id']}"
        conn.execute(
            "INSERT INTO nodes (id,title,intent,exit_criterion,parent) VALUES (?,?,?,?,?)",
            (tid, t["title"], t["intent"], t["exit_criterion"], gid),
        )
        for i, text in enumerate(t.get("criteria") or [t["exit_criterion"]]):
            conn.execute("INSERT INTO criteria (node, ord, text) VALUES (?,?,?)",
                         (tid, i, text))
    for t in plan["tasks"]:
        for b in t.get("blocked_by", []):
            conn.execute(
                "INSERT INTO edges (blocker,blocked) VALUES (?,?)",
                (f"{gid}/{b}", f"{gid}/{t['id']}"),
            )
    conn.commit()
    s.append_event(conn, gid, "waiting", "decomposer",
                   f"proposed tree with {len(plan['tasks'])} tasks; awaiting negotiation")
    return gid


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit('usage: decompose.py "the goal, in one sentence" | --json plan.json')
    if sys.argv[1] == "--json":
        plan = json.load(open(sys.argv[2]))
    else:
        sentence = " ".join(sys.argv[1:])
        print("thinking (one AI call)...")
        plan = think(sentence)
    gid = store_proposal(plan)
    print(f"proposed goal stored: {gid}")
    for t in plan["tasks"]:
        blockers = ", ".join(t.get("blocked_by") or []) or "none"
        print(f"  {t['id']}: {t['title']}  [blocked by: {blockers}]")
        print(f"     exit: {t['exit_criterion']}")
    # Say what happens next. This used to print the plan and stop dead, which
    # left no way of knowing the plan was sitting there waiting for a person.
    print()
    print("This plan is WAITING FOR YOU. Nothing runs until you approve it.")
    print("Open this page to read it, reshape it, and approve:")
    print()
    print("    http://localhost:8004/prototypes/negotiate/negotiate.html")
    print()

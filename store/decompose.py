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
      "criteria": ["<each separately checkable condition, 1 to 5 of them>"],
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


RESHAPE_PROMPT = """You are the decomposer inside a goal-tracking system. A person read the plan below and asked for something to change.

The goal: {title}
What it means: {intent}
Done when: {exit_criterion}

The plan you proposed:
{plan}

What the person wants changed:
"{note}"

Produce ONLY a JSON object, no other text, with this exact shape:
{{
  "tasks": [
    {{"id": "<slug>", "title": "<short imperative>",
      "intent": "<what this piece is for>",
      "exit_criterion": "<one testable sentence, the headline>",
      "criteria": ["<each separately checkable condition, 1 to 5 of them>"],
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

Make the change they asked for. Leave the rest of the plan alone, including the
ids and the wording of the tasks the change does not touch, so the person can
see what moved and what did not.

Never use an em dash (the long dash) anywhere in your output. Use a comma, a
colon, or two sentences instead."""


def api(path, payload=None):
    req = urllib.request.Request(STORE + path)
    if payload is not None:
        req.data = json.dumps(payload).encode()
        req.method = "POST"
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def ask(prompt):
    """One call to the model. Planning and replanning fail the same way."""
    try:
        out = subprocess.run(
            ["claude", "-p", prompt, "--model", "sonnet"],
            capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        # Without this the caller gets a Python traceback, which tells a
        # person nothing about what to do next.
        sys.exit("the claude command is not installed, so there is nothing to "
                 "turn the sentence into a plan")
    if out.returncode != 0 or "Failed to authenticate" in out.stdout:
        # The CLI prints a login failure on stdout with a zero exit code, so
        # check both, and say what to do rather than showing an empty error.
        why = out.stdout.strip() if "Failed to authenticate" in out.stdout else \
            (out.stderr or out.stdout).strip()
        why = why[:400]
        sys.exit("the claude command could not run: " + (why or "no output")
                 + "\n  if it says authenticate: open a terminal, run `claude`, log in, try again")
    m = re.search(r"\{.*\}", out.stdout, re.DOTALL)
    if not m:
        sys.exit("no JSON in model output:\n" + out.stdout[:400])
    return json.loads(m.group(0))


def think(goal_sentence):
    return ask(PROMPT.format(goal=goal_sentence))


def write_tasks(conn, gid, tasks):
    """Write one set of tasks, their criteria and their edges, under a goal."""
    for t in tasks:
        tid = f"{gid}/{t['id']}"
        conn.execute(
            "INSERT INTO nodes (id,title,intent,exit_criterion,parent) VALUES (?,?,?,?,?)",
            (tid, t["title"], t["intent"], t["exit_criterion"], gid),
        )
        for i, text in enumerate(t.get("criteria") or [t["exit_criterion"]]):
            conn.execute("INSERT INTO criteria (node, ord, text) VALUES (?,?,?)",
                         (tid, i, text))
    ids = {t["id"] for t in tasks}
    for t in tasks:
        for b in t.get("blocked_by", []):
            # A blocker the model invented would point at a row that does not
            # exist, and the whole plan would fail to save because of it.
            if b in ids:
                conn.execute("INSERT INTO edges (blocker,blocked) VALUES (?,?)",
                             (f"{gid}/{b}", f"{gid}/{t['id']}"))


def reshape(goal_id, note, actor="unknown"):
    """Re-plan one goal, keeping the goal and replacing its tasks.

    The goal's own title, intent and exit criterion are left alone. Wanting a
    different thing is a different goal, and rejecting this one and typing
    that one says so plainly. This is for changing how it will be done.

    Both the terminal and the app come through here, so the note is written
    down here too. It used to be written by the app's path only, which meant
    asking from the terminal left no record of why the plan changed.
    """
    from pathlib import Path as _P
    sys.path.insert(0, str(_P(__file__).parent))
    import substrate_store as s

    conn = s.db()
    try:
        s.check_reshapable(conn, goal_id)
    except ValueError as e:
        sys.exit(str(e))
    g = conn.execute("SELECT * FROM nodes WHERE id=? AND removed=0",
                     (goal_id,)).fetchone()

    # Every task under the goal, however deep. Walking only the direct
    # children left subtasks behind, pointing at a parent row that had just
    # been deleted.
    old_ids = s.descendants(conn, goal_id)
    old = [dict(conn.execute("SELECT * FROM nodes WHERE id=?", (i,)).fetchone())
           for i in old_ids]

    # A task that has been worked on is never thrown away. Being created is
    # not work: every task has a creation event, so counting those would
    # refuse to reshape any plan a person had added a task to. What counts is
    # leaving idle, or a check that somebody has already answered.
    for t in old:
        worked = conn.execute(
            "SELECT 1 FROM events WHERE node=? AND to_state!='idle'", (t["id"],)).fetchone()
        answered = conn.execute(
            "SELECT 1 FROM criteria WHERE node=? AND state!='unmet'", (t["id"],)).fetchone()
        if worked or answered:
            sys.exit(f"{t['id']} has already been worked on; reshaping would lose that")

    lines = []
    for t in old:
        if t["parent"] != goal_id:
            continue  # the model is shown the top level, which is what it wrote
        after = [x["blocker"].split("/")[-1] for x in conn.execute(
            "SELECT blocker FROM edges WHERE blocked=?", (t["id"],))]
        lines.append(f"- {t['id'].split('/')[-1]}: {t['title']}"
                     + (f"  [after: {', '.join(after)}]" if after else ""))

    s.record_change_request(conn, goal_id, actor, note)
    conn.commit()

    # Said here, after the checks, so a refusal never comes with a line
    # claiming the model is already thinking about it.
    print("rethinking the plan (one AI call)...")
    plan = ask(RESHAPE_PROMPT.format(
        title=g["title"], intent=g["intent"], exit_criterion=g["exit_criterion"],
        plan="\n".join(lines) or "(no tasks)", note=note))
    if not plan.get("tasks"):
        sys.exit("the model came back with no tasks, so the old plan is left alone")

    # descendants() returns deepest first, so a child is always gone before
    # its parent.
    for t in old:
        conn.execute("DELETE FROM edges WHERE blocker=? OR blocked=?", (t["id"], t["id"]))
        conn.execute("DELETE FROM criteria WHERE node=?", (t["id"],))
        conn.execute("DELETE FROM nodes WHERE id=?", (t["id"],))
    write_tasks(conn, goal_id, plan["tasks"])
    conn.commit()
    s.append_event(conn, goal_id, "waiting", "decomposer",
                   f"replanned after your note; {len(plan['tasks'])} tasks")
    return plan


def store_proposal(plan):
    import sqlite3
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent))
    import substrate_store as s

    conn = s.db()
    g = plan["goal"]
    gid = g["id"]
    # Ids must be unique, and a removed goal keeps its id so the log still
    # reads. A second goal with the same name gets -2, -3, and so on.
    base, n = gid, 1
    while conn.execute("SELECT 1 FROM nodes WHERE id=?", (gid,)).fetchone():
        n += 1
        gid = f"{base}-{n}"
    g["id"] = gid
    conn.execute(
        "INSERT INTO nodes (id,title,intent,exit_criterion,state) VALUES (?,?,?,?, 'idle')",
        (gid, g["title"], g["intent"], g["exit_criterion"]),
    )
    conn.execute("INSERT INTO criteria (node, ord, text) VALUES (?,0,?)",
                 (gid, g["exit_criterion"]))
    write_tasks(conn, gid, plan["tasks"])
    conn.commit()
    s.append_event(conn, gid, "waiting", "decomposer",
                   f"proposed tree with {len(plan['tasks'])} tasks; awaiting negotiation")
    return gid


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit('usage: decompose.py "the goal, in one sentence"'
                 ' | --json plan.json | --reshape <goal> "what should change"')
    if sys.argv[1] == "--reshape":
        argv = sys.argv[2:]
        actor = "unknown"
        if "--actor" in argv:
            i = argv.index("--actor")
            actor = argv[i + 1] if i + 1 < len(argv) else "unknown"
            argv = argv[:i] + argv[i + 2:]
        if len(argv) < 2:
            sys.exit('usage: decompose.py --reshape <goal> "what should change"')
        gid = argv[0]
        out = reshape(gid, " ".join(argv[1:]), actor)
        print(f"replanned goal: {gid}")
        for t in out["tasks"]:
            blockers = ", ".join(t.get("blocked_by") or []) or "none"
            print(f"  {t['id']}: {t['title']}  [blocked by: {blockers}]")
        print()
        print("This plan is WAITING FOR YOU. Nothing runs until you approve it.")
        sys.exit(0)
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
    print()
    print("Read it:")
    print(f"    substrate tree {gid}")
    print("    substrate show <task>              one task, its checks and evidence")
    print()
    print("Then answer it, one of three ways:")
    print(f"    substrate approve {gid}")
    print(f'    substrate changes {gid} "two tasks, not five"')
    print(f"    substrate reject {gid} -w \"why\"")
    print()
    print("Or change it yourself first:")
    print("    substrate edit <task> -t \"a better title\"")
    print("    substrate add <goal>/<slug> \"A task\" -c \"what closes it\"")
    print("    substrate block <task> --after <other>")
    print("    substrate remove <task>")
    print()

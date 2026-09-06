#!/usr/bin/env python3
"""
Substrate worker v0: slice E of plan v1.

The work loop from the brief: pick a frontier task, claim it, execute, report
state changes with evidence back to the store. The tree viewer shows the dot
turn white (working) and then green (done) or red (error). The worker never
talks to the display, only to the store.

v0 executes tasks that carry a `runbook` (a shell command). Tasks without a
runbook are left for agents that can think (slice C's decomposer will write
runbooks; AI-executed tasks arrive with the real agent integration).

Usage: python3 worker.py [--store http://localhost:8040] [--actor worker-1]
"""

import argparse
import json
import subprocess
import urllib.request

def api(store, path, payload=None):
    req = urllib.request.Request(store + path)
    if payload is not None:
        req.data = json.dumps(payload).encode()
        req.method = "POST"
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--store", default="http://localhost:8040")
    p.add_argument("--actor", default="worker-1")
    args = p.parse_args()

    frontier = api(args.store, "/frontier")
    tree = api(args.store, "/tree")
    nodes = {n["id"]: n for n in tree["nodes"]}
    runnable = [nid for nid in frontier if nodes[nid].get("runbook")]

    if not runnable:
        print("frontier:", frontier, "- none carry a runbook; nothing this worker can execute")
        return

    task = nodes[runnable[0]]
    print(f"claiming {task['id']}: {task['title']}")
    api(args.store, "/event", {"node": task["id"], "to": "working",
        "actor": args.actor, "note": "claimed from the frontier"})

    proc = subprocess.run(task["runbook"], shell=True, capture_output=True,
                          text=True, timeout=600)
    tail = (proc.stdout + proc.stderr).strip().splitlines()[-1:] or [""]

    if proc.returncode == 0:
        # For a runbook task the command IS the check, so a clean exit is the
        # evidence. Every criterion is met against that same run, then the node
        # closes - it cannot close any other way.
        for c in api(args.store, f"/criteria/{task['id']}"):
            if c["state"] != "met":
                api(args.store, "/criterion/set", {
                    "criterion": c["id"], "to": "met", "actor": args.actor,
                    "evidence": f"runbook exited 0: {task['runbook'][:80]} -> {tail[0][:120]}"})
        api(args.store, "/event", {"node": task["id"], "to": "done",
            "actor": args.actor,
            "note": f"exit met, runbook succeeded: {tail[0][:140]}"})
        print("done:", tail[0][:140])
    else:
        api(args.store, "/event", {"node": task["id"], "to": "error",
            "actor": args.actor,
            "note": f"runbook failed ({proc.returncode}): {tail[0][:140]}"})
        print("error:", tail[0][:140])

if __name__ == "__main__":
    main()

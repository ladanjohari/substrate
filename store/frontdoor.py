#!/usr/bin/env python3
"""
The front door: one word, and it always tells you what to do next.

This is a trial of a different shape for the product, sitting beside the old
one rather than replacing it. Nothing it does is new capability. What is new is
that there is one thing to learn instead of four, and that every screen ends
with a single next action rather than leaving you to work out where to go.

What it removes, deliberately:
  no ports, no addresses, no double-clicking a file, no remembering a command,
  no switching between a Terminal and a browser to finish one thought.

It talks straight to the database file, so nothing has to be running first. If
a step genuinely needs the background service (executing a task), it starts it
quietly and says nothing about it.

  substrate                  where things stand, and the one next action
  substrate new "a goal"     describe a goal in a sentence
  substrate tree             open the visual view in a browser
"""

import getpass
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import substrate_store as store

ACTOR = os.environ.get("SUBSTRATE_ACTOR") or getpass.getuser()  # noqa: E402

STORE_URL = "http://localhost:8040"
PAGES_URL = "http://localhost:8004"
OUTPUTS = HERE / "outputs"

# One narrow column, calm, no boxes. The terminal is the working surface, so it
# should read like a note rather than a dashboard.
DIM = "\033[2m"
BOLD = "\033[1m"
GREEN = "\033[32m"
AMBER = "\033[33m"
OFF = "\033[0m"


def plain(s):
    return s if sys.stdout.isatty() else ""


def c(code, text):
    return f"{plain(code)}{text}{plain(OFF)}"


def say(text=""):
    print("  " + text if text else "")


def prompt_text(label):
    """A free-text answer. Never let a stray end-of-input take the tool down."""
    try:
        return input("  " + label).strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return ""


def ask(prompt, options):
    """options: list of (key, label). Empty key means just pressing enter."""
    bits = "   ".join(
        f"[{k or 'enter'}] {label}" for k, label in options)
    say()
    say(c(DIM, bits))
    try:
        return input("  > ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return "q"


# ---------------------------------------------------------------- the state

import re  # noqa: E402

# A judgement only a person can make.
NEEDS_A_DECISION = re.compile(
    r"approved by|chosen by|marked as chosen|decides|decision required|"
    r"sign.?off|human decision|\w+ (approves|decides|picks|chooses)", re.I)

# An action that happens in the world, not in text. No amount of writing
# satisfies "a recording exists on disk" or "an Apple account is active", and
# offering to do these is how a tool loses someone's trust in the first minute.
NEEDS_A_BODY = re.compile(
    r"\b(record(ing|ed)?|screen.?captur|screenshot|film|photograph|"
    r"upload(ed|s)?|download|enrol|enroll|sign ?up|register(ed)?|"
    r"pay(ment|s)?|purchase|subscribe|"
    r"install(ed|s)?|deploy(ed|s)?|push(ed)?|merge[ds]?|"
    r"export(ed|s)?|archive[ds]?|submit(ted)? for (apple |app ?store )?review|"
    r"phone|call|meet|interview|email(ed)? (them|him|her|someone)|"
    r"certificate|provisioning|bundle id|app store connect|xcode)\b", re.I)


def human_only(node):
    text = node["exit_criterion"] + " " + node["intent"] + " " + node["title"]
    return bool(NEEDS_A_DECISION.search(text) or NEEDS_A_BODY.search(text))


def snapshot(conn):
    t = store.tree(conn)
    nodes = {n["id"]: n for n in t["nodes"]}
    goals = [n for n in t["nodes"] if not n["parent"]]
    front = store.frontier(conn)
    return t, nodes, goals, front


def path_of(node_id):
    return OUTPUTS / (node_id.replace("/", "__") + ".md")


def output_of(node_id):
    f = path_of(node_id)
    return f.read_text() if f.exists() else None


def next_action(conn, skipped=()):
    """The single most useful thing to do right now.

    Order matters and is the whole design: a person's attention is the scarcest
    thing here, so anything already waiting on them comes before anything an
    agent could be doing. Anything skipped this session drops out, so saying
    "not that one" always moves you forward rather than asking again.
    """
    t, nodes, goals, front = snapshot(conn)

    # 1. A plan is proposed and cannot move until a person says yes.
    for g in goals:
        if g["state"] == "waiting" and g["id"] not in skipped:
            return ("approve", g)

    # 2. Work an agent finished but could not fully evidence.
    for n in t["nodes"]:
        if (n["parent"] and n["state"] == "waiting"
                and n["id"] not in skipped and output_of(n["id"])):
            return ("check", n)

    # 3. Something an agent can genuinely do.
    for nid in front:
        n = nodes[nid]
        if (n["parent"] and nid not in skipped
                and not n.get("runbook") and not human_only(n)):
            return ("run", n)

    # 4. Everything left on the frontier is a person's own work.
    mine = [nodes[i] for i in front if nodes[i]["parent"]]
    if mine:
        return ("yours", mine)

    if not goals:
        return ("first-goal", None)
    if all(g["state"] == "done" for g in goals):
        return ("all-done", None)
    return ("nothing", None)


# ---------------------------------------------------------------- the views

def show_standing(conn):
    t, nodes, goals, front = snapshot(conn)
    live = [g for g in goals if g["state"] != "done"]
    if not live:
        return
    say()
    for g in live:
        tasks = [n for n in t["nodes"] if n["parent"] == g["id"]]
        done = sum(1 for x in tasks if x["state"] == "done")
        ready = sum(1 for x in tasks if x["id"] in front)
        title = g["title"] if len(g["title"]) <= 52 else g["title"][:51] + "…"
        state = c(AMBER, "needs you") if g["state"] == "waiting" else c(
            DIM, f"{done} of {len(tasks)} done, {ready} ready")
        say(f"{title:<54}{state}")


def show_plan(conn, goal):
    t = store.tree(conn)
    tasks = [n for n in t["nodes"] if n["parent"] == goal["id"]]
    ids = {x["id"] for x in tasks}
    blocked_by = {}
    for e in t["edges"]:
        if e["blocked"] in ids and e["blocker"] in ids:
            blocked_by.setdefault(e["blocked"], []).append(e["blocker"])
    say()
    say(c(BOLD, goal["title"]))
    say(c(DIM, goal["intent"]))
    say()
    for i, x in enumerate(tasks, 1):
        after = blocked_by.get(x["id"], [])
        say(f"{i}. {x['title']}")
        say(c(DIM, f"   done when: {x['exit_criterion']}"))
        if after:
            names = ", ".join(nx["title"] for nx in tasks if nx["id"] in after)
            say(c(DIM, f"   after: {names}"))
    return tasks


# ---------------------------------------------------------------- the doing

def store_running():
    try:
        urllib.request.urlopen(STORE_URL + "/tree", timeout=2)
        return True
    except (urllib.error.URLError, OSError):
        return False


def ensure_store():
    """Executing a task needs the background service. Start it and say nothing."""
    if store_running():
        return True
    subprocess.Popen(
        ["python3", str(HERE / "substrate_store.py"), "serve", "8040"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    for _ in range(20):
        time.sleep(0.4)
        if store_running():
            return True
    return False


def do_approve(conn, goal):
    """Returns (keep going, skip this one)."""
    tasks = show_plan(conn, goal)
    while True:
        a = ask("", [("", "approve the whole plan"),
                     ("r", "remove a task"),
                     ("s", "leave it for now"),
                     ("q", "quit")])
        if a == "q":
            return (False, False)
        if a == "s":
            return (True, True)
        if a == "r":
            which = prompt_text("which number? ")
            if which.isdigit() and 1 <= int(which) <= len(tasks):
                gone = tasks[int(which) - 1]
                store.remove_node(conn, gone["id"], ACTOR)
                say(c(DIM, f"removed: {gone['title']}"))
                tasks = show_plan(conn, goal)
            continue
        if a == "":
            store.append_event(conn, goal["id"], "working", ACTOR,
                               "approved from the terminal")
            say()
            say(c(GREEN, "Approved.") + " The tasks are live.")
            return (True, False)


def do_run(conn, node):
    say()
    say(c(BOLD, node["title"]))
    say(c(DIM, f"done when: {node['exit_criterion']}"))
    say()
    say("I can draft this one. It takes about a minute and costs one AI call.")
    a = ask("", [("", "do it"), ("s", "skip it"), ("q", "quit")])
    if a == "q":
        return (False, False)
    if a != "":
        return (True, True)
    if not ensure_store():
        say(c(AMBER, "Could not start the engine. Nothing was changed."))
        return (False, False)
    say()
    say(c(DIM, "working…"))
    proc = subprocess.run(
        ["python3", str(HERE / "worker_ai.py"), "--task", node["id"]],
        capture_output=True, text=True, timeout=900)
    if proc.returncode != 0:
        say(c(AMBER, "That task failed. Nothing else was touched."))
        say(c(DIM, (proc.stderr or "").strip()[:200]))
        return (True, True)
    fresh = store.db()
    crits = store.criteria_for(fresh, node["id"])
    met = [x for x in crits if x["state"] == "met"]
    say()
    say(c(GREEN, "Done.") + f" {len(met)} of {len(crits)} criteria met with evidence.")
    for x in crits:
        mark = c(GREEN, "met  ") if x["state"] == "met" else c(AMBER, "open ")
        say(f"{mark} {x['text'][:66]}")
    return (True, False)


def fix_criterion(conn, node, crits):
    """Rewrite what 'done' means for this task.

    Sometimes the work is right and the test is wrong. The decomposer guessed
    that a privacy policy had to be live at a public URL when the task was only
    ever to draft the text. Without this, the only ways out were to accept
    something untrue or to leave the task stuck forever.
    """
    say()
    say("Which one is worded wrong?")
    for i, x in enumerate(crits, 1):
        say(c(AMBER, f"  {i}. ") + x["text"][:70])
    which = prompt_text("which number? ")
    if not (which.isdigit() and 1 <= int(which) <= len(crits)):
        return crits
    x = crits[int(which) - 1]
    say()
    say(c(DIM, "now: ") + x["text"])
    new = prompt_text("should say: ")
    if not new:
        say(c(DIM, "Left as it was."))
        return crits
    was = store.edit_criterion(conn, x["id"], new, ACTOR)["was"]
    say()
    say(c(GREEN, "Changed.") + " The old wording is kept in the log:")
    say(c(DIM, f'  was: "{was}"'))
    return [y for y in store.criteria_for(conn, node["id"]) if y["state"] != "met"]


def do_check(conn, node):
    """Returns (keep going, skip this one).

    The safe choice is the default here on purpose. An agent wrote text to a
    file; it did not publish, send, or install anything. Reading that and being
    offered "accept them all" as the obvious next key invites a person to record
    something untrue in the one system whose whole promise is that done is
    testable. So the enter key now leaves it open, and accepting is one
    criterion at a time, each needing a reason.
    """
    say()
    say(c(BOLD, node["title"]))
    say(c(DIM, "An agent drafted this. Nothing was published, sent or installed,"))
    say(c(DIM, "and nothing left your Mac."))
    # A readable taste of the result, not the whole file: blank lines and
    # markdown scaffolding stripped so what shows is the actual content.
    text = output_of(node["id"]) or ""
    lines = [ln.rstrip() for ln in text.splitlines()]
    lines = [ln for ln in lines if ln.strip() and set(ln.strip()) != {"-"}]
    lines = [ln.lstrip("#* ").replace("**", "") for ln in lines]
    say()
    for line in lines[1:19]:
        say(c(DIM, line[:76]))
    if len(lines) > 19:
        say(c(DIM, f"… {len(lines) - 19} more lines"))
    crits = [x for x in store.criteria_for(conn, node["id"]) if x["state"] != "met"]
    say()
    say(c(DIM, f"saved to {path_of(node['id']).relative_to(ROOT)}"))
    say()
    say("Still open, one at a time:")
    for i, x in enumerate(crits, 1):
        say(c(AMBER, f"  {i}. ") + x["text"][:70])
    say()
    say(c(DIM, "Accepting a criterion records it as true in your own system, so"))
    say(c(DIM, "only accept what you can actually point at. Leaving it open is fine."))

    while True:
        a = ask("", [("", "leave it open"),
                     ("r", "ask for changes"),
                     ("c", "fix a criterion"),
                     ("a", "accept one of them"),
                     ("q", "quit")])
        if a == "q":
            return (False, False)
        if a == "":
            return (True, True)
        if a == "c":
            crits = fix_criterion(conn, node, crits)
            if not crits:
                return (True, True)
            continue
        if a == "r":
            note = prompt_text("what should change? ")
            if not note:
                continue
            if not ensure_store():
                say(c(AMBER, "Could not start the engine. Nothing was changed."))
                return (True, True)
            say()
            say(c(DIM, "redoing it with your note…"))
            subprocess.run(
                ["python3", str(HERE / "worker_ai.py"), "--task", node["id"],
                 "--note", note], capture_output=True, text=True, timeout=900)
            say(c(GREEN, "Rewritten.") + " Run substrate again to read it.")
            return (True, True)
        if a == "a":
            which = prompt_text("which number? ")
            if not (which.isdigit() and 1 <= int(which) <= len(crits)):
                continue
            x = crits[int(which) - 1]
            say()
            say(c(BOLD, x["text"]))
            why = prompt_text("what makes this true? ")
            if not why:
                say(c(DIM, "Not accepted. A criterion needs evidence."))
                continue
            store.set_criterion(conn, x["id"], "met", ACTOR, why)
            crits = [y for y in store.criteria_for(conn, node["id"])
                     if y["state"] != "met"]
            say(c(GREEN, "Recorded."))
            if not crits:
                store.append_event(conn, node["id"], "done", ACTOR,
                                   "every criterion met and evidenced")
                say(c(GREEN, "That task is done."))
                return (True, False)
            say()
            say("Still open:")
            for i, y in enumerate(crits, 1):
                say(c(AMBER, f"  {i}. ") + y["text"][:70])


def do_yours(nodes):
    say()
    say("Nothing left that I can do. These are yours:")
    say()
    for n in nodes:
        say(f"· {n['title']}")
        say(c(DIM, f"  done when: {n['exit_criterion']}"))
    say()
    say(c(DIM, "When one is finished, run substrate again and tell me."))
    return False


# ---------------------------------------------------------------- commands

def cmd_new(sentence):
    if not sentence:
        say("Say the goal in one sentence, in quotes.")
        return
    say()
    say(c(DIM, "thinking about how to break this down…"))
    proc = subprocess.run(
        ["python3", str(HERE / "decompose.py"), sentence],
        capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        say(c(AMBER, "That did not work."))
        say(c(DIM, (proc.stderr or proc.stdout).strip()[-300:]))
        return
    loop()


def cmd_tree():
    if not ensure_store():
        say(c(AMBER, "Could not start the engine."))
        return
    try:
        urllib.request.urlopen(PAGES_URL, timeout=2)
    except (urllib.error.URLError, OSError):
        subprocess.Popen(["python3", str(HERE / "pages.py"), "8004"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
        time.sleep(1.5)
    subprocess.run(["open", PAGES_URL + "/prototypes/canvas/canvas.html"])
    say()
    say("Opened the visual view in your browser.")


def loop():
    """Show where things stand, do the next thing, repeat until she stops."""
    skipped = set()
    while True:
        conn = store.db()
        say()
        say(c(BOLD, "Substrate"))
        show_standing(conn)
        kind, payload = next_action(conn, skipped)
        say()

        if kind == "first-goal":
            say("Nothing here yet.")
            say()
            say(c(DIM, 'Start with:  substrate new "your goal in one sentence"'))
            return
        if kind == "all-done":
            say(c(GREEN, "Everything is done."))
            return
        if kind == "nothing":
            say("Nothing to do right now, and nothing waiting on you.")
            return

        say(c(BOLD, "Next"))
        if kind == "approve":
            say("A plan is waiting for you to say yes.")
            went_on, skip = do_approve(conn, payload)
        elif kind == "check":
            say("Something was finished and needs your eyes.")
            went_on, skip = do_check(conn, payload)
        elif kind == "run":
            went_on, skip = do_run(conn, payload)
        else:  # "yours"
            do_yours(payload)
            return

        if skip:
            skipped.add(payload["id"])
        if not went_on:
            return


def main():
    args = sys.argv[1:]
    if args and args[0] == "new":
        cmd_new(" ".join(args[1:]))
    elif args and args[0] == "tree":
        cmd_tree()
    elif args and args[0] in ("-h", "--help", "help"):
        print(__doc__)
    else:
        loop()
    print()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()

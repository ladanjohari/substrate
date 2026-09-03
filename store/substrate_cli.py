#!/usr/bin/env python3
"""
Substrate CLI — the substrate without a browser.

Talks straight to the SQLite file, so it works whether or not the store service
is running, and anything it writes shows up in the live tree on the next poll.
Every command takes --json for agents; the default output is for humans.

  substrate                            the tree (same as substrate tree)
  substrate decompose ["a goal"]       one sentence in, a proposed tree out; asks if you give none
  substrate approve <goal>             let the runner start on a waiting goal
  substrate run [--once] [--agents N]  agents take work, N at a time (default 2)
  substrate add <id> TITLE -c ""       create a goal, or a task inside one (goal/task)
  substrate edit <node> -t "" -i ""    change a node's title, intent, or headline criterion
  substrate block <node> --after X     one task waits on another
  substrate unblock <node> --from X    undo that
  substrate remove <node>              delete a node (a goal takes its tasks with it)
  substrate tree [goal]                the whole plan, indented, with criteria
  substrate frontier                   what is allowed to run right now
  substrate path                       the critical path per goal
  substrate show <node>                one node in full
  substrate criteria <node>            its exit criteria and their evidence
  substrate add-criterion <node> TEXT  add a criterion
  substrate meet <criterion-id> -e ""  mark one met, with evidence
  substrate fail <criterion-id> -e ""  mark one failed, with evidence
  substrate reopen <criterion-id>      take back one ticked off in error
  substrate state <node> <state> -n "" move a node (done needs criteria met)
  substrate log [n]                    the last n events

Ids: a goal is a short slug, a task is goal/slug. Inside a goal you can refer
to a task by its short name wherever a node is expected.

The actor defaults to $SUBSTRATE_ACTOR, else your shell username.
The database defaults to store/substrate.db; set $SUBSTRATE_DB to use another.
"""

import argparse
import getpass
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import substrate_store as store  # noqa: E402

def _unicode_ok():
    if os.environ.get("SUBSTRATE_ASCII"):
        return False
    try:
        "·▸✓☐☑☒".encode(sys.stdout.encoding or "ascii")
        return True
    except (UnicodeEncodeError, LookupError):
        return False


GLYPHS = _unicode_ok()
MARK = ({"idle": "·", "working": "▸", "waiting": "!", "error": "x", "done": "✓"}
        if GLYPHS else
        {"idle": ".", "working": ">", "waiting": "!", "error": "x", "done": "v"})
CRIT = ({"unmet": "☐", "met": "☑", "failed": "☒"}
        if GLYPHS else {"unmet": "-", "met": "x", "failed": "!"})

# Colour carries the same meaning it carries everywhere else in this project:
# motion is working, amber means a person is needed, green means done. It is
# switched off when the output is piped or when NO_COLOR is set, so a script
# reading this never has to strip escape codes.
def _colour_on():
    # Off when piped, so a script never has to strip escape codes. NO_COLOR
    # turns it off everywhere; SUBSTRATE_COLOR=1 forces it on, which is what
    # you want when piping into `less -R` or capturing output for a demo.
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("SUBSTRATE_COLOR"):
        return os.environ["SUBSTRATE_COLOR"] not in ("0", "", "no", "false")
    return sys.stdout.isatty()


COLOUR = _colour_on()


def c(text, *styles):
    if not COLOUR or not styles:
        return text
    codes = {"dim": "2", "bold": "1", "green": "32", "amber": "33",
             "blue": "34", "red": "31", "cyan": "36"}
    return "\033[" + ";".join(codes[s] for s in styles) + "m" + text + "\033[0m"


STATE_STYLE = {"idle": ("dim",), "working": ("blue",), "waiting": ("amber", "bold"),
               "error": ("red", "bold"), "done": ("green",)}
CRIT_STYLE = {"unmet": ("dim",), "met": ("green",), "failed": ("red",)}


def actor():
    return os.environ.get("SUBSTRATE_ACTOR") or getpass.getuser()


def out(human, data, as_json):
    print(json.dumps(data, indent=2) if as_json else human)


def crit_tag(n):
    if not n["criteria_total"]:
        return "no criteria"
    tag = f"{n['criteria_met']}/{n['criteria_total']} criteria"
    return tag + (f", {n['criteria_failed']} failed" if n["criteria_failed"] else "")


def resolve(conn, ref, goal=None):
    """Turn what the person typed into a node id.

    Accepts a full id, or a task's short name when the goal is known or when
    only one task anywhere has that name."""
    live = "SELECT id FROM nodes WHERE id=? AND removed=0"
    if conn.execute(live, (ref,)).fetchone():
        return ref
    if goal and conn.execute(live, (f"{goal}/{ref}",)).fetchone():
        return f"{goal}/{ref}"
    hits = [r["id"] for r in conn.execute(
        "SELECT id FROM nodes WHERE id LIKE ? AND removed=0", (f"%/{ref}",))]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        sys.exit(f"'{ref}' is in more than one goal, say which: " + ", ".join(hits))
    sys.exit(f"no such node: {ref}")


def cmd_add(conn, a):
    nid = a.id.strip()
    if not nid or any(ch.isspace() for ch in nid) or nid.count("/") > 1:
        sys.exit("an id is a short slug like 'ship-cli', or goal/slug for a task")
    parent = nid.split("/")[0] if "/" in nid else None
    if parent and not conn.execute(
            "SELECT 1 FROM nodes WHERE id=? AND removed=0 AND parent IS NULL", (parent,)).fetchone():
        sys.exit(f"no such goal: {parent}   (create it first: substrate add {parent} \"...\" -c \"...\")")
    criteria = [c.strip() for c in a.criterion if c.strip()]
    if not criteria:
        sys.exit("a node needs at least one exit criterion (-c \"what a stranger could check\")")
    store.add_node(conn, actor(), {
        "id": nid, "title": a.title, "intent": a.intent or a.title,
        "exit_criterion": criteria[0], "criteria": criteria, "parent": parent,
        "blocked_by": [resolve(conn, b, parent) for b in a.after],
        "note": "created from the command line",
    })
    n = dict(conn.execute("SELECT * FROM nodes WHERE id=?", (nid,)).fetchone())
    n["criteria"] = store.criteria_for(conn, nid)
    kind = "task" if parent else "goal"
    human = (f"added {kind} {nid}  ({len(criteria)} criteria)"
             + (f"\n  after: {', '.join(a.after)}" if a.after else ""))
    out(human, n, a.json)


def cmd_edit(conn, a):
    node = resolve(conn, a.node)
    fields = {k: v for k, v in (("title", a.title), ("intent", a.intent),
                                ("exit_criterion", a.exit)) if v is not None}
    if not fields:
        sys.exit("nothing to change: give -t, -i, or -e")
    store.update_node(conn, node, actor(), fields)
    out(f"{node}: {', '.join(fields)} rewritten", {"node": node, "changed": list(fields)}, a.json)


def cmd_block(conn, a):
    node = resolve(conn, a.node)
    goal = node.split("/")[0]
    done = []
    for b in a.after:
        blocker = resolve(conn, b, goal)
        store.add_edge(conn, actor(), blocker, node)
        done.append(blocker)
    out(f"{node} now waits on {', '.join(done)}", {"node": node, "blocked_by": done}, a.json)


def cmd_unblock(conn, a):
    node = resolve(conn, a.node)
    goal = node.split("/")[0]
    done = []
    for b in a.from_:
        blocker = resolve(conn, b, goal)
        store.remove_edge(conn, actor(), blocker, node)
        done.append(blocker)
    out(f"{node} no longer waits on {', '.join(done)}", {"node": node, "unblocked": done}, a.json)


def cmd_remove(conn, a):
    node = resolve(conn, a.node)
    gone = store.remove_node(conn, node, actor())
    extra = f" and its {len(gone) - 1} tasks" if len(gone) > 1 else ""
    out(f"removed {node}{extra}", {"removed": gone}, a.json)


def cmd_decompose(conn, a):
    # One sentence in, a proposed tree out, written straight to the database.
    # Uses the `claude` command once. The goal arrives waiting for approval.
    import decompose
    sentence = " ".join(a.sentence).strip()
    if not sentence:
        try:
            sentence = input("Your goal, in one sentence: ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.exit("\nno goal given")
    if not sentence:
        sys.exit("no goal given")
    print("thinking (one AI call, about half a minute)...")
    plan = decompose.think(sentence)
    gid = decompose.store_proposal(plan)
    a.goal = gid
    cmd_tree(conn, a)
    if not a.json:
        print(f"\nwaiting for you. Read it, reshape it, then: substrate approve {gid}")


def cmd_run(conn, a):
    # The runner is its own program so it can be left going in a window. This
    # keeps it reachable as one more word after `substrate`, rather than a
    # python command that breaks the shape of everything else.
    import subprocess
    cmd = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "runner.py")]
    if a.once:
        cmd.append("--once")
    if a.model:
        cmd += ["--model", a.model]
    if a.agents:
        cmd += ["--agents", str(a.agents)]
    try:
        sys.exit(subprocess.call(cmd))
    except KeyboardInterrupt:
        sys.exit("\nstopped")


def cmd_approve(conn, a):
    goal = resolve(conn, a.goal)
    row = conn.execute("SELECT state, parent FROM nodes WHERE id=?", (goal,)).fetchone()
    if row["parent"]:
        sys.exit(f"{goal} is a task; approve its goal: {row['parent']}")
    if row["state"] != "waiting":
        if row["state"] in ("idle", "working"):
            sys.exit(f"{goal} is already open for work, it needs no approval.\n"
                     f"Approval is for a plan the decomposer proposed."
                     f"  substrate run --once  to let an agent take a task")
        sys.exit(f"{goal} is {row['state']}, and only a plan waiting for you "
                 f"can be approved")
    store.append_event(conn, goal, "working", actor(),
                       a.note or "approved from the command line; the runner may start")
    out(f"{goal} approved. To let an agent take the first task:\n"
        f"  substrate run --once        one task, then stop\n"
        f"  substrate run               keep going, control-C to stop",
        {"goal": goal, "state": "working"}, a.json)


def order_tasks(tasks, blockers):
    """Blockers before the things they block, so 'after X' always points up."""
    left = {t["id"]: t for t in tasks}
    placed, ordered = set(), []
    while left:
        ready = [t for t in left.values()
                 if not [b for b in blockers.get(t["id"], []) if b in left and b not in placed]]
        if not ready:                      # a cycle, should not happen; print the rest as is
            ready = sorted(left.values(), key=lambda t: t["id"])
        for t in sorted(ready, key=lambda t: t["id"]):
            ordered.append(t); placed.add(t["id"]); left.pop(t["id"])
    return ordered


def boxes(n, plain=False):
    """Criteria as a row of boxes: ☑ met, ☒ failed, ☐ still open."""
    cs = n.get("criteria") or []
    if not cs:
        return "no criteria"
    if len(cs) > 8:
        return f"{n['criteria_met']}/{n['criteria_total']}"
    if plain:
        return "".join(CRIT[x["state"]] for x in cs)
    return "".join(c(CRIT[x["state"]], *CRIT_STYLE[x["state"]]) for x in cs)


def width():
    # Wrapping mid-word makes the tree unreadable, so every line is built to
    # fit the window. Narrower than 60 is treated as 60; a pipe reports 80.
    return max(60, shutil.get_terminal_size((80, 24)).columns)


def why(node, blockers, state, room=None, n=None):
    if state == "done":
        return "done"
    if state == "working":
        return "an agent is on it"
    if state == "waiting":
        if n and n.get("criteria_total"):
            left = n["criteria_total"] - n["criteria_met"]
            return f"needs you, {left} of {n['criteria_total']} checks left"
        return "needs you"
    if state == "error":
        return "error, look at the log"
    b = [x.split("/")[-1] for x in blockers.get(node, [])]
    if not b and state == "idle":
        return "ready for an agent"
    if not b:
        return "ready to start"
    line = "after " + ", ".join(b)
    if room is None or len(line) <= room:
        return line
    # Too long for the window: name the first one and count the rest, and if
    # even that will not fit, cut the name rather than print a bare number.
    if len(b) > 1:
        short = f"after {b[0]} +{len(b) - 1} more"
        if len(short) <= room:
            return short
        return f"after {len(b)} tasks"
    return "after " + (b[0] if len(b[0]) + 6 <= room else b[0][:max(3, room - 7)] + "\u2026")


def tally(tasks):
    """The one line that says where a goal stands."""
    n = {"done": 0, "waiting": 0, "working": 0, "ready": 0, "blocked": 0}
    for t in tasks:
        if t["state"] in ("done", "waiting", "working"):
            n[t["state"]] += 1
        elif t.get("_ready"):
            n["ready"] += 1
        else:
            n["blocked"] += 1
    bits = []
    if n["waiting"]:
        bits.append(c(f"{n['waiting']} need you", "amber", "bold"))
    if n["working"]:
        bits.append(c(f"{n['working']} running", "blue"))
    if n["ready"]:
        bits.append(f"{n['ready']} ready")
    if n["blocked"]:
        bits.append(c(f"{n['blocked']} blocked", "dim"))
    if n["done"]:
        bits.append(c(f"{n['done']} done", "green"))
    return "   ".join(bits)


def render_goal(g, tasks, blockers):
    title = c(g["title"], "bold")
    lines = [f"{title}   {c(g['id'], 'dim')}"]
    if g["state"] == "waiting":
        lines.append(c("  not approved, so nothing runs", "amber", "bold"))
        lines.append(c(f"  substrate approve {g['id']}", "amber"))
    if not tasks:
        lines.append(c("  no tasks yet", "dim"))
        return lines
    tasks = order_tasks(tasks, blockers)
    for t in tasks:
        t["_ready"] = not blockers.get(t["id"]) and t["state"] == "idle"
    lines.append("  " + tally(tasks))
    lines.append("")
    w = max(len(t["id"].split("/")[-1]) for t in tasks)
    bw = max(len(boxes(t, plain=True)) for t in tasks)
    room = width() - (2 + 2 + w + 2 + bw + 2)
    for t in tasks:
        st = t["state"]
        mark = c(MARK[st], *STATE_STYLE[st])
        name = t["id"].split("/")[-1]
        name_out = c(f"{name:<{w}}", "bold") if st == "waiting" else \
            (c(f"{name:<{w}}", "dim") if st == "idle" and not t["_ready"] else f"{name:<{w}}")
        pad = " " * (bw - len(boxes(t, plain=True)))
        reason = why(t["id"], blockers, st, room, t)
        rstyle = {"waiting": ("amber", "bold"), "done": ("green",),
                  "working": ("blue",), "error": ("red", "bold")}.get(st, ("dim",))
        lines.append(f"  {mark} {name_out}  {boxes(t)}{pad}  {c(reason, *rstyle)}")
    return lines


def next_action(conn, goals):
    """End on the one thing to do next, not on a legend."""
    needs = [t for g in goals for t in g["tasks"] if t["state"] == "waiting"]
    unapproved = [g for g in goals if g["state"] == "waiting"]
    if not needs and unapproved:
        g = unapproved[0]
        return [c("Next", "bold") + "  read it, then let it run",
                "      " + c(f"substrate approve {g['id']}", "amber")]
    if needs:
        t = needs[0]["id"].split("/")[-1]
        word = "task needs" if len(needs) == 1 else "tasks need"
        return [c("Next", "bold") + f"  {len(needs)} {word} you, starting with {t}",
                "      " + c(f"substrate show {t}", "amber")
                + c("     see what is left on it", "dim")]
    ready = [t for g in goals for t in g["tasks"]
             if t["state"] == "idle" and t.get("_ready")]
    if ready:
        return [c("Next", "bold") + f"  {len(ready)} ready for an agent",
                "      " + c("substrate run --once", "blue")
                + c("     one task, then stop", "dim")]
    if goals and all(t["state"] == "done" for g in goals for t in g["tasks"]):
        return [c("Every task is done.", "green", "bold")]
    return []


def cmd_tree(conn, a):
    t = store.tree(conn)
    goals = [n for n in t["nodes"] if not n["parent"]]
    if not goals:
        out("no goals yet. Start one:\n"
            "  substrate decompose        and type your goal when it asks",
            [], a.json)
        return
    if a.goal:
        goals = [g for g in goals if g["id"] == a.goal]
        if not goals:
            sys.exit(f"no such goal: {a.goal}")
    blockers = {}
    for e in t["edges"]:
        blockers.setdefault(e["blocked"], []).append(e["blocker"])
    lines, payload = [], []
    for g in goals:
        tasks = [n for n in t["nodes"] if n["parent"] == g["id"]]
        lines += render_goal(g, tasks, blockers) + [""]
        payload.append(dict(g, tasks=tasks))
    if not a.json:
        lines += next_action(conn, payload)
    out("\n".join(lines).rstrip(), payload, a.json)


def cmd_frontier(conn, a):
    ids = store.frontier(conn)
    rows = [dict(conn.execute("SELECT id,title,parent FROM nodes WHERE id=?", (i,)).fetchone())
            for i in ids]
    if not rows:
        out("nothing is runnable. Everything is waiting, blocked, or done.", rows, a.json)
        return
    w = max(len(r["id"]) for r in rows)
    human = "\n".join(f"  {r['id']:<{w}}   {r['title']}" for r in rows)
    out(f"Runnable now ({len(rows)}):\n{human}", rows, a.json)


def cmd_path(conn, a):
    cp = store.critical_path(conn)
    lines = []
    for gid, v in cp.items():
        if not v["path"]:
            continue
        gstate = conn.execute("SELECT state FROM nodes WHERE id=?", (gid,)).fetchone()["state"]
        lines.append(f"{c(v['title'], 'bold')}   {c(gid, 'dim')}")
        lines.append("  " + c(f"the longest chain left is {v['cost']} open criteria", "dim"))
        lines.append("")
        w = max(len(x["id"].split("/")[-1]) for x in v["path"])
        for x in v["path"]:
            st = x["state"]
            n = x["id"].split("/")[-1]
            name = c(f"{n:<{w}}", "bold") if st == "waiting" else \
                (c(f"{n:<{w}}", "dim") if st == "idle" else f"{n:<{w}}")
            lines.append(f"  {c(MARK[st], *STATE_STYLE[st])} {name}  "
                         + c(f"{x['open_criteria']} open", "dim"))
        lines.append("")
        nxt = v["next"]
        if nxt:
            lines.append(c("Next", "bold") + "  start here")
            lines.append("      " + c(f"substrate show {nxt.split('/')[-1]}", "amber"))
        elif gstate == "waiting":
            lines.append(c("Next", "bold") + "  nothing can start, this plan is not approved")
            lines.append("      " + c(f"substrate approve {gid}", "amber"))
        else:
            h = v["head"].split("/")[-1]
            lines.append(c("Next", "bold") + f"  nothing can start, {h} is waiting on you")
            lines.append("      " + c(f"substrate show {h}", "amber"))
        lines.append("")
    if not lines:
        goals = conn.execute(
            "SELECT COUNT(*) FROM nodes WHERE parent IS NULL AND removed=0").fetchone()[0]
        if not goals:
            msg = "no goals yet.  substrate decompose  to start one"
        elif conn.execute("SELECT COUNT(*) FROM criteria c JOIN nodes n ON n.id=c.node"
                          " WHERE c.state!='met' AND n.removed=0").fetchone()[0]:
            msg = ("no chain to walk: your goals have no tasks under them yet.\n"
                   "substrate tree   to see what is there")
        else:
            msg = "every criterion is met. Nothing is left."
        out(msg, cp, a.json)
        return
    out("\n".join(lines).rstrip(), cp, a.json)


def cmd_show(conn, a):
    a.node = resolve(conn, a.node)
    r = conn.execute("SELECT * FROM nodes WHERE id=?", (a.node,)).fetchone()
    n = dict(r)
    n["criteria"] = store.criteria_for(conn, a.node)
    b = [x["blocker"] for x in conn.execute(
        "SELECT blocker FROM edges WHERE blocked=?", (a.node,))]
    n["blocked_by"] = b
    st = n["state"]
    label = {"waiting": "needs you", "done": "done", "working": "an agent is on it",
             "error": "error", "idle": "not started"}[st]
    L = [f"{c(MARK[st], *STATE_STYLE[st])} {c(n['title'], 'bold')}   "
         + c(label, *STATE_STYLE[st]),
         "  " + c(n["id"], "dim")]
    if n["intent"]:
        L += ["", "  " + n["intent"]]
    if b:
        L += ["", "  " + c("waits for  ", "dim")
              + ", ".join(x.split("/")[-1] for x in b)]
    met = sum(1 for x in n["criteria"] if x["state"] == "met")
    L += ["", f"  {c('CHECKS', 'dim')}  {met} of {len(n['criteria'])} met"]
    for x in n["criteria"]:
        L.append(f"  {c(CRIT[x['state']], *CRIT_STYLE[x['state']])} "
                 + c(f"#{x['id']}", "dim") + f" {x['text']}")
        if x["evidence"]:
            L.append("       " + c("evidence: " + x["evidence"], "dim"))
    open_ = [x for x in n["criteria"] if x["state"] != "met"]
    if open_ and st != "done":
        L += ["", c("Next", "bold") + "  do the work, then record the proof",
              "      " + c(f"substrate meet {open_[0]['id']} -e \"what shows it is true\"",
                           "amber")]
        if len(open_) == 1:
            L.append("      " + c(f"substrate state {n['id'].split('/')[-1]} done", "dim")
                     + c("   once that last check is met", "dim"))
    out("\n".join(L), n, a.json)


def cmd_criteria(conn, a):
    a.node = resolve(conn, a.node)
    cs = store.criteria_for(conn, a.node)
    human = "\n".join(
        f"{CRIT[c['state']]} #{c['id']} {c['text']}"
        + (f"\n     evidence: {c['evidence']}  ({c['checked_by']}, {c['checked_at']})"
           if c["evidence"] else "")
        for c in cs) or "no criteria on this node"
    out(human, cs, a.json)


def cmd_add_criterion(conn, a):
    a.node = resolve(conn, a.node)
    cid = store.add_criterion(conn, a.node, a.text, actor())
    out(f"added criterion #{cid} to {a.node}", {"criterion": cid}, a.json)


def cmd_reopen(conn, a):
    # A criterion ticked off in error has to be takeable back, or the record
    # is not truthful. The log keeps the mistake and the correction both:
    # the trail of a mistake is data.
    res = store.set_criterion(conn, a.criterion, "unmet", actor(),
                              a.reason or "reopened; the earlier evidence did not hold")
    out(f"#{a.criterion} on {res['node']} is open again. The old evidence stays in the log.",
        res, a.json)


def cmd_set_criterion(conn, a, to_state):
    res = store.set_criterion(conn, a.criterion, to_state, actor(), a.evidence)
    tail = ("  all criteria met — this node can now be closed"
            if res["node_closable"] and to_state == "met" else "")
    out(f"#{a.criterion} on {res['node']} -> {to_state}{tail}", res, a.json)


def cmd_state(conn, a):
    a.node = resolve(conn, a.node)
    try:
        store.append_event(conn, a.node, a.state, actor(), a.note)
    except ValueError as e:
        sys.exit(f"refused: {e}")
    out(f"{a.node} -> {a.state}", {"node": a.node, "state": a.state}, a.json)


def cmd_log(conn, a):
    rows = [dict(r) for r in conn.execute(
        "SELECT * FROM events ORDER BY seq DESC LIMIT ?", (a.n,))][::-1]
    human = "\n".join(
        f"{r['ts']}  {r['actor']:<10} {r['node']}  "
        f"{r['from_state']} -> {r['to_state']}  {r['note'] or ''}" for r in rows)
    out(human, rows, a.json)


def main():
    p = argparse.ArgumentParser(prog="substrate", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--json", action="store_true", help="machine-readable output")
    sub = p.add_subparsers(dest="cmd")  # no command means: show the tree

    s = sub.add_parser("decompose", help="one sentence in, a proposed tree out (uses claude once)")
    s.add_argument("sentence", nargs="*", help="leave empty to be asked")
    s = sub.add_parser("run", help="let an agent work the approved tasks")
    s.add_argument("--once", action="store_true", help="one round, then stop")
    s.add_argument("--agents", type=int,
                   help="how many tasks to work at the same time (default 2)")
    s.add_argument("--model", help="which model the agent uses")
    s = sub.add_parser("approve", help="let the runner start on a waiting goal")
    s.add_argument("goal"); s.add_argument("-n", "--note")
    s = sub.add_parser("add", help="create a goal, or a task as goal/slug")
    s.add_argument("id"); s.add_argument("title")
    s.add_argument("-i", "--intent", help="why this exists, one sentence")
    s.add_argument("-c", "--criterion", action="append", default=[],
                   help="an exit criterion; repeat for more (at least one)")
    s.add_argument("--after", action="append", default=[],
                   help="a task this one waits on; repeat for more")
    s = sub.add_parser("edit", help="change a node's wording")
    s.add_argument("node")
    s.add_argument("-t", "--title"); s.add_argument("-i", "--intent")
    s.add_argument("-e", "--exit", help="the headline exit criterion")
    s = sub.add_parser("block", help="make one node wait on another")
    s.add_argument("node"); s.add_argument("--after", action="append", required=True)
    s = sub.add_parser("unblock", help="undo a block")
    s.add_argument("node"); s.add_argument("--from", dest="from_", action="append", required=True)
    s = sub.add_parser("remove", help="delete a node; a goal takes its tasks with it")
    s.add_argument("node")
    s = sub.add_parser("tree"); s.add_argument("goal", nargs="?")
    sub.add_parser("frontier")
    sub.add_parser("path")
    s = sub.add_parser("show"); s.add_argument("node")
    s = sub.add_parser("criteria"); s.add_argument("node")
    s = sub.add_parser("add-criterion"); s.add_argument("node"); s.add_argument("text")
    s = sub.add_parser("reopen", help="take back a criterion ticked off in error")
    s.add_argument("criterion", type=int)
    s.add_argument("-e", "--reason", help="why it is being reopened")
    for name in ("meet", "fail"):
        s = sub.add_parser(name)
        s.add_argument("criterion", type=int)
        s.add_argument("-e", "--evidence", help="what shows this is true")
    s = sub.add_parser("state")
    s.add_argument("node"); s.add_argument("state", choices=store.STATES)
    s.add_argument("-n", "--note")
    s = sub.add_parser("log"); s.add_argument("n", nargs="?", type=int, default=15)

    a = p.parse_args()
    if a.cmd is None:
        a.cmd, a.goal = "tree", None
    conn = store.db()
    dispatch = {
        "decompose": cmd_decompose, "approve": cmd_approve, "run": cmd_run,
        "add": cmd_add, "edit": cmd_edit, "block": cmd_block, "unblock": cmd_unblock,
        "remove": cmd_remove,
        "tree": cmd_tree, "frontier": cmd_frontier, "path": cmd_path, "show": cmd_show,
        "criteria": cmd_criteria, "add-criterion": cmd_add_criterion,
        "state": cmd_state, "log": cmd_log,
        "reopen": cmd_reopen,
        "meet": lambda c, x: cmd_set_criterion(c, x, "met"),
        "fail": lambda c, x: cmd_set_criterion(c, x, "failed"),
    }
    try:
        dispatch[a.cmd](conn, a)
    except ValueError as e:
        sys.exit(f"refused: {e}")


if __name__ == "__main__":
    main()

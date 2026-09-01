#!/usr/bin/env python3
"""
Substrate store v0, slice B of plan v1.

The memory layer: a SQLite file holding the goal DAG (data model v1: node,
edges, log) behind a tiny local HTTP service. Agents and humans write state
changes through it; displays read from it. No cloud, no AI, this layer only
remembers.

Data model v1 (process/data-model-v1.html):
  node:  intent, exit criterion, state, owner, children (via parent)
  edges: blocked_by (the DAG)
  log:   append-only events, evidence attached; node state is derived
         convenience, the log is the truth

Run:   python3 substrate_store.py serve [port]     (default 8040)
Seed:  python3 substrate_store.py seed             (loads the example plan, idempotent)

API:
  GET  /tree            the full graph: nodes, edges, latest state + criteria
  GET  /log             the append-only event log
  GET  /frontier        nodes whose blockers are all done and state is idle
  GET  /critical-path   the longest remaining chain of open criteria per goal
  GET  /criteria/<node> the exit criteria of one node, with state and evidence
  POST /event           {"node": id, "to": state, "actor": who,
                         "note": evidence}  -> appends event, updates state
  POST /criterion/add   {"node": id, "text": ..., "actor": who}
  POST /criterion/set   {"criterion": n, "to": met|unmet|failed,
                         "evidence": ..., "actor": who}

A node cannot reach 'done' while any of its criteria is unmet, and a criterion
cannot be met without evidence. That pair is what makes 'done' testable rather
than asserted.
"""

import json
import os
import sqlite3
import sys
import traceback
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# The database lives next to this file unless SUBSTRATE_DB points elsewhere.
# The override exists so a test, or a second person on the same machine, can
# work against their own file without touching the real one.
DB_PATH = Path(os.environ.get("SUBSTRATE_DB") or Path(__file__).parent / "substrate.db")
STATES = ("idle", "working", "waiting", "error", "done")
CRIT_STATES = ("unmet", "met", "failed")

SCHEMA = """
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  intent TEXT NOT NULL,
  exit_criterion TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'idle',
  owner TEXT,
  parent TEXT REFERENCES nodes(id),
  runbook TEXT
);
CREATE TABLE IF NOT EXISTS edges (
  blocker TEXT NOT NULL REFERENCES nodes(id),
  blocked TEXT NOT NULL REFERENCES nodes(id),
  PRIMARY KEY (blocker, blocked)
);
CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL,
  actor TEXT NOT NULL,
  node TEXT NOT NULL REFERENCES nodes(id),
  from_state TEXT,
  to_state TEXT NOT NULL,
  note TEXT
);
CREATE TABLE IF NOT EXISTS criteria (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  node TEXT NOT NULL REFERENCES nodes(id),
  ord INTEGER NOT NULL DEFAULT 0,
  text TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'unmet',
  evidence TEXT,
  checked_by TEXT,
  checked_at TEXT
);
CREATE INDEX IF NOT EXISTS criteria_by_node ON criteria(node, ord);
"""

PLAN_V1 = {
    "goal": {
        "id": "substrate-v0.1",
        "title": "Build the substrate v0.1",
        "intent": "One real goal typed in, decomposed, executed by an agent, watched live, finished green.",
        "exit_criterion": "The dogfood goal (H) reaches done.",
    },
    "nodes": [
        ("A", "Lock the data model",
         "Agree what a goal, task, exit criterion, question, and state change look like as data.",
         "The owner signs off the data-model page; schema committed.", []),
        ("B", "The store: memory that survives sessions",
         "A database file plus a small always-on service; agents write through it, displays read.",
         "A state change written by one session is read back by a different session.", ["A"]),
        ("C", "The decomposer: goal in, proposed tree out",
         "An agent takes a typed goal, restates intent, writes a proposed tree with exit criteria.",
         "Typing one sentence produces a stored, inspectable proposed tree.", ["B"]),
        ("D", "The live tree: the viewer, now watching",
         "The goal-tree page reads the store instead of a baked file.",
         "A state change in the store is visible in the browser within a second, no reload.", ["B"]),
        ("E", "The worker: an agent that reports home",
         "One agent picks a frontier task, works it, writes state changes with evidence back.",
         "One task goes idle to working to done by an agent's own updates, evidence logged.", ["B"]),
        ("F", "The negotiation surface",
         "Where a proposed tree is reshaped and approved before anything runs.",
         "The owner reshapes and approves a proposed tree; the approval is recorded as an event.", ["C", "D"]),
        ("G", "The gate inbox",
         "Every amber question in one place; answering one unblocks its branch.",
         "Answering a question flips its node from waiting and its dependents start.", ["D", "E"]),
        ("H", "Dogfood: the substrate tracks its own v0.2",
         "The next milestone entered as goal number one, run through the whole system.",
         "The v0.2 plan lives in the substrate, not in a chat.", ["C", "D", "E", "F", "G"]),
    ],
}


_CONN = None


def db():
    # One connection per process, opened once and kept.
    # This used to open a fresh connection on every single call and nothing
    # ever closed them. A page polling the store once a second exhausted the
    # process's file handles within an hour or two and killed the server.
    global _CONN
    if _CONN is not None:
        return _CONN
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    for mig in ("ALTER TABLE nodes ADD COLUMN runbook TEXT",
                "ALTER TABLE nodes ADD COLUMN removed INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE events ADD COLUMN criterion INTEGER"):
        try:
            conn.execute(mig)
        except sqlite3.OperationalError:
            pass
    backfill_criteria(conn)
    _CONN = conn
    return _CONN


def backfill_criteria(conn):
    # Every node used to carry exactly one exit criterion as a string on the
    # row. Criteria are now first-class rows with their own state, so any node
    # that has none yet gets its old sentence promoted into criterion 1. A done
    # node's criterion is recorded as met - that is what done meant.
    missing = conn.execute("""
        SELECT id, state, exit_criterion FROM nodes n
        WHERE NOT EXISTS (SELECT 1 FROM criteria c WHERE c.node = n.id)
    """).fetchall()
    if not missing:
        return
    for r in missing:
        conn.execute(
            "INSERT INTO criteria (node, ord, text, state, evidence, checked_by, checked_at)"
            " VALUES (?,?,?,?,?,?,?)",
            (r["id"], 0, r["exit_criterion"] or "to be defined in negotiation",
             "met" if r["state"] == "done" else "unmet",
             "carried over from the single exit criterion" if r["state"] == "done" else None,
             "migration" if r["state"] == "done" else None,
             now() if r["state"] == "done" else None),
        )
    conn.commit()


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def unmet(conn, node):
    return [dict(r) for r in conn.execute(
        "SELECT id, text, state FROM criteria WHERE node=? AND state!='met' ORDER BY ord", (node,))]


def append_event(conn, node, to_state, actor, note=None):
    if to_state not in STATES:
        raise ValueError(f"unknown state: {to_state}")
    row = conn.execute("SELECT state FROM nodes WHERE id=?", (node,)).fetchone()
    if not row:
        raise ValueError(f"unknown node: {node}")
    if to_state == "done":
        # The one rule that makes done trustable: a node is done when its
        # criteria say so, not when an agent asserts it. Meet the criteria
        # first, with evidence, and done follows.
        total = conn.execute("SELECT COUNT(*) FROM criteria WHERE node=?", (node,)).fetchone()[0]
        if not total:
            raise ValueError(f"{node} has no exit criteria; add one before closing it")
        open_ = unmet(conn, node)
        if open_:
            # One criterion per line. This message is read by a person deciding
            # what to do next, and a single long line is unreadable.
            n = len(open_)
            word = "criterion" if n == 1 else "criteria"
            names = "".join(f"\n        #{c['id']} {c['text']}" for c in open_)
            raise ValueError(f"{node} cannot be done: {n} {word} still open{names}")
    conn.execute(
        "INSERT INTO events (ts, actor, node, from_state, to_state, note) VALUES (?,?,?,?,?,?)",
        (now(), actor, node, row["state"], to_state, note),
    )
    conn.execute("UPDATE nodes SET state=? WHERE id=?", (to_state, node))
    conn.commit()


def seed():
    conn = db()
    if conn.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]:
        print("already seeded:", DB_PATH)
        return
    g = PLAN_V1["goal"]
    conn.execute(
        "INSERT INTO nodes (id,title,intent,exit_criterion,state) VALUES (?,?,?,?, 'working')",
        (g["id"], g["title"], g["intent"], g["exit_criterion"]),
    )
    for nid, title, intent, exit_c, blockers in PLAN_V1["nodes"]:
        conn.execute(
            "INSERT INTO nodes (id,title,intent,exit_criterion,parent) VALUES (?,?,?,?,?)",
            (nid, title, intent, exit_c, g["id"]),
        )
        for b in blockers:
            conn.execute("INSERT INTO edges (blocker,blocked) VALUES (?,?)", (b, nid))
    conn.commit()
    append_event(conn, "A", "working", "claude", "data model drafted, page built")
    append_event(conn, "A", "done", "owner", "exit met: v1 signed off in session, schema committed")
    append_event(conn, "B", "working", "claude", "store build started")
    print("seeded plan v1 into", DB_PATH)


def criteria_for(conn, node=None):
    if node:
        rows = conn.execute("SELECT * FROM criteria WHERE node=? ORDER BY ord, id", (node,))
    else:
        rows = conn.execute("SELECT * FROM criteria ORDER BY node, ord, id")
    return [dict(r) for r in rows]


def add_criterion(conn, node, text, actor):
    if not conn.execute("SELECT 1 FROM nodes WHERE id=? AND removed=0", (node,)).fetchone():
        raise ValueError(f"unknown node: {node}")
    ord_ = conn.execute("SELECT COALESCE(MAX(ord)+1, 0) FROM criteria WHERE node=?",
                        (node,)).fetchone()[0]
    cur = conn.execute("INSERT INTO criteria (node, ord, text) VALUES (?,?,?)",
                       (node, ord_, text))
    cid = cur.lastrowid
    st = conn.execute("SELECT state FROM nodes WHERE id=?", (node,)).fetchone()["state"]
    conn.execute(
        "INSERT INTO events (ts, actor, node, from_state, to_state, note, criterion)"
        " VALUES (?,?,?,?,?,?,?)",
        (now(), actor, node, st, st, f"criterion added: {text}", cid))
    conn.commit()
    return cid


def set_criterion(conn, cid, to_state, actor, evidence=None):
    if to_state not in CRIT_STATES:
        raise ValueError(f"unknown criterion state: {to_state} (use {'/'.join(CRIT_STATES)})")
    row = conn.execute("SELECT * FROM criteria WHERE id=?", (cid,)).fetchone()
    if not row:
        raise ValueError(f"unknown criterion: {cid}")
    if to_state == "met" and not evidence:
        # Met without evidence is exactly the vibes-based done this system exists
        # to replace.
        raise ValueError("meeting a criterion requires evidence: what shows it is true?")
    conn.execute(
        "UPDATE criteria SET state=?, evidence=?, checked_by=?, checked_at=? WHERE id=?",
        (to_state, evidence, actor, now(), cid))
    node_state = conn.execute("SELECT state FROM nodes WHERE id=?",
                              (row["node"],)).fetchone()["state"]
    conn.execute(
        "INSERT INTO events (ts, actor, node, from_state, to_state, note, criterion)"
        " VALUES (?,?,?,?,?,?,?)",
        (now(), actor, row["node"], node_state, node_state,
         f"criterion {row['state']} -> {to_state}: {row['text']}"
         + (f" | evidence: {evidence}" if evidence else ""), cid))
    conn.commit()
    return {"criterion": cid, "node": row["node"], "state": to_state,
            "node_closable": not unmet(conn, row["node"])}


def tree(conn):
    nodes = [dict(r) for r in conn.execute("SELECT * FROM nodes WHERE removed=0 ORDER BY id")]
    edges = [dict(r) for r in conn.execute("""
        SELECT e.* FROM edges e
        JOIN nodes a ON a.id=e.blocker JOIN nodes b ON b.id=e.blocked
        WHERE a.removed=0 AND b.removed=0""")]
    crit = {}
    for c in criteria_for(conn):
        crit.setdefault(c["node"], []).append(c)
    for n in nodes:
        cs = crit.get(n["id"], [])
        n["criteria"] = cs
        n["criteria_met"] = sum(1 for c in cs if c["state"] == "met")
        n["criteria_total"] = len(cs)
        n["criteria_failed"] = sum(1 for c in cs if c["state"] == "failed")
    return {"nodes": nodes, "edges": edges, "as_of": now()}


def critical_path(conn):
    # The longest remaining chain of blocked-by dependencies inside each goal.
    # Weight is unmet criteria, not tasks, so the path answers the real question:
    # which chain of unfinished checks is holding this goal, and what is the
    # first link a human or agent can pick up right now.
    nodes = {r["id"]: dict(r) for r in
             conn.execute("SELECT * FROM nodes WHERE removed=0")}
    weight = {nid: 0 for nid in nodes}
    for c in conn.execute("SELECT node, state FROM criteria"):
        if c["node"] in weight and c["state"] != "met":
            weight[c["node"]] += 1
    pending = {nid: n for nid, n in nodes.items() if n["state"] != "done"}
    for nid in pending:
        weight[nid] = max(weight[nid], 1)
    succ = {}
    for e in conn.execute("SELECT blocker, blocked FROM edges"):
        if e["blocker"] in pending and e["blocked"] in pending:
            succ.setdefault(e["blocker"], []).append(e["blocked"])

    best, walking = {}, set()

    def longest(nid):
        # (cost, path) of the heaviest chain starting at nid
        if nid in best:
            return best[nid]
        if nid in walking:            # a cycle should be impossible in a DAG;
            return (0, [])            # refuse to hang if one ever appears
        walking.add(nid)
        cost, path = weight[nid], [nid]
        for s in succ.get(nid, []):
            c, p = longest(s)
            if c > cost - weight[nid]:
                cost, path = weight[nid] + c, [nid] + p
        walking.discard(nid)
        best[nid] = (cost, path)
        return best[nid]

    out = {}
    for gid, g in nodes.items():
        if g["parent"]:
            continue
        kids = [nid for nid, n in pending.items() if n["parent"] == gid]
        if not kids:
            out[gid] = {"title": g["title"], "cost": 0, "path": [], "next": None}
            continue
        cost, path = max((longest(k) for k in kids), key=lambda x: x[0])
        ready = set(frontier(conn))
        head = next((p for p in path if p in ready), None)
        out[gid] = {
            "title": g["title"],
            "cost": cost,
            "path": [{"id": p, "title": nodes[p]["title"], "state": nodes[p]["state"],
                      "open_criteria": weight[p]} for p in path],
            "next": head,          # first link anyone can pick up right now
            "head": path[0],       # first link in the chain, ready or not
            "blocked": head is None,
        }
    return out


def frontier(conn):
    # A task reaches the frontier only when (1) it is idle, (2) every blocker
    # is done, and (3) its goal is not still awaiting negotiation - approval
    # is what arms a plan.
    rows = conn.execute("""
        SELECT n.id FROM nodes n
        LEFT JOIN nodes g ON g.id=n.parent
        WHERE n.state='idle' AND n.removed=0
          AND (n.parent IS NULL OR g.state != 'waiting')
          AND NOT EXISTS (
            SELECT 1 FROM edges e JOIN nodes b ON b.id=e.blocker
            WHERE e.blocked=n.id AND b.removed=0 AND b.state != 'done')
    """).fetchall()
    return [r["id"] for r in rows]


def update_node(conn, node, actor, fields):
    allowed = {k: v for k, v in fields.items()
               if k in ("title", "intent", "exit_criterion") and isinstance(v, str)}
    if not allowed:
        raise ValueError("nothing to update")
    row = conn.execute("SELECT state FROM nodes WHERE id=? AND removed=0", (node,)).fetchone()
    if not row:
        raise ValueError(f"unknown node: {node}")
    for k, v in allowed.items():
        conn.execute(f"UPDATE nodes SET {k}=? WHERE id=?", (v, node))
    if "exit_criterion" in allowed:
        # keep the node's headline criterion and criterion 0 the same sentence
        conn.execute("UPDATE criteria SET text=? WHERE node=? AND ord=0",
                     (allowed["exit_criterion"], node))
    conn.execute(
        "INSERT INTO events (ts, actor, node, from_state, to_state, note) VALUES (?,?,?,?,?,?)",
        (now(), actor, node, row["state"], row["state"],
         "reshaped: " + ", ".join(f"{k} rewritten" for k in allowed)),
    )
    conn.commit()


def edit_criterion(conn, cid, text, actor):
    # Changing what "done" means is a real change to the record, so it is
    # logged with the old wording kept in the note. A criterion that has
    # already been met goes back to unmet: the evidence was for the old
    # sentence and cannot be assumed to carry over to a new one.
    row = conn.execute(
        "SELECT c.node, c.text, c.state, c.ord, n.state AS nstate FROM criteria c"
        " JOIN nodes n ON n.id = c.node WHERE c.id=?", (cid,)).fetchone()
    if not row:
        raise ValueError(f"unknown criterion: {cid}")
    text = (text or "").strip()
    if not text:
        raise ValueError("a criterion needs words")
    conn.execute(
        "UPDATE criteria SET text=?, state='unmet', evidence=NULL,"
        " checked_by=NULL, checked_at=NULL WHERE id=?", (text, cid))
    if row["ord"] == 0:
        # criterion 0 and the node's headline are the same sentence
        conn.execute("UPDATE nodes SET exit_criterion=? WHERE id=?",
                     (text, row["node"]))
    conn.execute(
        "INSERT INTO events (ts, actor, node, from_state, to_state, note, criterion)"
        " VALUES (?,?,?,?,?,?,?)",
        (now(), actor, row["node"], row["nstate"], row["nstate"],
         f'criterion rewritten. was: "{row["text"]}"', cid),
    )
    conn.commit()
    return {"ok": True, "criterion": cid, "was": row["text"]}


def add_node(conn, actor, payload):
    nid = payload["id"]
    if conn.execute("SELECT 1 FROM nodes WHERE id=?", (nid,)).fetchone():
        raise ValueError(f"node exists: {nid}")
    conn.execute(
        "INSERT INTO nodes (id,title,intent,exit_criterion,parent) VALUES (?,?,?,?,?)",
        (nid, payload["title"], payload.get("intent", ""),
         payload.get("exit_criterion", "to be defined in negotiation"),
         payload.get("parent")),
    )
    for b in payload.get("blocked_by", []):
        conn.execute("INSERT OR IGNORE INTO edges (blocker,blocked) VALUES (?,?)", (b, nid))
    for i, text in enumerate(payload.get("criteria") or
                             [payload.get("exit_criterion", "to be defined in negotiation")]):
        conn.execute("INSERT INTO criteria (node, ord, text) VALUES (?,?,?)", (nid, i, text))
    conn.execute(
        "INSERT INTO events (ts, actor, node, from_state, to_state, note) VALUES (?,?,?,?,?,?)",
        (now(), actor, nid, None, "idle",
         payload.get("note", "created on the canvas")),
    )
    conn.commit()


def blockers_of(conn, node, seen=None):
    # Every node that has to finish before this one can start, transitively.
    seen = seen if seen is not None else set()
    for r in conn.execute("SELECT blocker FROM edges WHERE blocked=?", (node,)):
        if r["blocker"] not in seen:
            seen.add(r["blocker"])
            blockers_of(conn, r["blocker"], seen)
    return seen


def add_edge(conn, actor, blocker, blocked):
    for x in (blocker, blocked):
        if not conn.execute("SELECT 1 FROM nodes WHERE id=? AND removed=0", (x,)).fetchone():
            raise ValueError(f"unknown node: {x}")
    if blocker == blocked:
        raise ValueError(f"{blocked} cannot block itself")
    if blocked in blockers_of(conn, blocker):
        # blocker already waits on blocked, directly or through others; adding
        # this edge would make a loop that nothing could ever finish
        raise ValueError(f"{blocker} already waits on {blocked}; that would be a loop")
    st = conn.execute("SELECT state FROM nodes WHERE id=?", (blocked,)).fetchone()["state"]
    conn.execute("INSERT OR IGNORE INTO edges (blocker,blocked) VALUES (?,?)", (blocker, blocked))
    conn.execute(
        "INSERT INTO events (ts, actor, node, from_state, to_state, note) VALUES (?,?,?,?,?,?)",
        (now(), actor, blocked, st, st, f"edge added: now blocked by {blocker}"),
    )
    conn.commit()


def remove_edge(conn, actor, blocker, blocked):
    hit = conn.execute("SELECT 1 FROM edges WHERE blocker=? AND blocked=?",
                       (blocker, blocked)).fetchone()
    if not hit:
        raise ValueError(f"{blocked} is not blocked by {blocker}")
    st = conn.execute("SELECT state FROM nodes WHERE id=?", (blocked,)).fetchone()["state"]
    conn.execute("DELETE FROM edges WHERE blocker=? AND blocked=?", (blocker, blocked))
    conn.execute(
        "INSERT INTO events (ts, actor, node, from_state, to_state, note) VALUES (?,?,?,?,?,?)",
        (now(), actor, blocked, st, st, f"edge removed: no longer blocked by {blocker}"),
    )
    conn.commit()


def remove_node(conn, node, actor, note="removed in negotiation"):
    # Removal is soft: the row stays, flagged, so the event log still makes
    # sense. Removing a goal removes its tasks with it, since a task with no
    # goal is not reachable from anywhere.
    row = conn.execute("SELECT state FROM nodes WHERE id=? AND removed=0", (node,)).fetchone()
    if not row:
        raise ValueError(f"unknown node: {node}")
    removed = [node]
    for kid in conn.execute("SELECT id FROM nodes WHERE parent=? AND removed=0",
                            (node,)).fetchall():
        removed += remove_node(conn, kid["id"], actor, f"removed with its goal {node}")
    conn.execute("UPDATE nodes SET removed=1 WHERE id=?", (node,))
    conn.execute(
        "INSERT INTO events (ts, actor, node, from_state, to_state, note) VALUES (?,?,?,?,?,?)",
        (now(), actor, node, row["state"], row["state"], note),
    )
    conn.commit()
    return removed


# Typing a goal in used to mean opening a Terminal. The store now runs the
# decomposer itself and keeps the in-flight sentences here so a page can say
# "thinking" instead of looking broken for the half minute the AI call takes.
THINKING = {}
RUNNER_BEAT = Path(__file__).parent / "runner.beat"


def start_decompose(sentence):
    import subprocess as sp
    import threading
    sentence = (sentence or "").strip()
    if not sentence:
        raise ValueError("a goal needs a sentence")
    key = str(int(datetime.now(timezone.utc).timestamp() * 1000))
    THINKING[key] = {"sentence": sentence, "state": "thinking", "error": None}

    def run():
        proc = sp.run(["python3", str(Path(__file__).parent / "decompose.py"), sentence],
                      capture_output=True, text=True, timeout=300)
        if proc.returncode == 0:
            THINKING[key]["state"] = "done"
        else:
            THINKING[key]["state"] = "failed"
            THINKING[key]["error"] = (proc.stderr or proc.stdout or "").strip()[-400:]

    threading.Thread(target=run, daemon=True).start()
    return {"ok": True, "id": key}


def runner_state():
    # The runner writes a timestamp next to the database every few seconds.
    # If that timestamp is recent, work is actually being picked up; if it is
    # not, nothing is running no matter what any page claims.
    if not RUNNER_BEAT.exists():
        return {"on": False, "note": "never started"}
    try:
        beat = json.loads(RUNNER_BEAT.read_text())
    except (ValueError, OSError):
        return {"on": False, "note": "unreadable"}
    age = datetime.now(timezone.utc).timestamp() - beat.get("at", 0)
    return {"on": age < 30, "seconds_ago": round(age),
            "note": beat.get("note", ""), "task": beat.get("task")}


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        body = json.dumps(obj, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _fail(self, exc):
        # One bad request must never take the store down with it.
        traceback.print_exc()
        try:
            self._send({"error": f"{type(exc).__name__}: {exc}"}, 500)
        except Exception:
            pass

    def do_GET(self):
        try:
            self._get()
        except Exception as e:
            self._fail(e)

    def do_POST(self):
        try:
            self._post()
        except Exception as e:
            self._fail(e)

    def _get(self):
        conn = db()
        if self.path.startswith("/output/"):
            import urllib.parse
            nid = urllib.parse.unquote(self.path[len("/output/"):])
            f = Path(__file__).parent / "outputs" / (nid.replace("/", "__") + ".md")
            if f.exists():
                self._send({"node": nid, "output": f.read_text()})
            else:
                self._send({"error": "no output yet"}, 404)
            return
        if self.path.startswith("/criteria"):
            import urllib.parse
            q = urllib.parse.urlparse(self.path)
            node = urllib.parse.parse_qs(q.query).get("node", [None])[0]
            if q.path.startswith("/criteria/"):
                node = urllib.parse.unquote(q.path[len("/criteria/"):])
            self._send(criteria_for(conn, node))
            return
        if self.path == "/status":
            self._send({"runner": runner_state(),
                        "thinking": [t for t in THINKING.values()
                                     if t["state"] == "thinking"],
                        "failed": [t for t in THINKING.values()
                                   if t["state"] == "failed"]})
            return
        if self.path == "/tree":
            self._send(tree(conn))
        elif self.path == "/log":
            self._send([dict(r) for r in conn.execute("SELECT * FROM events ORDER BY seq")])
        elif self.path == "/frontier":
            self._send(frontier(conn))
        elif self.path == "/critical-path":
            self._send(critical_path(conn))
        else:
            self._send({"error": "unknown path"}, 404)

    def _post(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length))
            actor = payload.get("actor", "unknown")
            if self.path == "/event":
                append_event(db(), payload["node"], payload["to"], actor,
                             payload.get("note"))
            elif self.path == "/node/update":
                update_node(db(), payload["node"], actor, payload.get("fields", {}))
            elif self.path == "/node/remove":
                remove_node(db(), payload["node"], actor)
            elif self.path == "/node/add":
                add_node(db(), actor, payload)
            elif self.path == "/edge/add":
                add_edge(db(), actor, payload["blocker"], payload["blocked"])
            elif self.path == "/criterion/add":
                cid = add_criterion(db(), payload["node"], payload["text"], actor)
                return self._send({"ok": True, "criterion": cid})
            elif self.path == "/criterion/set":
                return self._send(set_criterion(db(), int(payload["criterion"]),
                                                payload["to"], actor,
                                                payload.get("evidence")))
            elif self.path == "/run":
                import subprocess as sp
                sp.Popen(["python3", str(Path(__file__).parent / "worker_ai.py"),
                          "--task", payload["node"]],
                         stdout=sp.DEVNULL, stderr=sp.DEVNULL)
            elif self.path == "/goal/new":
                return self._send(start_decompose(payload.get("sentence", "")))
            else:
                return self._send({"error": "unknown path"}, 404)
            self._send({"ok": True})
        except (ValueError, KeyError, json.JSONDecodeError) as e:
            self._send({"error": str(e)}, 400)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "seed":
        seed()
    elif cmd == "serve":
        # Serving no longer loads the example plan. A new database starts
        # empty; `seed` loads the example on purpose.
        port = int(sys.argv[2]) if len(sys.argv) > 2 else 8040
        db()
        print(f"substrate store serving on http://localhost:{port}  (db: {DB_PATH})")
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
    else:
        sys.exit("usage: substrate_store.py [serve [port] | seed]")

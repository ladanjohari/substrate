# The Substrate — data model

The whole backend is **four tables in one SQLite file** (`store/substrate.db`),
fronted by a small service (`store/substrate_store.py`). No cloud, no framework.
This document is the backend in plain language.

---

## 1. `nodes` — every goal and task

One shape for both. A goal is just a node with no parent; a task is a node whose
`parent` points at its goal. A question to a human is a node whose exit criterion
names a person.

| column           | meaning                                                        |
|------------------|----------------------------------------------------------------|
| `id`             | unique name, e.g. `about-section/lock-bio`                     |
| `title`          | short human label                                              |
| `intent`         | what this is *for*, in plain words                            |
| `exit_criterion` | the one testable sentence that decides "done"                 |
| `state`          | `idle` / `working` / `waiting` / `error` / `done`             |
| `owner`          | which agent or person currently holds it (can be empty)       |
| `parent`         | the goal this task belongs to (empty = this node *is* a goal) |
| `runbook`        | optional shell command a worker can run (usually empty)       |
| `removed`        | 1 if cut during negotiation (kept for history, never deleted) |

A real row, live from the store:

```
id:             about-section/lock-bio
title:          Lock the short bio text
intent:         The bio must read as Ladan's own voice...
exit_criterion: Ladan approves the final bio wording.
state:          waiting
parent:         about-section
```

---

## 2. `edges` — which task blocks which

This is what makes the plan a DAG (branches that fork and merge) instead of a
flat list. Two columns only.

| column    | meaning                                  |
|-----------|------------------------------------------|
| `blocker` | the task that must finish first          |
| `blocked` | the task that waits on it                |

Example: `about-section/lock-bio` **blocks** `about-section/build-section`.
Tasks with no shared edge run in parallel. Merge points simply have several
blockers.

---

## 3. `events` — the append-only history

Nothing in `nodes` is ever edited in place without also writing a line here.
Every state change is a new, permanent row. The tree you look at is just the
latest state of every node; this log is the truth, and it can be replayed.

| column       | meaning                                        |
|--------------|------------------------------------------------|
| `seq`        | order it happened (auto-counts up)            |
| `ts`         | timestamp                                      |
| `actor`      | who did it — a person or an agent name        |
| `node`       | which node changed                             |
| `from_state` / `to_state` | the transition                    |
| `note`       | evidence, in plain words                       |

A real row:

```
ts:    2026-07-17T05:18:43   actor: ladan
node:  demo-video   waiting -> working
note:  negotiated and approved on the sculpt surface
```

---

## 4. `criteria` — what has to be true, checked one at a time

`nodes.exit_criterion` is the headline sentence. This table is the real thing:
a task's exit split into the separate conditions that can be checked and
evidenced **individually**, so partial progress is visible instead of hidden
inside one all-or-nothing sentence.

| column       | meaning                                                     |
|--------------|-------------------------------------------------------------|
| `id`         | the number you refer to it by (`substrate meet 17 …`)       |
| `node`       | which task it belongs to                                     |
| `ord`        | order within the task (0 is the headline)                   |
| `text`       | one fact a stranger could confirm by looking                |
| `state`      | `unmet` / `met` / `failed`                                   |
| `evidence`   | the specific thing that shows it — a path, output, a person |
| `checked_by` | who or what checked it                                       |
| `checked_at` | when                                                         |

Two rules are enforced in the store, not by convention:

> A node **cannot reach `done`** while any of its criteria is unmet.
> A criterion **cannot be met without evidence**.

That pair is what makes "done" testable rather than asserted, and it is the
difference between this and a task list. An agent that wants to close something
has to say what would show it is true, and that sentence lands in the log.

Every criterion change writes an `events` row too (with `events.criterion` set),
so the history of a task includes each check, its evidence, and who did it.

---

## The one real piece of logic: the frontier

Everything else is storing and showing. This single rule decides what is
*allowed to run right now*, and priorities/parallelism/gating all fall out of it:

> A task can start only if — it is `idle`, none of its blockers are unfinished,
> and its goal has been approved (its goal is not still `waiting`).

That last clause is why approval matters: an un-negotiated plan can never reach
the frontier, so nothing runs that you haven't agreed to.

---

## The second piece of logic: the critical path

The frontier says what *can* run. The critical path says what is *actually
holding the goal* — the longest chain of dependent, unfinished work between here
and done. Weight is counted in **open criteria, not tasks**, so a task with four
unchecked conditions weighs more than one with a single box left.

It answers the question a plan is for: of everything runnable, which one thing
should be picked up first, because everything else is waiting behind it. When
the head of the chain is a question for a person, it says so instead of naming a
next step that nobody can take.

`substrate path`, or `GET /critical-path`.

---

## The service — fourteen doors

The pages, the CLI, and the AI workers all talk to the database through the same
service.

**Read:** `/tree` (all nodes + edges + criteria) · `/log` (the history) ·
`/frontier` (what can run now) · `/critical-path` (what is holding each goal) ·
`/criteria/<node>` · `/output/<id>` (a worker's deliverable)

**Write:** `/event` (change a state) · `/node/add` · `/node/update` ·
`/node/remove` · `/edge/add` · `/criterion/add` · `/criterion/set` ·
`/run` (start an AI worker on a task)

To see the raw data with no UI, with the servers running, open in a browser:
`http://localhost:8040/tree`

---

## The substrate without a browser

`./bin/substrate` is the same model as a command line, straight against the file,
so it works with or without the service running:

```
substrate path                        what is holding each goal
substrate frontier                    what is allowed to start now
substrate show <node>                 one task in full, criteria and evidence
substrate meet <criterion> -e "..."   record a check, with evidence
substrate state <node> done -n "..."  close it (refused if criteria are open)
```

Add `--json` to any command for an agent to read. Set `SUBSTRATE_ACTOR` so the
log records which session did what.

---

## The files that *are* the backend

- `store/substrate_store.py` — the schema (top) and the service. The `frontier`
  and `critical_path` functions are the brain.
- `store/substrate_cli.py` — the same model from a terminal.
- `store/worker_ai.py` — how an agent claims a task, does it, and reports back.
  Its checker is a **separate call from its doer**: the deliverable is judged
  against each criterion by something that did not write it, and anything it
  cannot evidence stays unmet and goes to a human.
- `skills/substrate/SKILL.md` — how a Claude session attaches to all of this.
- `store/substrate.db` — the actual data (your goals and their full history).
  `store/substrate.db.bak-precriteria` is the snapshot taken before criteria
  became first-class, in case the migration ever needs re-running.

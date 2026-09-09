---
name: substrate
description: Work against the substrate, the durable record of a goal, its tasks, and their exit criteria. Use at the start of any session that continues multi-week work, to find what is runnable, to record what you did as evidence against a criterion, and to leave the next session a true picture instead of a transcript.
---

A session is short. The work is not. This skill attaches a session to the
**substrate**: the record of what the goal is, which tasks it broke into, what
each task's exit criteria are, and which of those criteria are met, by whom,
with what evidence.

You do not hold the plan in context. You read it, take one thing, and write back
what is now true.

## The one rule

**A node is done when its criteria are met, not when you say so.** Every
criterion is a single fact a stranger could confirm by looking. Meeting one
requires evidence: the file, the command output, the URL, the person who
approved. The store refuses `done` while any criterion is open, and refuses to
meet a criterion with no evidence. Do not work around this. It is the product.

## Commands

Run from the substrate repo. `./bin/substrate` (add `--json` for parsing).

| Command | What it answers |
|---|---|
| `substrate tree [goal]` | What is the plan, and how far along is each task |
| `substrate frontier` | What am I allowed to start right now |
| `substrate path` | Which chain of open criteria is actually holding this goal |
| `substrate show <node>` | What is this task for, what blocks it, what must be true to close it |
| `substrate criteria <node>` | Its criteria, their state, the evidence recorded |
| `substrate meet <id> -e "..."` | Record a criterion as met, with evidence |
| `substrate fail <id> -e "..."` | Record a criterion as failed, with what went wrong |
| `substrate add-criterion <node> "..."` | Add a condition that was missing |
| `substrate state <node> <state> -n "..."` | Move a node: idle, working, waiting, error, done |
| `substrate log [n]` | What has happened, most recent last |

A proposed plan has exactly three answers, and only a person gives them:

| Command | What it does |
|---|---|
| `substrate approve <goal>` | Releases the plan. Nothing runs before this |
| `substrate changes <goal> "..."` | Asks for the plan to be thought again, with your note |
| `substrate reject <goal> -w "..."` | Throws the plan away. The log keeps it |

Set `SUBSTRATE_ACTOR` so the log records who you are, e.g. `claude-session-3`.

## Session shape

1. **Orient, don't reconstruct.** `substrate path` first. It tells you the
   longest chain of unfinished criteria and the first link you can pick up. Do
   not re-derive the plan from the conversation or from files.
2. **Take one thing.** From the frontier, or the `next` the critical path names.
   `substrate state <node> working -n "claimed by <you>"`. The claim is visible
   to every other session, so nobody duplicates you.
3. **Do the work.** Normal work, normal tools.
4. **Report against criteria, one at a time.** For each criterion you can
   evidence: `substrate meet <id> -e "<the specific thing that shows it>"`.
   Evidence is a fact, not a summary. `"tests/auth_test.py::test_expiry passes,
   14/14 green"` is evidence. `"implemented and working"` is not.
5. **Leave partial work honest.** If you cannot evidence a criterion, leave it
   unmet and put the node in `waiting` with a note saying what a human has to
   check or decide. A half-finished task that reads as half-finished is worth
   more than one that reads as done.
6. **Add what was missing.** If doing the work revealed a condition nobody wrote
   down, `add-criterion` it rather than quietly widening an existing one.

## What not to do

- **Never mark a criterion met on your own promise.** If the evidence would be
  "I wrote the code", the criterion is unmet until something ran.
- **Never mark a human's decision met.** Criteria naming a person ("the owner
  approves…") are for that person. Put the node in `waiting` and stop.
- **Never rewrite history.** The event log is append-only. Wrong state? Add the
  correcting event, with a note. The trail of a mistake is data.
- **Never hold the plan only in your context.** If a decision changes the plan,
  write it to the substrate in the same turn. A session that ends with the truth
  only in the transcript has lost it.

## Where it lives

- `store/substrate.db`, the record: nodes, edges, criteria, events
- `store/substrate_store.py`, the service on port 8040 and the frontier rule
- `store/substrate_cli.py`, these commands
- `DATA-MODEL.md`, the whole model in plain language

## Related but different

`/wayfinder` (mattpocock/skills) maps the *decisions* ahead of a foggy effort
and stops when the route is clear. Substrate holds the *state* of the work while
it happens, with testable criteria, and is still there after the route is clear.
Charting the route and tracking the run are different jobs; the two can sit on
the same goal.

# Substrate

**The system of record for delegated work.**

A durable, shared record of the goals AI agents are working on. A goal breaks
into tasks. Each task carries exit criteria, checked one at a time with
evidence, so "done" is testable rather than asserted. Agents update the record
as a side effect of doing the work. Humans read that state at whatever altitude
they need: one status dot, the full task tree, or the single question that
needs a person.

This repo is the data store, the command line in front of it, the Claude skill
that lets an agent work against it, and the browser pages that show it live.
The menu bar app that sits on top is described in [PROPOSAL.md](PROPOSAL.md).

## Install

Python 3.10 or newer. No packages to install.

```
git clone <this repo> substrate
cd substrate
./bin/substrate tree
```

The first run creates an empty database at `store/substrate.db`. To keep more
than one, point `SUBSTRATE_DB` at another file.

## The seven commands

| You want to | Run |
|---|---|
| Create a goal, or a task inside it, with exit criteria | `substrate add <id> "Title" -c "criterion" [-c "..."] [--after other-task]` |
| Change the state of an exit criterion, with evidence | `substrate meet <criterion-id> -e "what shows it"` or `substrate fail <criterion-id> -e "..."` |
| Change a task's description | `substrate edit <task> -t "new title" -i "new intent"` |
| Block one task on another | `substrate block <task> --after <other-task>` (undo: `unblock --from`) |
| Delete a task | `substrate remove <task>` (removing a goal removes its tasks) |
| Recalculate the critical path | `substrate path` |
| Show the state of the tree | `substrate tree` |

A goal's id is a short slug. A task's id is `goal/slug`. Inside a goal you can
use the short name anywhere a task is expected. Add `--json` before any command
for machine-readable output.

Also there: `frontier` (what may start right now), `show`, `criteria`,
`add-criterion`, `state`, `log`. Run `./bin/substrate -h` for the full list.

## Sixty seconds, end to end

```
./bin/substrate add ship-cli "Ship the CLI" -c "A stranger runs all seven commands from the README"
./bin/substrate add ship-cli/repo "Public repo" -c "Repo is public" -c "README covers install"
./bin/substrate add ship-cli/test "Test as a stranger" -c "Fresh clone, README only, all pass" --after repo
./bin/substrate tree
./bin/substrate path                       # start with: ship-cli/repo
./bin/substrate criteria repo              # ☐ #2 Repo is public   ☐ #3 README covers install
./bin/substrate meet 2 -e "https://github.com/..."
./bin/substrate meet 3 -e "README.md, install section"
./bin/substrate state repo done            # allowed now: every criterion met
./bin/substrate frontier                   # test is runnable, its blocker is done
./bin/substrate log
```

Two rules are enforced by the store, not by convention:

- A task cannot reach `done` while any of its criteria is open.
- A criterion cannot be marked met without evidence.

Try `substrate state repo done` before meeting its criteria and the store
refuses. That refusal is the product.

## The Claude skill

`skills/substrate/SKILL.md` teaches a Claude Code session to attach to the
substrate: read the plan, take one runnable thing, and write back what is now
true as evidence against a criterion instead of leaving a transcript. Copy the
folder into `~/.claude/skills/` or point a project's skills at it.

## The pages

Four browser pages read the same database live: the canvas (the main view), the
live tree (watch only), negotiate (reshape and approve a proposed tree), and
gates (answer the questions agents are waiting on). Double-click
`Open Substrate.command` to start the store, the page server and the runner
together, or read [HOW-TO-OPEN.md](HOW-TO-OPEN.md).

The decomposer (`store/decompose.py`) turns one sentence into a proposed tree
with criteria, and the worker (`store/worker_ai.py`) executes a task and then
checks its own result against each criterion with a separate call. Both use the
`claude` command line and are optional; the store and the CLI work without them.

## Layout

```
bin/substrate           the command
store/substrate_store.py   the database, its rules, and a small HTTP service
store/substrate_cli.py     the commands
store/decompose.py         goal in, proposed tree out
store/runner.py, worker.py, worker_ai.py   agents that take tasks and report back
skills/substrate/       the Claude skill
prototypes/             the four pages
DATA-MODEL.md           what a goal, task, criterion and event are as data
MIGRATIONS.md           how the database has changed, and how to move an old one
BRIEF.md                the longer description: problem, pitch, positioning
PROPOSAL.md             the menu bar app on top of this, milestones and dates
```

## Status

The store, CLI, skill, decomposer, worker and pages run today. The menu bar app
is next. Details and dates in [PROPOSAL.md](PROPOSAL.md).

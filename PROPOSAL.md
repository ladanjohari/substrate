# Substrate: project proposal

*Clean version, 1 September 2026. Replaces the draft outline in the shared doc.*

## What it is

A macOS menu bar app for supervising a swarm of AI agents working toward one goal.

A person states a goal and what "done" means for it. The goal breaks into a tree
of tasks. Every task carries its own exit criteria. Agents pick tasks from the
tree, work in parallel, and write their progress back into one shared record.
The menu bar shows at a glance which agents and subagents are working, which are
waiting, and which need a person. When an agent reaches a decision it is not
allowed to make, the app asks the human for approval and the agent waits. A task
is done when its criteria are met with evidence, not when someone says so.

Three layers:

| Layer | What it holds | Status |
|---|---|---|
| Substrate (data store + CLI) | goals, tasks, exit criteria, blocking edges, the event log | built, needs polish and a public repo |
| Agents | a decomposer that turns a goal into a tree, workers that take tasks, a checker that marks criteria met with evidence | built as prototypes |
| Menu bar app | the live tree, which agent is on which task, approval requests | to build |

## Milestones

| Piece | Exit criteria (all must be true) | Date |
|---|---|---|
| 1. Substrate CLI and data store | Public GitHub repo with a README. A stranger can install it and run all seven commands: create a task with exit criteria, change a criterion's state, edit a description, block one task on another, delete a task, recalculate the critical path, show the tree. | Wed 2 Sep |
| 1A. Claude skill | The skill file ships in the same repo and is documented in the README. | Wed 2 Sep |
| 2. End-to-end interaction model | A clickable mockup with mock data that walks the whole loop: state a goal, see the tree, watch agents work, get asked for approval, approve, see it finish. Not wired to the substrate. | Fri 4 Sep |
| 3. Menu bar app with task tree | The app runs on a Mac, reads the live tree from the substrate, shows which agent is on which task, and completes one real goal end to end with at least one approval. | Fri 11 Sep |
| 3A. Approval dialogs | One question at a time. Approve, ask for changes, or reject. The answer is written to the store and the agent continues. | Fri 11 Sep |
| 4. App Store | Submitted for review. Needs signing and a developer account. | After 11 Sep, not in this window |

## The seven CLI commands (piece 1)

| Command | Does | Exists today |
|---|---|---|
| `substrate add` | create a task with exit criteria | store function only, command to add |
| `substrate meet` / `fail` | change the state of an exit criterion, with evidence | yes |
| `substrate edit` | change a task's description | store function only, command to add |
| `substrate block` | block one task on another | store function only, command to add |
| `substrate remove` | delete a task | store function only, command to add |
| `substrate path` | recalculate the critical path | yes |
| `substrate tree` | show the state of the tree | yes |

## Non-goals for this window

- No iPhone companion.
- No multi-user or cloud sync. One Mac, one store.
- No new agent framework. The existing runner and workers are enough for one real goal.
- No App Store submission before the app completes a real goal.

## Open decision, to settle on 4 September with the mockups

The draft says "React-based". A menu bar app needs a shell; React cannot sit in
the menu bar on its own. Two ways to get there:

| Option | Shell | Pages | Reuses | Cost |
|---|---|---|---|---|
| A. Native shell | SwiftUI menu bar, already built for Session Indicator | the existing substrate HTML pages inside a web view, React components where useful | shell, pages, store API, App Store path | glue only |
| B. Electron or Tauri | new | React | pages, store API | new shell, harder App Store path |

Recommendation: A. Every piece already exists; only the glue is new.

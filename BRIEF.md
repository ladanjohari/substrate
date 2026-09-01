# Substrate — the brief

*The canonical description of the project, written July 30, 2026. The CLI has grown since; the current command list is in the README and PROPOSAL.md.*

---

## In one line

**The system of record for delegated work.** (46 characters, for any form that
asks.)

Substrate is a durable, shared record of the goals AI agents are working on. A
goal breaks into tasks. Each task carries exit criteria, checked one at a time
with evidence, so "done" is testable rather than asserted. Long-running agents
update the record as a side effect of doing the work, so the state is always
true instead of hand-maintained and stale. Humans read that state at whatever
altitude they need: one status dot, the full task tree, or the single question
that needs a person.

Git gave code durable, inspectable, shared state. Nothing has done that for
delegated work.

---

## The problem

Agents can execute for hours, in parallel, but the plan has nowhere to live.
Goal state is smeared across chat transcripts, task lists, and human memory.
Every session starts amnesiac. Every handoff, human to agent, agent to agent,
yesterday to today, loses the intent. The unit of work has moved from the
message to the goal, and there is no system of record for goals.

**Framing note, learned the hard way:** tell this as a *coordination and handoff*
problem, not as "I kept hitting my context window." The personal-context version
invites the obvious counter, that bigger context windows will solve it. They will
not: context is memory for one agent in one run. A bigger window does not give a
human a legible view of six parallel agents, does not survive a crashed run, does
not let a teammate pick up where an agent stopped, and does not give anyone a
testable "done." Bigger windows make agents more capable, which makes the
coordination problem worse, not smaller.

---

## What it is, in four layers

1. **The workers.** Long-running agents. Loop: execute, hit a decision they are
   not allowed to make, post the question, wait.
2. **The shared state, the substrate itself.** One source of truth: what each
   agent is doing, what questions are pending, what is done. Tasks carry exit
   criteria so done is checkable. The plan is updated **by** the workers as a
   side effect of execution.
3. **The display layers.** Logic-free windows onto the state, at altitudes: dot
   (Session Indicator), tree (the plan), question (the gate). Legibility
   grammar: motion means working, amber means a human is needed, green means
   done. Attention is singular.
4. **The observer.** Append-only log of every transition, check, and answer. A
   periodic analysis agent writes human-readable digests.

Full data model: `DATA-MODEL.md`. Architecture: `ARCHITECTURE.html`.

---

## The pitch

### Written, 30 seconds

Agents got hands. Work still has no memory. Substrate is the system of record
for delegated work: a goal breaks into tasks with testable exit criteria, the
agents update the state as they work so it is always true, and a person can read
it at a glance, as a tree, or as the one question that needs them. Git for goals.

### Spoken, 60 seconds

> I'm a design engineer, and I build Substrate.
>
> Here's the problem I kept hitting. AI agents can run for hours now, in
> parallel, but the plan they're working on has nowhere to live. The goal is
> smeared across chat transcripts and stale task lists, and every handoff loses
> the intent. There's no system of record for delegated work.
>
> Substrate is that record. A goal breaks into tasks with testable exit
> criteria. The agents update the state as they work, so it's always true, not
> hand-maintained. And a person can read it at a glance, as a tree, or as the
> one question that needs them. It's Git for goals.
>
> I've built it, it's running, and I use it every day on my own work. I live
> this problem, I ship, and I designed the part that makes agent work legible to
> a person.

Delivery: look at the lens, slow down about 20% from instinct, five or six
takes, keep the one that sounds like you rather than the perfect one.

### The lines that carry the most

- "Agents got hands. Work still has no memory."
- "Git for goals."
- "Done is testable, not asserted."
- "The state is true because the work updates it, not because someone
  remembered to."

---

## Who it is for

1. **Developers running parallel agent sessions.** The wedge. The author is user
   zero: resume any session against the same goal tree.
2. **Small mixed human and agent teams.** The shared tree is the coordination
   surface.
3. **Anyone with a multi-week life goal** (visa, renovation, job search). This
   is a research and awareness audience, not the first revenue. Say so plainly
   rather than listing three audiences as if all three are the plan.

Money, when there is money: seat and usage based, sold like developer
infrastructure. Every team running agents will need a record of that work, the
same way every team running code needs version control.

First users, bottom-up: a developer running parallel sessions points Substrate
at their work and sees the tree in five minutes with no new infrastructure. That
claim has to actually be true and demoable, or it is marketing.

---

## Positioning

| They | Their state | The gap |
|---|---|---|
| Memory tools (mem0, Letta) | recall for one agent | not a shared, human-legible goal record |
| Agent frameworks (LangGraph, CrewAI) | internal, developer-only, dies with the run | not durable or cross-session |
| Coding agents (Devin, Cognition) | single-agent execution | not the neutral record above them |
| Task managers (Linear, Jira, Asana) | hand-updated, therefore stale | not updated by the work itself |
| Mission-control dashboards | organized around sessions | not organized around goals |
| Plan mode / task lists in coding agents | per-session, amnesiac | this is the memory they lack |

**The one sentence:** everyone else either stores memory for one agent or shows
you sessions. Substrate is the durable, legible record organized around the
goal, updated by the work itself, with exit criteria that make done trustable.

"Organized around goals not sessions" is a real distinction but a subtle one, and
in a fast read it can sound like a reframed dashboard. The demo has to make the
difference obvious in ten seconds, and **the exit-criteria mechanic is the
sharpest, most concrete wedge.** Lead with it.

---

## The hard questions, and the honest answers

*Harvested from the pressure-test. These are the attacks any serious reader will
make, with where the answer is still thin. Read before any pitch or interview.*

**"Won't the big labs just build this?"** They are optimizing single-session,
single-agent execution inside their own products. Substrate is deliberately
cross-session, cross-agent and cross-vendor: the record that sits above any one
model or tool, the way Git sits above any one editor. The labs are structurally
disinclined to build the neutral layer, because it commoditizes their
orchestration. The wedge is observe-don't-instrument: Substrate attaches by
reading transcripts and outputs, so no lab has to cooperate.
*Still thin:* platform risk is real and the schema is copyable. The defensibility
is the neutral multi-vendor position plus accumulated data, not the schema.

**"Is this a company or an art project?"** The exhibition is the showcase and the
first public user study, not the product. Underneath it is running software.
The art is a distribution and validation channel most infrastructure builders do
not have, not a substitute for the product.
*Still thin:* lead with the software and the developer wedge every time, or the
whole thing gets filed under "artist."

**"Who pays?"** Developers running parallel sessions, then small mixed teams
where the shared tree is the coordination surface. Seat or usage based.
*Still thin:* zero paying users today. One crisp sentence on who the first ten
paying teams are, and one real user who is not the author, closes this.

**"Why you, and why solo?"** She is user zero and lives the problem daily. She
built the working prototype and, more to the point, the interaction grammar that
makes agent state legible to a person, which is the genuinely hard,
non-commodity part a backend engineer would not have built. A technical advisor
reviews the code. Open to the right co-founder, not blocked meanwhile.
*Still thin:* solo is a headwind. The mitigation is a specific, magnitude-driven
"most impressive thing," naming the advisor honestly rather than dressing him up,
and pointing at software that already runs.

**"Why now?"** Long-running parallel agents only became real in the last year.
The moment agents can execute for hours unattended, the missing piece becomes
the durable place the plan lives and a human's ability to supervise many at once.
*This is the strongest answer. Do not overthink it.*

---

## How this differs from `/wayfinder`

*Added July 30, 2026, the day Matt Pocock's `/wayfinder` skill went wide
(mattpocock/skills v1.1). It is the closest public thing to this project, it
arrived from a well-known educator with a large audience, and it uses the same
word for the same concept: the **frontier**. Written down here so the difference
is never re-derived under pressure.*

**What wayfinder is.** A Claude skill. You give it an effort too big for one
agent session and too foggy to spec. It creates one `wayfinder:map` issue on
GitHub or Linear, with child **decision tickets** underneath: questions whose
resolution is a decision, not a slice of a build. Tickets are typed research,
prototype, grilling or task, and are either HITL (needs the human) or AFK (agent
alone). A session claims one ticket, resolves it, records the answer as a
comment, closes it, and appends a line to "Decisions so far." Unspecifiable work
sits in "Not yet specified," the fog of war, and graduates into tickets as the
frontier advances. Explicitly: *"produce decisions, not deliverables."*

**Where it genuinely overlaps.** Same starting pain: a goal larger than one
session, context lost at every restart. Same shape: one root, children beneath
it, a frontier of open unblocked actionable items. Same human/agent split.
Same instinct that the record has to live outside the session. This convergence
is real and should be conceded openly, not argued with.

**Where it is a different thing.**

| | wayfinder | Substrate |
|---|---|---|
| **Produces** | decisions | state of work |
| **Lifespan** | ends when the route is clear, then hands off to spec/tickets/implement | starts there and lasts until the goal closes |
| **Unit** | a question you can state precisely now | a task with exit criteria, each individually checkable |
| **"Done"** | a human reads a resolution comment | criteria met with evidence, enforced by the store |
| **Storage** | GitHub or Linear issues, prose for people | own schema and append-only log, machine state agents read and write |
| **Concurrency** | one ticket per session, by rule | parallel long-running agents updating one tree |
| **Human** | reads the map | reads a dot, a tree, or one amber question |
| **Representation** | none, it is markdown plus a tracker UI | the whole point: legibility grammar, live tree, indicator |

**The honest read.** This is validation with a cost.

*Validation:* a well-known educator shipping this, and thousands of developers
adopting it in a week, is proof that the problem is felt widely and that people
will accept real structure to fix it. Nobody has to be convinced the pain
exists any more.

*The cost:* "break a big goal into a tree of smaller items with a frontier" is
now free, famous, and installable in one command. It can no longer be the
headline. If the pitch opens with decomposition, it reads as commodity. Open
instead with the system-of-record framing and the exit-criteria mechanic.

*The strategic note:* the engineer review of July 19 listed "a Claude skill" as
one of the five pieces of this project. Wayfinder just filled that slot
publicly, which is the proof that a skill wrapper is not the moat. The store,
the per-criterion state, and the representation layer are.

*Not competitors, different jobs.* Charting a foggy route and tracking a running
one are separate problems. The two can sit on the same goal: wayfinder decides
what to build, Substrate holds what is happening while it gets built. If
anything, wayfinder's map is finished exactly where Substrate's tree gets
interesting. That is a compatible story, and a more credible one than claiming
he built the same thing.

---

## State of the build, July 30, 2026

Running software, not a mockup.

- **Store** — SQLite plus a small always-on service on port 8040. Nodes, edges,
  criteria, append-only events.
- **Criteria as first-class state** *(new, July 30)* — a task's exit split into
  separately checkable conditions, each with its own state and evidence. A node
  cannot reach done while any criterion is open; a criterion cannot be met
  without evidence. Both enforced in the store, not by convention.
- **Critical path** *(new, July 30)* — the longest remaining chain of open
  criteria per goal, weighted in criteria rather than tasks, naming the one
  thing to pick up first, or saying plainly when the head of the chain is
  waiting on a person.
- **CLI** *(new, July 30)* — `./bin/substrate`: tree, frontier, path, show,
  criteria, meet, fail, state, log. `--json` for agents. Works without the
  service running.
- **Claude skill** *(new, July 30)* — `skills/substrate/SKILL.md`: how a session
  attaches to the substrate, takes one thing, and reports back as evidence
  rather than as a claim.
- **Decomposer** — one sentence in, proposed tree with per-task criteria out,
  arriving in `waiting` so nothing runs unapproved.
- **Worker** — claims a frontier task, executes it, and now judges the result
  against each criterion with a **separate checker call**, marking only what it
  can evidence and sending the rest to a human.
- **Live tree, negotiation surface, gate inbox** — built.
- **Representation study** — five hi-fi versions of the same snapshot (tree
  canvas, Miller columns, timeline, outline, true Miller columns), published as
  artifacts with a moderator script, ready for a focus group.

Dogfooded on real multi-week goals: this portfolio's About section, the demo
video, v0.2, and demand validation all live in the store.

---

## What is open

1. **Show criteria in the tree.** The state exists in the model but the displays
   still render one status per task. This is a design decision, not a build one:
   how does a task that is three-quarters checked look at each altitude?
2. **Get one developer who is not the author to run it.** Closes the traction gap and
   the "is the five-minute claim true" gap at once.
3. **Sharpen the "most impressive thing" line.** It carries the whole personal
   case in any application or intro.
4. **Run the representation study** with the five published versions.
5. **A written positioning piece** on the difference between planning and state,
   using wayfinder as the foil rather than the enemy. This is a good moment for
   it: the audience is already assembled.


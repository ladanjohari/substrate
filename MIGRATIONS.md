# Changes to the database, and how to undo them

*Every change to the shape of `store/substrate.db` gets written down here, with
the exact way back. Newest first.*

---

## July 30, 2026 — criteria became their own thing

**What changed, in plain words.** Before, every task carried one sentence saying
what "done" meant, stored on the task itself. Now that sentence is one row in a
new list, and a task can have several, each with its own tick box, its own
evidence, and a record of who ticked it.

**What was added**

| Change | Detail |
|---|---|
| New table `criteria` | one row per condition: which task, the text, `unmet`/`met`/`failed`, the evidence, who checked it, when |
| New column `events.criterion` | so the history says which condition a line refers to |
| Backfill | every existing task got one criterion, carrying over its old sentence. Tasks already `done` had theirs recorded as met, noted as "carried over" |

**What was NOT changed.** Nothing was deleted, renamed, or overwritten. Every
existing table, column and row is exactly as it was, including
`nodes.exit_criterion`, which still holds the headline sentence. 44 tasks, 56
history rows, all intact. The change is purely additive, which is why the old
pages still run against it untouched.

**New behaviour that comes with it.** A task cannot be marked done while any of
its conditions is open, and a condition cannot be ticked without evidence. This
is the point of the change, but it does mean anything that used to close a task
in one step now has to tick the conditions first.

### The way back

There are two independent copies of the database as it was before this change:

1. **A file next to it:** `store/substrate.db.bak-precriteria`, taken before
   anything was touched.
2. **Git history:** the database is tracked, so the version from the July 21
   commit is always recoverable.

To undo completely, undo the code and the data together. Undoing only the data
does not work: the code re-applies the change the next time anything reads the
database.

```bash
cd substrate
git revert 61fd895                              # put the code back
cp store/substrate.db.bak-precriteria store/substrate.db   # put the data back
```

To undo only the data and keep the new code (rarely what you want, it will
simply be re-migrated):

```bash
cp store/substrate.db.bak-precriteria store/substrate.db
```

To look at the old data without touching the live one:

```bash
git show 0a36143:store/substrate.db > /tmp/old-substrate.db   # any older commit
```

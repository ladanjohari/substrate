# The window's layouts

The window draws the whole plan. How it draws it is a swappable part, chosen
in the picker at the top left and remembered between launches.

This file exists so that trying a different layout later, or putting two in
front of someone to choose between, does not need anybody explained to.

## What is decided, and why

| Decision | Why | Date |
|---|---|---|
| Miller columns is the default | It was asked for, and it is one of only two options that handle any depth | 8 Sep 2026 |
| The layout is a swappable part, not the shape of the window | So a different one can be tried, or two compared, without rebuilding anything around it | 8 Sep 2026 |
| Outline is built as well | One layout behind a picker proves nothing. Two that share the same model prove the seam holds | 8 Sep 2026 |

Four layouts were drawn up and costed before any were built. Two are built:

| | Gives | Takes | Built |
|---|---|---|---|
| A. Task tree | The shape of the plan, where the work forks | No room for detail, and every state change moves the layout under the cursor | No |
| B. Three panes | Detail has a permanent home on the right | The count is fixed, a subtask three levels down has nowhere to appear | No |
| D. Outline and inspector | Any depth, every branch at once, detail that stays put | Indentation eats width, a long plan becomes a scroll with no shape | **Yes** |
| E. Miller columns | Any depth, and the path you took stays visible | Every branch except the one you are in | **Yes, default** |

## What every layout gets for free

A layout only draws. It never fetches, decides state, or decides what a task
is. All of that is shared, which is why they cannot drift apart.

| Piece | File | What it is |
|---|---|---|
| `TreeModel` | `TreeModel.swift` | Polls the store, holds the tree, holds where you are |
| `NodeRow` | `Layouts.swift` | One row: state dot, name, checks, what it waits on |
| `DetailPane` | `Layouts.swift` | One task in full: why, waits for, every check and its evidence |
| `Dot` | `PillView.swift` | The state vocabulary, same as the menu bar |

Two things follow from this. Selection is shared, so switching layout keeps
your place, and the breadcrumb at the top right reads the same either way.
And ordering is shared: children come back in the order they will run, so
"after X" always points at a row above, in every layout at once.

## Adding a third

Three steps, no more.

1. Add a case to `TreeLayout` in `Layouts.swift`, with a `name` for the picker
   and a `note` saying in one line what it gives you.
2. Add it to `draw`.
3. Write the view. Take `model: TreeModel`, read `model.roots`,
   `model.children(of:)` and `model.path`, call `model.select(_:atDepth:)`
   when someone picks something, and use `NodeRow` and `DetailPane`.

Nothing else has to change. The picker, the breadcrumb, the polling, the empty
state and the offline state are all already there.

## Looking at one without clicking

```
.build/debug/SubstrateBar --preview --tree
.build/debug/SubstrateBar --preview --tree --layout outline
.build/debug/SubstrateBar --preview --tree --select goal,goal/task,goal/task/sub
```

`--layout` overrides the remembered choice for that run. `--select` drills
straight in, through the same function a click calls, so a screenshot can show
the columns opened up.

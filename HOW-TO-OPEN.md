# How to open Substrate

## The app

Double-click **`Open Substrate.command`** in this folder, or run it from a
terminal:

```
open "Open Substrate.command"
```

A Terminal window opens and builds the app, which takes a minute the first time
and a second or two after that. Then a row of dots appears in your menu bar, top
right. Click the dots for the panel.

- **Type a goal** in the panel and press Plan it. One AI call, about half a
  minute, and the plan comes back as tasks with the checks that close them.
- **Nothing runs until you approve.** The three answers are approve, ask for
  changes, and reject.
- **Start the agents** from the panel when work is ready.
- **Open the full tree** for the window: every goal, its tasks, what each one
  waits on, and the checks with their evidence.

To stop it: quit from the panel, or close that Terminal window.

You need macOS 14 or newer and Xcode. The command line tools alone are not
enough at the moment: the September 2026 release ships without the SwiftUI macro
plugin, and the build fails on it. The launcher uses Xcode when it is installed.

## The record

Your goals live in one SQLite file, `store/substrate.db`. To keep more than one,
point `SUBSTRATE_DB` at another file, or use **Open another record** in the
panel's settings menu.

## The command line

The same record, without the app:

```
./bin/substrate            the tree
./bin/substrate decompose  a sentence in, a plan out
./bin/substrate approve <goal>
./bin/substrate run        agents take the work
```

`./bin/substrate --help` lists every command.

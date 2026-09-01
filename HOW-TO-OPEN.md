# How to open the Substrate yourself

## The whole project lives here
the folder you cloned this into

To see it: open Finder, press Cmd+Shift+G, paste that path, hit Enter.
Or: this folder is `substrate` inside your `projects` folder.

## To open the live app (canvas, gates, negotiate)
Double-click **`Open Substrate.command`** in this folder.
- A Terminal window opens and starts three small things: the store (your goals),
  the pages, and the runner (which picks up work you have approved).
- It waits until each one really answers, then says `running` next to each.
  If one says `DID NOT START`, it tells you which file holds the reason.
- Your browser opens the canvas automatically.
- Leave the Terminal window open while you use it.
- To stop: close that Terminal window.

(First time only, macOS may warn about opening it. Right-click the file,
choose Open, then Open again. After that, double-click works.)

## The pages, once it's running
Every page now has a bar across the top with links to the other three, so you
do not have to remember any of these addresses.

- Canvas (the main one):  http://localhost:8004/prototypes/canvas/canvas.html
- Live tree (watch only):  http://localhost:8004/prototypes/live-tree/live-tree.html
- Negotiate (approve plans): http://localhost:8004/prototypes/negotiate/negotiate.html
- Gates (answer questions):  http://localhost:8004/prototypes/gates/gates.html

The right-hand end of that bar tells you the truth about the engine: whether
your goals are reachable, and whether the runner is actually working on
something or sitting idle. If the store stops, every page says so and tells you
how to start it again.

## What's inside, in plain terms
- `store/`      the database and its little service (the memory)
- `prototypes/` the app pages you open

## To type a new goal in
On the Canvas page, press **New goal**, write it in one sentence, press
**Break it down**.

It thinks for about half a minute, then the plan appears on the canvas. It
arrives amber, meaning it is waiting for you. Go to the Negotiate page to
reshape it and approve it. Nothing runs until you approve.

Once you approve, the runner picks the plan up by itself, one task at a time.
It will not touch a task whose exit criterion needs a person to decide: those
are left for you, and it says so rather than guessing.

(The Terminal still works if you prefer it:
`python3 store/decompose.py "your goal in one sentence"`)
# Substrate menu bar

A macOS menu bar app that watches the substrate. One dot per thing that
matters, and a panel that answers one question: does anything need me?

## Build and run

```
cd app/mac
swift build
.build/debug/SubstrateBar
```

That gives you a bare executable, which runs but has no icon and cannot open
at login. For the real thing:

```
cd app/mac
./make-app.sh
```

That builds `Substrate.app`: the same binary in the bundle macOS expects, with
an icon and a marker pointing back at this repo so it can still find the store.
It is a menu bar app, so it has no Dock icon by design; the icon shows in
Finder, in Spotlight and in the login items list.

It is not signed or notarised. That is the App Store piece and it is not in
this window, so the first open asks whether you meant to run it.

## Opening at login

The panel offers this only when you are running the bundled app, because macOS
will not register a bare executable and a switch that always fails is worse
than no switch. From a terminal:

```
./Substrate.app/Contents/MacOS/Substrate --login status
./Substrate.app/Contents/MacOS/Substrate --login on
./Substrate.app/Contents/MacOS/Substrate --login off
```

## The icon

`make-icon.py` draws it: a row of dots where one is amber. That is already the
mark in the menu bar, and an icon that was a picture of something else would be
a second identity to keep in step. Motion means state, colour means exception,
so the icon shows the one moment that matters. Rerun it only to change the
drawing; `Substrate.icns` is committed so nobody needs Pillow to build the app.

That is all of it. The app polls `http://127.0.0.1:8040/panel` once a second,
and if nothing answers there it starts the store itself and stops it again when
you quit. A menu bar app that makes you open a Terminal and run a Python server
first is not a Mac app, it is a Python server with an icon.

If a store is already running, in a window you can see, the app leaves it alone
and only uses it.

## Checking it without the interface

A menu bar item is 22 points tall, which is too small to review on a
screenshot, and squinting is not a design process. So:

```
SubstrateBar --print                     poll once and print what it sees
SubstrateBar --render-pill out.png       the pill, magnified 8x
SubstrateBar --render-panel out.png      the panel, magnified 2x
SubstrateBar --render-panel out.png --dark
SubstrateBar --render-panel out.png --empty      the nothing-yet state
SubstrateBar --preview                   run with a Dock icon, to capture on screen
```

The render modes use mock data, so the design can be reviewed without the store
running and without waiting for agents to reach an interesting state.

## The dot language

Unchanged from Session Indicator. Motion means state, colour means exception.

| State | Dot |
|---|---|
| nothing yet | hollow |
| idle | dim, still |
| an agent is on it | ink, breathing |
| needs a person | amber, still |
| error | red ring, told apart by shape as well as hue |
| done | green |

The pill shows at most four and counts the rest. Anything needing a person is
never the thing that gets folded into the count: the pill compresses the quiet,
never the actionable. That ordering is decided in the store, not here, so the
command line and the app cannot disagree.

## Approving a plan

A goal nobody has approved shows the whole plan: every task, how many checks it
carries, and what it waits on. Press Approve and the agents may start. Until
then nothing runs, which is the point of the gate.

The rule that a plan can only be approved once, and only while it is waiting,
lives in the store rather than in the app. The command line had that guard and
the app did not, so approving twice from the app put a second event in a log
whose only value is that it is true.

## Dragging it off the menu bar

The panel is a transient popover, so it closes when you look at something else. That is right
for a glance and wrong for anything that takes thought, because it vanishes the moment you
consult the thing you are describing.

So drag it off. It becomes an ordinary window with the same content, and it stays. This is
AppKit's own gesture, `popoverShouldDetach`, and the window is built for you.

## Closing a check from the panel

A task that stopped shows the checks it could not prove. Press "I did this",
say what shows it is true, and the check closes. The store refuses a check
without evidence, so the panel refuses too rather than sending a request it
knows will bounce, and when the store does refuse something its own words are
what you see.

That is the difference between a display and a tool: the panel can move work,
not only report on it.

## What is not built yet

The full tree window. "Open the full tree" starts the page server and opens the
browser view for now.

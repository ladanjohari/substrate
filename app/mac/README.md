# Substrate menu bar

A macOS menu bar app that watches the substrate. One dot per thing that
matters, and a panel that answers one question: does anything need me?

## Build and run

```
cd app/mac
swift build
.build/debug/SubstrateBar
```

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

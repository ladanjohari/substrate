# Substrate menu bar

A macOS menu bar app that watches the substrate. One dot per thing that
matters, and a panel that answers one question: does anything need me?

## Build and run

```
cd app/mac
swift build
.build/debug/SubstrateBar
```

It polls `http://127.0.0.1:8040/panel` once a second, so start the store first:

```
python3 store/substrate_store.py serve 8040
```

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

## What is not built yet

The full tree window. "Open the full tree" opens the browser page for now.
Answering a question from inside the panel is next.

# Moving the store to Swift

The decision, 9 September 2026: the store, the command line and the agents
move from Python to Swift. The app is already Swift.

## Why

| Reason | |
|---|---|
| Shipping | On macOS `/usr/bin/python3` is a stub that asks the user to install developer tools. A Python core cannot be handed to somebody who does not code, and cannot go through the App Store |
| One binary | Swift produces a single executable with nothing to install alongside it |
| The rules cannot drift | Today the app talks to the store over HTTP because they are different languages. As a library both link, there is one copy of every rule and the compiler checks it. Twice this month the two disagreed about a rule |
| Readability, for the person who owns this | Swift is the language she already knows. Python was the newer thing |

SQLite is part of macOS, so the core needs no package dependency at all.

## What this does not solve

The App Store blocker is not only Python. Three places shell out to the
`claude` command, and a sandboxed App Store app cannot run a binary the user
installed elsewhere. That route needs the API called directly, with the user
bringing a key, which is a product decision about who pays for tokens.

Signed and notarised direct download does not have this problem.

## The order

1. **`SubstrateCore`**, the library: schema, the two rules, the queries. **Done.**
2. **The command line**, as a second executable on the same core. **Done:**
   tree, show, criteria, meet, fail, state, log, frontier, approve, reject,
   remove, panel. Still Python: add, edit, block, unblock, path, decompose,
   changes, run, reopen, add-criterion.
3. **The app** reads the core directly instead of over HTTP, and the HTTP
   server becomes optional rather than the way the app works.
4. **The agents**: the decomposer, the runner and the workers. Mostly a
   subprocess call and some JSON.
5. **Then** delete the Python, and not before.

## What makes this a port and not a rewrite

```
./bin/substrate-compare
```

It builds one database with the states that behave differently, a plan still
awaiting approval, a task being worked, a task that stopped for a person, then
asks both implementations the same questions and fails if any answer differs.
Fifteen answers, including `panel`, which is the biggest query and the one the
app lives on. Refusals are compared by their words, because a
person reads them to decide what to do next.

```
cd app/mac && swift build && .build/debug/substrate-selftest
```

Fifteen checks on the two rules themselves. Not XCTest: that needs full Xcode,
and this has to run for anyone who can run `swift build`.

Both were confirmed to fail when the code is wrong, by breaking it on purpose
and watching them catch it. A check that has never failed proves nothing.

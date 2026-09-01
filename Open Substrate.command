#!/bin/bash
# Double-click this file to open the Substrate.
# It clears anything left over from last time, starts the two little servers,
# checks they actually answered, and opens the canvas in your browser.
# To stop everything later: close this Terminal window.

cd "$(dirname "$0")"

STORE_PORT=8040
FILES_PORT=8004

echo "Starting the Substrate..."
echo ""

# Clear out anything still holding these two ports from a previous run.
# This is why restarting could look like it did nothing: an old server was
# still sitting on the port, so the new one never started, and the pages went
# on talking to the stale one.
for PORT in $STORE_PORT $FILES_PORT; do
  OLD=$(lsof -ti tcp:$PORT 2>/dev/null)
  if [ -n "$OLD" ]; then
    echo "  clearing an old server on port $PORT"
    kill $OLD 2>/dev/null
    sleep 1
    kill -9 $(lsof -ti tcp:$PORT 2>/dev/null) 2>/dev/null
  fi
done

# 1. the store (the database service)
python3 store/substrate_store.py serve $STORE_PORT >/tmp/substrate-store.log 2>&1 &
STORE_PID=$!

# 2. the file server (serves the pages, with caching off so a reload always
#    shows the current version rather than a stale copy)
python3 store/pages.py $FILES_PORT >/tmp/substrate-files.log 2>&1 &
FILES_PID=$!

# 3. the runner (picks up work you have approved, one task at a time)
python3 store/runner.py >/tmp/substrate-runner.log 2>&1 &
RUNNER_PID=$!

# Wait until each one actually answers, rather than assuming it worked.
wait_for () {
  for i in $(seq 1 20); do
    if curl -s -o /dev/null -m 2 "$1"; then return 0; fi
    sleep 0.5
  done
  return 1
}

STORE_OK=no
FILES_OK=no
wait_for "http://localhost:$STORE_PORT/tree" && STORE_OK=yes
wait_for "http://localhost:$FILES_PORT/"     && FILES_OK=yes

echo ""
if [ "$STORE_OK" = yes ]; then
  echo "  the store   -> running"
else
  echo "  the store   -> DID NOT START"
  echo "                 the reason is in /tmp/substrate-store.log"
fi
if [ "$FILES_OK" = yes ]; then
  echo "  the pages   -> running"
else
  echo "  the pages   -> DID NOT START"
  echo "                 the reason is in /tmp/substrate-files.log"
fi
if kill -0 $RUNNER_PID 2>/dev/null; then
  echo "  the runner  -> watching for approved work"
else
  echo "  the runner  -> DID NOT START"
  echo "                 the reason is in /tmp/substrate-runner.log"
fi
echo ""

if [ "$STORE_OK" = yes ] && [ "$FILES_OK" = yes ]; then
  echo "Opening the canvas in your browser..."
  open "http://localhost:$FILES_PORT/prototypes/canvas/canvas.html"
else
  echo "Not opening the browser, because something above did not start."
  echo "Close this window and try once more. If it fails again, the log file"
  echo "named above holds the reason."
fi

echo ""
echo "-------------------------------------------------------"
echo "  The Substrate is open. Other pages you can visit:"
echo ""
echo "  Canvas (main):  http://localhost:$FILES_PORT/prototypes/canvas/canvas.html"
echo "  Live tree:      http://localhost:$FILES_PORT/prototypes/live-tree/live-tree.html"
echo "  Negotiate:      http://localhost:$FILES_PORT/prototypes/negotiate/negotiate.html"
echo "  Gates:          http://localhost:$FILES_PORT/prototypes/gates/gates.html"
echo ""
echo "  To STOP: close this window."
echo "-------------------------------------------------------"

# keep the window alive so the servers keep running
trap "kill $STORE_PID $FILES_PID $RUNNER_PID 2>/dev/null" EXIT
wait

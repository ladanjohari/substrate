#!/usr/bin/env python3
"""
The little server that hands out the pages.

This exists for one reason. The plain `python3 -m http.server` lets the browser
cache pages, so after a change you can reload and still be looking at
yesterday's version, with no way of telling. That turned a session of real fixes
into "you keep fixing it and it still does not work", because the fixes were on
disk and the browser was showing an old copy.

Everything here is served with caching switched off, so a reload always shows
what is actually in the folder.

Usage: python3 pages.py [port]     (default 8004, serves the repo root)
"""

import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        # Keep the launcher window readable: only complain about real failures.
        if args and str(args[1]).startswith(("4", "5")):
            sys.stderr.write("pages: %s %s\n" % (args[0], args[1]))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8004
    handler = partial(NoCacheHandler, directory=str(ROOT))
    print(f"pages serving {ROOT} on http://localhost:{port} (caching off)")
    ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()

#!/usr/bin/env python3
"""Where the claude command is, for the times PATH cannot say.

A terminal inherits your shell's PATH, so `claude` is found. The app does
not: macOS starts it with PATH=/usr/bin:/bin:/usr/sbin:/sbin, and Homebrew
is not on that list. The same install was therefore present when planning
came from a terminal and missing when it came from the menu bar, which read
as "the claude command is not installed" on a machine where it plainly was.

So ask PATH first, and when PATH does not know, look where the installers
actually put it.
"""

import os
import shutil
from pathlib import Path

# Homebrew on Apple silicon, Homebrew on Intel, npm and the local installer.
PLACES = (
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    "~/.local/bin/claude",
    "~/.claude/local/claude",
    "~/.bun/bin/claude",
)

MISSING = ("the claude command cannot be found. It is not on PATH and not in "
           "the usual places, so there is nothing to call. If `which claude` "
           "in a terminal does print a path, say so: it means this list needs "
           "that path adding.")


def binary():
    """The claude command, or None when it genuinely is not there."""
    found = shutil.which("claude")
    if found:
        return found
    for place in PLACES:
        p = Path(place).expanduser()
        if os.access(p, os.X_OK):
            return str(p)
    return None

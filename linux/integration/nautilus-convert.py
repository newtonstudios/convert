#!/usr/bin/env python3
"""Convert… -- the right-click entry for Nautilus, Nemo and Caja.

Those file managers hand a script the selection as one newline-separated
environment variable. A shell loop would have to take the paths apart by hand
and would break on a name with a space or a newline; passing a list to exec
doesn't.

install.sh replaces __CONVERT__ with the installed command.
"""

import os
import subprocess
import sys

CONVERT = "__CONVERT__"


def main():
    paths = [p for p in os.environ.get("NAUTILUS_SCRIPT_SELECTED_FILE_PATHS", "").splitlines() if p]
    if not paths:
        # Nautilus can be told to run a script with nothing selected; there is
        # nothing to convert, so say so rather than opening an empty picker.
        return 0
    try:
        return subprocess.call([CONVERT, "--ui"] + paths)
    except OSError:
        return 1


if __name__ == "__main__":
    sys.exit(main())

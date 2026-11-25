"""``python3 -m convert`` -- the same entry point the installed ``convert`` uses."""

import sys

from .cli import main

if __name__ == "__main__":
    sys.exit(main())

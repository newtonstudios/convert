"""The window: a format picker, the progress, and any error.

Convert has no toolkit of its own -- a right-click converter that drags in
GTK or Qt bindings is a converter that doesn't start on half the distros --
so the dialog is whatever the desktop already ships: ``zenity`` (GNOME, XFCE,
Cinnamon, MATE) or ``kdialog`` (KDE). Both are present by default, and the
command line works without either.

This is also what the file-manager integrations call, so a Nautilus or Dolphin
right-click lands here.
"""

from __future__ import annotations

import os
import subprocess
import sys

from . import core, formats, tools
from .errors import ConvertError, Stopped


def available():
    """Whether a window can be shown at all."""
    if os.environ.get("CONVERT_NO_UI") == "1":
        return False
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return False
    return bool(tools.find("zenity") or tools.find("kdialog"))


def run(files, settings):
    """Pick a format, convert, report. Returns a process exit code."""
    files = [os.path.abspath(f) for f in files if os.path.exists(f)]
    if not files:
        return _fail("There's nothing to convert.")
    if len({os.path.dirname(f) for f in files}) > 1:
        # Not a problem, just worth knowing: each file is saved next to itself.
        pass

    targets = formats.common_targets(files)
    if not targets:
        return _fail("These files can't be converted together: a batch has one "
                     "format, and these don't share one. Try them one at a time.")

    target = _pick(files, targets)
    if target is None:
        return 0  # cancelled, which is not an error

    return _convert(files, target, settings)


def _zenity():
    return tools.find("zenity")


# ── Choosing ─────────────────────────────────────────────────────────────


def _pick(files, targets):
    suggested = formats.preferred(files, targets)
    count = "%d file%s" % (len(files), "" if len(files) == 1 else "s")
    if len(files) == 1:
        count = os.path.basename(files[0])

    zenity = _zenity()
    if zenity:
        cmd = [
            zenity, "--list", "--radiolist",
            "--title=Convert",
            "--text=Convert %s to:" % _escape(count),
            "--column=", "--column=Format", "--column=id",
            "--hide-column=3", "--print-column=3",
            "--width=340", "--height=460",
        ]
        for target in targets:
            chosen = "TRUE" if target is suggested else "FALSE"
            cmd += [chosen, _escape(target.label), target.id]
        code, out, _ = tools.run(cmd, timeout=None)
        if code != 0 or not out.strip():
            return None
        return formats.BY_ID.get(out.strip().splitlines()[-1])

    dialog = tools.find("kdialog")
    if dialog:
        args = [dialog, "--title", "Convert", "--radiolist", "Convert %s to:" % count]
        for target in targets:
            args += [target.label, target.id, "on" if target is suggested else "off"]
        code, out, _ = tools.run(args, timeout=None)
        if code != 0 or not out.strip():
            return None
        return formats.BY_ID.get(out.strip().splitlines()[-1])
    return None


def _escape(text):
    """Zenity reads Pango markup unless told not to, and a file name can contain '<'."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ── Converting ───────────────────────────────────────────────────────────


def _convert(files, target, settings):
    batch = core.Batch(settings)
    progress = _Progress()
    name = ""

    def on_file(index, path):
        nonlocal name
        name = os.path.basename(path)
        progress.text("%d of %d: %s" % (index + 1, len(files), _escape(name)))
        progress.percent(index * 100 // max(1, len(files)))

    def on_progress(fraction):
        progress.percent(int(fraction * 100))

    try:
        batch.run(files, target, on_file, on_progress)
    except Stopped:
        progress.close()
        return 1
    except ConvertError as e:
        progress.close()
        return _fail(str(e))
    progress.close()

    if batch.failed:
        lines = ["%s\n  %s" % (os.path.basename(src), message) for src, message in batch.failed]
        heading = ("Nothing was converted:" if not batch.done
                   else "%d of %d files couldn't be converted:"
                   % (len(batch.failed), len(files)))
        return _fail(heading + "\n\n" + "\n\n".join(lines))
    return 0


class _Progress:
    """The progress window, kept up to date through its standard input."""

    def __init__(self):
        self.proc = None
        zenity = _zenity()
        if not zenity:
            return
        try:
            self.proc = subprocess.Popen(
                [zenity, "--progress", "--title=Convert", "--auto-close",
                 "--width=380", "--percentage=0", "--no-cancel"],
                stdin=subprocess.PIPE, text=True,
            )
        except OSError:
            self.proc = None

    def text(self, message):
        if self.proc and self.proc.stdin:
            try:
                self.proc.stdin.write("# %s\n" % message)
                self.proc.stdin.flush()
            except (OSError, ValueError):
                self.proc = None

    def percent(self, value):
        if self.proc and self.proc.stdin:
            try:
                self.proc.stdin.write("%d\n" % max(0, min(100, value)))
                self.proc.stdin.flush()
            except (OSError, ValueError):
                self.proc = None

    def close(self):
        if not self.proc:
            return
        try:
            if self.proc.stdin:
                self.proc.stdin.write("100\n")
                self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            try:
                self.proc.kill()
            except OSError:
                pass
        self.proc = None


# ── Saying what went wrong ───────────────────────────────────────────────


def _fail(message):
    sys.stderr.write(message.rstrip("\n") + "\n")
    zenity = _zenity()
    if zenity:
        try:
            tools.run([zenity, "--error", "--title=Convert", "--no-markup",
                       "--width=420", "--text=%s" % message], timeout=None)
        except ConvertError:
            pass
    else:
        dialog = tools.find("kdialog")
        if dialog:
            try:
                tools.run([dialog, "--title", "Convert", "--error", message], timeout=None)
            except ConvertError:
                pass
    return 1

"""The command line, which is also how the desktop integrations call Convert.

    convert-file mp3 song.m4a notes.wav      # convert to MP3
    convert-file --targets clip.mov          # what can this become here?
    convert-file --ui photo.heic             # the picker, from a file manager
    convert-file --list-targets              # everything, and what is available

The installed command is ``convert-file``, not ``convert``: on Linux ``convert``
is ImageMagick's, and a converter for files must not take its name.
"""

from __future__ import annotations

import json
import os
import signal
import sys

from . import core, formats, kinds, ui
from .errors import ConvertError, Stopped

USAGE = """Usage:
  convert-file FORMAT FILE...        Convert the files to FORMAT
  convert-file --ui FILE...          Choose a format in a window
  convert-file --targets FILE...     List the formats these files can become
  convert-file --list-targets        List every format, and whether it's available
  convert-file --list-extensions     List the file types Convert opens

FORMAT is a target id (mp4-h264, mp3, jpg, pdf-png, font-woff2, ...) or the
label shown in the picker ("MP4 (H.264)").

Settings come from CONVERT_SETTINGS, or from --settings, as a JSON object:
  {"audioBitrate": 192, "videoQuality": 0.8, "imageQuality": 0.9, "pdfDPI": 300}
Run "convert-file --help" for the full list.

For a program reading the output (the Files panel does):
  --machine        print only "PROGRESS n", "ERROR why" and the paths written
  --matrix-json    every format each source extension can become, as JSON
"""


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print(USAGE, end="")
        return 2

    flags = {"ui": False, "quiet": False, "json": False, "machine": False}
    settings_json = None
    items = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help"):
            print(USAGE, end="")
            print_help_tail()
            return 0
        elif arg == "--version":
            from . import __version__
            print("convert %s" % __version__)
            return 0
        elif arg == "--list-targets":
            return list_targets()
        elif arg == "--list-extensions":
            return list_extensions()
        elif arg == "--targets":
            rest = [a for a in argv[i + 1:] if not a.startswith("-")]
            return list_available(rest)
        elif arg == "--matrix-json":
            return matrix_json()
        elif arg in ("--ui", "--picker"):
            flags["ui"] = True
        elif arg in ("-q", "--quiet"):
            flags["quiet"] = True
        elif arg == "--json":
            flags["json"] = True
        elif arg == "--machine":
            flags["machine"] = True
        elif arg == "--settings":
            i += 1
            if i >= len(argv):
                return fail("--settings needs a JSON object")
            settings_json = argv[i]
        elif arg.startswith("--settings="):
            settings_json = arg.split("=", 1)[1]
        elif arg == "--":
            items += argv[i + 1:]
            break
        elif arg.startswith("-") and arg != "-":
            return fail("Unknown option %s\n\n%s" % (arg, USAGE))
        else:
            items.append(arg)
        i += 1

    if not items:
        return fail("No files given.\n\n" + USAGE)

    try:
        settings = formats.Settings.from_json(settings_json) if settings_json \
            else formats.Settings.from_environment()
    except ValueError as e:
        return fail("Those settings can't be used: %s" % e)

    # "convert-file mp3 a.mp3" -- the first word is the format when it names one.
    target = None
    if not flags["ui"]:
        try:
            target = core.target_for(items[0])
        except ConvertError:
            target = None
    files = items[1:] if target else items
    files = [os.path.abspath(f) for f in files]

    if target is not None:
        return run_cli(files, target, settings, flags)
    if flags["ui"] or ui.available():
        return ui.run(files, settings)
    listed = ", ".join("%s (%s)" % (t.id, t.label) for t in formats.CATALOGUE[:6])
    return fail("Which format? Name one first, for example: convert-file mp3 song.wav\n"
                "Some targets: %s\nRun \"convert-file --targets %s\" for all of them."
                % (listed, os.path.basename(files[0])))


def run_cli(files, target, settings, flags):
    machine = flags["machine"]
    batch = core.Batch(settings)
    progress_shown = False
    last_percent = [-1]

    def say(text):
        print(text, flush=True)

    def on_file(index, path):
        if not flags["quiet"] and not machine:
            say("%s \u2192 %s" % (os.path.basename(path), target.label))

    def on_progress(fraction):
        nonlocal progress_shown
        if machine:
            # One line per whole percent: the Files panel reads these as they
            # arrive, and the same number twice is a line it has to skip.
            value = int(fraction * 100)
            if value != last_percent[0]:
                last_percent[0] = value
                say("PROGRESS %d" % value)
            return
        if flags["quiet"] or not sys.stderr.isatty():
            return
        progress_shown = True
        sys.stderr.write("\r  %3d%%" % int(fraction * 100))
        sys.stderr.flush()

    # Stop is a signal from the terminal (Ctrl-C) and from the Files panel
    # (SIGTERM to this process). Either way the tool in the middle is what has
    # to be killed and what was half-written is what has to go -- so the signal
    # cancels the batch instead of the process dying where it stands.
    def stop(signum, frame):
        batch.cancel()

    installed = {}
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            installed[sig] = signal.signal(sig, stop)
        except (ValueError, OSError):
            pass

    try:
        done, failed = batch.run(files, target, on_file, on_progress)
    except Stopped:
        if progress_shown:
            sys.stderr.write("\n")
        if machine:
            say("ERROR Stopped")
        return 130
    except ConvertError as e:
        if progress_shown:
            sys.stderr.write("\n")
        if machine:
            say("ERROR %s" % e)
        return fail(str(e))
    finally:
        for sig, handler in installed.items():
            try:
                signal.signal(sig, handler)
            except (ValueError, OSError):
                pass

    if progress_shown:
        sys.stderr.write("\n")

    if machine:
        for src, message in batch.failed:
            say("ERROR %s: %s" % (os.path.basename(src), message))
        for src, written in batch.done:
            for path in written:
                say(path)
        return 1 if batch.failed else 0

    if flags["json"]:
        print(json.dumps({
            "target": target.id,
            "written": [{"input": src, "output": out} for src, out in batch.done],
            "failed": [{"input": src, "error": msg} for src, msg in batch.failed],
        }, indent=2))
    else:
        for src, written in batch.done:
            if not flags["quiet"]:
                for path in written:
                    say("   saved as %s" % path)
        if batch.done and not flags["quiet"]:
            say("%d file%s converted." % (len(batch.done), "" if len(batch.done) == 1 else "s"))

    for src, message in batch.failed:
        sys.stderr.write("error: %s: %s\n" % (os.path.basename(src), message))
    return 1 if batch.failed else 0


def matrix_json():
    """What each source extension can become here, for a menu that has only the name.

    A menu built from this can't offer a format the converter would refuse: both
    sides ask the same machine the same question.
    """
    matrix = {}
    for exts in kinds.EXTENSIONS.values():
        for ext in sorted(exts):
            offered = formats.offered_for("sample." + ext)
            if offered:
                matrix[ext] = [[t.id, t.label] for t in offered]
    print(json.dumps(matrix, separators=(",", ":")))
    return 0


def list_targets():
    print("%-12s %-28s %s" % ("ID", "FORMAT", "AVAILABLE"))
    for group, targets in formats.grouped(formats.CATALOGUE):
        print("\n%s" % formats.GROUP_LABELS.get(group, group.capitalize()))
        for target in targets:
            print("  %-12s %-28s %s" % (target.id, target.label,
                                        "yes" if formats.available(target) else "no"))
    print("\nA format can also need the right source: pdf-png needs a PDF, and "
          "documents photographed as images need jpg/png.")
    return 0


def list_extensions():
    for kind, exts in kinds.EXTENSIONS.items():
        print("%-9s %s" % (kind, " ".join(sorted(exts))))
    return 0


def list_available(files):
    if not files:
        return fail("Which files? For example: convert-file --targets photo.heic")
    files = [os.path.abspath(f) for f in files]
    missing = [f for f in files if not os.path.exists(f)]
    if missing:
        return fail("%s is not there" % os.path.basename(missing[0]))
    targets = formats.common_targets(files)
    if not targets:
        kind = kinds.kind_of(files[0])
        if kind is None:
            return fail("Convert doesn't handle %s" % os.path.basename(files[0]))
        return fail("No format is available for these files here (they are %s files)" % kind)
    for target in targets:
        print("%-12s %s" % (target.id, target.label))
    return 0


def print_help_tail():
    print("Settings (all optional, same names as the Mac app):")
    for name, default in formats.Settings.FIELDS.items():
        print("  %-14s %s" % (name, default))


def fail(message):
    sys.stderr.write(message.rstrip("\n") + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())

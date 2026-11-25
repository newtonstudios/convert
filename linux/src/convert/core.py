"""One conversion, and a batch of them.

``Converter.swift``'s count of what happens for one file:

1. the kind is worked out from the name (looking inside when the name is
   ambiguous);
2. the target has to be one this file can become;
3. the target has to be available on this machine;
4. the contents have to agree with the name;
5. the conversion runs in a temp folder and only its finished result is moved
   next to the original -- so a failure, or Stop, leaves no half-written file.

The last point is why every module writes to a temp folder and calls
``paths.move_into_place``: the name that appears in the user's folder is always
a complete file.
"""

from __future__ import annotations

import os

from . import docs, fonts, formats, images, kinds, media, pdfs, tools
from .errors import ConvertError, Stopped


def target_for(id_or_label):
    """A target by its id (``mp4-h264``) or by what the picker shows (``MP4 (H.264)``)."""
    if id_or_label in formats.BY_ID:
        return formats.BY_ID[id_or_label]
    for target in formats.CATALOGUE:
        if target.label == id_or_label:
            return target
    raise ConvertError('There is no format called "%s". Run "convert --list-targets" '
                       "to see them." % id_or_label)


def convert(input_path, target, settings=None, runner=None, progress=None):
    """Convert one file; returns the paths written.

    ``target`` is a ``formats.Target`` or its id. ``progress`` is called with a
    number from 0 to 1.
    """
    if runner is None:
        runner = tools.Runner()
    settings = settings or formats.Settings()
    progress = progress or (lambda fraction: None)

    if isinstance(target, str):
        target = target_for(target)
    if not os.path.exists(input_path):
        raise ConvertError("%s is no longer there" % os.path.basename(input_path))
    if not os.path.isfile(input_path):
        raise ConvertError("%s is a folder" % os.path.basename(input_path))

    kind = kinds.kind_of(input_path)
    if kind is None:
        raise ConvertError("Convert doesn't handle %s" % os.path.basename(input_path))
    if target.group not in kinds.GROUPS_FOR_KIND[kind]:
        raise ConvertError("%s can't become %s" % (os.path.basename(input_path), target.label))

    ext = input_path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(input_path) else ""
    if not formats.available(target, kind, ext):
        raise ConvertError(not_available_message(target))

    # The name was never the point: a file has to be what it claims.
    kinds.verify(input_path, kind)
    runner.check()

    if kind in (kinds.AUDIO, kinds.VIDEO):
        written = media.convert(input_path, target, settings, runner, progress)
    elif kind == kinds.IMAGE:
        written = images.convert(input_path, target, settings, runner, progress)
    elif kind == kinds.DOCUMENT:
        written = docs.convert(input_path, target, settings, runner, progress)
    elif kind == kinds.PDF:
        written = pdfs.convert(input_path, target, settings, runner, progress)
    elif kind == kinds.FONT:
        written = fonts.convert(input_path, target, settings, runner, progress)
    else:
        raise ConvertError("Convert doesn't handle %s" % os.path.basename(input_path))

    runner.check()
    return written


def not_available_message(target):
    """What is missing for a format that isn't offered here."""
    needs = {
        "audio": "ffmpeg with the %s encoder" % formats.NEEDS_ENCODER.get(target.id, target.label),
        "video": "ffmpeg with the %s encoder" % formats.NEEDS_ENCODER.get(target.id, target.label),
        "image": "ImageMagick support for writing %s" % target.ext.upper(),
        "document": "LibreOffice",
        "pdf": "poppler-utils",
        "font": "fontTools",
    }.get(target.group, "the required tool")
    return ("%s isn't available on this machine: it needs %s. Install it and try again."
            % (target.label, needs))


class Batch:
    """A conversion of several files, with one Stop and one progress figure."""

    def __init__(self, settings=None):
        self.settings = settings or formats.Settings()
        self.runner = tools.Runner()
        self.done = []
        self.failed = []

    def cancel(self):
        self.runner.cancel()

    def run(self, files, target, on_file=None, on_progress=None):
        """Convert every file, stopping at the first Stop.

        A file that fails does not stop the batch -- one broken video among
        twenty should not cost the other nineteen -- unless the failure is the
        tool being missing, which would only repeat.
        """
        on_file = on_file or (lambda index, path: None)
        on_progress = on_progress or (lambda fraction: None)
        total = max(1, len(files))
        for index, path in enumerate(files):
            self.runner.check()
            on_file(index, path)

            def file_progress(fraction, index=index):
                on_progress((index + fraction) / total)

            try:
                written = convert(path, target, self.settings, self.runner, file_progress)
                self.done.append((path, written))
            except Stopped:
                raise
            except ConvertError as e:
                self.failed.append((path, str(e)))
                if "isn't installed" in str(e) or "isn't available" in str(e):
                    # Every other file would fail the same way.
                    for rest in files[index + 1:]:
                        self.failed.append((rest, str(e)))
                    break
        on_progress(1.0)
        return self.done, self.failed

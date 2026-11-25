"""Where converted files go, and how their names are chosen.

Mirrors ``Paths.cs``: next to the original (``name.ext``, then ``name 2.ext``),
or in Downloads when that folder can't be written to. Nothing is ever
overwritten and nothing half-written stays.
"""

from __future__ import annotations

import os
import shutil
import stat
import tempfile
import time
import uuid

from .errors import ConvertError


def fallback_dir():
    """Where a conversion goes when the original's folder is read-only.

    The XDG download folder when the desktop defines one, else ``~/Downloads``;
    ``CONVERT_FALLBACK_DIR`` replaces it (the tests use that).
    """
    override = os.environ.get("CONVERT_FALLBACK_DIR", "").strip()
    if override:
        return os.path.abspath(os.path.expanduser(override))
    try:
        out = os.popen("xdg-user-dir DOWNLOAD 2>/dev/null").read().strip()
        if out and os.path.isdir(out):
            return out
    except OSError:
        pass
    return os.path.join(os.path.expanduser("~"), "Downloads")


def is_writable(folder):
    """Whether a file can be created in a folder.

    Asked by trying: permissions don't know about a read-only mount or what a
    file server will allow, and the only answer that matters is the one the
    kernel gives.
    """
    probe = os.path.join(folder, ".convert-%s.tmp" % uuid.uuid4().hex)
    try:
        fd = os.open(probe, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        os.unlink(probe)
        return True
    except OSError:
        return False


def folder_for(input_path, fallback=None):
    """The folder a conversion of this file is written into."""
    folder = os.path.dirname(os.path.abspath(input_path))
    if is_writable(folder):
        return folder
    where = fallback or fallback_dir()
    if not is_writable(where):
        raise ConvertError(
            "Can't save the converted file: the original's folder is read-only, "
            "and \u201c%s\u201d can't be written to either" % os.path.basename(where.rstrip("/")))
    return where


def stem(path):
    name = os.path.basename(path)
    return name.rsplit(".", 1)[0] if "." in name else name


def unique_output(input_path, ext, suffix="", fallback=None):
    """The next free name next to the input: ``name.ext``, ``name 2.ext``, …"""
    folder = folder_for(input_path, fallback)
    name = stem(input_path) + suffix
    path = os.path.join(folder, "%s.%s" % (name, ext))
    n = 2
    while os.path.exists(path):
        path = os.path.join(folder, "%s %d.%s" % (name, n, ext))
        n += 1
    return path


def unique_folder(input_path, suffix, fallback=None):
    """The next free folder name, for a multi-page PDF or a font collection."""
    folder = folder_for(input_path, fallback)
    name = stem(input_path) + suffix
    path = os.path.join(folder, name)
    n = 2
    while os.path.exists(path):
        path = os.path.join(folder, "%s %d" % (name, n))
        n += 1
    return path


def create_new(path):
    """Open a new file for writing, failing rather than replacing one that appeared meanwhile."""
    return open(path, "xb")


def write_new(path, data):
    """Write bytes to a new file; removed again if writing fails.

    Only a file this call created is ever removed: a name that is already
    taken is somebody else's file, and it stays exactly as it was.
    """
    created = False
    try:
        with create_new(path) as f:
            created = True
            f.write(data)
    except FileExistsError:
        raise ConvertError("%s already exists" % os.path.basename(path))
    except OSError as e:
        if created:
            try_delete(path)
        raise ConvertError("Couldn't write %s: %s" % (os.path.basename(path), e.strerror or e))


def move_into_place(source, dest):
    """Move a finished temp file to its final name, without ever replacing anything.

    ``os.link`` then unlink is the one move that fails when the name is taken;
    ``os.rename`` would happily replace a file the user created meanwhile.
    """
    try:
        os.link(source, dest)
    except FileExistsError:
        raise ConvertError("%s already exists" % os.path.basename(dest))
    except OSError:
        # A different filesystem (temp is a tmpfs, say) can't be linked across.
        try:
            with open(source, "rb") as src, create_new(dest) as out:
                shutil.copyfileobj(src, out)
        except FileExistsError:
            raise ConvertError("%s already exists" % os.path.basename(dest))
        except OSError as e:
            try_delete(dest)
            raise ConvertError("Couldn't write %s: %s" % (os.path.basename(dest), e.strerror or e))
    try:
        os.unlink(source)
    except OSError:
        pass
    _fix_permissions(dest)


# Read once, at import, while nothing else runs: os.umask can only be read by setting it.
_UMASK = os.umask(0o022)
os.umask(_UMASK)


def _fix_permissions(path):
    """Give the new file the mode any new file of this user's gets (0644 with the usual umask).

    A file made in a temp folder arrives as 0600, and a converted document the
    user then can't open from another account (or from a shared folder) is not
    a finished conversion. Never the folder's bits: those include x.
    """
    try:
        os.chmod(path, (0o666 & ~_UMASK) | 0o600)
    except OSError:
        pass


def try_delete(path):
    """Remove a file or folder, ignoring a failure: it's cleanup, not the result."""
    if not path:
        return
    try:
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path, ignore_errors=True)
        elif os.path.exists(path):
            os.unlink(path)
    except OSError:
        pass


def temp_root():
    """This user's scratch folder, with the uid in it.

    Not plain ``/tmp/convert``: a folder called ``convert`` is a checkout of this
    very project often enough, and working files must never appear inside one.
    """
    uid = getattr(os, "getuid", lambda: 0)()
    root = os.path.join(tempfile.gettempdir(), "convert-%d" % uid)
    # /tmp is shared with every other account: the folder must be this user's
    # own and closed to the others, or they could read (or swap) the copies of
    # documents that pass through it.
    try:
        os.mkdir(root, 0o700)
    except FileExistsError:
        pass
    except OSError as e:
        raise ConvertError("Couldn't create the temp folder %s: %s" % (root, e.strerror or e))
    info = os.lstat(root)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid:
        raise ConvertError("%s isn't Convert's own temp folder; remove it and try again" % root)
    if info.st_mode & 0o077:
        os.chmod(root, 0o700)
    return root


def temp_dir():
    """A folder of this conversion's own, in Convert's temp root."""
    root = temp_root()
    sweep_once(root)
    path = os.path.join(root, uuid.uuid4().hex)
    os.mkdir(path, 0o700)
    return path


_swept = False


def sweep_once(root):
    """Remove temp folders a crash left behind.

    A conversion removes its own folder, but not if Convert was killed or the
    power went. Those folders can hold a copy of somebody's document, so the
    next run removes any older than a day -- no conversion takes that long.
    """
    global _swept
    if _swept:
        return
    _swept = True
    try:
        for name in os.listdir(root):
            if len(name) != 32 or any(c not in "0123456789abcdef" for c in name):
                continue
            path = os.path.join(root, name)
            try:
                if time.time() - os.path.getmtime(path) > 86400:
                    shutil.rmtree(path, ignore_errors=True)
            except OSError:
                pass
    except OSError:
        pass

"""Documents: Word, ODT, RTF, Markdown, HTML and plain text.

The Mac uses ``textutil``, its own Markdown renderer and AppKit's text system.
None of those exist here, so the work is split by what each format needs:

* **Word / ODT / RTF, in or out** -- ``soffice --headless`` with a throwaway
  profile, which is the Linux equivalent of a document engine, and the only
  thing on a normal system that can read a ``.docx``.
* **Markdown, plain text and HTML to PDF** -- a Chromium-family browser printing
  the page, which is what ``DocBrowser`` does on Windows with WebView2. The
  browser resolves no names and gets a proxy that isn't there, and an HTML
  file is cleaned first (``htmlclean``: no scripts, frames, objects, stylesheet
  links, event handlers or CSS ``url()``s), so a document cannot make the
  machine talk to anyone: Convert's promise is that nothing leaves it. HTML
  handed to LibreOffice is cleaned the same way.
* **A PDF's text to Word / ODT / RTF** -- Convert writes those files itself
  (``docwrite``), because the point of "text only" is the paragraphs, not a
  layout a converter would try to rebuild.
"""

from __future__ import annotations

import html
import os
import re
import shutil
import urllib.parse

from . import htmlclean, markdown, paths, tools
from .errors import ConvertError

OFFICE = "soffice"

# The filter names are LibreOffice's own; the plain extension is enough for PDF.
FILTERS = {
    "pdf": "pdf",
    "docx": "docx:MS Word 2007 XML",
    "doc": "doc:MS Word 97",
    "odt": "odt:writer8",
    "rtf": "rtf:Rich Text Format",
    "html": "html:XHTML Writer File",
    "txt": "txt:Text",
}

OFFICE_INPUTS = ("doc", "docx", "odt", "rtf")
WEB_INPUTS = ("md", "markdown", "txt", "text", "html", "htm")


def _ext(path):
    name = os.path.basename(path)
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def convert(input_path, target, settings, runner, progress):
    work = paths.temp_dir()
    try:
        ext = _ext(input_path)
        staged = os.path.join(work, "input." + ext)
        try:
            shutil.copyfile(input_path, staged)
        except OSError as e:
            raise ConvertError("Couldn't read the file: %s" % (e.strerror or e))
        runner.check()

        if target.id == "pdf-doc":
            produced = _to_pdf(staged, ext, input_path, settings, work, runner)
        elif target.id in ("docx", "doc", "odt", "rtf"):
            produced = _to_office(staged, ext, target.ext, work, runner)
        elif target.id == "html":
            produced = _to_html(staged, ext, work, runner)
        elif target.id == "txt":
            produced = _to_text(staged, ext, work, runner)
        else:
            raise ConvertError("Unsupported target")

        runner.check()
        if not os.path.exists(produced) or os.path.getsize(produced) == 0:
            raise ConvertError("The conversion wrote nothing")
        dest = paths.unique_output(input_path, target.ext)
        paths.move_into_place(produced, dest)
        progress(1.0)
        return [dest]
    finally:
        paths.try_delete(work)


# ── To PDF ───────────────────────────────────────────────────────────────


def _to_pdf(staged, ext, original, settings, work, runner):
    if ext in WEB_INPUTS:
        page = _html_page(staged, ext, original, work, settings.paperA4)
        return _print_to_pdf(page, work, runner)
    out = office_convert(staged, "pdf", work, runner)
    return out


def _html_page(staged, ext, original, work, paper_a4=True):
    """A printable HTML file for a Markdown, text or HTML document."""
    title = paths.stem(original)
    if ext in ("md", "markdown"):
        with open(staged, "r", encoding="utf-8", errors="replace") as f:
            body = markdown.to_html(f.read())
        page = markdown.page(body, title, paper_a4)
    elif ext in ("txt", "text"):
        with open(staged, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        body = ("<pre style=\"white-space:pre-wrap;font-family:'DejaVu Sans Mono',"
                "monospace\">%s</pre>" % html.escape(text, quote=False))
        page = markdown.page(body, title, paper_a4)
    else:
        # HTML goes in cleaned (htmlclean), with its own title kept when it has
        # one. The paper size is still Convert's to decide, so a page rule is
        # added at the start of <head> -- a document that sets its own @page
        # keeps it, since later rules win.
        with open(staged, "r", encoding="utf-8", errors="replace") as f:
            source = f.read()
        rule = "<style>@page { size: %s; margin: 20mm; }</style>" % markdown.PAPER[bool(paper_a4)]
        source = htmlclean.clean(source, _CHARSET + rule)
        out = os.path.join(work, "page.html")
        with open(out, "w", encoding="utf-8") as f:
            f.write(source)
        return out
    out = os.path.join(work, "page.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(page)
    return out


def _print_to_pdf(page, work, runner):
    """Print a page to PDF with a Chromium-family browser."""
    chrome = tools.find("chrome")
    if not chrome:
        raise ConvertError("Printing a document to PDF needs a Chromium-based browser "
                           "(Chrome, Chromium, Brave or Edge). Install one, or convert "
                           "the file with LibreOffice instead.")
    out = os.path.join(work, "printed.pdf")
    profile = os.path.join(work, "browser")
    args = [
        chrome,
        "--headless",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-background-networking",
        "--disable-component-update",
        "--no-pings",
        # A document is not allowed to reach the network: no name resolves, so
        # there is nothing to reach. Scripts are removed from the page instead
        # (see `_html_page`), because the flag that would disable them stops
        # the browser printing at all.
        "--host-resolver-rules=MAP * ~NOTFOUND",
        # ...and, as on Windows, a proxy that isn't there for whatever bypasses
        # name resolution (an IP address), and no WebRTC outside that proxy.
        "--proxy-server=http://127.0.0.1:1",
        "--proxy-bypass-list=<-loopback>",
        "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
        "--user-data-dir=" + profile,
        "--no-pdf-header-footer",
        "--print-to-pdf=" + out,
        "--virtual-time-budget=1500",
    ]
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        args.append("--no-sandbox")
    url = "file://" + urllib.parse.quote(os.path.abspath(page))
    args.append(url)

    # The browser sometimes writes the file and then sits there instead of
    # exiting. The file is the result, so it is what decides.
    try:
        tools.run(args, runner=runner, timeout=120)
    except ConvertError:
        if runner.cancelled:
            raise
        # A browser that overran is only a failure when it produced nothing.
        pass
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        raise ConvertError("Couldn't print this document to PDF")
    return out


def office_convert(staged, ext, work, runner):
    """Convert with LibreOffice, into this folder."""
    soffice = tools.find(OFFICE)
    if not soffice:
        raise ConvertError("LibreOffice isn't installed, and it is what reads and writes "
                           "Word, ODT and RTF files. Install it and try again "
                           "(for example: sudo apt install libreoffice-writer)")
    profile = os.path.join(work, "office-profile")
    # LibreOffice has no offline switch, and it fetches what an HTML page or a
    # DOCX links to (pictures, stylesheets). Its web traffic honours the proxy
    # set in the profile, so the throwaway profile gets one that isn't there --
    # the same guard as the Windows port's DocOffice.cs.
    os.makedirs(os.path.join(profile, "user"), exist_ok=True)
    with open(os.path.join(profile, "user", "registrymodifications.xcu"), "w", encoding="utf-8") as f:
        f.write(_OFFLINE_PROFILE)
    args = [
        soffice,
        "--headless",
        "--norestore",
        "--invisible",
        "--nodefault",
        "--nolockcheck",
        # A throwaway profile: the user's own LibreOffice is never touched, and
        # two conversions can't fight over one lock file.
        "-env:UserInstallation=file://" + urllib.parse.quote(profile),
        "--convert-to", FILTERS[ext],
        "--outdir", work,
        staged,
    ]
    code, _, err = tools.run(args, runner=runner, timeout=180)
    produced = os.path.join(work, paths.stem(staged) + "." + ext)
    if not os.path.exists(produced):
        raise ConvertError("LibreOffice couldn't convert this document: %s"
                           % (tools.last_line(err) or "no output"))
    return produced


def _inet(name, value):
    return ('<item oor:path="/org.openoffice.Inet/Settings"><prop oor:name="%s" oor:op="fuse">'
            "<value>%s</value></prop></item>\n" % (name, value))


_OFFLINE_PROFILE = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<oor:items xmlns:oor="http://openoffice.org/2001/registry" '
    'xmlns:xs="http://www.w3.org/2001/XMLSchema" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
    + _inet("ooInetProxyType", "2")            # manual
    + _inet("ooInetHTTPProxyName", "127.0.0.1")
    + _inet("ooInetHTTPProxyPort", "1")
    + _inet("ooInetHTTPSProxyName", "127.0.0.1")
    + _inet("ooInetHTTPSProxyPort", "1")
    + _inet("ooInetNoProxy", "")                # loopback too
    + "</oor:items>\n"
)


# ── Between the other document formats ───────────────────────────────────


def _to_office(staged, ext, target_ext, work, runner):
    if ext in OFFICE_INPUTS:
        return office_convert(staged, target_ext, work, runner)
    if ext in ("md", "markdown", "txt", "text"):
        # Markdown and text are handed to LibreOffice as HTML: it reads that
        # reliably, and the alternative is a second document engine.
        page = _html_page(staged, ext, staged, work)
        return office_convert(page, target_ext, work, runner)
    if ext in ("html", "htm"):
        return office_convert(_cleaned_feed(staged, work), target_ext, work, runner)
    raise ConvertError("This kind of document can't be converted to that format")


_CHARSET = '<meta charset="utf-8">'


def _cleaned_feed(staged, work):
    """An HTML file cleaned for LibreOffice, which would otherwise load what it links to.

    In a folder of its own, so the file LibreOffice writes next to the
    others (``document.<ext>``) can never be this one.
    """
    with open(staged, "r", encoding="utf-8", errors="replace") as f:
        source = f.read()
    folder = os.path.join(work, "feed")
    os.makedirs(folder, exist_ok=True)
    feed = os.path.join(folder, "document.html")
    with open(feed, "w", encoding="utf-8") as f:
        f.write(htmlclean.clean(source, _CHARSET))
    return feed


def _to_html(staged, ext, work, runner):
    if ext in ("md", "markdown"):
        with open(staged, "r", encoding="utf-8", errors="replace") as f:
            body = markdown.to_html(f.read())
        out = os.path.join(work, "out.html")
        with open(out, "w", encoding="utf-8") as f:
            f.write(markdown.page(body, paths.stem(staged)))
        return out
    if ext in ("txt", "text"):
        with open(staged, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        out = os.path.join(work, "out.html")
        with open(out, "w", encoding="utf-8") as f:
            f.write(markdown.page("<pre>%s</pre>" % html.escape(text, quote=False),
                                  paths.stem(staged)))
        return out
    if ext in ("html", "htm"):
        return office_convert(_cleaned_feed(staged, work), "html", work, runner)
    return office_convert(staged, "html", work, runner)


def _to_text(staged, ext, work, runner):
    if ext in ("md", "markdown"):
        with open(staged, "r", encoding="utf-8", errors="replace") as f:
            text = markdown.plain_text(f.read())
        out = os.path.join(work, "out.txt")
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
        return out
    if ext in ("txt", "text"):
        out = os.path.join(work, "out.txt")
        shutil.copyfile(staged, out)
        return out
    if ext in ("html", "htm"):
        with open(staged, "r", encoding="utf-8", errors="replace") as f:
            text = html_to_text(f.read())
        out = os.path.join(work, "out.txt")
        with open(out, "w", encoding="utf-8") as f:
            f.write(text)
        return out
    return office_convert(staged, "txt", work, runner)


# ── HTML's words ─────────────────────────────────────────────────────────

_BLOCK = re.compile(r"</(p|div|h[1-6]|li|tr|blockquote|pre)>", re.I)
_BREAK = re.compile(r"<br\s*/?>", re.I)
_SCRIPT = re.compile(r"<(script|style)[^>]*>.*?</\1>", re.I | re.S)
_TAG = re.compile(r"<[^>]+>")


def html_to_text(source):
    """The words of an HTML file, one block per line."""
    text = _SCRIPT.sub("", source)
    text = _BREAK.sub("\n", text)
    text = _BLOCK.sub("\n", text)
    text = _TAG.sub("", text)
    text = html.unescape(text)
    lines = [line.strip() for line in text.splitlines()]
    out = []
    for line in lines:
        if line:
            out.append(line)
        elif out and out[-1] != "":
            out.append("")
    return "\n".join(out).strip() + "\n"

"""An HTML file made safe to print or to hand to LibreOffice.

Mirrors the Windows port's ``DocBrowser.CleanScript``: everything that would
make the browser or LibreOffice run code, load another file or reach the
network is taken out, and the words, headings, tables and links to the web
stay. The browser is also kept off the network by its flags (``docs.py``) and
LibreOffice by its proxy; this is the layer that doesn't depend on either.

Taken out:

* elements that run or embed something, with everything inside them --
  ``script``, ``noscript``, ``template``, ``iframe``, ``frameset``, ``object``,
  ``applet``, ``video``, ``audio``, ``portal`` -- and the empty ones that load
  something: ``link``, ``meta`` (refresh included), ``base``, ``embed``,
  ``frame``, ``source``, ``track``;
* every ``on…`` event handler;
* every attribute that names something to load (``src``, ``srcset``,
  ``poster``, ``background``, ``action``, ``xlink:href``, …), except a picture
  embedded as ``data:`` and a link (``a``/``area``) to the web, to an e-mail
  address or within the page;
* in CSS, ``@import`` and ``@font-face``, and every ``url()``, ``image()`` and
  ``image-set()``; a style that uses CSS escapes (which could spell any of
  those) is dropped whole.

Parsed with the standard library's HTML parser and written out again, rather
than edited with patterns: a pattern can be talked past (``<script >``,
``<SCRIPT/x>``, a handler on any element), a parser sees the elements and
attributes the browser will.
"""

from __future__ import annotations

import html
import re
from html.parser import HTMLParser

# Removed together with what is inside them.
DROP_WITH_CONTENT = frozenset({
    "script", "noscript", "template", "iframe", "frameset", "object", "applet",
    "video", "audio", "portal",
})
# Removed; they have no content.
DROP_EMPTY = frozenset({"link", "meta", "base", "embed", "frame", "source", "track"})
VOID = frozenset({
    "area", "base", "br", "col", "embed", "frame", "hr", "img", "input", "link", "meta",
    "param", "source", "track", "wbr",
})
# Attributes that name something to load.
URL_ATTRIBUTES = frozenset({
    "src", "srcset", "href", "poster", "data", "background", "action", "formaction", "cite",
    "longdesc", "lowsrc", "dynsrc", "codebase", "archive", "classid", "usemap", "manifest",
    "ping", "icon", "profile", "imagesrcset",
})
_LINK_SCHEMES = re.compile(r"^(https?:|mailto:|#)", re.I)
_ATTRIBUTE_NAME = re.compile(r"^[a-zA-Z_:][-a-zA-Z0-9_:.]*$")

_CSS_IMPORT = re.compile(r"@import\b[^;]*;?", re.I)
_CSS_FONT_FACE = re.compile(r"@font-face\s*\{[^}]*\}", re.I)
_CSS_FETCH = re.compile(r"(?:url|image|image-set|-webkit-image-set)\(\s*(?:\"[^\"]*\"|'[^']*'|[^)]*)\s*\)", re.I)


def clean_css(css):
    """CSS with nothing left that loads something, or "" when that can't be sure."""
    if "\\" in css:
        return ""
    css = _CSS_IMPORT.sub("", css)
    css = _CSS_FONT_FACE.sub("", css)
    css = _CSS_FETCH.sub("none", css)
    if re.search(r"@import|url\(|image\(|image-set\(", css, re.I):
        return ""
    return css


def _keep_attribute(tag, name, value):
    if not _ATTRIBUTE_NAME.match(name):
        return None
    if name.startswith("on"):
        return None
    if name == "style":
        cleaned = clean_css(value)
        return cleaned or None
    if name == "href" and tag in ("a", "area"):
        return value if _LINK_SCHEMES.match(value.strip()) else None
    if name == "src" and tag == "img":
        return value if value.strip().lower().startswith("data:image/") else None
    if name in URL_ATTRIBUTES or name.endswith(":href"):
        return None
    return value


class _Cleaner(HTMLParser):
    def __init__(self, head_extra):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.head_extra = head_extra
        self.injected = not head_extra
        self.skipping = None
        self.depth = 0
        self.in_style = False

    def _inject(self):
        if not self.injected:
            self.out.append(self.head_extra)
            self.injected = True

    def _start(self, tag, attrs, closed):
        if self.skipping is not None:
            if tag == self.skipping and not closed:
                self.depth += 1
            return
        if tag in DROP_WITH_CONTENT:
            if not closed and tag not in VOID:
                self.skipping, self.depth = tag, 1
            return
        if tag in DROP_EMPTY:
            return
        if tag not in ("html", "head"):
            # A document with no <head>: what goes into it goes before the first element.
            self._inject()
        parts = [tag]
        for name, value in attrs:
            name = name.lower()
            kept = _keep_attribute(tag, name, value or "")
            if kept is None and value is not None:
                continue
            if value is None:
                if _ATTRIBUTE_NAME.match(name) and not name.startswith("on") \
                        and name not in URL_ATTRIBUTES:
                    parts.append(name)
                continue
            parts.append('%s="%s"' % (name, html.escape(kept, quote=True)))
        self.out.append("<%s%s>" % (" ".join(parts), " /" if closed else ""))
        if tag == "head":
            self._inject()
        if tag == "style" and not closed:
            self.in_style = True

    def handle_starttag(self, tag, attrs):
        self._start(tag, attrs, False)

    def handle_startendtag(self, tag, attrs):
        self._start(tag, attrs, True)

    def handle_endtag(self, tag):
        if self.skipping is not None:
            if tag == self.skipping:
                self.depth -= 1
                if self.depth == 0:
                    self.skipping = None
            return
        if tag in DROP_WITH_CONTENT or tag in DROP_EMPTY:
            return
        if tag == "style":
            self.in_style = False
        self.out.append("</%s>" % tag)

    def handle_data(self, data):
        if self.skipping is not None:
            return
        if self.in_style:
            self.out.append(clean_css(data).replace("</", "<\\/"))
            return
        if data.strip():
            self._inject()
        self.out.append(html.escape(data, quote=False))

    def handle_decl(self, decl):
        if self.skipping is None and decl.lower().startswith("doctype"):
            self.out.append("<!%s>" % decl)

    # Comments, processing instructions and CDATA sections are dropped.
    def handle_comment(self, data):
        pass

    def handle_pi(self, data):
        pass

    def unknown_decl(self, data):
        pass

    def result(self):
        self.close()
        self._inject()
        return "".join(self.out)


def clean(source, head_extra=""):
    """The cleaned document; ``head_extra`` goes at the start of its <head>.

    Put first, a rule there (Convert's ``@page`` size) gives way to the
    document's own rules, which come after it.
    """
    cleaner = _Cleaner(head_extra)
    # A byte-order mark read as text would come before <!DOCTYPE> and put the
    # page in quirks mode.
    cleaner.feed(source.lstrip("\ufeff"))
    return cleaner.result()

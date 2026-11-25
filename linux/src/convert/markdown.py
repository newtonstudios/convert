"""Markdown to HTML, for the document conversions.

Covers the common syntax -- headings, bold, italic, inline code, code blocks,
lists (including task lists), tables, quotes, links and rules -- which is what
``Markdown.swift`` covers on the Mac. Footnotes, HTML inside Markdown and
images are not rendered, and the README says so.

Kept as its own module because both "Markdown to PDF" and "Markdown to Word"
go through the HTML this produces.
"""

from __future__ import annotations

import html
import re

_INLINE_CODE = re.compile(r"`([^`]+)`")
_BOLD = re.compile(r"\*\*(.+?)\*\*|__(.+?)__")
_ITALIC = re.compile(r"(?<![\*\w])\*([^*]+)\*(?!\*)|(?<![\w_])_([^_]+)_(?![\w_])")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_STRIKE = re.compile(r"~~(.+?)~~")


def _inline(text):
    """One line of Markdown as HTML."""
    out = html.escape(text, quote=False)
    # Code first: a `*` inside backticks is a star, not emphasis.
    placeholders = []

    def keep_code(match):
        placeholders.append("<code>%s</code>" % html.escape(match.group(1), quote=False))
        return "\x00%d\x00" % (len(placeholders) - 1)

    out = _INLINE_CODE.sub(keep_code, out)
    out = _BOLD.sub(lambda m: "<strong>%s</strong>" % (m.group(1) or m.group(2)), out)
    out = _ITALIC.sub(lambda m: "<em>%s</em>" % (m.group(1) or m.group(2)), out)
    out = _STRIKE.sub(lambda m: "<del>%s</del>" % m.group(1), out)
    # The line was escaped as a whole, so the URL arrives with its "&" already
    # escaped; unescaping it first keeps the query string from being escaped
    # twice ("&amp;amp;" is not a query string).
    out = _LINK.sub(lambda m: '<a href="%s">%s</a>'
                    % (html.escape(html.unescape(m.group(2)), quote=True), m.group(1)), out)
    for i, code in enumerate(placeholders):
        out = out.replace("\x00%d\x00" % i, code)
    return out


def _table(rows):
    """A table out of its lines, with the second line being the alignment row."""
    def cells(line):
        return [c.strip() for c in line.strip().strip("|").split("|")]

    head = cells(rows[0])
    aligns = []
    for spec in cells(rows[1]) if len(rows) > 1 else []:
        spec = spec.strip()
        if spec.endswith(":") and spec.startswith(":"):
            aligns.append("center")
        elif spec.endswith(":"):
            aligns.append("right")
        else:
            aligns.append("left")
    out = ["<table>", "<thead><tr>"]
    for i, cell in enumerate(head):
        align = aligns[i] if i < len(aligns) else "left"
        out.append('<th style="text-align:%s">%s</th>' % (align, _inline(cell)))
    out.append("</tr></thead><tbody>")
    for row in rows[2:]:
        out.append("<tr>")
        for i, cell in enumerate(cells(row)):
            align = aligns[i] if i < len(aligns) else "left"
            out.append('<td style="text-align:%s">%s</td>' % (align, _inline(cell)))
        out.append("</tr>")
    out += ["</tbody></table>"]
    return "".join(out)


def to_html(text):
    """The body of a page for this Markdown."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out = []
    i = 0
    list_kind = None       # "ul", "ol" or None
    in_quote = False
    paragraph = []

    def flush_paragraph():
        if paragraph:
            out.append("<p>%s</p>" % _inline(" ".join(paragraph)))
            del paragraph[:]

    def close_list():
        nonlocal list_kind
        if list_kind:
            out.append("</%s>" % list_kind)
            list_kind = None

    def close_quote():
        nonlocal in_quote
        if in_quote:
            out.append("</blockquote>")
            in_quote = False

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # A fenced code block, to its closing fence or the end.
        if stripped.startswith("```") or stripped.startswith("~~~"):
            flush_paragraph()
            close_list()
            close_quote()
            fence = stripped[:3]
            language = stripped[3:].strip()
            i += 1
            code = []
            while i < len(lines) and not lines[i].strip().startswith(fence):
                code.append(lines[i])
                i += 1
            i += 1
            cls = ' class="language-%s"' % html.escape(language) if language else ""
            out.append("<pre><code%s>%s</code></pre>"
                       % (cls, html.escape("\n".join(code), quote=False)))
            continue

        if not stripped:
            flush_paragraph()
            close_list()
            close_quote()
            i += 1
            continue

        # A horizontal rule.
        if re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", stripped):
            flush_paragraph()
            close_list()
            out.append("<hr>")
            i += 1
            continue

        heading = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if heading:
            flush_paragraph()
            close_list()
            close_quote()
            level = len(heading.group(1))
            out.append("<h%d>%s</h%d>" % (level, _inline(heading.group(2)), level))
            i += 1
            continue

        # A table: a header row, then the |---|---| line under it.
        if (stripped.startswith("|") and i + 1 < len(lines)
                and re.fullmatch(r"\|?[\s:|-]+\|?", lines[i + 1].strip())
                and "-" in lines[i + 1]):
            flush_paragraph()
            close_list()
            close_quote()
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(lines[i])
                i += 1
            out.append(_table(rows))
            continue

        if stripped.startswith(">"):
            flush_paragraph()
            close_list()
            if not in_quote:
                out.append("<blockquote>")
                in_quote = True
            out.append("<p>%s</p>" % _inline(stripped.lstrip("> ").strip()))
            i += 1
            continue
        close_quote()

        item = re.match(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$", line)
        if item:
            flush_paragraph()
            kind = "ol" if item.group(2)[0].isdigit() else "ul"
            if list_kind != kind:
                close_list()
                out.append("<%s>" % kind)
                list_kind = kind
            body = item.group(3)
            task = re.match(r"^\[([ xX])\]\s+(.*)$", body)
            if task:
                box = "&#9745;" if task.group(1).lower() == "x" else "&#9744;"
                body = "%s %s" % (box, task.group(2))
            out.append("<li>%s</li>" % _inline(body))
            i += 1
            continue
        close_list()

        paragraph.append(stripped)
        i += 1

    flush_paragraph()
    close_list()
    close_quote()
    return "\n".join(out)


# The paper the document is printed on. The browser prints at this size because
# of the @page rule, which is the one way to set it from a page.
PAPER = {True: "A4", False: "Letter"}


def page(body, title="", paper_a4=True):
    """A whole printable page: the body with the styles a document needs."""
    return """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>%(title)s</title>
<style>
  @page { size: %(paper)s; margin: 20mm; }
  body { font-family: "DejaVu Serif", "Liberation Serif", Georgia, serif;
         font-size: 11pt; line-height: 1.5; color: #1a1a1a; }
  h1, h2, h3, h4, h5, h6 { font-family: "DejaVu Sans", "Liberation Sans", sans-serif;
         line-height: 1.25; margin: 1.2em 0 0.4em; }
  h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.2em; }
  p { margin: 0.6em 0; }
  code, pre { font-family: "DejaVu Sans Mono", "Liberation Mono", monospace; font-size: 0.9em; }
  pre { background: #f4f4f4; padding: 0.7em; overflow-wrap: anywhere; white-space: pre-wrap; }
  blockquote { margin: 0.8em 0; padding-left: 0.9em; border-left: 3px solid #d0d0d0; color: #444; }
  table { border-collapse: collapse; margin: 0.8em 0; width: 100%%; }
  th, td { border: 1px solid #d0d0d0; padding: 0.35em 0.5em; text-align: left; }
  th { background: #f0f0f0; }
  hr { border: none; border-top: 1px solid #d0d0d0; margin: 1.2em 0; }
  img { max-width: 100%%; }
  a { color: #0b57d0; }
</style>
</head>
<body>
%(body)s
</body>
</html>
""" % {"title": html.escape(title, quote=False), "body": body,
                    "paper": PAPER[bool(paper_a4)]}


def plain_text(markdown):
    """The words of a Markdown file as plain text (for Markdown to Plain Text)."""
    text = markdown
    text = re.sub(r"```.*?```", lambda m: m.group(0).strip("`").strip("\n"), text, flags=re.S)
    text = re.sub(r"^(#{1,6})\s+", "", text, flags=re.M)
    text = re.sub(r"^\s*>\s?", "", text, flags=re.M)
    text = _BOLD.sub(lambda m: m.group(1) or m.group(2), text)
    text = _ITALIC.sub(lambda m: m.group(1) or m.group(2), text)
    text = _LINK.sub(lambda m: "(%s)" % m.group(1), text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"^\s*([-*+]|\d+[.)])\s+", "", text, flags=re.M)
    text = re.sub(r"^\s*\|.*\|\s*$", "", text, flags=re.M)
    return text.strip() + "\n"

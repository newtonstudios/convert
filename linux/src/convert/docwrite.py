"""Writing Word, ODT and RTF out of plain paragraphs.

"PDF to Word" on every platform carries over the TEXT: paragraphs put back
together, with the page layout, tables and pictures left behind. The Mac writes
those files with AppKit and the Windows port with its own writers; this is the
same idea, small enough to read, and it means the PDF conversions don't need
LibreOffice installed at all.

Each writer takes a list of paragraphs and writes one file. They are called
from ``pdfs.py`` (a PDF's text) and from the tests.
"""

from __future__ import annotations

import html
import zipfile

_CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
"""

_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"""

_ODT_MANIFEST = """<?xml version="1.0" encoding="UTF-8"?>
<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
  <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.text"/>
  <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
  <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
</manifest:manifest>
"""

_ODT_STYLES = """<?xml version="1.0" encoding="UTF-8"?>
<office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    office:version="1.2">
  <office:styles>
    <style:style style:name="Standard" style:family="paragraph" style:class="text">
      <style:paragraph-properties fo:margin-bottom="0.2cm"
          xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"/>
    </style:style>
  </office:styles>
</office:document-styles>
"""


def split_paragraphs(text):
    """Lines of extracted text back into paragraphs.

    A blank line ends a paragraph; lines inside one are joined with a space,
    because a PDF breaks a sentence at the edge of the page rather than at the
    edge of the thought.
    """
    paragraphs = []
    current = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        stripped = line.strip()
        if stripped:
            current.append(stripped)
        elif current:
            paragraphs.append(" ".join(current))
            current = []
    if current:
        paragraphs.append(" ".join(current))
    return paragraphs


def write_docx(path, paragraphs):
    """A DOCX holding these paragraphs, one per line."""
    body = []
    for text in paragraphs or [""]:
        body.append('<w:p><w:r><w:t xml:space="preserve">%s</w:t></w:r></w:p>'
                    % html.escape(text, quote=False))
    document = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>%s<w:sectPr/></w:body>
</w:document>
""" % "".join(body)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", _CONTENT_TYPES)
        z.writestr("_rels/.rels", _RELS)
        z.writestr("word/document.xml", document)


def write_odt(path, paragraphs):
    """An ODT holding these paragraphs."""
    body = "".join('<text:p text:style-name="Standard">%s</text:p>'
                   % html.escape(text, quote=False) for text in (paragraphs or [""]))
    content = """<?xml version="1.0" encoding="UTF-8"?>
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
    office:version="1.2">
  <office:body><office:text>%s</office:text></office:body>
</office:document-content>
""" % body
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        # The mimetype entry has to be first and stored, not deflated, or
        # LibreOffice refuses to recognise the file.
        z.writestr(zipfile.ZipInfo("mimetype"), "application/vnd.oasis.opendocument.text",
                   compress_type=zipfile.ZIP_STORED)
        z.writestr("content.xml", content)
        z.writestr("styles.xml", _ODT_STYLES)
        z.writestr("META-INF/manifest.xml", _ODT_MANIFEST)


def write_rtf(path, paragraphs):
    """An RTF holding these paragraphs."""
    def escape(text):
        out = []
        for ch in text:
            if ch in "\\{}":
                out.append("\\" + ch)
            elif ord(ch) < 128:
                out.append(ch)
            else:
                # RTF's escape for anything outside ASCII: signed 16-bit code
                # unit, with a fallback character for readers that lack it.
                code = ord(ch)
                if code > 0xFFFF:
                    code -= 0x10000
                    high = 0xD800 + (code >> 10)
                    low = 0xDC00 + (code & 0x3FF)
                    out.append("\\u%d?\\u%d?" % (high - 0x10000 if high > 0x7FFF else high,
                                                 low - 0x10000 if low > 0x7FFF else low))
                else:
                    out.append("\\u%d?" % (code - 0x10000 if code > 0x7FFF else code))
        return "".join(out)

    body = "\\par\n".join(escape(text) for text in (paragraphs or [""]))
    rtf = ("{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\froman DejaVu Serif;}}"
           "\\f0\\fs22 " + body + "\\par}")
    with open(path, "w", encoding="ascii", errors="replace") as f:
        f.write(rtf)

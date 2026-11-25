#!/usr/bin/env python3
"""Writes a small PDF with real text in it, for the smoke test.

Why not make it with a tool: the point of the PDF formats is that they work
without anything installed, and the machine running the tests may have neither
a browser nor LibreOffice. This is a minimal, valid PDF written by hand, so
`pdftotext` and `pdftoppm` have something known to work on anywhere.

    python3 pdf_sample.py out.pdf [pages]
"""

import sys
import zlib


def _stream(text):
    content = ("BT /F1 18 Tf 64 760 Td 22 TL\n"
               + "".join("(%s) Tj T*\n" % line.replace("(", "\\(").replace(")", "\\)")
                         for line in text)
               + "ET\n")
    data = zlib.compress(content.encode("latin-1"))
    return b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(data) + data + b"\nendstream"


def build(page_texts):
    count = len(page_texts)
    # 1 catalog, 2 pages, 3..2+count the pages, then the font, then a stream per page.
    font_object = 3 + count
    objects = []
    objects.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    kids = " ".join("%d 0 R" % (3 + i) for i in range(count))
    objects.append(("<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, count)).encode())
    for i in range(count):
        objects.append(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
                        "/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>"
                        % (font_object, font_object + 1 + i)).encode())
    objects.append(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    for text in page_texts:
        objects.append(_stream(text))

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += (b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objects) + 1, xref))
    return bytes(out)


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = argv[1]
    pages = int(argv[2]) if len(argv) > 2 else 2
    texts = [["Convert sample PDF", "", "Page %d of %d" % (i + 1, pages),
              "This page has text that can be extracted."] for i in range(pages)]
    with open(path, "wb") as f:
        f.write(build(texts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

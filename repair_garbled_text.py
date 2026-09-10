"""
Repairs text that was corrupted by the confluence_extractor.ps1 encoding bug
(fixed in Invoke-ConfluenceApi): PowerShell decoded Confluence's UTF-8
response bytes as Windows-1252 before writing content.html, turning accents,
curly quotes, dashes etc. into garbage like "Ã©" or "â€™" or "Â ".

That mis-decode is a byte-for-byte, reversible mapping - re-encoding the
garbled text as Windows-1252 recovers the original UTF-8 bytes, which then
decode cleanly. This script does that to every already-extracted/converted
file, in place, so you don't have to re-pull the whole space from
Confluence. Only worth running against content produced by the .ps1
extractor before the fix - the Python extractor was never affected.

Usage:
    python repair_garbled_text.py [root_dir ...]

Defaults to confluence_export/ and confluence_markdown_export/ if no paths
are given. Walks every .html and .md file under each root. Files that
aren't actually garbled are left untouched (the round-trip only succeeds
on genuinely corrupted text - see repair_text below). Each file it does
change gets a .bak backup alongside it first.
"""

import sys
from pathlib import Path

DEFAULT_ROOTS = ["confluence_export", "confluence_markdown_export"]
FILE_PATTERNS = ("*.html", "*.md")

# Python's stdlib "cp1252" codec follows the strict Unicode.org table, which
# leaves 5 byte values (0x81, 0x8D, 0x8F, 0x90, 0x9D) undefined and refuses
# to encode/decode them. Windows' actual Windows-1252 - what PowerShell/.NET
# used when it mis-decoded the extractor's responses - fills those in as
# their Latin-1 equivalents instead of rejecting them. Build the real table
# so a repair round-trip doesn't choke on text containing one of those
# 5 byte values.
_CP1252_GAPS = {0x81, 0x8D, 0x8F, 0x90, 0x9D}
_CHAR_TO_BYTE = {
    (chr(byte) if byte in _CP1252_GAPS else bytes([byte]).decode("cp1252")): byte
    for byte in range(256)
}


def _windows_1252_encode(text):
    """Like text.encode('cp1252') but matching Windows' actual table
    (see _CP1252_GAPS above). Raises UnicodeEncodeError, like the stdlib
    version, for any character outside the Windows-1252 repertoire."""
    try:
        return bytes(_CHAR_TO_BYTE[ch] for ch in text)
    except KeyError as e:
        raise UnicodeEncodeError("windows-1252", text, 0, len(text), str(e)) from None


def repair_text(text, max_passes=4):
    """Undoes one or more rounds of UTF-8 -> Windows-1252 mis-decoding.

    A genuine mis-decode always expands the text (each original multi-byte
    UTF-8 character becomes several single-byte cp1252 characters), so a
    real repair pass strictly shortens it. Encoding back to cp1252 raises
    on any character outside its repertoire, which is exactly what happens
    to correctly-decoded prose containing real accents/dashes/quotes - that
    failure is what keeps this from mangling text that was never broken.

    Runs more than one pass to handle content that went through the buggy
    pipeline twice, stopping as soon as a pass fails or stops helping.
    """
    current = text
    passes = 0
    for _ in range(max_passes):
        try:
            candidate = _windows_1252_encode(current).decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            break
        if len(candidate) >= len(current):
            break
        current = candidate
        passes += 1
    return current, passes


def main():
    roots = [Path(p) for p in (sys.argv[1:] or DEFAULT_ROOTS)]

    # Say exactly where this is about to look, before doing anything -
    # otherwise the only feedback is a final "Fixed 0 of 0 files," which
    # looks identical whether nothing needed fixing or this just ran from
    # the wrong folder and found nothing at all.
    print("Looking for garbled .html/.md files in:")
    for root in roots:
        note = "" if root.exists() else "  <- doesn't exist, skipping"
        print(f"  {root.resolve()}{note}")
    print()

    files = []
    for root in roots:
        if not root.exists():
            continue
        for pattern in FILE_PATTERNS:
            files.extend(root.rglob(pattern))

    if not files:
        print("No .html or .md files found in the folder(s) above.")
        print("If your confluence_export/confluence_markdown_export folders are")
        print("somewhere else, either run this script from that location instead,")
        print("or pass the path(s) directly, e.g.:")
        print("    python repair_garbled_text.py C:\\path\\to\\confluence_export")
        return

    fixed_count = 0
    unreadable = []

    for file_path in sorted(files):
        try:
            original = file_path.read_text(encoding="utf-8")
        except UnicodeDecodeError as e:
            unreadable.append(f"{file_path}: {e}")
            continue

        repaired, passes = repair_text(original)
        if passes == 0:
            continue

        backup_path = file_path.with_name(file_path.name + ".bak")
        if not backup_path.exists():
            backup_path.write_text(original, encoding="utf-8")

        file_path.write_text(repaired, encoding="utf-8")
        fixed_count += 1
        print(f"Fixed ({passes} pass{'es' if passes != 1 else ''}): {file_path}")

    print(f"\nDone. Fixed {fixed_count} of {len(files)} file(s).")
    if fixed_count:
        print("Originals saved next to each as *.bak - spot-check a few repaired")
        print("files, then delete the .bak files once you're happy with them.")
    if unreadable:
        print(f"\n{len(unreadable)} file(s) couldn't even be read as UTF-8, skipped:")
        for warning in unreadable:
            print(f"  - {warning}")


if __name__ == "__main__":
    main()

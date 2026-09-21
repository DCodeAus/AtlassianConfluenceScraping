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
    python repair_garbled_text.py --force

Defaults to confluence_export/ and confluence_markdown_export/ if no paths
are given. Walks every .html and .md file under each root. Files that
aren't actually garbled are left untouched (the round-trip only succeeds
on genuinely corrupted text - see repair_text below). Each file it does
change gets a .bak backup alongside it first.

If a file still looks garbled afterwards (the original bytes are gone,
usually because something altered them further before this script ever
saw them), --force additionally offers to strip the leftover character -
a safe-looking guess, not a guaranteed fix, which is why it's opt-in and
requires both --force AND typing "YOLO" when asked. Every file it strips
gets logged, with a snippet and timestamp, to
garbled_text_repair_log.json.
"""

import json
import re
import sys
from datetime import datetime, timezone
from itertools import groupby
from pathlib import Path

DEFAULT_ROOTS = ["confluence_export", "confluence_markdown_export"]
FILE_PATTERNS = ("*.html", "*.md")

# Telltale leftovers of this mis-decode bug that repair_text couldn't (or
# didn't) resolve - "Ã" and "â€" are how it mangles most accented letters
# and curly quotes/dashes, "Â" is what it leaves in front of a stray
# non-breaking space, and U+FFFD is what shows up if a file got corrupted
# badly enough that even a correct decode can't recover real characters.
# Real text occasionally contains a genuine "Â" or "Ã" (e.g. French), so a
# hit here is a "go take a look", not proof the file is still broken.
_SUSPICIOUS_LEFTOVERS = re.compile("Ã|Â|â€|�")

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
_BYTE_TO_CHAR = {byte: ch for ch, byte in _CHAR_TO_BYTE.items()}


def _windows_1252_encode(text):
    """Like text.encode('cp1252') but matching Windows' actual table
    (see _CP1252_GAPS above). Raises UnicodeEncodeError, like the stdlib
    version, for any character outside the Windows-1252 repertoire."""
    try:
        return bytes(_CHAR_TO_BYTE[ch] for ch in text)
    except KeyError as e:
        raise UnicodeEncodeError("windows-1252", text, 0, len(text), str(e)) from None


def _decode_utf8_partial(data):
    """Decodes bytes as UTF-8, but a single byte sequence that doesn't form
    a valid character (one genuinely unrecoverable spot, like a
    non-breaking space whose second byte got altered before this script
    ever saw it) doesn't have to block decoding everything else in the
    data - unlike bytes.decode(), which fails the whole thing on the first
    bad sequence it hits. Whatever can't be decoded as UTF-8 is kept in its
    original Windows-1252 form and decoding continues from right after
    it."""
    parts = []
    pos = 0
    while pos < len(data):
        try:
            # Try decoding everything from here to the end in one go.
            parts.append(data[pos:].decode("utf-8"))
            pos = len(data)
        except UnicodeDecodeError as e:
            # That failed somewhere in the middle. e.start/e.end are
            # positions WITHIN data[pos:] (not the whole data), marking
            # exactly the bad byte(s) it choked on. So: keep whatever
            # decoded fine before that point, keep the bad byte(s) as
            # their original Windows-1252 character instead of guessing,
            # then loop around and try again starting right after them.
            if e.start > 0:
                parts.append(data[pos:pos + e.start].decode("utf-8"))
            bad_start, bad_end = pos + e.start, pos + e.end
            parts.append("".join(_BYTE_TO_CHAR[b] for b in data[bad_start:bad_end]))
            pos = bad_end
    return "".join(parts)


def _split_encodable_runs(text):
    """Breaks text into alternating runs of "every character here is
    something Windows-1252 can represent" and "this run has at least one
    character that isn't". A character outside cp1252's repertoire - an
    emoji, a tick mark, a name in another script - can't have come from
    the mis-decode bug (that bug only ever produces cp1252 characters), so
    splitting it into its own run stops it from blocking the repair of
    everything around it."""
    # groupby only merges *consecutive* characters that share the same
    # key (here: "is this character encodable?"), starting a new group
    # the moment that answer flips - which is exactly the alternating
    # runs this function is meant to produce.
    return [
        ("".join(group), is_encodable)
        for is_encodable, group in groupby(text, key=lambda ch: ch in _CHAR_TO_BYTE)
    ]


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
        any_run_improved = False
        rebuilt = []
        for run, is_encodable in _split_encodable_runs(current):
            if not is_encodable:
                rebuilt.append(run)
                continue
            # Every character in this run is Windows-1252-encodable by
            # construction (see _split_encodable_runs), so this can't raise.
            candidate = _decode_utf8_partial(_windows_1252_encode(run))
            if len(candidate) < len(run):
                rebuilt.append(candidate)
                any_run_improved = True
            else:
                rebuilt.append(run)
        if not any_run_improved:
            break
        current = "".join(rebuilt)
        passes += 1
    return current, passes


def main():
    args = sys.argv[1:]
    force = "--force" in args
    roots = [Path(p) for p in ([a for a in args if a != "--force"] or DEFAULT_ROOTS)]

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
    still_suspicious = []

    for file_path in sorted(files):
        try:
            original = file_path.read_text(encoding="utf-8")
        except UnicodeDecodeError as e:
            unreadable.append(f"{file_path}: {e}")
            continue

        repaired, passes = repair_text(original)
        final_text = repaired if passes else original

        if passes:
            backup_path = file_path.with_name(file_path.name + ".bak")
            if not backup_path.exists():
                backup_path.write_text(original, encoding="utf-8")

            file_path.write_text(repaired, encoding="utf-8")
            fixed_count += 1
            print(f"Fixed ({passes} pass{'es' if passes != 1 else ''}): {file_path}")

        # Health check: whether this file got fixed, partially fixed, or
        # left alone, does what's actually on disk now still look
        # garbled? Catches the cases repair_text can't resolve on its own
        # (like a corrupted character that got altered further by
        # something else before this script ever saw it). Every matching
        # spot is collected, not just the first, so the summary below
        # doesn't understate how many are there.
        leftover_matches = list(_SUSPICIOUS_LEFTOVERS.finditer(final_text))
        if leftover_matches:
            snippets = []
            for leftover_match in leftover_matches[:3]:
                start = max(0, leftover_match.start() - 20)
                end = min(len(final_text), leftover_match.end() + 20)
                snippets.append(final_text[start:end])
            still_suspicious.append((file_path, len(leftover_matches), snippets))

    print(f"\nDone. Fixed {fixed_count} of {len(files)} file(s).")
    if fixed_count:
        print("Originals saved next to each as *.bak - spot-check a few repaired")
        print("files, then delete the .bak files once you're happy with them.")
    if unreadable:
        print(f"\n{len(unreadable)} file(s) couldn't even be read as UTF-8, skipped:")
        for warning in unreadable:
            print(f"  - {warning}")

    if still_suspicious:
        print(f"\nHealth check: {len(still_suspicious)} file(s) still contain something")
        print("that looks like leftover garbled text (or, occasionally, genuine")
        print("accented text that just happens to match - worth a quick look either way):")
        for file_path, count, snippets in still_suspicious:
            print(f"  - {file_path} ({count} spot{'s' if count != 1 else ''})")
            for snippet in snippets:
                print(f"      ...{snippet}...")
            not_shown = count - len(snippets)
            if not_shown > 0:
                print(f"      ...and {not_shown} more")

        print("\nRecommended next step: re-extract just these pages from Confluence")
        print("rather than editing them by hand - the original bytes for these ones")
        print("are gone, so this is the only way to get the real text back. Find the")
        print("page's id in confluence_export/manifest.json, then run")
        print("confluence_extractor.py again and enter that id when it asks for a")
        print("Page ID (leave it blank and it re-pulls the whole space instead).")
        print()
        print("If you'd rather not re-extract, most of these are a stray leftover")
        print("character next to a space that's safe to just delete - but that's a")
        print("guess, not a certainty, so it's not done automatically.")
        if not force:
            print("Re-run this script with --force if you want the option to strip them.")
        else:
            print("To live dangerously and strip these leftover characters from the")
            print("file(s) above right now, type YOLO and press Enter. Anything else")
            print("leaves them untouched.")
            confirmation = input("Strip leftover characters: ").strip()
            if confirmation == "YOLO":
                log_path = Path("garbled_text_repair_log.json")
                log_entries = []
                if log_path.exists():
                    try:
                        log_entries = json.loads(log_path.read_text(encoding="utf-8"))
                    except json.JSONDecodeError:
                        # Only this script ever writes this file, so a parse
                        # failure here means it was hand-edited or damaged
                        # somehow - rather than crash the whole run over a
                        # log file, start a fresh one and keep going.
                        print(f"Couldn't read the existing {log_path} (it may be corrupted) - starting a fresh log.")
                        log_entries = []

                for file_path, count, snippets in still_suspicious:
                    stripped_backup_path = file_path.with_name(file_path.name + ".stripped.bak")
                    current_content = file_path.read_text(encoding="utf-8")
                    if not stripped_backup_path.exists():
                        stripped_backup_path.write_text(current_content, encoding="utf-8")
                    stripped = _SUSPICIOUS_LEFTOVERS.sub("", current_content)
                    file_path.write_text(stripped, encoding="utf-8")
                    print(f"Stripped: {file_path}")

                    log_entries.append({
                        "file": str(file_path),
                        "count": count,
                        "snippet": snippets[0],
                        "strippedAt": datetime.now(timezone.utc).astimezone().isoformat(),
                    })

                log_path.write_text(json.dumps(log_entries, indent=2), encoding="utf-8")
                print(f"Done. Pre-strip versions saved as *.stripped.bak, logged to {log_path}.")
            else:
                print("Left untouched.")


if __name__ == "__main__":
    main()

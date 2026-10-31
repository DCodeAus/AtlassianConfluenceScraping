"""
Pulls one table off one Confluence page and writes it out as a CSV, ready
for SharePoint's own "Create list from CSV/Excel" import. Stdlib only.

For a page that's really just a table (an on-call register, say) this is
usually a better fit in SharePoint as a proper List than as a wiki-style
page - filterable, sortable, a Calendar view if it's date-based, and you
can wire up a Power Automate flow against it. Creating that List doesn't
need any API access though, SharePoint can build one straight from a CSV
through its own UI, no Entra ID app registration involved. So this script
only does the local half: read the table out of Confluence's storage HTML,
write it as a clean CSV. You do the SharePoint side yourself.

Reads manifest.json from confluence_extractor (either version), so run
that first.

    python confluence_table_to_csv.py "On Call Register"
    python confluence_table_to_csv.py 123456789   (page id also works)

Leave off the title/id and it'll just ask for it instead - no need to
already know how command-line arguments work.

Also asks which export folder this is for and where to put the CSV,
defaulting to confluence_export / confluence_table_export - give it the
same export folder name you gave confluence_extractor for whichever space
this is. Set CONFLUENCE_EXPORT_DIR and CONFLUENCE_TABLE_EXPORT_DIR to fix
both in advance for unattended runs.
"""

import csv
import os
import re
import sys
import xml.etree.ElementTree as ET

# Everything the scripts here have in common - the questions, reading an
# export folder, making sense of Confluence's page HTML - lives in
# confluence_common.py, so a fix there fixes every script at once. It has
# to be in the same folder as this one.
try:
    from confluence_common import (
        NAMESPACE_DECLARATIONS, ask_export_dir, escape_non_xml_entities,
        input_with_help, load_export_manifest, local_name,
        normalise_relative_path, sanitise_filename, suggest_output_dir,
    )
except ImportError:
    print("Can't find confluence_common.py (or it's out of date) - it needs to be")
    print("in the same folder as this script. Download the whole repository")
    print("rather than just this one file.")
    raise SystemExit(1)

# EXPORT_DIR / TABLE_EXPORT_DIR are set inside main() instead of here,
# since which export to use is asked at runtime rather than hardcoded -
# see the comment there.
EXPORT_DIR = "confluence_export"
TABLE_EXPORT_DIR = "confluence_table_export"

def convert_node_to_text(elem):
    """Plain text only - a CSV cell has no room for links/formatting, just
    the visible words. <p>/<br> become line breaks within the cell, which
    extract_cell_text below then flattens to a single readable line."""
    parts = []
    if elem.text:
        parts.append(elem.text)

    for child in list(elem):
        tag = local_name(child.tag)
        if tag == "br":
            parts.append("\n")
        elif tag == "p":
            parts.append("\n" + convert_node_to_text(child) + "\n")
        else:
            parts.append(convert_node_to_text(child))
        if child.tail:
            parts.append(child.tail)

    return "".join(parts)


def extract_cell_text(cell):
    text = convert_node_to_text(cell).strip()
    # Collapse a cell with multiple paragraphs/line breaks down to one
    # readable line rather than an embedded multi-line CSV field.
    return re.sub(r"\s*\n\s*", "; ", text)


def extract_tables(root_element):
    """Every <table> on the page, each as a list of rows (list of cell
    strings), first row assumed to be the header - same assumption the
    other converters make."""
    tables = []
    for table_elem in root_element.iter():
        if local_name(table_elem.tag) != "table":
            continue

        rows = []
        table_rows = [e for e in table_elem.iter() if local_name(e.tag) == "tr"]
        for table_row in table_rows:
            cells = [c for c in table_row if local_name(c.tag) in ("th", "td")]
            rows.append([extract_cell_text(c) for c in cells])

        if rows:
            tables.append(rows)

    return tables


def find_page(manifest, query):
    normalised_query = query.strip().lower()
    for page_entry in manifest:
        if str(page_entry["id"]) == query.strip():
            return page_entry
        if page_entry["title"].strip().lower() == normalised_query:
            return page_entry
    return None


def main():
    # A title/id on the command line skips the prompt (handy for
    # scripting); otherwise just ask, and keep asking until something's
    # actually given - matches every other script here, none of them
    # expect you to already know about command-line args.
    if len(sys.argv) >= 2:
        query = sys.argv[1]
    else:
        query = ""
        while not query:
            query = input_with_help(
                "Which page? (title or id): ",
                [
                    "Type the page's exact title as it appears in Confluence (not case",
                    "sensitive), e.g. On Call Register - or its numeric page id, which",
                    "you can find in the page's URL, e.g. .../pages/123456789/Page+Title",
                    "means the id is 123456789. Either one works.",
                ],
            ).strip()

    global EXPORT_DIR, TABLE_EXPORT_DIR

    # Asked every run rather than hardcoded, so pulling a table from a
    # second space's export just means answering this differently - give
    # it the exact same name you gave the extractor for that space. Set
    # CONFLUENCE_EXPORT_DIR for unattended runs.
    EXPORT_DIR = ask_export_dir(
        "Export folder (blank for 'confluence_export'): ",
        [
            "Which extraction this is for - the exact folder name you gave",
            "(or accepted the default for) when running",
            "confluence_extractor.py/.ps1 for this space.",
            "Leave blank for: confluence_export",
        ],
    )

    # Suggest a matching output folder name, same idea as the other
    # scripts, so a second space's table CSV doesn't land in (and
    # overwrite) the first one's.
    suggested_table_export_dir = suggest_output_dir(EXPORT_DIR, "confluence_table_export")

    TABLE_EXPORT_DIR = os.environ.get("CONFLUENCE_TABLE_EXPORT_DIR") or input_with_help(
        f"Output folder (blank for '{suggested_table_export_dir}'): ",
        [
            "Where the CSV should go.",
            f"Leave blank for: {suggested_table_export_dir}",
        ],
    ).strip() or suggested_table_export_dir

    manifest, manifest_path = load_export_manifest(EXPORT_DIR)

    page_entry = find_page(manifest, query)
    if page_entry is None:
        print(f"No page found matching '{query}' (checked by title and id).")
        print("Check the exact title (or id) in confluence_export/manifest.json.")
        return

    relative_folder = normalise_relative_path(page_entry["folder"])
    html_path = os.path.join(EXPORT_DIR, relative_folder, page_entry["html_file"])

    if not os.path.exists(html_path):
        print(f"content.html not found at {html_path}.")
        return

    with open(html_path, "r", encoding="utf-8") as f:
        raw_html = f.read()

    raw_html = escape_non_xml_entities(raw_html)
    wrapped_html = f"<root {NAMESPACE_DECLARATIONS}>{raw_html}</root>"
    root_element = ET.fromstring(wrapped_html)

    tables = extract_tables(root_element)

    if not tables:
        print(f"No tables found on page '{page_entry['title']}'.")
        return

    os.makedirs(TABLE_EXPORT_DIR, exist_ok=True)
    safe_title = sanitise_filename(page_entry["title"])

    for index, rows in enumerate(tables, start=1):
        suffix = "" if len(tables) == 1 else f"_table_{index}"
        output_path = os.path.join(TABLE_EXPORT_DIR, f"{safe_title}{suffix}.csv")

        # utf-8-sig, not utf-8: Excel (and SharePoint's CSV import, which
        # goes through the same engine) needs the BOM to reliably detect
        # UTF-8 rather than misreading accented/special characters - the
        # same class of encoding bug this whole project already ran into
        # once with the old PowerShell extractor.
        with open(output_path, "w", newline="", encoding="utf-8-sig") as f:
            csv.writer(f).writerows(rows)

        data_row_count = len(rows) - 1
        print(f"Wrote {data_row_count} row(s) (plus header) to {output_path}")

    print("\nIn SharePoint: Create list -> From CSV/Excel, point it at that file.")
    print("Every column comes in as plain text - if you want a real Person or")
    print("Date column (profile photos, calendar view, etc.), change the")
    print("column type after import. The CSV itself can't carry that.")


if __name__ == "__main__":
    main()

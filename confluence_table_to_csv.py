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
"""

import csv
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

EXPORT_DIR = "confluence_export"
TABLE_EXPORT_DIR = "confluence_table_export"

NAMESPACE_DECLARATIONS = (
    'xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/" '
    'xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/"'
)

# Same list as the other converters - see confluence_html_to_markdown.py
# for why these specific ones.
KNOWN_HTML_ENTITIES = {
    "nbsp": " ",
    "mdash": "—",
    "ndash": "–",
    "hellip": "…",
    "lsquo": "‘",
    "rsquo": "’",
    "ldquo": "“",
    "rdquo": "”",
    "trade": "™",
    "copy": "©",
    "reg": "®",
}


def escape_non_xml_entities(raw_html):
    for name, char in KNOWN_HTML_ENTITIES.items():
        raw_html = raw_html.replace(f"&{name};", char)
    return raw_html


def local_name(tag):
    return tag.split("}", 1)[1] if "}" in tag else tag


def normalise_relative_path(path_str):
    parts = re.split(r"[\\/]+", path_str)
    return os.path.join(*parts) if parts else path_str


def sanitise_filename(name):
    invalid_chars = '<>:"/\\|?*'
    for ch in invalid_chars:
        name = name.replace(ch, "_")
    return name.strip()


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
    # scripting); otherwise just ask - matches every other script here,
    # none of them expect you to already know about command-line args.
    query = sys.argv[1] if len(sys.argv) >= 2 else input("Which page? (title or id): ").strip()

    if not query:
        print("No page given, nothing to do.")
        return

    manifest_path = os.path.join(EXPORT_DIR, "manifest.json")
    if not os.path.exists(manifest_path):
        print(f"Can't find manifest.json at {manifest_path}.")
        print("Run confluence_extractor.py (or .ps1) first.")
        return

    # utf-8-sig, not utf-8: if manifest.json was written by
    # confluence_extractor.ps1 on Windows PowerShell 5.1, Set-Content
    # -Encoding UTF8 adds a BOM there (unlike this Python extractor, and
    # unlike PowerShell 7's Set-Content) - plain "utf-8" chokes outright
    # on that BOM with a JSONDecodeError. utf-8-sig handles a manifest
    # with or without one.
    with open(manifest_path, "r", encoding="utf-8-sig") as f:
        manifest = json.load(f)

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

"""
Confluence HTML to Markdown converter. Stdlib only.

Reads manifest.json from confluence_extractor (either version), turns each
content.html into content.md, and sorts pages into:

    confluence_markdown_export/azure/...
    confluence_markdown_export/sharepoint/...
    confluence_markdown_export/unsorted/...

Technical docs go to Azure DevOps Wiki, everything else to SharePoint - no
way to tell those apart from the content itself, so you classify each page
once via a CSV (see load_or_create_classification below). Pure local file
processing, doesn't touch Confluence.

    python confluence_html_to_markdown.py
"""

import csv
import glob
import json
import os
import re
import shutil
import xml.etree.ElementTree as ET

EXPORT_DIR = "confluence_export"
MARKDOWN_EXPORT_DIR = "confluence_markdown_export"
CLASSIFICATION_PATH = os.path.join(EXPORT_DIR, "page_destinations.csv")
CSV_FIELDNAMES = ["id", "title", "destination"]

# Confluence storage format mixes plain XHTML with its own ac:/ri: prefixed
# elements (macros, images, attachment refs) - declare the namespaces so the
# parser doesn't choke on them.
NAMESPACE_DECLARATIONS = (
    'xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/" '
    'xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/"'
)


# Named entities that turn up in content pasted from Word/Outlook. XML only
# knows amp/lt/gt/apos/quot, so anything else here crashes ET.fromstring on
# an otherwise fine page. Hit a new one? The error names it - add it below.
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
    # ElementTree prefixes qualified tags/attrs with {namespace}, strip it
    return tag.split("}", 1)[1] if "}" in tag else tag

def find_child_by_local_name(elem, name):
    for child in elem:
        if local_name(child.tag) == name:
            return child
    return None

def get_attr(elem, local_attr_name):
    for key, value in elem.attrib.items():
        if local_name(key) == local_attr_name:
            return value
    return None


def convert_node_to_markdown(elem, list_depth=0):
    """Walks an element's children in document order (text + child elements),
    dispatching each child element to its Markdown equivalent."""
    parts = []
    if elem.text:
        parts.append(elem.text)

    for child in list(elem):
        parts.append(convert_element_to_markdown(child, list_depth))
        if child.tail:
            parts.append(child.tail)

    return "".join(parts)


def convert_element_to_markdown(elem, list_depth):
    tag = local_name(elem.tag)

    if tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
        level = int(tag[1])
        return f"\n{'#' * level} {convert_node_to_markdown(elem)}\n"

    if tag == "p":
        return f"\n{convert_node_to_markdown(elem)}\n"

    if tag == "br":
        return "\n"

    if tag in ("strong", "b"):
        return f"**{convert_node_to_markdown(elem)}**"

    if tag in ("em", "i"):
        return f"*{convert_node_to_markdown(elem)}*"

    if tag == "code":
        return f"`{convert_node_to_markdown(elem)}`"

    if tag == "a":
        href = get_attr(elem, "href")
        link_text = convert_node_to_markdown(elem)
        return f"[{link_text}]({href})" if href else link_text

    if tag == "link":
        # <ac:link> - internal page-to-page link, no stable URL until the
        # target's actually migrated, so keep the text and flag it instead
        # of dropping it (used to fall through to unknown-tag and vanish)
        page_ref = find_child_by_local_name(elem, "page")
        target_title = get_attr(page_ref, "content-title") if page_ref is not None else None
        link_text = convert_node_to_markdown(elem).strip()
        display_text = link_text or target_title or "link"
        if target_title:
            return f"{display_text} <!-- internal Confluence link, unresolved: \"{target_title}\" -->"
        return f"{display_text} <!-- internal Confluence link, unresolved -->"

    if tag == "ul":
        out = "\n"
        for list_item in elem:
            if local_name(list_item.tag) != "li":
                continue
            indent = "  " * list_depth
            out += f"{indent}- {convert_node_to_markdown(list_item, list_depth + 1).strip()}\n"
        return out

    if tag == "ol":
        out = "\n"
        item_number = 1
        for list_item in elem:
            if local_name(list_item.tag) != "li":
                continue
            indent = "  " * list_depth
            out += f"{indent}{item_number}. {convert_node_to_markdown(list_item, list_depth + 1).strip()}\n"
            item_number += 1
        return out

    if tag == "table":
        out = "\n"
        table_rows = [e for e in elem.iter() if local_name(e.tag) == "tr"]
        for row_index, table_row in enumerate(table_rows):
            table_cells = [c for c in table_row if local_name(c.tag) in ("th", "td")]
            cell_texts = [convert_node_to_markdown(c).strip().replace("|", "\\|") for c in table_cells]
            out += "| " + " | ".join(cell_texts) + " |\n"
            if row_index == 0:
                out += "| " + " | ".join(["---"] * len(cell_texts)) + " |\n"
        return out

    if tag == "image":
        # Confluence image, either an attachment reference or an external URL
        attachment_ref = find_child_by_local_name(elem, "attachment")
        url_ref = find_child_by_local_name(elem, "url")

        if attachment_ref is not None:
            filename = get_attr(attachment_ref, "filename")
            if filename:
                return f"\n![{filename}](images/{filename})\n"
        elif url_ref is not None:
            value = get_attr(url_ref, "value")
            if value:
                return f"\n![image]({value})\n"
        return ""

    if tag == "structured-macro":
        macro_name = get_attr(elem, "name") or "unknown"

        if macro_name == "code":
            body_node = find_child_by_local_name(elem, "plain-text-body")
            code_text = (body_node.text or "") if body_node is not None else ""
            return f"\n```\n{code_text}\n```\n"

        if macro_name in ("info", "note", "warning", "tip"):
            body_node = find_child_by_local_name(elem, "rich-text-body")
            inner_text = convert_node_to_markdown(body_node).strip() if body_node is not None else ""
            panel_label = macro_name.upper()
            return f"\n> **{panel_label}:** {inner_text}\n"

        # only handling code/info/note/warning/tip specifically, everything else
        # (page trees, Jira embeds, whatever) falls through here - keep the
        # readable text so nothing's silently lost, flag it for manual review
        inner_text = convert_node_to_markdown(elem).strip()
        if inner_text:
            return f"\n<!-- unrecognised macro: {macro_name} -->\n{inner_text}\n"
        return f"\n<!-- unrecognised macro: {macro_name} (no text content) -->\n"

    # Unknown tag: recurse into it so we don't lose the text inside
    return convert_node_to_markdown(elem, list_depth)


def normalise_relative_path(path_str):
    """The manifest's folder paths may use backslashes (written on Windows,
    or by the .ps1 extractor) or forward slashes (written on Mac/Linux).
    Normalise to whatever this OS actually uses before joining paths."""
    parts = re.split(r"[\\/]+", path_str)
    return os.path.join(*parts) if parts else path_str


# First run: no CSV yet, so we generate one (id/title/destination, blank)
# and stop so you can fill it in - "azure" or "sharepoint" per row, Excel's
# fine. Later runs: any new pages get appended with a blank destination,
# already-filled rows are left alone.


def write_classification_csv(rows, path):
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDNAMES)
        writer.writeheader()
        writer.writerows(rows)


def load_or_create_classification(manifest):
    """Returns a dict of page id -> normalised destination ('azure',
    'sharepoint', or '' for unclassified), or None if the caller should
    stop (template just created, or new rows were just added)."""
    if not os.path.exists(CLASSIFICATION_PATH):
        print("First time running this, so no page_destinations.csv yet.")
        print(f"Creating one now at: {CLASSIFICATION_PATH}")

        rows = [{"id": p["id"], "title": p["title"], "destination": ""} for p in manifest]
        write_classification_csv(rows, CLASSIFICATION_PATH)

        print("\nOpen that file (Excel's fine) and fill in the 'destination'")
        print("column for every row, azure or sharepoint. Save it, then run")
        print("this script again and it'll pick up where you left off.")
        return None

    # utf-8-sig not utf-8: Excel's "CSV UTF-8" save writes a BOM, and plain
    # utf-8 leaves it glued to the first header ("id" -> "﻿id"), which
    # silently breaks every row["id"] lookup below.
    with open(CLASSIFICATION_PATH, "r", newline="", encoding="utf-8-sig") as f:
        existing_rows = list(csv.DictReader(f))

    classification_lookup = {row["id"]: row["destination"] for row in existing_rows}

    new_rows_added = False
    all_rows = []
    for page_entry in manifest:
        page_id = str(page_entry["id"])
        if page_id not in classification_lookup:
            new_rows_added = True
            all_rows.append({"id": page_id, "title": page_entry["title"], "destination": ""})
        else:
            all_rows.append({
                "id": page_id,
                "title": page_entry["title"],
                "destination": classification_lookup[page_id],
            })

    if new_rows_added:
        write_classification_csv(all_rows, CLASSIFICATION_PATH)
        print("Found some new pages since the CSV was last filled in, added")
        print(f"them to {CLASSIFICATION_PATH} with a blank destination.")
        print("Fill those in and run this again when you're ready.")
        return None

    # Normalise values so "Azure", " azure ", "AZURE" etc all match cleanly.
    return {row["id"]: re.sub(r"\s", "", row["destination"]).lower() for row in all_rows}


# Azure DevOps Wiki caps full path at 235 chars, spaces->hyphens in the
# file name, / \ # not allowed, can't start/end with a period. SharePoint
# caps at 400, spaces are fine, disallowed chars are " * : < > ? / \ | # {}.
# Catching this now beats finding out 300 pages into an upload.
# learned these the hard way after a batch upload bounced most of a space
AZURE_MAX_PATH_LENGTH = 235
SHAREPOINT_MAX_PATH_LENGTH = 400

def to_azure_wiki_filename(title):
    """Mirrors how Azure DevOps derives a page's file name from its title:
    spaces become hyphens, disallowed characters are stripped, and the
    name can't start or end with a period."""
    safe_name = re.sub(r"\s+", "-", title)
    safe_name = re.sub(r"[/\\#]", "", safe_name)
    safe_name = safe_name.strip(".")
    return f"{safe_name}.md"


def to_sharepoint_filename(title):
    """SharePoint keeps spaces as-is (unlike Azure DevOps Wiki), it just
    needs the disallowed characters stripped out."""
    safe_name = re.sub(r'["*:<>?/\\|#{}]', "", title)
    safe_name = safe_name.strip()
    return f"{safe_name}.md"


def estimate_path_length(repo_url_prefix, folder_path, file_name, max_length):
    if repo_url_prefix:
        full_path = f"{repo_url_prefix}/{folder_path}/{file_name}"
    else:
        full_path = f"{folder_path}/{file_name}"

    return {
        "full_path": full_path,
        "length": len(full_path),
        "over_limit": len(full_path) > max_length,
    }


def run_destination_check(bucket, destination_name, max_path_length, url_prompt, pages_in_bucket):
    """Runs the length/naming check for one destination bucket (azure or
    sharepoint) against only the pages classified into that bucket."""
    print(f"\n--- {destination_name} ({len(pages_in_bucket)} pages) ---")
    print(f"For an accurate check, paste in the {url_prompt}.")
    destination_url_prefix = input("URL (leave blank for a rough estimate instead): ").strip()

    if not destination_url_prefix:
        print("No URL given. Continuing with a ROUGH ESTIMATE based on folder")
        print("path and file name only. This under-counts the real length, so")
        print("pages close to the limit might still fail on upload even if this")
        print("check says they're fine.")

    affected_pages = []

    for page_entry in pages_in_bucket:
        if bucket == "azure":
            destination_file_name = to_azure_wiki_filename(page_entry["title"])
        else:
            destination_file_name = to_sharepoint_filename(page_entry["title"])

        bucket_folder = f"{bucket}/{normalise_relative_path(page_entry['folder'])}"
        path_check = estimate_path_length(destination_url_prefix, bucket_folder, destination_file_name, max_path_length)

        if path_check["over_limit"]:
            affected_pages.append({
                "title": page_entry["title"],
                "folder": bucket_folder,
                "destination_file_name": destination_file_name,
                "length": path_check["length"],
                "page_id": page_entry["id"],
            })

    if not affected_pages:
        print(f"All {destination_name} page paths are within the {max_path_length} character limit.")
        return

    print(f"\n{len(affected_pages)} page(s) are too long for the {max_path_length} character limit:")
    for affected in affected_pages:
        print(f"  - {affected['title']} (estimated length: {affected['length']})")

    should_fix = input(f"\nShorten these automatically so they're {destination_name}-compliant? (y/n): ").strip().lower()

    if should_fix != "y":
        print(f"\nLeft as-is. These pages will likely fail on upload to {destination_name}.")
        return

    print("\nShortening the affected file names...")

    for affected in affected_pages:
        # trim the title down to fit, page_id suffix keeps shortened names unique
        unique_suffix = f"-{affected['page_id']}"
        overshoot = affected["length"] - max_path_length
        chars_to_trim = overshoot + len(unique_suffix) + 5  # small safety margin

        original_name = re.sub(r"\.md$", "", affected["destination_file_name"])
        trim_length = max(1, len(original_name) - chars_to_trim)
        shortened_name = original_name[:trim_length] + unique_suffix + ".md"

        destination_folder = os.path.join(MARKDOWN_EXPORT_DIR, normalise_relative_path(affected["folder"]))
        current_markdown_path = os.path.join(destination_folder, "content.md")
        new_markdown_path = os.path.join(destination_folder, shortened_name)

        if os.path.exists(current_markdown_path):
            os.replace(current_markdown_path, new_markdown_path)
            print(f"  Renamed: {affected['title']}")
            print(f"    -> {shortened_name}")
        else:
            print(f"  Skipped, couldn't find the file (maybe already renamed): {affected['title']}")

    print(f"\nDone. Affected files renamed to {destination_name}-compliant names.")
    if bucket == "azure":
        print("Heads up: these renamed files no longer follow Azure's exact")
        print("title-to-filename convention (hyphenated title), since they've")
        print("been trimmed down. When you create the page in Azure DevOps Wiki,")
        print("you might want to set a friendlier page title in the wiki UI")
        print("even though the underlying file name stays short.")


def main():
    manifest_path = os.path.join(EXPORT_DIR, "manifest.json")

    if not os.path.exists(manifest_path):
        print(f"Can't find manifest.json at {manifest_path}.")
        print("Run confluence_extractor.py (or .ps1) first, or check EXPORT_DIR points at the right spot.")
        return

    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)

    for page_entry in manifest:
        page_entry["id"] = str(page_entry["id"])

    classification_lookup = load_or_create_classification(manifest)
    if classification_lookup is None:
        return

    # each page lands in a subfolder matching its classification, or
    # "unsorted" if the CSV row is blank/unrecognised
    total_pages = len(manifest)
    conversion_warnings = []
    destination_counts = {"azure": 0, "sharepoint": 0, "unsorted": 0}

    for page_index, page_entry in enumerate(manifest, start=1):
        relative_folder = normalise_relative_path(page_entry["folder"])
        html_path = os.path.join(EXPORT_DIR, relative_folder, page_entry["html_file"])

        raw_destination = classification_lookup.get(page_entry["id"], "")
        destination_bucket = raw_destination if raw_destination in ("azure", "sharepoint") else "unsorted"
        destination_counts[destination_bucket] += 1

        # Destination folder mirrors the same relative structure as the source
        # export, but lives under MARKDOWN_EXPORT_DIR/<bucket> instead, kept
        # separate from the raw HTML/manifest so it's ready to upload as-is.
        destination_folder = os.path.join(MARKDOWN_EXPORT_DIR, destination_bucket, relative_folder)
        markdown_path = os.path.join(destination_folder, "content.md")

        print(f"[{page_index}/{total_pages}] ({destination_bucket}) {page_entry['title']}")

        if not os.path.exists(html_path):
            print(f"    Skipped: content.html not found at {html_path}")
            conversion_warnings.append(f"{page_entry['title']}: content.html not found")
            continue

        try:
            os.makedirs(destination_folder, exist_ok=True)

            # wipe any .md left over from a previous run (e.g. a name
            # shortened by run_destination_check) or it sits next to the new one
            for stale_markdown_file in glob.glob(os.path.join(destination_folder, "*.md")):
                os.remove(stale_markdown_file)

            with open(html_path, "r", encoding="utf-8") as f:
                raw_html = f.read()

            raw_html = escape_non_xml_entities(raw_html)

            # Wrap in a root element with the Confluence namespaces declared,
            # so the XML parser understands ac: and ri: prefixed tags.
            wrapped_html = f"<root {NAMESPACE_DECLARATIONS}>{raw_html}</root>"
            root_element = ET.fromstring(wrapped_html)

            markdown_body = convert_node_to_markdown(root_element)

            # Tidy up: collapse more than 2 consecutive blank lines
            markdown_body = re.sub(r"(\n\s*){3,}", "\n\n", markdown_body)
            markdown_body = markdown_body.strip() + "\n"

            final_markdown = f"# {page_entry['title']}\n\n{markdown_body}"

            with open(markdown_path, "w", encoding="utf-8") as f:
                f.write(final_markdown)

            # Copy this page's images across too, so the destination folder is
            # fully self-contained and ready to upload without touching the
            # original export.
            source_images_folder = os.path.join(EXPORT_DIR, relative_folder, "images")
            if os.path.isdir(source_images_folder):
                destination_images_folder = os.path.join(destination_folder, "images")
                shutil.copytree(source_images_folder, destination_images_folder, dirs_exist_ok=True)

        except Exception as e:
            print(f"    Failed to convert '{page_entry['title']}': {e}")
            conversion_warnings.append(f"{page_entry['title']}: {e}")

    converted_count = total_pages - len(conversion_warnings)
    print(f"\nDone. Converted {converted_count} of {total_pages} pages.")
    print(f"  -> {destination_counts['azure']} heading to Azure DevOps Wiki")
    print(f"  -> {destination_counts['sharepoint']} heading to SharePoint")
    if destination_counts["unsorted"] > 0:
        print(f"  -> {destination_counts['unsorted']} still UNSORTED, not classified in the CSV")
        print("     These landed in confluence_markdown_export/unsorted/ for now.")
        print(f"     Go back to {CLASSIFICATION_PATH}, fill in the blanks, and re-run")
        print("     this script to move them into the right spot.")
    print(f"Output saved to: {MARKDOWN_EXPORT_DIR}/")

    if conversion_warnings:
        print(f"\n{len(conversion_warnings)} page(s) had issues:")
        for warning in conversion_warnings:
            print(f"  - {warning}")
        print("\nWorth checking these manually, the XML parser can fail on malformed")
        print("content.html (e.g. a stray '&' or '<' left over from a copy-pasted")
        print("table). Open the failed content.html files and take a look.")

    print("\nAlso worth spot-checking a handful of converted .md files for any")
    print("'<!-- unrecognised macro -->' comments, these flag Confluence macros")
    print("(page trees, Jira embeds, etc.) that don't have a clean Markdown")
    print("equivalent, so they got left as a comment plus the visible text.")

    azure_pages = [p for p in manifest if classification_lookup.get(p["id"]) == "azure"]
    sharepoint_pages = [p for p in manifest if classification_lookup.get(p["id"]) == "sharepoint"]

    if not azure_pages and not sharepoint_pages:
        print("\nNo pages classified as azure or sharepoint yet, skipping the length check.")
        return

    if azure_pages:
        run_destination_check(
            "azure",
            "Azure DevOps Wiki",
            AZURE_MAX_PATH_LENGTH,
            "Azure DevOps wiki repo URL (e.g. https://dev.azure.com/yourorg/yourproject/_git/yourproject.wiki)",
            azure_pages,
        )

    if sharepoint_pages:
        run_destination_check(
            "sharepoint",
            "SharePoint",
            SHAREPOINT_MAX_PATH_LENGTH,
            "SharePoint document library URL (e.g. https://yourorg.sharepoint.com/sites/YourSite/Shared Documents)",
            sharepoint_pages,
        )


if __name__ == "__main__":
    main()

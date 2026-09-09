"""
Confluence storage HTML -> paste-ready HTML for SharePoint. Stdlib only.

Automating SharePoint page creation needs an Entra ID app registration to
call the Graph API, and that's not something every account can do (needs
admin rights, or at least an admin's one-time consent). This script is the
fallback that works with nothing more than the page-editing access you
already have: it turns each page classified "sharepoint" in
page_destinations.csv into a clean, standalone .html file. Open it in a
browser, Ctrl+A, Ctrl+C, paste into a new SharePoint page's text web part,
done - no reformatting headings/tables/lists by hand.

Images can't survive that copy-paste (a pasted <img src="local/path"> has
nothing to load once it's in a browser's clipboard, there's no server
behind a relative local path), so each one becomes a visible placeholder
telling you which file to drag in manually from the images/ folder sitting
next to content.html, using SharePoint's own image tool.

Reads the same manifest.json + page_destinations.csv that
confluence_html_to_markdown.py uses, so run that script first (at least
far enough to get pages classified in the CSV) before this one.

    python confluence_sharepoint_paste.py
"""

import csv
import json
import os
import re
import shutil
import xml.etree.ElementTree as ET

EXPORT_DIR = "confluence_export"
PASTE_EXPORT_DIR = "confluence_sharepoint_paste"
CLASSIFICATION_PATH = os.path.join(EXPORT_DIR, "page_destinations.csv")

# Same namespace/entity handling as confluence_html_to_markdown.py - see
# that script's comments for why these are needed.
NAMESPACE_DECLARATIONS = (
    'xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/" '
    'xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/"'
)

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


def escape_html_text(text):
    # elem.text/.tail are plain decoded strings, not HTML-escaped - a
    # literal <, >, or & in the original page text would otherwise be
    # misread as markup once this gets written out as real HTML.
    if not text:
        return ""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def escape_html_attr(value):
    return escape_html_text(value).replace('"', "&quot;")


# Set once per page (see main()) to that page's manifest "attachments"
# entry, mapping the original Confluence filename to whatever it actually
# got saved as - the image placeholder below points at the right file.
CURRENT_ATTACHMENT_MAP = {}


def build_attachment_map(attachments):
    attachment_map = {}
    for entry in attachments:
        if isinstance(entry, dict):
            attachment_map[entry["filename"]] = entry["saved_as"]
        else:
            attachment_map[entry] = entry
    return attachment_map


# Loaded once (see main()) from user_display_names.json - @mentions only
# carry an opaque userkey/username in the storage HTML, this is the
# extractor's best-effort resolution of those to an actual name.
USER_DISPLAY_NAMES = {}


def load_user_display_names():
    path = os.path.join(EXPORT_DIR, "user_display_names.json")
    if not os.path.exists(path):
        return {}
    # utf-8-sig - see the matching comment on manifest.json above.
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def convert_node_to_html(elem):
    """Walks an element's children in document order (text + child
    elements), dispatching each child to its HTML equivalent. Real HTML
    elements nest on their own, unlike the Markdown converter there's no
    need to track list depth by hand."""
    parts = []
    if elem.text:
        parts.append(escape_html_text(elem.text))

    for child in list(elem):
        parts.append(convert_element_to_html(child))
        if child.tail:
            parts.append(escape_html_text(child.tail))

    return "".join(parts)


def convert_element_to_html(elem):
    tag = local_name(elem.tag)

    if tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
        return f"<{tag}>{convert_node_to_html(elem)}</{tag}>"

    if tag == "p":
        return f"<p>{convert_node_to_html(elem)}</p>"

    if tag == "br":
        return "<br>"

    if tag in ("strong", "b"):
        return f"<strong>{convert_node_to_html(elem)}</strong>"

    if tag in ("em", "i"):
        return f"<em>{convert_node_to_html(elem)}</em>"

    if tag == "code":
        return f"<code>{convert_node_to_html(elem)}</code>"

    if tag == "a":
        href = get_attr(elem, "href")
        link_text = convert_node_to_html(elem)
        if href:
            return f'<a href="{escape_html_attr(href)}">{link_text}</a>'
        return link_text

    if tag == "link":
        # <ac:link> covers three different reference types depending on
        # which ri: child it wraps - page, attachment, or user.
        page_ref = find_child_by_local_name(elem, "page")
        attachment_ref = find_child_by_local_name(elem, "attachment")
        user_ref = find_child_by_local_name(elem, "user")
        link_text = convert_node_to_html(elem).strip()

        if attachment_ref is not None:
            # Link to a downloadable attachment (not an <ac:image> embed) -
            # same problem as images: a pasted <a href="images/..."> can't
            # resolve once it's in a browser's clipboard, so this needs the
            # same visible placeholder treatment rather than a real link.
            filename = get_attr(attachment_ref, "filename")
            saved_name = CURRENT_ATTACHMENT_MAP.get(filename, filename) if filename else None
            display_text = link_text or filename or "attachment"
            if filename:
                return (
                    f"{escape_html_text(display_text)} <strong>[ATTACH FILE HERE: "
                    f'"{escape_html_text(filename)}" - find it in the images folder next to this file '
                    f'as "{escape_html_text(saved_name)}", then delete this placeholder]</strong>'
                )
            return escape_html_text(display_text)

        if user_ref is not None:
            # @mention - Confluence resolves this to a live profile link we
            # have no equivalent for, so at minimum keep the person's name
            # visible instead of losing who was mentioned entirely.
            raw_id = get_attr(user_ref, "userkey") or get_attr(user_ref, "username")
            display_name = USER_DISPLAY_NAMES.get(raw_id) if raw_id else None
            return f"@{escape_html_text(display_name or link_text or raw_id or 'mentioned user')}"

        # Page link: no stable URL until the target's actually migrated.
        # Flag it visibly rather than as an HTML comment: comments vanish
        # silently on copy-paste into a rich text editor, and the whole
        # point is that a person notices this.
        target_title = get_attr(page_ref, "content-title") if page_ref is not None else None
        display_text = link_text or target_title or "link"
        if target_title:
            return f'{display_text} <strong>[UNRESOLVED LINK: "{escape_html_text(target_title)}"]</strong>'
        return f"{display_text} <strong>[UNRESOLVED LINK]</strong>"

    if tag == "emoticon":
        fallback = get_attr(elem, "emoji-fallback")
        if fallback:
            return fallback
        name = get_attr(elem, "name")
        return f":{name}:" if name else ""

    if tag == "task-list":
        items = "".join(
            convert_element_to_html(task_item) for task_item in elem if local_name(task_item.tag) == "task"
        )
        return f"<ul>{items}</ul>"

    if tag == "task":
        status_node = find_child_by_local_name(elem, "task-status")
        body_node = find_child_by_local_name(elem, "task-body")
        is_complete = status_node is not None and (status_node.text or "").strip().lower() == "complete"
        body_html = convert_node_to_html(body_node).strip() if body_node is not None else ""
        checkbox = "☑" if is_complete else "☐"
        return f"<li>{checkbox} {body_html}</li>"

    if tag == "ul":
        items = "".join(
            f"<li>{convert_node_to_html(list_item)}</li>" for list_item in elem if local_name(list_item.tag) == "li"
        )
        return f"<ul>{items}</ul>"

    if tag == "ol":
        items = "".join(
            f"<li>{convert_node_to_html(list_item)}</li>" for list_item in elem if local_name(list_item.tag) == "li"
        )
        return f"<ol>{items}</ol>"

    if tag == "table":
        rows_html = []
        table_rows = [e for e in elem.iter() if local_name(e.tag) == "tr"]
        for row_index, table_row in enumerate(table_rows):
            # First row gets <th> cells same as the Markdown converter's
            # header-row assumption - see that script's comments.
            cell_tag = "th" if row_index == 0 else "td"
            table_cells = [c for c in table_row if local_name(c.tag) in ("th", "td")]
            cells_html = "".join(f"<{cell_tag}>{convert_node_to_html(c)}</{cell_tag}>" for c in table_cells)
            rows_html.append(f"<tr>{cells_html}</tr>")
        return "<table><tbody>" + "".join(rows_html) + "</tbody></table>"

    if tag == "image":
        attachment_ref = find_child_by_local_name(elem, "attachment")
        url_ref = find_child_by_local_name(elem, "url")

        if attachment_ref is not None:
            filename = get_attr(attachment_ref, "filename")
            if filename:
                # A pasted <img src="images/..."> can't resolve once it's in
                # a browser's clipboard - there's no server behind a
                # relative local path. Point at the real saved-to-disk name
                # (see confluence_html_to_markdown.py for why that can
                # differ from the original) and leave a visible placeholder
                # instead of a broken image.
                saved_name = CURRENT_ATTACHMENT_MAP.get(filename, filename)
                return (
                    "<p><strong>[INSERT IMAGE HERE: "
                    f'"{escape_html_text(filename)}" - find it in the images folder '
                    f'next to this file as "{escape_html_text(saved_name)}", then delete '
                    "this placeholder]</strong></p>"
                )
        elif url_ref is not None:
            # An external URL image, unlike an attachment, is already a
            # normal absolute web address - it survives copy-paste fine.
            value = get_attr(url_ref, "value")
            if value:
                return f'<img src="{escape_html_attr(value)}" alt="image">'
        return ""

    if tag == "structured-macro":
        macro_name = get_attr(elem, "name") or "unknown"

        if macro_name == "code":
            body_node = find_child_by_local_name(elem, "plain-text-body")
            code_text = (body_node.text or "") if body_node is not None else ""
            return f"<pre><code>{escape_html_text(code_text)}</code></pre>"

        if macro_name in ("info", "note", "warning", "tip"):
            body_node = find_child_by_local_name(elem, "rich-text-body")
            inner_html = convert_node_to_html(body_node).strip() if body_node is not None else ""
            return f"<blockquote><strong>{macro_name.upper()}:</strong> {inner_html}</blockquote>"

        # Same "keep the visible text, flag it" approach as the Markdown
        # converter, just with a visible marker instead of an HTML comment
        # (comments vanish on copy-paste, see the "link" case above).
        inner_html = convert_node_to_html(elem).strip()
        marker = f"<p><strong>[UNRECOGNISED CONFLUENCE MACRO: {escape_html_text(macro_name)}]</strong></p>"
        return marker + inner_html

    # Unknown tag: recurse into it so we don't lose the text inside
    return convert_node_to_html(elem)


def normalise_relative_path(path_str):
    parts = re.split(r"[\\/]+", path_str)
    return os.path.join(*parts) if parts else path_str


def load_classification():
    """Returns a dict of page id -> normalised destination, or None if the
    CSV doesn't exist yet (caller should tell the user to run the Markdown
    converter first, that's what creates and fills it in)."""
    if not os.path.exists(CLASSIFICATION_PATH):
        return None

    with open(CLASSIFICATION_PATH, "r", newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))

    return {row["id"]: re.sub(r"\s", "", row["destination"]).lower() for row in rows}


PAGE_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>{title}</title>
</head>
<body>
<p><strong>PAGE TITLE (set this as the SharePoint page name, then delete this line): {title}</strong></p>
{tags}
{body}
{related_pages}
</body>
</html>
"""


def build_children_by_parent_id(manifest):
    children_by_parent_id = {}
    for page_entry in manifest:
        parent_id = page_entry.get("parent_id")
        if parent_id:
            children_by_parent_id.setdefault(str(parent_id), []).append(page_entry["title"])
    return children_by_parent_id


def build_related_pages_html(page_entry, children_by_parent_id):
    """A lightweight stand-in for Confluence's always-visible page tree -
    SharePoint has no direct equivalent, so each page gets its own
    parent/children links instead. Same visible-marker treatment as
    unresolved in-body links (see the "link" case above): none of these
    pages have real SharePoint URLs yet, so there's nothing to link to
    until they're actually migrated."""
    parent_title = page_entry.get("parent_title")
    children_titles = children_by_parent_id.get(page_entry["id"], [])

    if not parent_title and not children_titles:
        return ""

    parts = ["<hr>", "<h2>Related pages</h2>"]

    if parent_title:
        parts.append(f'<p><strong>Parent page:</strong> [UNRESOLVED LINK: "{escape_html_text(parent_title)}"]</p>')

    if children_titles:
        parts.append("<p><strong>Sub-pages:</strong></p>")
        items = "".join(f'<li>[UNRESOLVED LINK: "{escape_html_text(title)}"]</li>' for title in children_titles)
        parts.append(f"<ul>{items}</ul>")

    return "".join(parts)


def main():
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

    for page_entry in manifest:
        page_entry["id"] = str(page_entry["id"])

    classification_lookup = load_classification()
    if classification_lookup is None:
        print(f"Can't find {CLASSIFICATION_PATH}.")
        print("Run confluence_html_to_markdown.py first, at least far enough")
        print("to get pages classified as azure or sharepoint in that CSV.")
        return

    sharepoint_pages = [p for p in manifest if classification_lookup.get(p["id"]) == "sharepoint"]

    if not sharepoint_pages:
        print("No pages classified 'sharepoint' in the CSV yet, nothing to do.")
        return

    global USER_DISPLAY_NAMES
    USER_DISPLAY_NAMES = load_user_display_names()

    # Built from the full manifest, not just the sharepoint-classified
    # subset, since a page's children (or parent) might be headed to Azure
    # or still sitting unsorted - we still want to show their titles.
    children_by_parent_id = build_children_by_parent_id(manifest)

    total_pages = len(sharepoint_pages)
    warnings = []

    for page_index, page_entry in enumerate(sharepoint_pages, start=1):
        relative_folder = normalise_relative_path(page_entry["folder"])
        html_path = os.path.join(EXPORT_DIR, relative_folder, page_entry["html_file"])
        destination_folder = os.path.join(PASTE_EXPORT_DIR, relative_folder)

        print(f"[{page_index}/{total_pages}] {page_entry['title']}")

        if not os.path.exists(html_path):
            print(f"    Skipped: content.html not found at {html_path}")
            warnings.append(f"{page_entry['title']}: content.html not found")
            continue

        try:
            os.makedirs(destination_folder, exist_ok=True)

            with open(html_path, "r", encoding="utf-8") as f:
                raw_html = f.read()

            raw_html = escape_non_xml_entities(raw_html)

            global CURRENT_ATTACHMENT_MAP
            CURRENT_ATTACHMENT_MAP = build_attachment_map(page_entry.get("attachments", []))

            wrapped_html = f"<root {NAMESPACE_DECLARATIONS}>{raw_html}</root>"
            root_element = ET.fromstring(wrapped_html)

            body_html = convert_node_to_html(root_element)
            related_pages_html = build_related_pages_html(page_entry, children_by_parent_id)

            labels = page_entry.get("labels") or []
            tags_html = f"<p><strong>Tags:</strong> {escape_html_text(', '.join(labels))}</p>" if labels else ""

            page_html = PAGE_TEMPLATE.format(
                title=escape_html_text(page_entry["title"]),
                tags=tags_html,
                body=body_html,
                related_pages=related_pages_html,
            )

            output_path = os.path.join(destination_folder, "content.html")
            with open(output_path, "w", encoding="utf-8") as f:
                f.write(page_html)

            source_images_folder = os.path.join(EXPORT_DIR, relative_folder, "images")
            if os.path.isdir(source_images_folder):
                destination_images_folder = os.path.join(destination_folder, "images")
                shutil.copytree(source_images_folder, destination_images_folder, dirs_exist_ok=True)

        except Exception as e:
            print(f"    Failed to convert '{page_entry['title']}': {e}")
            warnings.append(f"{page_entry['title']}: {e}")

    converted_count = total_pages - len(warnings)
    print(f"\nDone. Converted {converted_count} of {total_pages} pages.")
    print(f"Output saved to: {PASTE_EXPORT_DIR}/")
    print()
    print("For each page: open its content.html in a browser, Ctrl+A, Ctrl+C.")
    print("In SharePoint, + New Page > Blank, paste into the text web part.")
    print("Use the first line to set the page's real title, then delete it.")
    print("Wherever you see '[INSERT IMAGE HERE: ...]', use SharePoint's own")
    print("image tool to add that file from the images/ folder next to")
    print("content.html, then delete the placeholder text.")
    print("Also look out for '[UNRESOLVED LINK: ...]' and '[UNRECOGNISED")
    print("CONFLUENCE MACRO: ...]' markers and fix those up by hand too.")

    if warnings:
        print(f"\n{len(warnings)} page(s) had issues:")
        for warning in warnings:
            print(f"  - {warning}")


if __name__ == "__main__":
    main()

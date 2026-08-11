"""
Confluence HTML to Markdown converter.
Standard library only, no pip install required.

Reads manifest.json produced by confluence_extractor.py (or the .ps1
version), converts each page's content.html into a content.md, writing it
into a separate output folder (confluence_markdown_export) that mirrors the
same page structure as the original export, complete with each page's
images copied alongside its markdown. This keeps the converted output
self-contained and ready to upload, without touching or mixing into the
original raw export.

No credentials needed, this step is pure local file processing, nothing
talks to Confluence.

Run:
    python confluence_html_to_markdown.py

Optional: edit EXPORT_DIR / MARKDOWN_EXPORT_DIR below if your folder names
differ.
"""

import json
import os
import re
import shutil
import xml.etree.ElementTree as ET

EXPORT_DIR = "confluence_export"
MARKDOWN_EXPORT_DIR = "confluence_markdown_export"

# Confluence storage format uses ac: and ri: prefixes for its own elements
# (macros, images, attachment references) alongside plain XHTML. We declare
# those namespaces so the XML parser doesn't choke on them.
NAMESPACE_DECLARATIONS = (
    'xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/" '
    'xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/"'
)


def local_name(tag):
    """Strips the {namespace} prefix ElementTree adds to qualified tag/attribute names."""
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

        # Unrecognised macro: keep any readable text inside it so nothing is
        # silently lost, flag it for manual review.
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


# ============================================================
# DESTINATION PATH LENGTH / NAMING CHECK
#
# WHY THIS EXISTS: both Azure DevOps Wiki and SharePoint document
# libraries have their own rules about how long a file's full path can be,
# and which characters are allowed in a file name. Uploads that break
# these rules fail, sometimes with unhelpful error messages, so it's safer
# to catch and fix this now than to discover it partway through uploading
# 500+ pages.
#
# Azure DevOps Wiki:
#   - Full path (repo URL + folder path + file name) must be 235
#     characters or less.
#   - Spaces in the page title become hyphens in the file name.
#   - Disallowed characters in the file name: / \ #
#   - File name can't start or end with a period.
#   Source: https://learn.microsoft.com/en-us/azure/devops/organizations/settings/naming-restrictions
#
# SharePoint document libraries:
#   - Individual file/folder names must be 400 characters or less.
#   - Full path (site URL + library + folders + file name) must also be
#     400 characters or less in total.
#   - Disallowed characters anywhere in the name: " * : < > ? / \ |  # { }
#   - Spaces are fine, SharePoint doesn't rewrite the title into the file
#     name the way Azure DevOps Wiki does.
#   Source: Microsoft SharePoint documentation on invalid file/folder names
#
# This section only runs if you confirm below that this export is headed
# to one of these destinations. It does NOT touch confluence_export (the
# raw source), only the already-converted files in confluence_markdown_export.
# ============================================================

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
    """Returns the estimated full path length for a page, and whether it
    breaches the given destination's limit."""
    if repo_url_prefix:
        full_path = f"{repo_url_prefix}/{folder_path}/{file_name}"
    else:
        full_path = f"{folder_path}/{file_name}"

    return {
        "full_path": full_path,
        "length": len(full_path),
        "over_limit": len(full_path) > max_length,
    }


def run_destination_path_length_check(manifest):
    print("\nWhere is this markdown export headed?")
    print("  1. Azure DevOps Wiki")
    print("  2. SharePoint")
    print("  3. Not sure / not fussed, skip this check")
    destination_choice = input("Enter 1, 2, or 3: ").strip()

    if destination_choice not in ("1", "2"):
        print("\nSkipping the destination path length check.")
        return

    if destination_choice == "1":
        destination_name = "Azure DevOps Wiki"
        max_path_length = AZURE_MAX_PATH_LENGTH
        url_prompt = "Azure DevOps wiki repo URL (e.g. https://dev.azure.com/yourorg/yourproject/_git/yourproject.wiki)"
    else:
        destination_name = "SharePoint"
        max_path_length = SHAREPOINT_MAX_PATH_LENGTH
        url_prompt = "SharePoint document library URL (e.g. https://yourorg.sharepoint.com/sites/YourSite/Shared Documents)"

    # Ask for the actual destination URL now, before running any check.
    # The limit applies to the FULL path (site/repo URL + folder path +
    # file name), so without the real URL the check below is only an
    # estimate and could miss pages that are actually over the limit once
    # the real URL is added on top. Getting this right up front is safer
    # than silently under-counting.
    print(f"\nFor an accurate check, paste in the {url_prompt}.")
    destination_url_prefix = input("URL (leave blank for a rough estimate instead): ").strip()

    if not destination_url_prefix:
        print("\nNo URL given. Continuing with a ROUGH ESTIMATE based on folder")
        print("path and file name only. This under-counts the real length, so")
        print("pages close to the limit might still fail on upload even if this")
        print("check says they're fine. Run it again with the real URL to be sure.")

    print(f"\nChecking page paths against {destination_name}'s {max_path_length} character limit...")
    affected_pages = []

    for page_entry in manifest:
        if destination_choice == "1":
            destination_file_name = to_azure_wiki_filename(page_entry["title"])
        else:
            destination_file_name = to_sharepoint_filename(page_entry["title"])

        path_check = estimate_path_length(
            destination_url_prefix, page_entry["folder"], destination_file_name, max_path_length
        )

        if path_check["over_limit"]:
            affected_pages.append({
                "title": page_entry["title"],
                "folder": page_entry["folder"],
                "destination_file_name": destination_file_name,
                "length": path_check["length"],
            })

    if not affected_pages:
        print(f"All page paths are within the {max_path_length} character limit. Nothing to fix.")
        return

    print(f"\n{len(affected_pages)} page(s) are too long for the {max_path_length} character limit:")
    for affected in affected_pages:
        print(f"  - {affected['title']} (estimated length: {affected['length']})")

    should_fix = input("\nShorten these automatically so they're compliant? (y/n): ").strip().lower()

    if should_fix != "y":
        print(f"\nLeft as-is. These pages will likely fail on upload to {destination_name}.")
        return

    print("\nShortening the affected file names...")

    for affected in affected_pages:
        page_entry = next(p for p in manifest if p["folder"] == affected["folder"])

        # Work out how much needs to be trimmed off the title portion of the
        # file name to fit under the limit, keeping a safety margin and
        # appending a short unique suffix so two shortened titles don't
        # collide with each other.
        unique_suffix = f"-{page_entry['id']}"
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
    if destination_choice == "1":
        print("Heads up: these renamed files no longer follow Azure's exact")
        print("title-to-filename convention (hyphenated title), since they've")
        print("been trimmed down. When you create the page in Azure DevOps Wiki,")
        print("you might want to set a friendlier page title in the wiki UI")
        print("even though the underlying file name stays short.")


def main():
    manifest_path = os.path.join(EXPORT_DIR, "manifest.json")

    if not os.path.exists(manifest_path):
        print(f"Can't find manifest.json at {manifest_path}.")
        print(f"Run confluence_extractor.py (or .ps1) first, or check EXPORT_DIR points at the right spot.")
        return

    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)

    total_pages = len(manifest)
    conversion_warnings = []

    for page_index, page_entry in enumerate(manifest, start=1):
        relative_folder = normalise_relative_path(page_entry["folder"])
        html_path = os.path.join(EXPORT_DIR, relative_folder, page_entry["html_file"])

        # Destination folder mirrors the same relative structure as the source
        # export, but lives under MARKDOWN_EXPORT_DIR instead, kept separate
        # from the raw HTML/manifest so it's ready to upload as-is.
        destination_folder = os.path.join(MARKDOWN_EXPORT_DIR, relative_folder)
        markdown_path = os.path.join(destination_folder, "content.md")

        print(f"[{page_index}/{total_pages}] {page_entry['title']}")

        if not os.path.exists(html_path):
            print(f"    Skipped: content.html not found at {html_path}")
            conversion_warnings.append(f"{page_entry['title']}: content.html not found")
            continue

        try:
            os.makedirs(destination_folder, exist_ok=True)

            with open(html_path, "r", encoding="utf-8") as f:
                raw_html = f.read()

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

    run_destination_path_length_check(manifest)


if __name__ == "__main__":
    main()

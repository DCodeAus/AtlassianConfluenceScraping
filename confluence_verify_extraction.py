"""
Confluence extraction verifier - stdlib only, no pip install.

Checks what confluence_extractor.py (or the .ps1 version - manifests from
either are compatible) actually saved to disk, without needing Confluence
at all:

  - every page's folder, content.html and rendered.html exist and aren't
    empty
  - every attachment it recorded is on disk, isn't empty, and isn't a web
    page saved in place of the real file (what you get when a proxy or
    login page answers instead of Confluence)
  - nothing's listed in failures.json (failed pages AND failed
    attachment downloads)
  - every image/file each page shows or links to was actually saved -
    including ones that really live on a DIFFERENT page, which don't come
    down with this one
  - and, for information: links to pages that aren't in this export,
    macros that pull their content from somewhere else (Jira, include
    page, page trees...) so it won't come with the export, and page
    folders on disk the manifest doesn't know about

Results are split into "must fix before Confluence is switched off" and
"for your information". It tells you if something's missing, empty or
broken - not whether a table rendered nicely, so still spot-check a few
pages by eye. confluence_verify_live_content goes further, comparing
every page against Confluence itself.

Asks which export folder to check - a folder name next to this script, or
a full path anywhere (e.g. a shared drive holding several spaces' exports).
Or pass it as the first argument, or set CONFLUENCE_EXPORT_DIR, to skip
the question:
    python confluence_verify_extraction.py
    python confluence_verify_extraction.py C:\\path\\to\\confluence_export_TEAM

While Confluence is still reachable - especially useful if it's about to be
decommissioned, since this is your last chance to check - add
--check-live-space to also compare the manifest against Confluence's own
live page list for that space, catching anything that never made it into
the manifest at all (which the checks above can't see, since they only look
at what the manifest itself claims):
    python confluence_verify_extraction.py --check-live-space

Something broken or unclear? Raise an issue at
https://github.com/DCodeAus/AtlassianConfluenceScraping/issues
"""

import html
import json
import os
import re
import sys

# Everything the scripts here have in common - the questions, talking to
# Confluence, reading an export folder - lives in confluence_common.py, so
# a fix there fixes every script at once. It has to be in the same folder
# as this one.
try:
    from confluence_common import (
        Confluence, ask_base_url, ask_export_dir, ask_login, env_saved_or_ask,
        input_with_help, load_export_manifest,
        normalise_relative_path, print_issue_summary, read_export_source, read_json,
    )
except ImportError:
    print("Can't find confluence_common.py (or it's out of date) - it needs to be")
    print("in the same folder as this script. Download the whole repository")
    print("rather than just this one file.")
    raise SystemExit(1)

REPORT_NAME = "verification_report.json"


# Patterns over the raw page HTML (Confluence's "storage format") - plain
# regexes rather than real XML parsing, same as the extractor. An
# <ri:attachment> is an image or file the page shows or links to; if it has
# an <ri:page>/<ri:content-entity> inside, that file lives on a DIFFERENT
# page and doesn't come down with this one.
ATTACHMENT_REF_PATTERN = re.compile(r'<ri:attachment\b([^>]*?)(?:/>|>(.*?)</ri:attachment>)', re.S)
PAGE_REF_PATTERN = re.compile(r'<ri:page\b([^>]*?)/?>')
CONTENT_ID_PATTERN = re.compile(r'<ri:content-entity\b[^>]*\bri:content-id="([^"]+)"')
MACRO_PATTERN = re.compile(r'<ac:structured-macro\b[^>]*\bac:name="([^"]+)"')

# Macros that show content which isn't actually stored in the page itself -
# it's fetched from elsewhere (another page, Jira, a live list) each time
# the page is viewed, so the export only has the macro, not what it showed.
EXTERNAL_CONTENT_MACROS = {
    "include", "excerpt-include", "jira", "jiraissues", "jirachart",
    "children", "pagetree", "pagetreesearch", "contentbylabel",
    "content-report-table", "detailssummary", "recently-updated",
    "task-report", "blog-posts", "gadget", "widget", "iframe", "rss",
    "html-include", "space-details", "spaces",
}


def get_attribute(attributes, name):
    match = re.search(name + r'="([^"]*)"', attributes)
    return html.unescape(match.group(1)) if match else None


# What a saved file starts with if it's actually a web page (a proxy's
# login screen, an error page) that got saved in place of the real file.
def looks_like_web_page(path):
    with open(path, "rb") as f:
        start = f.read(512).lstrip().lower()
    return start.startswith(b"<!doctype html") or start.startswith(b"<html")


def main():
    args = sys.argv[1:]
    check_live_space = "--check-live-space" in args
    positional = [a for a in args if a != "--check-live-space"]

    # Asked every run unless given as an argument, so checking each space's
    # export (saved under its own folder name by confluence_extractor, maybe
    # somewhere else entirely like a shared drive) just means answering
    # this differently. Set CONFLUENCE_EXPORT_DIR for unattended runs.
    export_dir = ask_export_dir(
        "Export folder to check (blank for 'confluence_export'): ",
        [
            "Which extraction to check - the folder name you gave (or",
            "accepted the default for) when running",
            "confluence_extractor.py/.ps1 for that space, or its full",
            "path if it's somewhere else (e.g. on a shared drive).",
            "Leave blank for: confluence_export",
        ],
        args=positional,
    )
    manifest, manifest_path = load_export_manifest(export_dir)
    print(f"Read {manifest_path}")
    print(f"{len(manifest)} page(s) recorded in the manifest.\n")

    failures_path = os.path.join(export_dir, "failures.json")
    recorded_failures = []
    if os.path.isfile(failures_path):
        recorded_failures = read_json(failures_path)

    missing_folders = []
    missing_or_empty_content = []
    bad_attachments = []
    missing_referenced_files = []
    links_outside_export = []
    external_content_macros = []
    seen_ids = set()
    duplicate_ids = []

    # For looking up pages a page refers to, by title or by ID.
    pages_by_title = {page["title"]: page for page in manifest}
    page_ids = {page["id"] for page in manifest}
    export_space_key = read_export_source(export_dir).get("spaceKey") or ""

    for index, page in enumerate(manifest, start=1):
        if index % 500 == 0:
            print(f"  checked {index}/{len(manifest)} so far...")

        page_id = page["id"]
        if page_id in seen_ids:
            duplicate_ids.append({"id": page_id, "title": page["title"]})
        else:
            seen_ids.add(page_id)

        page_folder = os.path.join(export_dir, normalise_relative_path(page["folder"]))

        if not os.path.isdir(page_folder):
            missing_folders.append({"id": page_id, "title": page["title"], "folder": page_folder})
            continue

        html_path = os.path.join(page_folder, page["html_file"])
        body = ""
        if not os.path.isfile(html_path):
            missing_or_empty_content.append({"id": page_id, "title": page["title"], "path": html_path, "reason": "missing"})
        elif os.path.getsize(html_path) == 0:
            missing_or_empty_content.append({"id": page_id, "title": page["title"], "path": html_path, "reason": "empty (0 bytes)"})
        else:
            with open(html_path, "r", encoding="utf-8-sig", errors="replace") as f:
                body = f.read()

        # The copy of the page as Confluence displayed it - only for exports
        # made since the extractor started saving one. One that failed to
        # save is already in failures.json, so only a missing/empty file
        # that the manifest says WAS saved is flagged here.
        if page.get("rendered_file"):
            rendered_path = os.path.join(page_folder, page["rendered_file"])
            if not os.path.isfile(rendered_path):
                missing_or_empty_content.append({"id": page_id, "title": page["title"], "path": rendered_path, "reason": "rendered.html missing"})
            elif os.path.getsize(rendered_path) == 0:
                missing_or_empty_content.append({"id": page_id, "title": page["title"], "path": rendered_path, "reason": "rendered.html empty (0 bytes)"})

        for attachment in page.get("attachments", []):
            att_path = os.path.join(page_folder, "images", attachment["saved_as"])
            problem = None
            if not os.path.isfile(att_path):
                problem = "missing on disk"
            elif os.path.getsize(att_path) == 0:
                problem = "empty (0 bytes)"
            elif not attachment["filename"].lower().endswith((".htm", ".html")) and looks_like_web_page(att_path):
                problem = "is a web page, not the real file (likely a login or error page)"
            if problem:
                bad_attachments.append({
                    "id": page_id,
                    "title": page["title"],
                    "attachmentName": attachment["filename"],
                    "path": att_path,
                    "reason": f"attachment '{attachment['filename']}' {problem}",
                })

        # Every image/file this page shows or links to should have been
        # saved - either with this page, or with the other page it really
        # lives on, as long as that page is in this export too.
        saved_here = {a["filename"].lower() for a in page.get("attachments", [])}
        for attributes, inner in ATTACHMENT_REF_PATTERN.findall(body):
            filename = get_attribute(attributes, "ri:filename")
            if not filename:
                continue
            inner = inner or ""
            other_page_tag = PAGE_REF_PATTERN.search(inner)
            other_id = CONTENT_ID_PATTERN.search(inner)
            if other_page_tag:
                other_title = get_attribute(other_page_tag.group(1), "ri:content-title") or ""
                other_space = get_attribute(other_page_tag.group(1), "ri:space-key") or ""
                other = pages_by_title.get(other_title) if other_space in ("", export_space_key) else None
                where = f"page '{other_title}'" + (f" in space {other_space}" if other_space else "")
            elif other_id:
                other = next((p for p in manifest if p["id"] == other_id.group(1)), None)
                where = f"page id {other_id.group(1)}"
            elif "<ri:" in inner:
                other, where = None, "another page or blog post"
            else:
                if filename.lower() not in saved_here:
                    missing_referenced_files.append({"id": page_id, "title": page["title"], "reason": f"'{filename}' wasn't saved with this page"})
                continue
            if other is None:
                missing_referenced_files.append({"id": page_id, "title": page["title"], "reason": f"'{filename}' lives on {where}, which isn't in this export"})
            elif filename.lower() not in {a["filename"].lower() for a in other.get("attachments", [])}:
                missing_referenced_files.append({"id": page_id, "title": page["title"], "reason": f"'{filename}' lives on {where}, but wasn't saved there"})

        # Links to other pages (attachment references already handled
        # above, so they're cut out first so their <ri:page> isn't counted
        # twice). Only informational - the link text survives, the page it
        # points at just isn't part of this export.
        outside = []
        for attributes in PAGE_REF_PATTERN.findall(ATTACHMENT_REF_PATTERN.sub("", body)):
            link_title = get_attribute(attributes, "ri:content-title")
            link_space = get_attribute(attributes, "ri:space-key") or ""
            if not link_title:
                continue
            if link_space not in ("", export_space_key) or link_title not in pages_by_title:
                outside.append(link_title + (f" (space {link_space})" if link_space else ""))
        if outside:
            unique = sorted(set(outside))
            shown = ", ".join(f"'{t}'" for t in unique[:3]) + (f" and {len(unique) - 3} more" if len(unique) > 3 else "")
            links_outside_export.append({"id": page_id, "title": page["title"], "reason": f"links to {shown}", "targets": unique})

        macros = [name for name in MACRO_PATTERN.findall(body) if name in EXTERNAL_CONTENT_MACROS]
        if macros:
            counts = {name: macros.count(name) for name in sorted(set(macros))}
            external_content_macros.append({
                "id": page_id,
                "title": page["title"],
                "reason": ", ".join(f"{name} x{count}" if count > 1 else name for name, count in counts.items()),
                "macros": counts,
            })

    # Page folders on disk the manifest doesn't list - usually left from an
    # earlier run, but worth a look: content here is invisible to the
    # converter and every other script, since they all go by the manifest.
    listed_folders = {os.path.normcase(os.path.normpath(os.path.join(export_dir, normalise_relative_path(p["folder"])))) for p in manifest}
    unlisted_folders = []
    pages_root = os.path.join(export_dir, "pages")
    if os.path.isdir(pages_root):
        for name in sorted(os.listdir(pages_root)):
            full = os.path.join(pages_root, name)
            if os.path.isdir(full) and os.path.normcase(os.path.normpath(full)) not in listed_folders:
                unlisted_folders.append({"id": name.split("_", 1)[0], "title": name, "path": full})

    print("\n--- Must fix before Confluence is switched off ---")
    print_issue_summary("Failed during extraction - pages and attachments (failures.json)", recorded_failures, REPORT_NAME)
    print_issue_summary("Duplicate page IDs in manifest", duplicate_ids, REPORT_NAME)
    print_issue_summary("Page folders missing on disk", missing_folders, REPORT_NAME)
    print_issue_summary("content.html / rendered.html missing or empty", missing_or_empty_content, REPORT_NAME)
    print_issue_summary("Attachment files missing, empty or not the real file", bad_attachments, REPORT_NAME)
    print_issue_summary("Images/files a page shows or links to that weren't saved", missing_referenced_files, REPORT_NAME)

    print("\n--- For your information ---")
    print_issue_summary("Pages using macros whose content lives elsewhere (it won't come with the export)", external_content_macros, REPORT_NAME)
    print_issue_summary("Pages linking to pages that aren't in this export", links_outside_export, REPORT_NAME)
    print_issue_summary("Page folders on disk the manifest doesn't list (invisible to the other scripts)", unlisted_folders, REPORT_NAME)

    live_check = None

    if check_live_space:
        print("\n--- Live space check ---")

        saved = read_export_source(export_dir)
        base_url = ask_base_url(saved.get("baseUrl"))
        space_key = env_saved_or_ask("CONFLUENCE_SPACE_KEY", saved.get("spaceKey"), "Confluence space key", lambda: input_with_help(
            "Confluence space key: ",
            [
                "The short code identifying which space to check, found in a",
                "page's URL right after /display/ or /spaces/.",
            ],
        ).strip())
        username, password = ask_login()
        confluence = Confluence(base_url, username, password)
        confluence.check_signed_in()

        try:
            # No expand= here on purpose - this is only comparing IDs/titles,
            # not re-fetching every page's full content, so there's no need
            # to ask Confluence for anything heavier than it takes to list
            # what exists.
            live_pages = confluence.get_all(
                "/rest/api/content",
                {"spaceKey": space_key, "type": "page"},
                limit=100,
                on_batch=lambda start: print(f"  fetching live page list: start={start}"),
            )

            live_ids = {p["id"] for p in live_pages}
            manifest_ids = {p["id"] for p in manifest}

            missing_from_extraction = [{"id": p["id"], "title": p["title"]} for p in live_pages if p["id"] not in manifest_ids]
            no_longer_live = [{"id": p["id"], "title": p["title"]} for p in manifest if p["id"] not in live_ids]

            print(f"  {len(live_pages)} page(s) live in Confluence right now, {len(manifest)} in the manifest.")
            print_issue_summary("Live pages never recorded in the manifest (extraction missed these)", missing_from_extraction, REPORT_NAME)
            print_issue_summary("Manifest pages no longer live (likely deleted/moved since extraction - not necessarily a problem)", no_longer_live, REPORT_NAME)

            live_check = {
                "liveTotal": len(live_pages),
                "manifestTotal": len(manifest),
                "missingFromExtraction": missing_from_extraction,
                "noLongerLive": no_longer_live,
            }
        except Exception as e:
            print(f"  Couldn't complete the live check: {e}")
            print("  Everything above this (the manifest-vs-disk checks) is still valid -")
            print("  this only affects the comparison against Confluence itself.")

    has_issues = bool(recorded_failures or duplicate_ids or missing_folders or missing_or_empty_content or bad_attachments or missing_referenced_files)
    if live_check and live_check["missingFromExtraction"]:
        has_issues = True

    print()
    print("Found issues to fix - see \"Must fix\" above (and the saved report) for details." if has_issues else "Nothing to fix. (Check \"For your information\" above too.)")

    report = {
        "manifestPath": manifest_path,
        "totalPagesInManifest": len(manifest),
        "recordedFailures": recorded_failures,
        "duplicateIds": duplicate_ids,
        "missingFolders": missing_folders,
        "missingOrEmptyContent": missing_or_empty_content,
        "badAttachments": bad_attachments,
        "missingReferencedFiles": missing_referenced_files,
        "externalContentMacros": external_content_macros,
        "linksOutsideExport": links_outside_export,
        "unlistedFolders": unlisted_folders,
        "liveCheck": live_check,
    }

    report_path = os.path.join(export_dir, REPORT_NAME)
    try:
        with open(report_path, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, ensure_ascii=False)
        print(f"Full report saved to {report_path}")
    except Exception as e:
        print(f"Couldn't save the full report to {report_path} - {e}")
        print("The summary printed above is still accurate, this just means there's no saved copy.")

    sys.exit(1 if has_issues else 0)


if __name__ == "__main__":
    main()

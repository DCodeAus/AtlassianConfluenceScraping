"""
Confluence extraction verifier - stdlib only, no pip install.

Checks what confluence_extractor.py (or the .ps1 version - manifests from
either are compatible) actually saved to disk against its own
manifest.json: every page's folder and content.html actually exist and
aren't empty, every attachment it recorded actually got downloaded, and
nothing's listed in failures.json. This is a coverage check, not a content
check - it tells you if something's missing or empty, not whether a table
rendered nicely or an image is the right one. Spot-check those by eye.

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

Supported by Daniel - raise issues with him.
"""

import base64
import getpass
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def input_with_help(prompt, help_lines):
    """Like input(), but typing a bare "?" prints an explanation of what's
    being asked for instead of being treated as the actual answer, then
    asks again."""
    while True:
        answer = input(prompt)
        if answer != "?":
            return answer
        for line in help_lines:
            print(line)


def getpass_with_help(prompt, help_lines):
    while True:
        answer = getpass.getpass(prompt)
        if answer != "?":
            return answer
        for line in help_lines:
            print(line)


# A manifest "folder" value from the PowerShell extractor looks like
# "pages\\123_Title" - written on the assumption it'll be read back on
# Windows. Swap in whatever this machine actually uses before joining it
# onto a path, so a manifest from either extractor reads correctly here
# regardless of which OS this verifier itself is running on.
def normalise_relative_path(relative_path):
    return relative_path.replace("\\", os.sep).replace("/", os.sep)


def print_issue_summary(label, items, show_max=15):
    if not items:
        print(f"  {label} : none")
        return
    print(f"  {label} : {len(items)}")
    for item in items[:show_max]:
        if "reason" in item:
            detail = f" - {item['reason']}"
        elif "attachmentName" in item:
            detail = f" - attachment '{item['attachmentName']}'"
        else:
            detail = ""
        print(f"    - [{item['id']}] {item['title']}{detail}")
    if len(items) > show_max:
        print(f"    ... and {len(items) - show_max} more (full list in verification_report.json)")


def main():
    args = sys.argv[1:]
    check_live_space = "--check-live-space" in args
    positional = [a for a in args if a != "--check-live-space"]

    # Asked every run unless given as an argument, so checking each space's
    # export (saved under its own folder name by confluence_extractor, maybe
    # somewhere else entirely like a shared drive) just means answering
    # this differently. Set CONFLUENCE_EXPORT_DIR for unattended runs.
    if positional:
        export_dir = positional[0]
    else:
        export_dir = os.environ.get("CONFLUENCE_EXPORT_DIR") or input_with_help(
            "Export folder to check (blank for 'confluence_export'): ",
            [
                "Which extraction to check - the folder name you gave (or",
                "accepted the default for) when running",
                "confluence_extractor.py/.ps1 for that space, or its full",
                "path if it's somewhere else (e.g. on a shared drive).",
                "Leave blank for: confluence_export",
            ],
        ).strip()
        # Windows "Copy as path" and dragging a folder into the terminal
        # both wrap the path in quotes - strip them so either works.
        export_dir = export_dir.strip('"').strip("'") or "confluence_export"

    if not os.path.isdir(export_dir):
        print(f"Can't find '{export_dir}' from here - run this from the folder")
        print("that contains it, or give its full path instead.")
        sys.exit(1)

    manifest_path = os.path.join(export_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        print(f"No manifest.json in '{export_dir}' - that's written by")
        print("confluence_extractor once it finishes, so either the")
        print("extraction hasn't been run yet, or this is pointed at the")
        print("wrong folder.")
        sys.exit(1)

    print(f"Reading {manifest_path} ...")
    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    print(f"{len(manifest)} page(s) recorded in the manifest.\n")

    failures_path = os.path.join(export_dir, "failures.json")
    recorded_failures = []
    if os.path.isfile(failures_path):
        with open(failures_path, "r", encoding="utf-8") as f:
            recorded_failures = json.load(f)

    missing_folders = []
    missing_or_empty_content = []
    missing_attachments = []
    seen_ids = set()
    duplicate_ids = []

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
        if not os.path.isfile(html_path):
            missing_or_empty_content.append({"id": page_id, "title": page["title"], "path": html_path, "reason": "missing"})
        elif os.path.getsize(html_path) == 0:
            missing_or_empty_content.append({"id": page_id, "title": page["title"], "path": html_path, "reason": "empty (0 bytes)"})

        for attachment in page.get("attachments", []):
            att_path = os.path.join(page_folder, "images", attachment["saved_as"])
            if not os.path.isfile(att_path):
                missing_attachments.append({
                    "id": page_id,
                    "title": page["title"],
                    "attachmentName": attachment["filename"],
                    "expectedPath": att_path,
                })

    print("\n--- Manifest checks ---")
    print_issue_summary("Pages recorded as failed during extraction (failures.json)", recorded_failures)
    print_issue_summary("Duplicate page IDs in manifest", duplicate_ids)
    print_issue_summary("Page folders missing on disk", missing_folders)
    print_issue_summary("content.html missing or empty", missing_or_empty_content)
    print_issue_summary("Attachments recorded but missing on disk", missing_attachments)

    live_check = None

    if check_live_space:
        print("\n--- Live space check ---")

        base_url = os.environ.get("CONFLUENCE_BASE_URL") or input_with_help(
            "Confluence base URL: ",
            [
                "The address of your Confluence site - no trailing slash, and",
                "nothing after the domain (not /wiki, not a page path, just",
                "the base site).",
            ],
        ).strip()
        space_key = os.environ.get("CONFLUENCE_SPACE_KEY") or input_with_help(
            "Confluence space key: ",
            [
                "The short code identifying which space to check, found in a",
                "page's URL right after /display/ or /spaces/.",
            ],
        ).strip()
        username = os.environ.get("CONFLUENCE_USERNAME") or input_with_help("Confluence username: ", [])
        password = os.environ.get("CONFLUENCE_PASSWORD") or getpass_with_help(
            "Confluence password: ",
            ["Masked as you type - that's normal, just type it and press Enter."],
        )

        auth_header = "Basic " + base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
        ssl_context = ssl.create_default_context()

        def api_get(params):
            query = urllib.parse.urlencode(params)
            url = f"{base_url}/rest/api/content?{query}"
            request = urllib.request.Request(url)
            request.add_header("Authorization", auth_header)
            request.add_header("Accept", "application/json")
            last_error = None
            for attempt in range(1, 4):
                try:
                    with urllib.request.urlopen(request, context=ssl_context) as response:
                        return json.loads(response.read().decode("utf-8"))
                except urllib.error.HTTPError as e:
                    last_error = e
                    if e.code < 500 or attempt == 3:
                        raise
                except urllib.error.URLError as e:
                    last_error = e
                    if attempt == 3:
                        raise
                wait = 1.0 * (2 ** (attempt - 1))
                print(f"    Request failed ({last_error}), retrying in {wait:.1f}s (attempt {attempt}/3)...")
                time.sleep(wait)

        try:
            # No expand= here on purpose - this is only comparing IDs/titles,
            # not re-fetching every page's full content, so there's no need
            # to ask Confluence for anything heavier than it takes to list
            # what exists.
            live_pages = []
            start = 0
            page_size = 100
            while True:
                print(f"  fetching live page list: start={start}")
                data = api_get({"spaceKey": space_key, "type": "page", "start": start, "limit": page_size})
                results = data.get("results", [])
                live_pages.extend(results)
                if len(results) < page_size:
                    break
                start += page_size

            live_ids = {p["id"] for p in live_pages}
            manifest_ids = {p["id"] for p in manifest}

            missing_from_extraction = [{"id": p["id"], "title": p["title"]} for p in live_pages if p["id"] not in manifest_ids]
            no_longer_live = [{"id": p["id"], "title": p["title"]} for p in manifest if p["id"] not in live_ids]

            print(f"  {len(live_pages)} page(s) live in Confluence right now, {len(manifest)} in the manifest.")
            print_issue_summary("Live pages never recorded in the manifest (extraction missed these)", missing_from_extraction)
            print_issue_summary("Manifest pages no longer live (likely deleted/moved since extraction - not necessarily a problem)", no_longer_live)

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

    has_issues = bool(recorded_failures or duplicate_ids or missing_folders or missing_or_empty_content or missing_attachments)
    if live_check and live_check["missingFromExtraction"]:
        has_issues = True

    print()
    print("Found issues - see above (and the saved report) for details." if has_issues else "No issues found.")

    report = {
        "manifestPath": manifest_path,
        "totalPagesInManifest": len(manifest),
        "recordedFailures": recorded_failures,
        "duplicateIds": duplicate_ids,
        "missingFolders": missing_folders,
        "missingOrEmptyContent": missing_or_empty_content,
        "missingAttachments": missing_attachments,
        "liveCheck": live_check,
    }

    report_path = os.path.join(export_dir, "verification_report.json")
    try:
        with open(report_path, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
        print(f"Full report saved to {report_path}")
    except Exception as e:
        print(f"Couldn't save the full report to {report_path} - {e}")
        print("The summary printed above is still accurate, this just means there's no saved copy.")

    sys.exit(1 if has_issues else 0)


if __name__ == "__main__":
    main()

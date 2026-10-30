"""
Confluence live content check - stdlib only, no pip install.

Goes one step further than confluence_verify_extraction: instead of only
checking that every file the manifest recorded exists on disk, this
re-fetches every extracted page from Confluence itself, one at a time the
same way the extractor did, and compares what's live right now against
what got saved:

  - content.html matches the live page's content exactly (line endings
    aside) - catches a page saved truncated, garbled, or otherwise not
    what Confluence actually holds
  - the live version number is the same one extracted - catches pages
    edited in Confluence since you ran the extractor, so the export is
    out of date for them
  - every attachment on the live page was actually saved - catches
    downloads the extractor warned about and moved on from (those never
    make it into the manifest, so confluence_verify_extraction can't see
    them), plus anything attached since

Only reads from Confluence and only writes one report file
(live_content_report.json) into the export folder - never changes
content.html or anything else that's there.

    python confluence_verify_live_content.py
    python confluence_verify_live_content.py C:\\path\\to\\confluence_export_TEAM

Asks which export folder to check (a folder name next to this script, or
a full path anywhere), then your login. The site address comes from the
export folder itself (saved there by the extractor) - only asked for if
it isn't there. Set
CONFLUENCE_EXPORT_DIR, CONFLUENCE_BASE_URL, CONFLUENCE_USERNAME and
CONFLUENCE_PASSWORD for unattended runs. Takes about as long as the
extraction did, since it's one request per page plus one for its
attachments - that's normal, not a hang.

If you've run repair_garbled_text's -Force/YOLO strip on this export,
those pages will (correctly) show as not matching - the strip deliberately
removed characters the live page still has.

Supported by Daniel - raise issues with him.
"""

import base64
import getpass
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


INTERNAL_CA_PATH = None   # e.g. r"C:\certs\company-root-ca.pem", same as the extractor
VERIFY_SSL = True

REQUEST_DELAY_SECONDS = 0.3   # same polite pace as the extractor
RETRY_MAX_ATTEMPTS = 3
RETRY_BASE_DELAY_SECONDS = 1.0


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


# confluence_extractor saves where an export came from into the export
# folder (export_source.json), so this doesn't have to ask for the site
# address and space key again. Exports made before that file existed still
# have the same details on the "- Source:" line of their README.md, so
# fall back to reading that.
def read_export_source(export_dir):
    source_path = os.path.join(export_dir, "export_source.json")
    if os.path.isfile(source_path):
        try:
            with open(source_path, "r", encoding="utf-8-sig") as f:
                return json.load(f)
        except Exception:
            pass
    readme_path = os.path.join(export_dir, "README.md")
    if os.path.isfile(readme_path):
        with open(readme_path, "r", encoding="utf-8-sig") as f:
            for line in f:
                match = re.match(r"- Source: (\S+) \((?:space '([^']*)'|page id .*)\)", line.strip())
                if match:
                    return {"baseUrl": match.group(1), "spaceKey": match.group(2) or ""}
    return {}


def env_saved_or_ask(env_var, saved_value, label, ask):
    """An environment variable wins (for unattended runs), then whatever
    was saved with the export - shown, so you can see what's being used -
    and only if neither has it, the usual question."""
    if os.environ.get(env_var):
        return os.environ[env_var]
    if saved_value:
        print(f"{label}: {saved_value} (saved with this export)")
        return saved_value
    return ask()


# Same as confluence_verify_extraction - a manifest "folder" from the
# PowerShell extractor uses backslashes, so swap in this machine's own
# separator before joining it onto a path.
def normalise_relative_path(relative_path):
    return relative_path.replace("\\", os.sep).replace("/", os.sep)


# Python's text-mode write on Windows turns every \n into \r\n, so a
# content.html saved by confluence_extractor.py on Windows never matches
# the live page byte for byte even when nothing's actually wrong. Compare
# with every kind of line ending folded to \n on both sides instead.
def normalise_line_endings(text):
    return text.replace("\r\n", "\n").replace("\r", "\n")


def describe_first_difference(saved, live, context=40):
    """Where the saved and live content first stop matching, with a little
    of each either side - enough to tell at a glance whether it's garbled
    characters, a cut-off page, or something else entirely."""
    index = 0
    shortest = min(len(saved), len(live))
    while index < shortest and saved[index] == live[index]:
        index += 1
    start = max(0, index - context)
    return {
        "firstDifferenceAt": index,
        "savedLength": len(saved),
        "liveLength": len(live),
        "savedAround": saved[start:index + context],
        "liveAround": live[start:index + context],
    }


def print_issue_summary(label, items, show_max=15):
    if not items:
        print(f"  {label} : none")
        return
    print(f"  {label} : {len(items)}")
    for item in items[:show_max]:
        detail = f" - {item['reason']}" if item.get("reason") else ""
        print(f"    - [{item['id']}] {item['title']}{detail}")
    if len(items) > show_max:
        print(f"    ... and {len(items) - show_max} more (full list in live_content_report.json)")


def main():
    args = sys.argv[1:]

    # Asked every run unless given as an argument, same as
    # confluence_verify_extraction - each space's export can live under its
    # own name, or somewhere else entirely like a shared drive.
    if args:
        export_dir = args[0]
    else:
        export_dir = os.environ.get("CONFLUENCE_EXPORT_DIR") or input_with_help(
            "Export folder to check (blank for 'confluence_export'): ",
            [
                "Which extraction to check against live Confluence - the",
                "folder name you gave (or accepted the default for) when",
                "running confluence_extractor.py/.ps1 for that space, or its",
                "full path if it's somewhere else (e.g. on a shared drive).",
                "Leave blank for: confluence_export",
            ],
        ).strip()
        # Windows "Copy as path" and dragging a folder into the terminal
        # both wrap the path in quotes - strip them so either works.
        export_dir = export_dir.strip('"').strip("'") or "confluence_export"

    # Checked before asking for a login, so a mistyped folder doesn't cost
    # you typing your password first.
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

    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    print(f"{len(manifest)} page(s) recorded in {manifest_path}.\n")

    saved = read_export_source(export_dir)
    base_url = env_saved_or_ask("CONFLUENCE_BASE_URL", saved.get("baseUrl"), "Confluence base URL", lambda: input_with_help(
        "Confluence base URL: ",
        [
            "The address of the Confluence site this export came from -",
            "everything in a page's URL before /display/ or /spaces/, with",
            "no slash on the end.",
        ],
    ).strip()).rstrip("/")
    username = os.environ.get("CONFLUENCE_USERNAME") or input_with_help(
        "Confluence username: ",
        ["The same username you log into Confluence with in your browser."],
    )
    password = os.environ.get("CONFLUENCE_PASSWORD") or getpass_with_help(
        "Confluence password: ",
        ["Masked as you type - that's normal, just type it and press Enter."],
    )

    auth_header = "Basic " + base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    if INTERNAL_CA_PATH:
        ssl_context = ssl.create_default_context(cafile=INTERNAL_CA_PATH)
    elif not VERIFY_SSL:
        ssl_context = ssl.create_default_context()
        ssl_context.check_hostname = False
        ssl_context.verify_mode = ssl.CERT_NONE
    else:
        ssl_context = ssl.create_default_context()

    def api_get(path, params):
        url = f"{base_url}{path}?{urllib.parse.urlencode(params)}"
        request = urllib.request.Request(url)
        request.add_header("Authorization", auth_header)
        request.add_header("Accept", "application/json")
        last_error = None
        for attempt in range(1, RETRY_MAX_ATTEMPTS + 1):
            try:
                with urllib.request.urlopen(request, context=ssl_context) as response:
                    return json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                last_error = e
                if e.code < 500 or attempt == RETRY_MAX_ATTEMPTS:
                    raise
            except urllib.error.URLError as e:
                last_error = e
                if attempt == RETRY_MAX_ATTEMPTS:
                    raise
            wait = RETRY_BASE_DELAY_SECONDS * (2 ** (attempt - 1))
            print(f"    Request failed ({last_error}), retrying in {wait:.1f}s (attempt {attempt}/{RETRY_MAX_ATTEMPTS})...")
            time.sleep(wait)

    def get_live_attachment_names(page_id):
        names = []
        start = 0
        limit = 50
        while True:
            data = api_get(f"/rest/api/content/{page_id}/child/attachment", {"start": start, "limit": limit})
            results = data.get("results", [])
            names.extend(a["title"] for a in results)
            if len(results) < limit:
                return names
            start += limit

    matching = []
    edited_since = []
    content_differs = []
    missing_attachments = []
    no_longer_live = []
    could_not_check = []

    for index, page in enumerate(manifest, start=1):
        page_id = page["id"]
        title = page["title"]
        status = []

        try:
            live = api_get(f"/rest/api/content/{page_id}", {"expand": "body.storage,version"})
            live_body = normalise_line_endings(live.get("body", {}).get("storage", {}).get("value", ""))
            live_version = live.get("version", {}).get("number")
            saved_version = page.get("version")

            # A newer live version means the page was edited after
            # extraction, so its content is expected to differ - that's
            # the export being out of date, not the save going wrong, and
            # gets reported as such rather than as a content mismatch.
            if saved_version is not None and live_version is not None and live_version > saved_version:
                edited_since.append({
                    "id": page_id,
                    "title": title,
                    "reason": f"version {saved_version} extracted, version {live_version} live now",
                    "savedVersion": saved_version,
                    "liveVersion": live_version,
                })
                status.append(f"edited since (v{saved_version} -> v{live_version})")
            else:
                html_path = os.path.join(export_dir, normalise_relative_path(page["folder"]), page["html_file"])
                if not os.path.isfile(html_path):
                    content_differs.append({"id": page_id, "title": title, "path": html_path, "reason": "content.html missing on disk"})
                    status.append("content.html missing")
                else:
                    # utf-8-sig so a BOM, if anything ever added one,
                    # doesn't count as a difference on its own.
                    with open(html_path, "r", encoding="utf-8-sig") as f:
                        saved_body = normalise_line_endings(f.read())
                    if saved_body != live_body:
                        difference = describe_first_difference(saved_body, live_body)
                        content_differs.append({
                            "id": page_id,
                            "title": title,
                            "path": html_path,
                            "reason": (
                                f"first difference at character {difference['firstDifferenceAt']} "
                                f"(saved {difference['savedLength']} chars, live {difference['liveLength']})"
                            ),
                            **difference,
                        })
                        status.append("content differs")

            # Compared by original Confluence filename - the manifest only
            # records attachments that actually downloaded, under the
            # name Confluence gave them (not the sanitised name on disk).
            saved_names = {a["filename"] for a in page.get("attachments", [])}
            for name in get_live_attachment_names(page_id):
                if name not in saved_names:
                    missing_attachments.append({"id": page_id, "title": title, "reason": f"attachment '{name}'", "attachmentName": name})
                    status.append(f"attachment '{name}' not saved")

            if not status:
                matching.append(page_id)

        except urllib.error.HTTPError as e:
            if e.code == 404:
                no_longer_live.append({"id": page_id, "title": title})
                status.append("no longer live")
            elif e.code == 401:
                # A wrong login fails identically on every page - stop now
                # rather than repeating it hundreds of times. (403 is left
                # to the branch below: that's one restricted page, not a
                # bad login, and the rest are still worth checking.)
                print(f"[{index}/{len(manifest)}] {title} - 401 {e.reason}")
                print("\nConfluence rejected the login. Check the username/password (and")
                print("that this is the right site), then run it again.")
                sys.exit(1)
            else:
                could_not_check.append({"id": page_id, "title": title, "reason": f"{e.code} {e.reason}"})
                status.append(f"couldn't check: {e.code} {e.reason}")
        except Exception as e:
            could_not_check.append({"id": page_id, "title": title, "reason": str(e)})
            status.append(f"couldn't check: {e}")

        print(f"[{index}/{len(manifest)}] {title} - {', '.join(status) if status else 'matches'}")
        time.sleep(REQUEST_DELAY_SECONDS)

    print("\n--- Live content check ---")
    print(f"  Pages matching live exactly : {len(matching)} of {len(manifest)}")
    print_issue_summary("Saved content doesn't match live (same version - the save went wrong, re-extract these)", content_differs)
    print_issue_summary("Edited in Confluence since extraction (export out of date for these)", edited_since)
    print_issue_summary("Live attachments that weren't saved", missing_attachments)
    print_issue_summary("Couldn't check", could_not_check)
    print_issue_summary("No longer live (likely deleted/moved since extraction - not necessarily a problem)", no_longer_live)

    has_issues = bool(content_differs or edited_since or missing_attachments or could_not_check)
    print()
    print("Found issues - see above (and the saved report) for details." if has_issues else "No issues found - every page matches live Confluence.")

    report = {
        "manifestPath": manifest_path,
        "baseUrl": base_url,
        "checkedOn": time.strftime("%Y-%m-%d %H:%M"),
        "totalPagesInManifest": len(manifest),
        "matchingCount": len(matching),
        "contentDiffers": content_differs,
        "editedSinceExtraction": edited_since,
        "missingAttachments": missing_attachments,
        "couldNotCheck": could_not_check,
        "noLongerLive": no_longer_live,
    }
    report_path = os.path.join(export_dir, "live_content_report.json")
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

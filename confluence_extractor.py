"""
Confluence extractor - stdlib only, no pip install.

Pulls every page in a space, or just one page if you give it a page ID when
asked: dumps the raw HTML (body.storage) plus any attached images, so it's
ready for the Markdown conversion step next.

    python confluence_extractor.py

Asks for your Confluence site address and space key every time it runs,
rather than having you edit them into the file - nothing identifying this
script's real target ever needs to be typed into the file itself, so it's
always safe to share or commit as-is. Set CONFLUENCE_BASE_URL and
CONFLUENCE_SPACE_KEY as environment variables for unattended runs, same
idea as the credentials below.

Also asks what to name the export folder, defaulting to one based on the
space key (e.g. confluence_export_TEAM) - pulling a second space just
means answering that differently, nothing overwrites your first export.
Set CONFLUENCE_EXPORT_DIR to fix it in advance for unattended runs.
confluence_html_to_markdown.py (and the other scripts downstream of this
one) ask the same thing, so give them the same folder name when it's that
space's turn to be converted.

Also writes a README.md into the export folder itself (source site/space,
who ran it, the date, and page/attachment counts) - handy if this export
ever leaves your machine without this script alongside it, e.g. uploaded
as its own repo for a teammate.
"""

import base64
import datetime
import getpass
import json
import os
import re
import shutil
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request


def input_with_help(prompt, help_lines):
    """Like input(), but typing a bare "?" prints an explanation of what's
    being asked for instead of being treated as the actual answer, then
    asks again - so someone new to this doesn't have to already know what
    to type before they can find out."""
    while True:
        answer = input(prompt)
        if answer != "?":
            return answer
        for line in help_lines:
            print(line)


def getpass_with_help(prompt, help_lines):
    """Same idea as input_with_help, but for a masked password prompt -
    typing "?" isn't visibly different from typing anything else, so it's
    only noticed here, after the (masked) input comes back."""
    while True:
        answer = getpass.getpass(prompt)
        if answer != "?":
            return answer
        for line in help_lines:
            print(line)


# Asked every run rather than hardcoded, so there's nothing identifying
# your Confluence instance sitting in this file to accidentally commit or
# share. Env vars for unattended runs, otherwise prompts.
BASE_URL = os.environ.get("CONFLUENCE_BASE_URL") or input_with_help(
    "Confluence base URL: ",
    [
        "The address of your Confluence site, with no slash on the end.",
        "Copy it from your browser's address bar while viewing any",
        "Confluence page, keeping only the part before /display/ or",
        "/spaces/, e.g. https://confluence.yourcompany.com - if there's",
        "something in between (like /wiki or /confluence), keep that too.",
    ],
).strip()

# Only actually used if you leave the "page ID" prompt blank further down
# (ignored if you're pulling just one specific page), but asked up front
# either way so it's never silently assumed.
SPACE_KEY = os.environ.get("CONFLUENCE_SPACE_KEY") or input_with_help(
    "Confluence space key (leave blank if you'll give a page ID instead): ",
    [
        "The short code identifying which space to pull pages from. Find",
        "it in a page's URL while browsing Confluence, right after",
        "/display/ or /spaces/ depending on which URL style your",
        "Confluence uses:",
        "  .../display/ABC/Page+Title                -> space key is 'ABC'",
        "  .../spaces/ABC/pages/123456789/Page+Title  -> space key is 'ABC'",
        "Leave this blank if you're going to enter a page ID instead when",
        "asked next - UNLESS you're re-extracting a page to fix it in an",
        "export you already have: then still enter that space's key, so",
        "the next question suggests that export's folder.",
    ],
).strip()

# Asked every run, same as everything above, so pulling a second space (or
# re-pulling the same one later) never silently overwrites an export you
# already have - give each one its own folder name, e.g.
# confluence_export_TEAM and confluence_export_personal. Leave blank for
# the plain default. Set CONFLUENCE_EXPORT_DIR for unattended runs.
# confluence_html_to_markdown.py (and the other scripts downstream of this
# one) ask the same thing, so give them the same folder name when it's
# that space's turn to be converted.
_suggested_output_dir = f"confluence_export_{SPACE_KEY}" if SPACE_KEY else "confluence_export"
OUTPUT_DIR = os.environ.get("CONFLUENCE_EXPORT_DIR") or input_with_help(
    f"Export folder name (blank for '{_suggested_output_dir}'): ",
    [
        "Where everything gets saved on your computer, relative to",
        "wherever you run this script from. Worth naming per space (e.g.",
        "confluence_export_TEAM) if you're going to extract more than",
        "one, so a second extraction doesn't land in the same folder as",
        "the first.",
        f"Leave blank for: {_suggested_output_dir}",
    ],
).strip() or _suggested_output_dir

# env vars for unattended runs, otherwise prompts
USERNAME = os.environ.get("CONFLUENCE_USERNAME") or input_with_help(
    "Confluence username: ",
    [
        "This is the same username you use to log into Confluence in your",
        "web browser - usually your email address or your company username.",
        "If you're not sure, open Confluence in a browser first and check",
        "what you log in with there.",
    ],
)
PASSWORD = os.environ.get("CONFLUENCE_PASSWORD") or getpass_with_help(
    "Confluence password: ",
    [
        "This is the same password you use to log into Confluence in your",
        "web browser. It's masked as you type (you won't see the characters",
        "appear) - that's normal, just type it and press Enter.",
    ],
)

# Asked every run so it's never silently assumed which mode you're about to
# get. Leave blank for the whole space, or paste a page ID (from the page
# URL, e.g. .../pages/123456789/Page+Title) to pull just that one page -
# handy for a personal space or a one-off. Set CONFLUENCE_PAGE_ID for
# unattended runs. Needs no more access than opening the page normally does.
# If the space key was left blank just now (on the assumption a page ID
# is coming instead), say so plainly here rather than showing an empty
# "''" in the message below.
_space_description = f"the '{SPACE_KEY}' space you just entered" if SPACE_KEY else "a space (you left the space key blank)"
PAGE_ID = os.environ.get("CONFLUENCE_PAGE_ID") or input_with_help(
    "Page ID to extract (leave blank for the whole space): ",
    [
        f"Leave this blank to pull every page in {_space_description}.",
        "To pull just ONE page instead, open that page in Confluence and",
        "look at the URL - it's the number right after /pages/, e.g.",
        ".../pages/123456789/Page+Title means the Page ID is 123456789.",
    ],
).strip()

INTERNAL_CA_PATH = None   # e.g. r"C:\certs\company-root-ca.pem"
VERIFY_SSL = True

PAGE_SIZE = 25   # seemed like a safe default, never bothered tuning it
REQUEST_DELAY_SECONDS = 0.3   # be a polite citizen


def build_ssl_context():
    if INTERNAL_CA_PATH:
        return ssl.create_default_context(cafile=INTERNAL_CA_PATH)
    if not VERIFY_SSL:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    return ssl.create_default_context()

def build_auth_header():
    pair = f"{USERNAME}:{PASSWORD}"
    encoded = base64.b64encode(pair.encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


AUTH_HEADER = build_auth_header()
SSL_CONTEXT = build_ssl_context()

RETRY_MAX_ATTEMPTS = 3
RETRY_BASE_DELAY_SECONDS = 1.0


def request_with_retry(func):
    """Retries on 5xx/connection errors, not on 4xx (bad creds won't fix
    themselves). Without this one flaky request mid-run kills the script."""
    last_error = None
    for attempt in range(1, RETRY_MAX_ATTEMPTS + 1):
        try:
            return func()
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


def api_get(path, params=None):
    query = f"?{urllib.parse.urlencode(params)}" if params else ""
    url = f"{BASE_URL}{path}{query}"

    def do_request():
        request = urllib.request.Request(url)
        request.add_header("Authorization", AUTH_HEADER)
        request.add_header("Accept", "application/json")

        with urllib.request.urlopen(request, context=SSL_CONTEXT) as response:
            return json.loads(response.read().decode("utf-8"))

    return request_with_retry(do_request)


def download_binary(url_path, dest_path):
    url = url_path if url_path.startswith("http") else f"{BASE_URL}{url_path}"

    def do_request():
        request = urllib.request.Request(url)
        request.add_header("Authorization", AUTH_HEADER)

        with urllib.request.urlopen(request, context=SSL_CONTEXT) as response:
            with open(dest_path, "wb") as f:
                # copyfileobj streams the download straight to disk in
                # chunks - response.read() would pull the whole thing
                # into memory first, which is fine for a screenshot but
                # not for a big video or design file attached to a page.
                shutil.copyfileobj(response, f)

    request_with_retry(do_request)


def sanitise_filename(name):
    # covers the invalid chars across Windows/Mac/Linux, not just this OS
    invalid_chars = '<>:"/\\|?*'
    for ch in invalid_chars:
        name = name.replace(ch, "_")
    return name.strip()

# A real attachment name can be long ("Q3 2024 Regional Sales Review -
# Final (reviewed by finance).xlsx"), and this project's own folder depth
# (confluence_export/pages/<id>_<title>/images/<filename>) adds a fair
# bit on top of that. Windows' classic 260-character path limit is easy
# to hit on an older setup once you add all that up, so keep the saved
# filename itself well short of being the problem.
MAX_ATTACHMENT_FILENAME_LENGTH = 100

def truncate_filename(name, max_length=MAX_ATTACHMENT_FILENAME_LENGTH):
    # Keeps the file extension (.xlsx, .png, ...) intact and trims the
    # rest, so a very long name gets shorter without losing the bit that
    # says what kind of file it actually is.
    if len(name) <= max_length:
        return name
    root, ext = os.path.splitext(name)
    # rstrip here matters most for an attachment with no extension at all
    # (where this would otherwise end the whole filename in a trailing
    # space or dot - Windows silently drops that when the file's actually
    # created, but a later open/write using this same string wouldn't get
    # that same treatment, so the two stop referring to the same file).
    root = root[:max_length - len(ext)].rstrip(' .')
    return root + ext

def make_unique_filename(name, used_names):
    """Appends a numeric suffix if this name was already used on the same page,
    so two attachments that sanitise to the same name don't overwrite each other."""
    if name not in used_names:
        used_names.add(name)
        return name

    root, ext = os.path.splitext(name)
    counter = 2
    while f"{root}_{counter}{ext}" in used_names:
        counter += 1
    unique_name = f"{root}_{counter}{ext}"
    used_names.add(unique_name)
    return unique_name


def get_all_pages_in_space():
    all_pages = []
    start = 0

    while True:
        print(f"Fetching page list: start={start}, limit={PAGE_SIZE}")
        data = api_get(
            "/rest/api/content",
            {
                "spaceKey": SPACE_KEY,
                "type": "page",
                "start": start,
                "limit": PAGE_SIZE,
                "expand": "body.storage,version,ancestors,metadata.labels",
            },
        )

        results = data.get("results", [])
        all_pages.extend(results)

        # Stop on an EMPTY batch, not a short one, and move on by however
        # many actually came back rather than by PAGE_SIZE. Some Confluence
        # setups quietly hand back fewer than asked for (a server-side cap
        # on page size), and treating that as "last batch" - or skipping
        # ahead by the full PAGE_SIZE - would silently miss pages.
        if not results:
            break

        start += len(results)
        time.sleep(REQUEST_DELAY_SECONDS)

    return all_pages


def get_single_page(page_id):
    return api_get(f"/rest/api/content/{page_id}", {"expand": "body.storage,version,ancestors,metadata.labels"})


# @mentions in the storage HTML reference a user by an opaque userkey (or
# occasionally a username on older content) with no display name anywhere
# in the page itself - Confluence resolves that live, client-side. Regexes
# over the raw HTML, not real XML parsing, since this is the only thing in
# the extractor that needs to look inside page content at all.
USERKEY_PATTERN = re.compile(r'<ri:user\b[^>]*\bri:userkey="([^"]+)"')
USERNAME_PATTERN = re.compile(r'<ri:user\b[^>]*\bri:username="([^"]+)"')


def resolve_user_display_name(user_key=None, username=None):
    params = {"key": user_key} if user_key else {"username": username}
    try:
        data = api_get("/rest/api/user", params)
        return data.get("displayName")
    except Exception:
        return None


def get_attachments_for_page(page_id):
    attachments = []
    start = 0
    limit = 50

    while True:
        data = api_get(
            f"/rest/api/content/{page_id}/child/attachment",
            {"start": start, "limit": limit},
        )
        results = data.get("results", [])
        attachments.extend(results)

        # Same as the page list above - empty batch means done, and move
        # on by however many actually came back.
        if not results:
            break
        start += len(results)

    return attachments


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    pages_dir = os.path.join(OUTPUT_DIR, "pages")
    os.makedirs(pages_dir, exist_ok=True)

    # Where this export came from, saved into the export folder so the
    # verify scripts can pick it up instead of asking for the site address
    # and space key again. Written first thing rather than at the end, so
    # it's there even if this run stops partway. Never any login details.
    # A one-page re-run into a folder that already has one leaves it
    # alone, so it doesn't swap the whole space's details for one page's.
    source_path = os.path.join(OUTPUT_DIR, "export_source.json")
    if not (PAGE_ID and os.path.isfile(source_path)):
        with open(source_path, "w", encoding="utf-8") as f:
            json.dump({"baseUrl": BASE_URL.rstrip("/"), "spaceKey": SPACE_KEY, "pageId": PAGE_ID}, f, indent=2)

    if PAGE_ID:
        print(f"Fetching single page (id {PAGE_ID})...")
        pages = [get_single_page(PAGE_ID)]
    else:
        print(f"Starting extraction for space '{SPACE_KEY}'...")
        pages = get_all_pages_in_space()
    print(f"Found {len(pages)} page(s). Beginning download...\n")

    manifest = []
    failures = []
    mentioned_user_keys = set()
    mentioned_usernames = set()

    for index, page in enumerate(pages, start=1):
        page_id = page["id"]
        title = page["title"]
        safe_title = sanitise_filename(title)
        # Cutting a long title at a fixed length can land right after a
        # space in the original title, leaving a TRAILING space on the
        # folder name. The OS silently drops a trailing space when the
        # folder actually gets created, but a later write using this same
        # (untrimmed) string doesn't get that same treatment - "could not
        # find" errors, because the two no longer refer to the same
        # folder. Stripping again after cutting closes that gap.
        short_title = safe_title[:50].rstrip(' .')
        print(f"[{index}/{len(pages)}] {title}")

        try:
            html_body = page.get("body", {}).get("storage", {}).get("value", "")

            mentioned_user_keys.update(USERKEY_PATTERN.findall(html_body))
            mentioned_usernames.update(USERNAME_PATTERN.findall(html_body))

            page_folder = os.path.join(pages_dir, f"{page_id}_{short_title}")
            os.makedirs(page_folder, exist_ok=True)

            # Save raw HTML content
            html_path = os.path.join(page_folder, "content.html")
            with open(html_path, "w", encoding="utf-8") as f:
                f.write(html_body)

            # Fetch and download attachments (images etc)
            attachments = get_attachments_for_page(page_id)
            attachment_records = []

            if attachments:
                images_folder = os.path.join(page_folder, "images")
                os.makedirs(images_folder, exist_ok=True)
                used_attachment_names = set()

                for attachment in attachments:
                    # per-attachment try/except so one bad download doesn't
                    # sink the whole page - the HTML's already saved by now
                    try:
                        att_title = attachment["title"]
                        download_link = attachment["_links"]["download"]
                        safe_att_name = make_unique_filename(truncate_filename(sanitise_filename(att_title)), used_attachment_names)
                        dest_path = os.path.join(images_folder, safe_att_name)

                        download_binary(download_link, dest_path)
                        # Keep both names: the page's HTML references images by
                        # their original Confluence filename, which can differ
                        # from what actually got saved to disk (sanitised
                        # characters, or a _2 suffix from a name collision).
                        # The converter needs this mapping to resolve them back
                        # to the file that's actually there.
                        attachment_records.append({"filename": att_title, "saved_as": safe_att_name})
                    except Exception as att_err:
                        # Recorded in failures.json alongside failed pages, so
                        # confluence_verify_extraction flags it - a warning
                        # that's scrolled off screen is too easy to miss.
                        att_title = attachment.get("title", "<unknown>")
                        print(f"    Warning: failed to download attachment '{att_title}': {att_err}")
                        failures.append({"id": page_id, "title": title, "error": str(att_err), "attachmentName": att_title})

                    time.sleep(REQUEST_DELAY_SECONDS)

            # "ancestors" comes back ordered root-first, so the immediate
            # parent (if any) is the last one - used to build the
            # "Related pages" parent/children links in the SharePoint export.
            ancestors = page.get("ancestors", [])
            parent = ancestors[-1] if ancestors else None

            labels = [label["name"] for label in page.get("metadata", {}).get("labels", {}).get("results", [])]

            manifest.append({
                "id": page_id,
                "title": title,
                "folder": os.path.relpath(page_folder, OUTPUT_DIR),
                "html_file": "content.html",
                "attachments": attachment_records,
                "parent_id": parent["id"] if parent else None,
                "parent_title": parent["title"] if parent else None,
                "labels": labels,
                "version": page.get("version", {}).get("number"),
            })

        except Exception as e:
            print(f"    ERROR processing page '{title}' (id {page_id}): {e}")
            failures.append({"id": page_id, "title": title, "error": str(e)})

        time.sleep(REQUEST_DELAY_SECONDS)

    # @mentions only give us an opaque userkey/username, so resolve each
    # one (once) to the name that's actually worth showing. Best-effort:
    # a lookup failing (e.g. a deleted user) just leaves that one out,
    # the converter falls back to showing the raw identifier instead.
    user_display_names = {}
    if mentioned_user_keys or mentioned_usernames:
        print(f"\nResolving {len(mentioned_user_keys) + len(mentioned_usernames)} mentioned user(s)...")
        for user_key in mentioned_user_keys:
            display_name = resolve_user_display_name(user_key=user_key)
            if display_name:
                user_display_names[user_key] = display_name
            time.sleep(REQUEST_DELAY_SECONDS)
        for username in mentioned_usernames:
            display_name = resolve_user_display_name(username=username)
            if display_name:
                user_display_names[username] = display_name
            time.sleep(REQUEST_DELAY_SECONDS)

    user_display_names_path = os.path.join(OUTPUT_DIR, "user_display_names.json")
    manifest_path = os.path.join(OUTPUT_DIR, "manifest.json")
    failures_path = os.path.join(OUTPUT_DIR, "failures.json")

    # Re-extracting ONE page (to fix something a verify script flagged)
    # into a folder that already holds the whole space: fold this page into
    # what's already there instead of replacing it. Otherwise the manifest
    # would end up listing just this one page - every other page still on
    # disk, but invisible to the converter and the verify scripts.
    merging = bool(PAGE_ID) and os.path.isfile(manifest_path)
    if merging:
        redone_ids = {p["id"] for p in pages}
        with open(manifest_path, "r", encoding="utf-8") as f:
            existing_manifest = json.load(f)
        new_entries = {entry["id"]: entry for entry in manifest}
        # Keeps each page in its original place, swapping in the new entry.
        merged = [new_entries.pop(entry["id"], entry) for entry in existing_manifest]
        manifest = merged + list(new_entries.values())
        if os.path.isfile(failures_path):
            with open(failures_path, "r", encoding="utf-8") as f:
                failures = [fail for fail in json.load(f) if fail["id"] not in redone_ids] + failures
        if os.path.isfile(user_display_names_path):
            with open(user_display_names_path, "r", encoding="utf-8") as f:
                user_display_names = {**json.load(f), **user_display_names}
        print(f"\nUpdated {len(redone_ids)} page(s) in the existing export - the other pages already there are kept.")

    if user_display_names:
        with open(user_display_names_path, "w", encoding="utf-8") as f:
            json.dump(user_display_names, f, indent=2, ensure_ascii=False)

    # Save a manifest so the Markdown conversion step knows what's here
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    page_failures = [fail for fail in failures if "attachmentName" not in fail]
    attachment_failures = [fail for fail in failures if "attachmentName" in fail]
    print(f"\nDone. {len(manifest)} pages in the export.")
    if failures:
        print(f"{len(page_failures)} page(s) and {len(attachment_failures)} attachment(s) failed:")
        for fail in failures:
            what = f"attachment '{fail['attachmentName']}' on " if "attachmentName" in fail else ""
            print(f"  - {what}{fail['title']} (id {fail['id']}): {fail['error']}")
        with open(failures_path, "w", encoding="utf-8") as f:
            json.dump(failures, f, indent=2)
        print(f"Failure details saved to {failures_path}")
    elif os.path.isfile(failures_path):
        # Left over from an earlier run that DID have failures - nothing
        # failed this time, so it'd only make the verify scripts report
        # problems that have since been fixed.
        os.remove(failures_path)

    print(f"\nManifest saved to {manifest_path}")

    if merging:
        # The README describes the whole space's export - leave it as it is
        # rather than rewriting it to describe just this one page.
        print("Next step: run the verify scripts again to check the fix.")
        return

    # A plain-English README saved alongside the export itself - handy if
    # this folder ever leaves your machine (e.g. uploaded as its own repo
    # for a teammate), so where it came from and what's in it doesn't
    # depend on anyone remembering or still having this script around.
    total_attachments = sum(len(p.get("attachments", [])) for p in manifest)
    source_description = f"space '{SPACE_KEY}'" if SPACE_KEY else f"page id {PAGE_ID}"
    readme_lines = [
        "# Confluence export",
        "",
        f"- Source: {BASE_URL} ({source_description})",
        f"- Extracted by: {getpass.getuser()}",
        f"- Extracted on: {datetime.date.today().isoformat()}",
        f"- Pages: {len(manifest)}",
        f"- Attachments: {total_attachments}",
    ]
    if failures:
        readme_lines.append(f"- Failed to extract: {len(page_failures)} page(s), {len(attachment_failures)} attachment(s) (see failures.json)")
    readme_lines += [
        "",
        "## Why Markdown?",
        "",
        "This gets converted to Markdown rather than kept as Confluence's",
        "raw HTML (next step below) because plain text outlives any one",
        "platform - no login wall, no proprietary format, readable by a",
        "person, a diff tool, or an AI model with no conversion step",
        "first. As more of how we search, summarise, and work with",
        "documentation runs through AI tools, content that's already",
        "plain structured text is simply easier for those tools to use",
        "well - we're building for where that's heading, not just",
        "archiving where Confluence is leaving off.",
        "",
        "## Next step",
        "",
        "To convert this into Markdown, run confluence_html_to_markdown.py",
        f"(or .ps1) and give it '{OUTPUT_DIR}' as the export folder to",
        "convert when asked.",
    ]
    readme_path = os.path.join(OUTPUT_DIR, "README.md")
    try:
        with open(readme_path, "w", encoding="utf-8") as f:
            f.write("\n".join(readme_lines) + "\n")
        print(f"Wrote {readme_path}")
    except Exception as e:
        # Not worth stopping over - everything else has already been
        # saved, this is just a convenience summary.
        print(f"Couldn't write {readme_path} - {e}")

    print("Next step: convert content.html files to Markdown.")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        print(f"HTTP error {e.code}: {e.reason}")
        if e.code == 401:
            print("Check your username/password.")
        elif e.code == 403:
            print("Creds are fine, you just don't have read access to this space.")
    except urllib.error.URLError as e:
        if "certificate verify failed" in str(e.reason).lower():
            print("SSL certificate verify failed. Set INTERNAL_CA_PATH above, see")
            print("confluence_auth_test.py for the cert export instructions.")
        else:
            print(f"Connection failed: {e.reason}")

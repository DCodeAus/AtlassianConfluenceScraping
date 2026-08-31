"""
Confluence extractor - stdlib only, no pip install.

Pulls every page in a space, or just one page if you give it a page ID when
asked: dumps the raw HTML (body.storage) plus any attached images, so it's
ready for the Markdown conversion step next.

    python confluence_extractor.py

Don't commit this with real creds filled in - see README.md for the
env-var approach.
"""

import base64
import getpass
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

# fill these in - see confluence_auth_test.py if you hit an SSL cert error
BASE_URL = "https://confluence.yourcompany.com"   # no trailing slash
SPACE_KEY = "ABC"   # used unless you enter a page ID below

# env vars for unattended runs, otherwise prompts
USERNAME = os.environ.get("CONFLUENCE_USERNAME") or input("Confluence username: ")
PASSWORD = os.environ.get("CONFLUENCE_PASSWORD") or getpass.getpass("Confluence password: ")

# Asked every run so it's never silently assumed which mode you're about to
# get. Leave blank for the whole space, or paste a page ID (from the page
# URL, e.g. .../pages/123456789/Page+Title) to pull just that one page -
# handy for a personal space or a one-off. Set CONFLUENCE_PAGE_ID for
# unattended runs. Needs no more access than opening the page normally does.
PAGE_ID = os.environ.get("CONFLUENCE_PAGE_ID") or input("Page ID to extract (leave blank for the whole space): ").strip()

INTERNAL_CA_PATH = None   # e.g. r"C:\certs\company-root-ca.pem"
VERIFY_SSL = True

OUTPUT_DIR = "confluence_export"
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
                f.write(response.read())

    request_with_retry(do_request)


def sanitise_filename(name):
    # covers the invalid chars across Windows/Mac/Linux, not just this OS
    invalid_chars = '<>:"/\\|?*'
    for ch in invalid_chars:
        name = name.replace(ch, "_")
    return name.strip()

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
                "expand": "body.storage,version",
            },
        )

        results = data.get("results", [])
        all_pages.extend(results)

        if len(results) < PAGE_SIZE:
            # last batch was smaller than a full page, we're done
            break

        start += PAGE_SIZE
        time.sleep(REQUEST_DELAY_SECONDS)

    return all_pages


def get_single_page(page_id):
    return api_get(f"/rest/api/content/{page_id}", {"expand": "body.storage,version"})


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

        if len(results) < limit:
            break
        start += limit

    return attachments


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    pages_dir = os.path.join(OUTPUT_DIR, "pages")
    os.makedirs(pages_dir, exist_ok=True)

    if PAGE_ID:
        print(f"Fetching single page (id {PAGE_ID})...")
        pages = [get_single_page(PAGE_ID)]
    else:
        print(f"Starting extraction for space '{SPACE_KEY}'...")
        pages = get_all_pages_in_space()
    print(f"Found {len(pages)} page(s). Beginning download...\n")

    manifest = []
    failures = []

    for index, page in enumerate(pages, start=1):
        page_id = page["id"]
        title = page["title"]
        safe_title = sanitise_filename(title)
        print(f"[{index}/{len(pages)}] {title}")

        try:
            html_body = page.get("body", {}).get("storage", {}).get("value", "")

            page_folder = os.path.join(pages_dir, f"{page_id}_{safe_title[:50]}")
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
                        safe_att_name = make_unique_filename(sanitise_filename(att_title), used_attachment_names)
                        dest_path = os.path.join(images_folder, safe_att_name)

                        download_binary(download_link, dest_path)
                        attachment_records.append(safe_att_name)
                    except Exception as att_err:
                        # TODO: track these and retry at the end instead of just
                        # warning and moving on - hasn't been a big enough problem yet
                        att_title = attachment.get("title", "<unknown>")
                        print(f"    Warning: failed to download attachment '{att_title}': {att_err}")

                    time.sleep(REQUEST_DELAY_SECONDS)

            manifest.append({
                "id": page_id,
                "title": title,
                "folder": os.path.relpath(page_folder, OUTPUT_DIR),
                "html_file": "content.html",
                "attachments": attachment_records,
                "version": page.get("version", {}).get("number"),
            })

        except Exception as e:
            print(f"    ERROR processing page '{title}' (id {page_id}): {e}")
            failures.append({"id": page_id, "title": title, "error": str(e)})

        time.sleep(REQUEST_DELAY_SECONDS)

    # Save a manifest so the Markdown conversion step knows what's here
    manifest_path = os.path.join(OUTPUT_DIR, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    print(f"\nDone. {len(manifest)} pages extracted successfully.")
    if failures:
        print(f"{len(failures)} pages failed, see failures below:")
        for fail in failures:
            print(f"  - {fail['title']} (id {fail['id']}): {fail['error']}")
        failures_path = os.path.join(OUTPUT_DIR, "failures.json")
        with open(failures_path, "w", encoding="utf-8") as f:
            json.dump(failures, f, indent=2)
        print(f"Failure details saved to {failures_path}")

    print(f"\nManifest saved to {manifest_path}")
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

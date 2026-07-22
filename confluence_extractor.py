"""
Confluence full space extractor.
Standard library only, no pip install required.

Pulls every page in a given space: saves the raw HTML content (body.storage)
and downloads every attached image, ready for the Markdown conversion step.

Run:
    python confluence_extractor.py

DO NOT commit this file with real USERNAME/PASSWORD filled in. See README.md
in this repo for the recommended environment-variable approach.
"""

import base64
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

# ============================================================
# CONFIG - fill these in (see confluence_auth_test.py notes on
# INTERNAL_CA_PATH if you hit an SSL certificate error)
# ============================================================
BASE_URL = "https://confluence.yourcompany.com"   # no trailing slash
USERNAME = "your.username"
PASSWORD = "your-password"
SPACE_KEY = "ABC"

INTERNAL_CA_PATH = None   # e.g. r"C:\certs\company-root-ca.pem"
VERIFY_SSL = True

OUTPUT_DIR = "confluence_export"
PAGE_SIZE = 25            # how many pages to request per API call
REQUEST_DELAY_SECONDS = 0.3   # small pause between calls, be a polite citizen
# ============================================================


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


def api_get(path, params=None):
    """GET request against the Confluence REST API, returns parsed JSON."""
    query = f"?{urllib.parse.urlencode(params)}" if params else ""
    url = f"{BASE_URL}{path}{query}"

    request = urllib.request.Request(url)
    request.add_header("Authorization", AUTH_HEADER)
    request.add_header("Accept", "application/json")

    with urllib.request.urlopen(request, context=SSL_CONTEXT) as response:
        return json.loads(response.read().decode("utf-8"))


def download_binary(url_path, dest_path):
    """Downloads a binary file (e.g. an attachment/image) to disk."""
    url = url_path if url_path.startswith("http") else f"{BASE_URL}{url_path}"

    request = urllib.request.Request(url)
    request.add_header("Authorization", AUTH_HEADER)

    with urllib.request.urlopen(request, context=SSL_CONTEXT) as response:
        with open(dest_path, "wb") as f:
            f.write(response.read())


def sanitise_filename(name):
    """Strips characters that aren't safe in Windows/Mac/Linux filenames."""
    invalid_chars = '<>:"/\\|?*'
    for ch in invalid_chars:
        name = name.replace(ch, "_")
    return name.strip()


def get_all_pages_in_space():
    """Paginates through the space, returns a list of page summaries."""
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


def get_attachments_for_page(page_id):
    """Returns a list of attachment metadata for a given page."""
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

    print(f"Starting extraction for space '{SPACE_KEY}'...")
    pages = get_all_pages_in_space()
    print(f"Found {len(pages)} pages. Beginning download...\n")

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

                for attachment in attachments:
                    att_title = attachment["title"]
                    download_link = attachment["_links"]["download"]
                    safe_att_name = sanitise_filename(att_title)
                    dest_path = os.path.join(images_folder, safe_att_name)

                    try:
                        download_binary(download_link, dest_path)
                        attachment_records.append(safe_att_name)
                    except Exception as att_err:
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
            print("Credentials are valid but you lack read access to this space.")
    except urllib.error.URLError as e:
        reason_text = str(e.reason)
        if "CERTIFICATE_VERIFY_FAILED" in reason_text or "certificate verify failed" in reason_text.lower():
            print("SSL certificate verify failed. Set INTERNAL_CA_PATH above, see")
            print("confluence_auth_test.py for the cert export instructions.")
        else:
            print(f"Connection failed: {e.reason}")

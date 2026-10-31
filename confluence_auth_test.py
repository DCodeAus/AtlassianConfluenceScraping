"""
Step 1 - quick check that your Confluence URL/creds actually work before
bothering with the full extractor. Stdlib only, nothing to install.

    python confluence_auth_test.py

Asks for your Confluence site address, space key, and login every time it
runs, rather than having you edit them into the file - nothing identifying
this script's real target ever needs to be typed into the file itself, so
it's always safe to share or commit as-is. Set CONFLUENCE_BASE_URL and
CONFLUENCE_SPACE_KEY as environment variables for unattended runs, same
idea as the credentials below.

Prints a page title on success. 401/403? Read the except block below.
"""

import json
import os
import urllib.error

# Everything the scripts here have in common - the questions, talking to
# Confluence, reading an export folder - lives in confluence_common.py, so
# a fix there fixes every script at once. It has to be in the same folder
# as this one.
try:
    from confluence_common import Confluence, ask_base_url, ask_login, input_with_help
except ImportError:
    print("Can't find confluence_common.py (or it's out of date) - it needs to be")
    print("in the same folder as this script. Download the whole repository")
    print("rather than just this one file.")
    raise SystemExit(1)


# Set CONFLUENCE_BASE_URL as an env var for unattended runs (cron etc),
# otherwise it just prompts.
BASE_URL = ask_base_url()
SPACE_KEY = os.environ.get("CONFLUENCE_SPACE_KEY") or input_with_help(
    "Confluence space key: ",
    [
        "The short code for the specific space you want to read. Find it",
        "in a page's URL while browsing Confluence, right after /display/",
        "or /spaces/ depending on which URL style your Confluence uses:",
        "  .../display/ABC/Page+Title                -> space key is 'ABC'",
        "  .../spaces/ABC/pages/123456789/Page+Title  -> space key is 'ABC'",
    ],
).strip()

# Set CONFLUENCE_USERNAME / CONFLUENCE_PASSWORD as env vars for unattended
# runs (cron etc), otherwise it just prompts.
USERNAME, PASSWORD = ask_login()

# "certificate verify failed" -> your org's internal CA isn't in Python's
# trust store. That's set once for every script, in confluence_common.py
# (INTERNAL_CA_PATH, or the CONFLUENCE_CA_FILE env var) - see there for
# how to get the certificate file.
confluence = Confluence(BASE_URL, USERNAME, PASSWORD)
params = {"spaceKey": SPACE_KEY, "limit": "1", "expand": "body.storage"}

try:
    with confluence.open("/rest/api/content", params, want_json=True) as response:
        status_code = response.getcode()
        body = response.read().decode("utf-8")
        print("Status code:", status_code)

        data = json.loads(body)
        results = data.get("results", [])
        if results:
            print("Success! First page title:", results[0]["title"])
            print("Total pages in this batch (max 1 requested):", data.get("size"))
            # Getting a page back doesn't prove the login was used - some
            # setups let you in as an anonymous visitor instead, which can
            # still see open spaces. This says which it was.
            confluence.check_signed_in()
        else:
            print("Connected, but no pages returned. Check SPACE_KEY is correct.")

except urllib.error.HTTPError as e:
    print("Status code:", e.code)
    if e.code == 401:
        print("401. Wrong username/password, or SSO is enforced and basic auth is off -")
        print("ask IT whether the REST API accepts basic auth or needs SSO/SAML.")
    elif e.code == 403:
        print("403. Creds are fine, you just don't have read access to this space.")
    else:
        print("Unexpected error, first 500 chars of body:")
        print(e.read().decode("utf-8", errors="replace")[:500])

except urllib.error.URLError as e:
    reason_text = str(e.reason)
    if "certificate verify failed" in reason_text.lower():
        print("SSL certificate verify failed - see the INTERNAL_CA_PATH note in confluence_common.py.")
    else:
        print("Connection failed:", e.reason)
        print("Check BASE_URL and that you're on the right network/VPN.")

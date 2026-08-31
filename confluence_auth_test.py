"""
Step 1 - quick check that your Confluence URL/creds actually work before
bothering with the full extractor. Stdlib only, nothing to install.

    python confluence_auth_test.py

Prints a page title on success. 401/403? Read the except block below.
"""

import base64
import getpass
import json
import os
import ssl
import urllib.request
import urllib.parse
import urllib.error

# --- fill these in ---
BASE_URL = "https://confluence.yourcompany.com"   # no trailing slash
SPACE_KEY = "ABC"                                   # it's in the page URL, /display/ABC/Page+Title

# Set CONFLUENCE_USERNAME / CONFLUENCE_PASSWORD as env vars for unattended
# runs (cron etc), otherwise it just prompts.
USERNAME = os.environ.get("CONFLUENCE_USERNAME") or input("Confluence username: ")
PASSWORD = os.environ.get("CONFLUENCE_PASSWORD") or getpass.getpass("Confluence password: ")

# "certificate verify failed" -> your org's internal CA isn't in Python's
# trust store (your browser trusts it, Python keeps its own list - and
# unlike the .ps1 version, it does NOT read the Windows cert store). Export
# the root CA as base64 X.509 from the browser padlock -> certificate
# viewer -> certification path -> top entry -> export, and point this at it.
INTERNAL_CA_PATH = None  # e.g. r"C:\certs\company-root-ca.pem"
VERIFY_SSL = True  # False = skip verification, fine for a five-minute test, don't leave it off

if INTERNAL_CA_PATH:
    ssl_context = ssl.create_default_context(cafile=INTERNAL_CA_PATH)
elif not VERIFY_SSL:
    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE
else:
    ssl_context = ssl.create_default_context()

params = {"spaceKey": SPACE_KEY, "limit": "1", "expand": "body.storage"}
query_string = urllib.parse.urlencode(params)
url = f"{BASE_URL}/rest/api/content?{query_string}"

# Build the basic auth header manually
credentials = f"{USERNAME}:{PASSWORD}"
encoded_credentials = base64.b64encode(credentials.encode("utf-8")).decode("ascii")

request = urllib.request.Request(url)
request.add_header("Authorization", f"Basic {encoded_credentials}")
request.add_header("Accept", "application/json")

try:
    with urllib.request.urlopen(request, context=ssl_context) as response:
        status_code = response.getcode()
        body = response.read().decode("utf-8")
        print("Status code:", status_code)

        data = json.loads(body)
        results = data.get("results", [])
        if results:
            print("Success! First page title:", results[0]["title"])
            print("Total pages in this batch (max 1 requested):", data.get("size"))
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
        print("SSL certificate verify failed - see the INTERNAL_CA_PATH note above.")
    else:
        print("Connection failed:", e.reason)
        print("Check BASE_URL and that you're on the right network/VPN.")

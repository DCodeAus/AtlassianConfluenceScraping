"""
Step 1: Test Confluence Server/Data Center REST API access.
Uses only Python's standard library, so no pip install is needed.

Fill in the four values below, then run:
    python confluence_auth_test.py

If it prints a page title, you're good to move to the full extractor.
If you get 401/403, see the troubleshooting notes at the bottom.
"""

import base64
import json
import ssl
import urllib.request
import urllib.parse
import urllib.error

# --- Fill these in ---
BASE_URL = "https://confluence.yourcompany.com"   # no trailing slash
USERNAME = "your.username"                         # same as browser login
PASSWORD = "your-password"                          # same as browser login
SPACE_KEY = "ABC"                                   # find in the page URL, e.g. /display/ABC/Page+Title

# --- SSL certificate handling ---
# Got "SSL certificate verify failed"? Your Confluence server likely uses a
# certificate from your organisation's internal Certificate Authority, which
# Python doesn't trust by default (even though your browser does).
#
# OPTION A (proper fix): if IT gave you a .pem/.crt file for the internal CA,
# point to it here and leave VERIFY_SSL as True:
INTERNAL_CA_PATH = None  # e.g. r"C:\certs\company-root-ca.pem"
VERIFY_SSL = True

if INTERNAL_CA_PATH:
    ssl_context = ssl.create_default_context(cafile=INTERNAL_CA_PATH)
elif not VERIFY_SSL:
    # OPTION B (quick test only): disables certificate verification entirely.
    # This means the connection can no longer confirm it's actually talking
    # to your real Confluence server and not something impersonating it.
    # Fine for a five-minute test on a trusted internal network you're
    # already VPN'd/logged into. NOT something to leave in a script that
    # handles credentials long-term. Get the proper CA cert from IT when you can.
    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE
else:
    ssl_context = ssl.create_default_context()
# ---------------------

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
        print("401 Unauthorized. Wrong username/password, OR your org requires SSO")
        print("and has disabled basic auth for the API. Ask IT: 'does the Confluence")
        print("REST API accept basic auth, or is it SSO/SAML only?'")
    elif e.code == 403:
        print("403 Forbidden. Credentials are valid but you lack read access to this space.")
    else:
        error_body = e.read().decode("utf-8", errors="replace")
        print("Unexpected error. First 500 chars of body:")
        print(error_body[:500])

except urllib.error.URLError as e:
    print("Connection failed:", e.reason)
    print("Check BASE_URL is correct and you're on the right network/VPN.")

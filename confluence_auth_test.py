"""
Step 1: Test Confluence Server/Data Center REST API access.
Uses only Python's standard library, so no pip install is needed.

Fill in the four values below, then run:
    python confluence_auth_test.py

If it prints a page title, you're good to move to the full extractor.
If you get 401/403, see the troubleshooting notes at the bottom.
"""

import base64
import getpass
import json
import ssl
import urllib.request
import urllib.parse
import urllib.error

# --- Fill these in ---
BASE_URL = "https://confluence.yourcompany.com"   # no trailing slash
SPACE_KEY = "ABC"                                   # find in the page URL, e.g. /display/ABC/Page+Title

# Username and password are asked for at runtime rather than hardcoded,
# so this file is safe to share without exposing credentials.
USERNAME = input("Confluence username: ")
PASSWORD = getpass.getpass("Confluence password: ")   # input is hidden, not echoed to screen

# --- SSL certificate handling ---
# Got "SSL certificate verify failed"? Your Confluence server likely uses a
# certificate from your organisation's internal Certificate Authority, which
# Python doesn't trust by default (even though your browser does).
#
# OPTION A (proper fix): if IT gave you a .pem/.crt file for the internal CA,
# point to it here and leave VERIFY_SSL as True.
#
# Don't have the file yet? You can usually export it yourself:
#
#   Method 1 - from your browser (try this first):
#     1. Open the Confluence page in Chrome or Edge.
#     2. Click the padlock icon in the address bar > "Connection is secure"
#        > "Certificate is valid" (wording varies slightly by browser).
#     3. In the certificate viewer, open the "Certification Path" or
#        "Certificate hierarchy" tab. This shows a chain, e.g.:
#            Company Root CA          <- this is the one you want
#            Company Issuing CA       <- (sometimes present)
#            confluence.yourcompany.com  (the site cert itself, not this one)
#     4. Click the TOP-MOST entry (the root, not the site cert) > "Export"
#        or "Copy to File".
#     5. Choose "Base-64 encoded X.509 (.CER)" format (same thing as .pem,
#        just a different extension). Save it, e.g. C:\certs\company-root-ca.pem
#
#   Method 2 - from Windows' own certificate store (it's already trusted
#   there, which is why your browser works):
#     1. Win + R, type certmgr.msc, Enter.
#     2. Go to Trusted Root Certification Authorities > Certificates.
#     3. Find the entry with your company's name.
#     4. Right-click > All Tasks > Export > "Base-64 encoded X.509".
#
#   Neither works? Ask IT: "what's our internal root CA cert, I need the
#   .pem for a script" - this is a normal, low-friction ask, separate from
#   needing any admin access to Confluence itself.
#
# IMPORTANT DIFFERENCE FROM POWERSHELL: even if you've already imported this
# cert into Windows' Trusted Root Certification Authorities store (e.g. via
# certmgr.msc), Python does NOT automatically use that store. You still need
# to export the .pem file and point INTERNAL_CA_PATH at it below. PowerShell
# reads the Windows store directly, Python keeps its own separate trust list.
#
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
    reason_text = str(e.reason)
    if "CERTIFICATE_VERIFY_FAILED" in reason_text or "certificate verify failed" in reason_text.lower():
        print("SSL certificate verify failed.")
        print("Your internal CA cert isn't trusted by Python yet. Set INTERNAL_CA_PATH")
        print("above to the exported .pem file (see the instructions above it), then")
        print("run this again. See the note above INTERNAL_CA_PATH about why importing")
        print("into Windows' certificate store alone isn't enough for Python.")
    else:
        print("Connection failed:", e.reason)
        print("Check BASE_URL is correct and you're on the right network/VPN.")

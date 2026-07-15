"""
Step 1: Test Confluence Server/Data Center REST API access.

Fill in the four values below, then run:
    pip install requests
    python confluence_auth_test.py

If it prints a page title, you're good to move to the full extractor.
If you get 401/403, see the troubleshooting notes at the bottom.
"""

import requests
from requests.auth import HTTPBasicAuth

# --- Fill these in ---
BASE_URL = "https://confluence.yourcompany.com"   # no trailing slash
USERNAME = "your.username"                         # same as browser login
PASSWORD = "your-password"                          # same as browser login
SPACE_KEY = "ABC"                                   # find in the page URL, e.g. /display/ABC/Page+Title
# ---------------------

session = requests.Session()
session.auth = HTTPBasicAuth(USERNAME, PASSWORD)
session.headers.update({"Accept": "application/json"})

url = f"{BASE_URL}/rest/api/content"
params = {"spaceKey": SPACE_KEY, "limit": 1, "expand": "body.storage"}

resp = session.get(url, params=params)

print("Status code:", resp.status_code)

if resp.status_code == 200:
    data = resp.json()
    results = data.get("results", [])
    if results:
        print("Success! First page title:", results[0]["title"])
        print("Total pages in this batch (max 1 requested):", data.get("size"))
    else:
        print("Connected, but no pages returned — check SPACE_KEY is correct.")
elif resp.status_code == 401:
    print("401 Unauthorized — wrong username/password, OR your org requires SSO")
    print("and has disabled basic auth for the API. Ask IT: 'does the Confluence")
    print("REST API accept basic auth, or is it SSO/SAML only?'")
elif resp.status_code == 403:
    print("403 Forbidden — credentials are valid but you lack read access to this space.")
else:
    print("Unexpected response. First 500 chars of body:")
    print(resp.text[:500])

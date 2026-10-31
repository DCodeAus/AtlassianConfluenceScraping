"""
A fake Confluence for testing the scripts - stdlib only.

Not something you need for a real extraction. tests/run_tests.py starts
this in the background, points every script at it, and checks what they
do. It answers the same REST API calls a real Confluence Server/Data
Center does, from the made-up space in test_site.json, and deliberately
behaves like the awkward real servers these scripts had to cope with:

  - hands back at most 10 results per request, whatever was asked for
    (a server-side cap - the extractor once silently missed pages because
    of exactly this)
  - sends JSON with no charset, so anything that guesses the encoding
    garbles accents and curly quotes
  - one attachment download fails with a 500, one "image" is really a
    login page, one attachment has no recorded size and one has the
    wrong recorded size
  - only accepts the login testuser / testpass

    python tests/mock_confluence.py 8765 tests/test_site.json

The site file is read again on every request, so a test can change it
while the server runs (e.g. set "anonymous": true to pretend the login
wasn't recognised).
"""

import json
import re
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# testuser:testpass as a Basic auth header
AUTH = "Basic dGVzdHVzZXI6dGVzdHBhc3M="
# Confluence never hands back more than this many results per request here.
MAX_BATCH = 10

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
SITE_FILE = sys.argv[2] if len(sys.argv) > 2 else "test_site.json"
BASE = f"http://127.0.0.1:{PORT}"


def render(page):
    """A rough stand-in for Confluence's own rendering (body.export_view):
    images become <img> tags pointing at Confluence's download address, and
    an include macro shows the text it would have pulled in."""
    body = re.sub(
        r'<ac:image><ri:attachment ri:filename="([^"]+)"/></ac:image>',
        lambda m: f'<img src="{BASE}/download/attachments/{page["id"]}/{urllib.parse.quote(m.group(1))}?version=1&amp;api=v2">',
        page["body"],
    )
    return re.sub(
        r'<ac:structured-macro ac:name="include">.*?</ac:structured-macro>',
        '<div class="included">INCLUDED TEXT FROM ANOTHER PAGE</div>',
        body,
        flags=re.S,
    )


def page_json(page, expand):
    data = {
        "id": page["id"],
        "type": "page",
        "title": page["title"],
        "_links": {"webui": f"/spaces/{page['space']}/pages/{page['id']}"},
    }
    if "body.export_view" in expand:
        if page.get("renderFails"):
            raise RuntimeError("render failed")
        data["body"] = {"export_view": {"value": render(page), "representation": "export_view"}}
    if "history" in expand:
        data["history"] = {"createdDate": "2021-03-04T10:00:00.000+11:00", "createdBy": {"displayName": "Original Author"}}
    if "body.storage" in expand:
        data["body"] = {"storage": {"value": page["body"], "representation": "storage"}}
    if "version" in expand:
        data["version"] = {"number": page["version"], "when": "2025-06-07T09:30:00.000+10:00", "by": {"displayName": "Last Editor É"}}
    if "ancestors" in expand:
        data["ancestors"] = page.get("ancestors", [])
    if "metadata.labels" in expand:
        data["metadata"] = {"labels": {"results": [{"name": label} for label in page.get("labels", [])]}}
    return data


class FakeConfluence(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body=b"", content_type="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)  # no charset, like real Confluence often
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.headers.get("Authorization") != AUTH:
            return self.send(401, b'{"message":"unauthorized"}')
        with open(SITE_FILE, encoding="utf-8") as f:
            site = json.load(f)
        pages = {page["id"]: page for page in site["pages"]}
        url = urllib.parse.urlparse(self.path)
        query = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        parts = [urllib.parse.unquote(x) for x in url.path.strip("/").split("/")]
        expand = query.get("expand", "")

        # Every page in a space, a batch at a time
        if parts[:3] == ["rest", "api", "content"] and len(parts) == 3:
            start, limit = int(query.get("start", 0)), min(MAX_BATCH, int(query.get("limit", 25)))
            in_space = [p for p in site["pages"] if p["space"] == query.get("spaceKey") and query.get("type", "page") == "page"]
            results = [page_json(p, expand) for p in in_space[start:start + limit]]
            return self.send(200, json.dumps({"results": results, "size": len(results)}).encode())

        # One page
        if parts[:3] == ["rest", "api", "content"] and len(parts) == 4:
            page = pages.get(parts[3])
            if not page:
                return self.send(404, b"{}")
            try:
                return self.send(200, json.dumps(page_json(page, expand)).encode())
            except RuntimeError:
                return self.send(500, b'{"message":"render failed"}')

        # A page's attachments, a batch at a time
        if parts[:3] == ["rest", "api", "content"] and parts[4:] == ["child", "attachment"]:
            page = pages.get(parts[3])
            if not page:
                return self.send(404, b"{}")
            start, limit = int(query.get("start", 0)), min(MAX_BATCH, int(query.get("limit", 25)))
            results = []
            for attachment in page.get("attachments", [])[start:start + limit]:
                result = {"title": attachment["title"], "_links": {"download": f"/download/attachments/{page['id']}/{urllib.parse.quote(attachment['title'])}"}}
                if not attachment.get("nosize"):
                    result["extensions"] = {"fileSize": attachment.get("realSize", len(attachment["content"].encode()))}
                results.append(result)
            return self.send(200, json.dumps({"results": results}).encode())

        # Downloading an attachment
        if parts[0] == "download":
            page = pages.get(parts[2])
            for attachment in (page or {}).get("attachments", []):
                if attachment["title"] == parts[3]:
                    if attachment.get("broken"):
                        return self.send(500, b"boom", "text/plain")
                    return self.send(200, attachment["content"].encode(), "application/octet-stream")
            return self.send(404, b"")

        # Who the login belongs to - or nobody, to test the anonymous warning
        if parts[:4] == ["rest", "api", "user", "current"] and site.get("anonymous"):
            return self.send(200, json.dumps({"type": "anonymous", "displayName": "Anonymous"}).encode())
        if parts[:3] == ["rest", "api", "user"]:
            return self.send(200, json.dumps({"type": "known", "displayName": "Jane Mentioned"}).encode())

        self.send(404, b"{}")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), FakeConfluence).serve_forever()

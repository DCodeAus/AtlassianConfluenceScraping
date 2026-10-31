"""
Shared code for every Python script in this folder - stdlib only, no pip
install.

Not something you run yourself. Every confluence_*.py script (and
repair_garbled_text.py) imports what it needs from here, so the things
they all do the same way - asking a question with "?" help, finding an
export folder and what it came from, talking to Confluence, reading
Confluence's page HTML - are written once, and a fix here fixes every
script at once.

Keep this file in the same folder as the scripts. Downloading just one
script on its own won't work - grab the whole repository.

The one part worth editing by hand is the SSL/certificate section just
below, if your organisation uses its own certificate authority - and
since every script reads it from here, it only needs doing once.
"""

import base64
import getpass
import json
import os
import re
import shutil
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


# --- Connection settings, shared by every script that talks to Confluence ---

# "certificate verify failed" -> your org's internal CA isn't in Python's
# trust store (your browser trusts it, Python keeps its own list - and
# unlike the .ps1 versions, it does NOT read the Windows cert store).
# Export the root CA as base64 X.509 from the browser padlock ->
# certificate viewer -> certification path -> top entry -> export, and
# point this at it - or set CONFLUENCE_CA_FILE to its path instead of
# editing this file.
INTERNAL_CA_PATH = os.environ.get("CONFLUENCE_CA_FILE") or None   # e.g. r"C:\certs\company-root-ca.pem"
VERIFY_SSL = True   # False = skip verification, fine for a five-minute test, don't leave it off

REQUEST_DELAY_SECONDS = 0.3   # be a polite citizen - a short pause between requests
RETRY_MAX_ATTEMPTS = 3
RETRY_BASE_DELAY_SECONDS = 1.0


# --- Asking questions ---

def input_with_help(prompt, help_lines):
    """Like input(), but typing a bare "?" prints an explanation of what's
    being asked for instead of being treated as the actual answer, then
    asks again - so someone new to this doesn't have to already know what
    to type before they can find out."""
    while True:
        answer = input(prompt)
        if answer.strip() != "?":
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


def ask_yes_no(prompt):
    """A y/N question - anything but "y" (including just pressing Enter)
    counts as no, so the safe answer is always the default. So does
    nothing at all to read (the input's been closed)."""
    try:
        return input(prompt).strip().lower() == "y"
    except EOFError:
        print()
        return False


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


BASE_URL_HELP = [
    "The address of your Confluence site, with no slash on the end.",
    "Copy it from your browser's address bar while viewing any",
    "Confluence page, keeping only the part before /display/ or",
    "/spaces/, e.g. https://confluence.yourcompany.com - if there's",
    "something in between (like /wiki or /confluence), keep that too.",
]


def ask_base_url(saved_value=None):
    """The Confluence site address - CONFLUENCE_BASE_URL, then the one
    saved with the export (if there is one), then asked. Asked every run
    rather than hardcoded, so there's nothing identifying your Confluence
    in any of these files to accidentally commit or share. Any slash on
    the end is dropped, since every address built from this adds its own."""
    return env_saved_or_ask(
        "CONFLUENCE_BASE_URL", saved_value, "Confluence base URL",
        lambda: input_with_help("Confluence base URL: ", BASE_URL_HELP),
    ).strip().rstrip("/")


def ask_login():
    """Username and password - CONFLUENCE_USERNAME / CONFLUENCE_PASSWORD
    for unattended runs, otherwise asked. Only ever held in memory, never
    written anywhere."""
    username = os.environ.get("CONFLUENCE_USERNAME") or input_with_help(
        "Confluence username: ",
        [
            "This is the same username you use to log into Confluence in your",
            "web browser - usually your email address or your company username.",
            "If you're not sure, open Confluence in a browser first and check",
            "what you log in with there.",
        ],
    )
    password = os.environ.get("CONFLUENCE_PASSWORD") or getpass_with_help(
        "Confluence password: ",
        [
            "This is the same password you use to log into Confluence in your",
            "web browser. It's masked as you type (you won't see the characters",
            "appear) - that's normal, just type it and press Enter.",
        ],
    )
    return username, password


def ask_export_dir(prompt, help_lines, default="confluence_export", args=None):
    """Which export folder to work on - the first command-line argument if
    there is one, then CONFLUENCE_EXPORT_DIR, then asked. Windows "Copy as
    path" and dragging a folder into the terminal both wrap the path in
    quotes, so those are stripped and either works."""
    if args:
        answer = args[0]
    else:
        answer = os.environ.get("CONFLUENCE_EXPORT_DIR") or input_with_help(prompt, help_lines)
    return answer.strip().strip('"').strip("'") or default


def suggest_output_dir(export_dir, prefix):
    """A matching output folder name for an export folder - with prefix
    "confluence_markdown_export", confluence_export_TEAM becomes
    confluence_markdown_export_TEAM - so converting a second space's
    export lands in its own folder instead of merging into (and
    overwriting) the first one's."""
    if export_dir == "confluence_export":
        return prefix
    if export_dir.startswith("confluence_export"):
        return prefix + export_dir[len("confluence_export"):]
    return f"{prefix}_{export_dir}"


# --- Reading an export folder ---

def read_json(path):
    """utf-8-sig, not utf-8: a JSON file written by Windows PowerShell 5.1
    can start with a BOM (an invisible marker), and plain "utf-8" chokes
    outright on that with a JSONDecodeError. utf-8-sig reads a file with
    or without one."""
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def load_export_manifest(export_dir):
    """An export folder's manifest.json (the extractor's list of every page
    it saved) and where it was read from - or a plain explanation and stop,
    if the folder or the manifest isn't there. Checked before anything
    else is asked, so a mistyped folder doesn't cost you typing your
    password first."""
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
    return read_json(manifest_path), manifest_path


def write_export_source(export_dir, base_url, space_key, page_id):
    """Where an export came from, saved into the export folder so the
    other scripts can pick it up instead of asking for the site address
    and space key again. Never any login details."""
    with open(os.path.join(export_dir, "export_source.json"), "w", encoding="utf-8") as f:
        json.dump({"baseUrl": base_url.rstrip("/"), "spaceKey": space_key, "pageId": page_id}, f, indent=2)


def read_export_source(export_dir):
    """What write_export_source saved (site address and space key).
    Exports made before that file existed still have the same details on
    the "- Source:" line of their README.md, so fall back to reading
    that. An empty dict if neither is there."""
    source_path = os.path.join(export_dir, "export_source.json")
    if os.path.isfile(source_path):
        try:
            return read_json(source_path)
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


def load_user_display_names(export_dir):
    """@mentions only carry an opaque userkey/username in the page HTML -
    user_display_names.json is the extractor's best-effort lookup of those
    to an actual name. Empty if the extractor didn't find any."""
    path = os.path.join(export_dir, "user_display_names.json")
    if not os.path.exists(path):
        return {}
    return read_json(path)


def build_attachment_map(attachments):
    """A page's manifest "attachments" entry as original Confluence
    filename -> whatever it actually got saved as (they differ when a
    name had characters Windows won't allow, or was too long)."""
    attachment_map = {}
    for entry in attachments:
        if isinstance(entry, dict):
            attachment_map[entry["filename"]] = entry["saved_as"]
        else:
            # Manifest from before this mapping existed: the saved filename
            # was assumed to match the original one-for-one, which is the
            # best we can do without re-extracting.
            attachment_map[entry] = entry
    return attachment_map


def normalise_relative_path(path_str):
    """A manifest "folder" from the PowerShell extractor uses backslashes
    (and one from the Python extractor on a Mac uses forward slashes), so
    rebuild it with this machine's own separator before joining it onto a
    path."""
    parts = re.split(r"[\\/]+", path_str)
    return os.path.join(*parts) if parts else path_str


def sanitise_filename(name):
    # covers the invalid chars across Windows/Mac/Linux, not just this OS
    invalid_chars = '<>:"/\\|?*'
    for ch in invalid_chars:
        name = name.replace(ch, "_")
    return name.strip()


def print_issue_summary(label, items, report_name, show_max=15):
    """One heading with a count, then the first few items under it - the
    rest are in the saved report, so a long list doesn't scroll the
    summary off the screen."""
    if not items:
        print(f"  {label} : none")
        return
    print(f"  {label} : {len(items)}")
    for item in items[:show_max]:
        if "reason" in item:
            detail = f" - {item['reason']}"
        elif "attachmentName" in item:
            detail = f" - attachment '{item['attachmentName']}'"
        else:
            detail = ""
        print(f"    - [{item['id']}] {item['title']}{detail}")
    if len(items) > show_max:
        print(f"    ... and {len(items) - show_max} more (full list in {report_name})")


# --- Confluence's page HTML ("storage format") ---

# Confluence's storage format is XHTML plus Confluence's own ac:/ri:
# elements (macros, images, attachment refs) - declare the namespaces so the
# parser doesn't choke on them.
NAMESPACE_DECLARATIONS = (
    'xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/" '
    'xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/"'
)


# Named entities that turn up in content pasted from Word/Outlook. XML only
# knows amp/lt/gt/apos/quot, so anything else here crashes ET.fromstring on
# an otherwise fine page. Hit a new one? The error names it - add it below.
KNOWN_HTML_ENTITIES = {
    "nbsp": " ",
    "mdash": "—",
    "ndash": "–",
    "hellip": "…",
    "lsquo": "‘",
    "rsquo": "’",
    "ldquo": "“",
    "rdquo": "”",
    "trade": "™",
    "copy": "©",
    "reg": "®",
}


def escape_non_xml_entities(raw_html):
    for name, char in KNOWN_HTML_ENTITIES.items():
        raw_html = raw_html.replace(f"&{name};", char)
    return raw_html


def local_name(tag):
    """ElementTree spells a namespaced tag as {namespace-url}name - this is
    just the name, so code can ask for "image" rather than the whole URL."""
    return tag.split("}", 1)[1] if "}" in tag else tag


def find_child_by_local_name(elem, name):
    for child in elem:
        if local_name(child.tag) == name:
            return child
    return None


def get_attr(elem, local_attr_name):
    for key, value in elem.attrib.items():
        if local_name(key) == local_attr_name:
            return value
    return None


# --- Talking to Confluence ---

def build_ssl_context():
    if INTERNAL_CA_PATH:
        return ssl.create_default_context(cafile=INTERNAL_CA_PATH)
    if not VERIFY_SSL:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    return ssl.create_default_context()


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


class Confluence:
    """One connection to a Confluence site: the address, your login and
    the SSL settings above, so each script just asks for what it wants
    (get_json, get_all, download) instead of building requests itself."""

    def __init__(self, base_url, username, password):
        self.base_url = base_url.rstrip("/")
        pair = f"{username}:{password}"
        self.auth_header = "Basic " + base64.b64encode(pair.encode("utf-8")).decode("ascii")
        self.ssl_context = build_ssl_context()

    def url(self, path, params=None):
        """A full address from a path like /rest/api/content - or a full
        address already (download links sometimes are) left as it is."""
        url = path if path.startswith("http") else f"{self.base_url}{path}"
        return f"{url}?{urllib.parse.urlencode(params)}" if params else url

    def open(self, path, params=None, want_json=False):
        """The raw response, for reading as it arrives - no retrying, so
        the caller sees exactly what happened (the auth test wants the
        status code, a download wants to stream to disk). Only asks for
        JSON when that's what's wanted - a file download shouldn't say
        it'll only accept JSON back."""
        request = urllib.request.Request(self.url(path, params))
        request.add_header("Authorization", self.auth_header)
        if want_json:
            request.add_header("Accept", "application/json")
        return urllib.request.urlopen(request, context=self.ssl_context)

    def get_json(self, path, params=None):
        def do_request():
            with self.open(path, params, want_json=True) as response:
                return json.loads(response.read().decode("utf-8"))

        return request_with_retry(do_request)

    def get_all(self, path, params, limit=50, delay=0, on_batch=None):
        """Every result from a listing (pages in a space, attachments on a
        page), a batch at a time. Stops on an EMPTY batch, not a short one,
        and moves on by however many actually came back rather than by the
        limit. Some Confluence setups quietly hand back fewer than asked
        for (a server-side cap on batch size), and treating that as "last
        batch" - or skipping ahead by the full limit - would silently miss
        the rest. on_batch(start) is called before each request, for
        showing progress."""
        results = []
        start = 0
        while True:
            if on_batch:
                on_batch(start)
            batch = self.get_json(path, {**params, "start": start, "limit": limit}).get("results", [])
            if not batch:
                return results
            results.extend(batch)
            start += len(batch)
            if delay:
                time.sleep(delay)

    def download(self, path, dest_path):
        def do_request():
            with self.open(path) as response:
                with open(dest_path, "wb") as f:
                    # copyfileobj streams the download straight to disk in
                    # chunks - response.read() would pull the whole thing
                    # into memory first, which is fine for a screenshot but
                    # not for a big video or design file attached to a page.
                    shutil.copyfileobj(response, f)

        request_with_retry(do_request)

    def check_signed_in(self):
        """Says who Confluence thinks you are, and warns if that's nobody.

        Some setups let you in as an anonymous visitor rather than turning
        the login away - you still get every page anyone can see, but
        anything that needs a login is quietly left out, and nothing else
        notices (the checking scripts are anonymous too, so they can't see
        those pages either). Asks whether to carry on rather than stopping,
        since an anonymous run of an open space can still be what you
        want. Running unattended (no keyboard to answer), or with
        CONFLUENCE_ALLOW_ANONYMOUS set, it just warns and carries on."""
        try:
            me = self.get_json("/rest/api/user/current")
        except Exception:
            # Older Confluence, or not allowed to ask - nothing to go on,
            # and not a reason to stop.
            return
        if me.get("type") != "anonymous":
            print(f"Signed in to Confluence as: {me.get('displayName') or me.get('username') or 'unknown'}")
            return
        print()
        print("WARNING: Confluence doesn't know who you are - you're connected as an")
        print("anonymous visitor, so your login wasn't used. Only pages anyone can see")
        print("without logging in will come through; anything that needs a login is")
        print("left out without any error, and the checking scripts can't spot it.")
        print("Check your username and password (see the README).")
        if os.environ.get("CONFLUENCE_ALLOW_ANONYMOUS") or not sys.stdin.isatty():
            print("Carrying on anyway.\n")
            return
        if not ask_yes_no("Carry on anyway? (y/N): "):
            sys.exit(1)
        print()


def connect(saved_base_url=None):
    """Asks for (or picks up) the site address and login, and hands back a
    ready-to-use connection - the same questions, in the same order, in
    every script that talks to Confluence."""
    base_url = ask_base_url(saved_base_url)
    username, password = ask_login()
    return Confluence(base_url, username, password)

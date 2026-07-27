# Atlassian Confluence Scraping

Scripts to test and extract access to a self-hosted (Server/Data Center) Confluence instance via its REST API, as a first step toward migrating documentation out to Markdown.

## Credentials: prompted at runtime, never hardcoded

None of these scripts store a username or password in the file. Running any of them prompts you interactively:

```
Confluence username: dan.smith
Confluence password: ****
```

- Python scripts use `input()` for the username and `getpass.getpass()` for the password, hidden input, standard library only.
- PowerShell scripts use `Read-Host` for the username and `Read-Host -AsSecureString` for the password, masked input.

Nothing is written to disk, logged, or displayed. This means the scripts are safe to commit and share as-is, there's nothing sensitive in them to begin with.

If you ever add automation on top of these (e.g. a scheduled task) where interactive prompts aren't practical, use environment variables instead of hardcoding, never commit the filled-in values:
- Python: `import os` then `USERNAME = os.environ["CONFLUENCE_USER"]`
- PowerShell: `$Username = $env:CONFLUENCE_USER`

If credentials were ever hardcoded and committed in an earlier version of a file, treat that password as compromised and change it, scrubbing it from git history alone isn't sufficient once it's been pushed.

## Files

| File | Description |
|---|---|
| `confluence_auth_test.py` | Auth test using Python's standard library only (`urllib`, `base64`, `json`, `ssl`, `getpass`). No `pip install` required. Includes configurable SSL handling for internal/self-signed certificate authorities. Prompts for credentials at runtime. |
| `confluence_auth_test.ps1` | Native PowerShell equivalent of the auth test. No separate install needed, and reads trusted certificates directly from the Windows certificate store, no manual `.pem` path required. Prompts for credentials at runtime. |
| `confluence_extractor.py` | Full space extractor (Python). Paginates through every page in a space, saves each page's HTML content and downloads its image attachments into a matching per-page folder, then writes a `manifest.json` for the Markdown conversion step. Standard library only. Prompts for credentials at runtime. |
| `confluence_extractor.ps1` | Full space extractor (PowerShell), same behaviour and output structure as the Python version above. Use this one if your organisation's internal CA certificate causes verification failures in Python but works fine in PowerShell. Prompts for credentials at runtime. |
| `confluence_html_to_markdown.ps1` | Converts every page's `content.html` into `content.md`, writing the result into a separate `confluence_markdown_export` folder that mirrors the original structure, with each page's images copied alongside. No credentials needed, purely local file processing. Includes an optional Azure DevOps Wiki / SharePoint path length and naming compliance check, see "Converting HTML to Markdown" below. |
| `runningPythonScriptsInVSCode.md` | Setup guide for running Python scripts in VS Code, including common first-time issues (PATH not recognised, scripts not running from the integrated terminal, selecting the correct interpreter). |

> **Note:** `confluence_no_ssl_auth_test.py` and `confluence_auth_test_no_imports.py` were earlier working variants created while iterating on SSL/cert handling. Their content has since been folded into `confluence_auth_test.py` above. They're kept for reference but aren't the ones to use going forward, if still present in the repo, they're due for cleanup.

## What these scripts do

Each auth test script:
1. Builds a Basic Auth header from a username and password (the same credentials used to log into Confluence via browser).
2. Sends a single request to `/rest/api/content` for a given space, requesting one page.
3. Prints the page title on success, or a specific message for common failure cases (401 Unauthorized, 403 Forbidden, SSL certificate errors, connection failures).

This confirms API access works before building a full extractor that loops through an entire space (500+ pages), pulling page content and attachments for conversion to Markdown.

## Converting HTML to Markdown

Once `confluence_extractor.py` or `confluence_extractor.ps1` has finished and you have a `confluence_export` folder full of `content.html` files, run the converter:

```
.\confluence_html_to_markdown.ps1
```

**What it does:**
1. Reads `manifest.json` from `confluence_export` to find every page.
2. Converts each page's `content.html` into proper Markdown, headings, bold/italic, links, lists, tables, code blocks, and info/note/warning panels are all handled.
3. Writes the result into a new `confluence_markdown_export` folder, mirroring the same per-page folder structure as the original export, with each page's images copied alongside its `content.md`. The original `confluence_export` is left untouched, so you can re-run the conversion again later without needing to re-extract from Confluence.
4. Any Confluence macro it doesn't recognise (page trees, Jira embeds, etc.) isn't silently dropped, it's kept as visible text with an HTML comment (`<!-- unrecognised macro: ... -->`) flagging it for a manual check.

**Destination compliance check (Azure DevOps Wiki / SharePoint):**

After conversion, it asks:

```
Where is this markdown export going?
  1. Azure DevOps Wiki
  2. SharePoint
  3. Neither / not sure, skip this check
```

Choosing 1 or 2 checks every page's file path against that destination's real limits (Azure: 235 characters total, hyphenated file names; SharePoint: 400 characters, spaces allowed, different disallowed character set), and offers to automatically shorten any page names that would be too long to upload successfully. You'll also be asked for the destination's actual URL, this is optional but gives a precise result rather than an estimate; leaving it blank still runs the check, just with a clear warning that it may under-count slightly. Choosing 3 skips the check entirely, useful if you're not ready to decide yet.

This check is deliberately interactive rather than requiring any setup or technical knowledge upfront, so anyone can run it safely, not just whoever wrote the script.

## Requirements

- **Python scripts**: Python 3.x. No external packages needed, standard library only.
- **PowerShell script**: Windows PowerShell 5.1 or later (comes preinstalled on Windows). If script execution is blocked, run as yourself (no admin rights required):
  ```
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```

## Setup

1. Clone or download this repo.
2. Open the relevant script and fill in the two non-sensitive values near the top:
   - `BASE_URL`, your Confluence server's base URL (no trailing slash)
   - `SPACE_KEY`, found in a page's URL, e.g. `/display/ABC/Page+Title` → `ABC`
3. Run it, you'll be prompted for your username and password interactively, nothing to fill in for those:
   - Python: `python confluence_auth_test.py`
   - PowerShell: `.\confluence_auth_test.ps1`

New to running Python scripts, or hitting a PATH/terminal issue? See `runningPythonScriptsInVSCode.md`.

## Troubleshooting

| Issue | Cause / fix |
|---|---|
| `SSL certificate verify failed` | Confluence server uses an internal CA cert Python doesn't trust by default. Export the cert (browser padlock icon, or `certmgr.msc` on Windows, if not blocked by policy) and point the script's `INTERNAL_CA_PATH` at the exported `.pem` file. See in-script comments for exact steps. |
| `Basic constraints of CA cert marked not critical` | The organisation's CA certificate itself is missing a flag (`critical`) that Python's SSL library enforces strictly, even though browsers and PowerShell are lenient about it. Not something you can fix client-side. Short-term workaround: set `VERIFY_SSL = False` in the script (test/internal-network use only, disables certificate verification entirely). Longer-term: worth flagging to IT that the internal CA cert isn't fully RFC-compliant. Alternatively, use the `.ps1` version of the script, PowerShell reads the Windows certificate store directly and isn't affected by this. |
| `401 Unauthorized` | Wrong credentials, or the organisation's API requires SSO rather than Basic Auth. |
| `403 Forbidden` | Credentials are valid, but the account lacks read access to the specified space. |
| `python is not recognised` | Python isn't on PATH, or the terminal session predates a Python install. See `runningPythonScriptsInVSCode.md`. |
| PowerShell: `running scripts is disabled on this system` | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` as yourself. |

## Roadmap

- [x] Authentication test (single page fetch)
- [x] Full space extractor: paginate through all pages, save HTML body content, download attachments
- [x] HTML → Markdown conversion, with optional Azure DevOps Wiki / SharePoint compliance check
- [ ] Push converted output to destination (Azure DevOps Wiki or SharePoint, pending organisational decision)

## Notes

These scripts use standard REST API GET requests, the same read access level as browsing Confluence normally in a browser. No admin or elevated permissions are required beyond the ability to view the relevant space.

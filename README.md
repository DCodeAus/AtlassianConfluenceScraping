# Atlassian Confluence Scraping

Scripts to test and extract access to a self-hosted (Server/Data Center) Confluence instance via its REST API, as a first step toward migrating documentation out to Markdown.

## ⚠️ Before you use these: don't commit real credentials

Every script below has placeholder fields near the top, e.g.:

```python
USERNAME = "your.username"
PASSWORD = "your-password"
```

**Never fill these in and then commit or push the file with real values in it.** A script with plain-text credentials in a public (or even private) repo is a genuine security risk, anyone with read access to the repo, or anyone who finds it later in commit history, can read them directly, and history keeps old commits around even if you edit the file afterwards.

Recommended approach:
- Fill in credentials only in a local, untracked copy, never the version that gets committed.
- Better: load credentials from environment variables instead of hardcoding them:
  - Python: `import os` then `USERNAME = os.environ["CONFLUENCE_USER"]`
  - PowerShell: `$Username = $env:CONFLUENCE_USER`
- Add a `.gitignore` entry for any local copy with real values filled in, if you keep one on disk.
- If credentials were ever committed by mistake, treat that password as compromised and change it, scrubbing it from git history alone isn't sufficient once it's been pushed.

## Files

| File | Description |
|---|---|
| `confluence_auth_test.py` | Auth test using Python's standard library only (`urllib`, `base64`, `json`, `ssl`). No `pip install` required. Includes configurable SSL handling for internal/self-signed certificate authorities. |
| `confluence_no_ssl_auth_test.py` | Variant of the above for environments where SSL certificate verification needs to be bypassed for testing (e.g. internal CA not yet trusted locally). Intended for short-term testing only, not for long-term or credential-handling use. |
| `confluence_auth_test_no_imports.py` | Minimal-dependency variant for testing basic API access. |
| `confluence_auth_test.ps1` | Native PowerShell equivalent of the auth test. No separate install needed, and reads trusted certificates directly from the Windows certificate store rather than needing a manually specified `.pem` path. |
| `runningPythonScriptsInVSCode.md` | Setup guide for running Python scripts in VS Code, including common first-time issues (PATH not recognised, scripts not running from the integrated terminal, selecting the correct interpreter). |

## What these scripts do

Each auth test script:
1. Builds a Basic Auth header from a username and password (the same credentials used to log into Confluence via browser).
2. Sends a single request to `/rest/api/content` for a given space, requesting one page.
3. Prints the page title on success, or a specific message for common failure cases (401 Unauthorized, 403 Forbidden, SSL certificate errors, connection failures).

This confirms API access works before building a full extractor that loops through an entire space (500+ pages), pulling page content and attachments for conversion to Markdown.

## Requirements

- **Python scripts**: Python 3.x. No external packages needed, standard library only.
- **PowerShell script**: Windows PowerShell 5.1 or later (comes preinstalled on Windows). If script execution is blocked, run as yourself (no admin rights required):
  ```
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```

## Setup

1. Clone or download this repo.
2. Open the relevant script and fill in:
   - `BASE_URL`, your Confluence server's base URL (no trailing slash)
   - `USERNAME` / `PASSWORD`, your normal Confluence login credentials
   - `SPACE_KEY`, found in a page's URL, e.g. `/display/ABC/Page+Title` → `ABC`
3. Run it:
   - Python: `python confluence_auth_test.py`
   - PowerShell: `.\confluence_auth_test.ps1`

New to running Python scripts, or hitting a PATH/terminal issue? See `runningPythonScriptsInVSCode.md`.

## Troubleshooting

| Issue | Cause / fix |
|---|---|
| `SSL certificate verify failed` | Confluence server uses an internal CA cert Python doesn't trust by default. Export the cert (browser padlock icon, or `certmgr.msc` on Windows) and point the script's `INTERNAL_CA_PATH` at the exported `.pem` file. See in-script comments for exact steps. `confluence_no_ssl_auth_test.py` bypasses this for quick local testing only. |
| `401 Unauthorized` | Wrong credentials, or the organisation's API requires SSO rather than Basic Auth. |
| `403 Forbidden` | Credentials are valid, but the account lacks read access to the specified space. |
| `python is not recognised` | Python isn't on PATH, or the terminal session predates a Python install. See `runningPythonScriptsInVSCode.md`. |
| PowerShell: `running scripts is disabled on this system` | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` as yourself. |

## Roadmap

- [x] Authentication test (single page fetch)
- [ ] Full space extractor: paginate through all pages, save HTML body content, download attachments
- [ ] HTML → Markdown conversion
- [ ] Push converted output to destination (Azure DevOps Wiki or SharePoint, pending organisational decision)

## Notes

These scripts use standard REST API GET requests, the same read access level as browsing Confluence normally in a browser. No admin or elevated permissions are required beyond the ability to view the relevant space.

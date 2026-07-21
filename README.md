# Confluence Extraction Scripts: README

## What's in this folder

| File | Purpose |
|---|---|
| `confluence_auth_test.py` | Tests Confluence REST API access using Python (standard library only, no installs needed) |
| `confluence_auth_test.ps1` | Same test, written in native PowerShell instead |
| `first_time_python_in_vscode.md` | General setup guide if Python/VS Code is new to you |

Both scripts do the same thing: confirm you can authenticate to Confluence's REST API and pull back one page's title. This is Step 1, proving access works, before building the full 500+ page extractor.

---

## ⚠️ Before you do anything: don't leave your password in these files

Both scripts currently have placeholder fields near the top:

```python
USERNAME = "your.username"
PASSWORD = "your-password"
```

**Do not fill these in and then save the file as-is if it's ever going anywhere near version control, a shared drive, email, Teams, or anywhere another person could open it.** A `.py` or `.ps1` file with real credentials sitting in plain text is a genuine security risk, not just a tidiness issue, anyone who opens the file can read them directly.

Safer options once you're past the initial test:

- **Simplest**: fill the credentials in only while testing locally, then clear them back to placeholders before saving or sharing the file again.
- **Better**: read credentials from environment variables instead of hardcoding them, so the file itself never contains anything sensitive:
  - Python: `import os` then `USERNAME = os.environ["CONFLUENCE_USER"]`
  - PowerShell: `$Username = $env:CONFLUENCE_USER`
  
  You'd set these once in your terminal session or system environment variables, outside the script entirely.
- **If this ever goes into a shared repo** (e.g. your team project's Git repo): add these filenames to `.gitignore`, or better, never let a filled-in copy touch Git at all, only the placeholder template version.

If you've already saved a copy somewhere with real credentials in it, worth deleting that copy and treating the password as something to change, same as you would for any other exposed credential.

---

## Which script should I use?

- **Python not working in your terminal, but PowerShell is?** Use `confluence_auth_test.ps1`, it needs no separate install and reads Windows' certificate store automatically.
- **Building the full 500+ page extractor later?** Python's the better long-term choice, easier JSON handling for looping through hundreds of pages, downloading attachments, and converting to Markdown afterward.
- **Not sure?** Run whichever one works first, they test the exact same thing.

---

## Quick start

**Python:**
```
python confluence_auth_test.py
```

**PowerShell:**
```
.\confluence_auth_test.ps1
```

Both need four values filled in near the top of the file: `BASE_URL`, `USERNAME`, `PASSWORD`, `SPACE_KEY` (see `first_time_python_in_vscode.md` or ask if you're not sure where to find any of these).

---

## If you hit an error

| Error | Likely cause |
|---|---|
| SSL certificate verify failed | Internal CA cert isn't trusted yet, see the instructions inside `confluence_auth_test.py` above `INTERNAL_CA_PATH` |
| 401 Unauthorized | Wrong credentials, or your org's API requires SSO rather than basic auth |
| 403 Forbidden | Credentials are correct, but you don't have read access to that space |
| "python is not recognised" | PATH issue, see `first_time_python_in_vscode.md` |
| "running scripts is disabled" (PowerShell) | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` as yourself, no admin needed |

---

## Once the test succeeds

Come back and we'll build the full extractor: pagination through all pages in the space, saving each page's HTML content and downloading its images, ready for the Markdown conversion step.

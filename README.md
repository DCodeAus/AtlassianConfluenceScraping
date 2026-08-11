# Atlassian Confluence Scraping

Pulls documentation out of a self-hosted Confluence instance and turns it into Markdown, ready to land in Azure DevOps Wiki or SharePoint. Built this because I needed to shift 500+ pages out of Confluence with no admin access, just an ordinary read login.

The pipeline goes: test you can actually connect → pull every page down → convert it all to Markdown → check it'll actually upload without falling over on file name limits.

## Credentials, don't worry about them

None of these scripts have a username or password sitting in the file. Run any of them and they'll just ask:

```
Confluence username: dan.smith
Confluence password: ****
```

Python scripts hide the password using `getpass`, PowerShell scripts do the same with `Read-Host -AsSecureString`. Either way, nothing gets written to disk, logged anywhere, or shown on screen. That means you can hand this whole repo to someone else, or commit it, without worrying about leaking anything, there's nothing sensitive baked in to begin with.

If you ever want to automate this properly (a scheduled job, say) where being asked for a password every time isn't practical, set `CONFLUENCE_USERNAME` and `CONFLUENCE_PASSWORD` as environment variables before running the script and the prompts are skipped. Just don't ever go hardcoding it in the file.

## What's in here

| File | What it does |
|---|---|
| `confluence_auth_test.py` | Quick check that you can actually talk to the Confluence API. Python standard library only, nothing to install. Handles internal/self-signed SSL certs too. |
| `confluence_auth_test.ps1` | Same test, PowerShell version. No install needed, and it trusts whatever certs Windows already trusts, so it sidesteps SSL hassles the Python version can hit. |
| `confluence_extractor.py` | The real extraction: walks every page in a space, saves the HTML, grabs every image, writes a manifest so the next step knows what's there. |
| `confluence_extractor.ps1` | Same extractor, PowerShell version. Use this one if Python keeps tripping over the org's certificate. |
| `confluence_html_to_markdown.ps1` | Takes everything the extractor pulled and turns it into proper Markdown, images and all, with a built-in check for Azure/SharePoint file name limits. |
| `confluence_html_to_markdown.py` | Same conversion, Python standard library only. Use this one if you don't have PowerShell (e.g. extracted on Mac/Linux). |
| `runningPythonScriptsInVSCode.md` | If Python in VS Code is giving you grief (PATH errors, nothing happening when you hit run), this walks through it. |

A couple of older files (`confluence_no_ssl_auth_test.py`, `confluence_auth_test_no_imports.py`) were working drafts from while I was sorting out the SSL cert issue. Everything useful from them is now folded into `confluence_auth_test.py`, so they're just clutter at this point, safe to delete.

## How the auth test works

It logs in with your normal Confluence username and password, asks for one page from whichever space you point it at, and tells you straight away whether that worked. If it did, you're clear to run the real extractor. If you get a 401 or 403 or an SSL error, it'll tell you which and point at the fix, see Troubleshooting below.

Worth running this before touching the full extractor, no point discovering an auth problem 200 pages into a 500-page run.

## Pulling everything down

Once the auth test passes, run the matching extractor (`confluence_extractor.py` or `.ps1`, whichever worked for you). It'll ask for your `BASE_URL` and `SPACE_KEY` if you haven't set them, then start working through every page in that space, saving the content and downloading images as it goes. For 500+ pages this'll take a few minutes, that's normal, not a hang, you'll see progress printed as `[142/500] Page Title`.

If a page fails partway through (odd permissions, a network blip), it won't kill the whole run, that page just gets logged to `failures.json` at the end so you can look at it separately.

Everything lands in a `confluence_export` folder, one subfolder per page, each with its own `content.html` and `images/`.

## Turning it into Markdown

Once you've got a `confluence_export` folder full of pages, run:

```
.\confluence_html_to_markdown.ps1
```
or, if you don't have PowerShell:
```
python confluence_html_to_markdown.py
```

Both do the same thing, pick whichever's available. It reads the manifest, converts each page's HTML into real Markdown (headings, bold, links, lists, tables, code blocks, info panels, the lot), and writes it all into a fresh `confluence_markdown_export` folder that mirrors the same structure, images copied in alongside. Your original `confluence_export` is left completely alone, so if something needs fixing you can just re-run the conversion without going back to Confluence.

If it hits a Confluence macro it doesn't recognise (a page tree, a Jira embed, something obscure), it doesn't just drop the content, it keeps whatever text was visible and flags the spot with a comment (`<!-- unrecognised macro: ... -->`) so you can go back and check it manually.

**Before it finishes, it'll ask where this is headed:**

```
Righto, where's this markdown export headed?
  1. Azure DevOps Wiki
  2. SharePoint
  3. Dunno / not fussed, skip this check
```

Pick 1 or 2 and it checks every page's file path against that platform's actual limits, Azure caps out at 235 characters total and turns spaces into hyphens, SharePoint's more generous at 400 characters but blocks a different set of characters. Anything too long gets flagged, and it'll offer to shorten the file names automatically so nothing fails on upload. You can also paste in the real destination URL for a precise check, or skip that and get an estimate instead, either way it tells you plainly which one you're getting.

Didn't decide on a destination yet? Pick 3 and it skips the check entirely.

## What you need installed

- **Python scripts**: just Python 3. Nothing to `pip install`, everything's standard library.
- **PowerShell scripts**: Windows PowerShell 5.1, which is already on any Windows machine. If it refuses to run with a "scripts are disabled" error, run this once as yourself (no admin needed):
  ```
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```

## Getting started

1. Grab this repo.
2. Open whichever script you're starting with and fill in `BASE_URL` and `SPACE_KEY` near the top, that's it, nothing sensitive to type in.
3. Run it:
   - Python: `python confluence_auth_test.py`
   - PowerShell: `.\confluence_auth_test.ps1`
4. You'll be prompted for your username and password when it runs.

First time running Python, or having trouble with VS Code's terminal? `runningPythonScriptsInVSCode.md` covers the common gotchas.

## When something goes wrong

| What you're seeing | What's actually going on |
|---|---|
| `SSL certificate verify failed` | Confluence is using an internal cert Python doesn't automatically trust. Export it (browser padlock icon, or `certmgr.msc` if that's not locked down) and point `INTERNAL_CA_PATH` in the script at the exported file. Full steps are in the script's own comments. |
| `Basic constraints of CA cert marked not critical` | This one's not on you, the org's cert itself is missing a flag Python's SSL library insists on, even though browsers and PowerShell don't care. Quickest fix is switching to the `.ps1` version, which doesn't hit this at all. Or set `VERIFY_SSL = False` for a short-term test, not something to leave on permanently. |
| `401 Unauthorized` | Wrong username/password, or the org's set up SSO in a way that blocks plain API logins. |
| `403 Forbidden` | Login's fine, you just don't have read access to that particular space. |
| `python is not recognised` | Python's not on PATH, or your terminal was open before Python got installed. See the VS Code guide. |
| PowerShell won't run the script at all | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, run as yourself, no admin needed. |

## Where things stand

- [x] Confirming access actually works
- [x] Pulling every page down, content and images
- [x] Converting it all to Markdown, with the Azure/SharePoint length check
- [ ] Actually pushing the converted files into Azure DevOps Wiki or SharePoint, still waiting on which one it's going to be

## One more thing

All of this uses the same read access you already have browsing Confluence normally, nothing here needs admin rights or anything elevated, just the ability to open the pages and access to the space you want to grab pages from in the first place.

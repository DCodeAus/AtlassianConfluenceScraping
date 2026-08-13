# Atlassian Confluence Scraping

Pulls documentation out of a self-hosted Confluence instance and turns it into Markdown, split between Azure DevOps Wiki (technical docs) and SharePoint (everything else, onboarding etc). Built this because I needed to shift 500+ pages out of Confluence with no admin access, just an ordinary read login.

The pipeline goes: test you can actually connect → pull every page down → classify each page as Azure or SharePoint → convert it all to Markdown, routed to the right spot → check it'll actually upload without falling over on file name limits.

## Credentials, don't worry about them

None of these scripts have a username or password sitting in the file. Run any of them and they'll just ask:

```
Confluence username: dan.smith
Confluence password: ****
```

Python scripts hide the password using `getpass`, PowerShell scripts do the same with `Read-Host -AsSecureString`. Either way, nothing gets written to disk, logged anywhere, or shown on screen. That means you can hand this whole repo to someone else, or commit it, without worrying about leaking anything, there's nothing sensitive baked in to begin with.

If you ever want to automate this properly (a scheduled job, say) where being asked for a password every time isn't practical, set `CONFLUENCE_USERNAME` and `CONFLUENCE_PASSWORD` as environment variables before running the script and the prompts are skipped. Just don't ever go back to hardcoding it in the file.

If an older version of a script ever did have real credentials typed into it and pushed to Git, treat that password as burnt and change it. Deleting it from the file afterwards doesn't remove it from history.

## What's in here

| File | What it does |
|---|---|
| `confluence_auth_test.py` | Quick check that you can actually talk to the Confluence API. Python standard library only, nothing to install. Handles internal/self-signed SSL certs too. |
| `confluence_auth_test.ps1` | Same test, PowerShell version. No install needed, and it trusts whatever certs Windows already trusts, so it sidesteps SSL hassles the Python version can hit. |
| `confluence_extractor.py` | The real extraction: walks every page in a space, saves the HTML, grabs every image, writes a manifest so the next step knows what's there. |
| `confluence_extractor.ps1` | Same extractor, PowerShell version. Use this one if Python keeps tripping over the org's certificate. |
| `confluence_html_to_markdown.ps1` | Takes everything the extractor pulled and turns it into proper Markdown, images and all. Routes each page to Azure or SharePoint based on how you've classified it in a CSV, with a built-in check for each platform's file name limits. |
| `confluence_html_to_markdown.py` | Same conversion and routing, Python standard library only. Use this one if you don't have PowerShell (e.g. extracted on Mac/Linux). |
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

Both do the same thing, pick whichever's available.

**First run:** there's no way to reliably guess which pages are technical (Azure) versus everything else (SharePoint) just from the content, so the script won't try. Instead, it generates `confluence_export\page_destinations.csv`, one row per page (`id`, `title`, `destination`), destination left blank, and stops there. Open it in Excel, type `azure` or `sharepoint` into the destination column for each row, save, and run the script again.

For 500+ pages this is genuinely the tedious part, no way around it without something automatically guessing "is this technical," which isn't reliable enough to trust blindly. It's a one-time cost per page though, not something you repeat.

**Once classified**, running the script converts each page's HTML into real Markdown (headings, bold, links, lists, tables, code blocks, info panels, the lot) and routes it into one of three folders:

```
confluence_markdown_export/
├── azure/          <- pages classified "azure"
├── sharepoint/      <- pages classified "sharepoint"
└── unsorted/         <- blank or typo'd rows, needs a look
```

Each page's images are copied alongside its `content.md`. Your original `confluence_export` is left completely alone, so if something needs fixing you can just re-run the conversion without going back to Confluence.

**Adding more pages later?** Re-run the extractor, then re-run this script, it'll add any new pages to the CSV with a blank destination without touching rows you've already filled in, then stop so you can classify just the new ones.

If it hits a Confluence macro it doesn't recognise (a page tree, a Jira embed, something obscure), it doesn't just drop the content, it keeps whatever text was visible and flags the spot with a comment (`<!-- unrecognised macro: ... -->`) so you can go back and check it manually.

**The length/naming check runs automatically** for whichever destinations actually have pages that run, no need to choose anything, since that's already decided per page by the CSV. For each destination present, it checks every page's file path against that platform's actual limits, Azure caps out at 235 characters total and turns spaces into hyphens, SharePoint's more generous at 400 characters but blocks a different set of characters. Anything too long gets flagged, and it'll offer to shorten the file names automatically so nothing fails on upload. You'll be asked for the real destination URL for a precise check, or you can leave it blank for an estimate, either way it tells you plainly which one you're getting.

Pages still sitting in `unsorted` don't go through this check at all, sort them into the CSV and re-run first.

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
- [x] Converting it all to Markdown, split by destination via the classification CSV, with the Azure/SharePoint length check
- [ ] Actually pushing the converted files into Azure DevOps Wiki and SharePoint (still manual for now, drag files in or `git push` for the Wiki side)

## One more thing

All of this uses the same read access you already have browsing Confluence normally, nothing here needs admin rights or anything elevated, just the ability to open the pages in the first place.

## Written by

Dan.

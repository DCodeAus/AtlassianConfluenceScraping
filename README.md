# Atlassian Confluence Scraping

*Get your team's docs out of Confluence and into Azure DevOps Wiki or SharePoint - no admin access, no API app registration, just the login you already use.*

[![Release](https://img.shields.io/github/v/release/DCodeAus/AtlassianConfluenceScraping)](https://github.com/DCodeAus/AtlassianConfluenceScraping/releases)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Python](https://img.shields.io/badge/Python-3%2C%20stdlib--only-3776AB?logo=python&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![tests](https://github.com/DCodeAus/AtlassianConfluenceScraping/actions/workflows/tests.yml/badge.svg)](https://github.com/DCodeAus/AtlassianConfluenceScraping/actions/workflows/tests.yml)

Pulls documentation out of a self-hosted Confluence instance and turns it into Markdown, split between Azure DevOps Wiki (technical docs) and SharePoint (everything else, onboarding etc). Built this because I needed to shift 500+ pages out of Confluence with no admin access, just an ordinary read login.


## Why this exists

- **No admin rights, anywhere.** Confluence, Azure DevOps, and SharePoint all just use the same access you already have browsing them normally.
- **Nothing to install.** Whatever you've already got - the Python side is standard library only, the PowerShell side needs nothing beyond what Windows already ships with.
- **Built for the messy real cases**, not just the happy path: broken encoding from old exports, table cells with multiple paragraphs, renamed/duplicate attachments, task lists, @mentions, page labels, file name length limits on both destinations.
- **Every script explains itself.** Stuck on a prompt? Type `?` and it tells you what it's actually asking for.
- **Nothing sensitive in the files.** Every script asks for your login when it runs and never saves it - see [Credentials](docs/extracting.md#credentials-dont-worry-about-them).

The pipeline goes: test you can actually connect → pull every page down → check nothing's missing → classify each page as Azure or SharePoint → convert it all to Markdown → lay it out for the Azure DevOps Wiki, or turn it into paste-ready pages for SharePoint.

Want the picture before the detail? [How it works](docs/how-it-works.md) has the whole pipeline as one diagram.

## Before you start

1. **Download a release.** Grab the latest numbered version from [Releases](https://github.com/DCodeAus/AtlassianConfluenceScraping/releases) rather than whatever's currently on `main`, so you know exactly what you're running. Unzip the whole thing - the scripts share `confluence_common.py`/`.ps1` and need it sitting next to them.
2. **Unblock the PowerShell scripts.** Windows marks anything downloaded as "from the internet", so run this once in the unzipped folder:
   ```powershell
   Get-ChildItem *.ps1 | Unblock-File
   ```
3. **Check it'll run.** PowerShell scripts need Windows PowerShell 5.1 (already on every Windows machine) or PowerShell 7. If it refuses with a "scripts are disabled" error, run this once as yourself, no admin needed:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```
   Python scripts just need Python 3 - nothing to `pip install`.

## Quick start (PowerShell)

Run each from inside this folder. Every script has a `.py` twin that does the same thing, if you'd rather use Python (`python confluence_extractor.py` instead of `.\confluence_extractor.ps1`). [Getting started](docs/getting-started.md) walks through the same steps with what each one does.

```powershell
# 1. Run it, it'll ask for your Confluence site address and space key,
#    then check you can actually connect:
.\confluence_auth_test.ps1

# 2. Only if you've got a confluence_export folder from BEFORE today, with
#    garbled characters in it (Â, â€™) - skip this if this is your first run.
#    Must be run from the same folder that CONTAINS confluence_export/, or
#    it silently finds nothing to fix:
.\repair_garbled_text.ps1

# 3. Same site address/space key as step 1, then pull every page down,
#    and check nothing's missing while Confluence is still there:
.\confluence_extractor.ps1
.\confluence_verify_extraction.ps1
.\confluence_verify_live_content.ps1

# 4. Convert to Markdown. First run just creates page_destinations.csv -
#    open it in Excel, mark each row "azure" or "sharepoint", save, then
#    run this again to actually convert:
.\confluence_html_to_markdown.ps1

# 5. Get each page where it's going:
#    - "azure" pages: lay them out the way the wiki expects, then copy the
#      result into your wiki clone and push (see docs/azure-devops-wiki.md):
.\confluence_to_azure_wiki.ps1
#    - "sharepoint" pages, turn them into paste-ready HTML:
.\confluence_sharepoint_paste.ps1
#    - a page that's really just a table (an on-call roster, say):
.\confluence_table_to_csv.ps1 "Page Title"
```

**Not sure what a prompt is asking for?** Every question these scripts ask you - username, page ID, which page, whether to shorten a file name, anything - accepts a bare `?` as the answer. Type it and press Enter, and it'll explain what it wants and ask again.

**Something not behaving like this says?** Check [When something goes wrong](docs/troubleshooting.md) first - most of what's in there looks alarming but has a one-line fix.

## What's in here

Every script comes as a `.ps1` and a `.py` that do the same thing. Keep them all in one folder.

**The pipeline, in order**

| Script | What it does | More |
|---|---|---|
| `confluence_auth_test` | Checks you can log in and read the space, before anything long-running. | [Connecting](docs/extracting.md#how-the-auth-test-works) |
| `confluence_extractor` | Pulls every page in a space (or one page) - content, images, attachments - plus a manifest the later steps use. | [Pulling pages down](docs/extracting.md#pulling-everything-down) |
| `confluence_verify_extraction` | Quick check of the export on disk: missing or failed pages and files, images that weren't saved. | [Checking an export](docs/checking-an-export.md) |
| `confluence_verify_live_content` | Thorough check: compares every page and attachment with live Confluence. | [Checking an export](docs/checking-an-export.md) |
| `confluence_html_to_markdown` | Converts pages to Markdown and sorts them into Azure / SharePoint / discard by your `page_destinations.csv`. | [Converting](docs/converting-to-markdown.md) |
| `confluence_to_azure_wiki` | Lays the Azure pages out the way an Azure DevOps Wiki repo expects - page tree, `.order`, `.attachments`, real links. | [Azure DevOps Wiki](docs/azure-devops-wiki.md) |
| `confluence_sharepoint_paste` | Turns the SharePoint pages into HTML you copy-paste into a new SharePoint page. | [SharePoint](docs/sharepoint.md) |
| `confluence_table_to_csv` | Pulls the tables off one page as CSV, to create a SharePoint List from. | [Tables](docs/sharepoint.md#pages-that-are-really-just-a-table) |

**Sometimes useful**

| Script | What it does | More |
|---|---|---|
| `confluence_export_to_git` | Turns an export folder into its own git repo, ready to push somewhere your team can get at it. | [Export to git](docs/extracting.md#putting-an-export-into-its-own-git-repo) |
| `repair_garbled_text` | One-off fix for exports pulled before an old encoding bug was fixed (`Â`, `â€™` in the text). | [Troubleshooting](docs/troubleshooting.md) |

**Not run directly**

| File | What it is |
|---|---|
| `confluence_common` | Code every script shares: questions with `?` help, finding an export, logging in, talking to Confluence. A script copied out on its own won't run without it. |
| `check_script_encoding.ps1` | For anyone editing the `.ps1` files - checks for the encoding problem that once broke a script. |
| `tests/` | Automatic tests against a fake Confluence, in both languages. See [Changing the scripts](docs/changing-the-scripts.md). |
| `docs/` | The detail behind everything above - see below. |

## Documentation

- [Getting started](docs/getting-started.md) - every step, start to finish, with what each one does
- [How it works](docs/how-it-works.md) - the whole pipeline as one diagram
- [Connecting and pulling pages down](docs/extracting.md) - credentials, the auth test, the extractor, exporting to git
- [Checking an export is complete](docs/checking-an-export.md)
- [Converting to Markdown](docs/converting-to-markdown.md)
- [Getting pages into Azure DevOps Wiki](docs/azure-devops-wiki.md) - including first-time git steps
- [Getting pages into SharePoint](docs/sharepoint.md) - and pages that are really a table
- [Setting up Power Automate](docs/power-automate.md) - trying to automate the SharePoint side
- [When something goes wrong](docs/troubleshooting.md)
- [Running Python in VS Code](docs/python-in-vs-code.md)
- [Changing the scripts](docs/changing-the-scripts.md) - and running the tests
- [The encoding bug postmortem](docs/encoding-bug-postmortem.md)

## Where things stand

- [x] Confirming access actually works
- [x] Pulling every page down, content and images
- [x] Converting it all to Markdown, split by destination via the classification CSV, with the Azure/SharePoint length check
- [x] Azure DevOps Wiki: `confluence_to_azure_wiki` lays the `azure/` pages out the way the wiki repo expects (page tree, `.order`, `.attachments`, real links between pages), then it's a `git push`
- [ ] SharePoint: no admin access to automate via Graph API yet, so `confluence_sharepoint_paste` generates paste-ready HTML but page creation itself is still a manual copy-paste per page - Power Automate is the next thing to try, see [Setting up Power Automate](docs/power-automate.md), but that's untested against a real tenant so far

## Questions and problems

Something broken, or doesn't make sense? [Raise an issue](https://github.com/DCodeAus/AtlassianConfluenceScraping/issues) - say which script, which version (Python or PowerShell), and paste what it printed (with your site address and anything private taken out).

## Licence

MIT - free to use, change and share, including at work. See [LICENSE](LICENSE).

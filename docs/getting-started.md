# Getting started

New to this? Here's the order to actually run things in, start to finish. Everything below shows the PowerShell (`.ps1`) command - if you're on Mac/Linux or don't have PowerShell, swap each one for the matching `.py` file (e.g. `python confluence_extractor.py` instead of `.\confluence_extractor.ps1`), same order, same steps.

1. **Grab this repo**, somewhere you can find it again - the whole thing, not just the script you want, since they all share `confluence_common.py`/`.ps1` and need it sitting next to them. Easiest way: on this repo's GitHub page, click the green **Code** button → **Download ZIP**, then unzip it. On Windows, run this once in the unzipped folder too, or PowerShell may refuse to load the shared file (Windows marks anything downloaded as "from the internet"):
   ```
   Get-ChildItem *.ps1 | Unblock-File
   ```

   If you've got [Git](https://git-scm.com/downloads) installed and want to be able to pull future updates instead of re-downloading, `git clone` the repo's URL from that same **Code** button into a folder instead (see [Getting pages into Azure DevOps Wiki](azure-devops-wiki.md) for a full walkthrough of installing/using git if you've never done it).

2. **Test you can actually connect.** Run:
   ```
   .\confluence_auth_test.ps1
   ```
   It'll ask for your Confluence site address, space key, username and password right there in the terminal - nothing gets saved anywhere, and nothing needs editing into the file first. If it prints a page title back, you're good to move on. If it prints an error instead, check [When something goes wrong](troubleshooting.md) before going any further - no point discovering a login problem 200 pages into a real run.

3. **Already extracted something with this project before, on an older copy of these scripts?** Check whether your `confluence_export` folder has weird garbled characters in it, e.g. `Â` where a space or accent should be, or `â€™` instead of an apostrophe. If it does, run this **from the same folder that contains your `confluence_export`/`confluence_markdown_export` folders** (it doesn't ask, it just looks for those two folder names right where you run it):
   ```
   .\repair_garbled_text.ps1
   ```
   The first thing it prints is exactly which folders it found (or didn't) - check that before anything else, since running it from the wrong spot just silently finds nothing to fix rather than erroring. If your export folders are somewhere else, pass the path directly instead: `.\repair_garbled_text.ps1 -Roots C:\path\to\confluence_export`. That's an old bug, already fixed for anything extracted from here on - if this is your first time running any of these scripts, skip this step entirely, you won't need it.

4. **Pull everything down.** Same site address/space key as step 2 when it asks, then run:
   ```
   .\confluence_extractor.ps1
   ```
   This is the one that actually talks to Confluence and downloads everything - content, images, attachments. Expect it to take a few minutes for a big space, that's normal. See [Pulling everything down](extracting.md#pulling-everything-down) for what the output looks like while it runs.

   Then check it got everything - both checks, while Confluence is still there: `.\confluence_verify_extraction.ps1`, then `.\confluence_verify_live_content.ps1`. Fix anything under "Must fix" and run them again until it's clear. See [Checking an export is complete](checking-an-export.md).

5. **Convert it to Markdown, and classify each page.** Run:
   ```
   .\confluence_html_to_markdown.ps1
   ```
   The first time, this just generates `page_destinations.csv` and stops - open that in Excel, mark each row `azure` or `sharepoint`, save, then run the script again to actually convert everything. See [Converting to Markdown](converting-to-markdown.md) for the full detail.

6. **Get each page into its actual destination:**
   - Classified `azure` → run `.\confluence_to_azure_wiki.ps1`, then copy what it builds into your Azure DevOps Wiki clone and push. See [Getting pages into Azure DevOps Wiki](azure-devops-wiki.md), including if you've never used git before.
   - Classified `sharepoint` → run `.\confluence_sharepoint_paste.ps1`, then copy-paste each resulting page into a new SharePoint page by hand. See [Getting pages into SharePoint](sharepoint.md).
   - A page that's really just a table (an on-call roster, say)? Run `.\confluence_table_to_csv.ps1 "Page Title"` instead, and create it as a SharePoint List from the CSV. See [Pages that are really just a table](sharepoint.md#pages-that-are-really-just-a-table).

Steps 4-6 are the ones you repeat if new pages get added to the space later. Steps 2 and 3 are one-off checks, not something you run every time.

**If anything above doesn't go the way this describes** - an error, a blank/weird result, a script that seems to hang - it's almost always one of the entries in the [When something goes wrong](troubleshooting.md) table. Check there first before assuming something's broken; most of what's listed there looks alarming but has a one-line fix.

First time running Python, or having trouble with VS Code's terminal? [Running Python in VS Code](python-in-vs-code.md) covers the common gotchas.

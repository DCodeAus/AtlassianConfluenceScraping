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
| `confluence_sharepoint_paste.ps1` | Turns each page classified "sharepoint" into a standalone .html file ready to copy-paste into a new SharePoint page. See "Getting pages into SharePoint" below. |
| `confluence_sharepoint_paste.py` | Same thing, Python standard library only. |
| `confluence_table_to_csv.ps1` | Pulls one table off one page (an on-call register, say) and writes it as a CSV - better off as a real SharePoint List than a wiki page, and SharePoint can create a List straight from a CSV itself, no upload script needed. |
| `confluence_table_to_csv.py` | Same thing, Python standard library only. |
| `repair_garbled_text.ps1` | Fixes up `content.html`/`content.md` files already extracted with the old `.ps1` encoding bug (garbled accents/quotes/dashes, see Troubleshooting below). Only needed once, for content pulled before that fix landed. |
| `repair_garbled_text.py` | Same repair, Python standard library only. |
| `runningPythonScriptsInVSCode.md` | If Python in VS Code is giving you grief (PATH errors, nothing happening when you hit run), this walks through it. |

A couple of older files (`confluence_no_ssl_auth_test.py`, `confluence_auth_test_no_imports.py`) were working drafts from while I was sorting out the SSL cert issue. Everything useful from them is now folded into `confluence_auth_test.py`, so they're just clutter at this point, safe to delete.

## How the auth test works

It logs in with your normal Confluence username and password, asks for one page from whichever space you point it at, and tells you straight away whether that worked. If it did, you're clear to run the real extractor. If you get a 401 or 403 or an SSL error, it'll tell you which and point at the fix, see Troubleshooting below.

Worth running this before touching the full extractor, no point discovering an auth problem 200 pages into a 500-page run.

## Pulling everything down

Once the auth test passes, run the matching extractor (`confluence_extractor.py` or `.ps1`, whichever worked for you). It'll ask for your `BASE_URL` and `SPACE_KEY` if you haven't set them, then start working through every page in that space, saving the content and downloading images as it goes. For 500+ pages this'll take a few minutes, that's normal, not a hang, you'll see progress printed as `[142/500] Page Title`.

A brief network blip won't even show up as a failure, connection errors and 5xx responses get retried a couple of times with a short backoff before giving up. If a page still fails after that (odd permissions, a persistent error), it won't kill the whole run, that page just gets logged to `failures.json` at the end so you can look at it separately.

Everything lands in a `confluence_export` folder, one subfolder per page, each with its own `content.html` and `images/`.

Only want one page instead of a whole space, say someone's personal space? Alongside the username/password prompts, it'll also ask for a page ID - leave it blank to pull the whole space as normal, or paste one in (grabbed straight from the page's URL, `.../pages/123456789/Page+Title`) to pull just that page instead. `SPACE_KEY` is ignored when you give it a page ID. Needs no more access than opening the page normally does. For unattended runs, set `CONFLUENCE_PAGE_ID` as an environment variable to skip the prompt, same as the credentials.

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

If it hits a Confluence macro it doesn't recognise (a page tree, a Jira embed, something obscure), it doesn't just drop the content, it keeps whatever text was visible and flags the spot with a comment (`<!-- unrecognised macro: ... -->`) so you can go back and check it manually. Links to other Confluence pages get the same treatment, since there's no way to know the page's new URL until it's actually been migrated: the link text is kept, tagged with `<!-- internal Confluence link, unresolved: "..." -->`, so you can find and fix these up once everything's landed in its new home.

A few other Confluence-specific things get carried across properly rather than falling into that generic "unrecognised" bucket:

- **Links to attachments** (a PDF, a spreadsheet, anything besides an embedded image) resolve to the actual downloaded file, same as images.
- **@mentions** show the person's real name, not just a raw internal ID - this needs the extractor to resolve each mentioned user via the Confluence API, which it does once per space (not per page), saving the result to `confluence_export/user_display_names.json`.
- **Emoji/emoticons** come through as the real emoji character where Confluence provides one, or a `:name:`-style fallback otherwise.
- **Task lists** (checkboxes) keep their checked/unchecked state - real Markdown task list syntax (`- [x]`) in the `.md` export, a ☑/☐ prefix in the SharePoint paste export since real checkboxes don't survive a copy-paste.
- **Page labels** show up as a `**Tags:** label1, label2` line under the title, in both exports.

All five need a re-extraction to pick up on content pulled before this landed - the underlying data (page labels, mentioned users, resolvable attachment links) isn't in an older `manifest.json`, so these features just don't trigger rather than showing anything wrong.

**The length/naming check runs automatically** for whichever destinations actually have pages that run, no need to choose anything, since that's already decided per page by the CSV. For each destination present, it checks every page's file path against that platform's actual limits, Azure caps out at 235 characters total and turns spaces into hyphens, SharePoint's more generous at 400 characters but blocks a different set of characters. Anything too long gets flagged, and it'll offer to shorten the file names automatically so nothing fails on upload. You'll be asked for the real destination URL for a precise check, or you can leave it blank for an estimate, either way it tells you plainly which one you're getting.

Pages still sitting in `unsorted` don't go through this check at all, sort them into the CSV and re-run first.

## Getting pages into SharePoint

Azure DevOps Wiki is a git repo under the hood, so getting the `azure/` output live is just a `git push`. SharePoint has no equivalent, and properly automating it (calling the Microsoft Graph API to create real SharePoint pages) needs an Entra ID app registration, which needs either admin rights or an admin's one-time consent to grant it access to your site. If you don't have that, run:

```
.\confluence_sharepoint_paste.ps1
```
or
```
python confluence_sharepoint_paste.py
```

against your `sharepoint/`-classified pages once they're converted. This doesn't upload anything, it turns each page into a standalone `confluence_sharepoint_paste/.../content.html` you open in a browser, select all (Ctrl+A), copy (Ctrl+C), then paste straight into a new SharePoint page's text web part (`+ New Page` > `Blank`). Headings, bold, links, lists, and tables all come through as real formatting, not as something you have to retype.

Two things it can't do automatically, so it flags them instead:

- **Images and attachments** - a pasted `<img src="local/path">` or `<a href="local/path">` has nothing to load once it's sitting in a browser's clipboard (there's no server behind a relative local file path), so each becomes a visible note - `[INSERT IMAGE HERE: ...]` or `[ATTACH FILE HERE: ...]` - telling you which file to add yourself, using SharePoint's own image/attachment tools, from the `images/` folder sitting next to that page's `content.html`.
- **Internal links and unrecognised macros** - same visible-marker treatment as the Markdown export (`[UNRESOLVED LINK: "..."]`, `[UNRECOGNISED CONFLUENCE MACRO: ...]`), just as plain text instead of an HTML comment, since comments silently vanish when you copy-paste into a rich text editor and the whole point is that you notice these.

The first line of each page is a reminder of what to set as the SharePoint page's title, meant to be deleted once you've used it, since the real title field lives in SharePoint's own page-creation dialog, not in the pasted body.

**Related pages block:** SharePoint has no direct equivalent of Confluence's always-visible page tree sidebar, so each page ends with its own "Related pages" section instead, listing its parent and direct sub-pages by title (same `[UNRESOLVED LINK: "..."]` treatment, since none of these have real SharePoint URLs until they're actually migrated). This needs the extractor to have pulled each page's Confluence ancestry, which only started being recorded once this feature landed - if your `confluence_export` predates it, re-run `confluence_extractor.py`/`.ps1` to pick it up, otherwise this section just won't appear.

If you *do* have (or can get) the Entra ID access this needs, the Graph API's Pages endpoint (`POST /sites/{siteId}/pages`) is the real automation path, at that point it's worth building a proper upload script instead of this copy-paste workflow.

## Pages that are really just a table

Some pages (an on-call register, say - person, dates, notes) aren't wiki content at all, they're a table, and they belong in SharePoint as an actual **List**, not a page: filterable, sortable, a Calendar view if it's date-based, and you can wire up a Power Automate flow against it. Creating that List doesn't need any API access, SharePoint builds one straight from a CSV through its own UI. So:

```
.\confluence_table_to_csv.ps1 "On Call Register"
```
or
```
python confluence_table_to_csv.py "On Call Register"
```
(a page id works too, instead of the title)

pulls every table off that one page and writes each as a CSV into `confluence_table_export/`. In SharePoint: **Create list → From CSV/Excel**, point it at the file, done. Every column comes in as plain text, if you want a real Person column (photo, presence) or a proper Date column, change the column type after import, a CSV can't carry that metadata.

## What you need installed

- **Python scripts**: just Python 3. Nothing to `pip install`, everything's standard library.
- **PowerShell scripts**: Windows PowerShell 5.1, which is already on any Windows machine. If it refuses to run with a "scripts are disabled" error, run this once as yourself (no admin needed):
  ```
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```

## Getting started - which script, in what order

New to this? Here's the order to actually run things in, start to finish. Everything below shows the PowerShell (`.ps1`) command - if you're on Mac/Linux or don't have PowerShell, swap each one for the matching `.py` file (e.g. `python confluence_extractor.py` instead of `.\confluence_extractor.ps1`), same order, same steps.

1. **Grab this repo**, somewhere you can find it again.

2. **Test you can actually connect.** Open `confluence_auth_test.ps1` in a text editor, fill in `$BaseUrl` and `$SpaceKey` near the top (just your Confluence site address and space code, nothing sensitive), save, then run:
   ```
   .\confluence_auth_test.ps1
   ```
   It'll ask for your username and password right there in the terminal - nothing gets saved anywhere. If it prints a page title back, you're good to move on. If it prints an error instead, check the "When something goes wrong" table below before going any further - no point discovering a login problem 200 pages into a real run.

3. **Already extracted something with this project before, on an older copy of these scripts?** Check whether your `confluence_export` folder has weird garbled characters in it, e.g. `Â` where a space or accent should be, or `â€™` instead of an apostrophe. If it does, run the repair script once before doing anything else:
   ```
   .\repair_garbled_text.ps1
   ```
   That's an old bug, already fixed for anything extracted from here on - if this is your first time running any of these scripts, skip this step entirely, you won't need it.

4. **Pull everything down.** Fill in `$BaseUrl`/`$SpaceKey` in `confluence_extractor.ps1` too (same values as step 2), then run:
   ```
   .\confluence_extractor.ps1
   ```
   This is the one that actually talks to Confluence and downloads everything - content, images, attachments. Expect it to take a few minutes for a big space, that's normal. See "Pulling everything down" above for what the output looks like while it runs.

5. **Convert it to Markdown, and classify each page.** Run:
   ```
   .\confluence_html_to_markdown.ps1
   ```
   The first time, this just generates `page_destinations.csv` and stops - open that in Excel, mark each row `azure` or `sharepoint`, save, then run the script again to actually convert everything. See "Turning it into Markdown" above for the full detail.

6. **Get each page into its actual destination:**
   - Classified `azure` → `git push` the `confluence_markdown_export/azure/` folder into your Azure DevOps Wiki repo. Done.
   - Classified `sharepoint` → run `.\confluence_sharepoint_paste.ps1`, then copy-paste each resulting page into a new SharePoint page by hand. See "Getting pages into SharePoint" above.
   - A page that's really just a table (an on-call roster, say)? Run `.\confluence_table_to_csv.ps1 "Page Title"` instead, and create it as a SharePoint List from the CSV. See "Pages that are really just a table" above.

Steps 4-6 are the ones you repeat if new pages get added to the space later. Steps 2 and 3 are one-off checks, not something you run every time.

**If anything above doesn't go the way this describes** - an error, a blank/weird result, a script that seems to hang - it's almost always one of the entries in the "When something goes wrong" table right below this. Check there first before assuming something's broken; most of what's listed there looks alarming but has a one-line fix.

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
| Weird garbled characters in the Markdown, e.g. `Â` where a space or accent should be, or `â€™` instead of an apostrophe | An old bug in `confluence_extractor.ps1`: PowerShell decoded Confluence's UTF-8 response as Windows-1252, mangling anything non-ASCII (accents, curly quotes, dashes). Already fixed in the extractor, so new extractions come out clean. For content you already pulled before the fix, run `repair_garbled_text.ps1` (or `.py`) once against your `confluence_export`/`confluence_markdown_export` folders, it undoes the mis-decode in place and backs up each file it touches as `.bak`. |
| A converted table looks broken, extra `\|` rows or content spilling out of the table | An old bug: a table cell with more than one paragraph, or a line break in it, produced a real newline in the Markdown, which splits a table row across lines. Already fixed, multi-line cell content now becomes `<br>` instead. No re-extraction needed, just re-run the Markdown converter over your existing `confluence_export`. |
| An image shows up broken after uploading, even though `content.md` references it | An old bug: the Markdown linked to the image by its original Confluence filename, which can differ from what's actually on disk (special characters get replaced with `_` when saved, and two attachments with the same name get a `_2` suffix). Already fixed, the extractor now records both names so the converter can point at the right file. Only fixes new extractions though, since the old filename mapping wasn't recorded before, re-run the extractor (not just the converter) on affected pages to pick it up. |
| `confluence_sharepoint_paste.ps1` says "nothing to do" even though you classified a page as `sharepoint`, or a page's one-and-only attachment silently never gets downloaded | An old bug specific to the `.ps1` scripts: PowerShell can silently misread a result set as empty/scalar when it has exactly one item (one page, one attachment, one page landing in a bucket) rather than treating it as a one-item list. Already fixed throughout, extracting or converting just one or two pages to try things out now behaves exactly like a full run. |
| A Python converter script crashes with a `JSONDecodeError` reading `manifest.json`, but only when it was extracted with `confluence_extractor.ps1` | An old cross-language bug: on Windows PowerShell 5.1, `Set-Content -Encoding UTF8` adds an invisible marker (a BOM) to the front of the file, which Python's `json` module refuses to read. Already fixed on both sides - the PowerShell extractor no longer adds that marker, and the Python scripts tolerate it either way - so extracting with one and converting with the other now works regardless of which combination you use. |
| Non-ASCII page titles (accents, curly quotes) show up garbled in Excel when you open `page_destinations.csv` | The same class of bug as the "weird garbled characters" row above, just via a different path: Excel needs that same invisible BOM marker to correctly read a UTF-8 CSV, and the Python script writing this file wasn't including it. Already fixed - regenerate the CSV (delete it and re-run the Markdown converter) to get a clean copy. |

## Where things stand

- [x] Confirming access actually works
- [x] Pulling every page down, content and images
- [x] Converting it all to Markdown, split by destination via the classification CSV, with the Azure/SharePoint length check
- [x] Azure DevOps Wiki: just `git push` the `azure/` output, it's a git repo
- [ ] SharePoint: no admin access to automate via Graph API yet, so `confluence_sharepoint_paste` generates paste-ready HTML but page creation itself is still a manual copy-paste per page

## One more thing

All of this uses the same read access you already have browsing Confluence normally, nothing here needs admin rights or anything elevated, just the ability to open the pages in the first place.

## Written by

Dan.

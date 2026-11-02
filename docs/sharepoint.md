# Getting pages into SharePoint

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

### If you want to automate the SharePoint side further

No Entra ID access, but want more than copy-paste? **Power Automate** is worth trying, since its own SharePoint connector runs under your normal signed-in permissions rather than a separate app registration - it sometimes gets through the exact gate that blocks Graph API automation. Nothing here has been tried against a real tenant yet, so treat it as "the next thing to try," not a finished recipe.

[Setting up Power Automate](power-automate.md) has the full first-time walkthrough: creating a flow, the actual connectivity test, and (if that works) the two-part approach to creating a real page, plus troubleshooting for the likely snags.

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

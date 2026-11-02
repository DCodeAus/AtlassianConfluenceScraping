# Checking an export is complete

With Confluence about to be switched off, the export *is* the backup - so there are two checks, and it's worth running both on every space before it goes. Both ask which export folder to check (the folder name you gave the extractor, or a full path), and both split what they find into **"Must fix before Confluence is switched off"** and **"For your information"**. Work through the first list until it says "none" everywhere; the second is for you to decide about.

**1. The quick check, no Confluence needed** - `confluence_verify_extraction.py` / `.ps1`:

```
python confluence_verify_extraction.py
.\confluence_verify_extraction.ps1
```

| Must fix | |
|---|---|
| Failed during extraction | Pages *and* attachment downloads that failed (`failures.json`) |
| Page folders, `content.html` or `rendered.html` missing or empty | A rendered copy that failed to save is listed under "Failed during extraction" |
| Attachment files missing, empty, or not the real file | Including a web page saved in place of the real file - what you get when a proxy or login page answers instead of Confluence |
| Images/files a page shows that weren't saved | Including ones that really live on a *different* page (or space), which don't come down with this one |

| For your information | |
|---|---|
| Macros whose content lives elsewhere | Jira lists, "include page", page trees and similar show content that isn't stored in the page, so the raw `content.html` only has the macro. The page's `rendered.html` has what it showed - open it and check that came through, since a few macros only fill in once a browser runs them. |
| Links to pages not in this export | The link text survives, the page it pointed at isn't part of this export |
| Page folders the manifest doesn't list | Usually left over from an earlier run - invisible to the converter and other scripts |

Add `--check-live-space` (`-CheckLiveSpace` for PowerShell) to also compare against Confluence's live page list, catching pages that never made it into the export at all. It saves everything to `verification_report.json` in the export folder.

**2. The thorough check, against live Confluence** - `confluence_verify_live_content.py` / `.ps1`. This re-fetches every page and its attachment list from Confluence and compares them with what's on disk:

```
python confluence_verify_live_content.py
.\confluence_verify_live_content.ps1
```

| Must fix | |
|---|---|
| Live pages missing from the export | Every page in the space is listed and compared, so nothing the extractor never got to slips through |
| Saved content doesn't match live | Same version, but the saved copy differs, i.e. the save went wrong (cut off, garbled). The report shows where the two first differ. |
| Edited since extraction | The page changed in Confluence after you extracted it |
| Title, parent page or labels differ | Renamed, moved or relabelled since - these don't always change the version number |
| Live attachments that weren't saved | |
| Saved attachments missing or a different size | A cut-off or wrong download - compared against the size Confluence reports |

| For your information | |
|---|---|
| No longer live | Deleted or moved since - usually fine |
| Attachments since removed from Confluence | Still in your export |
| Attachments with no size reported | Confluence didn't say, so that one's size wasn't checked |

It only reads from Confluence and only writes `live_content_report.json` into the export folder. It's a couple of requests per page, so expect it to take about as long as the extraction did.

**Neither check can see pages restricted from your account** - Confluence doesn't list them to you at all. If you know of restricted pages, ask whoever has access.

Both checks only ask for your login: the site address and space key come from `export_source.json`, which the extractor saves into the export folder (older exports fall back to the `Source:` line of their `README.md`). The PowerShell versions also take `-UseDefaultCredentials`, same as the extractor.

**Fixing what they find:** re-extract just the affected page by giving the extractor its page ID, into the *same* export folder. It updates that page in place and keeps every other page already there, so you can fix pages one at a time, then run the checks again. When it asks for the space key, still enter that space's key (or check the folder name it suggests next is the right export) - leaving it blank suggests plain `confluence_export`, which may be a different export. For pages missing from the export or a lot of problems at once, just re-run the whole space.

**Some "must fix" items can't be fixed by re-extracting**, so don't loop on them. If the quick check says a page shows an image that wasn't saved, but the thorough check *doesn't* list that file under "Live attachments that weren't saved", it was already broken in Confluence itself (the file was deleted at some point) - nothing to recover. An image borrowed from another space needs that space extracted too, or the file downloaded by hand from Confluence.

If you've used `repair_garbled_text`'s `-Force` strip on an export, those pages will show as differing in the thorough check, which is correct - the strip removed characters the live page still has.

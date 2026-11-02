# Converting to Markdown

Once you've got a `confluence_export` folder full of pages, run (it'll ask which export folder to convert and where to put the Markdown - give it the same folder name you gave the extractor for this space):

```
.\confluence_html_to_markdown.ps1
```
or, if you don't have PowerShell:
```
python confluence_html_to_markdown.py
```

Both do the same thing, pick whichever's available.

**First run:** there's no way to reliably guess which pages are technical (Azure) versus everything else (SharePoint) just from the content, so the script won't try. Instead, it generates `confluence_export\page_destinations.csv`, one row per page (`id`, `title`, `destination`), destination left blank, and stops there. Open it in Excel, type `azure`, `sharepoint`, or `discard` into the destination column for each row, save, and run the script again.

For 500+ pages this is genuinely the tedious part, no way around it without something automatically guessing "is this technical," which isn't reliable enough to trust blindly. It's a one-time cost per page though, not something you repeat.

**⚠️ Blank is not the same as "discard".** A blank row is treated as *"doesn't need migrating anywhere"* - fine if you genuinely haven't reviewed that page yet, or if the whole export is just staying on your machine (a personal space, say). Use `discard` instead for a page you've actually looked at and decided isn't worth keeping at all - it still gets converted (in case anyone wants one last look before it's gone from Confluence for good) but lands in its own folder so it's clearly been through a decision, not just skipped over.

**Once classified**, running the script converts each page's HTML into real Markdown (headings, bold, links, lists, tables, code blocks, info panels, the lot) and routes it into one of four folders:

```
confluence_markdown_export/
├── azure/          <- pages classified "azure"
├── sharepoint/      <- pages classified "sharepoint"
├── discard/          <- reviewed and deliberately not being kept anywhere
└── unsorted/         <- blank or typo'd rows, needs a look
```

Each page's images are copied alongside its `content.md`. Your original `confluence_export` is left completely alone, so if something needs fixing you can just re-run the conversion without going back to Confluence.

**Adding more pages later?** Re-run the extractor, then re-run this script, it'll add any new pages to the CSV with a blank destination without touching rows you've already filled in, then stop so you can classify just the new ones.

If it hits a Confluence macro it doesn't recognise (a page tree, a Jira embed, something obscure), it doesn't just drop the content, it keeps whatever text was visible and flags the spot with a comment (`<!-- unrecognised macro: ... -->`) so you can go back and check it manually. Links to other Confluence pages get the same treatment, since there's no way to know the page's new URL until it's actually been migrated: the link text is kept, wrapped in `<!-- internal Confluence link to "..." -->` and `<!-- end of internal link -->`, so you can find these, and `confluence_to_azure_wiki` turns the ones between wiki pages into real links for you. (Markdown converted before this change has the older `<!-- internal Confluence link, unresolved: "..." -->` instead - re-run the conversion to get the new form.)

A few other Confluence-specific things get carried across properly rather than falling into that generic "unrecognised" bucket:

- **Links to attachments** (a PDF, a spreadsheet, anything besides an embedded image) resolve to the actual downloaded file, same as images.
- **@mentions** show the person's real name, not just a raw internal ID - this needs the extractor to resolve each mentioned user via the Confluence API, which it does once per space (not per page), saving the result to `confluence_export/user_display_names.json`.
- **Emoji/emoticons** come through as the real emoji character where Confluence provides one, or a `:name:`-style fallback otherwise.
- **Task lists** (checkboxes) keep their checked/unchecked state - real Markdown task list syntax (`- [x]`) in the `.md` export, a ☑/☐ prefix in the SharePoint paste export since real checkboxes don't survive a copy-paste.
- **Page labels** show up as a `**Tags:** label1, label2` line under the title, in both exports.

All five need a re-extraction to pick up on content pulled before this landed - the underlying data (page labels, mentioned users, resolvable attachment links) isn't in an older `manifest.json`, so these features just don't trigger rather than showing anything wrong.

**The length/naming check runs automatically** for whichever destinations actually have pages that run, no need to choose anything, since that's already decided per page by the CSV. For each destination present, it checks every page's file path against that platform's actual limits, Azure caps out at 235 characters total and turns spaces into hyphens, SharePoint's more generous at 400 characters but blocks a different set of characters. Anything too long gets flagged, and it'll offer to shorten the file names automatically so nothing fails on upload. You'll be asked for the real destination URL for a precise check, or you can leave it blank for an estimate, either way it tells you plainly which one you're getting.

Pages still sitting in `unsorted` don't go through this check at all, sort them into the CSV and re-run first.

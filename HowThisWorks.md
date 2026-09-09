# How the Confluence Migration Pipeline Works

The picture of how the scripts in this repo fit together, start to finish. For what each step actually does, day-to-day usage, and troubleshooting, see [README.md](README.md) - that's the source of truth; this page just shows the shape of it, and links into README for the detail on each step rather than repeating it, so there's only one place to keep up to date.

```mermaid
flowchart TD
    A[confluence_auth_test.py/.ps1<br/>Confirm login + API access work] --> B

    B[confluence_extractor.py/.ps1<br/>Pull every page's HTML + images] --> C

    C[(confluence_export/<br/>raw HTML, images, manifest.json)] --> D

    D[confluence_html_to_markdown.py/.ps1<br/>first run: generates page_destinations.csv] --> E

    E{Fill in page_destinations.csv<br/>azure or sharepoint, per page}

    E -->|re-run script| F[confluence_html_to_markdown.py/.ps1<br/>converts HTML to Markdown]

    F --> G[(confluence_markdown_export/azure/)]
    F --> H[(confluence_markdown_export/sharepoint/)]
    F --> I[(confluence_markdown_export/unsorted/<br/>anything not classified)]

    G --> J[Length/naming check<br/>Azure: 235 chars]
    H --> K[Length/naming check<br/>SharePoint: 400 chars]

    J --> L[git push into Azure DevOps Wiki repo]

    H --> N[confluence_sharepoint_paste.py/.ps1<br/>converts HTML to paste-ready HTML]
    N --> M[Manual: paste into a new SharePoint page]

    C --> O[confluence_table_to_csv.py/.ps1<br/>one table off one page -> CSV]
    O --> P[(confluence_table_export/)]
    P --> Q[Manual: SharePoint "Create list from CSV/Excel"]

    style M stroke-dasharray: 5 5
    style Q stroke-dasharray: 5 5
```

*(Dashed boxes are the manual steps left - see [Getting pages into SharePoint](README.md#getting-pages-into-sharepoint) and [Pages that are really just a table](README.md#pages-that-are-really-just-a-table) in the README for why, and what a real fix would need.)*

## Stage by stage - see README for the detail

1. **Confirm access works** - [How the auth test works](README.md#how-the-auth-test-works)
2. **Already got a `confluence_export` folder from before, with garbled characters in it (`Â`, `â€™`)?** Run `repair_garbled_text` on it now - see that entry in [What's in here](README.md#whats-in-here). First time ever running this? Skip straight to step 3, nothing to repair yet.
3. **Pull everything down** - [Pulling everything down](README.md#pulling-everything-down)
4. **Classify pages, then convert to Markdown** - [Turning it into Markdown](README.md#turning-it-into-markdown)
5. **Get pages into SharePoint** - [Getting pages into SharePoint](README.md#getting-pages-into-sharepoint)
6. **A page that's really just a table?** - [Pages that are really just a table](README.md#pages-that-are-really-just-a-table) - better off as a SharePoint List

For the full walkthrough with actual commands in order, see [Getting started - which script, in what order](README.md#getting-started---which-script-in-what-order) in the README.

## Where things actually stand

See [Where things stand](README.md#where-things-stand) in the README - kept in one place so this page can't drift out of sync with it.

## A couple of things worth remembering

- **Nothing here needs admin access.** Every step uses the same read permission you already have browsing Confluence normally.
- **No credentials are ever stored.** Every script asks for your username and password at runtime and never writes them anywhere.
- **The raw export is never touched by later steps.** `confluence_export/` stays untouched even if you re-run later stages, so nothing's ever lost by re-running one.
- **Small test runs are safe.** The `.ps1` scripts are specifically hardened against a PowerShell quirk where a result set with exactly one item (one page, one attachment, one page in a bucket) can otherwise get silently misread as "nothing" - so extracting or converting just a page or two to try the pipeline out works exactly like a full run would.

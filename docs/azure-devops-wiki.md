# Getting pages into Azure DevOps Wiki

An Azure DevOps Wiki is a git repository behind the scenes, with its own rules about how pages are laid out in it: each page is a file named after the page (`How-to-deploy.md`), sub-pages go in a folder named after their parent, a `.order` file in each folder sets the order pages appear in, and images live in one `.attachments` folder. The converter's `azure/` folder isn't laid out like that - every page is a `content.md`, which the wiki would show as a page called "content" - so first run:

```
.\confluence_to_azure_wiki.ps1
```
or
```
python confluence_to_azure_wiki.py
```

It asks for the export folder, the Markdown folder, a new folder to build the wiki in (`confluence_azure_wiki_...` by default), and optionally the wiki repo's URL for the 235-character path check. Then it builds:

- **One file per page, in the Confluence page tree.** A page whose parent went to SharePoint (or was discarded) moves up to its nearest parent that's coming to the wiki, or to the top level.
- **Names the wiki's way.** A hyphen in a file name means a space, so a real hyphen in a title is stored as `%2D`; `: < > * ? | "` are encoded the same way; `/ \ #` can't appear at all. A path still too long is trimmed, with the page id added so it stays unique.
- **`.order` files**, so pages keep Confluence's order instead of going alphabetical.
- **`.attachments`**, with every image and attachment link pointing at it. An image a page borrows from another page is found there too, as long as exactly one page in the export has a file by that name.
- **Real links between pages.** A link to a page that isn't coming to the wiki (SharePoint, another space, deleted) is left flagged, and listed with the reason in `wiki_link_report.csv` in the export folder.

It never writes into your wiki clone (it refuses a folder that's a git repo) and never pushes anything. Re-running it rebuilds its folder from scratch. Then, to get it into the wiki - if you've never used git before, here's the actual steps, not just "git push it":

1. **Get Git itself, if it's not already on your machine.** Download it from [git-scm.com](https://git-scm.com/downloads) and install it - default options are fine, no admin rights needed for the per-user install.
2. **Get the wiki's repo address.** In Azure DevOps, open your project's Wiki, click **Clone Wiki** (or **Clone repository** if you're pointed at the underlying repo directly), and copy the URL it gives you (ends in `.wiki` or `.git`).
3. **Get a local copy of it.** Open a terminal, go to a folder you want to work in, and run:
   ```
   git clone <the URL you copied>
   ```
   This creates a new folder containing everything currently in the wiki.
4. **Copy your pages in.** Copy everything from inside the folder `confluence_to_azure_wiki` built into that cloned folder - the `.order` files and `.attachments` folder too - except the `.confluence_to_azure_wiki` marker file. If the wiki already has pages, merge the top-level `.order` by hand (keep its lines, add the new ones) rather than replacing it.
5. **Send it up.** Back in the terminal, inside that cloned folder, run:
   ```
   git add .
   git commit -m "Import pages from Confluence"
   git push
   ```
   That's it - refresh the Wiki in Azure DevOps and your pages are there.

If typing commands isn't your thing, [GitHub Desktop](https://desktop.github.com/) (works with Azure DevOps too, not just GitHub) gives you the same clone/commit/push steps as buttons in a normal-looking app instead - point it at the same repo URL from step 2.

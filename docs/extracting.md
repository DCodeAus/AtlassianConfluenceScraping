# Connecting and pulling pages down

## Credentials, don't worry about them

None of these scripts have a username, password, or even your Confluence site address sitting in the file. `confluence_auth_test` and `confluence_extractor` ask for all of it every time they run:

```
Confluence base URL: https://confluence.yourcompany.com
Confluence space key: ABC
Confluence username: dan.smith
Confluence password: ****
```

Python scripts hide the password using `getpass`, PowerShell scripts do the same with `Read-Host -AsSecureString`. Either way, nothing gets written to disk, logged anywhere, or shown on screen. That means you can hand this whole repo to someone else, or commit it, without worrying about leaking anything - there's nothing sensitive, or even identifying, baked in to begin with.

If you ever want to automate this properly (a scheduled job, say) where being asked everything every time isn't practical, set `CONFLUENCE_BASE_URL`, `CONFLUENCE_SPACE_KEY`, `CONFLUENCE_USERNAME`, and `CONFLUENCE_PASSWORD` as environment variables before running the script and the prompts are skipped. Just don't ever go back to hardcoding any of it in the file.

Once an export exists, the scripts that come after the extractor don't need asking again: the extractor saves the site address and space key (never your login) into the export folder as `export_source.json`, and the checking scripts pick them up from there.

If an older version of a script ever did have real credentials typed into it and pushed to Git, treat that password as burnt and change it. Deleting it from the file afterwards doesn't remove it from history.

## How the auth test works

It logs in with your normal Confluence username and password, asks for one page from whichever space you point it at, and tells you straight away whether that worked. If it did, you're clear to run the real extractor. If you get a 401 or 403 or an SSL error, it'll tell you which and point at the fix - see [When something goes wrong](troubleshooting.md).

Worth running this before touching the full extractor, no point discovering an auth problem 200 pages into a 500-page run.

### Who you're logged in as

Every script that talks to Confluence (the auth test, the extractor and both checks) prints who Confluence thinks you are before it does anything else:

```
Signed in to Confluence as: Dan Smith
```

That matters because some Confluence setups don't turn a login away when it doesn't work - they let you in as an **anonymous visitor** instead. You still get every page anyone can see without logging in, so it looks like it worked, but anything that needs a login is quietly left out - and the checking scripts can't spot it either, since they're anonymous too. If that happens you'll see a `WARNING: Confluence doesn't know who you are` and be asked whether to carry on. Running unattended (nobody at the keyboard to answer), it warns and carries on rather than waiting - set `CONFLUENCE_ALLOW_ANONYMOUS=1` to get that same behaviour at the keyboard, if an anonymous copy of an open space really is what you want.

This happened for real with `-UseDefaultCredentials` (the Windows-login option): it got through the network but Confluence treated it as nobody, and two login-only pages were missed out of 510. If you see the warning, try the other way of logging in - typing your username and password instead of `-UseDefaultCredentials`, or the other way round.

## Pulling everything down

Once the auth test passes, run the matching extractor (`confluence_extractor.py` or `.ps1`, whichever worked for you). It'll ask for your `BASE_URL` and `SPACE_KEY` if you haven't set them, then start working through every page in that space, saving the content and downloading images as it goes. For 500+ pages this'll take a few minutes, that's normal, not a hang, you'll see progress printed as `[142/500] Page Title`.

A brief network blip won't even show up as a failure, connection errors and 5xx responses get retried a couple of times with a short backoff before giving up. If a page still fails after that (odd permissions, a persistent error), it won't kill the whole run, that page just gets logged to `failures.json` at the end so you can look at it separately.

Everything lands in a `confluence_export` folder (it'll ask - see below), one subfolder per page, each with its own `content.html`, `rendered.html` and `images/`. `content.html` is the page's raw content, which the Markdown conversion works from. `rendered.html` is the page as Confluence displayed it - open it in any browser - and it's the only copy of anything a macro pulled in from elsewhere (an included page, a page tree, often a Jira list), since the raw content only has a reference to it. Its images point at the saved copies in `images/`, so it still works once Confluence is gone. There's also a `pages_index.csv` with one row per page - title, original address, who created and last edited it and when - for finding your way around the export in Excel. It also writes a `README.md` right into that folder, recording where it came from, who ran it, the date, and how many pages/attachments ended up there - handy if this export folder ever leaves your machine (e.g. uploaded as its own repo for a teammate), since then it doesn't depend on anyone remembering, or still having this script around.

Only want one page instead of a whole space, say someone's personal space? Alongside the username/password prompts, it'll also ask for a page ID - leave it blank to pull the whole space as normal, or paste one in (grabbed straight from the page's URL, `.../pages/123456789/Page+Title`) to pull just that page instead. `SPACE_KEY` is ignored when you give it a page ID. Needs no more access than opening the page normally does. Give it the same export folder as the rest of that space and it updates that one page in place, keeping every other page already there - that's how you fix individual pages the checks flag. For unattended runs, set `CONFLUENCE_PAGE_ID` as an environment variable to skip the prompt, same as the credentials.

**Extracting more than one space** (your own team space, then a personal one, say)? It asks what to name the export folder every run, defaulting to one based on the space key (e.g. `confluence_export_TEAM`) - just answer that prompt differently for each space and they'll never overwrite each other. `confluence_html_to_markdown.ps1`/`.py` and every other script downstream ask the same thing, so give them the matching folder name when it's that space's turn. Set `CONFLUENCE_EXPORT_DIR` as an environment variable to fix it in advance for unattended runs.

## Putting an export into its own git repo

Want to hand an export to someone else, or keep it somewhere safer than your own drive? `confluence_export_to_git.py` / `.ps1` sets one export folder up as its own git repo, ready to push:

```
python confluence_export_to_git.py
.\confluence_export_to_git.ps1
```

It asks which folder (the raw export or the converted Markdown one, whichever you want to hand over - a full path works too), then sets up the repo, adds a `.gitignore` for the report and backup files that don't belong in it, asks for your name/email for commits if git doesn't already have one, warns about any file too big for GitHub/Azure DevOps (over 50 MB), stages everything and offers to make the first commit. Last, it asks for the URL of the empty repo to push to - create that first (empty, no README) on GitHub, Azure DevOps or wherever your team keeps things.

It never pushes for you. Pushing is what actually puts the content somewhere else, so that's always one command left for you to run once you've checked the destination is private and allowed to hold it:

```
cd "path\to\confluence_export_TEAM"
git push -u origin main
```

Run it again after re-extracting and it'll reuse the same repo and commit the changes as an update. Needs [git](https://git-scm.com) installed. The export folder's own `README.md` (written by the extractor) says where it came from, so the repo makes sense to whoever opens it.

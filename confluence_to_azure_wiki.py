"""
Confluence Markdown to Azure DevOps Wiki layout - stdlib only, no pip install.

Takes the pages confluence_html_to_markdown sorted into "azure" and lays
them out the way an Azure DevOps Wiki repo expects, so pushing them is
the whole job rather than the start of a clean-up:

  - one file per page, named after the page (How-to-deploy.md), not a
    folder of content.md files that would all show up titled "content"
  - sub-pages in a folder named after their parent page, following the
    Confluence page tree (a page whose parent went to SharePoint moves up
    to its nearest parent that's coming to the wiki, or to the top)
  - a .order file in every folder, so pages keep their Confluence order
    instead of going alphabetical
  - images and attachments in the wiki's .attachments folder, with the
    links pointing at them
  - links between pages turned into real wiki links - anything that
    can't be (the page went to SharePoint, lives in another space, or no
    longer exists) stays flagged and is listed in wiki_link_report.csv
  - page names that break the wiki's rules (/ \\ #, a hyphen or colon in
    the title, too long a path) fixed up the way the wiki itself does

Pure local file processing - doesn't touch Confluence or Azure DevOps.
Builds into a fresh folder, never into your wiki repo directly, and never
pushes anything: copying the result in and pushing is left to you.

    python confluence_to_azure_wiki.py
    python confluence_to_azure_wiki.py C:\\path\\to\\confluence_export_TEAM

Asks for the export folder, the Markdown folder and where to build the
wiki. Set CONFLUENCE_EXPORT_DIR, CONFLUENCE_MARKDOWN_EXPORT_DIR,
CONFLUENCE_WIKI_EXPORT_DIR and CONFLUENCE_WIKI_REPO_URL to skip the
questions.

Something broken or unclear? Raise an issue at
https://github.com/DCodeAus/AtlassianConfluenceScraping/issues
"""

import csv
import glob
import os
import re
import shutil
import sys

# Everything the scripts here have in common - the questions, reading an
# export folder - lives in confluence_common.py, so a fix there fixes
# every script at once. It has to be in the same folder as this one.
try:
    from confluence_common import (
        ask_export_dir, input_with_help, load_export_manifest,
        normalise_relative_path, read_export_source, suggest_output_dir,
    )
except ImportError:
    print("Can't find confluence_common.py (or it's out of date) - it needs to be")
    print("in the same folder as this script. Download the whole repository")
    print("rather than just this one file.")
    raise SystemExit(1)

# The wiki caps a page's full path - repo URL, folders and file name - at
# 235 characters. Anything longer is trimmed, keeping the page id so
# trimmed names can't collide.
AZURE_MAX_PATH_LENGTH = 235

# Characters a wiki page title can contain but its file name has to carry
# encoded - a hyphen in the file name means a space in the title, so a
# real hyphen needs its own code. "%" goes first so the codes added after
# it aren't encoded a second time.
WIKI_ENCODED_CHARACTERS = [
    ("%", "%25"), ("-", "%2D"), (":", "%3A"), ("<", "%3C"), (">", "%3E"),
    ("*", "%2A"), ("?", "%3F"), ("|", "%7C"), ('"', "%22"),
]

# Written into the output folder so a re-run knows it's safe to clear it
# out - a folder without it is never deleted.
OUTPUT_MARKER = ".confluence_to_azure_wiki"

# The converter wraps each link to another page between these two comments
# (see confluence_html_to_markdown) - start, link text, end.
PAGE_LINK_PATTERN = re.compile(
    r'<!-- internal Confluence link to "(?P<title>.*?)"(?: \(space (?P<space>[^)]*)\))? -->'
    r"(?P<text>.*?)<!-- end of internal link -->",
    re.DOTALL,
)
# Older converter output had no start marker, so there's no telling where
# the link text began - these can only be counted and pointed out.
OLD_PAGE_LINK_PATTERN = re.compile(r"<!-- internal Confluence link, unresolved")
IMAGE_LINK_PATTERN = re.compile(r"\]\(<images/(?P<name>[^>]*)>\)")


def to_wiki_page_name(title, page_id):
    """A page title as the wiki's file name (without .md): / and \\ can't
    appear at all, so they become a hyphen in the title; # is dropped;
    the characters in WIKI_ENCODED_CHARACTERS are encoded; and spaces
    become hyphens. "Q3/Q4: plan" -> "Q3%2DQ4%3A-plan", which the wiki
    shows as "Q3-Q4: plan"."""
    name = re.sub(r"[\x00-\x1f\x7f]", "", title)
    name = re.sub(r"[/\\]", "-", name).replace("#", "")
    name = name.strip().strip(".").strip()
    for character, code in WIKI_ENCODED_CHARACTERS:
        name = name.replace(character, code)
    name = re.sub(r"\s+", "-", name)
    return name or f"Page-{page_id}"


def trim_page_name(name, page_id, room):
    """Shortens a page name to fit in `room` characters, ending in -<page id>
    so it stays unique, and never cutting an encoded character (%2D) in half."""
    suffix = f"-{page_id}"
    keep = max(1, room - len(suffix))
    trimmed = name[:keep]
    # Back off if the cut landed inside a %XX code.
    trimmed = re.sub(r"%[0-9A-Fa-f]?$", "", trimmed)
    return trimmed + suffix


def load_classification(export_dir):
    """page_destinations.csv as page id -> destination, or None if the
    Markdown converter hasn't been run on this export yet."""
    path = os.path.join(export_dir, "page_destinations.csv")
    if not os.path.isfile(path):
        return None
    # utf-8-sig: Excel's "CSV UTF-8" save adds a BOM.
    with open(path, "r", newline="", encoding="utf-8-sig") as f:
        return {row["id"]: re.sub(r"\s", "", row["destination"]).lower() for row in csv.DictReader(f)}


def nearest_wiki_parent(page, pages_by_id, wiki_ids):
    """The closest ancestor that's also coming to the wiki, so a page whose
    parent went to SharePoint (or was discarded) still sits in the right
    branch - or None for the top level."""
    seen = set()
    parent_id = page.get("parent_id")
    while parent_id and str(parent_id) not in seen:
        parent_id = str(parent_id)
        seen.add(parent_id)
        if parent_id in wiki_ids:
            return parent_id
        parent_id = (pages_by_id.get(parent_id) or {}).get("parent_id")
    return None


def prepare_output_dir(output_dir):
    """Clears out a previous run's output so pages renamed or moved since
    don't linger - but only a folder this script made. Refuses a git repo
    outright, in case it's pointed at the wiki clone itself."""
    if os.path.isdir(os.path.join(output_dir, ".git")):
        print(f"'{output_dir}' is a git repo - probably your wiki clone. This builds")
        print("into a separate folder that you then copy into the clone, so it")
        print("can never delete anything that's already in your wiki. Pick another")
        print("folder name (or leave it blank for the default) and run this again.")
        sys.exit(1)
    if os.path.isdir(output_dir) and os.listdir(output_dir):
        if not os.path.isfile(os.path.join(output_dir, OUTPUT_MARKER)):
            print(f"'{output_dir}' already exists and wasn't made by this script, so it's")
            print("been left alone. Pick an empty or new folder and run this again.")
            sys.exit(1)
        shutil.rmtree(output_dir)
        print(f"Cleared the previous build in '{output_dir}'.")
    os.makedirs(output_dir, exist_ok=True)
    with open(os.path.join(output_dir, OUTPUT_MARKER), "w", encoding="utf-8") as f:
        f.write("Built by confluence_to_azure_wiki - safe for it to clear and rebuild.\n"
                "Don't copy this file into your wiki repo.\n")


def main():
    export_dir = ask_export_dir(
        "Export folder (blank for 'confluence_export'): ",
        [
            "The export you converted with confluence_html_to_markdown - the",
            "same folder name you gave the extractor for this space.",
            "Leave blank for: confluence_export",
        ],
        args=sys.argv[1:],
    )
    manifest, _ = load_export_manifest(export_dir)

    suggested_markdown_dir = suggest_output_dir(export_dir, "confluence_markdown_export")
    markdown_dir = os.environ.get("CONFLUENCE_MARKDOWN_EXPORT_DIR") or input_with_help(
        f"Markdown folder (blank for '{suggested_markdown_dir}'): ",
        [
            "Where confluence_html_to_markdown put the converted pages - the",
            "folder with azure/, sharepoint/ etc. inside it.",
            f"Leave blank for: {suggested_markdown_dir}",
        ],
    ).strip() or suggested_markdown_dir
    azure_dir = os.path.join(markdown_dir, "azure")

    classification = load_classification(export_dir)
    if classification is None or not os.path.isdir(azure_dir):
        print("Can't find the converted pages - run confluence_html_to_markdown on")
        print(f"'{export_dir}' first (and mark the pages for the wiki 'azure' in")
        print("page_destinations.csv), then run this again.")
        sys.exit(1)

    suggested_output_dir = suggest_output_dir(export_dir, "confluence_azure_wiki")
    output_dir = os.environ.get("CONFLUENCE_WIKI_EXPORT_DIR") or input_with_help(
        f"Folder to build the wiki in (blank for '{suggested_output_dir}'): ",
        [
            "A NEW folder to lay the wiki out in - not your wiki clone itself.",
            "You copy what's in it into the clone afterwards (instructions at",
            "the end). Re-running this rebuilds it from scratch.",
            f"Leave blank for: {suggested_output_dir}",
        ],
    ).strip() or suggested_output_dir

    repo_url = os.environ.get("CONFLUENCE_WIKI_REPO_URL")
    if repo_url is None:
        repo_url = input_with_help(
            "Wiki repo URL, for the path length check (blank to estimate): ",
            [
                "The wiki caps a page's full path, INCLUDING the repo's URL, at 235",
                "characters. In Azure DevOps, open the Wiki, then ... > Clone wiki,",
                "and paste the URL, e.g.",
                "https://dev.azure.com/yourorg/yourproject/_git/yourproject.wiki",
                "Blank still checks, just without the URL's share of the length.",
            ],
        )
    repo_url = repo_url.strip().rstrip("/")

    for page in manifest:
        page["id"] = str(page["id"])
        if page.get("parent_id"):
            page["parent_id"] = str(page["parent_id"])
    pages_by_id = {page["id"]: page for page in manifest}
    wiki_pages = [page for page in manifest if classification.get(page["id"]) == "azure"]
    if not wiki_pages:
        print("No pages are marked 'azure' in page_destinations.csv, so there's nothing")
        print("for the wiki. Mark the ones that belong there and run the converter again.")
        sys.exit(1)
    wiki_ids = {page["id"] for page in wiki_pages}
    space_key = read_export_source(export_dir).get("spaceKey") or ""

    # --- Where each page goes: parent, file name, path ---
    wiki_parent = {page["id"]: nearest_wiki_parent(page, pages_by_id, wiki_ids) for page in wiki_pages}
    # A page tree that loops back on itself (shouldn't happen, but a
    # corrupt manifest shouldn't lose pages) would leave those pages with
    # no way down from the top - put them at the top level instead.
    for page_id in wiki_parent:
        seen, current = set(), page_id
        while current is not None and current not in seen:
            seen.add(current)
            current = wiki_parent[current]
        if current is not None:
            wiki_parent[page_id] = None
    children = {}  # parent id (None = top level) -> child pages, in manifest order
    for page in wiki_pages:
        children.setdefault(wiki_parent[page["id"]], []).append(page)

    path_of = {}  # page id -> list of page names from the top, e.g. ["Ops", "Deploy"]
    renamed = []
    prefix_length = len(repo_url) + 1 if repo_url else 0

    def place(parent_id, parent_path):
        used = set()
        for page in children.get(parent_id, []):
            name = to_wiki_page_name(page["title"], page["id"])
            # Unique within its folder - checked ignoring case, since
            # Windows can't hold two files differing only by case.
            if name.lower() in used:
                name = f"{name}-{page['id']}"
            folder = "/".join(parent_path)
            full_length = prefix_length + (len(folder) + 1 if folder else 0) + len(name) + len(".md")
            if full_length > AZURE_MAX_PATH_LENGTH:
                room = len(name) - (full_length - AZURE_MAX_PATH_LENGTH)
                name = trim_page_name(name, page["id"], room)
                renamed.append(page["title"])
            used.add(name.lower())
            path_of[page["id"]] = parent_path + [name]
            place(page["id"], path_of[page["id"]])

    place(None, [])

    wiki_page_by_title = {page["title"]: page for page in wiki_pages}

    # A page can show an image that's attached to a different page - the
    # converter only knows its file name, so it's not in this page's own
    # images folder. If exactly one page in the export has an attachment by
    # that name, that's the one: original name -> (page id, saved file).
    attachment_owners = {}
    for page in manifest:
        for entry in page.get("attachments", []):
            if isinstance(entry, dict):
                saved = os.path.join(export_dir, normalise_relative_path(page["folder"]), "images", entry["saved_as"])
                attachment_owners.setdefault(entry["filename"], []).append((page["id"], saved))

    # --- Build it ---
    prepare_output_dir(output_dir)
    attachments_dir = os.path.join(output_dir, ".attachments")

    link_report = []  # rows for wiki_link_report.csv
    missing_images = []
    not_converted = []
    old_style_links = 0
    linked = 0
    attachment_count = 0

    for page in wiki_pages:
        source_folder = os.path.join(azure_dir, normalise_relative_path(page["folder"]))
        # content.md, or a shorter name the converter's length check gave it.
        markdown_files = sorted(glob.glob(os.path.join(source_folder, "*.md")))
        if markdown_files:
            with open(markdown_files[0], "r", encoding="utf-8-sig") as f:
                markdown = f.read()
        else:
            not_converted.append(page["title"])
            markdown = (f"> **NOTE:** This page couldn't be converted from Confluence, so it's "
                        f"empty here. Check the converter's output for \"{page['title']}\".\n")

        # The converter starts every page with "# <title>" - the wiki
        # already shows the page name as its title, so it'd appear twice.
        markdown = re.sub(r"\A# [^\n]*\n+", "", markdown)

        def relink_image(match):
            nonlocal attachment_count
            name = match.group("name")
            source, owner_id = os.path.join(source_folder, "images", name), page["id"]
            if not os.path.isfile(source):
                # Borrowed from another page? Only if exactly one page has it.
                owners = [o for o in attachment_owners.get(name, []) if os.path.isfile(o[1])]
                if len(owners) != 1:
                    missing_images.append(f"{page['title']}: {name}")
                    return match.group(0)
                owner_id, source = owners[0]
            # Every page's attachments share one folder, so the id of the
            # page it's attached to keeps two pages' "image.png" apart.
            new_name = owner_id + "-" + re.sub(r"\s+", "-", os.path.basename(source))
            destination = os.path.join(attachments_dir, new_name)
            if not os.path.exists(destination):
                os.makedirs(attachments_dir, exist_ok=True)
                shutil.copy2(source, destination)
                attachment_count += 1
            return f"](</.attachments/{new_name}>)"

        markdown = IMAGE_LINK_PATTERN.sub(relink_image, markdown)

        def relink_page(match):
            nonlocal linked
            title, space, text = match.group("title"), match.group("space"), match.group("text")
            target = wiki_page_by_title.get(title)
            if space and space_key and space != space_key:
                reason = f"in another space ({space})"
            elif target is not None:
                linked += 1
                return f"[{text}](</{'/'.join(path_of[target['id']])}>)"
            else:
                match_in_export = next((p for p in manifest if p["title"] == title), None)
                if match_in_export is None:
                    reason = "not in this export (deleted, or in another space)"
                else:
                    destination = classification.get(match_in_export["id"]) or "not classified"
                    reason = f"going to {destination}, not the wiki"
            link_report.append({"page": page["title"], "link_text": text, "links_to": title, "reason": reason})
            return match.group(0)

        markdown = PAGE_LINK_PATTERN.sub(relink_page, markdown)
        old_style_links += len(OLD_PAGE_LINK_PATTERN.findall(markdown))

        page_path = os.path.join(output_dir, *path_of[page["id"]]) + ".md"
        os.makedirs(os.path.dirname(page_path), exist_ok=True)
        with open(page_path, "w", encoding="utf-8") as f:
            f.write(markdown)

    # One .order per folder, listing its pages in Confluence's order.
    for parent_id, pages in children.items():
        folder = os.path.join(output_dir, *path_of[parent_id]) if parent_id else output_dir
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, ".order"), "w", encoding="utf-8", newline="\n") as f:
            f.write("".join(path_of[page["id"]][-1] + "\n" for page in pages))

    report_path = os.path.join(export_dir, "wiki_link_report.csv")
    with open(report_path, "w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=["page", "link_text", "links_to", "reason"])
        writer.writeheader()
        writer.writerows(link_report)

    # --- What happened, and what to do next ---
    print(f"\nBuilt {len(wiki_pages)} wiki page(s) in '{output_dir}'.")
    print(f"  {linked} link(s) between pages turned into wiki links")
    print(f"  {attachment_count} image(s)/attachment(s) copied to .attachments")
    if link_report:
        print(f"  {len(link_report)} link(s) left flagged - the page they point to isn't")
        print(f"  coming to the wiki. Listed in {report_path}")
    if renamed:
        print(f"  {len(renamed)} page name(s) trimmed to fit the {AZURE_MAX_PATH_LENGTH}-character path limit:")
        for title in renamed[:15]:
            print(f"    - {title}")
    if missing_images:
        print(f"  {len(missing_images)} image(s) a page shows couldn't be found in the export (not")
        print("  saved, or borrowed from another space) - their links are left as they were:")
        for item in missing_images[:15]:
            print(f"    - {item}")
    if not_converted:
        print(f"  {len(not_converted)} page(s) had no converted Markdown - each is a placeholder")
        print("  saying so. Check the converter's warnings for:")
        for title in not_converted[:15]:
            print(f"    - {title}")
    if old_style_links:
        print(f"  {old_style_links} link(s) are in the converter's OLD format, which this can't")
        print("  turn into wiki links. Run confluence_html_to_markdown again (this")
        print("  version), then this script again, to fix them.")

    print("\nNext - into the wiki (needs git, https://git-scm.com):")
    print("  1. In Azure DevOps: Wiki > ... > Clone wiki, copy the URL, then:")
    print("       git clone <that URL>")
    print(f"  2. Copy EVERYTHING inside '{output_dir}' into the cloned folder,")
    print(f"     hidden .order files and .attachments included, except {OUTPUT_MARKER}.")
    print("     If the wiki already has pages, merge the top-level .order by hand")
    print("     (keep its lines and add these) rather than replacing it.")
    print("  3. In the cloned folder:")
    print("       git add -A")
    print("       git commit -m \"Import pages from Confluence\"")
    print("       git push")
    print("Check a few pages in the wiki before telling anyone it's moved.")


if __name__ == "__main__":
    main()

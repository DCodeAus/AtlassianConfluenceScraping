"""
Export-to-git setup - stdlib only, no pip install. Needs git itself
installed (https://git-scm.com - "Git for Windows" on Windows).

Turns one finished export folder into its own git repo, ready to push
somewhere your team can get at it (GitHub, Azure DevOps, wherever) -
asks where your export is, then:

  - sets it up as a git repo (or reuses it, if it already is one)
  - adds a .gitignore for the leftovers that don't belong in it
    (verification reports, repair_garbled_text's .bak backups)
  - asks for the name/email to put on commits, if git doesn't have one
  - warns about any file too big for GitHub/Azure DevOps to accept
  - stages everything, and offers to make the first commit for you
  - optionally records where it'll be pushed to

It never pushes anything itself - that's always left as one command for
you to run, once you've checked the remote is somewhere this content is
allowed to live.

Works on the raw export (confluence_export_TEAM) or the converted
Markdown (confluence_markdown_export_TEAM) - whichever one you want to
hand over. The extractor writes a README.md into the export folder
saying where it came from, so a repo made from that is self-explanatory
to whoever opens it.

    python confluence_export_to_git.py
    python confluence_export_to_git.py C:\\path\\to\\confluence_export_TEAM

Set CONFLUENCE_EXPORT_DIR to skip the folder question.

Supported by Daniel - raise issues with him.
"""

import os
import shutil
import subprocess
import sys


# Above this, GitHub warns on push; at 100 MB it refuses the push outright
# (Azure DevOps is similar). Flagged up front, since finding out at push
# time means rewriting the commit to get rid of it.
LARGE_FILE_WARNING_BYTES = 50 * 1024 * 1024

# Leftovers from the other scripts that land inside an export folder but
# aren't part of the content itself. Only written if the folder doesn't
# already have a .gitignore - yours is never overwritten.
EXPORT_GITIGNORE = """# Written by confluence_export_to_git - leftovers from the checking/repair
# scripts that aren't part of the export itself.
verification_report.json
live_content_report.json
*.bak
garbled_text_repair_log.json

# OS clutter
.DS_Store
Thumbs.db
desktop.ini
"""


def input_with_help(prompt, help_lines):
    """Like input(), but typing a bare "?" prints an explanation of what's
    being asked for instead of being treated as the actual answer, then
    asks again."""
    while True:
        answer = input(prompt)
        if answer != "?":
            return answer
        for line in help_lines:
            print(line)


def git(folder, *args, check=True):
    """Runs one git command inside the export folder and hands back its
    output - so every call below reads like the command you'd type."""
    result = subprocess.run(
        ["git", "-C", folder, *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and result.returncode != 0:
        print(f"git {' '.join(args)} failed:")
        print(result.stderr.strip() or result.stdout.strip())
        sys.exit(1)
    return result


def format_size(num_bytes):
    for unit in ("bytes", "KB", "MB", "GB"):
        if num_bytes < 1024 or unit == "GB":
            return f"{num_bytes:.0f} {unit}" if unit == "bytes" else f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024


def main():
    if not shutil.which("git"):
        print("Can't find git on this machine. Install it from https://git-scm.com")
        print("(\"Git for Windows\" on Windows - the default options are fine),")
        print("then open a NEW terminal window and run this again.")
        sys.exit(1)

    args = sys.argv[1:]
    if args:
        export_dir = args[0]
    else:
        export_dir = os.environ.get("CONFLUENCE_EXPORT_DIR") or input_with_help(
            "Export folder to put into git (blank for 'confluence_export'): ",
            [
                "Which folder to turn into a git repo - the folder name you",
                "gave the extractor (or the Markdown converter) for that",
                "space, or its full path if it's somewhere else (e.g. on a",
                "shared drive).",
                "Leave blank for: confluence_export",
            ],
        ).strip()
        # Windows "Copy as path" and dragging a folder into the terminal
        # both wrap the path in quotes - strip them so either works.
        export_dir = export_dir.strip('"').strip("'") or "confluence_export"

    if not os.path.isdir(export_dir):
        print(f"Can't find '{export_dir}' from here - run this from the folder")
        print("that contains it, or give its full path instead.")
        sys.exit(1)
    export_dir = os.path.abspath(export_dir)

    if not os.path.isfile(os.path.join(export_dir, "manifest.json")) and not os.path.isfile(os.path.join(export_dir, "README.md")):
        print(f"'{export_dir}' doesn't look like an export - no manifest.json or")
        print("README.md in it.")
        if input("Carry on anyway? (y/N): ").strip().lower() != "y":
            sys.exit(1)

    # The export usually sits inside this scripts folder, which is itself
    # a git repo. That's fine as long as the scripts repo ignores it (its
    # .gitignore covers every confluence_export*/ folder) - otherwise the
    # scripts repo would try to swallow the export's repo as well.
    already_a_repo = os.path.isdir(os.path.join(export_dir, ".git"))
    if not already_a_repo:
        outer = git(export_dir, "rev-parse", "--show-toplevel", check=False)
        if outer.returncode == 0:
            ignored = git(outer.stdout.strip(), "check-ignore", "-q", export_dir, check=False).returncode == 0
            if not ignored:
                print(f"'{export_dir}' is inside another git repo ({outer.stdout.strip()})")
                print("that ISN'T ignoring it - its contents could end up committed there")
                print("too. Safest is to move the export folder somewhere outside it first.")
                if input("Carry on anyway? (y/N): ").strip().lower() != "y":
                    sys.exit(1)

    if already_a_repo:
        print(f"'{export_dir}' is already a git repo - reusing it.")
    else:
        git(export_dir, "init")
        # Name the first branch "main" whatever this git version defaults
        # to - older ones still say "master", which then doesn't match
        # what GitHub/Azure DevOps expect when you push.
        git(export_dir, "symbolic-ref", "HEAD", "refs/heads/main")
        print(f"Created a new git repo in '{export_dir}'.")

    # Page folders + images/ + a long attachment name can pass Windows'
    # old 260-character path limit, which git for Windows refuses by
    # default ("Filename too long"). Only affects this repo, and does
    # nothing at all on Mac/Linux.
    git(export_dir, "config", "core.longpaths", "true")

    gitignore_path = os.path.join(export_dir, ".gitignore")
    if os.path.exists(gitignore_path):
        print("Keeping the .gitignore that's already there.")
    else:
        with open(gitignore_path, "w", encoding="utf-8") as f:
            f.write(EXPORT_GITIGNORE)
        print("Added a .gitignore for verification reports and repair backups.")

    # git refuses to commit without a name and email to put on it. Only
    # asked if it isn't set up already, and only saved for this repo -
    # your settings everywhere else stay as they are.
    for key, prompt, help_text in [
        ("user.name", "Your name, as it should appear on commits: ", "e.g. Jane Smith - shown as the author of the commit."),
        ("user.email", "Your email, as it should appear on commits: ", "Usually your work email, or the one on your GitHub/Azure DevOps account."),
    ]:
        if not git(export_dir, "config", key, check=False).stdout.strip():
            value = input_with_help(prompt, [help_text]).strip()
            if value:
                git(export_dir, "config", key, value)

    # Big-file check before staging - see LARGE_FILE_WARNING_BYTES above.
    large_files = []
    total_bytes = 0
    for root, dirs, files in os.walk(export_dir):
        dirs[:] = [d for d in dirs if d != ".git"]
        for name in files:
            path = os.path.join(root, name)
            size = os.path.getsize(path)
            total_bytes += size
            if size > LARGE_FILE_WARNING_BYTES:
                large_files.append((os.path.relpath(path, export_dir), size))

    if large_files:
        print(f"\n{len(large_files)} file(s) over {format_size(LARGE_FILE_WARNING_BYTES)} - GitHub warns above")
        print("50 MB and refuses anything over 100 MB, Azure DevOps is similar:")
        for path, size in sorted(large_files, key=lambda item: -item[1]):
            print(f"  {format_size(size):>10}  {path}")
        print("Options: add them to .gitignore and share them another way, or set up")
        print("Git LFS (https://git-lfs.com) for them before committing.")
        if input("Stage everything anyway? (y/N): ").strip().lower() != "y":
            print("Stopped before staging. The repo's set up - fix the above, then run")
            print("this again (it'll pick up where it left off).")
            sys.exit(0)

    print("\nStaging files (can take a minute for a big space)...")
    git(export_dir, "add", "-A")
    staged = [p for p in git(export_dir, "diff", "--cached", "--name-only", "-z").stdout.split("\0") if p]
    print(f"{len(staged)} file(s) staged, {format_size(total_bytes)} in total.")

    if staged:
        if input("\nMake the commit now? (y/N): ").strip().lower() == "y":
            has_commits = git(export_dir, "rev-parse", "--verify", "HEAD", check=False).returncode == 0
            message = "Update Confluence export" if has_commits else f"Add Confluence export ({os.path.basename(export_dir)})"
            git(export_dir, "commit", "-q", "-m", message)
            print(f"Committed: \"{message}\"")
        else:
            print("Left staged, not committed. When you're ready:")
            print(f"  cd \"{export_dir}\"")
            print("  git commit -m \"Add Confluence export\"")
    else:
        print("Nothing new to commit - everything's already in the repo.")

    # Where it'll be pushed to. Never pushed from here - pushing is what
    # actually publishes this content, so that's left as your call.
    existing_remote = git(export_dir, "remote", "get-url", "origin", check=False).stdout.strip()
    if existing_remote:
        print(f"\nAlready set to push to: {existing_remote}")
    else:
        remote = input_with_help(
            "\nURL of the empty repo to push to (blank to skip for now): ",
            [
                "Create a new, EMPTY repo first (no README, no .gitignore - this",
                "folder already has both) on GitHub, Azure DevOps or wherever",
                "your team keeps things, then paste the URL it gives you here,",
                "e.g. https://github.com/your-org/confluence-export-team.git",
                "Check it's private, and somewhere this content is allowed to go.",
            ],
        ).strip()
        if remote:
            git(export_dir, "remote", "add", "origin", remote)
            existing_remote = remote

    print("\nNext step - push it:")
    print(f"  cd \"{export_dir}\"")
    if not existing_remote:
        print("  git remote add origin <URL of your new empty repo>")
    print("  git push -u origin main")


if __name__ == "__main__":
    main()

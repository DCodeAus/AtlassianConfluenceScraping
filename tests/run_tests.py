"""
Automatic tests for every script here - stdlib only, no pip install.

    python tests/run_tests.py               # Python scripts, plus PowerShell if pwsh is installed
    python tests/run_tests.py --python      # just the Python scripts
    python tests/run_tests.py --powershell  # just the PowerShell scripts
    python tests/run_tests.py --windows-powershell  # PowerShell scripts on Windows PowerShell 5.1

Starts the fake Confluence in tests/mock_confluence.py, then runs every
script against it, the same order you would for real: auth test,
extractor, both checks, Markdown conversion, SharePoint paste, table to
CSV, the repair script and the git setup. Each step is checked against
what the made-up space in tests/test_site.json should produce - 34 pages
even though the server hands them out 10 at a time, the one attachment
that fails to download recorded in failures.json, the "image" that's
really a login page caught by both checks, and so on.

Also checks the warning when Confluence treats you as an anonymous
visitor, and the message when a script is copied out without
confluence_common next to it.

Everything happens in a temporary folder that's deleted afterwards -
nothing is written into this repo, and nothing goes near a real
Confluence. Takes a minute or two. Exits with 1 if any check fails, so
it can run on GitHub for every change (see .github/workflows/tests.yml).

Run it after changing any script, in either language - the two versions
are meant to behave the same, and these checks hold both to it.
"""

import csv
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(TESTS_DIR)
EXPORT = "confluence_export_TEAM"

# How the .ps1 scripts are run: PowerShell 7 by default, or with
# --windows-powershell, the Windows PowerShell 5.1 built into Windows - the
# version most people actually run these with, and the one with the quirks.
POWERSHELL = ["pwsh", "-NoProfile"]

failures = []


def check(label, ok, detail=""):
    """One PASS/FAIL line - and remembered, so the run can fail at the end
    rather than stopping at the first problem."""
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        failures.append(label)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def read_json(path):
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def run_suite(language, work):
    print(f"\n=== {'Python' if language == 'py' else ' '.join(POWERSHELL[:1])} ===")
    os.makedirs(work)

    # The site file is copied, so the anonymous test can change it without
    # touching the original.
    site = os.path.join(work, "site.json")
    shutil.copy(os.path.join(TESTS_DIR, "test_site.json"), site)
    port = free_port()
    server = subprocess.Popen([sys.executable, os.path.join(TESTS_DIR, "mock_confluence.py"), str(port), site])
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            break
        except OSError:
            time.sleep(0.1)

    # git refuses to commit without a name and email - give it test ones,
    # without touching your own git settings.
    git_config = os.path.join(work, "gitconfig")
    with open(git_config, "w") as f:
        f.write("[user]\n\tname = Test Runner\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n")

    env = {
        **os.environ,
        "CONFLUENCE_BASE_URL": f"http://127.0.0.1:{port}",
        "CONFLUENCE_SPACE_KEY": "TEAM",
        "CONFLUENCE_USERNAME": "testuser",
        "CONFLUENCE_PASSWORD": "testpass",
        "CONFLUENCE_EXPORT_DIR": EXPORT,
        "GIT_CONFIG_GLOBAL": git_config,
        "GIT_CONFIG_NOSYSTEM": "1",
        "PYTHONIOENCODING": "utf-8",
    }

    def run(script, *args, answers="", extra_env=None):
        """Runs one script with blank answers to any question (the default)
        unless others are given, and hands back everything it printed."""
        if language == "py":
            command = [sys.executable, os.path.join(REPO_DIR, f"{script}.py"), *args]
        else:
            command = [*POWERSHELL, "-File", os.path.join(REPO_DIR, f"{script}.ps1"), *args]
        try:
            result = subprocess.run(
                command, cwd=work, env={**env, **(extra_env or {})},
                input=answers + "\n" * 40, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=300,
            )
        except subprocess.TimeoutExpired as hung:
            # A script that never finishes is a failure like any other -
            # say which one, show the last thing it printed (where it got
            # stuck), and carry on with the rest of the checks.
            printed = hung.stdout or b""
            printed = printed.decode("utf-8", "replace") if isinstance(printed, bytes) else printed
            check(f"{script} finishes (it was stopped after 5 minutes)", False, printed[-800:] or "printed nothing")
            return printed
        return result.stdout + result.stderr

    try:
        export = os.path.join(work, EXPORT)

        output = run("confluence_auth_test")
        check("auth test connects", "Success! First page title" in output, output[-300:])
        check("auth test says who it's signed in as", "Signed in to Confluence as: Jane Mentioned" in output)

        output = run("confluence_extractor")
        manifest = read_json(os.path.join(export, "manifest.json")) if os.path.isfile(os.path.join(export, "manifest.json")) else []
        check("extractor gets all 34 pages, though the server sends 10 at a time", len(manifest) == 34, f"got {len(manifest)}")
        failed = read_json(os.path.join(export, "failures.json")) if os.path.isfile(os.path.join(export, "failures.json")) else []
        check("the download that fails is recorded in failures.json", [f.get("attachmentName") for f in failed] == ["fails.mp4"], str(failed))
        source = read_json(os.path.join(export, "export_source.json")) if os.path.isfile(os.path.join(export, "export_source.json")) else {}
        check("export_source.json saves the site and space, never the login",
              source.get("spaceKey") == "TEAM" and "testpass" not in json.dumps(source) and "testuser" not in json.dumps(source), str(source))
        first = next((p for p in manifest if p["id"] == "1001"), None)
        if first:
            folder = os.path.join(export, *first["folder"].replace("\\", "/").split("/"))
            with open(os.path.join(folder, "content.html"), encoding="utf-8-sig") as f:
                content = f.read()
            check("accents and curly quotes come through intact", "Café" in content or "“" in content, content[:120])
        else:
            check("page 1001 was extracted", False)
        table_page = next((p for p in manifest if p["id"] == "1034"), None)
        rendered = ""
        if table_page:
            folder = os.path.join(export, *table_page["folder"].replace("\\", "/").split("/"))
            with open(os.path.join(folder, "rendered.html"), encoding="utf-8-sig") as f:
                rendered = f.read()
        check("rendered.html points images at the saved copies", 'src="images/pic.png"' in rendered, rendered[-200:])
        with open(os.path.join(export, "pages_index.csv"), encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f))
        check("pages_index.csv lists every page", len(rows) == 34, f"got {len(rows)}")

        run("confluence_verify_extraction", "--check-live-space" if language == "py" else "-CheckLiveSpace")
        report = read_json(os.path.join(export, "verification_report.json"))
        check("offline check: the login page saved as an image is caught",
              any("chart.png" in a.get("reason", "") for a in report["badAttachments"]))
        check("offline check: 3 images a page shows but weren't saved", len(report["missingReferencedFiles"]) == 3,
              f"got {len(report['missingReferencedFiles'])}")
        check("offline check: the live page list matches the export",
              (report.get("liveCheck") or {}).get("liveTotal") == 34 and not (report.get("liveCheck") or {}).get("missingFromExtraction"))

        run("confluence_verify_live_content")
        report = read_json(os.path.join(export, "live_content_report.json"))
        check("live check: 32 pages match exactly", report.get("matchingCount") == 32, f"got {report.get('matchingCount')}")
        check("live check: the failed download shows as not saved", len(report["missingAttachments"]) == 1)
        check("live check: the login page saved as an image is caught",
              any("chart.png" in a.get("reason", "") for a in report["attachmentFilesWrong"]))
        check("live check: no content mismatches", not report["contentDiffers"])

        markdown_env = {"CONFLUENCE_MARKDOWN_EXPORT_DIR": "md", "CONFLUENCE_PASTE_EXPORT_DIR": "paste", "CONFLUENCE_TABLE_EXPORT_DIR": "tables"}
        run("confluence_html_to_markdown", extra_env=markdown_env)
        destinations = os.path.join(export, "page_destinations.csv")
        check("first Markdown run creates page_destinations.csv", os.path.isfile(destinations))
        # Fill in the CSV the way you would in Excel: every page somewhere.
        with open(destinations, encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f))
        for i, row in enumerate(rows):
            row["destination"] = ["azure", "sharepoint", "", "discard"][i % 4]
        with open(destinations, "w", encoding="utf-8-sig", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        run("confluence_html_to_markdown", extra_env=markdown_env)
        converted = sum(len([n for n in names if n.endswith(".md")]) for _, _, names in os.walk(os.path.join(work, "md")))
        check("Markdown conversion writes one file per page", converted == 34, f"got {converted}")
        check("pages go to the folder chosen in the CSV",
              all(os.path.isdir(os.path.join(work, "md", d)) for d in ("azure", "sharepoint", "discard", "unsorted")))

        run("confluence_sharepoint_paste", extra_env=markdown_env)
        pasted = len(os.listdir(os.path.join(work, "paste", "pages"))) if os.path.isdir(os.path.join(work, "paste", "pages")) else 0
        check("SharePoint paste makes a page for each 'sharepoint' row", pasted == sum(r["destination"] == "sharepoint" for r in rows), f"got {pasted}")

        run("confluence_table_to_csv", "Table page", extra_env=markdown_env)
        table = os.path.join(work, "tables", "Table page.csv")
        rows = []
        if os.path.isfile(table):
            with open(table, encoding="utf-8-sig", newline="") as f:
                rows = list(csv.reader(f))
        check("table to CSV pulls the table out", rows == [["Name", "Role"], ["Alice & Bob", "Owner"]], str(rows))

        # Azure DevOps Wiki layout, on a copy so the destinations can be
        # set for it without changing what the checks below see. The space
        # home page (1001, with every awkward character in its title) comes
        # to the wiki, so everything nests under it; 1011 goes to SharePoint,
        # so its child 1012 should move up under 1007.
        wiki_export = os.path.join(work, "wikicopy")
        shutil.copytree(export, wiki_export)
        wiki_pages = {"1001", "1002", "1005", "1006", "1007", "1008", "1009", "1010", "1012", "1013", "1034"}
        destinations = os.path.join(wiki_export, "page_destinations.csv")
        with open(destinations, encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f))
        for row in rows:
            row["destination"] = "azure" if row["id"] in wiki_pages else "sharepoint" if row["id"] == "1011" else "discard"
        with open(destinations, "w", encoding="utf-8-sig", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        wiki_env = {"CONFLUENCE_EXPORT_DIR": "wikicopy", "CONFLUENCE_MARKDOWN_EXPORT_DIR": "mdwiki",
                    "CONFLUENCE_WIKI_EXPORT_DIR": "wiki", "CONFLUENCE_WIKI_REPO_URL": ""}
        run("confluence_html_to_markdown", extra_env=wiki_env)
        output = run("confluence_to_azure_wiki", extra_env=wiki_env)
        wiki = os.path.join(work, "wiki")
        home = "Café-“Notes”-–-Q3%2DQ4%3A-plan%3F"

        def wiki_file(*parts):
            path = os.path.join(wiki, *parts)
            if not os.path.isfile(path):
                return None
            with open(path, encoding="utf-8") as f:
                return f.read()

        built = [os.path.relpath(os.path.join(root, name), wiki).replace(os.sep, "/")
                 for root, _, names in os.walk(wiki) for name in names if name.endswith(".md")]
        check("wiki: one file per page, named after the page", len(built) == len(wiki_pages) and not any(p.endswith("content.md") for p in built), str(sorted(built)))
        check("wiki: hyphens, colons, slashes and ? in a title encoded the wiki's way", wiki_file(home + ".md") is not None, str(sorted(built)))
        check("wiki: a real hyphen in a title is kept apart from the spaces", wiki_file(home, "Deploy-%2D-step-1.md") is not None)
        check("wiki: sub-pages sit in a folder named after their parent", wiki_file(home, "Page-7", "Page-8", "Page-9.md") is not None)
        check("wiki: a page whose parent went to SharePoint moves up to the next one",
              wiki_file(home, "Page-7", "Page-12.md") is not None)
        check("wiki: top-level .order lists the top page", wiki_file(".order") == home + "\n", repr(wiki_file(".order")))
        check("wiki: each folder's .order keeps the Confluence order",
              wiki_file(home, "Page-7", ".order") == "Page-8\nPage-10\nPage-12\n", repr(wiki_file(home, "Page-7", ".order")))
        page7 = wiki_file(home, "Page-7.md") or ""
        check("wiki: the converter's '# title' line isn't repeated", not page7.startswith("# Page 7"), page7[:60])
        links = wiki_file(home, "Macros-and-links.md") or ""
        check("wiki: a link to a page in the wiki becomes a wiki link", f"[Page 7](</{home}/Page-7>)" in links, links[:400])
        check("wiki: a link into another space isn't linked to a page here",
              "[Shared & Common](" not in links and "Shared & Common" in links, links[:400])
        report_rows = []
        if os.path.isfile(os.path.join(wiki_export, "wiki_link_report.csv")):
            with open(os.path.join(wiki_export, "wiki_link_report.csv"), encoding="utf-8-sig", newline="") as f:
                report_rows = list(csv.DictReader(f))
        reasons = {row["links_to"]: row["reason"] for row in report_rows}
        check("wiki: links that can't be wiki links are listed with why",
              "another space" in reasons.get("Shared & Common", "") and "not in this export" in reasons.get("Deleted long ago", ""), str(reasons))
        attachments = sorted(os.listdir(os.path.join(wiki, ".attachments"))) if os.path.isdir(os.path.join(wiki, ".attachments")) else []
        attached = wiki_file(home, "Two-attachments.md") or ""
        check("wiki: attachments copied to .attachments with the page id in front",
              "1002-a.pdf" in attachments and "](</.attachments/1002-a.pdf>)" in attached, f"{attachments} / {attached[:200]}")
        borrowed = wiki_file(home, "Borrows-images.md") or ""
        check("wiki: an image borrowed from another page comes from that page's attachments",
              "](</.attachments/1001-diagram.png>)" in borrowed and "1001-diagram.png" in attachments, borrowed[:300])
        check("wiki: images that were never saved are reported, not lost",
              "Borrows images: ghost.png" in output and "](<images/ghost.png>)" in borrowed, output[-600:])
        check("wiki: the build never includes a git repo", not os.path.isdir(os.path.join(wiki, ".git")))

        output = run("confluence_to_azure_wiki", extra_env=wiki_env)
        check("wiki: running it again rebuilds the folder", "Cleared the previous build" in output and wiki_file(home + ".md") is not None, output[-300:])
        clone = os.path.join(work, "wikiclone")
        os.makedirs(os.path.join(clone, ".git"))
        with open(os.path.join(clone, "Existing-page.md"), "w") as f:
            f.write("keep me")
        output = run("confluence_to_azure_wiki", extra_env={**wiki_env, "CONFLUENCE_WIKI_EXPORT_DIR": "wikiclone"})
        check("wiki: refuses to build straight into a git repo (the wiki clone)",
              os.path.isfile(os.path.join(clone, "Existing-page.md")) and "is a git repo" in output, output[-300:])

        shutil.copytree(export, os.path.join(work, "repaircopy"))
        output = run("repair_garbled_text", "repaircopy")
        check("repair script finds nothing to fix in a clean export", "Fixed 0 of" in output, output[-200:])

        shutil.copytree(export, os.path.join(work, "gitcopy"))
        run("confluence_export_to_git", answers="y\n\n", extra_env={"CONFLUENCE_EXPORT_DIR": "gitcopy"})
        commits = subprocess.run(["git", "-C", os.path.join(work, "gitcopy"), "log", "--oneline"], capture_output=True, text=True, env=env).stdout
        check("export_to_git makes a repo with one commit", len(commits.splitlines()) == 1, commits or "no commits")
        pushed = subprocess.run(["git", "-C", os.path.join(work, "gitcopy"), "remote"], capture_output=True, text=True, env=env).stdout.strip()
        check("export_to_git never adds a remote unless asked", pushed == "", pushed)

        # Pretend Confluence didn't recognise the login.
        data = read_json(site)
        data["anonymous"] = True
        with open(site, "w", encoding="utf-8") as f:
            json.dump(data, f)
        output = run("confluence_extractor", extra_env={"CONFLUENCE_PAGE_ID": "1001", "CONFLUENCE_EXPORT_DIR": "anon"})
        check("anonymous login is warned about", "Confluence doesn't know who you are" in output, output[:300])
        check("...and, with nobody at the keyboard, carries on", "Carrying on anyway" in output and os.path.isdir(os.path.join(work, "anon")))

        # A script copied out on its own, without confluence_common next to it.
        alone = os.path.join(work, "alone")
        os.makedirs(alone)
        extension = "py" if language == "py" else "ps1"
        shutil.copy(os.path.join(REPO_DIR, f"confluence_extractor.{extension}"), alone)
        command = [sys.executable, "-I", "confluence_extractor.py"] if language == "py" else [*POWERSHELL, "-File", "confluence_extractor.ps1"]
        result = subprocess.run(command, cwd=alone, env=env, input="", capture_output=True, text=True, timeout=60)
        check("a script on its own says confluence_common is missing",
              result.returncode == 1 and "confluence_common" in result.stdout, (result.stdout + result.stderr)[:200])
    finally:
        server.terminate()
        server.wait()


def main():
    global POWERSHELL
    args = sys.argv[1:]
    if "--windows-powershell" in args:
        if not shutil.which("powershell"):
            print("Windows PowerShell (powershell.exe) isn't here - this option is for Windows.")
            sys.exit(1)
        POWERSHELL = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass"]
        args = args + ["--powershell"]
    languages = []
    if "--powershell" not in args:
        languages.append("py")
    if "--python" not in args:
        if shutil.which(POWERSHELL[0]):
            languages.append("ps")
        elif "--powershell" in args:
            print("PowerShell 7 (pwsh) isn't installed, so the PowerShell scripts can't be tested here.")
            sys.exit(1)
        else:
            print("PowerShell 7 (pwsh) isn't installed - testing the Python scripts only.")

    work = tempfile.mkdtemp(prefix="confluence-tests-")
    try:
        for language in languages:
            run_suite(language, os.path.join(work, language))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failures:
        print(f"{len(failures)} check(s) failed:")
        for label in failures:
            print(f"  - {label}")
        sys.exit(1)
    print("All checks passed.")


if __name__ == "__main__":
    main()

# Changing the scripts

Every script comes in a Python and a PowerShell version that do the same thing - change one, change the other to match. Anything more than one script needs (asking a question, logging in, reading an export folder) lives in `confluence_common.py`/`.ps1` rather than being copied into each script, so look there first. After editing any `.ps1` file, run `.\check_script_encoding.ps1` before committing (see [When something goes wrong](troubleshooting.md) for why).

Then run the tests - no Confluence needed:

```
python tests/run_tests.py
```

It starts a fake Confluence on your machine and runs every script against it, start to finish, in Python and (if PowerShell 7 is installed) PowerShell: auth test, extractor, both checks, Markdown, Azure DevOps Wiki layout, SharePoint paste, table to CSV, repair and git setup. `--windows-powershell` runs the PowerShell checks on Windows PowerShell 5.1 instead, which GitHub also does on every change. The fake one is deliberately awkward in the ways real servers were - it hands out results 10 at a time whatever you ask for, leaves the character set off its replies, has a download that fails, an "image" that's really a login page, and attachments with missing or wrong sizes - and every check says what it expected if it fails. Everything happens in a temporary folder and nothing is written into the repo. It takes a minute or two. The same tests run on GitHub for every push and pull request (the badge at the top shows the latest result).

Found a new way a real Confluence misbehaves? Add it to `tests/test_site.json` (and `tests/mock_confluence.py` if it needs new behaviour) with a check in `run_tests.py`, so it stays fixed.

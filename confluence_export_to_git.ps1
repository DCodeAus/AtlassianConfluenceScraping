<#
Export-to-git setup - PowerShell version.
Needs git itself installed (https://git-scm.com - "Git for Windows").

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

    .\confluence_export_to_git.ps1
    .\confluence_export_to_git.ps1 -ExportDir "S:\Exports\confluence_export_TEAM"

Set CONFLUENCE_EXPORT_DIR to skip the folder question.

Something broken or unclear? Raise an issue at
https://github.com/DCodeAus/AtlassianConfluenceScraping/issues
#>

param(
    # The export folder to turn into a repo. Asked for if not given.
    [string]$ExportDir
)

# Everything the scripts here have in common - the questions, talking to
# Confluence, reading an export folder - lives in confluence_common.ps1,
# so a fix there fixes every script at once. It has to be in the same
# folder as this one.
$commonScript = Join-Path $PSScriptRoot "confluence_common.ps1"
if (-not (Test-Path -LiteralPath $commonScript)) {
    Write-Host "Can't find confluence_common.ps1 - it needs to be in the same folder"
    Write-Host "as this script. Download the whole repository rather than just this"
    Write-Host "one file."
    exit 1
}
. $commonScript

# Above this, GitHub warns on push; at 100 MB it refuses the push outright
# (Azure DevOps is similar). Flagged up front, since finding out at push
# time means rewriting the commit to get rid of it.
$LargeFileWarningBytes = 50MB

# Leftovers from the other scripts that land inside an export folder but
# aren't part of the content itself. Only written if the folder doesn't
# already have a .gitignore - yours is never overwritten.
$ExportGitignore = @"
# Written by confluence_export_to_git - leftovers from the checking/repair
# scripts that aren't part of the export itself.
verification_report.json
live_content_report.json
*.bak
garbled_text_repair_log.json

# OS clutter
.DS_Store
Thumbs.db
desktop.ini
"@

function Invoke-Git {
    # Runs one git command inside the export folder and hands back its
    # output - so every call below reads like the command you'd type.
    # -AllowFailure is for the questions ("is this set?") where git saying
    # no is a normal answer, not something to stop over.
    param([string[]]$GitArgs, [switch]$AllowFailure)
    $output = & git -C $ExportDir @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        Write-Host "git $($GitArgs -join ' ') failed:"
        Write-Host ($output | Out-String).Trim()
        exit 1
    }
    return $output
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Can't find git on this machine. Install it from https://git-scm.com"
    Write-Host "(""Git for Windows"" - the default options are fine), then open a"
    Write-Host "NEW PowerShell window and run this again."
    exit 1
}

$exportDirHelp = @(
    "Which folder to turn into a git repo - the folder name you gave the",
    "extractor (or the Markdown converter) for that space, or its full",
    "path if it's somewhere else (e.g. a shared drive).",
    "Leave blank for: confluence_export"
)
$ExportDir = Read-ExportDir -Value $ExportDir -Prompt "Export folder to put into git (blank for 'confluence_export')" -HelpText $exportDirHelp

if (-not (Test-Path -LiteralPath $ExportDir -PathType Container)) {
    Write-Host "Can't find '$ExportDir' from here - run this from the folder"
    Write-Host "that contains it, or give its full path instead."
    exit 1
}
$ExportDir = (Resolve-Path -LiteralPath $ExportDir).Path

if (-not (Test-Path -LiteralPath (Join-Path $ExportDir "manifest.json")) -and -not (Test-Path -LiteralPath (Join-Path $ExportDir "README.md"))) {
    Write-Host "'$ExportDir' doesn't look like an export - no manifest.json or"
    Write-Host "README.md in it."
    if (-not (Read-YesNo "Carry on anyway?")) { exit 1 }
}

# The export usually sits inside this scripts folder, which is itself a git
# repo. That's fine as long as the scripts repo ignores it (its .gitignore
# covers every confluence_export*/ folder) - otherwise the scripts repo
# would try to swallow the export's repo as well.
$alreadyARepo = Test-Path -LiteralPath (Join-Path $ExportDir ".git")
if (-not $alreadyARepo) {
    $outer = Invoke-Git @("rev-parse", "--show-toplevel") -AllowFailure
    if ($LASTEXITCODE -eq 0) {
        $outerRepo = "$outer".Trim()
        & git -C $outerRepo check-ignore -q $ExportDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host "'$ExportDir' is inside another git repo ($outerRepo)"
            Write-Host "that ISN'T ignoring it - its contents could end up committed there"
            Write-Host "too. Safest is to move the export folder somewhere outside it first."
            if (-not (Read-YesNo "Carry on anyway?")) { exit 1 }
        }
    }
}

if ($alreadyARepo) {
    Write-Host "'$ExportDir' is already a git repo - reusing it."
}
else {
    Invoke-Git @("init") | Out-Null
    # Name the first branch "main" whatever this git version defaults to -
    # older ones still say "master", which then doesn't match what
    # GitHub/Azure DevOps expect when you push.
    Invoke-Git @("symbolic-ref", "HEAD", "refs/heads/main") | Out-Null
    Write-Host "Created a new git repo in '$ExportDir'."
}

# Page folders + images\ + a long attachment name can pass Windows' old
# 260-character path limit, which git for Windows refuses by default
# ("Filename too long"). Only affects this repo.
Invoke-Git @("config", "core.longpaths", "true") | Out-Null

$gitignorePath = Join-Path $ExportDir ".gitignore"
if (Test-Path -LiteralPath $gitignorePath) {
    Write-Host "Keeping the .gitignore that's already there."
}
else {
    # Written without a BOM, same as every other file these scripts write.
    [System.IO.File]::WriteAllText($gitignorePath, $ExportGitignore, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Added a .gitignore for verification reports and repair backups."
}

# git refuses to commit without a name and email to put on it. Only asked
# if it isn't set up already, and only saved for this repo - your
# settings everywhere else stay as they are.
$identityQuestions = @(
    @{ Key = "user.name"; Prompt = "Your name, as it should appear on commits"; Help = "e.g. Jane Smith - shown as the author of the commit." },
    @{ Key = "user.email"; Prompt = "Your email, as it should appear on commits"; Help = "Usually your work email, or the one on your GitHub/Azure DevOps account." }
)
foreach ($question in $identityQuestions) {
    # "$(...)" rather than [string]: git printing nothing at all hands back
    # PowerShell's special "nothing" value, which [string] leaves as null
    # (and .Trim() then fails on) - "$(...)" always gives a real string.
    $current = "$(Invoke-Git @("config", $question.Key) -AllowFailure)"
    if (-not $current.Trim()) {
        $value = (Read-HostWithHelp $question.Prompt @($question.Help)).Trim()
        if ($value) {
            Invoke-Git @("config", $question.Key, $value) | Out-Null
        }
    }
}

# Big-file check before staging - see $LargeFileWarningBytes above.
# -Force so hidden files are counted too, since git will pick those up.
# The trailing separator matters: without it, .gitignore itself would
# also count as "inside .git" and be left out.
$gitFolder = (Join-Path $ExportDir ".git") + [System.IO.Path]::DirectorySeparatorChar
$allFiles = @(Get-ChildItem -LiteralPath $ExportDir -Recurse -File -Force | Where-Object { -not $_.FullName.StartsWith($gitFolder) })
$totalBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
if (-not $totalBytes) { $totalBytes = 0 }
$largeFiles = @($allFiles | Where-Object { $_.Length -gt $LargeFileWarningBytes } | Sort-Object Length -Descending)

if ($largeFiles.Count -gt 0) {
    Write-Host "`n$($largeFiles.Count) file(s) over $(Format-Size $LargeFileWarningBytes) - GitHub warns above"
    Write-Host "50 MB and refuses anything over 100 MB, Azure DevOps is similar:"
    foreach ($file in $largeFiles) {
        Write-Host ("  {0,10}  {1}" -f (Format-Size $file.Length), $file.FullName.Substring($ExportDir.Length).TrimStart('\', '/'))
    }
    Write-Host "Options: add them to .gitignore and share them another way, or set up"
    Write-Host "Git LFS (https://git-lfs.com) for them before committing."
    if (-not (Read-YesNo "Stage everything anyway?")) {
        Write-Host "Stopped before staging. The repo's set up - fix the above, then run"
        Write-Host "this again (it'll pick up where it left off)."
        exit 0
    }
}

Write-Host "`nStaging files (can take a minute for a big space)..."
Invoke-Git @("add", "-A") | Out-Null
# @()-wrapped so exactly one staged file still counts as 1, not as the
# length of its name.
$staged = @(Invoke-Git @("diff", "--cached", "--name-only") | Where-Object { $_ })
Write-Host "$($staged.Count) file(s) staged, $(Format-Size $totalBytes) in total."

if ($staged.Count -gt 0) {
    if (Read-YesNo "`nMake the commit now?") {
        Invoke-Git @("rev-parse", "--verify", "HEAD") -AllowFailure | Out-Null
        $message = if ($LASTEXITCODE -eq 0) { "Update Confluence export" } else { "Add Confluence export ($(Split-Path $ExportDir -Leaf))" }
        Invoke-Git @("commit", "-q", "-m", $message) | Out-Null
        Write-Host "Committed: ""$message"""
    }
    else {
        Write-Host "Left staged, not committed. When you're ready:"
        Write-Host "  cd ""$ExportDir"""
        Write-Host "  git commit -m ""Add Confluence export"""
    }
}
else {
    Write-Host "Nothing new to commit - everything's already in the repo."
}

# Where it'll be pushed to. Never pushed from here - pushing is what
# actually publishes this content, so that's left as your call.
$existingRemote = "$(Invoke-Git @("remote", "get-url", "origin") -AllowFailure)".Trim()
if ($LASTEXITCODE -eq 0 -and $existingRemote) {
    Write-Host "`nAlready set to push to: $existingRemote"
}
else {
    $existingRemote = ""
    $remoteHelp = @(
        "Create a new, EMPTY repo first (no README, no .gitignore - this",
        "folder already has both) on GitHub, Azure DevOps or wherever your",
        "team keeps things, then paste the URL it gives you here, e.g.",
        "https://github.com/your-org/confluence-export-team.git",
        "Check it's private, and somewhere this content is allowed to go."
    )
    $remote = (Read-HostWithHelp "`nURL of the empty repo to push to (blank to skip for now)" $remoteHelp).Trim()
    if ($remote) {
        Invoke-Git @("remote", "add", "origin", $remote) | Out-Null
        $existingRemote = $remote
    }
}

Write-Host "`nNext step - push it:"
Write-Host "  cd ""$ExportDir"""
if (-not $existingRemote) {
    Write-Host "  git remote add origin <URL of your new empty repo>"
}
Write-Host "  git push -u origin main"

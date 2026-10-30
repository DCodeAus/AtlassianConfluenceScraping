<#
Confluence extraction verifier - PowerShell version.
No install required.

Checks what confluence_extractor.ps1 actually saved to disk against its own
manifest.json: every page's folder and content.html actually exist and
aren't empty, every attachment it recorded actually got downloaded, and
nothing's listed in failures.json. This is a coverage check, not a content
check - it tells you if something's missing or empty, not whether a table
rendered nicely or an image is the right one. Spot-check those by eye.

Asks which export folder to check - a folder name next to this script, or
a full path anywhere (e.g. a shared drive holding several spaces' exports).
Or pass -ExportDir, or set CONFLUENCE_EXPORT_DIR, to skip the question:
    .\confluence_verify_extraction.ps1
    .\confluence_verify_extraction.ps1 -ExportDir "S:\Exports\confluence_export_TEAM"

While Confluence is still reachable - especially useful if it's about to be
decommissioned, since this is your last chance to check - add
-CheckLiveSpace to also compare the manifest against Confluence's own live
page list for that space, catching anything that never made it into the
manifest at all (which the checks above can't see, since they only look at
what the manifest itself claims):
    .\confluence_verify_extraction.ps1 -CheckLiveSpace

Supported by Daniel - raise issues with him.
#>

param(
    # Where confluence_extractor.ps1 saved its output - same folder you'd
    # point confluence_html_to_markdown.ps1 at. Asked for if not given.
    [string]$ExportDir,
    # Also fetch the live page list for the space from Confluence itself and
    # compare it against the manifest, catching pages the extractor never
    # recorded at all (a crash before it even started, a page added since,
    # etc). Needs Confluence to still be reachable and asks for the same
    # site address/space key/login as the extractor did.
    [switch]$CheckLiveSpace,
    # Same idea as confluence_extractor.ps1 - only relevant together with
    # -CheckLiveSpace. Pass this if your organisation logs you in
    # automatically via your Windows login rather than a separate
    # Confluence username and password.
    [switch]$UseDefaultCredentials
)

# On Windows PowerShell 5.1, "cd"/Set-Location only moves PowerShell's OWN
# idea of where you are - it does NOT tell .NET's file-writing functions
# (which this script uses directly, for reasons explained where they're
# used), which silently keep using wherever this PowerShell window first
# opened. Real, confirmed failure mode in a sibling script: folders/files
# visibly show up in the right place (PowerShell cmdlets follow you), but
# a .NET read or write then fails with "Could not find a part of the
# path", because .NET is still looking somewhere else entirely. This line
# keeps the two in sync, right from the start, regardless of how this
# window was opened or what you "cd"'d through to get here.
[System.Environment]::CurrentDirectory = (Get-Location).Path

# Same proxy fix as the extractor - harmless if there's no proxy in the
# way, only matters at all if -CheckLiveSpace is actually hitting the
# network.
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
[System.Net.WebRequest]::DefaultWebProxy = $proxy

function Read-HostWithHelp {
    param([string]$Prompt, [string[]]$HelpText)
    while ($true) {
        $answer = Read-Host $Prompt
        if ($answer -ne "?") {
            return $answer
        }
        foreach ($line in $HelpText) {
            Write-Host $line
        }
    }
}

function Set-Utf8NoBomContent {
    param([string]$Path, [string]$Value)
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

# A manifest "folder" value looks like "pages\123_Title", written on the
# assumption it'll be read back on Windows. Swap in whatever this machine
# actually uses before joining it onto a path, so this script also works
# correctly if it's ever run from Mac/Linux against a copied export.
function Get-NormalisedRelativePath {
    param([string]$RelativePath)
    return $RelativePath.Replace('\', [System.IO.Path]::DirectorySeparatorChar).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

# confluence_extractor.ps1 saves where an export came from into the export
# folder (export_source.json), so this doesn't have to ask for the site
# address and space key again. Exports made before that file existed still
# have the same details on the "- Source:" line of their README.md, so
# fall back to reading that.
function Get-ExportSource {
    param([string]$Dir)
    $sourcePath = Join-Path $Dir "export_source.json"
    if (Test-Path -LiteralPath $sourcePath) {
        try {
            $source = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $sourcePath).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            return @{ baseUrl = [string]$source.baseUrl; spaceKey = [string]$source.spaceKey }
        }
        catch {
            # Unreadable file - fall through to the README below instead.
        }
    }
    $readmePath = Join-Path $Dir "README.md"
    if (Test-Path -LiteralPath $readmePath) {
        foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $readmePath).Path, [System.Text.Encoding]::UTF8)) {
            if ($line.Trim() -match "^- Source: (\S+) \((?:space '([^']*)'|page id .*)\)") {
                return @{ baseUrl = $Matches[1]; spaceKey = [string]$Matches[2] }
            }
        }
    }
    return @{ baseUrl = ""; spaceKey = "" }
}

function Get-EnvSavedOrAsk {
    # An environment variable wins (for unattended runs), then whatever was
    # saved with the export - shown, so you can see what's being used - and
    # only if neither has it, the usual question.
    param([string]$EnvValue, [string]$SavedValue, [string]$Label, [string[]]$HelpText)
    if ($EnvValue) {
        return $EnvValue
    }
    if ($SavedValue) {
        Write-Host "${Label}: $SavedValue (saved with this export)"
        return $SavedValue
    }
    return (Read-HostWithHelp $Label $HelpText).Trim()
}

# Asked every run unless -ExportDir is given, so checking each space's
# export (saved under its own folder name by confluence_extractor.ps1, maybe
# somewhere else entirely like a shared drive) just means answering this
# differently. Set CONFLUENCE_EXPORT_DIR for unattended runs.
if (-not $ExportDir) {
    $exportDirHelp = @(
        "Which extraction to check - the folder name you gave (or accepted",
        "the default for) when running confluence_extractor.ps1 for that",
        "space, or its full path if it's somewhere else (e.g. a shared drive).",
        "Leave blank for: confluence_export"
    )
    $ExportDir = if ($env:CONFLUENCE_EXPORT_DIR) { $env:CONFLUENCE_EXPORT_DIR } else { (Read-HostWithHelp "Export folder to check (blank for 'confluence_export')" $exportDirHelp).Trim() }
    # Explorer's "Copy as path" and dragging a folder into the window both
    # wrap the path in quotes - strip them so either works.
    $ExportDir = $ExportDir.Trim('"').Trim("'")
    if (-not $ExportDir) { $ExportDir = "confluence_export" }
}

if (-not (Test-Path -LiteralPath $ExportDir)) {
    Write-Host "Can't find '$ExportDir' from here - run this from the folder"
    Write-Host "that contains it, or give its full path instead."
    exit 1
}

$manifestPath = Join-Path $ExportDir "manifest.json"
if (-not (Test-Path $manifestPath)) {
    Write-Host "No manifest.json in '$ExportDir' - that's written by"
    Write-Host "confluence_extractor.ps1 once it finishes, so either the"
    Write-Host "extraction hasn't been run yet, or this is pointed at the"
    Write-Host "wrong folder."
    exit 1
}

Write-Host "Reading $manifestPath ..."
# @()-wrapped for the same reason every other script here does this: a
# manifest with exactly one page would otherwise come back as a bare
# object instead of a one-item array, and break the loop below.
$manifest = @((Get-Content -Raw $manifestPath | ConvertFrom-Json))
Write-Host "$($manifest.Count) page(s) recorded in the manifest.`n"

$failuresPath = Join-Path $ExportDir "failures.json"
$recordedFailures = @()
if (Test-Path $failuresPath) {
    $recordedFailures = @((Get-Content -Raw $failuresPath | ConvertFrom-Json))
}

$missingFolders = @()
$missingOrEmptyContent = @()
$missingAttachments = @()
$seenIds = [System.Collections.Generic.HashSet[string]]::new()
$duplicateIds = @()

$index = 0
foreach ($page in $manifest) {
    $index++
    if ($index % 500 -eq 0) {
        Write-Host "  checked $index/$($manifest.Count) so far..."
    }

    $pageIdStr = [string]$page.id
    if (-not $seenIds.Add($pageIdStr)) {
        $duplicateIds += [PSCustomObject]@{ id = $page.id; title = $page.title }
    }

    $pageFolder = Join-Path $ExportDir (Get-NormalisedRelativePath $page.folder)

    if (-not (Test-Path $pageFolder)) {
        $missingFolders += [PSCustomObject]@{ id = $page.id; title = $page.title; folder = $pageFolder }
        continue
    }

    $htmlPath = Join-Path $pageFolder $page.html_file
    if (-not (Test-Path $htmlPath)) {
        $missingOrEmptyContent += [PSCustomObject]@{ id = $page.id; title = $page.title; path = $htmlPath; reason = "missing" }
    }
    else {
        $size = (Get-Item $htmlPath).Length
        if ($size -eq 0) {
            $missingOrEmptyContent += [PSCustomObject]@{ id = $page.id; title = $page.title; path = $htmlPath; reason = "empty (0 bytes)" }
        }
    }

    foreach ($attachment in @($page.attachments)) {
        $attPath = Join-Path (Join-Path $pageFolder "images") $attachment.saved_as
        if (-not (Test-Path $attPath)) {
            $missingAttachments += [PSCustomObject]@{
                id              = $page.id
                title           = $page.title
                attachmentName  = $attachment.filename
                expectedPath    = $attPath
            }
        }
    }
}

function Write-IssueSummary {
    param([string]$Label, [array]$Items, [int]$ShowMax = 15)
    if ($Items.Count -eq 0) {
        Write-Host "  $Label : none"
        return
    }
    Write-Host "  $Label : $($Items.Count)"
    foreach ($item in ($Items | Select-Object -First $ShowMax)) {
        $detail = if ($item.reason) { " - $($item.reason)" } elseif ($item.attachmentName) { " - attachment '$($item.attachmentName)'" } else { "" }
        Write-Host "    - [$($item.id)] $($item.title)$detail"
    }
    if ($Items.Count -gt $ShowMax) {
        Write-Host "    ... and $($Items.Count - $ShowMax) more (full list in verification_report.json)"
    }
}

Write-Host "`n--- Manifest checks ---"
Write-IssueSummary "Pages recorded as failed during extraction (failures.json)" $recordedFailures
Write-IssueSummary "Duplicate page IDs in manifest" $duplicateIds
Write-IssueSummary "Page folders missing on disk" $missingFolders
Write-IssueSummary "content.html missing or empty" $missingOrEmptyContent
Write-IssueSummary "Attachments recorded but missing on disk" $missingAttachments

$liveCheck = $null

if ($CheckLiveSpace) {
    Write-Host "`n--- Live space check ---"

    $baseUrlHelp = @(
        "The address of your Confluence site - everything in a page's URL",
        "before /display/ or /spaces/, with no slash on the end."
    )
    $saved = Get-ExportSource -Dir $ExportDir
    $BaseUrl = (Get-EnvSavedOrAsk $env:CONFLUENCE_BASE_URL $saved.baseUrl "Confluence base URL" $baseUrlHelp).TrimEnd('/')

    $spaceKeyHelp = @(
        "The short code identifying which space to check, found in a page's",
        "URL right after /display/ or /spaces/."
    )
    $SpaceKey = Get-EnvSavedOrAsk $env:CONFLUENCE_SPACE_KEY $saved.spaceKey "Confluence space key" $spaceKeyHelp

    if ($UseDefaultCredentials) {
        Write-Host "Using your current Windows login instead of a separate username/password."
        $headers = @{ Accept = "application/json" }
    }
    else {
        $Username = if ($env:CONFLUENCE_USERNAME) { $env:CONFLUENCE_USERNAME } else { Read-HostWithHelp "Confluence username" @() }
        if ($env:CONFLUENCE_PASSWORD) {
            $Password = $env:CONFLUENCE_PASSWORD
        }
        else {
            $SecurePassword = Read-Host "Confluence password" -AsSecureString
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
            $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        }
        $pair = "$($Username):$($Password)"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
        $headers = @{
            Authorization = "Basic $([System.Convert]::ToBase64String($bytes))"
            Accept        = "application/json"
        }
    }

    function Invoke-ConfluenceApi {
        param([string]$Uri)
        if ($UseDefaultCredentials) {
            return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -UseBasicParsing -UseDefaultCredentials
        }
        return Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get -UseBasicParsing
    }

    # No expand= here on purpose - this is only comparing IDs/titles, not
    # re-fetching every page's full content, so there's no need to ask
    # Confluence for anything heavier than it takes to list what exists.
    $livePages = @()
    $start = 0
    $pageSize = 100
    try {
        while ($true) {
            Write-Host "  fetching live page list: start=$start"
            $uri = "$BaseUrl/rest/api/content?spaceKey=$SpaceKey&type=page&start=$start&limit=$pageSize"
            $data = Invoke-ConfluenceApi -Uri $uri
            $results = @($data.results)
            $livePages += $results
            if ($results.Count -lt $pageSize) {
                break
            }
            $start += $pageSize
        }

        $liveIds = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in $livePages) { [void]$liveIds.Add([string]$p.id) }
        $manifestIds = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in $manifest) { [void]$manifestIds.Add([string]$p.id) }

        $missingFromExtraction = @($livePages | Where-Object { -not $manifestIds.Contains([string]$_.id) } | ForEach-Object { [PSCustomObject]@{ id = $_.id; title = $_.title } })
        $noLongerLive = @($manifest | Where-Object { -not $liveIds.Contains([string]$_.id) } | ForEach-Object { [PSCustomObject]@{ id = $_.id; title = $_.title } })

        Write-Host "  $($livePages.Count) page(s) live in Confluence right now, $($manifest.Count) in the manifest."
        Write-IssueSummary "Live pages never recorded in the manifest (extraction missed these)" $missingFromExtraction
        Write-IssueSummary "Manifest pages no longer live (likely deleted/moved since extraction - not necessarily a problem)" $noLongerLive

        $liveCheck = [PSCustomObject]@{
            liveTotal              = $livePages.Count
            manifestTotal          = $manifest.Count
            missingFromExtraction  = $missingFromExtraction
            noLongerLive           = $noLongerLive
        }
    }
    catch {
        Write-Host "  Couldn't complete the live check: $($_.Exception.Message)"
        Write-Host "  Everything above this (the manifest-vs-disk checks) is still valid -"
        Write-Host "  this only affects the comparison against Confluence itself."
    }
}

$hasIssues = $recordedFailures.Count -gt 0 -or $duplicateIds.Count -gt 0 -or $missingFolders.Count -gt 0 -or $missingOrEmptyContent.Count -gt 0 -or $missingAttachments.Count -gt 0
if ($liveCheck -and $liveCheck.missingFromExtraction.Count -gt 0) {
    $hasIssues = $true
}

Write-Host ""
if ($hasIssues) {
    Write-Host "Found issues - see above (and the saved report) for details."
}
else {
    Write-Host "No issues found."
}

$report = [PSCustomObject]@{
    manifestPath          = $manifestPath
    totalPagesInManifest   = $manifest.Count
    recordedFailures       = $recordedFailures
    duplicateIds           = $duplicateIds
    missingFolders         = $missingFolders
    missingOrEmptyContent  = $missingOrEmptyContent
    missingAttachments     = $missingAttachments
    liveCheck              = $liveCheck
}

$reportPath = Join-Path $ExportDir "verification_report.json"
try {
    Set-Utf8NoBomContent -Path $reportPath -Value (ConvertTo-Json -InputObject $report -Depth 10)
    Write-Host "Full report saved to $reportPath"
}
catch {
    Write-Host "Couldn't save the full report to $reportPath - $($_.Exception.Message)"
    Write-Host "The summary printed above is still accurate, this just means there's no saved copy."
}

exit [int]$hasIssues

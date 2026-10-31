<#
Confluence extraction verifier - PowerShell version.
No install required.

Checks what confluence_extractor.ps1 actually saved to disk, without
needing Confluence at all:

  - every page's folder, content.html and rendered.html exist and aren't
    empty
  - every attachment it recorded is on disk, isn't empty, and isn't a web
    page saved in place of the real file (what you get when a proxy or
    login page answers instead of Confluence)
  - nothing's listed in failures.json (failed pages AND failed
    attachment downloads)
  - every image/file each page shows or links to was actually saved -
    including ones that really live on a DIFFERENT page, which don't come
    down with this one
  - and, for information: links to pages that aren't in this export,
    macros that pull their content from somewhere else (Jira, include
    page, page trees...) so it won't come with the export, and page
    folders on disk the manifest doesn't know about

Results are split into "must fix before Confluence is switched off" and
"for your information". It tells you if something's missing, empty or
broken - not whether a table rendered nicely, so still spot-check a few
pages by eye. confluence_verify_live_content.ps1 goes further, comparing
every page against Confluence itself.

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

Something broken or unclear? Raise an issue at
https://github.com/DCodeAus/AtlassianConfluenceScraping/issues
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

$ReportName = "verification_report.json"

# Asked every run unless -ExportDir is given, so checking each space's
# export (saved under its own folder name by confluence_extractor.ps1, maybe
# somewhere else entirely like a shared drive) just means answering this
# differently. Set CONFLUENCE_EXPORT_DIR for unattended runs.
$exportDirHelp = @(
    "Which extraction to check - the folder name you gave (or accepted",
    "the default for) when running confluence_extractor.ps1 for that",
    "space, or its full path if it's somewhere else (e.g. a shared drive).",
    "Leave blank for: confluence_export"
)
$ExportDir = Read-ExportDir -Value $ExportDir -Prompt "Export folder to check (blank for 'confluence_export')" -HelpText $exportDirHelp
$export = Get-ExportManifest -Dir $ExportDir
$manifest = $export.Manifest
$manifestPath = $export.Path
Write-Host "Read $manifestPath"
Write-Host "$($manifest.Count) page(s) recorded in the manifest.`n"

$failuresPath = Join-Path $ExportDir "failures.json"
$recordedFailures = @()
if (Test-Path -LiteralPath $failuresPath) {
    $recordedFailures = @(Read-JsonFile $failuresPath)
}

# Patterns over the raw page HTML (Confluence's "storage format") - plain
# regexes rather than real XML parsing, same as the extractor. An
# <ri:attachment> is an image or file the page shows or links to; if it has
# an <ri:page>/<ri:content-entity> inside, that file lives on a DIFFERENT
# page and doesn't come down with this one.
$attachmentRefPattern = [regex]::new('<ri:attachment\b([^>]*?)(?:/>|>(.*?)</ri:attachment>)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
$pageRefPattern = [regex]::new('<ri:page\b([^>]*?)/?>')
$contentIdPattern = [regex]::new('<ri:content-entity\b[^>]*\bri:content-id="([^"]+)"')
$macroPattern = [regex]::new('<ac:structured-macro\b[^>]*\bac:name="([^"]+)"')

# Macros that show content which isn't actually stored in the page itself -
# it's fetched from elsewhere (another page, Jira, a live list) each time
# the page is viewed, so the export only has the macro, not what it showed.
$externalContentMacros = @(
    "include", "excerpt-include", "jira", "jiraissues", "jirachart",
    "children", "pagetree", "pagetreesearch", "contentbylabel",
    "content-report-table", "detailssummary", "recently-updated",
    "task-report", "blog-posts", "gadget", "widget", "iframe", "rss",
    "html-include", "space-details", "spaces"
)

function Get-Attribute {
    param([string]$Attributes, [string]$Name)
    $match = [regex]::Match($Attributes, [regex]::Escape($Name) + '="([^"]*)"')
    if ($match.Success) { return [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value) }
    return $null
}

# What a saved file starts with if it's actually a web page (a proxy's
# login screen, an error page) that got saved in place of the real file.
function Test-LooksLikeWebPage {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $buffer = New-Object byte[] 512
        $read = $stream.Read($buffer, 0, 512)
    }
    finally {
        $stream.Dispose()
    }
    $start = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).TrimStart().ToLower()
    return $start.StartsWith("<!doctype html") -or $start.StartsWith("<html")
}

$missingFolders = @()
$missingOrEmptyContent = @()
$badAttachments = @()
$missingReferencedFiles = @()
$linksOutsideExport = @()
$pagesWithExternalMacros = @()
$seenIds = [System.Collections.Generic.HashSet[string]]::new()
$duplicateIds = @()

# For looking up pages a page refers to, by title or by ID.
$pagesByTitle = @{}
$pagesById = @{}
foreach ($p in $manifest) {
    $pagesByTitle[[string]$p.title] = $p
    $pagesById[[string]$p.id] = $p
}
$exportSpaceKey = (Get-ExportSource -Dir $ExportDir).spaceKey

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
    $body = ""
    if (-not (Test-Path -LiteralPath $htmlPath)) {
        $missingOrEmptyContent += [PSCustomObject]@{ id = $page.id; title = $page.title; path = $htmlPath; reason = "missing" }
    }
    elseif ((Get-Item -LiteralPath $htmlPath).Length -eq 0) {
        $missingOrEmptyContent += [PSCustomObject]@{ id = $page.id; title = $page.title; path = $htmlPath; reason = "empty (0 bytes)" }
    }
    else {
        $body = Read-Utf8Text $htmlPath
    }

    # The copy of the page as Confluence displayed it - only for exports
    # made since the extractor started saving one. One that failed to save
    # is already in failures.json, so only a missing/empty file that the
    # manifest says WAS saved is flagged here.
    if ($page.rendered_file) {
        $renderedPath = Join-Path $pageFolder $page.rendered_file
        if (-not (Test-Path -LiteralPath $renderedPath)) {
            $missingOrEmptyContent += [PSCustomObject]@{ id = $page.id; title = $page.title; path = $renderedPath; reason = "rendered.html missing" }
        }
        elseif ((Get-Item -LiteralPath $renderedPath).Length -eq 0) {
            $missingOrEmptyContent += [PSCustomObject]@{ id = $page.id; title = $page.title; path = $renderedPath; reason = "rendered.html empty (0 bytes)" }
        }
    }

    # @()-wrapped so a page with exactly one attachment is still a list.
    $pageAttachments = @($page.attachments | Where-Object { $_ })
    $savedHere = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($attachment in $pageAttachments) {
        [void]$savedHere.Add([string]$attachment.filename)
        $attPath = Join-Path (Join-Path $pageFolder "images") $attachment.saved_as
        $problem = $null
        if (-not (Test-Path -LiteralPath $attPath)) {
            $problem = "missing on disk"
        }
        elseif ((Get-Item -LiteralPath $attPath).Length -eq 0) {
            $problem = "empty (0 bytes)"
        }
        elseif ($attachment.filename -notmatch '\.html?$' -and (Test-LooksLikeWebPage $attPath)) {
            $problem = "is a web page, not the real file (likely a login or error page)"
        }
        if ($problem) {
            $badAttachments += [PSCustomObject]@{
                id             = $page.id
                title          = $page.title
                attachmentName = $attachment.filename
                path           = $attPath
                reason         = "attachment '$($attachment.filename)' $problem"
            }
        }
    }

    # Every image/file this page shows or links to should have been saved -
    # either with this page, or with the other page it really lives on, as
    # long as that page is in this export too.
    foreach ($ref in $attachmentRefPattern.Matches($body)) {
        $filename = Get-Attribute $ref.Groups[1].Value "ri:filename"
        if (-not $filename) { continue }
        $inner = $ref.Groups[2].Value
        $otherPageTag = $pageRefPattern.Match($inner)
        $otherId = $contentIdPattern.Match($inner)
        if ($otherPageTag.Success) {
            $otherTitle = [string](Get-Attribute $otherPageTag.Groups[1].Value "ri:content-title")
            $otherSpace = [string](Get-Attribute $otherPageTag.Groups[1].Value "ri:space-key")
            $other = if ((-not $otherSpace) -or $otherSpace -eq $exportSpaceKey) { $pagesByTitle[$otherTitle] } else { $null }
            $where = "page '$otherTitle'" + $(if ($otherSpace) { " in space $otherSpace" } else { "" })
        }
        elseif ($otherId.Success) {
            $other = $pagesById[$otherId.Groups[1].Value]
            $where = "page id $($otherId.Groups[1].Value)"
        }
        elseif ($inner -like "*<ri:*") {
            $other = $null
            $where = "another page or blog post"
        }
        else {
            if (-not $savedHere.Contains($filename)) {
                $missingReferencedFiles += [PSCustomObject]@{ id = $page.id; title = $page.title; reason = "'$filename' wasn't saved with this page" }
            }
            continue
        }
        if (-not $other) {
            $missingReferencedFiles += [PSCustomObject]@{ id = $page.id; title = $page.title; reason = "'$filename' lives on $where, which isn't in this export" }
        }
        else {
            $savedThere = @($other.attachments | Where-Object { $_ -and ([string]$_.filename).ToLower() -eq $filename.ToLower() })
            if ($savedThere.Count -eq 0) {
                $missingReferencedFiles += [PSCustomObject]@{ id = $page.id; title = $page.title; reason = "'$filename' lives on $where, but wasn't saved there" }
            }
        }
    }

    # Links to other pages (attachment references already handled above,
    # so they're cut out first so their <ri:page> isn't counted twice).
    # Only informational - the link text survives, the page it points at
    # just isn't part of this export.
    $outside = @()
    foreach ($link in $pageRefPattern.Matches($attachmentRefPattern.Replace($body, ""))) {
        $linkTitle = Get-Attribute $link.Groups[1].Value "ri:content-title"
        $linkSpace = [string](Get-Attribute $link.Groups[1].Value "ri:space-key")
        if (-not $linkTitle) { continue }
        if (($linkSpace -and $linkSpace -ne $exportSpaceKey) -or -not $pagesByTitle.ContainsKey($linkTitle)) {
            $outside += $linkTitle + $(if ($linkSpace) { " (space $linkSpace)" } else { "" })
        }
    }
    if ($outside.Count -gt 0) {
        $unique = @($outside | Sort-Object -Unique)
        $shown = (($unique | Select-Object -First 3) | ForEach-Object { "'$_'" }) -join ", "
        if ($unique.Count -gt 3) { $shown += " and $($unique.Count - 3) more" }
        $linksOutsideExport += [PSCustomObject]@{ id = $page.id; title = $page.title; reason = "links to $shown"; targets = $unique }
    }

    $macros = @($macroPattern.Matches($body) | ForEach-Object { $_.Groups[1].Value } | Where-Object { $externalContentMacros -contains $_ })
    if ($macros.Count -gt 0) {
        $counts = [ordered]@{}
        foreach ($name in ($macros | Sort-Object -Unique)) {
            $counts[$name] = @($macros | Where-Object { $_ -eq $name }).Count
        }
        $reason = ($counts.Keys | ForEach-Object { if ($counts[$_] -gt 1) { "$_ x$($counts[$_])" } else { $_ } }) -join ", "
        $pagesWithExternalMacros += [PSCustomObject]@{ id = $page.id; title = $page.title; reason = $reason; macros = $counts }
    }
}

# Page folders on disk the manifest doesn't list - usually left from an
# earlier run, but worth a look: content here is invisible to the converter
# and every other script, since they all go by the manifest.
$listedFolders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($p in $manifest) {
    [void]$listedFolders.Add([System.IO.Path]::GetFullPath((Join-Path $ExportDir (Get-NormalisedRelativePath $p.folder))))
}
$unlistedFolders = @()
$pagesRoot = Join-Path $ExportDir "pages"
if (Test-Path -LiteralPath $pagesRoot) {
    foreach ($folder in (Get-ChildItem -LiteralPath $pagesRoot -Directory | Sort-Object Name)) {
        if (-not $listedFolders.Contains([System.IO.Path]::GetFullPath($folder.FullName))) {
            $unlistedFolders += [PSCustomObject]@{ id = ($folder.Name -split "_", 2)[0]; title = $folder.Name; path = $folder.FullName }
        }
    }
}

Write-Host "`n--- Must fix before Confluence is switched off ---"
Write-IssueSummary "Failed during extraction - pages and attachments (failures.json)" $recordedFailures $ReportName
Write-IssueSummary "Duplicate page IDs in manifest" $duplicateIds $ReportName
Write-IssueSummary "Page folders missing on disk" $missingFolders $ReportName
Write-IssueSummary "content.html / rendered.html missing or empty" $missingOrEmptyContent $ReportName
Write-IssueSummary "Attachment files missing, empty or not the real file" $badAttachments $ReportName
Write-IssueSummary "Images/files a page shows or links to that weren't saved" $missingReferencedFiles $ReportName

Write-Host "`n--- For your information ---"
Write-IssueSummary "Pages using macros whose content lives elsewhere (it won't come with the export)" $pagesWithExternalMacros $ReportName
Write-IssueSummary "Pages linking to pages that aren't in this export" $linksOutsideExport $ReportName
Write-IssueSummary "Page folders on disk the manifest doesn't list (invisible to the other scripts)" $unlistedFolders $ReportName

$liveCheck = $null

if ($CheckLiveSpace) {
    Write-Host "`n--- Live space check ---"

    $saved = Get-ExportSource -Dir $ExportDir
    $BaseUrl = Read-BaseUrl -SavedValue $saved.baseUrl

    $spaceKeyHelp = @(
        "The short code identifying which space to check, found in a page's",
        "URL right after /display/ or /spaces/."
    )
    $SpaceKey = Get-EnvSavedOrAsk $env:CONFLUENCE_SPACE_KEY $saved.spaceKey "Confluence space key" $spaceKeyHelp

    $Connection = New-ConfluenceConnection -BaseUrl $BaseUrl -UseDefaultCredentials:$UseDefaultCredentials
    Test-ConfluenceSignIn -Connection $Connection

    try {
        # No expand= here on purpose - this is only comparing IDs/titles, not
        # re-fetching every page's full content, so there's no need to ask
        # Confluence for anything heavier than it takes to list what exists.
        $livePages = @(Get-AllResults -Connection $Connection -Path "/rest/api/content" -Query "spaceKey=$SpaceKey&type=page" -Limit 100 -OnBatch { param($start) Write-Host "  fetching live page list: start=$start" })

        $liveIds = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in $livePages) { [void]$liveIds.Add([string]$p.id) }
        $manifestIds = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in $manifest) { [void]$manifestIds.Add([string]$p.id) }

        $missingFromExtraction = @($livePages | Where-Object { -not $manifestIds.Contains([string]$_.id) } | ForEach-Object { [PSCustomObject]@{ id = $_.id; title = $_.title } })
        $noLongerLive = @($manifest | Where-Object { -not $liveIds.Contains([string]$_.id) } | ForEach-Object { [PSCustomObject]@{ id = $_.id; title = $_.title } })

        Write-Host "  $($livePages.Count) page(s) live in Confluence right now, $($manifest.Count) in the manifest."
        Write-IssueSummary "Live pages never recorded in the manifest (extraction missed these)" $missingFromExtraction $ReportName
        Write-IssueSummary "Manifest pages no longer live (likely deleted/moved since extraction - not necessarily a problem)" $noLongerLive $ReportName

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

$hasIssues = $recordedFailures.Count -gt 0 -or $duplicateIds.Count -gt 0 -or $missingFolders.Count -gt 0 -or $missingOrEmptyContent.Count -gt 0 -or $badAttachments.Count -gt 0 -or $missingReferencedFiles.Count -gt 0
if ($liveCheck -and $liveCheck.missingFromExtraction.Count -gt 0) {
    $hasIssues = $true
}

Write-Host ""
if ($hasIssues) {
    Write-Host "Found issues to fix - see ""Must fix"" above (and the saved report) for details."
}
else {
    Write-Host "Nothing to fix. (Check ""For your information"" above too.)"
}

$report = [PSCustomObject]@{
    manifestPath          = $manifestPath
    totalPagesInManifest   = $manifest.Count
    recordedFailures       = $recordedFailures
    duplicateIds           = $duplicateIds
    missingFolders         = $missingFolders
    missingOrEmptyContent  = $missingOrEmptyContent
    badAttachments         = $badAttachments
    missingReferencedFiles = $missingReferencedFiles
    externalContentMacros  = $pagesWithExternalMacros
    linksOutsideExport     = $linksOutsideExport
    unlistedFolders        = $unlistedFolders
    liveCheck              = $liveCheck
}

$reportPath = Join-Path $ExportDir $ReportName
try {
    Set-Utf8NoBomContent -Path $reportPath -Value (ConvertTo-Json -InputObject $report -Depth 10)
    Write-Host "Full report saved to $reportPath"
}
catch {
    Write-Host "Couldn't save the full report to $reportPath - $($_.Exception.Message)"
    Write-Host "The summary printed above is still accurate, this just means there's no saved copy."
}

exit [int]$hasIssues

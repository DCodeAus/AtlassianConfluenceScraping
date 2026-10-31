<#
Confluence live content check - PowerShell version.
No install required.

Goes one step further than confluence_verify_extraction.ps1: instead of
only checking that every file the manifest recorded exists on disk, this
re-fetches every extracted page from Confluence itself, one at a time the
same way the extractor did, and compares what's live right now against
what got saved:

  - content.html matches the live page's content exactly (line endings
    aside) - catches a page saved truncated, garbled, or otherwise not
    what Confluence actually holds
  - the live version number is the same one extracted - catches pages
    edited in Confluence since you ran the extractor, so the export is
    out of date for them
  - every attachment on the live page was actually saved, and the saved
    file is the same size Confluence says it is - and where it isn't, the
    file is downloaded again and compared byte for byte, since Confluence's
    recorded sizes aren't always right. Catches failed, cut-off and
    replaced files, plus anything attached since
  - each page's title, parent page and labels match live - catches pages
    renamed, moved or relabelled since (which doesn't always change the
    version number)
  - every page live in the space is in the export at all - catches pages
    the extractor never got to, or added since

Results are split into "must fix before Confluence is switched off" and
"for your information".

Only reads from Confluence and only writes one report file
(live_content_report.json) into the export folder - never changes
content.html or anything else that's there.

    .\confluence_verify_live_content.ps1
    .\confluence_verify_live_content.ps1 -ExportDir "S:\Exports\confluence_export_TEAM"
    .\confluence_verify_live_content.ps1 -UseDefaultCredentials

Asks which export folder to check (a folder name next to this script, or
a full path anywhere), then your login. The site address comes from the
export folder itself (saved there by the extractor) - only asked for if
it isn't there. Set
CONFLUENCE_EXPORT_DIR, CONFLUENCE_BASE_URL, CONFLUENCE_USERNAME and
CONFLUENCE_PASSWORD for unattended runs. Takes about as long as the
extraction did, since it's one request per page plus one for its
attachments - that's normal, not a hang.

If you've run repair_garbled_text's -Force/YOLO strip on this export,
those pages will (correctly) show as not matching - the strip deliberately
removed characters the live page still has.

Something broken or unclear? Raise an issue at
https://github.com/DCodeAus/AtlassianConfluenceScraping/issues
#>

param(
    # Where confluence_extractor.ps1 saved its output. Asked for if not given.
    [string]$ExportDir,
    # Same as confluence_extractor.ps1 - pass this if your organisation logs
    # you in automatically via your Windows login rather than a separate
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

$ReportName = "live_content_report.json"

# Python's text-mode write on Windows turns every \n into \r\n, so a
# content.html saved by confluence_extractor.py on Windows never matches
# the live page byte for byte even when nothing's actually wrong. Compare
# with every kind of line ending folded to \n on both sides instead.
function Get-NormalisedLineEndings {
    param([string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-FirstDifference {
    # Where the saved and live content first stop matching, with a little
    # of each either side - enough to tell at a glance whether it's garbled
    # characters, a cut-off page, or something else entirely.
    param([string]$Saved, [string]$Live, [int]$Context = 40)
    $shortest = [Math]::Min($Saved.Length, $Live.Length)
    $index = 0
    while ($index -lt $shortest -and $Saved[$index] -ceq $Live[$index]) {
        $index++
    }
    $start = [Math]::Max(0, $index - $Context)
    return [PSCustomObject]@{
        firstDifferenceAt = $index
        savedLength       = $Saved.Length
        liveLength        = $Live.Length
        savedAround       = $Saved.Substring($start, [Math]::Min($Saved.Length, $index + $Context) - $start)
        liveAround        = $Live.Substring($start, [Math]::Min($Live.Length, $index + $Context) - $start)
    }
}

# Asked every run unless -ExportDir is given, same as
# confluence_verify_extraction.ps1 - each space's export can live under its
# own name, or somewhere else entirely like a shared drive.
$exportDirHelp = @(
    "Which extraction to check against live Confluence - the folder name",
    "you gave (or accepted the default for) when running",
    "confluence_extractor.ps1 for that space, or its full path if it's",
    "somewhere else (e.g. a shared drive).",
    "Leave blank for: confluence_export"
)
$ExportDir = Read-ExportDir -Value $ExportDir -Prompt "Export folder to check (blank for 'confluence_export')" -HelpText $exportDirHelp
$export = Get-ExportManifest -Dir $ExportDir
$manifest = $export.Manifest
$manifestPath = $export.Path
Write-Host "$($manifest.Count) page(s) recorded in $manifestPath.`n"

# The site address comes from the export folder itself (saved there by
# the extractor), so only your login gets asked for.
$saved = Get-ExportSource -Dir $ExportDir
$Connection = Connect-Confluence -SavedBaseUrl $saved.baseUrl -UseDefaultCredentials:$UseDefaultCredentials
$BaseUrl = $Connection.BaseUrl
Test-ConfluenceSignIn -Connection $Connection

function Get-FreshDownload {
    # Downloads the live file again into a temporary file, and hands back
    # its hash, size and whether it's actually a web page - so a saved file
    # can be compared with what Confluence actually sends right now, rather
    # than with the size it has on record (which isn't always right). The
    # temporary file is always deleted afterwards.
    param([string]$DownloadPath)
    $tempPath = [System.IO.Path]::GetTempFileName()
    try {
        Save-ConfluenceFile -Connection $Connection -Url $DownloadPath -OutFile $tempPath
        $stream = [System.IO.File]::OpenRead($tempPath)
        try {
            $buffer = New-Object byte[] 512
            $read = $stream.Read($buffer, 0, 512)
        }
        finally {
            $stream.Dispose()
        }
        $start = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).TrimStart().ToLower()
        return [PSCustomObject]@{
            Hash          = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash
            Size          = (Get-Item -LiteralPath $tempPath).Length
            IsWebPage     = $start.StartsWith("<!doctype html") -or $start.StartsWith("<html")
        }
    }
    finally {
        Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue
    }
}

$matchingCount = 0
$editedSince = @()
$contentDiffers = @()
$detailsDiffer = @()
$missingAttachments = @()
$attachmentFilesWrong = @()
$attachmentsRemovedLive = @()
$sizeNotReported = @()
$sizeRecordWrong = @()
$noLongerLive = @()
$couldNotCheck = @()

$index = 0
foreach ($page in $manifest) {
    $index++
    $pageId = [string]$page.id
    $title = $page.title
    $status = @()

    try {
        $live = Invoke-WithRetry { Invoke-ConfluenceApi -Connection $Connection -Uri "$BaseUrl/rest/api/content/${pageId}?expand=body.storage,version,ancestors,metadata.labels" }
        $liveBody = Get-NormalisedLineEndings ([string]$live.body.storage.value)
        $liveVersion = $live.version.number
        $savedVersion = $page.version

        # A newer live version means the page was edited after extraction,
        # so its content is expected to differ - that's the export being out
        # of date, not the save going wrong, and gets reported as such
        # rather than as a content mismatch.
        if ($null -ne $savedVersion -and $null -ne $liveVersion -and [int]$liveVersion -gt [int]$savedVersion) {
            $editedSince += [PSCustomObject]@{
                id           = $page.id
                title        = $title
                reason       = "version $savedVersion extracted, version $liveVersion live now"
                savedVersion = $savedVersion
                liveVersion  = $liveVersion
            }
            $status += "edited since (v$savedVersion -> v$liveVersion)"
        }
        else {
            $htmlPath = Join-Path (Join-Path $ExportDir (Get-NormalisedRelativePath $page.folder)) $page.html_file
            if (-not (Test-Path -LiteralPath $htmlPath)) {
                $contentDiffers += [PSCustomObject]@{ id = $page.id; title = $title; path = $htmlPath; reason = "content.html missing on disk" }
                $status += "content.html missing"
            }
            else {
                # ReadAllText with UTF-8 skips a BOM if one's there, so that
                # alone never counts as a difference.
                $savedBody = Get-NormalisedLineEndings ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $htmlPath).Path, [System.Text.Encoding]::UTF8))
                # -cne: PowerShell's plain -ne ignores case, which would
                # miss a real difference that's only in capitalisation.
                if ($savedBody -cne $liveBody) {
                    $difference = Get-FirstDifference -Saved $savedBody -Live $liveBody
                    $contentDiffers += [PSCustomObject]@{
                        id                = $page.id
                        title             = $title
                        path              = $htmlPath
                        reason            = "first difference at character $($difference.firstDifferenceAt) (saved $($difference.savedLength) chars, live $($difference.liveLength))"
                        firstDifferenceAt = $difference.firstDifferenceAt
                        savedLength       = $difference.savedLength
                        liveLength        = $difference.liveLength
                        savedAround       = $difference.savedAround
                        liveAround        = $difference.liveAround
                    }
                    $status += "content differs"
                }
            }

            # Title, parent and labels, as the extractor recorded them. Only
            # when the version matches - an edited page is already flagged
            # above, and would differ here for the same reason.
            $liveAncestors = @($live.ancestors | Where-Object { $_ })
            $liveParent = if ($liveAncestors.Count -gt 0) { [string]$liveAncestors[-1].id } else { "" }
            $liveLabels = (@($live.metadata.labels.results | Where-Object { $_ } | ForEach-Object { [string]$_.name }) | Sort-Object) -join ", "
            $savedLabels = (@($page.labels | Where-Object { $_ } | ForEach-Object { [string]$_ }) | Sort-Object) -join ", "
            $savedFields = $page.PSObject.Properties.Name
            $differences = @()
            if ([string]$live.title -cne [string]$title) {
                $differences += "title now '$($live.title)'"
            }
            if ($savedFields -contains "parent_id" -and $liveParent -ne [string]$page.parent_id) {
                $differences += "moved to a different parent page"
            }
            if ($savedFields -contains "labels" -and $liveLabels -cne $savedLabels) {
                $differences += "labels now $(if ($liveLabels) { $liveLabels } else { '(none)' })"
            }
            if ($differences.Count -gt 0) {
                $detailsDiffer += [PSCustomObject]@{ id = $page.id; title = $title; reason = $differences -join "; " }
                $status += "title/parent/labels differ"
            }
        }

        # Compared by original Confluence filename - the manifest only
        # records attachments that actually downloaded, under the name
        # Confluence gave them (not the sanitised name on disk).
        $savedByName = @{}
        foreach ($a in @($page.attachments | Where-Object { $_ })) {
            $savedByName[[string]$a.filename] = $a
        }
        $pageFolder = Join-Path $ExportDir (Get-NormalisedRelativePath $page.folder)
        $liveNames = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($liveAttachment in @(Get-AllResults -Connection $Connection -Path "/rest/api/content/$pageId/child/attachment" -Query "expand=version")) {
            $name = [string]$liveAttachment.title
            [void]$liveNames.Add($name)
            if (-not $savedByName.ContainsKey($name)) {
                $missingAttachments += [PSCustomObject]@{ id = $page.id; title = $title; reason = "attachment '$name'"; attachmentName = $name }
                $status += "attachment '$name' not saved"
                continue
            }
            $savedPath = Join-Path (Join-Path $pageFolder "images") $savedByName[$name].saved_as
            $liveSize = $liveAttachment.extensions.fileSize
            if (-not (Test-Path -LiteralPath $savedPath)) {
                $problem = "missing on disk"
            }
            elseif ($null -eq $liveSize) {
                $sizeNotReported += [PSCustomObject]@{ id = $page.id; title = $title; reason = "attachment '$name'" }
                continue
            }
            else {
                $savedSize = (Get-Item -LiteralPath $savedPath).Length
                if ($savedSize -eq [long]$liveSize) { continue }
                # Confluence's recorded size isn't always right, so before
                # calling this a bad download, fetch the file again and
                # compare the actual contents.
                try {
                    $fresh = Get-FreshDownload -DownloadPath $liveAttachment._links.download
                    if ($fresh.IsWebPage -and $name -notmatch '\.html?$') {
                        $problem = "Confluence is sending a web page instead of this file (likely a login or error page)"
                    }
                    elseif ($fresh.Hash -eq (Get-FileHash -LiteralPath $savedPath -Algorithm SHA256).Hash) {
                        $sizeRecordWrong += [PSCustomObject]@{ id = $page.id; title = $title; reason = "attachment '$name' - Confluence says $liveSize bytes, the file is $savedSize" }
                        continue
                    }
                    else {
                        $problem = "differs from a fresh download (saved $savedSize bytes, fresh $($fresh.Size)) - replaced since, or a bad download"
                    }
                }
                catch {
                    $problem = "saved $savedSize bytes, Confluence says $liveSize (couldn't download it again to compare: $($_.Exception.Message))"
                }
            }
            $attachmentFilesWrong += [PSCustomObject]@{ id = $page.id; title = $title; attachmentName = $name; path = $savedPath; reason = "attachment '$name' $problem" }
            $status += "attachment '$name' $problem"
        }
        foreach ($name in $savedByName.Keys) {
            if (-not $liveNames.Contains($name)) {
                $attachmentsRemovedLive += [PSCustomObject]@{ id = $page.id; title = $title; reason = "attachment '$name'" }
            }
        }

        if ($status.Count -eq 0) {
            $matchingCount++
        }
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            $noLongerLive += [PSCustomObject]@{ id = $page.id; title = $title }
            $status += "no longer live"
        }
        elseif ($statusCode -eq 401) {
            # A wrong login fails identically on every page - stop now rather
            # than repeating it hundreds of times. (403 is left to the branch
            # below: that's one restricted page, not a bad login, and the
            # rest are still worth checking.)
            Write-Host "[$index/$($manifest.Count)] $title - 401 Unauthorized"
            Write-Host "`nConfluence rejected the login. Check the username/password (and"
            Write-Host "that this is the right site, or try -UseDefaultCredentials), then run it again."
            exit 1
        }
        else {
            $couldNotCheck += [PSCustomObject]@{ id = $page.id; title = $title; reason = $_.Exception.Message }
            $status += "couldn't check: $($_.Exception.Message)"
        }
    }

    $statusText = if ($status.Count -gt 0) { $status -join ", " } else { "matches" }
    Write-Host "[$index/$($manifest.Count)] $title - $statusText"
    Start-Sleep -Seconds $RequestDelaySeconds
}

# Pages live in the space that the export doesn't have at all - the loop
# above only looks at pages the manifest already knows about. Needs the
# space key the extractor saved; a one-page export has none.
$spaceKey = if ($env:CONFLUENCE_SPACE_KEY) { $env:CONFLUENCE_SPACE_KEY } else { $saved.spaceKey }
$missingPages = @()
$spaceCheckNote = $null
if ($spaceKey) {
    Write-Host "`nListing every page live in space '$spaceKey'..."
    try {
        $manifestIds = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in $manifest) { [void]$manifestIds.Add([string]$p.id) }
        $livePages = @(Get-AllResults -Connection $Connection -Path "/rest/api/content" -Query "spaceKey=$([System.Uri]::EscapeDataString($spaceKey))&type=page")
        $missingPages = @($livePages | Where-Object { -not $manifestIds.Contains([string]$_.id) } | ForEach-Object { [PSCustomObject]@{ id = $_.id; title = $_.title } })
        Write-Host "  $($livePages.Count) page(s) live, $($manifest.Count) in the export."
    }
    catch {
        $spaceCheckNote = "Couldn't list the space's pages: $($_.Exception.Message)"
    }
}
else {
    $spaceCheckNote = "No space key saved with this export (a one-page export?), so pages missing from it weren't looked for."
}

Write-Host "`n--- Must fix before Confluence is switched off ---"
Write-Host "  Pages matching live exactly : $matchingCount of $($manifest.Count)"
Write-IssueSummary "Live pages missing from the export entirely" $missingPages $ReportName
Write-IssueSummary "Saved content doesn't match live (same version - the save went wrong, re-extract these)" $contentDiffers $ReportName
Write-IssueSummary "Edited in Confluence since extraction (export out of date for these)" $editedSince $ReportName
Write-IssueSummary "Title, parent page or labels differ from live (renamed/moved since - re-extract)" $detailsDiffer $ReportName
Write-IssueSummary "Live attachments that weren't saved" $missingAttachments $ReportName
Write-IssueSummary "Saved attachments missing or different from live (re-extract these pages)" $attachmentFilesWrong $ReportName
Write-IssueSummary "Couldn't check" $couldNotCheck $ReportName
if ($spaceCheckNote) {
    Write-Host "  NOTE: $spaceCheckNote"
}

Write-Host "`n--- For your information ---"
Write-IssueSummary "No longer live (likely deleted/moved since extraction - not necessarily a problem)" $noLongerLive $ReportName
Write-IssueSummary "Attachments since removed from Confluence (still in the export)" $attachmentsRemovedLive $ReportName
Write-IssueSummary "Attachments where Confluence's recorded size is wrong, but a fresh download matches the saved file exactly (fine)" $sizeRecordWrong $ReportName
Write-IssueSummary "Attachments Confluence didn't report a size for (size not checked)" $sizeNotReported $ReportName
Write-Host "  Pages restricted from your account can't be seen by any check - Confluence"
Write-Host "  doesn't list them to you at all."

$hasIssues = $missingPages.Count -gt 0 -or $contentDiffers.Count -gt 0 -or $editedSince.Count -gt 0 -or $detailsDiffer.Count -gt 0 -or $missingAttachments.Count -gt 0 -or $attachmentFilesWrong.Count -gt 0 -or $couldNotCheck.Count -gt 0 -or ($spaceCheckNote -and $spaceKey)

Write-Host ""
if ($hasIssues) {
    Write-Host "Found issues to fix - see ""Must fix"" above (and the saved report) for details."
}
else {
    Write-Host "Nothing to fix - every page matches live Confluence."
}

$report = [PSCustomObject]@{
    manifestPath          = $manifestPath
    baseUrl               = $BaseUrl
    checkedOn             = (Get-Date -Format "yyyy-MM-dd HH:mm")
    totalPagesInManifest  = $manifest.Count
    matchingCount         = $matchingCount
    contentDiffers        = $contentDiffers
    editedSinceExtraction = $editedSince
    missingPages           = $missingPages
    detailsDiffer          = $detailsDiffer
    missingAttachments     = $missingAttachments
    attachmentFilesWrong   = $attachmentFilesWrong
    couldNotCheck          = $couldNotCheck
    spaceCheckNote         = $spaceCheckNote
    noLongerLive           = $noLongerLive
    attachmentsRemovedLive = $attachmentsRemovedLive
    sizeNotReported        = $sizeNotReported
    sizeRecordWrong        = $sizeRecordWrong
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

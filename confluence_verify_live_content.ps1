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
  - every attachment on the live page was actually saved - catches
    downloads the extractor warned about and moved on from (those never
    make it into the manifest, so confluence_verify_extraction can't see
    them), plus anything attached since

Only reads from Confluence and only writes one report file
(live_content_report.json) into the export folder - never changes
content.html or anything else that's there.

    .\confluence_verify_live_content.ps1
    .\confluence_verify_live_content.ps1 -ExportDir "S:\Exports\confluence_export_TEAM"
    .\confluence_verify_live_content.ps1 -UseDefaultCredentials

Asks which export folder to check (a folder name next to this script, or
a full path anywhere), then your Confluence site address and login. Set
CONFLUENCE_EXPORT_DIR, CONFLUENCE_BASE_URL, CONFLUENCE_USERNAME and
CONFLUENCE_PASSWORD for unattended runs. Takes about as long as the
extraction did, since it's one request per page plus one for its
attachments - that's normal, not a hang.

If you've run repair_garbled_text's -Force/YOLO strip on this export,
those pages will (correctly) show as not matching - the strip deliberately
removed characters the live page still has.

Supported by Daniel - raise issues with him.
#>

param(
    # Where confluence_extractor.ps1 saved its output. Asked for if not given.
    [string]$ExportDir,
    # Same as confluence_extractor.ps1 - pass this if your organisation logs
    # you in automatically via your Windows login rather than a separate
    # Confluence username and password.
    [switch]$UseDefaultCredentials
)

# Same Windows PowerShell 5.1 fix as every other script here - keeps .NET's
# idea of the current folder in step with PowerShell's, so the .NET file
# reads below find content.html where PowerShell says it is.
[System.Environment]::CurrentDirectory = (Get-Location).Path

# Same proxy fix as the extractor - harmless if there's no proxy in the way.
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
[System.Net.WebRequest]::DefaultWebProxy = $proxy

$RequestDelaySeconds = 0.3   # same polite pace as the extractor
$RetryMaxAttempts = 3
$RetryBaseDelaySeconds = 1.0

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

# Same as confluence_verify_extraction.ps1 - lets this also run from
# Mac/Linux against a copied export.
function Get-NormalisedRelativePath {
    param([string]$RelativePath)
    return $RelativePath.Replace('\', [System.IO.Path]::DirectorySeparatorChar).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

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

function Write-IssueSummary {
    param([string]$Label, [array]$Items, [int]$ShowMax = 15)
    if ($Items.Count -eq 0) {
        Write-Host "  $Label : none"
        return
    }
    Write-Host "  $Label : $($Items.Count)"
    foreach ($item in ($Items | Select-Object -First $ShowMax)) {
        $detail = if ($item.reason) { " - $($item.reason)" } else { "" }
        Write-Host "    - [$($item.id)] $($item.title)$detail"
    }
    if ($Items.Count -gt $ShowMax) {
        Write-Host "    ... and $($Items.Count - $ShowMax) more (full list in live_content_report.json)"
    }
}

# Asked every run unless -ExportDir is given, same as
# confluence_verify_extraction.ps1 - each space's export can live under its
# own name, or somewhere else entirely like a shared drive.
if (-not $ExportDir) {
    $exportDirHelp = @(
        "Which extraction to check against live Confluence - the folder name",
        "you gave (or accepted the default for) when running",
        "confluence_extractor.ps1 for that space, or its full path if it's",
        "somewhere else (e.g. a shared drive).",
        "Leave blank for: confluence_export"
    )
    $ExportDir = if ($env:CONFLUENCE_EXPORT_DIR) { $env:CONFLUENCE_EXPORT_DIR } else { (Read-HostWithHelp "Export folder to check (blank for 'confluence_export')" $exportDirHelp).Trim() }
    # Explorer's "Copy as path" and dragging a folder into the window both
    # wrap the path in quotes - strip them so either works.
    $ExportDir = $ExportDir.Trim('"').Trim("'")
    if (-not $ExportDir) { $ExportDir = "confluence_export" }
}

# Checked before asking for a login, so a mistyped folder doesn't cost you
# typing your password first.
if (-not (Test-Path -LiteralPath $ExportDir)) {
    Write-Host "Can't find '$ExportDir' from here - run this from the folder"
    Write-Host "that contains it, or give its full path instead."
    exit 1
}

$manifestPath = Join-Path $ExportDir "manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host "No manifest.json in '$ExportDir' - that's written by"
    Write-Host "confluence_extractor.ps1 once it finishes, so either the"
    Write-Host "extraction hasn't been run yet, or this is pointed at the"
    Write-Host "wrong folder."
    exit 1
}

# @()-wrapped so a one-page manifest is still a one-item array.
$manifest = @(([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $manifestPath).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json))
Write-Host "$($manifest.Count) page(s) recorded in $manifestPath.`n"

$baseUrlHelp = @(
    "The address of the Confluence site this export came from - no trailing",
    "slash, and nothing after the domain (not /wiki, not a page path, just",
    "the base site). If you're not sure, it's on the 'Source:' line of the",
    "README.md inside the export folder."
)
$BaseUrl = if ($env:CONFLUENCE_BASE_URL) { $env:CONFLUENCE_BASE_URL } else { (Read-HostWithHelp "Confluence base URL" $baseUrlHelp).Trim() }
$BaseUrl = $BaseUrl.TrimEnd('/')

if ($UseDefaultCredentials) {
    Write-Host "Using your current Windows login instead of a separate username/password."
    $headers = @{ Accept = "application/json" }
}
else {
    $Username = if ($env:CONFLUENCE_USERNAME) { $env:CONFLUENCE_USERNAME } else { Read-HostWithHelp "Confluence username" @("The same username you log into Confluence with in your browser.") }
    if ($env:CONFLUENCE_PASSWORD) {
        $Password = $env:CONFLUENCE_PASSWORD
    }
    else {
        # Typed with the characters hidden, then unscrambled back to plain
        # text only for as long as it takes to build the login header below
        # - held in memory only, never written anywhere.
        $SecurePassword = Read-Host "Confluence password" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
    # "Basic Auth": username:password in Base64 - encoding, not encryption,
    # so always use an https:// address.
    $pair = "$($Username):$($Password)"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    $headers = @{
        Authorization = "Basic $([System.Convert]::ToBase64String($bytes))"
        Accept        = "application/json"
    }
}

function Invoke-WithRetry {
    # Same as the extractor: retries connection errors and 5xx, not 4xx.
    param([scriptblock]$Action)
    for ($attempt = 1; $attempt -le $RetryMaxAttempts; $attempt++) {
        try {
            return & $Action
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $isClientError = $statusCode -and $statusCode -lt 500
            if ($isClientError -or $attempt -eq $RetryMaxAttempts) {
                throw
            }
            $wait = $RetryBaseDelaySeconds * [Math]::Pow(2, $attempt - 1)
            Write-Host "    Request failed ($($_.Exception.Message)), retrying in ${wait}s (attempt $attempt/$RetryMaxAttempts)..."
            Start-Sleep -Seconds $wait
        }
    }
}

function Invoke-ConfluenceApi {
    # Same raw-bytes-then-UTF-8 approach as the extractor, and it matters
    # even more here: letting Invoke-RestMethod guess the encoding would
    # garble the LIVE copy, and every page with a smart quote or accent
    # would then wrongly show up as not matching.
    param([string]$Uri)
    if ($UseDefaultCredentials) {
        $response = Invoke-WebRequest -Uri $Uri -Headers $headers -Method Get -UseBasicParsing -UseDefaultCredentials
    }
    else {
        $response = Invoke-WebRequest -Uri $Uri -Headers $headers -Method Get -UseBasicParsing
    }
    if ($response.RawContentStream) {
        $bytes = $response.RawContentStream.ToArray()
    }
    elseif ($response.Content -is [byte[]]) {
        $bytes = $response.Content
    }
    else {
        $bytes = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetBytes($response.Content)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
}

function Get-LiveAttachmentNames {
    param([string]$PageId)
    $names = @()
    $start = 0
    $limit = 50
    while ($true) {
        $uri = "$BaseUrl/rest/api/content/$PageId/child/attachment?start=$start&limit=$limit"
        $data = Invoke-WithRetry { Invoke-ConfluenceApi -Uri $uri }
        # @()-wrapped - a page with exactly one attachment would otherwise
        # come back as a bare object.
        $results = @($data.results)
        foreach ($a in $results) { $names += [string]$a.title }
        if ($results.Count -lt $limit) {
            return $names
        }
        $start += $limit
    }
}

$matchingCount = 0
$editedSince = @()
$contentDiffers = @()
$missingAttachments = @()
$noLongerLive = @()
$couldNotCheck = @()

$index = 0
foreach ($page in $manifest) {
    $index++
    $pageId = [string]$page.id
    $title = $page.title
    $status = @()

    try {
        $live = Invoke-WithRetry { Invoke-ConfluenceApi -Uri "$BaseUrl/rest/api/content/${pageId}?expand=body.storage,version" }
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
        }

        # Compared by original Confluence filename - the manifest only
        # records attachments that actually downloaded, under the name
        # Confluence gave them (not the sanitised name on disk).
        $savedNames = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($a in @($page.attachments)) {
            if ($a) { [void]$savedNames.Add([string]$a.filename) }
        }
        foreach ($name in @(Get-LiveAttachmentNames -PageId $pageId)) {
            if (-not $savedNames.Contains($name)) {
                $missingAttachments += [PSCustomObject]@{ id = $page.id; title = $title; reason = "attachment '$name'"; attachmentName = $name }
                $status += "attachment '$name' not saved"
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

Write-Host "`n--- Live content check ---"
Write-Host "  Pages matching live exactly : $matchingCount of $($manifest.Count)"
Write-IssueSummary "Saved content doesn't match live (same version - the save went wrong, re-extract these)" $contentDiffers
Write-IssueSummary "Edited in Confluence since extraction (export out of date for these)" $editedSince
Write-IssueSummary "Live attachments that weren't saved" $missingAttachments
Write-IssueSummary "Couldn't check" $couldNotCheck
Write-IssueSummary "No longer live (likely deleted/moved since extraction - not necessarily a problem)" $noLongerLive

$hasIssues = $contentDiffers.Count -gt 0 -or $editedSince.Count -gt 0 -or $missingAttachments.Count -gt 0 -or $couldNotCheck.Count -gt 0

Write-Host ""
if ($hasIssues) {
    Write-Host "Found issues - see above (and the saved report) for details."
}
else {
    Write-Host "No issues found - every page matches live Confluence."
}

$report = [PSCustomObject]@{
    manifestPath          = $manifestPath
    baseUrl               = $BaseUrl
    checkedOn             = (Get-Date -Format "yyyy-MM-dd HH:mm")
    totalPagesInManifest  = $manifest.Count
    matchingCount         = $matchingCount
    contentDiffers        = $contentDiffers
    editedSinceExtraction = $editedSince
    missingAttachments    = $missingAttachments
    couldNotCheck         = $couldNotCheck
    noLongerLive          = $noLongerLive
}

$reportPath = Join-Path $ExportDir "live_content_report.json"
try {
    Set-Utf8NoBomContent -Path $reportPath -Value (ConvertTo-Json -InputObject $report -Depth 10)
    Write-Host "Full report saved to $reportPath"
}
catch {
    Write-Host "Couldn't save the full report to $reportPath - $($_.Exception.Message)"
    Write-Host "The summary printed above is still accurate, this just means there's no saved copy."
}

exit [int]$hasIssues

<#
Confluence full space extractor - PowerShell version.
No install required. Reads trusted certificates from the Windows certificate
store automatically, so no cert file path is needed here (unlike the Python
version).

Run:
    .\confluence_extractor.ps1

DO NOT commit this file with real values filled in. See README.md.

Written by Dan.
#>

# --- Fill these in ---
$BaseUrl = "https://confluence.yourcompany.com"   # no trailing slash
$SpaceKey = "ABC"

$OutputDir = "confluence_export"
$PageSize = 25
$RequestDelaySeconds = 0.3
# ---------------------

# Username and password are asked for at runtime rather than hardcoded,
# so this file is safe to share without exposing credentials. If you're
# automating this (e.g. a scheduled job), set CONFLUENCE_USERNAME and
# CONFLUENCE_PASSWORD as environment variables instead and the prompts
# below are skipped.
$Username = if ($env:CONFLUENCE_USERNAME) { $env:CONFLUENCE_USERNAME } else { Read-Host "Confluence username" }

if ($env:CONFLUENCE_PASSWORD) {
    $Password = $env:CONFLUENCE_PASSWORD
}
else {
    # Convert the secure string back to plain text only for the moment it's
    # needed to build the auth header. It's held in memory only, never written
    # to disk or displayed on screen.
    $SecurePassword = Read-Host "Confluence password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}

$pair = "$($Username):$($Password)"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$encodedCredentials = [System.Convert]::ToBase64String($bytes)

$headers = @{
    Authorization = "Basic $encodedCredentials"
    Accept        = "application/json"
}

$RetryMaxAttempts = 3
$RetryBaseDelaySeconds = 1.0

function Invoke-WithRetry {
    # Retries an action on connection errors or 5xx responses (transient
    # issues), but not on 4xx errors (bad credentials/permissions won't fix
    # themselves by retrying). Without this, a single flaky moment mid-run
    # (e.g. fetching page 300 of 500) aborts the whole script.
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

function Get-SanitisedFilename {
    param([string]$Name)
    $invalidChars = '<>:"/\|?*'
    $result = $Name
    foreach ($ch in $invalidChars.ToCharArray()) {
        $result = $result.Replace([string]$ch, "_")
    }
    return $result.Trim()
}

function Get-UniqueFilename {
    # Appends a numeric suffix if this name was already used on the same page,
    # so two attachments that sanitise to the same name don't overwrite each other.
    param([string]$Name, [System.Collections.Generic.HashSet[string]]$UsedNames)

    if (-not $UsedNames.Contains($Name)) {
        [void]$UsedNames.Add($Name)
        return $Name
    }

    $extension = [System.IO.Path]::GetExtension($Name)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $counter = 2
    do {
        $candidate = "${baseName}_${counter}${extension}"
        $counter++
    } while ($UsedNames.Contains($candidate))

    [void]$UsedNames.Add($candidate)
    return $candidate
}

function Get-AllPagesInSpace {
    $allPages = @()
    $start = 0

    while ($true) {
        Write-Host "Fetching page list: start=$start, limit=$PageSize"
        $uri = "$BaseUrl/rest/api/content?spaceKey=$SpaceKey&type=page&start=$start&limit=$PageSize&expand=body.storage,version"
        $data = Invoke-WithRetry { Invoke-RestMethod -Uri $uri -Headers $headers -Method Get }

        $results = $data.results
        $allPages += $results

        if ($results.Count -lt $PageSize) {
            break
        }

        $start += $PageSize
        Start-Sleep -Seconds $RequestDelaySeconds
    }

    return $allPages
}

function Get-AttachmentsForPage {
    param([string]$PageId)

    $attachments = @()
    $start = 0
    $limit = 50

    while ($true) {
        $uri = "$BaseUrl/rest/api/content/$PageId/child/attachment?start=$start&limit=$limit"
        $data = Invoke-WithRetry { Invoke-RestMethod -Uri $uri -Headers $headers -Method Get }

        $results = $data.results
        $attachments += $results

        if ($results.Count -lt $limit) {
            break
        }
        $start += $limit
    }

    return $attachments
}

function Save-Attachment {
    param([string]$DownloadPath, [string]$DestPath)

    $url = if ($DownloadPath -like "http*") { $DownloadPath } else { "$BaseUrl$DownloadPath" }
    Invoke-WithRetry { Invoke-WebRequest -Uri $url -Headers $headers -OutFile $DestPath }
}

# --- Main ---

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$pagesDir = Join-Path $OutputDir "pages"
New-Item -ItemType Directory -Force -Path $pagesDir | Out-Null

Write-Host "Starting extraction for space '$SpaceKey'..."

try {
    $pages = Get-AllPagesInSpace
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 401) {
        Write-Host "401 Unauthorized. Check your username/password."
    }
    elseif ($statusCode -eq 403) {
        Write-Host "403 Forbidden. Credentials valid but no read access to this space."
    }
    else {
        Write-Host "Failed to fetch page list:" $_.Exception.Message
    }
    exit 1
}

Write-Host "Found $($pages.Count) pages. Beginning download...`n"

$manifest = @()
$failures = @()
$index = 0

foreach ($page in $pages) {
    $index++
    $pageId = $page.id
    $title = $page.title
    $safeTitle = Get-SanitisedFilename $title
    $shortTitle = if ($safeTitle.Length -gt 50) { $safeTitle.Substring(0, 50) } else { $safeTitle }

    Write-Host "[$index/$($pages.Count)] $title"

    try {
        $htmlBody = $page.body.storage.value

        $pageFolder = Join-Path $pagesDir "${pageId}_$shortTitle"
        New-Item -ItemType Directory -Force -Path $pageFolder | Out-Null

        $htmlPath = Join-Path $pageFolder "content.html"
        Set-Content -Path $htmlPath -Value $htmlBody -Encoding UTF8

        $attachments = Get-AttachmentsForPage -PageId $pageId
        $attachmentRecords = @()

        if ($attachments.Count -gt 0) {
            $imagesFolder = Join-Path $pageFolder "images"
            New-Item -ItemType Directory -Force -Path $imagesFolder | Out-Null
            $usedAttachmentNames = [System.Collections.Generic.HashSet[string]]::new()

            foreach ($attachment in $attachments) {
                # Everything in this loop is guarded per-attachment: a
                # missing field or a failed download should only cost this
                # one attachment, not the whole page (whose HTML content
                # was already fetched and saved above).
                $attTitle = "<unknown>"
                try {
                    $attTitle = $attachment.title
                    $downloadLink = $attachment._links.download
                    $safeAttName = Get-UniqueFilename (Get-SanitisedFilename $attTitle) $usedAttachmentNames
                    $destPath = Join-Path $imagesFolder $safeAttName

                    Save-Attachment -DownloadPath $downloadLink -DestPath $destPath
                    $attachmentRecords += $safeAttName
                }
                catch {
                    Write-Host "    Warning: failed to download attachment '$attTitle':" $_.Exception.Message
                }

                Start-Sleep -Seconds $RequestDelaySeconds
            }
        }

        $manifest += [PSCustomObject]@{
            id          = $pageId
            title       = $title
            folder      = "pages\${pageId}_$shortTitle"
            html_file   = "content.html"
            attachments = $attachmentRecords
            version     = $page.version.number
        }
    }
    catch {
        Write-Host "    ERROR processing page '$title' (id $pageId):" $_.Exception.Message
        $failures += [PSCustomObject]@{ id = $pageId; title = $title; error = $_.Exception.Message }
    }

    Start-Sleep -Seconds $RequestDelaySeconds
}

$manifestPath = Join-Path $OutputDir "manifest.json"
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "`nDone. $($manifest.Count) pages extracted successfully."

if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) pages failed:"
    foreach ($fail in $failures) {
        Write-Host "  - $($fail.title) (id $($fail.id)): $($fail.error)"
    }
    $failuresPath = Join-Path $OutputDir "failures.json"
    $failures | ConvertTo-Json -Depth 10 | Set-Content -Path $failuresPath -Encoding UTF8
    Write-Host "Failure details saved to $failuresPath"
}

Write-Host "`nManifest saved to $manifestPath"
Write-Host "Next step: convert content.html files to Markdown."
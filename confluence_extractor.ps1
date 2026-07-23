<#
Confluence full space extractor - PowerShell version.
No install required. Reads trusted certificates from the Windows certificate
store automatically, so no cert file path is needed here (unlike the Python
version).

Run:
    .\confluence_extractor.ps1

DO NOT commit this file with real values filled in. See README.md.
#>

# --- Fill these in ---
$BaseUrl = "https://confluence.yourcompany.com"   # no trailing slash
$Username = "your.username"
$Password = "your-password"
$SpaceKey = "ABC"

$OutputDir = "confluence_export"
$PageSize = 25
$RequestDelaySeconds = 0.3
# ---------------------

$pair = "$($Username):$($Password)"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$encodedCredentials = [System.Convert]::ToBase64String($bytes)

$headers = @{
    Authorization = "Basic $encodedCredentials"
    Accept        = "application/json"
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

function Get-AllPagesInSpace {
    $allPages = @()
    $start = 0

    while ($true) {
        Write-Host "Fetching page list: start=$start, limit=$PageSize"
        $uri = "$BaseUrl/rest/api/content?spaceKey=$SpaceKey&type=page&start=$start&limit=$PageSize&expand=body.storage,version"
        $data = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

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
        $data = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

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
    Invoke-WebRequest -Uri $url -Headers $headers -OutFile $DestPath
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

            foreach ($attachment in $attachments) {
                $attTitle = $attachment.title
                $downloadLink = $attachment._links.download
                $safeAttName = Get-SanitisedFilename $attTitle
                $destPath = Join-Path $imagesFolder $safeAttName

                try {
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
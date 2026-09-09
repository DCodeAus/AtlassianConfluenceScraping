<#
Confluence extractor - PowerShell version.
No install required. Reads trusted certificates from the Windows certificate
store automatically, so no cert file path is needed here (unlike the Python
version).

Pulls every page in a space, or just one page if you give it a page ID
when asked.

Run:
    .\confluence_extractor.ps1

DO NOT commit this file with real values filled in. See README.md.

Written by Dan.
#>

# --- Fill these in ---
# The address of your Confluence site. No trailing slash, and nothing
# after the domain (not /wiki, not a page path, just the base site).
$BaseUrl = "https://confluence.yourcompany.com"   # no trailing slash
# The short code identifying which space to pull pages from. Only used if
# you leave the "page ID" prompt blank when the script asks (see below) -
# ignored if you're pulling just one specific page.
$SpaceKey = "ABC"   # used unless you enter a page ID below

# Where everything gets saved on your computer, relative to wherever you
# run this script from.
$OutputDir = "confluence_export"
# How many pages to ask Confluence for per request. Confluence won't hand
# over an entire 500-page space in one go, so the script asks for this many
# at a time and keeps asking for more until it's got everything (see
# Get-AllPagesInSpace below).
$PageSize = 25
# A short pause between requests, in seconds, so this script doesn't
# hammer the Confluence server with requests as fast as possible.
$RequestDelaySeconds = 0.3
# ---------------------

# Username and password are asked for at runtime rather than hardcoded,
# so this file is safe to share without exposing credentials. If you're
# automating this (e.g. a scheduled job), set CONFLUENCE_USERNAME and
# CONFLUENCE_PASSWORD as environment variables instead and the prompts
# below are skipped.

# Check if the username was already supplied as an environment variable
# (handy for unattended/scheduled runs); if not, ask for it right now.
$Username = if ($env:CONFLUENCE_USERNAME) { $env:CONFLUENCE_USERNAME } else { Read-Host "Confluence username" }

if ($env:CONFLUENCE_PASSWORD) {
    # Environment variable already had it - just use that, no prompt.
    $Password = $env:CONFLUENCE_PASSWORD
}
else {
    # Convert the secure string back to plain text only for the moment it's
    # needed to build the auth header. It's held in memory only, never written
    # to disk or displayed on screen.
    # Ask for the password with the on-screen characters hidden (shows
    # ***** instead of what's actually typed).
    $SecurePassword = Read-Host "Confluence password" -AsSecureString
    # The three lines below unscramble that hidden password back into
    # normal readable text for just long enough to use it, then
    # immediately wipe the unscrambled copy from memory again.
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}

# Asked every run so it's never silently assumed which mode you're about to
# get. Leave blank for the whole space, or paste a page ID (from the page
# URL, e.g. .../pages/123456789/Page+Title) to pull just that one page -
# handy for a personal space or a one-off. Set CONFLUENCE_PAGE_ID for
# unattended runs. Needs no more access than opening the page normally does.
$PageId = if ($env:CONFLUENCE_PAGE_ID) { $env:CONFLUENCE_PAGE_ID } else { (Read-Host "Page ID to extract (leave blank for the whole space)").Trim() }

# Build the login credentials Confluence expects: username and password
# joined together, then converted into the Base64 text format the "Basic
# Auth" standard requires (this is encoding, not encryption - always use
# HTTPS URLs so this travels over an encrypted connection).
$pair = "$($Username):$($Password)"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$encodedCredentials = [System.Convert]::ToBase64String($bytes)

# Every request to Confluence carries these two headers: who's asking
# (Authorization) and what data format we want back (Accept: JSON).
$headers = @{
    Authorization = "Basic $encodedCredentials"
    Accept        = "application/json"
}

# Settings for Invoke-WithRetry below: how many times to retry a failed
# request, and how long to wait before the first retry (each subsequent
# retry waits twice as long as the one before).
$RetryMaxAttempts = 3
$RetryBaseDelaySeconds = 1.0

function Invoke-WithRetry {
    # Retries an action on connection errors or 5xx responses (transient
    # issues), but not on 4xx errors (bad credentials/permissions won't fix
    # themselves by retrying). Without this, a single flaky moment mid-run
    # (e.g. fetching page 300 of 500) aborts the whole script.
    param([scriptblock]$Action)

    # Try the given action up to $RetryMaxAttempts times.
    for ($attempt = 1; $attempt -le $RetryMaxAttempts; $attempt++) {
        try {
            # Run whatever action was passed in (e.g. "fetch this page").
            # If it works, we're done - hand back its result immediately.
            return & $Action
        }
        catch {
            # It failed. Figure out whether this looks like a "won't get
            # better if we try again" problem (4xx, e.g. wrong password)
            # or a "worth trying again" problem (5xx, or no response at
            # all, e.g. the server had a brief hiccup).
            $statusCode = $_.Exception.Response.StatusCode.value__
            $isClientError = $statusCode -and $statusCode -lt 500
            if ($isClientError -or $attempt -eq $RetryMaxAttempts) {
                # Either it's a permanent-looking error, or we're out of
                # attempts - give up and let the error bubble up to
                # whoever called this.
                throw
            }
            # Worth another try: wait a bit (longer each time) then loop
            # back around and attempt it again.
            $wait = $RetryBaseDelaySeconds * [Math]::Pow(2, $attempt - 1)
            Write-Host "    Request failed ($($_.Exception.Message)), retrying in ${wait}s (attempt $attempt/$RetryMaxAttempts)..."
            Start-Sleep -Seconds $wait
        }
    }
}

function Invoke-ConfluenceApi {
    # Invoke-RestMethod guesses the response encoding from the Content-Type
    # header, and falls back to ISO-8859-1 when no charset is present -
    # Confluence's REST API often omits one. That silently mangles every
    # non-ASCII character (smart quotes, en/em dashes, accents) into
    # "Â"-style garbled text in the extracted HTML. Fetch the raw bytes instead
    # and decode as UTF-8 ourselves so page content comes through intact.
    param([string]$Uri)

    # Ask for the raw web response ourselves (rather than letting
    # Invoke-RestMethod decode it automatically), so we control exactly
    # how the bytes get turned into text.
    $response = Invoke-WebRequest -Uri $Uri -Headers $headers -Method Get -UseBasicParsing

    # Depending on the PowerShell version, the raw response bytes show up
    # in slightly different places - check each possibility in turn.
    if ($response.RawContentStream) {
        $bytes = $response.RawContentStream.ToArray()
    }
    elseif ($response.Content -is [byte[]]) {
        $bytes = $response.Content
    }
    else {
        # Content already came back as a (possibly wrongly-decoded) string -
        # undo the ISO-8859-1 guess to recover the original UTF-8 bytes.
        $bytes = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetBytes($response.Content)
    }

    # Now decode those raw bytes as UTF-8 ourselves (the correct encoding
    # Confluence actually uses), and parse the resulting text as JSON into
    # a usable PowerShell object.
    return [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
}

function Get-SanitisedFilename {
    # Windows/Mac/Linux all disallow certain characters in file names -
    # this swaps every one of them for an underscore so a page title can
    # always be safely used as part of a folder/file name.
    param([string]$Name)
    $invalidChars = '<>:"/\|?*'
    $result = $Name
    foreach ($ch in $invalidChars.ToCharArray()) {
        $result = $result.Replace([string]$ch, "_")
    }
    return $result.Trim()
}

# A real attachment name can be long ("Q3 2024 Regional Sales Review -
# Final (reviewed by finance).xlsx"), and this project's own folder depth
# (confluence_export\pages\<id>_<title>\images\<filename>) adds a fair
# bit on top of that. Windows' classic 260-character path limit is easy
# to hit on an older setup once you add all that up, so keep the saved
# filename itself well short of being the problem.
$MaxAttachmentFilenameLength = 100

function Get-TruncatedFilename {
    # Keeps the file extension (.xlsx, .png, ...) intact and trims the
    # rest, so a very long name gets shorter without losing the bit that
    # says what kind of file it actually is.
    param([string]$Name, [int]$MaxLength = $MaxAttachmentFilenameLength)

    if ($Name.Length -le $MaxLength) {
        return $Name
    }
    $extension = [System.IO.Path]::GetExtension($Name)
    $root = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $root = $root.Substring(0, $MaxLength - $extension.Length)
    return "$root$extension"
}

function Get-UniqueFilename {
    # Appends a numeric suffix if this name was already used on the same page,
    # so two attachments that sanitise to the same name don't overwrite each other.
    param([string]$Name, [System.Collections.Generic.HashSet[string]]$UsedNames)

    if (-not $UsedNames.Contains($Name)) {
        # First time seeing this name on this page - use it as-is.
        [void]$UsedNames.Add($Name)
        return $Name
    }

    # Name's already taken - split it into "name" and ".extension", then
    # try name_2.ext, name_3.ext, and so on until one isn't already used.
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
    # Fetches every page in $SpaceKey, a batch of $PageSize at a time,
    # until there's nothing left to fetch.
    $allPages = @()
    $start = 0

    while ($true) {
        Write-Host "Fetching page list: start=$start, limit=$PageSize"
        # Ask Confluence for this batch: which space, only actual pages
        # (not attachments etc), starting at $start, plus each page's
        # stored content, version number, parent-page info, and labels.
        $uri = "$BaseUrl/rest/api/content?spaceKey=$SpaceKey&type=page&start=$start&limit=$PageSize&expand=body.storage,version,ancestors,metadata.labels"
        $data = Invoke-WithRetry { Invoke-ConfluenceApi -Uri $uri }

        # @()-wrapped: when a batch has exactly one result, ConvertFrom-Json
        # (inside Invoke-ConfluenceApi) hands back a bare object instead of
        # a one-item array for that JSON array, and the .Count check below
        # would misfire on a version without PowerShell's newer "count on
        # a single object" compatibility shim.
        $results = @($data.results)
        # Add this batch's pages onto the running total.
        $allPages += $results

        # Confluence hands back fewer results than we asked for once we've
        # reached the last batch - that's the signal to stop asking for more.
        if ($results.Count -lt $PageSize) {
            break
        }

        # Otherwise, move the starting point forward by one batch and,
        # after a short polite pause, go around and fetch the next one.
        $start += $PageSize
        Start-Sleep -Seconds $RequestDelaySeconds
    }

    return $allPages
}

function Get-SinglePage {
    # Fetches just one specific page by its ID, with the same extra
    # information (content, version, parent, labels) as the whole-space path.
    param([string]$PageId)
    $uri = "$BaseUrl/rest/api/content/${PageId}?expand=body.storage,version,ancestors,metadata.labels"
    Invoke-WithRetry { Invoke-ConfluenceApi -Uri $uri }
}

# @mentions in the storage HTML reference a user by an opaque userkey (or
# occasionally a username on older content) with no display name anywhere
# in the page itself - Confluence resolves that live, client-side. Regexes
# over the raw HTML, not real XML parsing, since this is the only thing in
# the extractor that needs to look inside page content at all.
# These two patterns find "<ri:user ri:userkey="...">"-style tags and pull
# out just the identifier in quotes.
$userKeyPattern = '<ri:user\b[^>]*\bri:userkey="([^"]+)"'
$userNamePattern = '<ri:user\b[^>]*\bri:username="([^"]+)"'

function Resolve-UserDisplayName {
    # Looks up one mentioned person's real display name via Confluence's
    # own user-lookup API, using whichever identifier (key or username)
    # we actually have for them.
    param([string]$UserKey, [string]$Username)

    $uri = if ($UserKey) {
        "$BaseUrl/rest/api/user?key=$([uri]::EscapeDataString($UserKey))"
    } else {
        "$BaseUrl/rest/api/user?username=$([uri]::EscapeDataString($Username))"
    }

    try {
        $data = Invoke-ConfluenceApi -Uri $uri
        return $data.displayName
    }
    catch {
        # Lookup failed (e.g. the user's account was since deleted) - not
        # worth stopping the whole extraction over, just report "unknown".
        return $null
    }
}

function Get-AttachmentsForPage {
    # Fetches the list of every file attached to one page (images, PDFs,
    # anything), a batch at a time the same way Get-AllPagesInSpace does
    # for pages.
    param([string]$PageId)

    $attachments = @()
    $start = 0
    $limit = 50

    while ($true) {
        $uri = "$BaseUrl/rest/api/content/$PageId/child/attachment?start=$start&limit=$limit"
        $data = Invoke-WithRetry { Invoke-ConfluenceApi -Uri $uri }

        # @()-wrapped - see the matching comment in Get-AllPagesInSpace.
        $results = @($data.results)
        $attachments += $results

        if ($results.Count -lt $limit) {
            break
        }
        $start += $limit
    }

    return $attachments
}

function Set-Utf8NoBomContent {
    # Set-Content -Encoding UTF8 adds a BOM on Windows PowerShell 5.1 (not
    # on PowerShell 7, which quietly changed this default) - bypassing it
    # with a direct .NET write keeps output byte-identical to the Python
    # scripts regardless of which PowerShell version wrote it. Matters
    # concretely for manifest.json: Python's json module refuses to parse
    # a leading BOM under plain "utf-8" and crashes outright, so a
    # PowerShell-extracted, Python-converted mixed run would otherwise fail.
    param([string]$Path, [string]$Value)
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

function Save-Attachment {
    # Downloads one attachment's actual file content to disk.
    param([string]$DownloadPath, [string]$DestPath)

    # Confluence sometimes gives a full URL, sometimes just the path part
    # of one - handle both.
    $url = if ($DownloadPath -like "http*") { $DownloadPath } else { "$BaseUrl$DownloadPath" }
    Invoke-WithRetry { Invoke-WebRequest -Uri $url -Headers $headers -OutFile $DestPath }
}

# --- Main ---
# Everything above this line was just defining settings and helper
# functions - nothing has actually happened yet. This is where the script
# really starts doing the work.

# Create the output folders if they don't already exist (does nothing if
# they're already there, so running this script again is always safe).
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$pagesDir = Join-Path $OutputDir "pages"
New-Item -ItemType Directory -Force -Path $pagesDir | Out-Null

if ($PageId) {
    Write-Host "Fetching single page (id $PageId)..."
}
else {
    Write-Host "Starting extraction for space '$SpaceKey'..."
}

try {
    # Get the list of pages we're about to process - either just the one
    # page ID that was entered, or every page in the whole space.
    # @()-wrapped on both branches: PowerShell unwraps a returned collection
    # to a bare object when it has exactly one element (a space with
    # exactly one page, here), which would silently turn $pages from an
    # array into a single PSCustomObject.
    $pages = if ($PageId) { @(Get-SinglePage -PageId $PageId) } else { @(Get-AllPagesInSpace) }
}
catch {
    # Couldn't even get the page list - almost certainly a login or
    # permissions problem, so explain it clearly and stop here rather
    # than continuing with nothing to work on.
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

Write-Host "Found $($pages.Count) page(s). Beginning download...`n"

# $manifest builds up the master list describing every page successfully
# extracted (this becomes manifest.json at the end - the next script,
# confluence_html_to_markdown.ps1, reads this to know what's there).
$manifest = @()
# $failures collects anything that went wrong, so one bad page doesn't
# stop the whole run, but you can still see what needs a second look.
$failures = @()
$index = 0
# These collect every distinct person mentioned anywhere across all
# pages, so we can look each of them up ONCE at the end (see below)
# rather than repeating the same lookup every time the same person is
# mentioned on multiple pages.
$mentionedUserKeys = [System.Collections.Generic.HashSet[string]]::new()
$mentionedUsernames = [System.Collections.Generic.HashSet[string]]::new()

# The main loop: go through every page one at a time, save its content,
# download its attachments, and record it in the manifest.
foreach ($page in $pages) {
    $index++
    $pageId = $page.id
    $title = $page.title
    $safeTitle = Get-SanitisedFilename $title
    # Folder names can only be so long - trim an overly long title down
    # to a sane length before it becomes part of a folder name below.
    $shortTitle = if ($safeTitle.Length -gt 50) { $safeTitle.Substring(0, 50) } else { $safeTitle }

    Write-Host "[$index/$($pages.Count)] $title"

    try {
        # The actual page content, in Confluence's own storage format
        # (a flavour of XHTML).
        $htmlBody = $page.body.storage.value

        # Scan this page's content for any @mentions, adding whoever's
        # found to the running lists above.
        foreach ($m in [regex]::Matches($htmlBody, $userKeyPattern)) {
            [void]$mentionedUserKeys.Add($m.Groups[1].Value)
        }
        foreach ($m in [regex]::Matches($htmlBody, $userNamePattern)) {
            [void]$mentionedUsernames.Add($m.Groups[1].Value)
        }

        # Each page gets its own folder, named after its ID and title so
        # it's easy to recognise while browsing the output on disk.
        $pageFolder = Join-Path $pagesDir "${pageId}_$shortTitle"
        New-Item -ItemType Directory -Force -Path $pageFolder | Out-Null

        # Save the raw page content to content.html inside that folder.
        $htmlPath = Join-Path $pageFolder "content.html"
        Set-Utf8NoBomContent -Path $htmlPath -Value $htmlBody

        # @()-wrapped: without it, a page with exactly one attachment would
        # have PowerShell unwrap the returned collection to a bare object,
        # and $attachments.Count below could come back $null instead of 1 -
        # silently skipping that page's only attachment entirely.
        $attachments = @(Get-AttachmentsForPage -PageId $pageId)
        # This will end up holding one entry per successfully-downloaded
        # attachment, recording both its original name and what it got
        # saved as (see the comment futher down for why both matter).
        $attachmentRecords = @()

        if ($attachments.Count -gt 0) {
            # This page has at least one attachment - make an "images"
            # subfolder to hold them all.
            $imagesFolder = Join-Path $pageFolder "images"
            New-Item -ItemType Directory -Force -Path $imagesFolder | Out-Null
            # Tracks names already used on THIS page, so Get-UniqueFilename
            # can spot and avoid collisions.
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
                    # Work out a safe, unique file name to save this
                    # attachment under on disk.
                    $safeAttName = Get-UniqueFilename (Get-TruncatedFilename (Get-SanitisedFilename $attTitle)) $usedAttachmentNames
                    $destPath = Join-Path $imagesFolder $safeAttName

                    Save-Attachment -DownloadPath $downloadLink -DestPath $destPath
                    # Keep both names: the page's HTML references images by
                    # their original Confluence filename, which can differ
                    # from what actually got saved to disk (sanitised
                    # characters, or a _2 suffix from a name collision). The
                    # converter needs this mapping to resolve them back to
                    # the file that's actually there.
                    $attachmentRecords += [PSCustomObject]@{ filename = $attTitle; saved_as = $safeAttName }
                }
                catch {
                    # This one attachment failed - note it and move on,
                    # don't let it take down the rest of the page.
                    Write-Host "    Warning: failed to download attachment '$attTitle':" $_.Exception.Message
                }

                Start-Sleep -Seconds $RequestDelaySeconds
            }
        }

        # "ancestors" comes back ordered root-first, so the immediate parent
        # (if any) is the last one - used to build the "Related pages"
        # parent/children links in the SharePoint export.
        $parent = if ($page.ancestors -and $page.ancestors.Count -gt 0) { $page.ancestors[-1] } else { $null }

        # Pull out this page's labels/tags, if it has any, as a plain list
        # of names.
        $labels = if ($page.metadata -and $page.metadata.labels -and $page.metadata.labels.results) {
            @($page.metadata.labels.results | ForEach-Object { $_.name })
        } else {
            @()
        }

        # Record everything about this page in the manifest - the next
        # script reads this to know what pages exist and where to find
        # each one's saved content.
        $manifest += [PSCustomObject]@{
            id           = $pageId
            title        = $title
            folder       = "pages\${pageId}_$shortTitle"
            html_file    = "content.html"
            attachments  = $attachmentRecords
            parent_id    = if ($parent) { $parent.id } else { $null }
            parent_title = if ($parent) { $parent.title } else { $null }
            labels       = $labels
            version      = $page.version.number
        }
    }
    catch {
        # Something about this whole page failed (not just one
        # attachment) - record it as a failure and move on to the next
        # page rather than stopping the entire run.
        Write-Host "    ERROR processing page '$title' (id $pageId):" $_.Exception.Message
        $failures += [PSCustomObject]@{ id = $pageId; title = $title; error = $_.Exception.Message }
    }

    Start-Sleep -Seconds $RequestDelaySeconds
}

# @mentions only give us an opaque userkey/username, so resolve each one
# (once) to the name that's actually worth showing. Best-effort: a lookup
# failing (e.g. a deleted user) just leaves that one out, the converter
# falls back to showing the raw identifier instead.
if ($mentionedUserKeys.Count -gt 0 -or $mentionedUsernames.Count -gt 0) {
    Write-Host "`nResolving $($mentionedUserKeys.Count + $mentionedUsernames.Count) mentioned user(s)..."
    $userDisplayNames = @{}

    # Look up every distinct mentioned person exactly once (that's the
    # whole point of collecting them into $mentionedUserKeys/Usernames
    # above instead of looking each one up every time they're mentioned).
    foreach ($userKey in $mentionedUserKeys) {
        $displayName = Resolve-UserDisplayName -UserKey $userKey
        if ($displayName) { $userDisplayNames[$userKey] = $displayName }
        Start-Sleep -Seconds $RequestDelaySeconds
    }
    foreach ($username in $mentionedUsernames) {
        $displayName = Resolve-UserDisplayName -Username $username
        if ($displayName) { $userDisplayNames[$username] = $displayName }
        Start-Sleep -Seconds $RequestDelaySeconds
    }

    # Save the userkey/username -> real name lookup table so the next
    # script can turn @mentions into actual names instead of raw IDs.
    $userDisplayNamesPath = Join-Path $OutputDir "user_display_names.json"
    Set-Utf8NoBomContent -Path $userDisplayNamesPath -Value (ConvertTo-Json -InputObject $userDisplayNames -Depth 5)
}

$manifestPath = Join-Path $OutputDir "manifest.json"
# -InputObject, not piped: piping a one-element array into ConvertTo-Json
# writes a bare JSON object ({...}) instead of a one-item array ([{...}]),
# since ConvertTo-Json only sees the single object the pipeline unrolled
# it into - this would break every downstream script expecting to loop
# over a list of pages, exactly when there's exactly one page extracted
# (the documented single-page mode).
Set-Utf8NoBomContent -Path $manifestPath -Value (ConvertTo-Json -InputObject $manifest -Depth 10)

Write-Host "`nDone. $($manifest.Count) pages extracted successfully."

if ($failures.Count -gt 0) {
    # Print a short summary of anything that failed, and also save the
    # full details to failures.json so they can be looked at separately.
    Write-Host "$($failures.Count) pages failed:"
    foreach ($fail in $failures) {
        Write-Host "  - $($fail.title) (id $($fail.id)): $($fail.error)"
    }
    $failuresPath = Join-Path $OutputDir "failures.json"
    Set-Utf8NoBomContent -Path $failuresPath -Value (ConvertTo-Json -InputObject $failures -Depth 10)
    Write-Host "Failure details saved to $failuresPath"
}

Write-Host "`nManifest saved to $manifestPath"
Write-Host "Next step: convert content.html files to Markdown."

<#
Confluence extractor - PowerShell version.
No install required. Reads trusted certificates from the Windows certificate
store automatically, so no cert file path is needed here (unlike the Python
version).

Pulls every page in a space, or just one page if you give it a page ID
when asked.

Run:
    .\confluence_extractor.ps1

Get a 401 error mentioning SSO, or "Failed to fetch page list" with a
JSON-parsing error mentioning an unexpected "<" character? Some Confluence
setups log you in via your Windows login automatically (Integrated Windows
Authentication) rather than a separate username/password. Try again with:
    .\confluence_extractor.ps1 -UseDefaultCredentials
That skips the username/password prompts entirely and uses your current
Windows login instead - see confluence_auth_test.ps1 for how to confirm
which kind of login your Confluence actually needs before running a full
extraction.

Get a 407 (Proxy Authentication Required) error instead? This script
already offers your Windows login to the proxy automatically on every
run - if you're still seeing 407, the proxy itself needs something this
script can't provide (a different login, or isn't using your Windows
account at all), and that needs sorting out with whoever manages your
network.

Asks for your Confluence site address and space key every time it runs,
rather than having you edit them into the file - nothing identifying this
script's real target ever needs to be typed into the file itself, so it's
always safe to share or commit as-is. Set CONFLUENCE_BASE_URL and
CONFLUENCE_SPACE_KEY as environment variables for unattended runs, same
idea as the credentials below.

Also asks what to name the export folder, defaulting to one based on the
space key (e.g. confluence_export_TEAM) - pulling a second space just
means answering that differently, nothing overwrites your first export.
Set CONFLUENCE_EXPORT_DIR to fix it in advance for unattended runs.
confluence_html_to_markdown.ps1 (and the other scripts downstream of this
one) ask the same thing, so give them the same folder name when it's
that space's turn to be converted.

Also writes a README.md into the export folder itself (source site/space,
who ran it, the date, and page/attachment counts) - handy if this export
ever leaves your machine without this script alongside it, e.g. uploaded
as its own repo for a teammate.

Get "Could not find a part of the path" partway through, on content.html
or failures.json or manifest.json, even though folders are visibly being
created? Fixed - this was Windows PowerShell 5.1 specifically: "cd"
moves PowerShell's own idea of where you are, but doesn't tell .NET's
file-writing functions, which quietly keep using wherever the window
first opened instead. Folders got created in the right place (PowerShell
cmdlets follow you), but every file write then looked for that folder in
the wrong place (.NET didn't). Already fixed below - grab a fresh copy
if you're still seeing this.

Supported by Daniel - raise issues with him.
#>

param(
    # Pass this if your organisation logs you into things automatically via
    # your Windows login rather than a separate Confluence username and
    # password. Skips the username/password prompts below entirely and
    # uses your current Windows login instead. Not sure which applies to
    # you? Run confluence_auth_test.ps1 first (with or without this same
    # switch) to check before committing to a full extraction.
    [switch]$UseDefaultCredentials
)

# On Windows PowerShell 5.1, "cd"/Set-Location only moves PowerShell's OWN
# idea of where you are - it does NOT tell .NET's file-writing functions
# (which this script uses directly, for reasons explained where they're
# used), which silently keep using wherever this PowerShell window first
# opened. Real, confirmed failure mode: folders visibly get created in
# the right place (PowerShell cmdlets like New-Item follow you), but
# every file write into them then fails with "Could not find a part of
# the path", because .NET is still looking somewhere else entirely. This
# line keeps the two in sync, right from the start, regardless of how
# this window was opened or what you "cd"'d through to get here.
[System.Environment]::CurrentDirectory = (Get-Location).Path

# Tells .NET to offer your current Windows login to the proxy if it ever
# asks for one. Some corporate networks require an authenticated proxy to
# reach the internet at all - without this, that fails with a confusing
# "407 (Proxy Authentication Required)" error, since PowerShell doesn't
# send proxy credentials automatically the way a browser does. Harmless
# if there's no proxy in the way, or it doesn't need credentials - this
# only does anything on a network that specifically needs it. Only lasts
# for this one run, which is why it's set automatically here rather than
# needing to be retyped by hand every time you open a new window.
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
[System.Net.WebRequest]::DefaultWebProxy = $proxy

function Read-HostWithHelp {
    # Like Read-Host, but typing a bare "?" prints an explanation of what's
    # being asked for instead of being treated as the actual answer, then
    # asks again - so someone new to this doesn't have to already know what
    # to type before they can find out.
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

# Asked every run rather than hardcoded, so there's nothing identifying
# your Confluence instance sitting in this file to accidentally commit or
# share. Set CONFLUENCE_BASE_URL for unattended runs, same idea as the
# credentials further down.
$baseUrlHelp = @(
    "The address of your Confluence site, with no slash on the end. Copy it",
    "from your browser's address bar while viewing any Confluence page,",
    "keeping only the part before /display/ or /spaces/, e.g.",
    "https://confluence.yourcompany.com - if there's something in between",
    "(like /wiki or /confluence), keep that too."
)
$BaseUrl = if ($env:CONFLUENCE_BASE_URL) { $env:CONFLUENCE_BASE_URL } else { (Read-HostWithHelp "Confluence base URL" $baseUrlHelp).Trim() }

# Same idea - only actually used if you leave the "page ID" prompt blank
# further down (ignored if you're pulling just one specific page), but
# asked up front either way so it's never silently assumed. Set
# CONFLUENCE_SPACE_KEY for unattended runs.
$spaceKeyHelp = @(
    "The short code identifying which space to pull pages from. Find it",
    "in a page's URL while browsing Confluence, right after /display/ or",
    "/spaces/ depending on which URL style your Confluence uses:",
    "  .../display/ABC/Page+Title                -> space key is 'ABC'",
    "  .../spaces/ABC/pages/123456789/Page+Title  -> space key is 'ABC'",
    "Leave this blank if you're going to enter a page ID instead when",
    "asked next."
)
$SpaceKey = if ($env:CONFLUENCE_SPACE_KEY) { $env:CONFLUENCE_SPACE_KEY } else { (Read-HostWithHelp "Confluence space key (leave blank if you'll give a page ID instead)" $spaceKeyHelp).Trim() }

# Asked every run, same as everything else above, so pulling a second
# space (or re-pulling the same one later) never silently overwrites an
# export you already have - give each one its own folder name, e.g.
# confluence_export_TEAM and confluence_export_personal. Leave blank for
# the plain default. Set CONFLUENCE_EXPORT_DIR for unattended runs.
$suggestedOutputDir = if ($SpaceKey) { "confluence_export_$SpaceKey" } else { "confluence_export" }
$outputDirHelp = @(
    "Where everything gets saved on your computer, relative to wherever",
    "you run this script from. Worth naming per space (e.g.",
    "confluence_export_TEAM) if you're going to extract more than one,",
    "so a second extraction doesn't land in the same folder as the first.",
    "Leave blank for: $suggestedOutputDir"
)
$OutputDir = if ($env:CONFLUENCE_EXPORT_DIR) { $env:CONFLUENCE_EXPORT_DIR } else { (Read-HostWithHelp "Export folder name (blank for '$suggestedOutputDir')" $outputDirHelp).Trim() }
if (-not $OutputDir) { $OutputDir = $suggestedOutputDir }

# --- Fill these in ---
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

if ($UseDefaultCredentials) {
    Write-Host "Using your current Windows login instead of a separate username/password."
}
else {
    # Check if the username was already supplied as an environment variable
    # (handy for unattended/scheduled runs); if not, ask for it right now.
    $usernameHelp = @(
        "This is the same username you use to log into Confluence in your",
        "web browser - usually your email address or your company username.",
        "If you're not sure, open Confluence in a browser first and check",
        "what you log in with there."
    )
    $Username = if ($env:CONFLUENCE_USERNAME) { $env:CONFLUENCE_USERNAME } else { Read-HostWithHelp "Confluence username" $usernameHelp }

    if ($env:CONFLUENCE_PASSWORD) {
        # Environment variable already had it - just use that, no prompt.
        $Password = $env:CONFLUENCE_PASSWORD
    }
    else {
        while ($true) {
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

            # Password input is masked, so typing "?" isn't visibly different
            # from typing anything else - only found out here, after decoding.
            if ($Password -ne "?") {
                break
            }
            Write-Host "This is the same password you use to log into Confluence in your"
            Write-Host "web browser. It's masked as you type (you won't see the characters"
            Write-Host "appear) - that's normal, just type it and press Enter."
        }
    }
}

# Asked every run so it's never silently assumed which mode you're about to
# get. Leave blank for the whole space, or paste a page ID (from the page
# URL, e.g. .../pages/123456789/Page+Title) to pull just that one page -
# handy for a personal space or a one-off. Set CONFLUENCE_PAGE_ID for
# unattended runs. Needs no more access than opening the page normally does.
# If the space key was left blank just now (on the assumption a page ID
# is coming instead), say so plainly here rather than showing an empty
# "''" in the message below.
$spaceDescription = if ($SpaceKey) { "the '$SpaceKey' space you just entered" } else { "a space (you left the space key blank)" }
$pageIdHelp = @(
    "Leave this blank to pull every page in $spaceDescription.",
    "To pull just ONE page instead, open that page in Confluence and",
    "look at the URL - it's the number right after /pages/, e.g.",
    ".../pages/123456789/Page+Title means the Page ID is 123456789."
)
$PageId = if ($env:CONFLUENCE_PAGE_ID) { $env:CONFLUENCE_PAGE_ID } else { (Read-HostWithHelp "Page ID to extract (leave blank for the whole space)" $pageIdHelp).Trim() }

if ($UseDefaultCredentials) {
    # No Authorization header needed here - Invoke-ConfluenceApi passes
    # -UseDefaultCredentials to Invoke-WebRequest instead, which negotiates
    # using the Windows login directly, the same thing a browser does
    # automatically.
    $headers = @{
        Accept = "application/json"
    }
}
else {
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
    # how the bytes get turned into text. -UseDefaultCredentials only gets
    # added when that switch was actually passed at the top of this script
    # - $headers already has no Authorization entry in that case (see
    # above), so this negotiates using the current Windows login instead.
    if ($UseDefaultCredentials) {
        $response = Invoke-WebRequest -Uri $Uri -Headers $headers -Method Get -UseBasicParsing -UseDefaultCredentials
    }
    else {
        $response = Invoke-WebRequest -Uri $Uri -Headers $headers -Method Get -UseBasicParsing
    }

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
    # TrimEnd here matters most for an attachment with no extension at all
    # (where this would otherwise end the whole filename in a trailing
    # space or dot - Windows silently drops that when the file's actually
    # created, but a later open/write using this same string wouldn't get
    # that same treatment, so the two stop referring to the same file).
    $root = $root.Substring(0, $MaxLength - $extension.Length).TrimEnd(' ', '.')
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

        # An EMPTY batch is the signal there's nothing left. (Not a short
        # one: some Confluence setups quietly hand back fewer than asked
        # for, because of a server-side cap on page size, and treating that
        # as "last batch" would silently miss every page after it.)
        if ($results.Count -eq 0) {
            break
        }

        # Otherwise, move the starting point forward by however many
        # actually came back (not by $PageSize, for the same reason) and,
        # after a short polite pause, go around and fetch the next one.
        $start += $results.Count
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

        # Same as Get-AllPagesInSpace - empty batch means done, and move on
        # by however many actually came back.
        if ($results.Count -eq 0) {
            break
        }
        $start += $results.Count
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

# Where this export came from, saved into the export folder so the verify
# scripts can pick it up instead of asking for the site address and space
# key again. Written first thing rather than at the end, so it's there
# even if this run stops partway. Never any login details. A one-page
# re-run into a folder that already has one leaves it alone, so it doesn't
# swap the whole space's details for one page's.
$sourcePath = Join-Path $OutputDir "export_source.json"
if (-not ($PageId -and (Test-Path -LiteralPath $sourcePath))) {
    $source = [PSCustomObject]@{ baseUrl = $BaseUrl.TrimEnd('/'); spaceKey = $SpaceKey; pageId = $PageId }
    Set-Utf8NoBomContent -Path $sourcePath -Value (ConvertTo-Json -InputObject $source)
}

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
        Write-Host "401 Unauthorized. Check your username/password, or try again with"
        Write-Host "-UseDefaultCredentials - see the top of this file."
    }
    elseif ($statusCode -eq 403) {
        Write-Host "403 Forbidden. Credentials valid but no read access to this space."
    }
    elseif ($_.Exception.Message -like "*Unexpected character*parsing value*") {
        # No useful HTTP status code here either - the request got a
        # normal 200 OK back, so no HTTP-level error was thrown, but the
        # body wasn't JSON at all (this is the exact error .NET's JSON
        # parser gives for an unexpected character, almost always "<" -
        # the start of an HTML page). That's the signature of basic auth
        # silently being redirected to an HTML login/SSO page instead of
        # being cleanly rejected - try -UseDefaultCredentials instead.
        Write-Host "Got a response back, but it wasn't JSON - likely an HTML login or"
        Write-Host "SSO page instead of real API content. Try again with"
        Write-Host "-UseDefaultCredentials - see the top of this file."
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
    # Folder names can only be so long - trim an overly long title down to
    # a sane length before it becomes part of a folder name below. Confirmed
    # real bug: cutting at a fixed length can land right after a space in
    # the original title, leaving a TRAILING space on the folder name.
    # Windows silently drops a trailing space when the folder actually
    # gets created, but a later write using this same (untrimmed) string
    # doesn't get that same treatment - "Could not find a part of the
    # path", because the two no longer refer to the same folder. Trimming
    # again after cutting closes that gap.
    $shortTitle = if ($safeTitle.Length -gt 50) { $safeTitle.Substring(0, 50).TrimEnd(' ', '.') } else { $safeTitle }

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
                    # don't let it take down the rest of the page. Recorded
                    # in failures.json alongside failed pages, so
                    # confluence_verify_extraction.ps1 flags it - a warning
                    # that's scrolled off screen is too easy to miss.
                    Write-Host "    Warning: failed to download attachment '$attTitle':" $_.Exception.Message
                    $failures += [PSCustomObject]@{ id = $pageId; title = $title; error = $_.Exception.Message; attachmentName = $attTitle }
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
$userDisplayNames = @{}
if ($mentionedUserKeys.Count -gt 0 -or $mentionedUsernames.Count -gt 0) {
    Write-Host "`nResolving $($mentionedUserKeys.Count + $mentionedUsernames.Count) mentioned user(s)..."

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

}

$userDisplayNamesPath = Join-Path $OutputDir "user_display_names.json"
$manifestPath = Join-Path $OutputDir "manifest.json"
$failuresPath = Join-Path $OutputDir "failures.json"

# Re-extracting ONE page (to fix something a verify script flagged) into a
# folder that already holds the whole space: fold this page into what's
# already there instead of replacing it. Otherwise the manifest would end
# up listing just this one page - every other page still on disk, but
# invisible to the converter and the verify scripts.
$merging = [bool]$PageId -and (Test-Path -LiteralPath $manifestPath)
if ($merging) {
    $redoneIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $pages) { [void]$redoneIds.Add([string]$p.id) }

    $newEntries = @{}
    foreach ($entry in $manifest) { $newEntries[[string]$entry.id] = $entry }
    # @()-wrapped so a one-page existing manifest is still a list.
    $existingManifest = @((Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json))
    $merged = @()
    # Keeps each page in its original place, swapping in the new entry.
    foreach ($entry in $existingManifest) {
        $entryId = [string]$entry.id
        if ($newEntries.ContainsKey($entryId)) {
            $merged += $newEntries[$entryId]
            $newEntries.Remove($entryId)
        }
        else {
            $merged += $entry
        }
    }
    foreach ($entry in $manifest) {
        if ($newEntries.ContainsKey([string]$entry.id)) { $merged += $entry }
    }
    $manifest = $merged

    if (Test-Path -LiteralPath $failuresPath) {
        $keptFailures = @((Get-Content -Raw -LiteralPath $failuresPath -Encoding UTF8 | ConvertFrom-Json) | Where-Object { $_ -and -not $redoneIds.Contains([string]$_.id) })
        $failures = $keptFailures + $failures
    }
    if (Test-Path -LiteralPath $userDisplayNamesPath) {
        $existingNames = Get-Content -Raw -LiteralPath $userDisplayNamesPath -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $existingNames.PSObject.Properties) {
            if (-not $userDisplayNames.ContainsKey($prop.Name)) { $userDisplayNames[$prop.Name] = $prop.Value }
        }
    }
    Write-Host "`nUpdated $($redoneIds.Count) page(s) in the existing export - the other pages already there are kept."
}

# Save the userkey/username -> real name lookup table so the next script
# can turn @mentions into actual names instead of raw IDs.
if ($userDisplayNames.Count -gt 0) {
    Set-Utf8NoBomContent -Path $userDisplayNamesPath -Value (ConvertTo-Json -InputObject $userDisplayNames -Depth 5)
}

# -InputObject, not piped: piping a one-element array into ConvertTo-Json
# writes a bare JSON object ({...}) instead of a one-item array ([{...}]),
# since ConvertTo-Json only sees the single object the pipeline unrolled
# it into - this would break every downstream script expecting to loop
# over a list of pages, exactly when there's exactly one page extracted
# (the documented single-page mode).
Set-Utf8NoBomContent -Path $manifestPath -Value (ConvertTo-Json -InputObject $manifest -Depth 10)

$pageFailures = @($failures | Where-Object { -not $_.attachmentName })
$attachmentFailures = @($failures | Where-Object { $_.attachmentName })
Write-Host "`nDone. $($manifest.Count) pages in the export."

if ($failures.Count -gt 0) {
    # Print a short summary of anything that failed - this always happens,
    # regardless of whether saving the file below works, so the list below
    # is never the only copy of this information.
    Write-Host "$($pageFailures.Count) page(s) and $($attachmentFailures.Count) attachment(s) failed:"
    foreach ($fail in $failures) {
        $what = if ($fail.attachmentName) { "attachment '$($fail.attachmentName)' on " } else { "" }
        Write-Host "  - $what$($fail.title) (id $($fail.id)): $($fail.error)"
    }
    try {
        Set-Utf8NoBomContent -Path $failuresPath -Value (ConvertTo-Json -InputObject $failures -Depth 10)
        Write-Host "Failure details also saved to $failuresPath"
    }
    catch {
        # Don't claim success if it didn't work - the summary printed
        # above is still there either way, this is just the extra copy.
        Write-Host "Couldn't save failure details to $failuresPath - $($_.Exception.Message)"
        Write-Host "The summary above is still accurate, this just means there's no extra copy on disk."
    }
}
elseif (Test-Path -LiteralPath $failuresPath) {
    # Left over from an earlier run that DID have failures - nothing failed
    # this time, so it'd only make the verify scripts report problems that
    # have since been fixed.
    Remove-Item -LiteralPath $failuresPath
}

Write-Host "`nManifest saved to $manifestPath"

if ($merging) {
    # The README describes the whole space's export - leave it as it is
    # rather than rewriting it to describe just this one page.
    Write-Host "Next step: run the verify scripts again to check the fix."
    exit 0
}

# A plain-English README saved alongside the export itself - handy if
# this folder ever leaves your machine (e.g. uploaded as its own repo for
# a teammate), so where it came from and what's in it doesn't depend on
# anyone remembering or still having this script around.
$totalAttachments = ($manifest | ForEach-Object { $_.attachments.Count } | Measure-Object -Sum).Sum
if (-not $totalAttachments) { $totalAttachments = 0 }
$extractedBy = if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { "unknown" }
$sourceDescription = if ($SpaceKey) { "space '$SpaceKey'" } else { "page id $PageId" }
$readmeLines = @(
    "# Confluence export"
    ""
    "- Source: $BaseUrl ($sourceDescription)"
    "- Extracted by: $extractedBy"
    "- Extracted on: $(Get-Date -Format 'yyyy-MM-dd')"
    "- Pages: $($manifest.Count)"
    "- Attachments: $totalAttachments"
)
if ($failures.Count -gt 0) {
    $readmeLines += "- Failed to extract: $($pageFailures.Count) page(s), $($attachmentFailures.Count) attachment(s) (see failures.json)"
}
$readmeLines += @(
    ""
    "## Why Markdown?"
    ""
    "This gets converted to Markdown rather than kept as Confluence's raw"
    "HTML (next step below) because plain text outlives any one platform -"
    "no login wall, no proprietary format, readable by a person, a diff"
    "tool, or an AI model with no conversion step first. As more of how we"
    "search, summarise, and work with documentation runs through AI"
    "tools, content that's already plain structured text is simply easier"
    "for those tools to use well - we're building for where that's"
    "heading, not just archiving where Confluence is leaving off."
    ""
    "## Next step"
    ""
    "To convert this into Markdown, run confluence_html_to_markdown.ps1"
    "(or .py) and give it '$OutputDir' as the export folder to convert"
    "when asked."
)
$readmePath = Join-Path $OutputDir "README.md"
try {
    Set-Utf8NoBomContent -Path $readmePath -Value (($readmeLines -join "`n") + "`n")
    Write-Host "Wrote $readmePath"
}
catch {
    # Not worth stopping over - everything else has already been saved,
    # this is just a convenience summary.
    Write-Host "Couldn't write $readmePath - $($_.Exception.Message)"
}

Write-Host "Next step: convert content.html files to Markdown."

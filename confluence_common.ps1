<#
Shared code for every PowerShell script in this folder.

Not something you run yourself. Every confluence_*.ps1 script (and
repair_garbled_text.ps1) loads this file first, with a line like:

    . (Join-Path $PSScriptRoot "confluence_common.ps1")

(the dot at the start means "run it as part of this script", so
everything defined here can be used straight away). The things they all
do the same way - asking a question with "?" help, finding an export
folder and what it came from, talking to Confluence, reading Confluence's
page HTML - are written once here, and a fix here fixes every script at
once.

Keep this file in the same folder as the scripts. Downloading just one
script on its own won't work - grab the whole repository. Downloaded it
as a ZIP on Windows? Run this once in the folder first, or Windows may
refuse to load this file:

    Get-ChildItem *.ps1 | Unblock-File
#>

# On Windows PowerShell 5.1, "cd"/Set-Location only moves PowerShell's OWN
# idea of where you are - it does NOT tell .NET's file-reading and
# file-writing functions (which these scripts use directly, for reasons
# explained where they're used), which silently keep using wherever this
# PowerShell window first opened. Real, confirmed failure mode: folders
# visibly get created in the right place (PowerShell cmdlets like New-Item
# follow you), but every file write into them then fails with "Could not
# find a part of the path", because .NET is still looking somewhere else
# entirely. This line keeps the two in sync, right from the start,
# regardless of how this window was opened or what you "cd"'d through to
# get here.
[System.Environment]::CurrentDirectory = (Get-Location).Path

# Tells .NET to offer your current Windows login to the proxy if it ever
# asks for one. Some corporate networks require an authenticated proxy to
# reach the internet at all - without this, that fails with a confusing
# "407 (Proxy Authentication Required)" error, since PowerShell doesn't
# send proxy credentials automatically the way a browser does. Harmless
# if there's no proxy in the way, or it doesn't need credentials - this
# only does anything on a network that specifically needs it.
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
[System.Net.WebRequest]::DefaultWebProxy = $proxy

# A short pause between requests, in seconds, so these scripts don't
# hammer the Confluence server with requests as fast as possible.
$RequestDelaySeconds = 0.3
# How many times to retry a failed request, and how long to wait before
# the first retry (each retry after that waits twice as long).
$RetryMaxAttempts = 3
$RetryBaseDelaySeconds = 1.0

# --- Asking questions ---

function Read-HostWithHelp {
    # Like Read-Host, but typing a bare "?" prints an explanation of what's
    # being asked for instead of being treated as the actual answer, then
    # asks again - so someone new to this doesn't have to already know what
    # to type before they can find out.
    param([string]$Prompt, [string[]]$HelpText)
    while ($true) {
        $answer = Read-Host $Prompt
        if ("$answer".Trim() -ne "?") {
            return $answer
        }
        foreach ($line in $HelpText) {
            Write-Host $line
        }
    }
}

function Read-PasswordWithHelp {
    # Asks for a password with the on-screen characters hidden (shows *****
    # instead of what's actually typed), then unscrambles it back into
    # normal text for just long enough to use it. Held in memory only,
    # never written to disk or displayed on screen.
    param([string]$Prompt, [string[]]$HelpText)
    while ($true) {
        $securePassword = Read-Host $Prompt -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

        # Password input is masked, so typing "?" isn't visibly different
        # from typing anything else - only found out here, after decoding.
        if ($password -ne "?") {
            return $password
        }
        foreach ($line in $HelpText) {
            Write-Host $line
        }
    }
}

function Read-YesNo {
    # Anything other than "y" (including just pressing Enter) counts as
    # no, so the safe answer is always the default.
    param([string]$Prompt)
    return (Read-Host "$Prompt (y/N)").Trim().ToLower() -eq "y"
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

$BaseUrlHelp = @(
    "The address of your Confluence site, with no slash on the end. Copy it",
    "from your browser's address bar while viewing any Confluence page,",
    "keeping only the part before /display/ or /spaces/, e.g.",
    "https://confluence.yourcompany.com - if there's something in between",
    "(like /wiki or /confluence), keep that too."
)

function Read-BaseUrl {
    # The Confluence site address - CONFLUENCE_BASE_URL, then the one saved
    # with the export (if there is one), then asked. Asked every run rather
    # than hardcoded, so there's nothing identifying your Confluence in any
    # of these files to accidentally commit or share. Any slash on the end
    # is dropped, since every address built from this adds its own.
    param([string]$SavedValue)
    return (Get-EnvSavedOrAsk $env:CONFLUENCE_BASE_URL $SavedValue "Confluence base URL" $BaseUrlHelp).Trim().TrimEnd('/')
}

function Read-ExportDir {
    # Which export folder to work on - whatever was passed to the script
    # (-ExportDir) if anything, then CONFLUENCE_EXPORT_DIR, then asked.
    # Explorer's "Copy as path" and dragging a folder into the window both
    # wrap the path in quotes, so those are stripped and either works.
    param([string]$Value, [string]$Prompt, [string[]]$HelpText, [string]$Default = "confluence_export")
    if (-not $Value) {
        $Value = if ($env:CONFLUENCE_EXPORT_DIR) { $env:CONFLUENCE_EXPORT_DIR } else { Read-HostWithHelp $Prompt $HelpText }
    }
    $Value = $Value.Trim().Trim('"').Trim("'")
    if (-not $Value) { $Value = $Default }
    return $Value
}

function Get-SuggestedOutputDir {
    # A matching output folder name for an export folder - with -Prefix
    # "confluence_markdown_export", confluence_export_TEAM becomes
    # confluence_markdown_export_TEAM - so converting a second space's
    # export lands in its own folder instead of merging into (and
    # overwriting) the first one's.
    param([string]$ExportDir, [string]$Prefix)
    if ($ExportDir -eq "confluence_export") {
        return $Prefix
    }
    if ($ExportDir.StartsWith("confluence_export")) {
        return $Prefix + $ExportDir.Substring("confluence_export".Length)
    }
    return "${Prefix}_$ExportDir"
}

# --- Reading and writing files ---

function Read-Utf8Text {
    # Read as UTF-8 explicitly: Windows PowerShell 5.1 otherwise assumes the
    # old Windows character set, garbling any page title with an accent or
    # curly quote.
    param([string]$Path)
    return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.Encoding]::UTF8)
}

function Read-JsonFile {
    # A JSON file read as UTF-8 (see Read-Utf8Text). A JSON list with
    # exactly one thing in it comes back as that one thing rather than a
    # list - wrap the call in @() wherever a list is expected.
    param([string]$Path)
    return (Read-Utf8Text $Path | ConvertFrom-Json)
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

# --- Reading an export folder ---

function Get-ExportManifest {
    # An export folder's manifest.json (the extractor's list of every page
    # it saved), as .Manifest, and where it was read from, as .Path - or a
    # plain explanation and stop, if the folder or the manifest isn't
    # there. Checked before anything else is asked, so a mistyped folder
    # doesn't cost you typing your password first.
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Host "Can't find '$Dir' from here - run this from the folder"
        Write-Host "that contains it, or give its full path instead."
        exit 1
    }
    $manifestPath = Join-Path $Dir "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Host "No manifest.json in '$Dir' - that's written by"
        Write-Host "confluence_extractor.ps1 once it finishes, so either the"
        Write-Host "extraction hasn't been run yet, or this is pointed at the"
        Write-Host "wrong folder."
        exit 1
    }
    # @()-wrapped: a manifest can legitimately have exactly one page (the
    # extractor's single-page mode), and ConvertFrom-Json hands back a bare
    # object instead of a one-item list for that.
    return @{ Manifest = @(Read-JsonFile $manifestPath); Path = $manifestPath }
}

function Save-ExportSource {
    # Where an export came from, saved into the export folder so the other
    # scripts can pick it up instead of asking for the site address and
    # space key again. Never any login details.
    param([string]$Dir, [string]$BaseUrl, [string]$SpaceKey, [string]$PageId)
    $source = [PSCustomObject]@{ baseUrl = $BaseUrl.TrimEnd('/'); spaceKey = $SpaceKey; pageId = $PageId }
    Set-Utf8NoBomContent -Path (Join-Path $Dir "export_source.json") -Value (ConvertTo-Json -InputObject $source)
}

function Get-ExportSource {
    # What Save-ExportSource saved (site address and space key). Exports
    # made before that file existed still have the same details on the
    # "- Source:" line of their README.md, so fall back to reading that.
    param([string]$Dir)
    $sourcePath = Join-Path $Dir "export_source.json"
    if (Test-Path -LiteralPath $sourcePath) {
        try {
            $source = Read-JsonFile $sourcePath
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

function Get-UserDisplayNames {
    # Loads the userkey/username -> real name lookup table the extractor
    # built, if one exists (older exports won't have this file at all,
    # which is fine - @mentions just show the raw ID instead).
    param([string]$Dir)
    $path = Join-Path $Dir "user_display_names.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return @{}
    }
    $map = @{}
    $data = Read-JsonFile $path
    foreach ($property in $data.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }
    return $map
}

function Get-AttachmentMap {
    # Turns one page's "attachments" manifest entry into a simple lookup:
    # original Confluence filename -> whatever it actually got saved as
    # on disk (they differ when a name had characters Windows won't allow,
    # or was too long).
    param($attachments)

    $map = @{}
    foreach ($entry in $attachments) {
        if ($entry.PSObject.Properties.Match("filename").Count -gt 0 -and $entry.PSObject.Properties.Match("saved_as").Count -gt 0) {
            $map[$entry.filename] = $entry.saved_as
        }
        else {
            # Manifest from before this mapping existed: the saved filename
            # was assumed to match the original one-for-one, which is the
            # best we can do without re-extracting.
            $map[[string]$entry] = [string]$entry
        }
    }
    return $map
}

function Get-NormalisedRelativePath {
    # A manifest "folder" value looks like "pages\123_Title", written on the
    # assumption it'll be read back on Windows. Swap in whatever this
    # machine actually uses before joining it onto a path, so these scripts
    # also work if they're ever run from Mac/Linux against a copied export.
    param([string]$RelativePath)
    return $RelativePath.Replace('\', [System.IO.Path]::DirectorySeparatorChar).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
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

function Write-IssueSummary {
    # One heading with a count, then the first few items under it - the
    # rest are in the saved report, so a long list doesn't scroll the
    # summary off the screen.
    param([string]$Label, [array]$Items, [string]$ReportName, [int]$ShowMax = 15)
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
        Write-Host "    ... and $($Items.Count - $ShowMax) more (full list in $ReportName)"
    }
}

# --- Confluence's page HTML ("storage format") ---

# Confluence storage format uses ac: and ri: prefixed elements (macros,
# images, attachment references) alongside plain XHTML. These namespaces
# get declared around each page before parsing it, so the XML parser
# doesn't choke on them.
$namespaceDeclarations = @'
xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/"
xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/"
'@

# The named HTML entities Confluence content actually tends to contain,
# almost always from something pasted out of Word/Outlook. XML only
# understands &amp; &lt; &gt; &apos; &quot;, so any of these left in the
# page crash the XML parser on an otherwise perfectly fine page. If a page
# still fails to convert because of some other named entity, the error
# message names it, just add it here. Values are [char] codepoints rather
# than the literal character, so there's no risk of a stray non-breaking
# space or curly quote sneaking into this file looking identical to a
# normal one.
$knownHtmlEntities = @{
    "nbsp"   = [char]0x0020   # a plain space, on purpose, not U+00A0
    "mdash"  = [char]0x2014
    "ndash"  = [char]0x2013
    "hellip" = [char]0x2026
    "lsquo"  = [char]0x2018
    "rsquo"  = [char]0x2019
    "ldquo"  = [char]0x201C
    "rdquo"  = [char]0x201D
    "trade"  = [char]0x2122
    "copy"   = [char]0x00A9
    "reg"    = [char]0x00AE
}

function ConvertTo-XmlSafeEntities {
    # Swaps known HTML entities for the real character they stand for, so
    # the XML parser doesn't choke on them.
    param([string]$RawHtml)

    $result = $RawHtml
    foreach ($name in $knownHtmlEntities.Keys) {
        $result = $result.Replace("&$name;", $knownHtmlEntities[$name])
    }
    return $result
}

# --- Talking to Confluence ---

function New-ConfluenceConnection {
    # One connection to a Confluence site: the address and how to log in,
    # so each script just asks for what it wants (Invoke-ConfluenceApi,
    # Get-AllResults, Save-ConfluenceFile) instead of building requests
    # itself. Asks for your username and password here (or picks them up
    # from CONFLUENCE_USERNAME / CONFLUENCE_PASSWORD) - unless
    # -UseDefaultCredentials, which uses your current Windows login instead.
    param([string]$BaseUrl, [switch]$UseDefaultCredentials)

    if ($UseDefaultCredentials) {
        Write-Host "Using your current Windows login instead of a separate username/password."
        # No Authorization header needed - every request passes
        # -UseDefaultCredentials instead, which negotiates using the
        # Windows login directly, the same thing a browser does.
        $headers = @{ Accept = "application/json" }
    }
    else {
        $usernameHelp = @(
            "This is the same username you use to log into Confluence in your",
            "web browser - usually your email address or your company username.",
            "If you're not sure, open Confluence in a browser first and check",
            "what you log in with there."
        )
        $username = if ($env:CONFLUENCE_USERNAME) { $env:CONFLUENCE_USERNAME } else { Read-HostWithHelp "Confluence username" $usernameHelp }
        $passwordHelp = @(
            "This is the same password you use to log into Confluence in your",
            "web browser. It's masked as you type (you won't see the characters",
            "appear) - that's normal, just type it and press Enter."
        )
        $password = if ($env:CONFLUENCE_PASSWORD) { $env:CONFLUENCE_PASSWORD } else { Read-PasswordWithHelp "Confluence password" $passwordHelp }

        # "Basic Auth": username:password joined together, then converted
        # into Base64 text - encoding, not encryption, so always use an
        # https:// address so it travels over an encrypted connection.
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$($username):$($password)")
        $headers = @{
            Authorization = "Basic $([System.Convert]::ToBase64String($bytes))"
            Accept        = "application/json"
        }
    }

    return [PSCustomObject]@{
        BaseUrl               = $BaseUrl.TrimEnd('/')
        Headers               = $headers
        UseDefaultCredentials = [bool]$UseDefaultCredentials
    }
}

function Connect-Confluence {
    # Asks for (or picks up) the site address and login, and hands back a
    # ready-to-use connection - the same questions, in the same order, in
    # every script that talks to Confluence.
    param([string]$SavedBaseUrl, [switch]$UseDefaultCredentials)
    $baseUrl = Read-BaseUrl -SavedValue $SavedBaseUrl
    return New-ConfluenceConnection -BaseUrl $baseUrl -UseDefaultCredentials:$UseDefaultCredentials
}

function Get-ConfluenceUrl {
    # A full address from a path like /rest/api/content - or a full address
    # already (download links sometimes are) left as it is.
    param($Connection, [string]$Uri)
    if ($Uri -like "http*") { return $Uri }
    return "$($Connection.BaseUrl)$Uri"
}

function Invoke-WithRetry {
    # Retries an action on connection errors or 5xx responses (transient
    # issues), but not on 4xx errors (bad credentials/permissions won't fix
    # themselves by retrying). Without this, a single flaky moment mid-run
    # (e.g. fetching page 300 of 500) aborts the whole script.
    param([scriptblock]$Action)

    for ($attempt = 1; $attempt -le $RetryMaxAttempts; $attempt++) {
        try {
            # If it works, we're done - hand back its result immediately.
            return & $Action
        }
        catch {
            # A "won't get better if we try again" problem (4xx, e.g. wrong
            # password), or out of attempts - give up and let the error
            # bubble up to whoever called this.
            $statusCode = $_.Exception.Response.StatusCode.value__
            $isClientError = $statusCode -and $statusCode -lt 500
            if ($isClientError -or $attempt -eq $RetryMaxAttempts) {
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
    # One request to Confluence's REST API, handed back as a PowerShell
    # object. No retrying - wrap it in Invoke-WithRetry for that.
    #
    # Invoke-RestMethod guesses the response encoding from the Content-Type
    # header, and falls back to ISO-8859-1 when no charset is present -
    # Confluence's REST API often omits one. That silently mangles every
    # non-ASCII character (smart quotes, en/em dashes, accents) into
    # garbled text. Fetch the raw bytes instead and decode as UTF-8 here.
    param($Connection, [string]$Uri)

    $url = Get-ConfluenceUrl $Connection $Uri
    if ($Connection.UseDefaultCredentials) {
        $response = Invoke-WebRequest -Uri $url -Headers $Connection.Headers -Method Get -UseBasicParsing -UseDefaultCredentials
    }
    else {
        $response = Invoke-WebRequest -Uri $url -Headers $Connection.Headers -Method Get -UseBasicParsing
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
    return [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
}

function Get-AllResults {
    # Every result from a listing (pages in a space, attachments on a page),
    # a batch at a time. $Query is everything after the "?" except
    # start/limit. Stops on an EMPTY batch, not a short one, and moves on by
    # however many actually came back rather than by -Limit. Some
    # Confluence setups quietly hand back fewer than asked for (a
    # server-side cap on batch size), and treating that as "last batch" -
    # or skipping ahead by the full limit - would silently miss the rest.
    # -OnBatch is run before each request with the start position, for
    # showing progress.
    param($Connection, [string]$Path, [string]$Query, [int]$Limit = 50, [double]$DelaySeconds = 0, [scriptblock]$OnBatch)
    $all = @()
    $start = 0
    $separator = if ($Query) { "&" } else { "" }
    while ($true) {
        if ($OnBatch) { & $OnBatch $start }
        $uri = "$Path`?$Query${separator}start=$start&limit=$Limit"
        $data = Invoke-WithRetry { Invoke-ConfluenceApi -Connection $Connection -Uri $uri }
        # @()-wrapped - a batch of exactly one would otherwise come back as
        # a bare object.
        $batch = @($data.results | Where-Object { $_ })
        if ($batch.Count -eq 0) {
            return $all
        }
        $all += $batch
        $start += $batch.Count
        if ($DelaySeconds) { Start-Sleep -Seconds $DelaySeconds }
    }
}

function Save-ConfluenceFile {
    # Downloads one file (an attachment) straight to disk, retrying the
    # same way as everything else, and logged in the same way as every
    # other request.
    param($Connection, [string]$Url, [string]$OutFile)
    $fullUrl = Get-ConfluenceUrl $Connection $Url
    if ($Connection.UseDefaultCredentials) {
        Invoke-WithRetry { Invoke-WebRequest -Uri $fullUrl -Headers $Connection.Headers -OutFile $OutFile -UseBasicParsing -UseDefaultCredentials }
    }
    else {
        Invoke-WithRetry { Invoke-WebRequest -Uri $fullUrl -Headers $Connection.Headers -OutFile $OutFile -UseBasicParsing }
    }
}

function Test-ConfluenceSignIn {
    # Says who Confluence thinks you are, and warns if that's nobody.
    #
    # Some setups let you in as an anonymous visitor rather than turning the
    # login away - -UseDefaultCredentials in particular can end up that way.
    # You still get every page anyone can see, but anything that needs a
    # login is quietly left out, and nothing else notices (the checking
    # scripts are anonymous too, so they can't see those pages either).
    # Asks whether to carry on rather than stopping, since an anonymous run
    # of an open space can still be what you want. Running unattended (no
    # keyboard to answer), or with CONFLUENCE_ALLOW_ANONYMOUS set, it just
    # warns and carries on.
    param($Connection)
    try {
        $me = Invoke-WithRetry { Invoke-ConfluenceApi -Connection $Connection -Uri "/rest/api/user/current" }
    }
    catch {
        # Older Confluence, or not allowed to ask - nothing to go on, and
        # not a reason to stop.
        return
    }
    if ($me.type -ne "anonymous") {
        $name = if ($me.displayName) { $me.displayName } elseif ($me.username) { $me.username } else { "unknown" }
        Write-Host "Signed in to Confluence as: $name"
        return
    }
    Write-Host ""
    Write-Host "WARNING: Confluence doesn't know who you are - you're connected as an"
    Write-Host "anonymous visitor, so your login wasn't used. Only pages anyone can see"
    Write-Host "without logging in will come through; anything that needs a login is"
    Write-Host "left out without any error, and the checking scripts can't spot it."
    if ($Connection.UseDefaultCredentials) {
        Write-Host "Try again without -UseDefaultCredentials, typing your username and"
        Write-Host "password instead (see the README)."
    }
    else {
        Write-Host "Check your username and password, or try -UseDefaultCredentials"
        Write-Host "instead (see the README)."
    }
    if ($env:CONFLUENCE_ALLOW_ANONYMOUS -or [Console]::IsInputRedirected) {
        Write-Host "Carrying on anyway.`n"
        return
    }
    if (-not (Read-YesNo "Carry on anyway?")) {
        exit 1
    }
    Write-Host ""
}

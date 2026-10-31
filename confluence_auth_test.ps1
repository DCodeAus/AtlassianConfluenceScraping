<#
Step 1: Test Confluence Server/Data Center REST API access.
Native PowerShell version, no Python required.

Run it, it'll ask for your Confluence site address, space key, and login:
    .\confluence_auth_test.ps1

If PowerShell blocks it with a "running scripts is disabled" error, see the
note at the very bottom of this file.

If it prints a page title, you're good to move to the full extractor.

Get a 401 error mentioning SSO? Some Confluence setups log you in via your
Windows login automatically (Integrated Windows Authentication) rather than
a separate username/password. Try again with:
    .\confluence_auth_test.ps1 -UseDefaultCredentials
That skips the username/password prompts entirely and uses your current
Windows login instead.

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

Something broken or unclear? Raise an issue at
https://github.com/DCodeAus/AtlassianConfluenceScraping/issues
#>

param(
    # Pass this if your organisation logs you into things automatically via
    # your Windows login rather than a separate Confluence username and
    # password. Skips the prompts below entirely and uses your current
    # Windows login instead. Not sure which applies to you? Just run this
    # once without it first - if that fails with a 401 mentioning SSO,
    # that's the sign to try this instead.
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

# Asked every run rather than hardcoded, so there's nothing identifying
# your Confluence instance sitting in this file to accidentally commit or
# share. Set CONFLUENCE_BASE_URL for unattended runs, same idea as the
# credentials further down.
$BaseUrl = Read-BaseUrl

# Set CONFLUENCE_SPACE_KEY for unattended runs.
$spaceKeyHelp = @(
    "The short code for the specific space you want to read. Find it in",
    "a page's URL while browsing Confluence, right after /display/ or",
    "/spaces/ depending on which URL style your Confluence uses:",
    "  .../display/ABC/Page+Title                -> space key is 'ABC'",
    "  .../spaces/ABC/pages/123456789/Page+Title  -> space key is 'ABC'"
)
$SpaceKey = if ($env:CONFLUENCE_SPACE_KEY) { $env:CONFLUENCE_SPACE_KEY } else { (Read-HostWithHelp "Confluence space key" $spaceKeyHelp).Trim() }

# Username and password are asked for at runtime rather than hardcoded,
# so this file is safe to share without exposing credentials. If you're
# automating this (e.g. a scheduled job), set CONFLUENCE_USERNAME and
# CONFLUENCE_PASSWORD as environment variables instead and the prompts
# below are skipped - and with -UseDefaultCredentials there's no separate
# login to ask for at all.

$Connection = New-ConfluenceConnection -BaseUrl $BaseUrl -UseDefaultCredentials:$UseDefaultCredentials
# $headers is the extra information sent along with the request, telling
# Confluence who's asking (Authorization, unless -UseDefaultCredentials)
# and what format we'd like the answer in (Accept: JSON, a common data
# format).
$headers = $Connection.Headers

# Build the actual web address we're going to ask for: give me content
# from this space, just 1 result, and include each page's stored content.
$uri = "$BaseUrl/rest/api/content?spaceKey=$SpaceKey&limit=1&expand=body.storage"

# try/catch means: attempt the request, and if anything goes wrong,
# don't crash - jump down to the "catch" block below and explain what
# happened in plain English instead.
try {
    # Invoke-RestMethod actually sends the web request and waits for
    # Confluence to answer, then turns the JSON response into a regular
    # PowerShell object we can read properties off of. -UseDefaultCredentials
    # only gets added when that switch was actually passed - with no
    # separate login to send, this negotiates using the current Windows
    # login instead, the same thing a browser does automatically.
    if ($UseDefaultCredentials) {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -UseDefaultCredentials
    }
    else {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    }

    # $response.results is the list of pages Confluence sent back - if
    # login worked and the space key is right, there should be exactly 1
    # (since we asked for limit=1 above).
    if ($response.results.Count -gt 0) {
        Write-Host "Success! First page title:" $response.results[0].title
        Write-Host "Total pages in this batch (max 1 requested):" $response.size
        # Getting a page back doesn't prove the login was used - some setups
        # let you in as an anonymous visitor instead (-UseDefaultCredentials
        # in particular), which can still see open spaces. This says which
        # it was.
        Test-ConfluenceSignIn -Connection $Connection
    }
    else {
        # Login worked (no error was thrown) but Confluence returned zero
        # pages - almost always means the space key is wrong or empty.
        Write-Host "Connected, but no pages returned. Check SPACE_KEY is correct."
    }
}
catch {
    # Something went wrong with the request. $_.Exception carries the
    # details - specifically the HTTP status code, a standard number web
    # servers use to say what kind of problem occurred (401 = bad login,
    # 403 = valid login but no permission, etc).
    $statusCode = $_.Exception.Response.StatusCode.value__

    if ($statusCode -eq 401) {
        Write-Host "401 Unauthorized. Wrong username/password, OR your org requires SSO"
        Write-Host "and has disabled basic auth for the API. Try again with"
        Write-Host "-UseDefaultCredentials - see the top of this file."
    }
    elseif ($statusCode -eq 403) {
        Write-Host "403 Forbidden. Credentials are valid but you lack read access to this space."
    }
    elseif ($_.Exception.Message -like "*Unexpected character*parsing value*") {
        # No useful HTTP status code here either - Invoke-RestMethod got a
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
    elseif ($_.Exception.Message -like "*trust*" -or $_.Exception.Message -like "*SSL*" -or $_.Exception.Message -like "*certificate*") {
        # No HTTP status code at all here - the connection failed before
        # it even got that far, which is the signature of an SSL/certificate
        # problem rather than a login problem.
        Write-Host "SSL certificate error. Your internal CA cert likely isn't in the"
        Write-Host "Windows Trusted Root store yet. Import it via certmgr.msc, see"
        Write-Host "the running_python_scripts / cert export notes for steps, then"
        Write-Host "try again. No code change needed here once it's imported."
    }
    else {
        # Something else entirely - print whatever .NET's own error
        # message says, better than swallowing it silently.
        Write-Host "Unexpected error:"
        Write-Host $_.Exception.Message
    }
}

<#
NOTE on "running scripts is disabled on this system":
PowerShell blocks .ps1 files from running by default as a security measure.
If you hit this, run PowerShell as yourself (not admin) and set:

    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

Then confirm with Y. This only relaxes the restriction for scripts you
run yourself under your own account, it doesn't require admin rights.
#>

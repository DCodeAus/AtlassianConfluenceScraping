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

Supported by Daniel - raise issues with him.
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
# below are skipped. None of this section runs at all with
# -UseDefaultCredentials, since there's no separate login to ask for.

if ($UseDefaultCredentials) {
    Write-Host "Using your current Windows login instead of a separate username/password."
    # No Authorization header needed here - -UseDefaultCredentials further
    # down tells Invoke-RestMethod to negotiate using the Windows login
    # directly, the same thing your browser does automatically.
    $headers = @{
        Accept = "application/json"
    }
}
else {
    $usernameHelp = @(
        "This is the same username you use to log into Confluence in your",
        "web browser - usually your email address or your company username.",
        "If you're not sure, open Confluence in a browser first and check",
        "what you log in with there."
    )

    # $env:CONFLUENCE_USERNAME checks whether that environment variable is
    # already set on this computer. If it is, use it. If not, ask the person
    # running the script to type their username, right here in the terminal.
    $Username = if ($env:CONFLUENCE_USERNAME) { $env:CONFLUENCE_USERNAME } else { Read-HostWithHelp "Confluence username" $usernameHelp }

    # Same idea for the password, but passwords need extra care so they don't
    # end up sitting in plain text in memory or on screen any longer than
    # necessary.
    if ($env:CONFLUENCE_PASSWORD) {
        # An environment variable was already set (e.g. for an unattended
        # run) - just use it directly, no prompt needed.
        $Password = $env:CONFLUENCE_PASSWORD
    }
    else {
        while ($true) {
            # -AsSecureString means whatever's typed shows up as ***** on screen,
            # and PowerShell keeps it scrambled in memory rather than as plain
            # readable text - this is the "SecureString" object, not the actual
            # password yet.
            $SecurePassword = Read-Host "Confluence password" -AsSecureString
            # To actually USE the password (e.g. to build a login header), it has
            # to be unscrambled back into normal text for a moment. These next
            # three lines do exactly that, as briefly as possible:
            # 1. Get a temporary pointer to the unscrambled password in memory.
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
            # 2. Read the actual password text from that pointer.
            $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            # 3. Immediately wipe that temporary unscrambled copy from memory -
            #    don't leave a plain-text password sitting around any longer
            #    than needed.
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

    # Confluence's API expects login credentials sent as "Basic Auth": your
    # username and password joined with a colon, then encoded (not
    # encrypted - just reformatted) into a block of text called Base64.
    # Build the Basic Auth header manually (same approach as the Python version)
    # Join "username:password" into one piece of text.
    $pair = "$($Username):$($Password)"
    # Turn that text into raw bytes (computers work with the API in bytes,
    # not directly in text).
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    # Encode those bytes as Base64 text - this is what actually gets sent.
    $encodedCredentials = [System.Convert]::ToBase64String($bytes)

    # $headers is the extra information sent along with the request, telling
    # Confluence who's asking (Authorization) and what format we'd like the
    # answer in (Accept: JSON, a common data format).
    $headers = @{
        Authorization = "Basic $encodedCredentials"
        Accept        = "application/json"
    }
}

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

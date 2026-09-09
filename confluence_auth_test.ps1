<#
Step 1: Test Confluence Server/Data Center REST API access.
Native PowerShell version, no Python required.

Fill in the four values below, then run:
    .\confluence_auth_test.ps1

If PowerShell blocks it with a "running scripts is disabled" error, see the
note at the very bottom of this file.

If it prints a page title, you're good to move to the full extractor.

Written by Dan.
#>

# --- Fill these in ---
# $BaseUrl is the address of your Confluence site, with nothing after it
# (no trailing slash, and no /wiki or /pages on the end).
$BaseUrl  = "https://confluence.yourcompany.com"   # no trailing slash
# $SpaceKey is the short code for the specific space you want to read.
# You can find it in the URL when you're browsing Confluence in your
# browser, e.g. .../display/ABC/Page+Title means the space key is "ABC".
$SpaceKey = "ABC"                                    # find in the page URL, e.g. /display/ABC/Page+Title
# ---------------------

# Username and password are asked for at runtime rather than hardcoded,
# so this file is safe to share without exposing credentials. If you're
# automating this (e.g. a scheduled job), set CONFLUENCE_USERNAME and
# CONFLUENCE_PASSWORD as environment variables instead and the prompts
# below are skipped.

# $env:CONFLUENCE_USERNAME checks whether that environment variable is
# already set on this computer. If it is, use it. If not, ask the person
# running the script to type their username, right here in the terminal.
$Username = if ($env:CONFLUENCE_USERNAME) { $env:CONFLUENCE_USERNAME } else { Read-Host "Confluence username" }

# Same idea for the password, but passwords need extra care so they don't
# end up sitting in plain text in memory or on screen any longer than
# necessary.
if ($env:CONFLUENCE_PASSWORD) {
    # An environment variable was already set (e.g. for an unattended
    # run) - just use it directly, no prompt needed.
    $Password = $env:CONFLUENCE_PASSWORD
}
else {
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

# Build the actual web address we're going to ask for: give me content
# from this space, just 1 result, and include each page's stored content.
$uri = "$BaseUrl/rest/api/content?spaceKey=$SpaceKey&limit=1&expand=body.storage"

# try/catch means: attempt the request, and if anything goes wrong,
# don't crash - jump down to the "catch" block below and explain what
# happened in plain English instead.
try {
    # Invoke-RestMethod actually sends the web request and waits for
    # Confluence to answer, then turns the JSON response into a regular
    # PowerShell object we can read properties off of.
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

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
        Write-Host "and has disabled basic auth for the API."
    }
    elseif ($statusCode -eq 403) {
        Write-Host "403 Forbidden. Credentials are valid but you lack read access to this space."
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

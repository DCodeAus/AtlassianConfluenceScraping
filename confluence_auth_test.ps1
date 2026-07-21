<#
Step 1: Test Confluence Server/Data Center REST API access.
Native PowerShell version, no Python required.

Fill in the four values below, then run:
    .\confluence_auth_test.ps1

If PowerShell blocks it with a "running scripts is disabled" error, see the
note at the very bottom of this file.

If it prints a page title, you're good to move to the full extractor.
#>

# --- Fill these in ---
$BaseUrl  = "https://confluence.yourcompany.com"   # no trailing slash
$Username = "your.username"                         # same as browser login
$Password = "your-password"                          # same as browser login
$SpaceKey = "ABC"                                    # find in the page URL, e.g. /display/ABC/Page+Title
# ---------------------

# Build the Basic Auth header manually (same approach as the Python version)
$pair = "$($Username):$($Password)"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$encodedCredentials = [System.Convert]::ToBase64String($bytes)

$headers = @{
    Authorization = "Basic $encodedCredentials"
    Accept        = "application/json"
}

$uri = "$BaseUrl/rest/api/content?spaceKey=$SpaceKey&limit=1&expand=body.storage"

try {
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

    if ($response.results.Count -gt 0) {
        Write-Host "Success! First page title:" $response.results[0].title
        Write-Host "Total pages in this batch (max 1 requested):" $response.size
    }
    else {
        Write-Host "Connected, but no pages returned. Check SPACE_KEY is correct."
    }
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__

    if ($statusCode -eq 401) {
        Write-Host "401 Unauthorized. Wrong username/password, OR your org requires SSO"
        Write-Host "and has disabled basic auth for the API."
    }
    elseif ($statusCode -eq 403) {
        Write-Host "403 Forbidden. Credentials are valid but you lack read access to this space."
    }
    elseif ($_.Exception.Message -like "*trust*" -or $_.Exception.Message -like "*SSL*" -or $_.Exception.Message -like "*certificate*") {
        Write-Host "SSL certificate error. Your internal CA cert likely isn't in the"
        Write-Host "Windows Trusted Root store yet. Import it via certmgr.msc, see"
        Write-Host "the running_python_scripts / cert export notes for steps, then"
        Write-Host "try again. No code change needed here once it's imported."
    }
    else {
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

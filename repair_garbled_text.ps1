<#
Repairs text corrupted by the confluence_extractor.ps1 encoding bug (fixed
in Invoke-ConfluenceApi): PowerShell decoded Confluence's UTF-8 response
bytes as Windows-1252 before writing content.html, turning accents, curly
quotes, dashes etc. into garbage like "Ã©" or "â€™" or "Â ".

That mis-decode is a byte-for-byte, reversible mapping - re-encoding the
garbled text as Windows-1252 recovers the original UTF-8 bytes, which then
decode cleanly. This script does that to every already-extracted/converted
file, in place, so you don't have to re-pull the whole space from
Confluence. Only worth running against content produced by the .ps1
extractor before the fix - the Python extractor was never affected.

Run:
    .\repair_garbled_text.ps1
    .\repair_garbled_text.ps1 -Roots confluence_export, confluence_markdown_export

Defaults to confluence_export/ and confluence_markdown_export/ if -Roots
isn't given. Walks every .html and .md file under each root. Files that
aren't actually garbled are left untouched (the round-trip only succeeds
on genuinely corrupted text - see Repair-Text below). Each file it does
change gets a .bak backup alongside it first.
#>

# Which folders to scan. Defaults to both export folders if you don't
# specify your own - e.g. .\repair_garbled_text.ps1 -Roots some_other_folder
param(
    [string[]]$Roots = @("confluence_export", "confluence_markdown_export")
)

# Strict fallbacks so a failed round-trip throws instead of silently
# substituting '?' or U+FFFD - that failure is exactly how genuinely
# correct text (real accents, dashes, quotes) is told apart from garbled
# text and left alone.
try {
    # The encoding the bug actually used - loaded once up front, with
    # strict error handling so any character it can't cleanly convert
    # throws an error rather than silently getting mangled.
    $windows1252 = [System.Text.Encoding]::GetEncoding(
        1252,
        [System.Text.EncoderFallback]::ExceptionFallback,
        [System.Text.DecoderFallback]::ExceptionFallback)
}
catch {
    Write-Error "Couldn't load the Windows-1252 code page: $($_.Exception.Message)"
    exit 1
}
# The correct encoding, also with strict error handling for the same reason.
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

function Repair-Text {
    # Undoes one or more rounds of UTF-8 -> Windows-1252 mis-decoding. A
    # genuine mis-decode always expands the text (each original multi-byte
    # UTF-8 character becomes several single-byte cp1252 characters), so a
    # real repair pass strictly shortens it. Re-encoding to Windows-1252
    # throws on any character outside its repertoire, which is exactly what
    # happens to correctly-decoded prose containing real accents/dashes/
    # quotes - that's what keeps this from mangling text that was never
    # broken.
    #
    # Runs more than one pass to handle content that went through the buggy
    # pipeline twice, stopping as soon as a pass fails or stops helping.
    param([string]$Text, [int]$MaxPasses = 4)

    $current = $Text
    $passes = 0

    # Keep trying to "un-garble" the text, up to $MaxPasses times.
    for ($i = 0; $i -lt $MaxPasses; $i++) {
        try {
            # Re-encode the (possibly garbled) text as Windows-1252 bytes,
            # then read those same bytes back as UTF-8 - if the text really
            # was garbled this way, this recovers the original characters.
            $bytes = $windows1252.GetBytes($current)
            $candidate = $strictUtf8.GetString($bytes)
        }
        catch {
            # This text contains a character Windows-1252 can't represent
            # at all - a strong sign it was never actually garbled in the
            # first place. Stop here and keep whatever we had before this
            # attempt.
            break
        }

        if ($candidate.Length -ge $current.Length) {
            # A real repair pass always makes the text shorter (see the
            # explanation above) - if it didn't get shorter, this pass
            # didn't actually fix anything, so stop.
            break
        }

        # Genuine improvement - keep it, and see if another pass helps
        # further (content that got garbled twice needs two passes).
        $current = $candidate
        $passes++
    }

    return @{ Text = $current; Passes = $passes }
}

# Build the full list of .html and .md files to check, across every
# folder given in $Roots.
$files = @()
foreach ($root in $Roots) {
    if (-not (Test-Path $root)) {
        Write-Host "Skipping $root, doesn't exist."
        continue
    }
    $files += Get-ChildItem -Path $root -Recurse -Include "*.html", "*.md" -File
}

if ($files.Count -eq 0) {
    Write-Host ("No .html or .md files found under: " + ($Roots -join ", "))
    return
}

$fixedCount = 0
# Any file that can't even be read as valid UTF-8 gets noted here rather
# than stopping the whole run.
$unreadable = @()

# Check every file, one at a time (sorted just so the output prints in a
# predictable, easy-to-follow order).
foreach ($file in ($files | Sort-Object FullName)) {
    try {
        $original = [System.IO.File]::ReadAllText($file.FullName, $strictUtf8)
    }
    catch {
        $unreadable += "$($file.FullName): $($_.Exception.Message)"
        continue
    }

    $result = Repair-Text -Text $original
    if ($result.Passes -eq 0) {
        # Nothing needed fixing in this file - leave it alone entirely,
        # don't even touch its last-modified time.
        continue
    }

    # Back up the original before overwriting it, so it's always
    # possible to get back to exactly what was there before.
    $backupPath = "$($file.FullName).bak"
    if (-not (Test-Path $backupPath)) {
        Copy-Item -Path $file.FullName -Destination $backupPath
    }

    [System.IO.File]::WriteAllText($file.FullName, $result.Text, $strictUtf8)
    $fixedCount++
    $passLabel = if ($result.Passes -ne 1) { "passes" } else { "pass" }
    Write-Host "Fixed ($($result.Passes) $passLabel): $($file.FullName)"
}

Write-Host ""
Write-Host "Done. Fixed $fixedCount of $($files.Count) file(s)."
if ($fixedCount -gt 0) {
    Write-Host "Originals saved next to each as *.bak - spot-check a few repaired"
    Write-Host "files, then delete the .bak files once you're happy with them."
}
if ($unreadable.Count -gt 0) {
    Write-Host ""
    Write-Host "$($unreadable.Count) file(s) couldn't even be read as UTF-8, skipped:"
    foreach ($warning in $unreadable) {
        Write-Host "  - $warning"
    }
}

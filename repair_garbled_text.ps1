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
    $windows1252 = [System.Text.Encoding]::GetEncoding(
        1252,
        [System.Text.EncoderFallback]::ExceptionFallback,
        [System.Text.DecoderFallback]::ExceptionFallback)
}
catch {
    Write-Error "Couldn't load the Windows-1252 code page: $($_.Exception.Message)"
    exit 1
}
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

# Every character Windows-1252 can actually represent (one per byte value,
# 0-255). Anything not in this set - an emoji, a tick mark, a name in
# another script - was never touched by the mis-decode bug in the first
# place, since that bug only ever produces cp1252 characters. Knowing this
# up front lets Repair-Text step around such characters instead of one of
# them silently blocking the repair for a whole file.
$encodableChars = [System.Collections.Generic.HashSet[char]]::new()
for ($byteValue = 0; $byteValue -le 255; $byteValue++) {
    [void]$encodableChars.Add($windows1252.GetString(@([byte]$byteValue))[0])
}

function Split-EncodableRuns {
    # Breaks text into alternating runs of "every character here is
    # something Windows-1252 can represent" and "this run has at least one
    # character that isn't" - so the caller can round-trip the former
    # without one stray character in the latter aborting everything.
    param([string]$Text)

    $runs = [System.Collections.Generic.List[object]]::new()
    if ($Text.Length -eq 0) {
        return , $runs
    }

    $runStart = 0
    $runIsEncodable = $encodableChars.Contains($Text[0])
    for ($pos = 1; $pos -lt $Text.Length; $pos++) {
        $isEncodable = $encodableChars.Contains($Text[$pos])
        if ($isEncodable -ne $runIsEncodable) {
            $runs.Add(@{ Text = $Text.Substring($runStart, $pos - $runStart); Encodable = $runIsEncodable })
            $runStart = $pos
            $runIsEncodable = $isEncodable
        }
    }
    $runs.Add(@{ Text = $Text.Substring($runStart); Encodable = $runIsEncodable })
    return , $runs
}

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

    for ($i = 0; $i -lt $MaxPasses; $i++) {
        $rebuilt = New-Object System.Text.StringBuilder
        $anyRunImproved = $false

        foreach ($run in (Split-EncodableRuns -Text $current)) {
            if (-not $run.Encodable) {
                # Can't have come from the mis-decode bug - pass it through
                # untouched rather than letting it block the runs around it.
                [void]$rebuilt.Append($run.Text)
                continue
            }

            try {
                # Re-encode this run as Windows-1252 bytes, then read those
                # same bytes back as UTF-8 - if it really was garbled this
                # way, this recovers the original characters.
                $bytes = $windows1252.GetBytes($run.Text)
                $candidate = $strictUtf8.GetString($bytes)
            }
            catch {
                # Not valid UTF-8 once re-encoded - this run was never
                # actually garbled. Keep it as-is.
                [void]$rebuilt.Append($run.Text)
                continue
            }

            if ($candidate.Length -lt $run.Text.Length) {
                # A real repair pass always makes the text shorter (see the
                # explanation above) - keep the improvement.
                [void]$rebuilt.Append($candidate)
                $anyRunImproved = $true
            }
            else {
                [void]$rebuilt.Append($run.Text)
            }
        }

        if (-not $anyRunImproved) {
            # Nothing left to fix anywhere in this pass - stop.
            break
        }

        # See if another pass helps further (content that got garbled
        # twice needs two passes).
        $current = $rebuilt.ToString()
        $passes++
    }

    return @{ Text = $current; Passes = $passes }
}

# Say exactly where this is about to look, before doing anything -
# otherwise the only feedback is a final "Fixed 0 of 0 files," which
# looks identical whether nothing needed fixing or this just ran from
# the wrong folder and found nothing at all.
Write-Host "Looking for garbled .html/.md files in:"
foreach ($root in $Roots) {
    $note = if (Test-Path $root) { "" } else { "  <- doesn't exist, skipping" }
    # Resolve-Path only works on a folder that actually exists - fall back
    # to just showing where it would be, relative to the current folder,
    # so a missing path still prints something useful instead of erroring.
    $resolved = Resolve-Path -Path $root -ErrorAction SilentlyContinue
    $displayPath = if ($resolved) { $resolved.Path } else { Join-Path (Get-Location) $root }
    Write-Host "  $displayPath$note"
}
Write-Host ""

$files = @()
foreach ($root in $Roots) {
    if (-not (Test-Path $root)) {
        continue
    }
    $files += Get-ChildItem -Path $root -Recurse -Include "*.html", "*.md" -File
}

if ($files.Count -eq 0) {
    Write-Host "No .html or .md files found in the folder(s) above."
    Write-Host "If your confluence_export/confluence_markdown_export folders are"
    Write-Host "somewhere else, either run this script from that location instead,"
    Write-Host "or pass the path(s) directly, e.g.:"
    Write-Host "    .\repair_garbled_text.ps1 -Roots C:\path\to\confluence_export"
    return
}

# Telltale leftovers of this mis-decode bug that Repair-Text couldn't (or
# didn't) resolve - "Ã" and "â€" are how it mangles most accented letters
# and curly quotes/dashes, "Â" is what it leaves in front of a stray
# non-breaking space, and U+FFFD is what shows up if a file got corrupted
# badly enough that even a correct decode can't recover real characters.
# Real text occasionally contains a genuine "Â" or "Ã" (e.g. French), so a
# hit here is a "go take a look", not proof the file is still broken.
$suspiciousLeftovers = [regex]("Ã|Â|â€|" + [char]0xFFFD)

$fixedCount = 0
# Any file that can't even be read as valid UTF-8 gets noted here rather
# than stopping the whole run.
$unreadable = @()
$stillSuspicious = @()

# Sorted just so the output prints in a predictable order.
foreach ($file in ($files | Sort-Object FullName)) {
    try {
        $original = [System.IO.File]::ReadAllText($file.FullName, $strictUtf8)
    }
    catch {
        $unreadable += "$($file.FullName): $($_.Exception.Message)"
        continue
    }

    $result = Repair-Text -Text $original
    $finalText = if ($result.Passes -gt 0) { $result.Text } else { $original }

    if ($result.Passes -gt 0) {
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

    # Health check: whether this file got fixed, partially fixed, or left
    # alone, does what's actually on disk now still look garbled? Catches
    # the cases Repair-Text can't resolve on its own (like a corrupted
    # character that got altered further by something else before this
    # script ever saw it).
    $match = $suspiciousLeftovers.Match($finalText)
    if ($match.Success) {
        $start = [Math]::Max(0, $match.Index - 20)
        $end = [Math]::Min($finalText.Length, $match.Index + $match.Length + 20)
        $stillSuspicious += @{ File = $file.FullName; Snippet = $finalText.Substring($start, $end - $start) }
    }
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
if ($stillSuspicious.Count -gt 0) {
    Write-Host ""
    Write-Host "Health check: $($stillSuspicious.Count) file(s) still contain something"
    Write-Host "that looks like leftover garbled text (or, occasionally, genuine"
    Write-Host "accented text that just happens to match - worth a quick look either way):"
    foreach ($entry in $stillSuspicious) {
        Write-Host "  - $($entry.File)"
        Write-Host "      ...$($entry.Snippet)..."
    }
    Write-Host ""
    Write-Host "Recommended next step: re-extract just these pages from Confluence"
    Write-Host "(confluence_extractor.ps1 -PageId <id>, or by title) rather than"
    Write-Host "editing them by hand - the original bytes for these ones are gone,"
    Write-Host "so this is the only way to get the real text back."
    Write-Host ""
    Write-Host "If you'd rather not re-extract, most of these are a stray leftover"
    Write-Host "character next to a space that's safe to just delete - but that's a"
    Write-Host "guess, not a certainty, so it's not done automatically. To live"
    Write-Host "dangerously and strip these leftover characters from the file(s)"
    Write-Host "above right now, type YOLO and press Enter. Anything else leaves"
    Write-Host "them untouched."
    $confirmation = Read-Host "Strip leftover characters"
    if ($confirmation -ceq "YOLO") {
        foreach ($entry in $stillSuspicious) {
            $strippedBackupPath = "$($entry.File).stripped.bak"
            $currentContent = [System.IO.File]::ReadAllText($entry.File, $strictUtf8)
            if (-not (Test-Path $strippedBackupPath)) {
                Copy-Item -Path $entry.File -Destination $strippedBackupPath
            }
            $stripped = $suspiciousLeftovers.Replace($currentContent, "")
            [System.IO.File]::WriteAllText($entry.File, $stripped, $strictUtf8)
            Write-Host "Stripped: $($entry.File)"
        }
        Write-Host "Done. Pre-strip versions saved as *.stripped.bak."
    }
    else {
        Write-Host "Left untouched."
    }
}

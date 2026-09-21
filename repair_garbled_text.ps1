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
    .\repair_garbled_text.ps1 -Force

Defaults to confluence_export/ and confluence_markdown_export/ if -Roots
isn't given. Walks every .html and .md file under each root. Files that
aren't actually garbled are left untouched (the round-trip only succeeds
on genuinely corrupted text - see Repair-Text below). Each file it does
change gets a .bak backup alongside it first.

If a file still looks garbled afterwards (the original bytes are gone,
usually because something altered them further before this script ever
saw them), -Force additionally offers to strip the leftover character -
a safe-looking guess, not a guaranteed fix, which is why it's opt-in and
requires both -Force AND typing "YOLO" when asked. Every file it strips
gets logged, with a snippet and timestamp, to
garbled_text_repair_log.json.
#>

# Which folders to scan. Defaults to both export folders if you don't
# specify your own - e.g. .\repair_garbled_text.ps1 -Roots some_other_folder.
# -Force additionally allows stripping leftover unrepairable characters -
# see the health check section near the bottom of this script.
param(
    [string[]]$Roots = @("confluence_export", "confluence_markdown_export"),
    [switch]$Force
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

function ConvertFrom-Cp1252BytesPartial {
    # Decodes bytes as UTF-8, but a single byte sequence that doesn't form
    # a valid character (one genuinely unrecoverable spot, like a
    # non-breaking space whose second byte got altered before this script
    # ever saw it) doesn't have to block decoding everything else in the
    # same run - unlike GetString, which fails the whole thing on the
    # first bad sequence it hits. Whatever can't be decoded as UTF-8 is
    # kept in its original Windows-1252 form and decoding continues from
    # right after it.
    param([byte[]]$Bytes)

    $result = New-Object System.Text.StringBuilder
    $pos = 0
    while ($pos -lt $Bytes.Length) {
        try {
            [void]$result.Append($strictUtf8.GetChars($Bytes, $pos, $Bytes.Length - $pos))
            $pos = $Bytes.Length
        }
        catch [System.Text.DecoderFallbackException] {
            if ($_.Exception.Index -gt 0) {
                [void]$result.Append($strictUtf8.GetChars($Bytes, $pos, $_.Exception.Index))
            }
            $badStart = $pos + $_.Exception.Index
            $badLength = $_.Exception.BytesUnknown.Length
            [void]$result.Append($windows1252.GetChars($Bytes, $badStart, $badLength))
            $pos = $badStart + $badLength
        }
    }
    return $result.ToString()
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

            # Re-encode this run as Windows-1252 bytes, then read those same
            # bytes back as UTF-8 - if it really was garbled this way, this
            # recovers the original characters. Every character in this run
            # is Windows-1252-encodable by construction (see
            # Split-EncodableRuns), so GetBytes itself can't throw here.
            $bytes = $windows1252.GetBytes($run.Text)
            $candidate = ConvertFrom-Cp1252BytesPartial -Bytes $bytes

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
    # script ever saw it). Every matching spot is collected, not just the
    # first, so the summary below doesn't understate how many are there.
    $leftoverMatches = $suspiciousLeftovers.Matches($finalText)
    if ($leftoverMatches.Count -gt 0) {
        $snippets = foreach ($leftoverMatch in ($leftoverMatches | Select-Object -First 3)) {
            $start = [Math]::Max(0, $leftoverMatch.Index - 20)
            $end = [Math]::Min($finalText.Length, $leftoverMatch.Index + $leftoverMatch.Length + 20)
            $finalText.Substring($start, $end - $start)
        }
        $stillSuspicious += @{ File = $file.FullName; Count = $leftoverMatches.Count; Snippets = @($snippets) }
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
        $spotLabel = if ($entry.Count -ne 1) { "spots" } else { "spot" }
        Write-Host "  - $($entry.File) ($($entry.Count) $spotLabel)"
        foreach ($snippet in $entry.Snippets) {
            Write-Host "      ...$snippet..."
        }
        $notShown = $entry.Count - $entry.Snippets.Count
        if ($notShown -gt 0) {
            Write-Host "      ...and $notShown more"
        }
    }
    Write-Host ""
    Write-Host "Recommended next step: re-extract just these pages from Confluence"
    Write-Host "rather than editing them by hand - the original bytes for these ones"
    Write-Host "are gone, so this is the only way to get the real text back. Find the"
    Write-Host "page's id in confluence_export\manifest.json, then run"
    Write-Host "confluence_extractor.ps1 again and enter that id when it asks for a"
    Write-Host "Page ID (leave it blank and it re-pulls the whole space instead)."
    Write-Host ""
    Write-Host "If you'd rather not re-extract, most of these are a stray leftover"
    Write-Host "character next to a space that's safe to just delete - but that's a"
    Write-Host "guess, not a certainty, so it's not done automatically."
    if (-not $Force) {
        Write-Host "Re-run this script with -Force if you want the option to strip them."
    }
    else {
        Write-Host "To live dangerously and strip these leftover characters from the"
        Write-Host "file(s) above right now, type YOLO and press Enter. Anything else"
        Write-Host "leaves them untouched."
        $confirmation = (Read-Host "Strip leftover characters").Trim()
        if ($confirmation -ceq "YOLO") {
            $logPath = "garbled_text_repair_log.json"
            $logEntries = @()
            if (Test-Path $logPath) {
                try {
                    $logEntries = @(Get-Content $logPath -Raw | ConvertFrom-Json)
                }
                catch {
                    # Only this script ever writes this file, so a parse
                    # failure here means it was hand-edited or damaged
                    # somehow - rather than crash the whole run over a log
                    # file, start a fresh one and keep going.
                    Write-Host "Couldn't read the existing $logPath (it may be corrupted) - starting a fresh log."
                    $logEntries = @()
                }
            }

            foreach ($entry in $stillSuspicious) {
                $strippedBackupPath = "$($entry.File).stripped.bak"
                $currentContent = [System.IO.File]::ReadAllText($entry.File, $strictUtf8)
                if (-not (Test-Path $strippedBackupPath)) {
                    Copy-Item -Path $entry.File -Destination $strippedBackupPath
                }
                $stripped = $suspiciousLeftovers.Replace($currentContent, "")
                [System.IO.File]::WriteAllText($entry.File, $stripped, $strictUtf8)
                Write-Host "Stripped: $($entry.File)"

                $logEntries += [PSCustomObject]@{
                    file       = $entry.File
                    count      = $entry.Count
                    snippet    = $entry.Snippets[0]
                    strippedAt = (Get-Date).ToString("o")
                }
            }

            # -InputObject, not piped: piping a one-item array into
            # ConvertTo-Json collapses it to a bare object instead of a
            # one-item JSON array. WriteAllText with $strictUtf8, not
            # Set-Content -Encoding UTF8: the latter adds a BOM on Windows
            # PowerShell 5.1, which breaks a plain ConvertFrom-Json/re-read.
            $logJson = ConvertTo-Json -InputObject $logEntries
            [System.IO.File]::WriteAllText((Join-Path (Get-Location) $logPath), $logJson, $strictUtf8)
            Write-Host "Done. Pre-strip versions saved as *.stripped.bak, logged to $logPath."
        }
        else {
            Write-Host "Left untouched."
        }
    }
}

<#
Checks every .ps1 file in the current folder for the exact trap that broke
repair_garbled_text.ps1 in real use: a script with no UTF-8 BOM, containing
a literal non-ASCII character somewhere in its actual code (not a comment).
Windows PowerShell 5.1 only trusts a script is UTF-8 if it has that BOM -
without one, it falls back to guessing the machine's system codepage, and
on a machine where that guess is wrong, a literal special character gets
silently corrupted before the script even runs.

Run this after editing any .ps1 file in this project, before committing:
    .\check_script_encoding.ps1

A character in a COMMENT is fine - PowerShell doesn't care what a comment
contains, so a garbled comment can't break anything, just look odd. It's
only a character sitting in actual code that's a real risk.

Exits 0 if everything's clean, 1 if it found something - so this is safe
to make a habit of running rather than just eyeballing the output.
#>

$hasIssues = $false

foreach ($file in (Get-ChildItem -Path . -Filter "*.ps1" -File)) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF

    if (-not $hasBom) {
        Write-Host "MISSING BOM: $($file.Name)"
        Write-Host "  Windows PowerShell 5.1 will guess this file's encoding instead of"
        Write-Host "  trusting it's UTF-8 - on some machines that guess is wrong."
        $hasIssues = $true
    }

    # ReadAllText auto-detects and strips a BOM if one's present; if there
    # isn't one, this reads the bytes as UTF-8 anyway (correct, since we
    # know from context this repo's files are actually saved as UTF-8) -
    # we're checking the file's own content here, not simulating a bad read.
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    $lines = $text -split "`r?`n"
    $inBlockComment = $false

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        $trimmed = $line.Trim()

        if ($trimmed.StartsWith("<#")) {
            $inBlockComment = $true
        }
        if ($inBlockComment) {
            if ($trimmed.Contains("#>")) {
                $inBlockComment = $false
            }
            continue
        }

        $codePart = if ($line.Contains("#")) { $line.Substring(0, $line.IndexOf("#")) } else { $line }
        $nonAsciiChars = $codePart.ToCharArray() | Where-Object { [int]$_ -gt 127 }

        if ($nonAsciiChars.Count -gt 0) {
            $lineNum = $i + 1
            Write-Host "LITERAL SPECIAL CHARACTER IN CODE: $($file.Name), line $lineNum"
            Write-Host "  $($line.Trim())"
            Write-Host "  Build this from its character code instead (e.g. [char]0x00C2),"
            Write-Host "  so it can't get corrupted if this file's encoding is ever misread."
            $hasIssues = $true
        }
    }
}

if (-not $hasIssues) {
    Write-Host "All .ps1 files have a UTF-8 BOM and no literal special characters in code. Clean."
    exit 0
}
else {
    Write-Host ""
    Write-Host "Fix what's flagged above, then run this again."
    exit 1
}

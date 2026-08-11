<#
Confluence HTML to Markdown converter.
Reads manifest.json produced by confluence_extractor.ps1, converts each
page's content.html into a content.md, writing it into a separate output
folder (confluence_markdown_export) that mirrors the same page structure
as the original export, complete with each page's images copied alongside
its markdown. This keeps the converted output self-contained and ready to
upload, without touching or mixing into the original raw export.

No credentials needed, this step is pure local file processing, nothing
talks to Confluence.

Run:
    .\confluence_html_to_markdown.ps1

Optional: edit $exportDir / $markdownExportDir below if your folder names differ.
#>

$exportDir = "confluence_export"
$markdownExportDir = "confluence_markdown_export"

$manifestPath = Join-Path $exportDir "manifest.json"

if (-not (Test-Path $manifestPath)) {
    Write-Host "Nah, can't find manifest.json at $manifestPath, mate."
    Write-Host "Run confluence_extractor.ps1 first, or check `$exportDir's pointing at the right spot."
    exit 1
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# --- XML namespace setup ---
# Confluence storage format uses ac: and ri: prefixes for its own elements
# (macros, images, attachment references) alongside plain XHTML. We declare
# those namespaces so the XML parser doesn't choke on them.
$namespaceDeclarations = @'
xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/"
xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/"
'@

function Convert-NodeToMarkdown {
    param(
        [System.Xml.Linq.XElement]$node,
        [int]$listDepth = 0
    )

    $stringBuilder = New-Object System.Text.StringBuilder

    foreach ($childNode in $node.Nodes()) {

        if ($childNode -is [System.Xml.Linq.XText]) {
            [void]$stringBuilder.Append($childNode.Value)
            continue
        }

        if ($childNode -isnot [System.Xml.Linq.XElement]) { continue }

        $tagName = $childNode.Name.LocalName

        switch ($tagName) {
            "h1" { [void]$stringBuilder.Append("`n# " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h2" { [void]$stringBuilder.Append("`n## " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h3" { [void]$stringBuilder.Append("`n### " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h4" { [void]$stringBuilder.Append("`n#### " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h5" { [void]$stringBuilder.Append("`n##### " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h6" { [void]$stringBuilder.Append("`n###### " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "p"  { [void]$stringBuilder.Append("`n" + (Convert-NodeToMarkdown $childNode) + "`n") }
            "br" { [void]$stringBuilder.Append("`n") }
            "strong" { [void]$stringBuilder.Append("**" + (Convert-NodeToMarkdown $childNode) + "**") }
            "b"      { [void]$stringBuilder.Append("**" + (Convert-NodeToMarkdown $childNode) + "**") }
            "em"     { [void]$stringBuilder.Append("*" + (Convert-NodeToMarkdown $childNode) + "*") }
            "i"      { [void]$stringBuilder.Append("*" + (Convert-NodeToMarkdown $childNode) + "*") }
            "code"   { [void]$stringBuilder.Append("``" + (Convert-NodeToMarkdown $childNode) + "``") }

            "a" {
                $hrefAttribute = $childNode.Attribute("href")
                $linkText = Convert-NodeToMarkdown $childNode
                if ($hrefAttribute) {
                    [void]$stringBuilder.Append("[$linkText]($($hrefAttribute.Value))")
                } else {
                    [void]$stringBuilder.Append($linkText)
                }
            }

            "ul" {
                [void]$stringBuilder.Append("`n")
                foreach ($listItem in $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "li" }) {
                    $indent = "  " * $listDepth
                    [void]$stringBuilder.Append("$indent- " + (Convert-NodeToMarkdown $listItem ($listDepth + 1)).Trim() + "`n")
                }
            }

            "ol" {
                [void]$stringBuilder.Append("`n")
                $itemNumber = 1
                foreach ($listItem in $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "li" }) {
                    $indent = "  " * $listDepth
                    [void]$stringBuilder.Append("$indent$itemNumber. " + (Convert-NodeToMarkdown $listItem ($listDepth + 1)).Trim() + "`n")
                    $itemNumber++
                }
            }

            "table" {
                [void]$stringBuilder.Append("`n")
                $tableRows = $childNode.Descendants() | Where-Object { $_.Name.LocalName -eq "tr" }
                $rowIndex = 0
                foreach ($tableRow in $tableRows) {
                    $tableCells = $tableRow.Elements() | Where-Object { $_.Name.LocalName -in @("th", "td") }
                    $cellTexts = $tableCells | ForEach-Object { (Convert-NodeToMarkdown $_).Trim() -replace '\|', '\|' }
                    [void]$stringBuilder.Append("| " + ($cellTexts -join " | ") + " |`n")

                    if ($rowIndex -eq 0) {
                        $headerSeparator = ($cellTexts | ForEach-Object { "---" }) -join " | "
                        [void]$stringBuilder.Append("| " + $headerSeparator + " |`n")
                    }
                    $rowIndex++
                }
            }

            "image" {
                # Confluence image, either an attachment reference or an external URL
                $attachmentRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "attachment" } | Select-Object -First 1
                $urlRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "url" } | Select-Object -First 1

                if ($attachmentRef) {
                    $filenameAttribute = $attachmentRef.Attributes() | Where-Object { $_.Name.LocalName -eq "filename" } | Select-Object -First 1
                    if ($filenameAttribute) {
                        $filename = $filenameAttribute.Value
                        [void]$stringBuilder.Append("`n![$filename](images/$filename)`n")
                    }
                } elseif ($urlRef) {
                    $valueAttribute = $urlRef.Attributes() | Where-Object { $_.Name.LocalName -eq "value" } | Select-Object -First 1
                    if ($valueAttribute) {
                        [void]$stringBuilder.Append("`n![image]($($valueAttribute.Value))`n")
                    }
                }
            }

            "structured-macro" {
                $macroNameAttribute = $childNode.Attributes() | Where-Object { $_.Name.LocalName -eq "name" } | Select-Object -First 1
                $macroName = if ($macroNameAttribute) { $macroNameAttribute.Value } else { "unknown" }

                if ($macroName -eq "code") {
                    $bodyNode = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "plain-text-body" } | Select-Object -First 1
                    $codeText = if ($bodyNode) { $bodyNode.Value } else { "" }
                    [void]$stringBuilder.Append("`n``````" + "`n$codeText`n" + "``````" + "`n")
                }
                elseif ($macroName -in @("info", "note", "warning", "tip")) {
                    $bodyNode = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "rich-text-body" } | Select-Object -First 1
                    $innerText = if ($bodyNode) { (Convert-NodeToMarkdown $bodyNode).Trim() } else { "" }
                    $panelLabel = $macroName.ToUpper()
                    [void]$stringBuilder.Append("`n> **${panelLabel}:** $innerText`n")
                }
                else {
                    # Unrecognised macro: keep any readable text inside it so
                    # nothing is silently lost, flag it for manual review.
                    $innerText = (Convert-NodeToMarkdown $childNode).Trim()
                    if ($innerText) {
                        [void]$stringBuilder.Append("`n<!-- unrecognised macro: $macroName -->`n$innerText`n")
                    } else {
                        [void]$stringBuilder.Append("`n<!-- unrecognised macro: $macroName (no text content) -->`n")
                    }
                }
            }

            default {
                # Unknown tag: recurse into it so we don't lose the text inside
                [void]$stringBuilder.Append((Convert-NodeToMarkdown $childNode $listDepth))
            }
        }
    }

    return $stringBuilder.ToString()
}

# --- Main ---

$totalPages = $manifest.Count
$pageIndex = 0
$conversionWarnings = @()

foreach ($pageEntry in $manifest) {
    $pageIndex++
    $htmlPath = Join-Path $exportDir (Join-Path $pageEntry.folder $pageEntry.html_file)

    # Destination folder mirrors the same relative structure as the source
    # export, but lives under $markdownExportDir instead, kept separate
    # from the raw HTML/manifest so it's ready to upload as-is.
    $destinationFolder = Join-Path $markdownExportDir $pageEntry.folder
    $markdownPath = Join-Path $destinationFolder "content.md"

    Write-Host "[$pageIndex/$totalPages] $($pageEntry.title)"

    if (-not (Test-Path $htmlPath)) {
        Write-Host "    Nah, skipped: content.html not found at $htmlPath"
        $conversionWarnings += "$($pageEntry.title): content.html not found"
        continue
    }

    try {
        New-Item -ItemType Directory -Force -Path $destinationFolder | Out-Null

        $rawHtml = Get-Content $htmlPath -Raw -Encoding UTF8

        # Wrap in a root element with the Confluence namespaces declared,
        # so the XML parser understands ac: and ri: prefixed tags.
        $wrappedHtml = "<root $namespaceDeclarations>$rawHtml</root>"

        $xmlDocument = [System.Xml.Linq.XDocument]::Parse($wrappedHtml)
        $rootElement = $xmlDocument.Root

        $markdownBody = Convert-NodeToMarkdown $rootElement

        # Tidy up: collapse more than 2 consecutive blank lines
        $markdownBody = $markdownBody -replace "(`n\s*){3,}", "`n`n"
        $markdownBody = $markdownBody.Trim() + "`n"

        $pageTitle = $pageEntry.title
        $finalMarkdown = "# $pageTitle`n`n$markdownBody"

        Set-Content -Path $markdownPath -Value $finalMarkdown -Encoding UTF8

        # Copy this page's images across too, so the destination folder is
        # fully self-contained and ready to upload without touching the
        # original export.
        $sourceImagesFolder = Join-Path $exportDir (Join-Path $pageEntry.folder "images")
        if (Test-Path $sourceImagesFolder) {
            $destinationImagesFolder = Join-Path $destinationFolder "images"
            Copy-Item -Path $sourceImagesFolder -Destination $destinationImagesFolder -Recurse -Force
        }
    }
    catch {
        Write-Host "    Yeah nah, that one's carked it: '$($pageEntry.title)': $($_.Exception.Message)"
        $conversionWarnings += "$($pageEntry.title): $($_.Exception.Message)"
    }
}

Write-Host "`nAll done, no worries. Converted $($totalPages - $conversionWarnings.Count) of $totalPages pages."
Write-Host "Output's sitting in: $markdownExportDir\"

if ($conversionWarnings.Count -gt 0) {
    Write-Host "`n$($conversionWarnings.Count) page(s) had a bit of a whinge:"
    foreach ($warning in $conversionWarnings) {
        Write-Host "  - $warning"
    }
    Write-Host "`nWorth having a squiz at these manually, the XML parser can spit"
    Write-Host "the dummy on malformed content.html (e.g. a stray '&' or '<' left"
    Write-Host "over from a copy-pasted table). Crack open the failed content.html"
    Write-Host "files and have a look."
}

Write-Host "`nAlso worth having a squiz at a handful of converted .md files for any"
Write-Host "'<!-- unrecognised macro -->' comments, these flag Confluence macros"
Write-Host "(page trees, Jira embeds, etc.) that don't have a clean Markdown"
Write-Host "equivalent, so they got left as a comment plus the visible text."

# ============================================================
# DESTINATION PATH LENGTH / NAMING CHECK
#
# WHY THIS EXISTS: both Azure DevOps Wiki and SharePoint document
# libraries have their own rules about how long a file's full path can be,
# and which characters are allowed in a file name. Uploads that break
# these rules fail, sometimes with unhelpful error messages, so it's safer
# to catch and fix this now than to discover it partway through uploading
# 500+ pages.
#
# Azure DevOps Wiki:
#   - Full path (repo URL + folder path + file name) must be 235
#     characters or less.
#   - Spaces in the page title become hyphens in the file name.
#   - Disallowed characters in the file name: / \ #
#   - File name can't start or end with a period.
#   Source: https://learn.microsoft.com/en-us/azure/devops/organizations/settings/naming-restrictions
#
# SharePoint document libraries:
#   - Individual file/folder names must be 400 characters or less.
#   - Full path (site URL + library + folders + file name) must also be
#     400 characters or less in total.
#   - Disallowed characters anywhere in the name: " * : < > ? / \ |  # { }
#   - Spaces are fine, SharePoint doesn't rewrite the title into the file
#     name the way Azure DevOps Wiki does.
#   Source: Microsoft SharePoint documentation on invalid file/folder names
#
# This section only runs if you confirm below that this export is headed
# to one of these destinations. It does NOT touch confluence_export (the
# raw source), only the already-converted files in confluence_markdown_export.
# ============================================================

$azureMaxPathLength = 235
$sharePointMaxPathLength = 400

function ConvertTo-AzureWikiFileName {
    # Mirrors how Azure DevOps derives a page's file name from its title:
    # spaces become hyphens, disallowed characters are stripped, and the
    # name can't start or end with a period.
    param([string]$title)

    $safeName = $title -replace '\s+', '-'
    $safeName = $safeName -replace '[/\\#]', ''
    $safeName = $safeName.Trim('.')
    return "$safeName.md"
}

function ConvertTo-SharePointFileName {
    # SharePoint keeps spaces as-is (unlike Azure DevOps Wiki), it just
    # needs the disallowed characters stripped out.
    param([string]$title)

    $safeName = $title -replace '["\*:<>\?/\\\|#\{\}]', ''
    $safeName = $safeName.Trim()
    return "$safeName.md"
}

function Test-DestinationPathLength {
    # Returns the estimated full path length for a page, and whether it
    # breaches the given destination's limit.
    param(
        [string]$repoUrlPrefix,
        [string]$folderPath,
        [string]$fileName,
        [int]$maxLength
    )

    $fullPath = if ($repoUrlPrefix) {
        "$repoUrlPrefix/$folderPath/$fileName"
    } else {
        "$folderPath/$fileName"
    }

    return [PSCustomObject]@{
        FullPath   = $fullPath
        Length     = $fullPath.Length
        OverLimit  = $fullPath.Length -gt $maxLength
    }
}

Write-Host "`nRighto, where's this markdown export headed?"
Write-Host "  1. Azure DevOps Wiki"
Write-Host "  2. SharePoint"
Write-Host "  3. Dunno / not fussed, skip this check"
$destinationChoice = Read-Host "Enter 1, 2, or 3"

if ($destinationChoice -eq "1" -or $destinationChoice -eq "2") {

    if ($destinationChoice -eq "1") {
        $destinationName = "Azure DevOps Wiki"
        $maxPathLength = $azureMaxPathLength
        $urlPrompt = "Azure DevOps wiki repo URL (e.g. https://dev.azure.com/yourorg/yourproject/_git/yourproject.wiki)"
    }
    else {
        $destinationName = "SharePoint"
        $maxPathLength = $sharePointMaxPathLength
        $urlPrompt = "SharePoint document library URL (e.g. https://yourorg.sharepoint.com/sites/YourSite/Shared Documents)"
    }

    # Ask for the actual destination URL now, before running any check.
    # The limit applies to the FULL path (site/repo URL + folder path +
    # file name), so without the real URL the check below is only an
    # estimate and could miss pages that are actually over the limit once
    # the real URL is added on top. Getting this right up front is safer
    # than silently under-counting, especially for someone who might not
    # know to double-check this themselves later.
    Write-Host "`nFor a proper accurate check, chuck in the $urlPrompt."
    $destinationUrlPrefix = Read-Host "URL (leave it blank if you want a rough estimate instead)"

    if (-not $destinationUrlPrefix) {
        Write-Host "`nFair enough, no URL. Carrying on with a ROUGH ESTIMATE based on"
        Write-Host "folder path and file name only. This'll under-count the real"
        Write-Host "length, so pages sitting close to the limit might still fall over"
        Write-Host "on upload even if this check reckons they're fine. Run it again"
        Write-Host "with the real URL if you want to be dead certain."
    }

    Write-Host "`nHaving a look through page paths against $destinationName's $maxPathLength character limit..."
    $affectedPages = @()

    foreach ($pageEntry in $manifest) {
        $destinationFileName = if ($destinationChoice -eq "1") {
            ConvertTo-AzureWikiFileName $pageEntry.title
        } else {
            ConvertTo-SharePointFileName $pageEntry.title
        }

        $pathCheck = Test-DestinationPathLength -repoUrlPrefix $destinationUrlPrefix -folderPath $pageEntry.folder -fileName $destinationFileName -maxLength $maxPathLength

        if ($pathCheck.OverLimit) {
            $affectedPages += [PSCustomObject]@{
                Title              = $pageEntry.title
                Folder             = $pageEntry.folder
                DestinationFileName = $destinationFileName
                Length             = $pathCheck.Length
            }
        }
    }

    if ($affectedPages.Count -eq 0) {
        Write-Host "She's right, all page paths are within the $maxPathLength character limit. Nothing to fix here."
    }
    else {
        Write-Host "`n$($affectedPages.Count) page(s) are too long for the $maxPathLength character limit:"
        foreach ($affected in $affectedPages) {
            Write-Host "  - $($affected.Title) (estimated length: $($affected.Length))"
        }

        $shouldFix = Read-Host "`nWant these shortened automatically so they're $destinationName-compliant? (y/n)"

        if ($shouldFix -eq "y") {
            Write-Host "`nRighto, shortening the affected file names..."

            foreach ($affected in $affectedPages) {
                # Work out how much needs to be trimmed off the title
                # portion of the file name to fit under the limit, keeping
                # a safety margin and appending a short unique suffix so
                # two shortened titles don't collide with each other.
                $pageEntry = $manifest | Where-Object { $_.folder -eq $affected.Folder } | Select-Object -First 1
                $uniqueSuffix = "-$($pageEntry.id)"
                $overshoot = $affected.Length - $maxPathLength
                $charsToTrim = $overshoot + $uniqueSuffix.Length + 5   # small safety margin

                $originalName = $affected.DestinationFileName -replace '\.md$', ''
                $trimLength = [Math]::Max(1, $originalName.Length - $charsToTrim)
                $shortenedName = $originalName.Substring(0, $trimLength) + $uniqueSuffix + ".md"

                $destinationFolder = Join-Path $markdownExportDir $affected.Folder
                $currentMarkdownPath = Join-Path $destinationFolder "content.md"
                $newMarkdownPath = Join-Path $destinationFolder $shortenedName

                if (Test-Path $currentMarkdownPath) {
                    Rename-Item -Path $currentMarkdownPath -NewName $shortenedName -Force
                    Write-Host "  Sorted: $($affected.Title)"
                    Write-Host "    -> $shortenedName"
                }
                else {
                    Write-Host "  Skipped, couldn't find the file (maybe already renamed): $($affected.Title)"
                }
            }

            Write-Host "`nToo easy, done. Affected files renamed to $destinationName-compliant names."
            if ($destinationChoice -eq "1") {
                Write-Host "Heads up: these renamed files no longer follow Azure's exact"
                Write-Host "title-to-filename convention (hyphenated title), since they've"
                Write-Host "been trimmed down. When you create the page in Azure DevOps Wiki,"
                Write-Host "you might want to set a friendlier page title in the wiki UI"
                Write-Host "even though the underlying file name stays short."
            }
        }
        else {
            Write-Host "`nFair enough, left as-is. These pages will probably fall over on"
            Write-Host "upload to $destinationName though, worth a look before you push."
        }
    }
}
else {
    Write-Host "`nNo dramas, skipping the destination path length check."
}

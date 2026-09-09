<#
Confluence HTML to Markdown converter.
Reads manifest.json produced by confluence_extractor.ps1, converts each
page's content.html into content.md, and routes the output into one of
three folders depending on where that specific page is headed:

    confluence_markdown_export/azure/...
    confluence_markdown_export/sharepoint/...
    confluence_markdown_export/unsorted/...  (not yet classified)

WHY PER-PAGE ROUTING: some pages are technical docs going to Azure DevOps
Wiki, others are onboarding/non-technical content going to SharePoint.
There's no reliable way to guess which is which from the content alone, so
this script asks you to classify each page once via a CSV file, rather than
assuming or applying one destination to everything.

No credentials needed, this step is pure local file processing, nothing
talks to Confluence.

Run:
    .\confluence_html_to_markdown.ps1

Optional: edit $exportDir / $markdownExportDir below if your folder names differ.

Written by Dan.
#>

# Loads .NET's "LINQ to XML" library, which this script uses to read and
# walk through each page's HTML content.
Add-Type -AssemblyName System.Xml.Linq

# Where confluence_extractor.ps1 saved everything (must match its
# $OutputDir), and where this script's own output will go.
$exportDir = "confluence_export"
$markdownExportDir = "confluence_markdown_export"
$classificationPath = Join-Path $exportDir "page_destinations.csv"

$manifestPath = Join-Path $exportDir "manifest.json"

if (-not (Test-Path $manifestPath)) {
    # Nothing to convert without the extractor having run first.
    Write-Host "Nah, can't find manifest.json at $manifestPath, mate."
    Write-Host "Run confluence_extractor.ps1 first, or check `$exportDir's pointing at the right spot."
    exit 1
}

# @()-wrapped: manifest.json legitimately can have exactly one page (the
# extractor's single-page mode), and ConvertFrom-Json hands back a bare
# object instead of a one-item array for a one-element JSON array - this
# script does $manifest.Count further down, which would misfire on that.
$manifest = @(Get-Content $manifestPath -Raw | ConvertFrom-Json)

# ============================================================
# PER-PAGE DESTINATION CLASSIFICATION
#
# WHY THIS EXISTS: this export is going to two different places, technical
# docs to Azure DevOps Wiki, everything else (onboarding, non-technical) to
# SharePoint. The script can't reliably tell those apart from content alone,
# so it asks you to classify each page once, in a plain CSV you can open in
# Excel, rather than guessing.
#
# FIRST RUN: if page_destinations.csv doesn't exist yet, this section
# creates it (one row per page, id/title/destination, destination left
# blank) and stops here so you can fill it in. Open it in Excel or any text
# editor, type "azure" or "sharepoint" in the destination column for each
# row, save, then run this script again.
#
# LATER RUNS: if you add more pages to confluence_export later (re-running
# the extractor), re-run this script, it'll add any new pages to the CSV
# with a blank destination without touching rows you've already filled in.
# ============================================================

function New-ClassificationTemplate {
    # Builds the very first version of page_destinations.csv: one row per
    # page, with the destination column left blank for you to fill in.
    param([array]$pages, [string]$path)

    $rows = foreach ($pageEntry in $pages) {
        [PSCustomObject]@{
            id          = $pageEntry.id
            title       = $pageEntry.title
            destination = ""
        }
    }

    $rows | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
}

if (-not (Test-Path $classificationPath)) {
    # No CSV yet - this must be the first time this script's been run.
    # Create the template and stop here so it can be filled in by hand.
    Write-Host "First time running this, so no page_destinations.csv yet."
    Write-Host "Chucking one together now at: $classificationPath"

    New-ClassificationTemplate -pages $manifest -path $classificationPath

    Write-Host "`nRighto, open that file (Excel's fine) and fill in the"
    Write-Host "'destination' column for every row, azure or sharepoint."
    Write-Host "Save it, then run this script again and it'll pick up where"
    Write-Host "you left off."
    exit 0
}

# Load whatever's in the CSV already, and add any pages that are in the
# manifest but missing from the CSV (e.g. new pages from a later extractor
# run), without touching rows that have already been classified.
$existingRows = Import-Csv -Path $classificationPath
# A quick lookup table: page id -> whatever's currently in its destination
# column (could be blank if not filled in yet).
$classificationLookup = @{}
foreach ($row in $existingRows) {
    $classificationLookup[$row.id] = $row.destination
}

$newRowsAdded = $false
# Go through every page in the manifest: if it's already got a row in the
# CSV, keep its existing destination; if it's a brand new page (not in
# the CSV yet), add a fresh row for it with a blank destination.
$allRows = foreach ($pageEntry in $manifest) {
    if (-not $classificationLookup.ContainsKey($pageEntry.id)) {
        $newRowsAdded = $true
        [PSCustomObject]@{
            id          = $pageEntry.id
            title       = $pageEntry.title
            destination = ""
        }
    }
    else {
        [PSCustomObject]@{
            id          = $pageEntry.id
            title       = $pageEntry.title
            destination = $classificationLookup[$pageEntry.id]
        }
    }
}

if ($newRowsAdded) {
    # Found pages the CSV didn't know about yet - save the updated CSV
    # (with blank destinations for the new ones) and stop so those can be
    # filled in before continuing.
    $allRows | Export-Csv -Path $classificationPath -NoTypeInformation -Encoding UTF8
    Write-Host "Found some new pages since the CSV was last filled in, added"
    Write-Host "them to $classificationPath with a blank destination."
    Write-Host "Fill those in and run this again when you're ready."
    exit 0
}

# Rebuild the lookup from the (possibly updated) rows, normalising values
# so "Azure", " azure ", "AZURE" etc all match cleanly.
$classificationLookup = @{}
foreach ($row in $allRows) {
    $classificationLookup[$row.id] = ($row.destination -replace '\s', '').ToLower()
}

# ============================================================
# XML NAMESPACE SETUP
# Confluence storage format uses ac: and ri: prefixed elements (macros,
# images, attachment references) alongside plain XHTML. We declare
# those namespaces so the XML parser doesn't choke on them.
# ============================================================
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

function Set-Utf8NoBomContent {
    # Set-Content -Encoding UTF8 adds a BOM on Windows PowerShell 5.1 (not
    # on PowerShell 7, which quietly changed this default) - bypassing it
    # with a direct .NET write keeps content.md byte-identical to the
    # Python converter's output regardless of which PowerShell version
    # wrote it.
    param([string]$Path, [string]$Value)
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}

# Set once per page (see the main loop below) to that page's manifest
# "attachments" entry, mapping the original Confluence filename to whatever
# it actually got saved as - the "image" case above consults it to build a
# working link.
$script:currentAttachmentMap = @{}

function Get-AttachmentMap {
    # Turns one page's "attachments" manifest entry into a simple lookup:
    # original Confluence filename -> whatever it actually got saved as
    # on disk.
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

# Loaded once (see the main loop below) from user_display_names.json -
# @mentions only carry an opaque userkey/username in the storage HTML,
# this is the extractor's best-effort resolution of those to a real name.
$script:userDisplayNames = @{}

function Get-UserDisplayNames {
    # Loads the userkey/username -> real name lookup table the extractor
    # built, if one exists (older exports won't have this file at all,
    # which is fine - @mentions just show the raw ID instead).
    $path = Join-Path $exportDir "user_display_names.json"
    if (-not (Test-Path $path)) {
        return @{}
    }
    $map = @{}
    $data = Get-Content $path -Raw | ConvertFrom-Json
    foreach ($property in $data.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }
    return $map
}

function Convert-NodeToMarkdown {
    # This is the heart of the whole script. It walks through one XML
    # element's contents piece by piece (plain text, or another nested
    # element), and for each piece decides what Markdown it should turn
    # into - a heading becomes "# text", bold text gets wrapped in **, a
    # list becomes "- item" lines, and so on. It calls itself
    # recursively for anything nested inside another element (e.g. bold
    # text inside a paragraph inside a list item).
    param(
        [System.Xml.Linq.XElement]$node,
        # How deeply nested inside lists we currently are, so a list
        # inside a list gets extra indentation.
        [int]$listDepth = 0
    )

    # Builds up the resulting Markdown text piece by piece as we go.
    $stringBuilder = New-Object System.Text.StringBuilder

    foreach ($childNode in $node.Nodes()) {

        if ($childNode -is [System.Xml.Linq.XText]) {
            # Plain text (not a tag) - just add it as-is.
            [void]$stringBuilder.Append($childNode.Value)
            continue
        }

        if ($childNode -isnot [System.Xml.Linq.XElement]) { continue }

        # Which HTML/Confluence tag is this? (e.g. "p", "strong", "table")
        $tagName = $childNode.Name.LocalName

        switch ($tagName) {
            # Headings: "# ", "## ", etc, one # per heading level.
            "h1" { [void]$stringBuilder.Append("`n# " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h2" { [void]$stringBuilder.Append("`n## " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h3" { [void]$stringBuilder.Append("`n### " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h4" { [void]$stringBuilder.Append("`n#### " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h5" { [void]$stringBuilder.Append("`n##### " + (Convert-NodeToMarkdown $childNode) + "`n") }
            "h6" { [void]$stringBuilder.Append("`n###### " + (Convert-NodeToMarkdown $childNode) + "`n") }
            # A paragraph just gets a blank line before and after it.
            "p"  { [void]$stringBuilder.Append("`n" + (Convert-NodeToMarkdown $childNode) + "`n") }
            # A manual line break within a paragraph.
            "br" { [void]$stringBuilder.Append("`n") }
            # Bold text: wrap in **.
            "strong" { [void]$stringBuilder.Append("**" + (Convert-NodeToMarkdown $childNode) + "**") }
            "b"      { [void]$stringBuilder.Append("**" + (Convert-NodeToMarkdown $childNode) + "**") }
            # Italic text: wrap in *.
            "em"     { [void]$stringBuilder.Append("*" + (Convert-NodeToMarkdown $childNode) + "*") }
            "i"      { [void]$stringBuilder.Append("*" + (Convert-NodeToMarkdown $childNode) + "*") }
            # Inline code: wrap in backticks.
            "code"   { [void]$stringBuilder.Append("``" + (Convert-NodeToMarkdown $childNode) + "``") }

            "a" {
                # A regular hyperlink - <a href="...">link text</a>
                # becomes [link text](...) in Markdown.
                $hrefAttribute = $childNode.Attribute("href")
                $linkText = Convert-NodeToMarkdown $childNode
                if ($hrefAttribute) {
                    [void]$stringBuilder.Append("[$linkText]($($hrefAttribute.Value))")
                } else {
                    # No actual link address, just keep the visible text.
                    [void]$stringBuilder.Append($linkText)
                }
            }

            "link" {
                # <ac:link> covers three different reference types depending
                # on which ri: child it wraps - page, attachment, or user -
                # and only the page case genuinely has no resolvable target
                # yet.
                # Work out which of the three kinds of link this actually is.
                $pageRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "page" } | Select-Object -First 1
                $attachmentRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "attachment" } | Select-Object -First 1
                $userRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "user" } | Select-Object -First 1
                $linkText = (Convert-NodeToMarkdown $childNode).Trim()

                if ($attachmentRef) {
                    # Link to a downloadable attachment (not an <ac:image>
                    # embed) - unlike a page link, we already know exactly
                    # where this file ends up (same attachment map images
                    # use), so resolve it properly instead of flagging it.
                    $filenameAttribute = $attachmentRef.Attributes() | Where-Object { $_.Name.LocalName -eq "filename" } | Select-Object -First 1
                    if ($filenameAttribute) {
                        $filename = $filenameAttribute.Value
                        $savedName = if ($script:currentAttachmentMap.ContainsKey($filename)) { $script:currentAttachmentMap[$filename] } else { $filename }
                        $displayText = if ($linkText) { $linkText } else { $filename }
                        [void]$stringBuilder.Append("[$displayText](<images/$savedName>)")
                    } else {
                        [void]$stringBuilder.Append($(if ($linkText) { $linkText } else { "attachment" }))
                    }
                }
                elseif ($userRef) {
                    # @mention - Confluence resolves this to a live profile
                    # link we have no equivalent for, so at minimum keep the
                    # person's name visible instead of losing who was
                    # mentioned entirely.
                    # Find whichever identifier (key or username) this
                    # mention actually carries, then look up their real
                    # name from the table the extractor built.
                    $userKeyAttribute = $userRef.Attributes() | Where-Object { $_.Name.LocalName -eq "userkey" } | Select-Object -First 1
                    $usernameAttribute = $userRef.Attributes() | Where-Object { $_.Name.LocalName -eq "username" } | Select-Object -First 1
                    $rawId = if ($userKeyAttribute) { $userKeyAttribute.Value } elseif ($usernameAttribute) { $usernameAttribute.Value } else { $null }
                    $displayName = if ($rawId -and $script:userDisplayNames.ContainsKey($rawId)) { $script:userDisplayNames[$rawId] } else { $null }
                    $shown = if ($displayName) { $displayName } elseif ($linkText) { $linkText } elseif ($rawId) { $rawId } else { "mentioned user" }
                    [void]$stringBuilder.Append("@$shown")
                }
                else {
                    # Page link: no stable URL until the target's actually
                    # migrated, so keep the text and flag it instead of
                    # dropping it (used to fall through to the "default"
                    # case and vanish with no trace).
                    $targetTitleAttribute = if ($pageRef) { $pageRef.Attributes() | Where-Object { $_.Name.LocalName -eq "content-title" } | Select-Object -First 1 } else { $null }
                    $targetTitle = if ($targetTitleAttribute) { $targetTitleAttribute.Value } else { $null }
                    $displayText = if ($linkText) { $linkText } elseif ($targetTitle) { $targetTitle } else { "link" }

                    if ($targetTitle) {
                        [void]$stringBuilder.Append("$displayText <!-- internal Confluence link, unresolved: `"$targetTitle`" -->")
                    } else {
                        [void]$stringBuilder.Append("$displayText <!-- internal Confluence link, unresolved -->")
                    }
                }
            }

            "emoticon" {
                # Self-closing - <ac:emoticon ac:name="smile" ac:emoji-fallback="🙂"/>
                # emoji-fallback (when present) is the literal character, best
                # case. Older content without it just gets a Slack/GitHub-style
                # :name:.
                $fallbackAttribute = $childNode.Attributes() | Where-Object { $_.Name.LocalName -eq "emoji-fallback" } | Select-Object -First 1
                if ($fallbackAttribute) {
                    [void]$stringBuilder.Append($fallbackAttribute.Value)
                } else {
                    $nameAttribute = $childNode.Attributes() | Where-Object { $_.Name.LocalName -eq "name" } | Select-Object -First 1
                    if ($nameAttribute) {
                        [void]$stringBuilder.Append(":$($nameAttribute.Value):")
                    }
                }
            }

            "task-list" {
                # Convert-NodeToMarkdown walks a node's CHILDREN through the
                # switch - it can't dispatch on a <ac:task> element's own
                # tag, so its status/body have to be pulled out directly
                # here rather than recursing into it expecting a "task" case
                # to fire (it never would - there's no separate per-element
                # dispatcher the way the Python converter has).
                [void]$stringBuilder.Append("`n")
                # A checklist - go through each <ac:task> and turn it into
                # a Markdown checkbox line: "- [x] done thing" or
                # "- [ ] not done yet".
                foreach ($taskItem in $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "task" }) {
                    $statusNode = $taskItem.Elements() | Where-Object { $_.Name.LocalName -eq "task-status" } | Select-Object -First 1
                    $bodyNode = $taskItem.Elements() | Where-Object { $_.Name.LocalName -eq "task-body" } | Select-Object -First 1
                    $isComplete = $statusNode -and ($statusNode.Value.Trim().ToLower() -eq "complete")
                    $bodyText = if ($bodyNode) { (Convert-NodeToMarkdown $bodyNode $listDepth).Trim() } else { "" }
                    $indent = "  " * $listDepth
                    $checkbox = if ($isComplete) { "x" } else { " " }
                    [void]$stringBuilder.Append("$indent- [$checkbox] $bodyText`n")
                }
            }

            "ul" {
                # A bulleted list - each <li> becomes a "- " line. Nested
                # lists get extra indentation ($listDepth + 1 when
                # recursing into each item).
                [void]$stringBuilder.Append("`n")
                foreach ($listItem in $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "li" }) {
                    $indent = "  " * $listDepth
                    [void]$stringBuilder.Append("$indent- " + (Convert-NodeToMarkdown $listItem ($listDepth + 1)).Trim() + "`n")
                }
            }

            "ol" {
                # A numbered list - same idea as above, but with 1. 2. 3.
                # instead of a bullet.
                [void]$stringBuilder.Append("`n")
                $itemNumber = 1
                foreach ($listItem in $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "li" }) {
                    $indent = "  " * $listDepth
                    [void]$stringBuilder.Append("$indent$itemNumber. " + (Convert-NodeToMarkdown $listItem ($listDepth + 1)).Trim() + "`n")
                    $itemNumber++
                }
            }

            "table" {
                # A table becomes a Markdown pipe table: "| cell | cell |"
                # rows, with a "| --- | --- |" separator line right after
                # the first (header) row.
                [void]$stringBuilder.Append("`n")
                $tableRows = $childNode.Descendants() | Where-Object { $_.Name.LocalName -eq "tr" }
                $rowIndex = 0
                foreach ($tableRow in $tableRows) {
                    $tableCells = $tableRow.Elements() | Where-Object { $_.Name.LocalName -in @("th", "td") }
                    # A cell with multiple <p>s or a <br> produces embedded newlines,
                    # which would otherwise split a pipe-table row across lines and
                    # corrupt the table - collapse them to <br> instead.
                    $cellTexts = $tableCells | ForEach-Object {
                        ((Convert-NodeToMarkdown $_).Trim() -replace '\s*\n\s*', '<br>') -replace '\|', '\|'
                    }
                    [void]$stringBuilder.Append("| " + ($cellTexts -join " | ") + " |`n")

                    if ($rowIndex -eq 0) {
                        # Right after the header row, add the required
                        # "| --- | --- |" separator line.
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
                        # The page references the image by its original Confluence
                        # filename, which may not be what actually got saved to disk
                        # (sanitised characters, or a _2 suffix from a name
                        # collision) - resolve it via the manifest's filename ->
                        # saved_as map for this page.
                        $savedName = if ($script:currentAttachmentMap.ContainsKey($filename)) { $script:currentAttachmentMap[$filename] } else { $filename }
                        # Angle-bracket the path: a lot of real attachment names have
                        # spaces (screenshots, "Diagram v2.png"), and a bare space in
                        # an unbracketed markdown link destination isn't reliably
                        # parsed by every renderer (some truncate at the first one).
                        [void]$stringBuilder.Append("`n![$filename](<images/$savedName>)`n")
                    }
                } elseif ($urlRef) {
                    # An externally-hosted image (not a Confluence
                    # attachment) - just link straight to its URL.
                    $valueAttribute = $urlRef.Attributes() | Where-Object { $_.Name.LocalName -eq "value" } | Select-Object -First 1
                    if ($valueAttribute) {
                        [void]$stringBuilder.Append("`n![image](<$($valueAttribute.Value)>)`n")
                    }
                }
            }

            "structured-macro" {
                # Confluence's "macros" - special blocks like code
                # samples, coloured info/warning panels, or anything more
                # exotic (page trees, Jira embeds, etc). We only know how
                # to properly translate a few kinds; everything else falls
                # through to the "else" branch below.
                $macroNameAttribute = $childNode.Attributes() | Where-Object { $_.Name.LocalName -eq "name" } | Select-Object -First 1
                $macroName = if ($macroNameAttribute) { $macroNameAttribute.Value } else { "unknown" }

                if ($macroName -eq "code") {
                    # A code block - wrap it in triple-backtick fences.
                    $bodyNode = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "plain-text-body" } | Select-Object -First 1
                    $codeText = if ($bodyNode) { $bodyNode.Value } else { "" }
                    [void]$stringBuilder.Append("`n``````" + "`n$codeText`n" + "``````" + "`n")
                }
                elseif ($macroName -in @("info", "note", "warning", "tip")) {
                    # A coloured panel - turn it into a Markdown blockquote
                    # with a bold label showing which kind it was.
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

# ============================================================
# MAIN CONVERSION LOOP
# Each page gets routed into a subfolder matching its classification:
# azure, sharepoint, or unsorted (if blank or an unrecognised value).
# ============================================================

$script:userDisplayNames = Get-UserDisplayNames

$totalPages = $manifest.Count
$pageIndex = 0
# Anything that goes wrong on a specific page gets noted here rather than
# stopping the whole run - reported as a summary at the end.
$conversionWarnings = @()
$destinationCounts = @{ azure = 0; sharepoint = 0; unsorted = 0 }

# Go through every page in the manifest, one at a time.
foreach ($pageEntry in $manifest) {
    $pageIndex++
    $htmlPath = Join-Path $exportDir (Join-Path $pageEntry.folder $pageEntry.html_file)

    # Look up what this page was classified as in the CSV.
    $rawDestination = $classificationLookup[$pageEntry.id]
    $destinationBucket = if ($rawDestination -eq "azure" -or $rawDestination -eq "sharepoint") {
        $rawDestination
    } else {
        # Blank, or something that isn't "azure"/"sharepoint" (a typo,
        # say) - park it in "unsorted" rather than guessing.
        "unsorted"
    }
    $destinationCounts[$destinationBucket]++

    # Destination folder mirrors the same relative structure as the source
    # export, but lives under $markdownExportDir\<bucket> instead, kept
    # separate from the raw HTML/manifest so it's ready to upload as-is.
    $destinationFolder = Join-Path $markdownExportDir (Join-Path $destinationBucket $pageEntry.folder)
    $markdownPath = Join-Path $destinationFolder "content.md"

    Write-Host "[$pageIndex/$totalPages] ($destinationBucket) $($pageEntry.title)"

    if (-not (Test-Path $htmlPath)) {
        # The manifest mentions this page, but its content.html is
        # missing - can't convert something that isn't there.
        Write-Host "    Nah, skipped: content.html not found at $htmlPath"
        $conversionWarnings += "$($pageEntry.title): content.html not found"
        continue
    }

    try {
        New-Item -ItemType Directory -Force -Path $destinationFolder | Out-Null

        # Clear out any .md file left in this folder from a previous run
        # (e.g. a name shortened by Invoke-DestinationCheck below) before
        # writing a fresh content.md. Without this, re-running the
        # conversion after a rename leaves both the old shortened file
        # and a new content.md sitting side by side.
        Get-ChildItem -Path $destinationFolder -Filter "*.md" -File -ErrorAction SilentlyContinue | Remove-Item -Force

        # Read the page's raw content, and fix up any named entities
        # (like &nbsp;) the XML parser wouldn't otherwise understand.
        $rawHtml = Get-Content $htmlPath -Raw -Encoding UTF8
        $rawHtml = ConvertTo-XmlSafeEntities $rawHtml

        # Build this page's own filename -> saved_as lookup, used by the
        # "image"/"link" cases above while converting this specific page.
        $script:currentAttachmentMap = Get-AttachmentMap $pageEntry.attachments

        # Wrap in a root element with the Confluence namespaces declared,
        # so the XML parser understands ac: and ri: prefixed tags.
        $wrappedHtml = "<root $namespaceDeclarations>$rawHtml</root>"

        # Actually parse the page content as XML now that it's wrapped
        # and entity-safe.
        $xmlDocument = [System.Xml.Linq.XDocument]::Parse($wrappedHtml)
        $rootElement = $xmlDocument.Root

        # This is where the real conversion happens - walk the whole page
        # and turn it into Markdown text.
        $markdownBody = Convert-NodeToMarkdown $rootElement

        # Tidy up: collapse more than 2 consecutive blank lines
        $markdownBody = $markdownBody -replace "(`n\s*){3,}", "`n`n"
        $markdownBody = $markdownBody.Trim() + "`n"

        # Stick a "# Page Title" heading (and a Tags line, if this page
        # has any labels) on the very top of the file.
        $pageTitle = $pageEntry.title
        $tagsLine = if ($pageEntry.labels -and $pageEntry.labels.Count -gt 0) { "**Tags:** $($pageEntry.labels -join ', ')`n`n" } else { "" }
        $finalMarkdown = "# $pageTitle`n`n$tagsLine$markdownBody"

        Set-Utf8NoBomContent -Path $markdownPath -Value $finalMarkdown

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
        # Something about converting this one page failed (e.g. broken
        # XML in its content.html) - note it and move on to the next
        # page rather than stopping the whole run.
        Write-Host "    Yeah nah, that one's carked it: '$($pageEntry.title)': $($_.Exception.Message)"
        $conversionWarnings += "$($pageEntry.title): $($_.Exception.Message)"
    }
}

Write-Host "`nAll done, no worries. Converted $($totalPages - $conversionWarnings.Count) of $totalPages pages."
Write-Host "  -> $($destinationCounts.azure) heading to Azure DevOps Wiki"
Write-Host "  -> $($destinationCounts.sharepoint) heading to SharePoint"
if ($destinationCounts.unsorted -gt 0) {
    Write-Host "  -> $($destinationCounts.unsorted) still UNSORTED, not classified in the CSV"
    Write-Host "     These landed in confluence_markdown_export\unsorted\ for now."
    Write-Host "     Go back to $classificationPath, fill in the blanks, and re-run"
    Write-Host "     this script to move them into the right spot."
}
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
# This runs automatically for whichever destinations actually have pages
# in this run, no need to ask "which one" any more since that's now
# decided per page by the CSV.
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

    # Build the full path the way it would actually look once uploaded,
    # then just measure how long that text is.
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

function Invoke-DestinationCheck {
    # Runs the length/naming check for one destination bucket (azure or
    # sharepoint) against only the pages classified into that bucket.
    param(
        [string]$bucket,
        [string]$destinationName,
        [int]$maxPathLength,
        [string]$urlPrompt,
        [array]$pagesInBucket
    )

    Write-Host "`n--- $destinationName ($($pagesInBucket.Count) pages) ---"
    Write-Host "For a proper accurate check, chuck in the $urlPrompt."
    $destinationUrlPrefix = Read-Host "URL (leave it blank if you want a rough estimate instead)"

    if (-not $destinationUrlPrefix) {
        Write-Host "Fair enough, no URL. Carrying on with a ROUGH ESTIMATE based on"
        Write-Host "folder path and file name only. This'll under-count the real"
        Write-Host "length, so pages sitting close to the limit might still fall over"
        Write-Host "on upload even if this check reckons they're fine."
    }

    # Check every page in this bucket, and remember any that end up over
    # the length limit.
    $affectedPages = @()

    foreach ($pageEntry in $pagesInBucket) {
        $destinationFileName = if ($bucket -eq "azure") {
            ConvertTo-AzureWikiFileName $pageEntry.title
        } else {
            ConvertTo-SharePointFileName $pageEntry.title
        }

        $bucketFolder = Join-Path $bucket $pageEntry.folder
        $pathCheck = Test-DestinationPathLength -repoUrlPrefix $destinationUrlPrefix -folderPath $bucketFolder -fileName $destinationFileName -maxLength $maxPathLength

        if ($pathCheck.OverLimit) {
            $affectedPages += [PSCustomObject]@{
                Title               = $pageEntry.title
                Folder              = $bucketFolder
                DestinationFileName = $destinationFileName
                Length              = $pathCheck.Length
                PageId              = $pageEntry.id
            }
        }
    }

    if ($affectedPages.Count -eq 0) {
        # Nothing's too long - nothing more to do here.
        Write-Host "She's right, all $destinationName page paths are within the $maxPathLength character limit."
        return
    }

    Write-Host "`n$($affectedPages.Count) page(s) are too long for the $maxPathLength character limit:"
    foreach ($affected in $affectedPages) {
        Write-Host "  - $($affected.Title) (estimated length: $($affected.Length))"
    }

    $shouldFix = Read-Host "`nWant these shortened automatically so they're $destinationName-compliant? (y/n)"

    if ($shouldFix -ne "y") {
        # They said no - leave the files as they are and just warn.
        Write-Host "`nFair enough, left as-is. These pages will probably fall over on"
        Write-Host "upload to $destinationName though, worth a look before you push."
        return
    }

    Write-Host "`nRighto, shortening the affected file names..."

    foreach ($affected in $affectedPages) {
        # Work out how much needs to be trimmed off the title portion of
        # the file name to fit under the limit, keeping a safety margin
        # and appending a short unique suffix so two shortened titles
        # don't collide with each other.
        $uniqueSuffix = "-$($affected.PageId)"
        $overshoot = $affected.Length - $maxPathLength
        $charsToTrim = $overshoot + $uniqueSuffix.Length + 5   # small safety margin

        $originalName = $affected.DestinationFileName -replace '\.md$', ''
        $trimLength = [Math]::Max(1, $originalName.Length - $charsToTrim)
        $shortenedName = $originalName.Substring(0, $trimLength) + $uniqueSuffix + ".md"

        $destinationFolder = Join-Path $markdownExportDir $affected.Folder
        $currentMarkdownPath = Join-Path $destinationFolder "content.md"

        if (Test-Path $currentMarkdownPath) {
            # Rename the file we already wrote earlier to this shorter name.
            Rename-Item -Path $currentMarkdownPath -NewName $shortenedName -Force
            Write-Host "  Sorted: $($affected.Title)"
            Write-Host "    -> $shortenedName"
        }
        else {
            Write-Host "  Skipped, couldn't find the file (maybe already renamed): $($affected.Title)"
        }
    }

    Write-Host "`nToo easy, done. Affected files renamed to $destinationName-compliant names."
    if ($bucket -eq "azure") {
        Write-Host "Heads up: these renamed files no longer follow Azure's exact"
        Write-Host "title-to-filename convention (hyphenated title), since they've"
        Write-Host "been trimmed down. When you create the page in Azure DevOps Wiki,"
        Write-Host "you might want to set a friendlier page title in the wiki UI"
        Write-Host "even though the underlying file name stays short."
    }
}

# @()-wrapped: without it, exactly one page matching a bucket (easy to hit
# early in a migration, or a small space) would have PowerShell unwrap the
# filtered result to a bare object instead of a one-item array, and the
# .Count checks just below would misfire.
$azurePages = @($manifest | Where-Object { $classificationLookup[$_.id] -eq "azure" })
$sharePointPages = @($manifest | Where-Object { $classificationLookup[$_.id] -eq "sharepoint" })

if ($azurePages.Count -eq 0 -and $sharePointPages.Count -eq 0) {
    # Nothing's been classified yet at all - nothing to check.
    Write-Host "`nNo pages classified as azure or sharepoint yet, skipping the length check."
}
else {
    # Only run the check for a destination that actually has pages
    # heading to it.
    if ($azurePages.Count -gt 0) {
        Invoke-DestinationCheck -bucket "azure" -destinationName "Azure DevOps Wiki" -maxPathLength $azureMaxPathLength `
            -urlPrompt "Azure DevOps wiki repo URL (e.g. https://dev.azure.com/yourorg/yourproject/_git/yourproject.wiki)" `
            -pagesInBucket $azurePages
    }

    if ($sharePointPages.Count -gt 0) {
        Invoke-DestinationCheck -bucket "sharepoint" -destinationName "SharePoint" -maxPathLength $sharePointMaxPathLength `
            -urlPrompt "SharePoint document library URL (e.g. https://yourorg.sharepoint.com/sites/YourSite/Shared Documents)" `
            -pagesInBucket $sharePointPages
    }
}

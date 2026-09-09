<#
Confluence storage HTML -> paste-ready HTML for SharePoint.

Automating SharePoint page creation needs an Entra ID app registration to
call the Graph API, and that's not something every account can do (needs
admin rights, or at least an admin's one-time consent). This script is the
fallback that works with nothing more than the page-editing access you
already have: it turns each page classified "sharepoint" in
page_destinations.csv into a clean, standalone .html file. Open it in a
browser, Ctrl+A, Ctrl+C, paste into a new SharePoint page's text web part,
done - no reformatting headings/tables/lists by hand.

Images can't survive that copy-paste (a pasted <img src="local/path"> has
nothing to load once it's in a browser's clipboard, there's no server
behind a relative local path), so each one becomes a visible placeholder
telling you which file to drag in manually from the images/ folder sitting
next to content.html, using SharePoint's own image tool.

Reads the same manifest.json + page_destinations.csv that
confluence_html_to_markdown.ps1 uses, so run that script first (at least
far enough to get pages classified in the CSV) before this one.

Run:
    .\confluence_sharepoint_paste.ps1

Written by Dan.
#>

# Loads .NET's "LINQ to XML" library, used to read and walk through each
# page's HTML content.
Add-Type -AssemblyName System.Xml.Linq

# Where confluence_extractor.ps1 saved everything, and where this
# script's own output goes.
$exportDir = "confluence_export"
$pasteExportDir = "confluence_sharepoint_paste"
$classificationPath = Join-Path $exportDir "page_destinations.csv"

$manifestPath = Join-Path $exportDir "manifest.json"

if (-not (Test-Path $manifestPath)) {
    Write-Host "Can't find manifest.json at $manifestPath."
    Write-Host "Run confluence_extractor.ps1 first."
    exit 1
}

if (-not (Test-Path $classificationPath)) {
    Write-Host "Can't find $classificationPath."
    Write-Host "Run confluence_html_to_markdown.ps1 first, at least far enough"
    Write-Host "to get pages classified as azure or sharepoint in that CSV."
    exit 1
}

# @()-wrapped: manifest.json legitimately can have exactly one page (the
# extractor's single-page mode), and ConvertFrom-Json hands back a bare
# object instead of a one-item array for a one-element JSON array.
$manifest = @(Get-Content $manifestPath -Raw | ConvertFrom-Json)

# Build a lookup: page id -> its destination ("azure", "sharepoint", or
# blank/other), read from the classification CSV.
$classificationLookup = @{}
foreach ($row in (Import-Csv -Path $classificationPath)) {
    $classificationLookup[$row.id] = ($row.destination -replace '\s', '').ToLower()
}

# @()-wrapped: without it, exactly one page classified "sharepoint" (easy
# to hit early in a migration, testing on just one page) would have
# PowerShell unwrap the filtered result to a bare object instead of a
# one-item array, and the .Count checks just below would misfire - this
# script would wrongly report "nothing to do" and convert nothing.
# This is the actual list of pages this script cares about - everything
# else in the manifest gets ignored (that's what confluence_html_to_markdown.ps1
# and the Azure git push are for).
$sharePointPages = @($manifest | Where-Object { $classificationLookup[$_.id] -eq "sharepoint" })

if (-not $sharePointPages -or $sharePointPages.Count -eq 0) {
    # Nothing classified "sharepoint" yet - nothing for this script to do.
    Write-Host "No pages classified 'sharepoint' in the CSV yet, nothing to do."
    exit 0
}

# Built from the full manifest, not just the sharepoint-classified subset,
# since a page's children (or parent) might be headed to Azure or still
# sitting unsorted - we still want to show their titles.
# This maps: parent page id -> list of its children's titles. Used later
# to build the "Related pages" section on each page (see
# Get-RelatedPagesHtml below).
$childrenByParentId = @{}
foreach ($pageEntry in $manifest) {
    if ($pageEntry.parent_id) {
        $parentKey = [string]$pageEntry.parent_id
        if (-not $childrenByParentId.ContainsKey($parentKey)) {
            $childrenByParentId[$parentKey] = @()
        }
        $childrenByParentId[$parentKey] += $pageEntry.title
    }
}

# Same namespace/entity handling as confluence_html_to_markdown.ps1 - see
# that script's comments for why these are needed.
$namespaceDeclarations = @'
xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/"
xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/"
'@

# Named HTML entities Confluence content commonly contains, mapped to
# their actual character (see confluence_html_to_markdown.ps1 for the
# full explanation of why this list exists at all).
$knownHtmlEntities = @{
    "nbsp"   = [char]0x0020
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

function ConvertTo-EscapedHtmlText {
    # Text pulled out of the XML is plain decoded content, not HTML-escaped
    # - a literal <, >, or & in the original page text would otherwise be
    # misread as markup once this gets written out as real HTML.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
}

function ConvertTo-EscapedHtmlAttr {
    # Same escaping as above, plus quotes, for text going inside an HTML
    # attribute like href="..." rather than as visible page text.
    param([string]$Value)
    return (ConvertTo-EscapedHtmlText $Value).Replace('"', "&quot;")
}

# Set once per page (see the main loop below) to that page's manifest
# "attachments" entry, mapping the original Confluence filename to whatever
# it actually got saved as - the image placeholder below points at the
# right file.
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
            # Manifest from before this mapping existed - best guess is
            # that the saved name matches the original one-for-one.
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
    # built, if one exists.
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

function Convert-NodeToHtml {
    # Walks an element's children in document order (text + child elements),
    # dispatching each child to its HTML equivalent. Real HTML elements nest
    # on their own, unlike the Markdown converter there's no need to track
    # list depth by hand.
    param([System.Xml.Linq.XElement]$node)

    $stringBuilder = New-Object System.Text.StringBuilder

    foreach ($childNode in $node.Nodes()) {
        if ($childNode -is [System.Xml.Linq.XText]) {
            # Plain text - escape it (see ConvertTo-EscapedHtmlText) and
            # add it as-is.
            [void]$stringBuilder.Append((ConvertTo-EscapedHtmlText $childNode.Value))
        }
        elseif ($childNode -is [System.Xml.Linq.XElement]) {
            # A nested tag - work out its own HTML equivalent.
            [void]$stringBuilder.Append((Convert-ElementToHtml $childNode))
        }
    }

    return $stringBuilder.ToString()
}

function Convert-ElementToHtml {
    # Given one specific tag, decides what real HTML it should become.
    # Unlike the Markdown converter, this is its own separate function
    # (not folded into Convert-NodeToHtml above), so it can be called
    # directly on a single element when needed (see "task-list" below).
    param([System.Xml.Linq.XElement]$childNode)

    $tag = $childNode.Name.LocalName

    switch ($tag) {
        # Headings carry straight across as real <h1>-<h6> tags.
        { $_ -in @("h1", "h2", "h3", "h4", "h5", "h6") } {
            return "<$tag>$(Convert-NodeToHtml $childNode)</$tag>"
        }

        # A paragraph.
        "p" { return "<p>$(Convert-NodeToHtml $childNode)</p>" }

        # A manual line break.
        "br" { return "<br>" }

        # Bold text.
        { $_ -in @("strong", "b") } { return "<strong>$(Convert-NodeToHtml $childNode)</strong>" }

        # Italic text.
        { $_ -in @("em", "i") } { return "<em>$(Convert-NodeToHtml $childNode)</em>" }

        # Inline code.
        "code" { return "<code>$(Convert-NodeToHtml $childNode)</code>" }

        "a" {
            # A regular hyperlink.
            $hrefAttribute = $childNode.Attributes() | Where-Object { $_.Name.LocalName -eq "href" } | Select-Object -First 1
            $linkText = Convert-NodeToHtml $childNode
            if ($hrefAttribute) {
                return "<a href=`"$(ConvertTo-EscapedHtmlAttr $hrefAttribute.Value)`">$linkText</a>"
            }
            return $linkText
        }

        "link" {
            # <ac:link> covers three different reference types depending on
            # which ri: child it wraps - page, attachment, or user.
            $pageRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "page" } | Select-Object -First 1
            $attachmentRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "attachment" } | Select-Object -First 1
            $userRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "user" } | Select-Object -First 1
            $linkText = (Convert-NodeToHtml $childNode).Trim()

            if ($attachmentRef) {
                # Link to a downloadable attachment (not an <ac:image>
                # embed) - same problem as images: a pasted
                # <a href="images/..."> can't resolve once it's in a
                # browser's clipboard, so this needs the same visible
                # placeholder treatment rather than a real link.
                $filenameAttribute = $attachmentRef.Attributes() | Where-Object { $_.Name.LocalName -eq "filename" } | Select-Object -First 1
                if ($filenameAttribute) {
                    $filename = $filenameAttribute.Value
                    $savedName = if ($script:currentAttachmentMap.ContainsKey($filename)) { $script:currentAttachmentMap[$filename] } else { $filename }
                    $displayText = if ($linkText) { $linkText } else { $filename }
                    $escapedFilename = ConvertTo-EscapedHtmlText $filename
                    $escapedSavedName = ConvertTo-EscapedHtmlText $savedName
                    return "$(ConvertTo-EscapedHtmlText $displayText) <strong>[ATTACH FILE HERE: `"$escapedFilename`" - find it in the images folder next to this file as `"$escapedSavedName`", then delete this placeholder]</strong>"
                }
                return ConvertTo-EscapedHtmlText $(if ($linkText) { $linkText } else { "attachment" })
            }

            if ($userRef) {
                # @mention - Confluence resolves this to a live profile link
                # we have no equivalent for, so at minimum keep the
                # person's name visible instead of losing who was
                # mentioned entirely.
                $userKeyAttribute = $userRef.Attributes() | Where-Object { $_.Name.LocalName -eq "userkey" } | Select-Object -First 1
                $usernameAttribute = $userRef.Attributes() | Where-Object { $_.Name.LocalName -eq "username" } | Select-Object -First 1
                $rawId = if ($userKeyAttribute) { $userKeyAttribute.Value } elseif ($usernameAttribute) { $usernameAttribute.Value } else { $null }
                $displayName = if ($rawId -and $script:userDisplayNames.ContainsKey($rawId)) { $script:userDisplayNames[$rawId] } else { $null }
                $shown = if ($displayName) { $displayName } elseif ($linkText) { $linkText } elseif ($rawId) { $rawId } else { "mentioned user" }
                return "@$(ConvertTo-EscapedHtmlText $shown)"
            }

            # Page link: no stable URL until the target's actually
            # migrated. Flag it visibly rather than as an HTML comment:
            # comments vanish silently on copy-paste into a rich text
            # editor, and the whole point is that a person notices this.
            $targetTitleAttribute = if ($pageRef) { $pageRef.Attributes() | Where-Object { $_.Name.LocalName -eq "content-title" } | Select-Object -First 1 }
            $targetTitle = if ($targetTitleAttribute) { $targetTitleAttribute.Value } else { $null }
            $displayText = if ($linkText) { $linkText } elseif ($targetTitle) { $targetTitle } else { "link" }
            if ($targetTitle) {
                return "$displayText <strong>[UNRESOLVED LINK: `"$(ConvertTo-EscapedHtmlText $targetTitle)`"]</strong>"
            }
            return "$displayText <strong>[UNRESOLVED LINK]</strong>"
        }

        "emoticon" {
            # Self-closing - <ac:emoticon ac:name="smile" ac:emoji-fallback="🙂"/>
            # emoji-fallback (when present) is the literal character, best
            # case. Older content without it just gets a Slack/GitHub-style
            # :name:.
            $fallbackAttribute = $childNode.Attributes() | Where-Object { $_.Name.LocalName -eq "emoji-fallback" } | Select-Object -First 1
            if ($fallbackAttribute) {
                return $fallbackAttribute.Value
            }
            $nameAttribute = $childNode.Attributes() | Where-Object { $_.Name.LocalName -eq "name" } | Select-Object -First 1
            if ($nameAttribute) {
                return ":$($nameAttribute.Value):"
            }
            return ""
        }

        "task-list" {
            # A checklist - each <ac:task> gets dispatched through this
            # same switch again (see the "task" case below), then all the
            # resulting <li> items get wrapped in a <ul>.
            $items = ($childNode.Elements() | Where-Object { $_.Name.LocalName -eq "task" } | ForEach-Object { Convert-ElementToHtml $_ }) -join ""
            return "<ul>$items</ul>"
        }

        "task" {
            # One checklist item - shown with a checked/unchecked box
            # character rather than a real HTML checkbox, since a real
            # <input type="checkbox"> is likely to get stripped out when
            # pasted into a rich text editor.
            $statusNode = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "task-status" } | Select-Object -First 1
            $bodyNode = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "task-body" } | Select-Object -First 1
            $isComplete = $statusNode -and ($statusNode.Value.Trim().ToLower() -eq "complete")
            $bodyHtml = if ($bodyNode) { (Convert-NodeToHtml $bodyNode).Trim() } else { "" }
            $checkbox = if ($isComplete) { "☑" } else { "☐" }
            return "<li>$checkbox $bodyHtml</li>"
        }

        "ul" {
            # A bulleted list - each <li> becomes a real <li>.
            $items = ($childNode.Elements() | Where-Object { $_.Name.LocalName -eq "li" } | ForEach-Object { "<li>$(Convert-NodeToHtml $_)</li>" }) -join ""
            return "<ul>$items</ul>"
        }

        "ol" {
            # A numbered list.
            $items = ($childNode.Elements() | Where-Object { $_.Name.LocalName -eq "li" } | ForEach-Object { "<li>$(Convert-NodeToHtml $_)</li>" }) -join ""
            return "<ol>$items</ol>"
        }

        "table" {
            # A real HTML table - unlike the Markdown pipe-table version,
            # multi-paragraph cells just work here without any special
            # handling, real <table> markup has no equivalent problem.
            $tableRows = $childNode.Descendants() | Where-Object { $_.Name.LocalName -eq "tr" }
            $rowIndex = 0
            $rowsHtml = foreach ($tableRow in $tableRows) {
                # First row gets <th> cells same as the Markdown converter's
                # header-row assumption - see that script's comments.
                $cellTag = if ($rowIndex -eq 0) { "th" } else { "td" }
                $tableCells = $tableRow.Elements() | Where-Object { $_.Name.LocalName -in @("th", "td") }
                $cellsHtml = ($tableCells | ForEach-Object { "<$cellTag>$(Convert-NodeToHtml $_)</$cellTag>" }) -join ""
                $rowIndex++
                "<tr>$cellsHtml</tr>"
            }
            return "<table><tbody>" + ($rowsHtml -join "") + "</tbody></table>"
        }

        "image" {
            # Confluence image, either an attachment reference or an
            # external URL - see the comments inside for why each is
            # handled differently.
            $attachmentRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "attachment" } | Select-Object -First 1
            $urlRef = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "url" } | Select-Object -First 1

            if ($attachmentRef) {
                $filenameAttribute = $attachmentRef.Attributes() | Where-Object { $_.Name.LocalName -eq "filename" } | Select-Object -First 1
                if ($filenameAttribute) {
                    $filename = $filenameAttribute.Value
                    # A pasted <img src="images/..."> can't resolve once it's
                    # in a browser's clipboard - there's no server behind a
                    # relative local path. Point at the real saved-to-disk
                    # name (see confluence_html_to_markdown.ps1 for why that
                    # can differ from the original) and leave a visible
                    # placeholder instead of a broken image.
                    $savedName = if ($script:currentAttachmentMap.ContainsKey($filename)) { $script:currentAttachmentMap[$filename] } else { $filename }
                    $escapedFilename = ConvertTo-EscapedHtmlText $filename
                    $escapedSavedName = ConvertTo-EscapedHtmlText $savedName
                    return "<p><strong>[INSERT IMAGE HERE: `"$escapedFilename`" - find it in the images folder next to this file as `"$escapedSavedName`", then delete this placeholder]</strong></p>"
                }
            }
            elseif ($urlRef) {
                # An external URL image, unlike an attachment, is already a
                # normal absolute web address - it survives copy-paste fine.
                $valueAttribute = $urlRef.Attributes() | Where-Object { $_.Name.LocalName -eq "value" } | Select-Object -First 1
                if ($valueAttribute) {
                    return "<img src=`"$(ConvertTo-EscapedHtmlAttr $valueAttribute.Value)`" alt=`"image`">"
                }
            }
            return ""
        }

        "structured-macro" {
            # Confluence's "macros" - special blocks like code samples or
            # coloured info panels. Only a few kinds get properly
            # translated below; anything else falls through to the visible
            # marker at the bottom.
            $nameAttribute = $childNode.Attributes() | Where-Object { $_.Name.LocalName -eq "name" } | Select-Object -First 1
            $macroName = if ($nameAttribute) { $nameAttribute.Value } else { "unknown" }

            if ($macroName -eq "code") {
                # A code block.
                $bodyNode = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "plain-text-body" } | Select-Object -First 1
                $codeText = if ($bodyNode) { $bodyNode.Value } else { "" }
                return "<pre><code>$(ConvertTo-EscapedHtmlText $codeText)</code></pre>"
            }

            if ($macroName -in @("info", "note", "warning", "tip")) {
                # A coloured panel - shown as a blockquote with a bold
                # label naming which kind it was.
                $bodyNode = $childNode.Elements() | Where-Object { $_.Name.LocalName -eq "rich-text-body" } | Select-Object -First 1
                $innerHtml = if ($bodyNode) { (Convert-NodeToHtml $bodyNode).Trim() } else { "" }
                return "<blockquote><strong>$($macroName.ToUpper()):</strong> $innerHtml</blockquote>"
            }

            # Same "keep the visible text, flag it" approach as the Markdown
            # converter, just with a visible marker instead of an HTML
            # comment (comments vanish on copy-paste, see "link" above).
            $innerHtml = (Convert-NodeToHtml $childNode).Trim()
            $marker = "<p><strong>[UNRECOGNISED CONFLUENCE MACRO: $(ConvertTo-EscapedHtmlText $macroName)]</strong></p>"
            return $marker + $innerHtml
        }

        default {
            # Unknown tag: recurse into it so we don't lose the text inside
            return Convert-NodeToHtml $childNode
        }
    }
}

function Get-RelatedPagesHtml {
    # A lightweight stand-in for Confluence's always-visible page tree -
    # SharePoint has no direct equivalent, so each page gets its own
    # parent/children links instead. Same visible-marker treatment as
    # unresolved in-body links (see the "link" case above): none of these
    # pages have real SharePoint URLs yet, so there's nothing to link to
    # until they're actually migrated.
    param($pageEntry, $childrenByParentId)

    $parentTitle = $pageEntry.parent_title
    $childrenTitles = if ($childrenByParentId.ContainsKey([string]$pageEntry.id)) { $childrenByParentId[[string]$pageEntry.id] } else { @() }

    if (-not $parentTitle -and $childrenTitles.Count -eq 0) {
        # No parent and no children recorded - nothing to show, and
        # nothing extra gets added to the page.
        return ""
    }

    $parts = @("<hr>", "<h2>Related pages</h2>")

    if ($parentTitle) {
        $parts += "<p><strong>Parent page:</strong> [UNRESOLVED LINK: `"$(ConvertTo-EscapedHtmlText $parentTitle)`"]</p>"
    }

    if ($childrenTitles.Count -gt 0) {
        $parts += "<p><strong>Sub-pages:</strong></p>"
        $items = ($childrenTitles | ForEach-Object { "<li>[UNRESOLVED LINK: `"$(ConvertTo-EscapedHtmlText $_)`"]</li>" }) -join ""
        $parts += "<ul>$items</ul>"
    }

    return ($parts -join "")
}

# The overall skeleton every output page gets wrapped in. {0}-{3} get
# filled in per page further down: title, tags line, main body, and the
# related-pages section.
$pageTemplate = @'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>{0}</title>
</head>
<body>
<p><strong>PAGE TITLE (set this as the SharePoint page name, then delete this line): {0}</strong></p>
{1}
{2}
{3}
</body>
</html>
'@

$totalPages = $sharePointPages.Count
$pageIndex = 0
# Anything that goes wrong on a specific page gets noted here rather than
# stopping the whole run.
$warnings = @()

$script:userDisplayNames = Get-UserDisplayNames

# Go through every sharepoint-classified page, one at a time.
foreach ($pageEntry in $sharePointPages) {
    $pageIndex++
    $htmlPath = Join-Path $exportDir (Join-Path $pageEntry.folder $pageEntry.html_file)
    $destinationFolder = Join-Path $pasteExportDir $pageEntry.folder

    Write-Host "[$pageIndex/$totalPages] $($pageEntry.title)"

    if (-not (Test-Path $htmlPath)) {
        Write-Host "    Skipped: content.html not found at $htmlPath"
        $warnings += "$($pageEntry.title): content.html not found"
        continue
    }

    try {
        New-Item -ItemType Directory -Force -Path $destinationFolder | Out-Null

        # Read the page's raw content, and fix up any named entities the
        # XML parser wouldn't otherwise understand.
        $rawHtml = Get-Content $htmlPath -Raw -Encoding UTF8
        $rawHtml = ConvertTo-XmlSafeEntities $rawHtml

        # Build this page's own filename -> saved_as lookup, used above
        # while converting this specific page's images/attachments.
        $script:currentAttachmentMap = Get-AttachmentMap $pageEntry.attachments

        # Wrap in a root element with the Confluence namespaces declared,
        # then actually parse it as XML.
        $wrappedHtml = "<root $namespaceDeclarations>$rawHtml</root>"
        $rootElement = [System.Xml.Linq.XElement]::Parse($wrappedHtml)

        # Do the real conversion, plus build the "Related pages" section
        # and the Tags line (if this page has any labels).
        $bodyHtml = Convert-NodeToHtml $rootElement
        $relatedPagesHtml = Get-RelatedPagesHtml $pageEntry $childrenByParentId

        $tagsHtml = if ($pageEntry.labels -and $pageEntry.labels.Count -gt 0) {
            "<p><strong>Tags:</strong> $(ConvertTo-EscapedHtmlText ($pageEntry.labels -join ', '))</p>"
        } else { "" }

        # Slot everything into the page template from above.
        $pageHtml = $pageTemplate -f (ConvertTo-EscapedHtmlText $pageEntry.title), $tagsHtml, $bodyHtml, $relatedPagesHtml

        # Save the finished, paste-ready HTML file.
        $outputPath = Join-Path $destinationFolder "content.html"
        [System.IO.File]::WriteAllText($outputPath, $pageHtml, (New-Object System.Text.UTF8Encoding($false)))

        # Copy this page's images across too, so you've got them handy
        # next to content.html when it's time to manually add them back
        # in via SharePoint's own image tool.
        $sourceImagesFolder = Join-Path $exportDir (Join-Path $pageEntry.folder "images")
        if (Test-Path $sourceImagesFolder) {
            $destinationImagesFolder = Join-Path $destinationFolder "images"
            Copy-Item -Path $sourceImagesFolder -Destination $destinationImagesFolder -Recurse -Force
        }
    }
    catch {
        # Something about converting this one page failed - note it and
        # move on to the next page rather than stopping the whole run.
        Write-Host "    Failed to convert '$($pageEntry.title)':" $_.Exception.Message
        $warnings += "$($pageEntry.title): $($_.Exception.Message)"
    }
}

$convertedCount = $totalPages - $warnings.Count
Write-Host ""
Write-Host "Done. Converted $convertedCount of $totalPages pages."
Write-Host "Output saved to: $pasteExportDir\"
Write-Host ""
Write-Host "For each page: open its content.html in a browser, Ctrl+A, Ctrl+C."
Write-Host "In SharePoint, + New Page > Blank, paste into the text web part."
Write-Host "Use the first line to set the page's real title, then delete it."
Write-Host "Wherever you see '[INSERT IMAGE HERE: ...]', use SharePoint's own"
Write-Host "image tool to add that file from the images folder next to"
Write-Host "content.html, then delete the placeholder text."
Write-Host "Also look out for '[UNRESOLVED LINK: ...]' and '[UNRECOGNISED"
Write-Host "CONFLUENCE MACRO: ...]' markers and fix those up by hand too."

if ($warnings.Count -gt 0) {
    Write-Host "`n$($warnings.Count) page(s) had issues:"
    foreach ($warning in $warnings) {
        Write-Host "  - $warning"
    }
}

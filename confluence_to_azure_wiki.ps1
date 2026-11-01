<#
Confluence Markdown to Azure DevOps Wiki layout - PowerShell version.

Takes the pages confluence_html_to_markdown sorted into "azure" and lays
them out the way an Azure DevOps Wiki repo expects, so pushing them is
the whole job rather than the start of a clean-up:

  - one file per page, named after the page (How-to-deploy.md), not a
    folder of content.md files that would all show up titled "content"
  - sub-pages in a folder named after their parent page, following the
    Confluence page tree (a page whose parent went to SharePoint moves up
    to its nearest parent that's coming to the wiki, or to the top)
  - a .order file in every folder, so pages keep their Confluence order
    instead of going alphabetical
  - images and attachments in the wiki's .attachments folder, with the
    links pointing at them
  - links between pages turned into real wiki links - anything that
    can't be (the page went to SharePoint, lives in another space, or no
    longer exists) stays flagged and is listed in wiki_link_report.csv
  - page names that break the wiki's rules (/ \ #, a hyphen or colon in
    the title, too long a path) fixed up the way the wiki itself does

Pure local file processing - doesn't touch Confluence or Azure DevOps.
Builds into a fresh folder, never into your wiki repo directly, and never
pushes anything: copying the result in and pushing is left to you.

    .\confluence_to_azure_wiki.ps1
    .\confluence_to_azure_wiki.ps1 -ExportDir "S:\Exports\confluence_export_TEAM"

Asks for the export folder, the Markdown folder and where to build the
wiki. Set CONFLUENCE_EXPORT_DIR, CONFLUENCE_MARKDOWN_EXPORT_DIR,
CONFLUENCE_WIKI_EXPORT_DIR and CONFLUENCE_WIKI_REPO_URL to skip the
questions.

Something broken or unclear? Raise an issue at
https://github.com/DCodeAus/AtlassianConfluenceScraping/issues
#>

param(
    # The export folder whose Markdown to lay out. Asked for if not given.
    [string]$ExportDir
)

# Everything the scripts here have in common - the questions, reading an
# export folder - lives in confluence_common.ps1, so a fix there fixes
# every script at once. It has to be in the same folder as this one.
$commonScript = Join-Path $PSScriptRoot "confluence_common.ps1"
if (-not (Test-Path -LiteralPath $commonScript)) {
    Write-Host "Can't find confluence_common.ps1 - it needs to be in the same folder"
    Write-Host "as this script. Download the whole repository rather than just this"
    Write-Host "one file."
    exit 1
}
. $commonScript

# The wiki caps a page's full path - repo URL, folders and file name - at
# 235 characters. Anything longer is trimmed, keeping the page id so
# trimmed names can't collide.
$AzureMaxPathLength = 235

# Characters a wiki page title can contain but its file name has to carry
# encoded - a hyphen in the file name means a space in the title, so a
# real hyphen needs its own code. "%" goes first so the codes added after
# it aren't encoded a second time.
$WikiEncodedCharacters = @(
    @("%", "%25"), @("-", "%2D"), @(":", "%3A"), @("<", "%3C"), @(">", "%3E"),
    @("*", "%2A"), @("?", "%3F"), @("|", "%7C"), @('"', "%22")
)

# Written into the output folder so a re-run knows it's safe to clear it
# out - a folder without it is never deleted.
$OutputMarker = ".confluence_to_azure_wiki"

# The converter wraps each link to another page between these two comments
# (see confluence_html_to_markdown) - start, link text, end. (?s) lets the
# link text run over more than one line.
$PageLinkPattern = '(?s)<!-- internal Confluence link to "(?<title>.*?)"(?: \(space (?<space>[^)]*)\))? -->(?<text>.*?)<!-- end of internal link -->'
# Older converter output had no start marker, so there's no telling where
# the link text began - these can only be counted and pointed out.
$OldPageLinkPattern = '<!-- internal Confluence link, unresolved'
$ImageLinkPattern = '\]\(<images/(?<name>[^>]*)>\)'

function ConvertTo-WikiPageName {
    # A page title as the wiki's file name (without .md): / and \ can't
    # appear at all, so they become a hyphen in the title; # is dropped;
    # the characters in $WikiEncodedCharacters are encoded; and spaces
    # become hyphens. "Q3/Q4: plan" -> "Q3%2DQ4%3A-plan", which the wiki
    # shows as "Q3-Q4: plan".
    param([string]$Title, [string]$PageId)
    $name = $Title -replace '[\x00-\x1f\x7f]', ''
    $name = ($name -replace '[/\\]', '-').Replace("#", "")
    $name = $name.Trim().Trim('.').Trim()
    foreach ($pair in $WikiEncodedCharacters) {
        $name = $name.Replace($pair[0], $pair[1])
    }
    $name = $name -replace '\s+', '-'
    if (-not $name) { $name = "Page-$PageId" }
    return $name
}

function Get-TrimmedPageName {
    # Shortens a page name to fit in $Room characters, ending in -<page id>
    # so it stays unique, and never cutting an encoded character (%2D) in half.
    param([string]$Name, [string]$PageId, [int]$Room)
    $suffix = "-$PageId"
    $keep = [Math]::Max(1, $Room - $suffix.Length)
    $trimmed = if ($Name.Length -gt $keep) { $Name.Substring(0, $keep) } else { $Name }
    # Back off if the cut landed inside a %XX code.
    $trimmed = $trimmed -replace '%[0-9A-Fa-f]?$', ''
    return $trimmed + $suffix
}

function Get-NearestWikiParent {
    # The closest ancestor that's also coming to the wiki, so a page whose
    # parent went to SharePoint (or was discarded) still sits in the right
    # branch - or "" for the top level.
    param($Page)
    $seen = @{}
    $parentId = [string]$Page.parent_id
    while ($parentId -and -not $seen.ContainsKey($parentId)) {
        $seen[$parentId] = $true
        if ($wikiIds.ContainsKey($parentId)) { return $parentId }
        $parent = $pagesById[$parentId]
        $parentId = if ($parent) { [string]$parent.parent_id } else { "" }
    }
    return ""
}

# --- The questions ---
$exportDirHelp = @(
    "The export you converted with confluence_html_to_markdown - the",
    "same folder name you gave the extractor for this space.",
    "Leave blank for: confluence_export"
)
$ExportDir = Read-ExportDir -Value $ExportDir -Prompt "Export folder (blank for 'confluence_export')" -HelpText $exportDirHelp
$manifest = (Get-ExportManifest $ExportDir).Manifest

$suggestedMarkdownDir = Get-SuggestedOutputDir -ExportDir $ExportDir -Prefix "confluence_markdown_export"
$markdownDir = $env:CONFLUENCE_MARKDOWN_EXPORT_DIR
if (-not $markdownDir) {
    $markdownHelp = @(
        "Where confluence_html_to_markdown put the converted pages - the",
        "folder with azure/, sharepoint/ etc. inside it.",
        "Leave blank for: $suggestedMarkdownDir"
    )
    $markdownDir = (Read-HostWithHelp "Markdown folder (blank for '$suggestedMarkdownDir')" $markdownHelp).Trim()
}
if (-not $markdownDir) { $markdownDir = $suggestedMarkdownDir }
$azureDir = Join-Path $markdownDir "azure"

$classificationPath = Join-Path $ExportDir "page_destinations.csv"
if (-not (Test-Path -LiteralPath $classificationPath) -or -not (Test-Path -LiteralPath $azureDir -PathType Container)) {
    Write-Host "Can't find the converted pages - run confluence_html_to_markdown on"
    Write-Host "'$ExportDir' first (and mark the pages for the wiki 'azure' in"
    Write-Host "page_destinations.csv), then run this again."
    exit 1
}
# Read the same way confluence_html_to_markdown.ps1 does. Values
# normalised so " Azure " matches.
$classification = @{}
foreach ($row in @(Import-Csv -LiteralPath $classificationPath)) {
    $classification[[string]$row.id] = ([string]$row.destination -replace '\s', '').ToLower()
}

$suggestedOutputDir = Get-SuggestedOutputDir -ExportDir $ExportDir -Prefix "confluence_azure_wiki"
$outputDir = $env:CONFLUENCE_WIKI_EXPORT_DIR
if (-not $outputDir) {
    $outputHelp = @(
        "A NEW folder to lay the wiki out in - not your wiki clone itself.",
        "You copy what's in it into the clone afterwards (instructions at",
        "the end). Re-running this rebuilds it from scratch.",
        "Leave blank for: $suggestedOutputDir"
    )
    $outputDir = (Read-HostWithHelp "Folder to build the wiki in (blank for '$suggestedOutputDir')" $outputHelp).Trim()
}
if (-not $outputDir) { $outputDir = $suggestedOutputDir }

# Set-but-empty means "don't ask" (used for unattended runs).
$repoUrl = [Environment]::GetEnvironmentVariable("CONFLUENCE_WIKI_REPO_URL")
if ($null -eq $repoUrl) {
    $repoHelp = @(
        "The wiki caps a page's full path, INCLUDING the repo's URL, at 235",
        "characters. In Azure DevOps, open the Wiki, then ... > Clone wiki,",
        "and paste the URL, e.g.",
        "https://dev.azure.com/yourorg/yourproject/_git/yourproject.wiki",
        "Blank still checks, just without the URL's share of the length."
    )
    $repoUrl = Read-HostWithHelp "Wiki repo URL, for the path length check (blank to estimate)" $repoHelp
}
$repoUrl = "$repoUrl".Trim().TrimEnd('/')

# --- Which pages, and where each one goes ---
$pagesById = @{}
foreach ($page in $manifest) { $pagesById[[string]$page.id] = $page }
$wikiPages = @($manifest | Where-Object { $classification[[string]$_.id] -eq "azure" })
if ($wikiPages.Count -eq 0) {
    Write-Host "No pages are marked 'azure' in page_destinations.csv, so there's nothing"
    Write-Host "for the wiki. Mark the ones that belong there and run the converter again."
    exit 1
}
$wikiIds = @{}
foreach ($page in $wikiPages) { $wikiIds[[string]$page.id] = $true }
$spaceKey = (Get-ExportSource $ExportDir).spaceKey

$wikiParent = @{}
foreach ($page in $wikiPages) { $wikiParent[[string]$page.id] = Get-NearestWikiParent $page }
# A page tree that loops back on itself (shouldn't happen, but a corrupt
# manifest shouldn't lose pages) would leave those pages with no way down
# from the top - put them at the top level instead.
foreach ($pageId in @($wikiParent.Keys)) {
    $seen = @{}
    $current = $pageId
    while ($current -and -not $seen.ContainsKey($current)) {
        $seen[$current] = $true
        $current = $wikiParent[$current]
    }
    if ($current) { $wikiParent[$pageId] = "" }
}
# Parent id ("" = top level) -> child pages, in manifest order.
$children = [ordered]@{}
foreach ($page in $wikiPages) {
    $parentId = $wikiParent[[string]$page.id]
    if (-not $children.Contains($parentId)) { $children[$parentId] = New-Object System.Collections.ArrayList }
    [void]$children[$parentId].Add($page)
}

$pathOf = @{}  # page id -> page names from the top, e.g. @("Ops", "Deploy")
$renamed = New-Object System.Collections.ArrayList
$prefixLength = if ($repoUrl) { $repoUrl.Length + 1 } else { 0 }

function Set-PagePlaces {
    param([string]$ParentId, [string[]]$ParentPath)
    # Unique within its folder - PowerShell's @{} ignores case, which is
    # what's wanted, since Windows can't hold two files differing only by case.
    $used = @{}
    if (-not $children.Contains($ParentId)) { return }
    foreach ($page in $children[$ParentId]) {
        $pageId = [string]$page.id
        $name = ConvertTo-WikiPageName -Title $page.title -PageId $pageId
        if ($used.ContainsKey($name)) { $name = "$name-$pageId" }
        $folder = $ParentPath -join "/"
        $fullLength = $prefixLength + $(if ($folder) { $folder.Length + 1 } else { 0 }) + $name.Length + ".md".Length
        if ($fullLength -gt $AzureMaxPathLength) {
            $room = $name.Length - ($fullLength - $AzureMaxPathLength)
            $name = Get-TrimmedPageName -Name $name -PageId $pageId -Room $room
            [void]$renamed.Add($page.title)
        }
        $used[$name] = $true
        $script:pathOf[$pageId] = @($ParentPath) + @($name)
        Set-PagePlaces -ParentId $pageId -ParentPath $script:pathOf[$pageId]
    }
}
Set-PagePlaces -ParentId "" -ParentPath @()

# PowerShell's @{} ignores case, Confluence titles don't - so look titles up
# in a case-sensitive table instead.
$wikiPageByTitle = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
foreach ($page in $wikiPages) { $wikiPageByTitle[[string]$page.title] = $page }
$pageByTitle = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
foreach ($page in $manifest) { if (-not $pageByTitle.ContainsKey([string]$page.title)) { $pageByTitle[[string]$page.title] = $page } }

# A page can show an image that's attached to a different page - the
# converter only knows its file name, so it's not in this page's own
# images folder. If exactly one page in the export has an attachment by
# that name, that's the one: original name -> list of (page id, saved file).
$attachmentOwners = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
foreach ($page in $manifest) {
    foreach ($entry in @($page.attachments)) {
        if ($entry -and $entry.PSObject.Properties.Match("saved_as").Count -gt 0) {
            $saved = [System.IO.Path]::Combine($ExportDir, (Get-NormalisedRelativePath $page.folder), "images", $entry.saved_as)
            if (-not $attachmentOwners.ContainsKey($entry.filename)) { $attachmentOwners[$entry.filename] = New-Object System.Collections.ArrayList }
            [void]$attachmentOwners[$entry.filename].Add(@([string]$page.id, $saved))
        }
    }
}

# --- Build it ---
# Clears out a previous run's output so pages renamed or moved since don't
# linger - but only a folder this script made. Refuses a git repo outright,
# in case it's pointed at the wiki clone itself.
if (Test-Path -LiteralPath (Join-Path $outputDir ".git")) {
    Write-Host "'$outputDir' is a git repo - probably your wiki clone. This builds"
    Write-Host "into a separate folder that you then copy into the clone, so it"
    Write-Host "can never delete anything that's already in your wiki. Pick another"
    Write-Host "folder name (or leave it blank for the default) and run this again."
    exit 1
}
if ((Test-Path -LiteralPath $outputDir -PathType Container) -and @(Get-ChildItem -LiteralPath $outputDir -Force).Count -gt 0) {
    if (-not (Test-Path -LiteralPath (Join-Path $outputDir $OutputMarker))) {
        Write-Host "'$outputDir' already exists and wasn't made by this script, so it's"
        Write-Host "been left alone. Pick an empty or new folder and run this again."
        exit 1
    }
    Remove-Item -LiteralPath $outputDir -Recurse -Force
    Write-Host "Cleared the previous build in '$outputDir'."
}
[void](New-Item -ItemType Directory -Path $outputDir -Force)
# .NET's file functions don't follow PowerShell's "cd", so work from the
# full path from here on.
$outputDir = (Resolve-Path -LiteralPath $outputDir).Path
Set-Utf8NoBomContent -Path (Join-Path $outputDir $OutputMarker) -Value "Built by confluence_to_azure_wiki - safe for it to clear and rebuild.`nDon't copy this file into your wiki repo.`n"
$attachmentsDir = Join-Path $outputDir ".attachments"

$script:linkReport = New-Object System.Collections.ArrayList
$script:missingImages = New-Object System.Collections.ArrayList
$notConverted = New-Object System.Collections.ArrayList
$script:linked = 0
$script:attachmentCount = 0
$oldStyleLinks = 0

foreach ($page in $wikiPages) {
    $script:currentPage = $page
    $script:sourceFolder = Join-Path $azureDir (Get-NormalisedRelativePath $page.folder)
    # content.md, or a shorter name the converter's length check gave it.
    # @()-wrapped so a folder with exactly one .md still counts as one.
    $markdownFiles = @(if (Test-Path -LiteralPath $script:sourceFolder) { Get-ChildItem -LiteralPath $script:sourceFolder -Filter "*.md" -File | Sort-Object Name })
    if ($markdownFiles.Count -gt 0) {
        $markdown = Read-Utf8Text $markdownFiles[0].FullName
    }
    else {
        [void]$notConverted.Add($page.title)
        $markdown = "> **NOTE:** This page couldn't be converted from Confluence, so it's empty here. Check the converter's output for `"$($page.title)`".`n"
    }

    # The converter starts every page with "# <title>" - the wiki already
    # shows the page name as its title, so it'd appear twice.
    $markdown = $markdown -replace '\A# [^\n]*\n+', ''

    $relinkImage = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        $name = $match.Groups["name"].Value
        $source = [System.IO.Path]::Combine($script:sourceFolder, "images", $name)
        $ownerId = [string]$script:currentPage.id
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            # Borrowed from another page? Only if exactly one page has it.
            $owners = @()
            if ($attachmentOwners.ContainsKey($name)) {
                $owners = @($attachmentOwners[$name] | Where-Object { Test-Path -LiteralPath $_[1] -PathType Leaf })
            }
            if ($owners.Count -ne 1) {
                [void]$script:missingImages.Add("$($script:currentPage.title): $name")
                return $match.Value
            }
            $ownerId = $owners[0][0]
            $source = $owners[0][1]
        }
        # Every page's attachments share one folder, so the id of the page
        # it's attached to keeps two pages' "image.png" apart.
        $newName = $ownerId + "-" + ([System.IO.Path]::GetFileName($source) -replace '\s+', '-')
        $destination = Join-Path $attachmentsDir $newName
        if (-not (Test-Path -LiteralPath $destination)) {
            [void](New-Item -ItemType Directory -Path $attachmentsDir -Force)
            Copy-Item -LiteralPath $source -Destination $destination
            $script:attachmentCount++
        }
        return "](</.attachments/$newName>)"
    }
    $markdown = [regex]::Replace($markdown, $ImageLinkPattern, $relinkImage)

    $relinkPage = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        $title = $match.Groups["title"].Value
        $space = $match.Groups["space"].Value
        $text = $match.Groups["text"].Value
        $target = $wikiPageByTitle[$title]
        if ($space -and $spaceKey -and $space -ne $spaceKey) {
            $reason = "in another space ($space)"
        }
        elseif ($target) {
            $script:linked++
            return "[$text](</$($pathOf[[string]$target.id] -join '/')>)"
        }
        else {
            $inExport = $pageByTitle[$title]
            if (-not $inExport) {
                $reason = "not in this export (deleted, or in another space)"
            }
            else {
                $destination = $classification[[string]$inExport.id]
                if (-not $destination) { $destination = "not classified" }
                $reason = "going to $destination, not the wiki"
            }
        }
        [void]$script:linkReport.Add([pscustomobject]@{ page = $script:currentPage.title; link_text = $text; links_to = $title; reason = $reason })
        return $match.Value
    }
    $markdown = [regex]::Replace($markdown, $PageLinkPattern, $relinkPage)
    $oldStyleLinks += ([regex]::Matches($markdown, [regex]::Escape($OldPageLinkPattern))).Count

    $pagePath = [System.IO.Path]::Combine([string[]](@($outputDir) + $pathOf[[string]$page.id])) + ".md"
    [void](New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($pagePath)) -Force)
    Set-Utf8NoBomContent -Path $pagePath -Value $markdown
}

# One .order per folder, listing its pages in Confluence's order.
foreach ($parentId in $children.Keys) {
    $folder = if ($parentId) { [System.IO.Path]::Combine([string[]](@($outputDir) + $pathOf[$parentId])) } else { $outputDir }
    [void](New-Item -ItemType Directory -Path $folder -Force)
    $lines = ($children[$parentId] | ForEach-Object { $pathOf[[string]$_.id][-1] + "`n" }) -join ""
    Set-Utf8NoBomContent -Path (Join-Path $folder ".order") -Value $lines
}

# The report, with a BOM so Excel reads accented titles properly (the same
# as the Python version's utf-8-sig).
$reportPath = Join-Path $ExportDir "wiki_link_report.csv"
$reportLines = if ($script:linkReport.Count -gt 0) { $script:linkReport | ConvertTo-Csv -NoTypeInformation } else { @('"page","link_text","links_to","reason"') }
[System.IO.File]::WriteAllText([System.IO.Path]::Combine((Resolve-Path -LiteralPath $ExportDir).Path, "wiki_link_report.csv"), (($reportLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

# --- What happened, and what to do next ---
Write-Host "`nBuilt $($wikiPages.Count) wiki page(s) in '$outputDir'."
Write-Host "  $($script:linked) link(s) between pages turned into wiki links"
Write-Host "  $($script:attachmentCount) image(s)/attachment(s) copied to .attachments"
if ($script:linkReport.Count -gt 0) {
    Write-Host "  $($script:linkReport.Count) link(s) left flagged - the page they point to isn't"
    Write-Host "  coming to the wiki. Listed in $reportPath"
}
if ($renamed.Count -gt 0) {
    Write-Host "  $($renamed.Count) page name(s) trimmed to fit the $AzureMaxPathLength-character path limit:"
    foreach ($title in @($renamed | Select-Object -First 15)) { Write-Host "    - $title" }
}
if ($script:missingImages.Count -gt 0) {
    Write-Host "  $($script:missingImages.Count) image(s) a page shows couldn't be found in the export (not"
    Write-Host "  saved, or borrowed from another space) - their links are left as they were:"
    foreach ($item in @($script:missingImages | Select-Object -First 15)) { Write-Host "    - $item" }
}
if ($notConverted.Count -gt 0) {
    Write-Host "  $($notConverted.Count) page(s) had no converted Markdown - each is a placeholder"
    Write-Host "  saying so. Check the converter's warnings for:"
    foreach ($title in @($notConverted | Select-Object -First 15)) { Write-Host "    - $title" }
}
if ($oldStyleLinks -gt 0) {
    Write-Host "  $oldStyleLinks link(s) are in the converter's OLD format, which this can't"
    Write-Host "  turn into wiki links. Run confluence_html_to_markdown again (this"
    Write-Host "  version), then this script again, to fix them."
}

Write-Host "`nNext - into the wiki (needs git, https://git-scm.com):"
Write-Host "  1. In Azure DevOps: Wiki > ... > Clone wiki, copy the URL, then:"
Write-Host "       git clone <that URL>"
Write-Host "  2. Copy EVERYTHING inside '$outputDir' into the cloned folder,"
Write-Host "     hidden .order files and .attachments included, except $OutputMarker."
Write-Host "     If the wiki already has pages, merge the top-level .order by hand"
Write-Host "     (keep its lines and add these) rather than replacing it."
Write-Host "  3. In the cloned folder:"
Write-Host "       git add -A"
Write-Host "       git commit -m `"Import pages from Confluence`""
Write-Host "       git push"
Write-Host "Check a few pages in the wiki before telling anyone it's moved."

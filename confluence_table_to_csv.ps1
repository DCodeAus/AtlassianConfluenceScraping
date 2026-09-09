<#
Pulls one table off one Confluence page and writes it out as a CSV, ready
for SharePoint's own "Create list from CSV/Excel" import.

For a page that's really just a table (an on-call register, say) this is
usually a better fit in SharePoint as a proper List than as a wiki-style
page - filterable, sortable, a Calendar view if it's date-based, and you
can wire up a Power Automate flow against it. Creating that List doesn't
need any API access though, SharePoint can build one straight from a CSV
through its own UI, no Entra ID app registration involved. So this script
only does the local half: read the table out of Confluence's storage HTML,
write it as a clean CSV. You do the SharePoint side yourself.

Reads manifest.json from confluence_extractor.ps1 (or the .py version), so
run that first.

Run:
    .\confluence_table_to_csv.ps1 "On Call Register"
    .\confluence_table_to_csv.ps1 123456789   # page id also works

Written by Dan.
#>

# The one thing you actually have to supply when running this script -
# either a page's exact title (in quotes if it has spaces) or its numeric
# id. See Find-Page below for how this gets matched.
param(
    [Parameter(Mandatory = $true)]
    [string]$PageQuery
)

# Loads .NET's "LINQ to XML" library, used to read and walk through the
# page's HTML content.
Add-Type -AssemblyName System.Xml.Linq

# Where confluence_extractor.ps1 saved everything, and where this
# script's own output (the CSV files) goes.
$exportDir = "confluence_export"
$tableExportDir = "confluence_table_export"

# Confluence storage format uses ac:/ri: prefixed elements alongside plain
# XHTML - declaring these namespaces is what lets the XML parser
# understand them.
$namespaceDeclarations = @'
xmlns:ac="http://www.atlassian.com/schema/confluence/4/ac/"
xmlns:ri="http://www.atlassian.com/schema/confluence/4/ri/"
'@

# Same list as the other converters - see confluence_html_to_markdown.ps1
# for why these specific ones.
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

function Get-SanitisedFilename {
    # Windows/Mac/Linux all disallow certain characters in file names -
    # this swaps every one of them for an underscore, so a page title can
    # always be safely used as part of a CSV file's name.
    param([string]$Name)
    $invalidChars = '<>:"/\|?*'
    $result = $Name
    foreach ($ch in $invalidChars.ToCharArray()) {
        $result = $result.Replace([string]$ch, "_")
    }
    return $result.Trim()
}

function Convert-NodeToPlainText {
    # Plain text only - a CSV cell has no room for links/formatting, just
    # the visible words. <p>/<br> become line breaks within the cell,
    # which Get-CellText below then flattens to a single readable line.
    param([System.Xml.Linq.XElement]$node)

    $stringBuilder = New-Object System.Text.StringBuilder

    foreach ($childNode in $node.Nodes()) {
        if ($childNode -is [System.Xml.Linq.XText]) {
            # Plain text - just add it as-is.
            [void]$stringBuilder.Append($childNode.Value)
        }
        elseif ($childNode -is [System.Xml.Linq.XElement]) {
            $tag = $childNode.Name.LocalName
            if ($tag -eq "br") {
                [void]$stringBuilder.Append("`n")
            }
            elseif ($tag -eq "p") {
                [void]$stringBuilder.Append("`n" + (Convert-NodeToPlainText $childNode) + "`n")
            }
            else {
                # Anything else (bold, a link, etc) - just keep its
                # visible text, formatting doesn't matter in a CSV cell.
                [void]$stringBuilder.Append((Convert-NodeToPlainText $childNode))
            }
        }
    }

    return $stringBuilder.ToString()
}

function Get-CellText {
    # Turns one table cell into a single clean line of text for the CSV.
    param([System.Xml.Linq.XElement]$cell)
    $text = (Convert-NodeToPlainText $cell).Trim()
    # Collapse a cell with multiple paragraphs/line breaks down to one
    # readable line rather than an embedded multi-line CSV field.
    return ($text -replace '\s*\n\s*', '; ')
}

function Get-TablesFromPage {
    # Every <table> on the page, each as a list of rows (list of cell
    # strings), first row assumed to be the header - same assumption the
    # other converters make.
    #
    # Built with List[object].Add() throughout, not @()/+= - PowerShell's
    # += silently flattens nested arrays by a level in exactly this
    # "list of lists" shape, even with the usual unary-comma workaround.
    # .Add() has no such ambiguity.
    param([System.Xml.Linq.XElement]$rootElement)

    $tables = [System.Collections.Generic.List[object]]::new()
    # Find every <table> anywhere on the page.
    foreach ($tableElement in $rootElement.Descendants() | Where-Object { $_.Name.LocalName -eq "table" }) {
        $rows = [System.Collections.Generic.List[object]]::new()
        # Within this one table, go row by row, cell by cell.
        foreach ($tableRow in $tableElement.Descendants() | Where-Object { $_.Name.LocalName -eq "tr" }) {
            $cells = $tableRow.Elements() | Where-Object { $_.Name.LocalName -in @("th", "td") }
            $cellValues = [System.Collections.Generic.List[string]]::new()
            foreach ($cell in $cells) {
                $cellValues.Add((Get-CellText $cell))
            }
            $rows.Add($cellValues)
        }
        if ($rows.Count -gt 0) {
            $tables.Add($rows)
        }
    }
    # ",$tables", not "return $tables": returning a collection normally
    # unrolls it onto the pipeline, and when it has exactly one element
    # (one table on the page), the caller ends up with that element
    # directly instead of a one-item list - silently losing a level of
    # nesting. The unary comma forces PowerShell to treat $tables as the
    # single object it actually is, rather than something to unroll.
    return ,$tables
}

function Find-Page {
    # Looks for a page in the manifest matching what was typed in on the
    # command line - either its exact id, or its title (not case
    # sensitive). Returns $null if nothing matches.
    param($manifest, [string]$Query)
    $trimmedQuery = $Query.Trim()
    foreach ($pageEntry in $manifest) {
        if ([string]$pageEntry.id -eq $trimmedQuery) { return $pageEntry }
        if ($pageEntry.title.Trim().ToLower() -eq $trimmedQuery.ToLower()) { return $pageEntry }
    }
    return $null
}

# --- Main ---
# Everything above this line was just defining settings and helper
# functions - this is where the script actually starts doing the work.

$manifestPath = Join-Path $exportDir "manifest.json"
if (-not (Test-Path $manifestPath)) {
    Write-Host "Can't find manifest.json at $manifestPath."
    Write-Host "Run confluence_extractor.ps1 (or .py) first."
    exit 1
}

# @()-wrapped: manifest.json legitimately can have exactly one page (the
# extractor's single-page mode), and ConvertFrom-Json hands back a bare
# object instead of a one-item array for a one-element JSON array.
$manifest = @(Get-Content $manifestPath -Raw | ConvertFrom-Json)

# Find the specific page that was asked for on the command line.
$pageEntry = Find-Page -manifest $manifest -Query $PageQuery
if (-not $pageEntry) {
    Write-Host "No page found matching '$PageQuery' (checked by title and id)."
    Write-Host "Check the exact title (or id) in $manifestPath."
    exit 1
}

$htmlPath = Join-Path $exportDir (Join-Path $pageEntry.folder $pageEntry.html_file)
if (-not (Test-Path $htmlPath)) {
    Write-Host "content.html not found at $htmlPath."
    exit 1
}

# Read the page's raw content, and fix up any named entities the XML
# parser wouldn't otherwise understand.
$rawHtml = Get-Content $htmlPath -Raw -Encoding UTF8
$rawHtml = ConvertTo-XmlSafeEntities $rawHtml

# Wrap in a root element with the Confluence namespaces declared, then
# actually parse it as XML.
$wrappedHtml = "<root $namespaceDeclarations>$rawHtml</root>"
$rootElement = [System.Xml.Linq.XElement]::Parse($wrappedHtml)

# Pull out every table this page actually has.
$tables = Get-TablesFromPage $rootElement

if ($tables.Count -eq 0) {
    Write-Host "No tables found on page '$($pageEntry.title)'."
    exit 0
}

New-Item -ItemType Directory -Force -Path $tableExportDir | Out-Null
$safeTitle = Get-SanitisedFilename $pageEntry.title

# Write out one CSV file per table found (usually just one). If there's
# more than one table on the page, each file gets "_table_1", "_table_2"
# etc added to its name so they don't overwrite each other.
for ($i = 0; $i -lt $tables.Count; $i++) {
    $suffix = if ($tables.Count -eq 1) { "" } else { "_table_$($i + 1)" }
    $outputPath = Join-Path $tableExportDir "$safeTitle$suffix.csv"

    $rows = $tables[$i]
    # Turn each row (a list of cell strings) into one properly-formatted
    # CSV line.
    $csvLines = foreach ($row in $rows) {
        ($row | ForEach-Object {
            # Minimal CSV quoting: only quote a field that actually needs
            # it, and double up any quote characters already inside it.
            if ($_ -match '[",\r\n]') { '"' + ($_ -replace '"', '""') + '"' } else { $_ }
        }) -join ","
    }

    # utf-8-sig, not utf-8: Excel (and SharePoint's CSV import, which goes
    # through the same engine) needs the BOM to reliably detect UTF-8
    # rather than misreading accented/special characters - the same class
    # of encoding bug this whole project already ran into once with the
    # old PowerShell extractor.
    [System.IO.File]::WriteAllLines($outputPath, $csvLines, (New-Object System.Text.UTF8Encoding($true)))

    Write-Host "Wrote $($rows.Count - 1) row(s) (plus header) to $outputPath"
}

Write-Host "`nIn SharePoint: Create list -> From CSV/Excel, point it at that file."
Write-Host "Every column comes in as plain text - if you want a real Person or"
Write-Host "Date column (profile photos, calendar view, etc.), change the"
Write-Host "column type after import. The CSV itself can't carry that."

<#
Shared data builder for the project kanban.

Both build-kanban.ps1 (static file) and serve-kanban.ps1 (live HTTP server) dot-source
this module so the doc-parsing logic lives in exactly one place. Get-KanbanJson reads the
governance docs and returns the board model as a JSON string.

Conventions
-----------
ASCII-only on purpose (Windows PowerShell 5.1 reads a BOM-less UTF-8 script as ANSI, so a
non-ASCII byte inside the script can garble output). Therefore:
  * No Chinese literals anywhere. Doc filenames are resolved via the filesystem (ASCII
    glob / content sniff), and Chinese column captions are matched by POSITION, not by
    string compare (positional indices match the stable docs table layout).
  * Status emoji are matched by code point, never as literal characters.
  * The two source filenames shown in the UI are taken from the resolved file paths
    (Split-Path -Leaf), never typed as literals here.
#>

function Col-FromStatus {
    param([string]$Status)
    if (-not $Status) { return 'backlog' }
    $cps = [int[]][char[]]$Status
    if ($cps -contains 0x2705) { return 'done' }                                  # U+2705 (done)
    if ($cps -contains 0xD83D -and $cps -contains 0xDD04) { return 'progress' }    # U+1F504 (in progress)
    if ($cps -contains 0x23F8) { return 'blocked' }                                # U+23F8 (blocked)
    # U+274C is "cancelled / out of scope" (the doc caption is Chinese; matched by code point, never
    # as a literal). It must be decided BEFORE the fallback: folding it into 'backlog' would show a
    # cancelled item as pending work (see CONTRIBUTING 9.3 for the mapping).
    if ($cps -contains 0x274C) { return 'closed' }                                 # U+274C (cancelled)
    return 'backlog'                                                              # U+2B1C (backlog) or anything else
}

# Parse a Markdown pipe table from a list of lines. Returns @{ Headers = @(); Rows = @() }
# where Rows is an array of string arrays (positional, so column order is stable).
function Parse-Table {
    param([string[]]$Lines)
    $headers = $null
    [System.Collections.ArrayList]$rows = @()
    foreach ($ln in $Lines) {
        if ($ln -notmatch '^\s*\|') {
            if ($headers) { break }
            continue
        }
        $cells = ($ln.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() }
        if (-not $headers) { $headers = $cells; continue }
        $isSep = $true
        foreach ($c in $cells) { if ($c -notmatch '^:?-+:?$') { $isSep = $false; break } }
        if ($isSep) { continue }
        $null = $rows.Add($cells)
    }
    return @{ Headers = $headers; Rows = $rows.ToArray() }
}

# Split a document into its contiguous pipe-table blocks, parsed one by one. The governance docs hold
# more than one table per file, and the blocks are told apart by their DATA - a first cell that is an
# ISO date, a first cell that is a stage id - never by the Chinese captions (see the header note).
function Get-PipeTables {
    param([string[]]$Lines)
    $tables = @()
    [System.Collections.ArrayList]$buf = @()
    foreach ($ln in $Lines) {
        if ($ln -match '^\s*\|') { $null = $buf.Add($ln); continue }
        if ($buf.Count -gt 0) { $tables += (Parse-Table $buf.ToArray()); $buf.Clear() }
    }
    if ($buf.Count -gt 0) { $tables += (Parse-Table $buf.ToArray()) }
    return $tables
}

# Build the document map: every .md under docs/, classified by the SHAPE of its file name (never by
# matching a Chinese caption - naming form is the interface, see CONTRIBUTING section 10), plus its
# first-seen / last-touched dates from ONE git log pass.
#
# The dates come from git and not from the file system: mtime is whatever the last checkout happened to
# write, so it cannot answer "when did this document last change in the repository". A document that is
# not tracked yet simply carries empty dates - the map still lists it.
# Where "origin" points, so a PR number can link to its pull request. Both the SSH and the HTTPS form are
# normalised to https and the trailing .git is dropped; anything unexpected (no remote, git missing, an
# unrecognised URL) yields an empty string and the board then shows plain text -- a link that cannot be
# resolved must never be invented, and the board must build on a machine that has no clone metadata at all.
function Get-RepoWebUrl {
    param([string]$RepoRoot)
    $raw = ''
    try { $raw = [string](& git -C $RepoRoot remote get-url origin 2>$null | Select-Object -First 1) }
    catch { return '' }
    $u = ([string]$raw).Trim()
    if (-not $u) { return '' }
    if ($u -match '^git@([^:]+):(.+?)(\.git)?$') { return ('https://' + $Matches[1] + '/' + $Matches[2]) }
    if ($u -match '^https?://(.+?)(\.git)?$') { return ('https://' + $Matches[1]) }
    return ''
}

function Get-DocMap {
    param([string]$RepoRoot, [string]$DocsDir)
    $files = @(Get-ChildItem -LiteralPath $DocsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $touch = @{}
    $prevOut = $null
    try { $prevOut = [Console]::OutputEncoding } catch { }
    try {
        # The console output encoding is pinned for the duration of the git call and restored right after
        # (the whole process shares it). Why: a native command's stdout is decoded with THAT encoding, and a
        # process started without a visible console - the live server is one - falls back to the OEM code
        # page, where a Chinese document name arrives as mojibake, matches no file, and every date silently
        # comes out empty. The direct build hid this, because an interactive console is UTF-8.
        # quotepath stays off so git does not octal-escape the paths on top of that.
        try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
        $log = @(& git -C $RepoRoot -c core.quotepath=false log --format='%x01%ad' --date=short --name-only -- docs 2>$null)
        $cur = ''
        foreach ($ln in $log) {
            if (-not $ln) { continue }
            if ($ln[0] -eq [char]1) {
                $stamp = $ln.Substring(1).Trim()
                $cur = if ($stamp -match '^\d{4}-\d{2}-\d{2}$') { $stamp } else { '' }
                continue
            }
            if (-not $cur) { continue }
            if ($ln -notmatch '^docs[/\\]') { continue }        # a stray warning line is not a path
            $leaf = (Split-Path -Leaf $ln).Trim().Trim('"')
            if (-not $leaf) { continue }
            # git log is newest-first: the first hit is the last change, every later hit pushes first-seen back
            if ($touch.ContainsKey($leaf)) { $touch[$leaf].first = $cur }
            else { $touch[$leaf] = @{ last = $cur; first = $cur } }
        }
    }
    catch { }
    finally { if ($prevOut) { try { [Console]::OutputEncoding = $prevOut } catch { } } }

    $map = @()
    foreach ($f in $files) {
        $name = $f.Name
        $num = ''
        if ($name -match '^(\d{2})-') { $num = $Matches[1] }
        $kind = 'standing'
        if ($name -match 'P\d+-\d+') { $kind = 'design' }
        elseif ($num) { $kind = 'numbered' }
        $content = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        $head = $content | Where-Object { $_ -match '^#\s+\S' } | Select-Object -First 1
        $title = if ($head) { ($head -replace '^#\s+', '').Trim() } else { $name }
        $first = ''; $last = ''
        if ($touch.ContainsKey($name)) { $first = $touch[$name].first; $last = $touch[$name].last }
        $map += [ordered]@{
            name  = $name
            num   = $num
            kind  = $kind
            title = $title
            lines = $content.Count
            bytes = $f.Length
            first = $first
            last  = $last
        }
    }
    return $map
}

# The active stage's plan document supplies the NEXT STEP. The active stage is the one whose status carries
# the in-progress code point (the same reading rule as Col-FromStatus), and it names its own plan file in the
# stage table - so nothing here guesses which document is "the plan".
#
# Section boundaries are matched by NUMBER (ASCII), never by the Chinese caption, and the plan file is matched
# by its exact leaf name: a renamed document degrades to "no next step", it never picks the wrong one.
function Get-NextStep {
    param([string]$DocsDir, $Stages)
    $planLeaf = ''
    foreach ($s in @($Stages)) {
        if (-not $s) { continue }
        $cps = [int[]][char[]][string]$s.status
        if ($cps -contains 0xD83D -and $cps -contains 0xDD04) { $planLeaf = (($s.plan -replace '`', '')).Trim(); break }   # U+1F504
    }
    if (-not $planLeaf -and @($Stages).Count -gt 0) { $planLeaf = (((@($Stages))[0].plan -replace '`', '')).Trim() }
    if (-not $planLeaf) { return $null }
    $file = Get-ChildItem -LiteralPath $DocsDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $planLeaf } | Select-Object -First 1
    if (-not $file) { return $null }
    $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
    $in4 = $false
    $sec = @()
    foreach ($l in $lines) {
        if ($l -match '^##\s*4\.') { $in4 = $true; continue }
        if ($in4 -and $l -match '^##\s*5\.') { break }
        if ($in4) { $sec += $l }
    }
    $heading = ''
    foreach ($l in $sec) {
        if ($l -match '^###\s+\S') { $heading = ($l -replace '^###\s+', '').Trim(); break }
    }
    $bullets = @()
    foreach ($l in $sec) {
        if ($l -match '^\s*-\s+\S') { $bullets += (($l -replace '^\s*-\s+', '')).Trim() }
        if ($bullets.Count -ge 5) { break }
    }
    return [ordered]@{ doc = $planLeaf; heading = $heading; bullets = $bullets }
}

# Parse the boundary list (the single register of gaps, R-Plan-7). Two shapes live in the same document and
# are told apart WITHOUT matching any Chinese caption:
#   * a row whose first cell is an I-number and that has 6 columns -> a registered item
#   * a row whose first cell is an I-number and that has 4 columns -> a closed/archived entry
#   * a row whose first cell carries Q1..Q4 (or, in the contract row, no Q at all) and 2 columns -> a quadrant
# The document itself is resolved by CONTENT (the file that has an I-number pipe row), so it may be renamed.
function Get-ScopeMap {
    param([string]$DocsDir)
    $file = $null
    foreach ($f in (Get-ChildItem -LiteralPath $DocsDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $hit = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^\|\s*I\d+\s*\|' }
        if ($hit) { $file = $f; break }
    }
    if (-not $file) { return $null }
    $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)
    $items = @(); $quadrants = @(); $closed = @()
    foreach ($t in (Get-PipeTables $lines)) {
        if ($t.Rows.Count -eq 0) { continue }
        $lead = [string]$t.Rows[0][0]
        if ($lead -match '^I\d+$') {
            foreach ($row in $t.Rows) {
                if ($row.Count -eq 6) {
                    $items += [ordered]@{
                        id      = (($row[0] -replace '\*', '')).Trim()
                        kind    = $row[1]
                        desc    = $row[2]
                        trigger = $row[3]
                        owner   = $row[4]
                        status  = $row[5]
                    }
                }
                elseif ($row.Count -eq 4) {
                    $closed += [ordered]@{
                        id    = (($row[0] -replace '\*', '')).Trim()
                        date  = $row[1]
                        way   = $row[2]
                        basis = $row[3]
                    }
                }
            }
            continue
        }
        if ($lead -match 'Q[1-4]') {
            foreach ($row in $t.Rows) {
                if ($row.Count -lt 2) { continue }
                $q = if ($row[0] -match 'Q([1-4])') { 'Q' + $Matches[1] } else { 'contract' }
                $ids = @()
                foreach ($m in [regex]::Matches([string]$row[1], 'I\d+')) { $ids += $m.Value }
                $quadrants += [ordered]@{ q = $q; label = $row[0]; ids = $ids }
            }
        }
    }
    return [ordered]@{ doc = $file.Name; items = $items; quadrants = $quadrants; closed = $closed }
}

# Build the board model JSON from the governance docs.
# Positional column indices follow the stable table layout of the docs:
#   plan section 3 : | 包 | 内容 | 依赖 | 状态 |
#   plan section 8 : | # | 问题 | 来源 | 阻塞哪个包 | 状态与结论 |
#   RTM table      : | 需求 ID | 需求（§/R） | 工作包 | 阶段 | 状态 | 验收 / 证据 | 备注 |
function Get-KanbanJson {
    param([string]$RepoRoot = '')

    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    $resolved = Resolve-Path -LiteralPath $RepoRoot -ErrorAction SilentlyContinue
    if (-not $resolved) {
        return (@{ error = 'repo root not found'; generatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); packages = @(); blockers = @(); unassigned = @(); timeline = @(); stages = @(); docmap = @(); nextstep = $null; scope = $null } | ConvertTo-Json -Depth 3 -Compress)
    }
    $RepoRoot = $resolved.Path
    $docsDir  = Join-Path $RepoRoot 'docs'

    # Resolve the two source docs by ASCII-only patterns (never hardcode Chinese filenames).
    $planFile = Get-ChildItem -LiteralPath $docsDir -Filter '03-*.md' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $rtmFile = $null
    foreach ($f in (Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $hit = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^\|\s*R-\d' }
        if ($hit) { $rtmFile = $f; break }
    }
    # The timeline doc is resolved by CONTENT as well: the file that carries a table whose first cell is
    # an ISO date. Section headings are Chinese and are never matched as literals.
    $tlFile = $null
    foreach ($f in (Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        $hit = Get-Content -LiteralPath $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^\|\s*\d{4}-\d{2}-\d{2}\s*\|' }
        if ($hit) { $tlFile = $f; break }
    }

    $planPath = if ($planFile) { $planFile.FullName } else { '' }
    $rtmPath  = if ($rtmFile)  { $rtmFile.FullName }  else { '' }
    $tlPath   = if ($tlFile)   { $tlFile.FullName }   else { '' }

    if (-not $planPath -or -not (Test-Path -LiteralPath $planPath)) {
        return (@{ error = 'plan doc not found'; generatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); packages = @(); blockers = @(); unassigned = @(); timeline = @(); stages = @(); docmap = @(); nextstep = $null; scope = $null } | ConvertTo-Json -Depth 3 -Compress)
    }
    if (-not $rtmPath -or -not (Test-Path -LiteralPath $rtmPath)) {
        return (@{ error = 'rtm doc not found'; generatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); packages = @(); blockers = @(); unassigned = @(); timeline = @(); stages = @(); docmap = @(); nextstep = $null; scope = $null } | ConvertTo-Json -Depth 3 -Compress)
    }

    $planLines = Get-Content -LiteralPath $planPath -Encoding UTF8
    $rtmLines  = @(Get-Content -LiteralPath $rtmPath -Encoding UTF8)

    # plan section 3 (work packages)
    $in3 = $false; $sec3 = @()
    foreach ($l in $planLines) {
        if ($l -match '^##\s*3\.') { $in3 = $true; continue }
        if ($in3 -and $l -match '^##\s*4\.') { break }
        if ($in3) { $sec3 += $l }
    }
    $t3 = Parse-Table $sec3

    # plan section 8 (open decisions / blockers)
    $in8 = $false; $sec8 = @()
    foreach ($l in $planLines) {
        if ($l -match '^##\s*8\.') { $in8 = $true; continue }
        if ($in8 -and $l -match '^###\s*8\.1') { break }
        if ($in8) { $sec8 += $l }
    }
    $t8 = Parse-Table $sec8

    # RTM table: ASCII-only detection; header sits two lines above the first `| R-N` body row.
    $rtmSec = @()
    $start = -1
    for ($k = 0; $k -lt $rtmLines.Count; $k++) {
        if ($rtmLines[$k] -match '^\|\s*R-\d') { $start = $k; break }
    }
    if ($start -ge 2) {
        for ($k = $start - 2; $k -lt $rtmLines.Count; $k++) {
            if ($rtmLines[$k] -match '^##\s') { break }
            $rtmSec += $rtmLines[$k]
        }
    }
    $tR = Parse-Table $rtmSec

    # timeline doc: one table per view, picked by the shape of its first data cell.
    $tlLines = @()
    if ($tlPath -and (Test-Path -LiteralPath $tlPath)) { $tlLines = @(Get-Content -LiteralPath $tlPath -Encoding UTF8) }
    $tlTables = Get-PipeTables $tlLines
    $tTl = $null; $tSt = $null
    foreach ($t in $tlTables) {
        if ($t.Rows.Count -eq 0) { continue }
        if (-not $tTl -and $t.Rows[0][0] -match '^\d{4}-\d{2}-\d{2}$') { $tTl = $t; continue }
        if (-not $tSt -and $t.Rows[0][0] -match '^P\d+$') { $tSt = $t; continue }
    }

    # timeline entries (positional: 0=date,1=type,2=content,3=package/stage,4=PR)
    $timeline = @()
    if ($tTl) {
        foreach ($row in $tTl.Rows) {
            if ($row.Count -lt 5) { continue }
            $timeline += [ordered]@{
                date    = $row[0]
                type    = $row[1]
                content = $row[2]
                pkg     = $row[3]
                pr      = $row[4]
            }
        }
    }

    # stage overview (positional: 0=stage,1=plan doc,2=status,3=review,4=note)
    $stages = @()
    if ($tSt) {
        foreach ($row in $tSt.Rows) {
            if ($row.Count -lt 5) { continue }
            $stages += [ordered]@{
                stage  = (($row[0] -replace '\*', '') -replace '`', '').Trim()
                plan   = $row[1]
                status = $row[2]
                review = $row[3]
                note   = $row[4]
            }
        }
    }

    $docmap = Get-DocMap -RepoRoot $RepoRoot -DocsDir $docsDir
    $nextstep = Get-NextStep -DocsDir $docsDir -Stages $stages
    $scope = Get-ScopeMap -DocsDir $docsDir

    # build packages (positional columns: 0=id,1=content,2=deps,3=status)
    $packages = @()
    foreach ($row in $t3.Rows) {
        if ($row.Count -lt 4) { continue }
        $id      = $row[0] -replace '\*', '' -replace '`', '' -replace '\s', ''
        $content = $row[1]
        $deps    = $row[2]
        $status  = $row[3]
        $col = Col-FromStatus $status
        $pr = ''
        if ($status -match '#(\d+)') { $pr = '#' + $Matches[1] }
        elseif ($status -like '*PR 待提*') { $pr = 'PR pending' }
        $stage = if ($id -match '^(P\d+)') { $Matches[1] } else { '' }
        $packages += [ordered]@{
            id      = $id
            content = $content
            deps    = $deps
            status  = $status
            column  = $col
            pr      = $pr
            stage   = $stage
            reqs    = @()
        }
    }

    # build requirements (positional: 0=id,1=title,2=pkg,3=stage,4=status,5=evidence,6=note)
    $reqs = @()
    foreach ($row in $tR.Rows) {
        if ($row.Count -lt 7) { continue }
        $rid      = $row[0]
        $title    = $row[1]
        $pkgCell  = $row[2]
        $stageCell = $row[3]
        $status   = $row[4]
        $evidence = $row[5]
        $note     = $row[6]
        $col = Col-FromStatus $status
        $stage = if ($stageCell -match '(P\d+)') { $Matches[1] } else { '' }
        $pkgIds = @()
        foreach ($m in ([regex]::Matches($pkgCell, 'P\d+-\d+'))) { $pkgIds += $m.Value }
        $reqs += [ordered]@{
            id       = $rid
            title    = $title
            status   = $status
            col      = $col
            evidence = $evidence
            note     = $note
            pkgIds   = $pkgIds
            stage    = $stage
        }
    }

    foreach ($p in $packages) {
        $p.reqs = @($reqs | Where-Object { $_.pkgIds -contains $p.id })
    }
    $unassigned = @($reqs | Where-Object { $_.pkgIds.Count -eq 0 })

    # blockers (positional: 0=id,1=question,2=source,3=blocks,4=status)
    $blockers = @()
    foreach ($row in $t8.Rows) {
        if ($row.Count -lt 5) { continue }
        $bid = $row[0] -replace '\*', '' -replace '`', '' -replace '\s', ''
        if (-not $bid) { continue }
        $blockers += [ordered]@{
            id       = $bid
            question = $row[1]
            source   = $row[2]
            blocks   = $row[3]
            status   = $row[4]
        }
    }

    $srcList = @((Split-Path $planPath -Leaf), (Split-Path $rtmPath -Leaf))
    if ($tlPath) { $srcList += (Split-Path $tlPath -Leaf) }

    # Resolved once, not per row: it is a property of the clone, not of a document (see Get-RepoWebUrl).
    $repoWebUrl = Get-RepoWebUrl -RepoRoot $RepoRoot

    $model = [ordered]@{
        generatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        sources     = $srcList
        packages    = $packages
        blockers    = $blockers
        unassigned  = $unassigned
        timeline    = $timeline
        stages      = $stages
        docmap      = $docmap
        nextstep    = $nextstep
        scope       = $scope
        repoUrl     = $repoWebUrl
    }
    return ($model | ConvertTo-Json -Depth 6 -Compress)
}

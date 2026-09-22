<#
Colour and wiring gate for the project kanban.

Why this exists: the template used to carry a comment claiming "no hard-coded colour outside this
block" while nine literals sat outside it, and the two themes were free to drift apart (a key missing
from the dark block does not error - it silently falls back to the light value). Neither claim was
checkable by eye, so both are asserted here. See CONTRIBUTING.md section 10.

What it checks - on the ARTIFACT, not on the template (run build-kanban.ps1 first):
  1. palette   : every colour lives in :root / html[data-theme="dark"], and the two themes define the
                 SAME key set.
  2. contrast  : the WCAG 2.1 ratio of each foreground/background pair the board actually renders -
                 4.5:1 for text, 3.0:1 for non-text (status dots, card edges).
  3. wiring    : the invariants a screenshot cannot show and a refactor can silently drop - render()
                 is the only entry, the drag guard and the scroll guard are in place, the poll compares
                 content fingerprints rather than the whole payload, and the drop handler clears the
                 drag flag BEFORE rendering. Also the reader-view mechanics added in P0-15: collapse,
                 undo, keyboard move, the change banner, the measured sticky offset and the single
                 preferences key. And the P0-20 affordances: the notice bar for hand moves (with the way
                 back) and the jump from a number to the row it refers to.

Not asserted here, and listed in the output so the gap stays visible: form control boundaries
(--field-border / --btn-border, which fail 3:1 today), hairline separators and shadows (decorative),
and gradients (none in this palette - if one is introduced, assert its WORST stop).

Exit codes: 0 = pass, 1 = findings, 2 = artifact missing.

Conventions: ASCII-only, no external dependencies (see kanban-data.ps1 header for why).

Usage
-----
  powershell -ExecutionPolicy Bypass -File tools/build-kanban.ps1
  powershell -ExecutionPolicy Bypass -File tools/kanban-check.ps1 [-Artifact tools/kanban.html]
#>
param(
    [string]$Artifact = '',
    [switch]$SkipServe
)

$ErrorActionPreference = 'Stop'

if (-not $Artifact) { $Artifact = Join-Path $PSScriptRoot 'kanban.html' }
if (-not (Test-Path -LiteralPath $Artifact)) {
    Write-Host ("::error::artifact not found: {0}" -f $Artifact)
    Write-Host '  run tools/build-kanban.ps1 first - this gate checks the artifact, not the template'
    exit 2
}

$script:Findings = New-Object System.Collections.ArrayList
function Add-Finding { param([string]$Message) $null = $script:Findings.Add($Message) }

$html = [System.IO.File]::ReadAllText($Artifact, [System.Text.Encoding]::UTF8)
$styleMatch = [regex]::Match($html, '(?s)<style>(.*?)</style>')
$style = $styleMatch.Groups[1].Value
if (-not $styleMatch.Success) { Add-Finding 'no <style> block in the artifact' }

# ------------------------------------------------------------------- palette
function Read-Palette {
    param([string]$Css, [string]$Pattern)
    $m = [regex]::Match($Css, $Pattern)
    if (-not $m.Success) { return $null }
    $table = [ordered]@{}
    foreach ($d in [regex]::Matches($m.Groups[1].Value, '(--[a-z0-9-]+)\s*:\s*([^;]+);')) {
        $table[$d.Groups[1].Value] = $d.Groups[2].Value.Trim()
    }
    return $table
}
$light = Read-Palette $style ':root\s*\{([^}]*)\}'
$dark  = Read-Palette $style 'html\[data-theme="dark"\]\s*\{([^}]*)\}'
if (-not $light) { Add-Finding 'light palette (:root) not found' }
if (-not $dark)  { Add-Finding 'dark palette (html[data-theme="dark"]) not found' }

if ($light -and $dark) {
    foreach ($k in @($light.Keys | Where-Object { -not $dark.Contains($_) })) {
        Add-Finding ("palette key {0} is defined for light but not for dark (it would silently fall back to the light value)" -f $k)
    }
    foreach ($k in @($dark.Keys | Where-Object { -not $light.Contains($_) })) {
        Add-Finding ("palette key {0} is defined for dark but not for light" -f $k)
    }
}

# ------------------------------------------ colours outside the two palettes
# Comments are stripped first: a colour inside a comment is explanation, not a declaration.
$scan = [regex]::Replace($style, '(?s)/\*.*?\*/', '')
$scan = [regex]::Replace($scan, ':root\s*\{[^}]*\}', '')
$scan = [regex]::Replace($scan, 'html\[data-theme="dark"\]\s*\{[^}]*\}', '')
foreach ($hit in [regex]::Matches($scan, '#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)')) {
    Add-Finding ("colour literal outside the palette: {0}" -f $hit.Value)
}

# ------------------------------------------------------------------ contrast
function Get-Rgb {
    param([string]$Value)
    $m = [regex]::Match(([string]$Value).Trim(), '^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$')
    if (-not $m.Success) { return $null }
    $hex = $m.Groups[1].Value
    if ($hex.Length -eq 3) {
        $hex = ([string]$hex[0] + [string]$hex[0] + [string]$hex[1] + [string]$hex[1] + [string]$hex[2] + [string]$hex[2])
    }
    return @(
        [Convert]::ToInt32($hex.Substring(0, 2), 16),
        [Convert]::ToInt32($hex.Substring(2, 2), 16),
        [Convert]::ToInt32($hex.Substring(4, 2), 16)
    )
}
function Get-Luminance {
    param($Rgb)
    $channels = @()
    foreach ($v in $Rgb) {
        $s = [double]$v / 255.0
        if ($s -le 0.03928) { $channels += ($s / 12.92) } else { $channels += [Math]::Pow((($s + 0.055) / 1.055), 2.4) }
    }
    return (0.2126 * $channels[0]) + (0.7152 * $channels[1]) + (0.0722 * $channels[2])
}
function Get-Ratio {
    param([string]$Fg, [string]$Bg)
    $f = Get-Rgb $Fg
    $b = Get-Rgb $Bg
    if (-not $f -or -not $b) { return $null }
    $lf = Get-Luminance $f
    $lb = Get-Luminance $b
    if ($lf -lt $lb) { $tmp = $lf; $lf = $lb; $lb = $tmp }
    return (($lf + 0.05) / ($lb + 0.05))
}
# A background may be a gradient (the dark header is one). The style value cannot be resolved, so every
# hex in it is measured and the WORST stop is what gets reported: a gradient is only as readable as its
# lightest stop against the ink.
function Get-WorstRatio {
    param([string]$Fg, [string]$Bg)
    if (-not $Bg) { return $null }
    $stops = @([regex]::Matches($Bg, '#[0-9a-fA-F]{6}\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($stops.Count -eq 0) { return (Get-Ratio $Fg $Bg) }
    $worst = $null
    foreach ($s in $stops) {
        $r = Get-Ratio $Fg $s
        if ($null -eq $r) { continue }
        if ($null -eq $worst -or $r -lt $worst) { $worst = $r }
    }
    return $worst
}
function Get-Value {
    param($Palette, [string]$Key)
    if (-not $Palette) { return $null }
    if (-not $Palette.Contains($Key)) { return $null }
    $v = $Palette[$Key]
    $m = [regex]::Match($v, '^var\((--[a-z0-9-]+)\)$')
    if ($m.Success) { return (Get-Value $Palette $m.Groups[1].Value) }
    return $v
}

# Every pair below is one the board really renders.
$pairs = @(
    @{ fg = '--ink';       bg = '--bg';       min = 4.5; label = 'body text on the page' },
    @{ fg = '--ink';       bg = '--card';     min = 4.5; label = 'text on a card' },
    @{ fg = '--ink';       bg = '--col';      min = 4.5; label = 'lane heading' },
    @{ fg = '--ink';       bg = '--field-bg'; min = 4.5; label = 'filter input text' },
    @{ fg = '--muted';     bg = '--bg';       min = 4.5; label = 'footer / secondary on the page' },
    @{ fg = '--muted';     bg = '--card';     min = 4.5; label = 'deps / status line on a card' },
    @{ fg = '--muted';     bg = '--bcard-bg'; min = 4.5; label = 'secondary text in a decision card' },
    @{ fg = '--rid';       bg = '--card';     min = 4.5; label = 'requirement id' },
    @{ fg = '--blue';      bg = '--card';     min = 4.5; label = 'package id / link' },
    @{ fg = '--count-ink'; bg = '--count-bg'; min = 4.5; label = 'lane count badge' },
    @{ fg = '--on-blue';   bg = '--blue';     min = 4.5; label = 'ink on a filled control (LIVE badge, active filter)' },
    @{ fg = '--done';      bg = '--card';     min = 3.0; label = 'status dot: done' },
    @{ fg = '--progress';  bg = '--card';     min = 3.0; label = 'status dot: in progress' },
    @{ fg = '--blocked';   bg = '--card';     min = 3.0; label = 'status dot: blocked' },
    @{ fg = '--idle';      bg = '--card';     min = 3.0; label = 'status dot: backlog ring' },
    @{ fg = '--blocked';   bg = '--bcard-bg'; min = 3.0; label = 'decision card edge' },
    @{ fg = '--idle';      bg = '--bcard-bg'; min = 3.0; label = 'unassigned card edge' },
    @{ fg = '--ink';       bg = '--header-bg'; min = 4.5; label = 'header text on the header surface' }
)

$rows = @()
foreach ($theme in @(@{ name = 'light'; palette = $light }, @{ name = 'dark'; palette = $dark })) {
    if (-not $theme.palette) { continue }
    foreach ($p in $pairs) {
        $fg = Get-Value $theme.palette $p.fg
        $bg = Get-Value $theme.palette $p.bg
        $ratio = Get-WorstRatio $fg $bg
        if ($null -eq $ratio) {
            Add-Finding ("{0}: cannot measure {1} on {2} (missing or non-hex value)" -f $theme.name, $p.fg, $p.bg)
            continue
        }
        $ok = $ratio -ge $p.min
        if (-not $ok) {
            Add-Finding ("{0}: {1} is {2:N2}:1, below {3:N1}:1 ({4} on {5})" -f $theme.name, $p.label, $ratio, $p.min, $p.fg, $p.bg)
        }
        $rows += [pscustomobject]@{ Theme = $theme.name; Pair = $p.label; Ratio = $ratio; Min = $p.min; Ok = $ok }
    }
}

# -------------------------------------------------------------------- wiring
$mustExist = @(
    @{ p = 'function render\(\)\{';                  label = 'render() exists as the single entry point' },
    @{ p = 'function renderBoard\(\)\{';             label = 'the render body is renderBoard()' },
    @{ p = 'withScroll\(renderEverything\);';        label = 'render() wraps every panel in the scroll guard' },
    @{ p = 'function renderEverything\(\)\{';        label = 'all panels are rendered from one place' },
    @{ p = 'function selectTab\(name,push\)\{';      label = 'the tab routing exists' },
    @{ p = 'id="p-overview"';                        label = 'the overview panel exists' },
    @{ p = 'id="p-stages"';                          label = 'the stages panel exists' },
    @{ p = 'id="p-timeline"';                        label = 'the timeline panel exists' },
    @{ p = 'id="p-decisions"';                       label = 'the decisions panel exists' },
    @{ p = 'class="tbl-wrap"';                       label = 'tables scroll inside their own wrapper' },
    @{ p = "var SCROLL_BOXES='[^']*\.tbl-wrap";      label = 'the scroll-box list includes the table wrapper' },
    @{ p = "var SCROLL_BOXES='[^']*\.dbody'";        label = 'the scroll-box list includes the drawer body' },
    @{ p = 'id="docmap"';                            label = 'the document map panel exists' },
    @{ p = 'function parseHash\(\)\{';               label = 'the hash carries dimension and document' },
    @{ p = 'function mdToHtml\(src\)\{';             label = 'the Markdown renderer exists' },
    @{ p = 'var t=esc\(s\)\.replace';                label = 'the renderer escapes BEFORE applying inline structure' },
    @{ p = 'function openDoc\(name,push\)\{';        label = 'openDoc exists' },
    @{ p = 'function closeDoc\(push\)\{';            label = 'closeDoc exists' },
    @{ p = 'id="drawer"';                            label = 'the drawer exists' },
    @{ p = 'id="dmask"';                             label = 'the drawer scrim exists' },
    @{ p = 'data-doc="';                             label = 'document links carry the document name' },
    @{ p = "getElementById\('dclose'\)\.addEventListener"; label = 'the drawer close button is wired' },
    @{ p = 'id="p-health"';                          label = 'the health panel exists' },
    @{ p = 'id="p-next"';                            label = 'the next panel exists' },
    @{ p = 'id="health-checks"';                     label = 'the consistency check list exists' },
    @{ p = 'id="freshness"';                         label = 'the freshness block exists' },
    @{ p = 'id="next-body"';                         label = 'the next-step block exists' },
    @{ p = 'id="outstanding"';                       label = 'the outstanding list exists' },
    @{ p = 'function renderHealthPanel\(\)\{';       label = 'the health panel is rendered' },
    @{ p = 'function renderNextPanel\(\)\{';         label = 'the next panel is rendered' },
    @{ p = 'function readyPkgs\(\)\{';               label = 'what can start now is derived from the dependency column' },
    @{ p = 'var STALE_DAYS=';                        label = 'the freshness threshold is a named constant, not a magic number' },
    @{ p = 'var TAB_NAMES=\[';                       label = 'the tab set has a single named source (its CONTENT is compared with the markup below, not spelled out here)' },
    @{ p = 'aria-controls="p-overview"';             label = 'the first tab points at the board panel' },
    @{ p = 'id="p-scope"';                           label = 'the scope panel exists' },
    @{ p = 'id="quadrants"';                         label = 'the quadrant view exists' },
    @{ p = 'id="scope-rows"';                        label = 'the registered-items table exists' },
    @{ p = 'id="closed"';                            label = 'the closed/archived table exists' },
    @{ p = 'function renderScopePanel\(\)\{';        label = 'the scope panel is rendered' },
    @{ p = 'function gapCol\(';                      label = 'gap status is read by code point (no separate colour scale)' },
    @{ p = 'aria-controls="p-gates"';                label = 'the gate tab points at the gate panel' },
    @{ p = 'if\(!mayRender\(\)\)return;';            label = 'render() goes through the drag guard' },
    @{ p = 'var lastJson = contentKey\(DATA\);';     label = 'the initial fingerprint uses contentKey()' },
    @{ p = 'var s=contentKey\(d\);';                 label = 'the poll compares content fingerprints' },
    @{ p = 'var SCROLL_BOXES=';                      label = 'scroll boxes have a single named source' },
    @{ p = 'dragging=true;e\.dataTransfer\.setData'; label = 'dragstart raises the drag flag' },
    @{ p = 'if\(pendingRender\)render\(\);';         label = 'dragend applies the render held during a drag' },
    @{ p = "s\.indexOf\('\\u274C'\)>=0";             label = 'the cancelled state is judged by code point' },
    @{ p = 'background:var\(--done\)';               label = 'status colours come from the palette' },
    @{ p = 'color:var\(--on-blue\)';                 label = 'filled controls use --on-blue' },
    @{ p = '@media print\{';                         label = 'a print stylesheet exists' },
    @{ p = 'function toggleCollapse\(k\)\{';         label = 'a lane can be collapsed' },
    @{ p = 'function undoMove\(\)\{';                label = 'the last lane move can be undone' },
    @{ p = 'function moveBy\(id,step\)\{';           label = 'a lane move has a keyboard path' },
    @{ p = 'function modelDiff\(a,b\)\{';            label = 'the change banner compares two models' },
    @{ p = 'function measureHeader\(\)\{';           label = 'the sticky offset is measured, not guessed' },
    @{ p = 'var PREF_KEY=';                          label = 'the reader view persists under a single key' },
,
    @{ p = 'recordMove\(id,c\.k\);';                 label = 'a drop records the move it is about to make' },
    @{ p = 'background:var\(--header-bg\)';       label = 'the header surface comes from the palette' },
    @{ p = 'border:1px solid var\(--col-border\)'; label = 'the lane edge comes from the palette' },
    @{ p = 'id="stickybar"';                        label = 'the tabs and the toolbar share one sticky band' },
    @{ p = 'class="hits" id="hits"';                 label = 'the toolbar has its own read-out line' },
    @{ p = 'id="boardtools"';                        label = 'the board-only tools have a container to hide' },
    @{ p = 'id="stagefilter"';                       label = 'the stage filter is a select, not a row of buttons' },
    @{ p = 'id="opt-empty"';                         label = 'the empty-lane option exists' },
    @{ p = 'id="opt-sort"';                          label = 'the sort option exists' },
    @{ p = 'setProperty\(''--hdr-h''';                 label = 'the band offset is measured, not assumed' },
    @{ p = 'orderedPkgs\(DATA.packages\)';          label = 'the card order follows the toolbar' },
    @{ p = 'function updateHits\(\)\{';             label = 'the toolbar read-out is derived from the filter' },
    @{ p = 'id="p-gates"';                           label = 'the gate panel exists' },
    @{ p = "'timeline','gates','decisions'";         label = 'the gate tab is registered in the tab list' },
    @{ p = 'function renderGatesPanel\(\)\{';        label = 'the gate panel is rendered from the timeline rows' },
    @{ p = 'id="ovbanner"';                          label = 'a hand move has a notice bar to appear in' },
    @{ p = 'function updateOverridesBanner\(\)\{';   label = 'a hand move is announced, never left silent' },
    @{ p = 'function droppedOverrides\(pkgs,ovs\)\{'; label = 'overrides the docs invalidated are a pure decision' },
    @{ p = 'function barModel\(pkgs,ovs,stack\)\{';  label = 'the notice bar is rendered from one pure model' },
    @{ p = 'data-act="undo"';                        label = 'the notice bar carries the way back' },
    @{ p = 'function reveal\(tab,key\)\{';           label = 'a number can jump to the row it refers to' },
    @{ p = 'function normalizeGoto\(go\)\{';         label = 'a key written for the source board still resolves' },
    @{ p = '\[data-goto\]\{cursor:pointer;\}';       label = 'a jump target looks like one' },
    @{ p = '@keyframes flashbg\{';                   label = 'the destination of a jump pulses' },
    @{ p = 'data-key="';                             label = 'rows carry the key a jump lands on' },
    @{ p = '--flash:rgba\(';                         label = 'the pulse colour comes from the palette' },
    @{ p = '\.banner\.warn\{';                       label = 'the notice bar marks a dropped override' },
    @{ p = 'function prHtml\(pr\)\{';                label = 'a PR number links to its pull request' },
    @{ p = '"repoUrl":';                             label = 'the model carries the repository URL (empty when the clone cannot say)' }
)
foreach ($c in $mustExist) {
    if (-not [regex]::IsMatch($html, $c.p)) { Add-Finding ("wiring: missing - {0}" -f $c.label) }
}
$renderCount = ([regex]::Matches($html, 'function render\(\)\{')).Count
if ($renderCount -ne 1) { Add-Finding ("render() must be defined exactly once (found {0})" -f $renderCount) }
if ($html.Contains('JSON.stringify(d)')) {
    Add-Finding 'the poll compares the whole payload again (JSON.stringify(d)) - that rebuilds the page on every tick'
}
# `top` on a sticky table header is measured against ITS OWN scroll box: adding the page header's height
# pushed the header down over the first rows, so it floated in the middle of the table (P0-15 did that;
# P0-18 removed it). It pins at 0 of its own box - the geometry check further down asserts that.
if ($scan.Contains('top:var(--stick')) {
    Add-Finding 'geometry: the sticky table header is offset off its own box top - it would float over the first rows'
}
# The drop handler is the user's own action, so it must clear the drag flag BEFORE rendering; in the
# other order the guard defers the move to a dragend that the rebuild itself removes.
$dropAt = $html.IndexOf('overrides[id]=c.k;')
$flagAt = if ($dropAt -ge 0) { $html.IndexOf('dragging=false;', $dropAt) } else { -1 }
$renderAt = if ($flagAt -ge 0) { $html.IndexOf('render();', $flagAt) } else { -1 }
if (-not ($dropAt -ge 0 -and $flagAt -gt $dropAt -and $renderAt -gt $flagAt)) {
    Add-Finding 'wiring: the drop handler must clear the drag flag BEFORE rendering'
}

# ------------------------------------------------------------------ geometry
# The part of "nothing overlaps, nothing jumps" that can be asserted without a layout engine: a sticky
# table header is only meaningful inside a scrolling, height-limited wrapper, and EVERY scroll container
# must be listed in SCROLL_BOXES or its reading position is silently lost on the next re-render
# (CONTRIBUTING section 10, item 5). What this cannot see is real overlap, truncation and wrapping -
# those need a layout engine, and the report says so instead of implying the geometry is covered. One more
# mechanical precondition lives at the end of this section: a tab name must not also be an element id, or the
# browser treats a tab switch as an in-page anchor jump (P0-21).
$scrollBoxes = ''
$sbMatch = [regex]::Match($html, "var SCROLL_BOXES='([^']*)'")
if ($sbMatch.Success) { $scrollBoxes = $sbMatch.Groups[1].Value }
foreach ($rule in [regex]::Matches($scan, '(?s)([^{}]+)\{([^}]*)\}')) {
    if ($rule.Groups[2].Value -notmatch 'overflow\s*:\s*(auto|scroll)') { continue }
    $sel = $rule.Groups[1].Value.Trim()
    # Only a class-addressed box is part of the board's scroll architecture. A descendant rule such as
    # ".md table" styles content INSIDE a rendered document: there can be any number of those, they are
    # not re-created by the board's own render, and positional matching cannot make sense of them.
    if ($sel -match '[\s>,+]') { continue }
    foreach ($cls in [regex]::Matches($sel, '\.[a-z0-9-]+')) {
        if ($scrollBoxes.IndexOf($cls.Value) -lt 0) {
            Add-Finding ("geometry: {0} scrolls but is not in SCROLL_BOXES - its position would be lost on every re-render" -f $cls.Value)
        }
    }
}
# The drawer reads its text from the local server, so the endpoint and its read-only boundary are part of
# this tool's contract: without them the document links have nothing to open.
$servePath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Artifact).Path) 'serve-kanban.ps1'
if (Test-Path -LiteralPath $servePath) {
    $serve = [System.IO.File]::ReadAllText($servePath, [System.Text.Encoding]::UTF8)
    if ($serve.IndexOf("'/docs/'") -lt 0 -and $serve.IndexOf("'/docs/*'") -lt 0) {
        Add-Finding 'serve: the /docs/ endpoint is missing - the drawer has nothing to read'
    }
    if ($serve.IndexOf('[^\\/:*?"<>|]+\.md') -lt 0) {
        Add-Finding 'serve: /docs/ does not validate the requested name (a single .md leaf, no separators)'
    }
    if ($serve.IndexOf('text/plain; charset=utf-8') -lt 0) {
        Add-Finding 'serve: /docs/ must answer as text/plain; charset=utf-8'
    }
}
else {
    Add-Finding 'serve: serve-kanban.ps1 was not found next to the artifact'
}
$wrapRule = [regex]::Match($scan, '(?s)\.tbl-wrap\s*\{([^}]*)\}')
if ($html.IndexOf('class="tbl-wrap"') -ge 0 -and -not $wrapRule.Success) {
    Add-Finding 'geometry: the artifact renders tables but no .tbl-wrap rule was found'
}
if ($wrapRule.Success) {
    if ($wrapRule.Groups[1].Value -notmatch 'max-height') {
        Add-Finding 'geometry: .tbl-wrap needs max-height, or the sticky header never pins'
    }
    if ($wrapRule.Groups[1].Value -notmatch 'overflow\s*:\s*(auto|scroll)') {
        Add-Finding 'geometry: .tbl-wrap needs overflow auto/scroll, or the sticky header never pins'
    }
}
$stickyTh = [regex]::Match($scan, '(?s)thead\s+th\s*\{([^}]*)\}')
if ($stickyTh.Success -and $stickyTh.Groups[1].Value -match 'position\s*:\s*sticky' -and $stickyTh.Groups[1].Value -notmatch 'top\s*:\s*0') {
    Add-Finding 'geometry: the sticky table header has no top:0, so it does not actually pin'
}
# A tab name IS the URL hash ("#<dimension>"), so an element carrying that id turns every tab switch into a
# fragment jump: the browser scrolls that element to the top of the viewport, which drops the reader into the
# middle of the panel they just asked for. Six hosts collided exactly this way (P0-21; the panels are `p-<tab>`
# for the same reason). The check is stated over TAB_NAMES rather than a fixed list, so a NEW tab cannot
# reintroduce it - which is the only version of this guard that stays true.
$tabNames = [regex]::Match($html, 'var TAB_NAMES=\[([^\]]*)\]')
$tabList = @()
if ($tabNames.Success) { $tabList = @($tabNames.Groups[1].Value.Replace("'", '') -split ',' | Where-Object { $_ }) }
# A guard that parses nothing reports nothing, which looks exactly like a pass: the first version of this check
# captured only the FIRST tab name (a `[^']*` in place of `[^\]]*`) and therefore never fired. So the parse is
# asserted too.
if ($tabList.Count -lt 2) {
    Add-Finding 'wiring: the tab list could not be parsed, so tab names and element ids cannot be compared'
}
else {
    foreach ($t in $tabList) {
        if ([regex]::IsMatch($html, ('id="' + [regex]::Escape($t) + '"'))) {
            Add-Finding ("geometry: an element carries id=`"{0}`" - that string is also the URL hash, so switching to that tab scrolls the page down to the element" -f $t)
        }
    }
}
# The panel's top gap and the page gutter are the SAME measurement: the first row of a panel must not sit
# tighter than the gaps between the blocks inside it (10px against a 20px gutter is what P0-24 fixed, and it
# looked like "no spacing at all"). The value is a design choice - so this compares the two numbers read out
# of the artifact instead of pinning a literal, which would fail the gate on every deliberate restyle.
$gutter   = [regex]::Match($scan, '\.section\s*\{[^}]*margin\s*:\s*0\s+(\d+)px').Groups[1].Value
$panelTop = [regex]::Match($scan, '\.panel\s*\{[^}]*padding-top\s*:\s*(\d+)px').Groups[1].Value
$tabRow   = [regex]::Match($scan, '\.stickybar\s+\.tabs\s*\{[^}]*padding\s*:\s*\S+\s+(\d+)px').Groups[1].Value
if (-not $gutter -or -not $panelTop) {
    Add-Finding 'geometry: the page gutter or the panel top gap could not be read, so the two cannot be compared'
}
elseif ($panelTop -ne $gutter) {
    Add-Finding ("geometry: the panel top gap is {0}px but the page gutter is {1}px - the first row of a panel would sit tighter than every other gap" -f $panelTop, $gutter)
}
# The tab row is the exception that proves the rule: `.tabs` is ONE class used by TWO rows (the tab bar and
# the in-panel type chips), so the tab bar's spacing lives in a scoped rule. Collapsing the two into the bare
# class would move the chips row - hence both rules are asserted to exist, and the scoped one is compared with
# the same gutter.
$baseTabs   = [regex]::IsMatch($scan, '(?m)^\.tabs\s*\{')
$scopedTabs = [regex]::IsMatch($scan, '(?m)^\.stickybar\s+\.tabs\s*\{')
if (-not $baseTabs -or -not $scopedTabs) {
    Add-Finding 'geometry: the tab row needs BOTH rules - `.tabs` (it is shared with the in-panel type chips) and the scoped `.stickybar .tabs`; collapsing them moves the other row'
}
if (-not $tabRow) {
    Add-Finding 'geometry: the tab row''s horizontal padding could not be read, so it cannot be compared with the gutter'
}
elseif ($tabRow -ne $gutter) {
    Add-Finding ("geometry: the tab row is indented {0}px but the page gutter is {1}px - the tabs would not line up with the rows below them" -f $tabRow, $gutter)
}

# ------------------------------------------------------------------- served
# Everything above inspects a FILE. The one class of defect a file cannot show is environmental: the live
# server runs in a different process, where a native command's output is decoded with the OEM code page -
# which silently emptied every document date once (docs/03 section 6, P0-12) while all the file-level checks
# were green. So the gate starts the server for real and reads what it actually answers.
$serveRan = $false
if (-not $SkipServe) {
    $serveScript = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $Artifact).Path) 'serve-kanban.ps1'
    $port = 5177
    $serveProc = $null
    try {
        # Launched through cmd WITH the output redirected, on purpose: that is how a background board server
        # is normally started, and it is the shape in which the P0-12 defect reproduces - a child with no
        # console decodes a native command's output with the OEM code page, so the Chinese document names come
        # back as mojibake and their git dates vanish. Starting the server straight from this script HIDES the
        # defect (both ways were measured), which is why the check reproduces the deployment shape rather than
        # a convenient one. The port is dedicated to this check.
        $serveOut = Join-Path $env:TEMP '{{APP_KEY}}-gate-serve-out.txt'
        $cmdLine = 'powershell -ExecutionPolicy Bypass -File "' + $serveScript + '" -NoOpen -Port ' + $port + ' > "' + $serveOut + '" 2>&1'
        $serveProc = Start-Process -FilePath 'cmd' -PassThru -WindowStyle Hidden -ArgumentList '/c', $cmdLine
        $base = "http://localhost:$port"
        $json = $null
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Milliseconds 500
            try { $json = (Invoke-WebRequest "$base/data" -UseBasicParsing -TimeoutSec 10).Content; break } catch { }
        }
        if (-not $json) {
            Write-Host ("  serve: no answer on port {0} - the live check did NOT run (use -SkipServe to silence)" -f $port)
        }
        else {
            $serveRan = $true
            $model = $null
            try { $model = $json | ConvertFrom-Json } catch { Add-Finding 'serve: /data did not return valid JSON' }
            if ($model) {
                foreach ($key in @('packages', 'blockers', 'timeline', 'stages', 'docmap', 'scope')) {
                    if ($null -eq $model.$key) { Add-Finding ("serve: /data carries no {0} collection" -f $key) }
                }
                # The dates come out of a native command's output, so the served payload is compared with the
                # model embedded in the artifact: the build ran in THIS process, where the encoding is right.
                # A deficit means the server's environment decoded the native output differently. Note the
                # shape of the real defect (P0-12): it did NOT empty every date - the ASCII-only file names
                # kept theirs - so "all dates are gone" would have been a guard that never fires. Comparing
                # the two models is both stricter and self-calibrating.
                if ($model.docmap) {
                    $builtMatch = [regex]::Match($html, '^var DATA = (.*);$', 'Multiline')
                    $builtDated = -1
                    if ($builtMatch.Success) {
                        try {
                            $builtModel = $builtMatch.Groups[1].Value | ConvertFrom-Json
                            if ($builtModel.docmap) { $builtDated = @($builtModel.docmap | Where-Object { $_.last }).Count }
                        }
                        catch { }
                    }
                    $servedDated = @($model.docmap | Where-Object { $_.last }).Count
                    if ($builtDated -ge 0 -and $servedDated -lt $builtDated) {
                        Add-Finding ("serve: the served model carries {0} dated document(s), the built one {1} - the server decoded a native command's output differently (docs/03 section 6, P0-12)" -f $servedDated, $builtDated)
                    }
                }
            }
            $page = ''
            try { $page = (Invoke-WebRequest $base -UseBasicParsing -TimeoutSec 10).Content } catch { Add-Finding 'serve: / did not answer' }
            if ($page) {
                if ($page.IndexOf('__DATA__') -ge 0) { Add-Finding 'serve: the served page still contains the __DATA__ placeholder' }
                if ($page.IndexOf('var DATA = {') -lt 0) { Add-Finding 'serve: the served page carries no injected model' }
            }
            if ($model -and $model.docmap -and @($model.docmap).Count -gt 0) {
                $docName = [string](@($model.docmap)[0].name)
                try {
                    $doc = Invoke-WebRequest ("$base/docs/" + [System.Uri]::EscapeDataString($docName)) -UseBasicParsing -TimeoutSec 10
                    if ($doc.Content.Length -lt 10) { Add-Finding 'serve: /docs/<name> answered with an empty body' }
                    if ($doc.Headers['Content-Type'] -notlike 'text/plain*') { Add-Finding 'serve: /docs/<name> must answer as text/plain' }
                }
                catch { Add-Finding ("serve: /docs/{0} did not answer" -f $docName) }
                # The read-only boundary: a traversal attempt must never be served.
                try {
                    $null = Invoke-WebRequest "$base/docs/..%2FREADME.md" -UseBasicParsing -TimeoutSec 10
                    Add-Finding 'serve: /docs/ served a path traversal request'
                }
                catch { }
            }
        }
    }
    catch {
        Write-Host ("  serve: the live check could not run ({0})" -f $_.Exception.Message)
    }
    finally {
        if ($serveProc) { try { Stop-Process -Id $serveProc.ProcessId -Force } catch { } }
        # The server is a grandchild (cmd -> powershell), so it is matched by its dedicated port.
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like ('*-Port ' + $port + '*') } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    }
}

# ------------------------------------------------- every register entry is visible (I16 / I18)
# Why: "each entry of a register reaches the board" had no criterion of its own, and the blind spot is real -
# a BLANK LINE inside a pipe table silently swallows rows, and a missing row is not a fault anywhere on the
# page; it is simply absent. The two registers fail in DIFFERENT ways, which is worth stating precisely
# because the fix a reader would reach for depends on it:
#   * the gap register is read table by table, so the first row of the block AFTER the gap is taken for a
#     header and dropped;
#   * the traceability register is read as ONE slice (from its header to the next heading), so a blank line
#     ENDS the read and every row below it is lost, not just one.
# Both are therefore read here INDEPENDENTLY, with a line regex - never through the shared parser: measuring
# a parser with itself can never fire. Each register is resolved by SHAPE (the widest I-headed / R-headed
# table in docs/), never by its Chinese file name: the tools are ASCII-only and a renamed document must not
# blind the check.
#
# A missing register, or an artifact whose model reports an error, is NOT a finding: a freshly generated repo
# has skeletons with no rows yet, and the board degrades to an empty panel on purpose (CONTRIBUTING section
# 10, item 2). It is printed as a notice instead, so "not judged" can never be read as "judged and clean".
$docsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs'

$embedded = $null
$dataMatch = [regex]::Match($html, '^var DATA = (.*);$', 'Multiline')
if (-not $dataMatch.Success) {
    Add-Finding 'coverage: the artifact carries no embedded model (var DATA = ...), so nothing can be compared'
} else {
    try { $embedded = $dataMatch.Groups[1].Value | ConvertFrom-Json }
    catch { Add-Finding ("coverage: the embedded model could not be parsed ({0})" -f $_.Exception.Message) }
}
$modelUsable = ($embedded -and -not $embedded.error)

function Get-RegisterIds {
    param([string]$HeadPattern, [int]$MinCols)
    $best = $null
    $bestIds = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $ids = @()
        foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
            $m = [regex]::Match($ln, $HeadPattern)
            if (-not $m.Success) { continue }
            # Width tells the tables apart: a narrower table with I-heads somewhere else is not the register.
            $cols = @($ln.Trim().Trim('|') -split '\|').Count
            if ($cols -ge $MinCols) { $ids += $m.Groups[1].Value }
        }
        if ($ids.Count -gt $bestIds.Count) { $best = $f; $bestIds = $ids }
    }
    return @{ File = $best; Ids = $bestIds }
}

# --- gap register: I-headed rows, 6 columns = registered, 4 = closed / archived
$ledger = Get-RegisterIds -HeadPattern '^\s*\|\s*(I\d+)\s*\|' -MinCols 4
$ledgerFile = $ledger.File
$ledgerIds = @($ledger.Ids)
$modelIds = @()
if ($embedded -and $embedded.scope) {
    $modelIds = @(@($embedded.scope.items) + @($embedded.scope.closed) | Where-Object { $_ } | ForEach-Object { [string]$_.id })
}
if (-not $ledgerFile) {
    Write-Host '  gap register : not found yet - coverage NOT judged (fill docs/ before relying on this)'
} elseif (-not $modelUsable) {
    Write-Host ('  gap register : {0} has {1} row(s) but the board model is not usable - coverage NOT judged' -f $ledgerFile.Name, $ledgerIds.Count)
} else {
    foreach ($id in $ledgerIds) {
        if ($modelIds -notcontains $id) {
            Add-Finding ("register: {0} heads a row of {1} but is NOT in the board model - a blank line inside the table makes the parser drop a block's first row" -f $id, $ledgerFile.Name)
        }
    }
    foreach ($id in $modelIds) {
        if ($ledgerIds -notcontains $id) {
            Add-Finding ("register: the model carries {0} but {1} has no such row (stale artifact?)" -f $id, $ledgerFile.Name)
        }
    }
}

# --- traceability register: R-headed rows in the WIDE table (the register, not a narrow R-table elsewhere)
$rtm = Get-RegisterIds -HeadPattern '^\s*\|\s*(R-[A-Za-z0-9-]+)\s*\|' -MinCols 7
$rtmFile = $rtm.File
$rtmIds = @($rtm.Ids)
$modelReqIds = @()
if ($modelUsable) {
    $modelReqs = @($embedded.requirements | Where-Object { $_ })
    $modelReqIds = @($modelReqs | ForEach-Object { [string]$_.id })
    $boardPkgIds = @($embedded.packages | Where-Object { $_ } | ForEach-Object { [string]$_.id })
    $boardStageIds = @($embedded.stages | Where-Object { $_ } | ForEach-Object { [string]$_.stage })

    foreach ($id in $rtmIds) {
        if ($modelReqIds -notcontains $id) {
            Add-Finding ("requirements: {0} heads a row of {1} but is NOT in the board model - a blank line inside the table ENDS the read there, so every row below it is lost" -f $id, $rtmFile.Name)
        }
    }
    foreach ($id in $modelReqIds) {
        if ($rtmIds -notcontains $id) {
            Add-Finding ("requirements: the model carries {0} but {1} has no such row (stale artifact?)" -f $id, $rtmFile.Name)
        }
    }
    # Every way OUT of a requirement row has to land somewhere: a package that is not on the board is a link
    # into empty space, and a stage the stage table does not carry is a jump to nothing.
    foreach ($r in $modelReqs) {
        foreach ($pkgRef in @($r.pkgIds)) {
            if ($boardPkgIds -notcontains $pkgRef) {
                Add-Finding ("requirements: {0} names package {1}, which is not on the board - its row would link nowhere" -f $r.id, $pkgRef)
            }
        }
        if ($r.stage -and ($boardStageIds -notcontains $r.stage)) {
            Add-Finding ("requirements: {0} names stage {1}, which the stage table does not carry" -f $r.id, $r.stage)
        }
    }
    # The tile and the panel have to count the SAME thing, so both read the model's own list: a view that
    # concatenates each package's reqs counts requirement-package PAIRS, which is not a requirement count.
    if (-not [regex]::IsMatch($html, 'function allReqs\(\)\{[^}]*DATA\.requirements')) {
        Add-Finding 'requirements: the board derives its requirement list instead of reading the model field - the tile would count requirement-package pairs'
    }
}
if (-not $rtmFile) {
    Write-Host '  requirements : no wide traceability table found yet - coverage NOT judged'
}

# --- every tab has a panel and every panel has a tab: an entry point that opens nothing and a panel no tab
# can reach are the two halves of one failure, and neither is visible in a screenshot of the other.
$tabSet = @([regex]::Matches($html, 'data-tab="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$panelSet = @([regex]::Matches($html, 'id="p-([a-z]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
foreach ($t in $tabSet) {
    if ($panelSet -notcontains $t) { Add-Finding ("tabs: '{0}' is a tab with no panel (p-{0}) - an entry point that opens nothing" -f $t) }
}
foreach ($p in $panelSet) {
    if ($tabSet -notcontains $p) { Add-Finding ("tabs: the panel p-{0} has no tab - nothing can reach it" -f $p) }
}

# The tab list in the SCRIPT has to know every tab the markup offers. selectTab() resolves an unknown name to
# 'overview', so a tab missing from that list is a tab that does nothing at all - and no screenshot of the
# working tabs can show it. This assertion exists because that defect happened while the tab/panel comparison
# above was green: the button and the panel were both there, only the list was stale.
$nameList = @()
$nm = [regex]::Match($html, 'var TAB_NAMES=\[([^\]]*)\]')
if (-not $nm.Success) {
    Add-Finding 'tabs: the script carries no TAB_NAMES list, so a new tab cannot be resolved by selectTab()'
} else {
    $nameList = @([regex]::Matches($nm.Groups[1].Value, "'([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })
    foreach ($t in $tabSet) {
        if ($nameList -notcontains $t) { Add-Finding ("tabs: '{0}' is a tab but missing from TAB_NAMES - selecting it falls back to the board and the panel never opens" -f $t) }
    }
    foreach ($n in $nameList) {
        if ($tabSet -notcontains $n) { Add-Finding ("tabs: TAB_NAMES lists '{0}' but no tab carries it - a dead entry the reader can never reach" -f $n) }
    }
}

# -------------------------------------------------------------------- report
Write-Host ('kanban-check: {0}' -f (Split-Path -Leaf $Artifact))
if ($light -and $dark) {
    Write-Host ('  palette keys: light {0} / dark {1}' -f $light.Keys.Count, $dark.Keys.Count)
}
Write-Host '  contrast (WCAG 2.1: text 4.5, non-text 3.0)'
foreach ($r in $rows) {
    $verdict = if ($r.Ok) { 'ok  ' } else { 'FAIL' }
    Write-Host ('    {0,-5} {1,6:N2}:1  {2} {3}' -f $r.Theme, $r.Ratio, $verdict, $r.Pair)
}
Write-Host '  deliberately NOT asserted, so the gap stays visible:'
Write-Host '    - form control boundaries (--field-border on --field-bg, --btn-border on --btn-bg):'
Write-Host '      they fail 3:1 today and darkening them is a visible redesign, out of this batch.'
Write-Host '    - hairline separators (--line) and shadows (rgba): decorative, no text sits on them.'
Write-Host '    - gradients: none in this palette; if one is introduced, assert its WORST stop.'
Write-Host '    - geometry beyond the mechanical preconditions: real overlap, truncation and wrapping need a'
Write-Host '      layout engine. Asserted here instead: a sticky header sits in a height-limited scrolling'
Write-Host '      wrapper, and every single-class scroll container is registered in SCROLL_BOXES.'
Write-Host '    - scroll boxes reached through a descendant selector (e.g. a wide table inside a rendered'
Write-Host '      document): their position is not preserved, and the gate does not claim otherwise.'
Write-Host '    - whether the drawer looks right: the smoke evaluates the renderer, not the layout.'
Write-Host '    - the printed layout: the gate sees that a print stylesheet exists, and how a print engine'
Write-Host '      paginates it is outside what a file can show.'
Write-Host '    - the jump itself: the gate sees the target exists and carries a key; whether the pulse reads'
Write-Host '      well, and how far the browser scrolls, is a layout question, not a file one.'
Write-Host '    - the lane edge (--col-border) and the header hairline (--header-line): decorative, no text sits on them.'
Write-Host ('  ledger coverage: {0} entries in {1}, {2} id(s) in the board model' -f $ledgerIds.Count, $(if ($ledgerFile) { $ledgerFile.Name } else { '(no register found)' }), $modelIds.Count)
Write-Host ('  requirement coverage: {0} row(s) in {1}, {2} in the board model; tabs {3} / panels {4}' -f $rtmIds.Count, $(if ($rtmFile) { $rtmFile.Name } else { '(no register found)' }), $modelReqIds.Count, $tabSet.Count, $panelSet.Count)
Write-Host ('  live check: {0}' -f $(if ($SkipServe) { 'skipped (-SkipServe)' } elseif ($serveRan) { 'ran - /data, /, /docs/<name> and a traversal attempt' } else { 'did NOT run (the server could not be started here)' }))
Write-Host ''
if ($script:Findings.Count -eq 0) {
    Write-Host ('KANBAN_CHECK_OK ({0} contrast pairs, {1} wiring assertions, {2} register entries, {3} requirements)' -f $rows.Count, $mustExist.Count, $ledgerIds.Count, $rtmIds.Count)
    exit 0
}
Write-Host ('KANBAN_CHECK_FAIL ({0} findings)' -f $script:Findings.Count)
foreach ($f in $script:Findings) { Write-Host ('  - {0}' -f $f) }
exit 1

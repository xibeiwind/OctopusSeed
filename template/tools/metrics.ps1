<#
tools/metrics.ps1 - process metrics that are REPRODUCIBLE from git alone.

Why this exists
---------------
Two gaps in one tool:
  1. the process could not answer "is it getting faster / more predictable?" (no DORA-style
     numbers at all), and
  2. the mechanical facts in the docs were copy-pasted by hand, so they rotted.

Every number here is derived from git with no CI API, so the same repository state always
yields the same output - and the timeline document carries an auto-generated block that this
script can refresh (-Write) and verify (-Check). That turns "mechanical facts live in exactly
one place" from a principle into something a gate can check.

Metrics (all recomputed, none hand-written)
-------------------------------------------
  packages_total           work-package rows in section 3 of the stage plan
  packages_done            of those, the ones whose status row carries the done glyph
  commits_per_pkg_median   median commit count per package id (commit subjects carry [Px-y])
  lead_time_median_days    first commit of a package -> the merge commit of its branch (days)
  plan_stale_days          days since the stage plan file was last touched (git date)
  open_gaps                open / triggered rows in the range-boundary registration table

Usage
-----
  powershell -ExecutionPolicy Bypass -File tools/metrics.ps1            # report to stdout
  powershell -ExecutionPolicy Bypass -File tools/metrics.ps1 -Write     # refresh the AUTO block
  powershell -ExecutionPolicy Bypass -File tools/metrics.ps1 -Check     # fail if the block is stale

Exit codes
----------
  0 ok / 1 stale or mismatch (-Check) / 2 cannot compute (no git, no stage plan, no AUTO block)

NOTE: kept ASCII-only on purpose (PowerShell 5.1 reads BOM-less UTF-8 as ANSI). Every CJK glyph
used as a DATA marker is built from its code point.
#>
param(
    [switch]$Write,
    [switch]$Check,
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$docsDir = Join-Path $RepoRoot 'docs'
$enc = New-Object System.Text.UTF8Encoding($false)
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$startMark = '<!-- METRICS:AUTO -->'
$endMark = '<!-- /METRICS:AUTO -->'
$metricOrder = @('generated_at', 'packages_total', 'packages_done', 'commits_per_pkg_median', 'lead_time_median_days', 'plan_stale_days', 'open_gaps')

function Invoke-Git([string[]]$gitArgs) {
    # A native command writes to stderr when it fails; under $ErrorActionPreference='Stop' that
    # would abort this script, yet "not a git repository" is a legitimate, non-fatal answer here
    # (it is reported by the caller as "cannot compute", exit 2).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & git -C $RepoRoot @gitArgs 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { return $null }
    return @($out)
}
function Get-Median([double[]]$values) {
    if ($values.Count -eq 0) { return $null }
    $s = @($values | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return [double]$s[[int](($n - 1) / 2)] }
    return [double](($s[$n / 2 - 1] + $s[$n / 2]) / 2)
}
function Format-Num($v) {
    if ($null -eq $v) { return 'n/a' }
    return ([double]$v).ToString('0.0', $inv)
}
function Format-Int($v) {
    if ($null -eq $v) { return 'n/a' }
    return ([int]$v).ToString($inv)
}

if (-not (Test-Path -LiteralPath $docsDir)) { Write-Host "METRICS_FAIL: no docs/ folder under $RepoRoot"; exit 2 }
if ($null -eq (Invoke-Git @('rev-parse', '--git-dir'))) { Write-Host 'METRICS_FAIL: not a git work tree'; exit 2 }

$today = (Get-Date).ToString('yyyy-MM-dd', $inv)

# --- package commits (subjects carry [Px-y]) -------------------------------
$pkgFirst = @{}
$pkgCount = @{}
foreach ($line in @(Invoke-Git @('log', '--no-merges', '--pretty=format:%ad|%s', '--date=short'))) {
    if (-not $line) { continue }
    $parts = $line -split '\|', 2
    if ($parts.Count -lt 2) { continue }
    $m = [regex]::Match($parts[1], '^\[(P[0-9]+-[0-9]+)\]')
    if (-not $m.Success) { continue }
    $id = $m.Groups[1].Value
    if (-not $pkgFirst.ContainsKey($id) -or $parts[0] -lt $pkgFirst[$id]) { $pkgFirst[$id] = $parts[0] }
    $pkgCount[$id] = if ($pkgCount.ContainsKey($id)) { $pkgCount[$id] + 1 } else { 1 }
}

# --- merges (lead time needs the merge date of the package branch) ---------
$mergeDate = @{}
foreach ($line in @(Invoke-Git @('log', '--merges', '--pretty=format:%ad|%s', '--date=short'))) {
    if (-not $line) { continue }
    $parts = $line -split '\|', 2
    if ($parts.Count -lt 2) { continue }
    $m = [regex]::Match($parts[1], 'Merge pull request #[0-9]+ from [^/]+/(P[0-9]+-[0-9]+)')
    if ($m.Success) { $mergeDate[$m.Groups[1].Value] = $parts[0] }
}
$leadTimes = @()
foreach ($id in @($mergeDate.Keys)) {
    if (-not $pkgFirst.ContainsKey($id)) { continue }
    $d0 = [datetime]::ParseExact($pkgFirst[$id], 'yyyy-MM-dd', $inv)
    $d1 = [datetime]::ParseExact($mergeDate[$id], 'yyyy-MM-dd', $inv)
    $leadTimes += ($d1 - $d0).TotalDays
}

# --- stage plan: totals, done count, staleness ----------------------------
$plan = @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^[0-9]+-P[0-9]+' } | Sort-Object Name -Descending) | Select-Object -First 1
$pkgTotal = 0
$pkgDone = 0
$planStale = $null
$doneGlyph = [string][char]0x2705
if ($plan) {
    foreach ($line in [IO.File]::ReadAllLines($plan.FullName, $enc)) {
        if (-not [regex]::IsMatch($line, '^\|\s*\*\*P[0-9]+-[0-9]+\*\*\s*\|')) { continue }
        $pkgTotal++
        if ($line.Contains($doneGlyph)) { $pkgDone++ }
    }
    $rel = 'docs/' + $plan.Name
    $d = @(Invoke-Git @('log', '-1', '--format=%ad', '--date=short', '--', $rel))
    if ($d.Count -gt 0 -and $d[0] -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
        $planStale = ([datetime]::ParseExact($today, 'yyyy-MM-dd', $inv) - [datetime]::ParseExact($d[0], 'yyyy-MM-dd', $inv)).Days
    }
}

# --- range-boundary registration table: open + triggered rows --------------
$openGaps = 0
$glyphOpen = [string][char]0x2B1C
$glyphTriggered = [string][char]0xD83D + [string][char]0xDD35   # triggered glyph (non-BMP: surrogate pair)
foreach ($doc in @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    foreach ($line in [IO.File]::ReadAllLines($doc.FullName, $enc)) {
        if (-not [regex]::IsMatch($line, '^\|\s*I[0-9]+\s*\|')) { continue }
        $cols = @($line.Trim('|') -split '\|')
        if ($cols.Count -ne 6) { continue }                 # registration table only
        $status = $cols[5]
        if ($status.Contains($glyphOpen) -or $status.Contains($glyphTriggered)) { $openGaps++ }
    }
}

# --- assemble --------------------------------------------------------------
$values = [ordered]@{
    'generated_at'           = $today
    'packages_total'         = Format-Int $pkgTotal
    'packages_done'          = Format-Int $pkgDone
    'commits_per_pkg_median' = Format-Num (Get-Median @($pkgCount.Values))
    'lead_time_median_days'  = Format-Num (Get-Median $leadTimes)
    'plan_stale_days'        = Format-Int $planStale
    'open_gaps'              = Format-Int $openGaps
}

function Get-AutoBlockLines($v) {
    $out = @()
    $out += $script:startMark
    $out += '| metric | value |'
    $out += '|---|---|'
    foreach ($k in $script:metricOrder) { $out += ("| {0} | {1} |" -f $k, $v[$k]) }
    $out += $script:endMark
    return $out
}

function Find-BlockHost {
    foreach ($doc in @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
        if ([IO.File]::ReadAllText($doc.FullName, $script:enc).Contains($script:startMark)) { return $doc }
    }
    return $null
}

$blockHost = Find-BlockHost

if (-not $Write -and -not $Check) {
    Write-Host "OctopusSeed metrics (recomputed from git; reproducible)"
    Write-Host ("  repo: {0}" -f $RepoRoot)
    if ($plan) { Write-Host ("  stage plan: docs/{0} (last touched {1} day(s) ago)" -f $plan.Name, (Format-Int $planStale)) }
    else { Write-Host '  stage plan: none found (expected docs/NN-Px执行计划.md)' }
    foreach ($k in $metricOrder) { Write-Host ("  {0,-24} {1}" -f $k, $values[$k]) }
    if ($leadTimes.Count -gt 0) { Write-Host ("  (lead time sample: {0} package(s) merged through a PR)" -f $leadTimes.Count) }
    else { Write-Host '  (lead time sample: none - no package branch was merged via a PR yet)' }
    Write-Host ''
    Write-Host 'METRICS_OK'
    exit 0
}

if (-not $blockHost) {
    Write-Host "METRICS_FAIL: no document carries $startMark (add the block to the timeline document)"
    exit 2
}

$rawText = [IO.File]::ReadAllText($blockHost.FullName, $enc)
$eol = if ($rawText.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = @($rawText -split "`r?`n")
$i0 = -1
$i1 = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -eq $startMark) { $i0 = $i }
    elseif ($i0 -ge 0 -and $lines[$i].Trim() -eq $endMark) { $i1 = $i; break }
}
if ($i0 -lt 0 -or $i1 -lt 0) {
    Write-Host "METRICS_FAIL: the AUTO block in docs/$($blockHost.Name) is not well formed"
    exit 2
}

if ($Write) {
    $out = @()
    if ($i0 -gt 0) { $out += $lines[0..($i0 - 1)] }
    $out += Get-AutoBlockLines $values
    if ($i1 -lt ($lines.Count - 1)) { $out += $lines[($i1 + 1)..($lines.Count - 1)] }
    [IO.File]::WriteAllText($blockHost.FullName, ($out -join $eol), $enc)
    Write-Host ("METRICS_WRITTEN: docs/{0} auto block refreshed" -f $blockHost.Name)
    exit 0
}

# -Check: recompute and compare, ignoring generated_at (it changes every day on purpose)
$stale = @()
$docValues = @{}
$blockLines = @()
if ($i1 -gt ($i0 + 1)) { $blockLines = @($lines[($i0 + 1)..($i1 - 1)]) }
foreach ($line in $blockLines) {
    $m = [regex]::Match($line, '^\|\s*([a-z_]+)\s*\|\s*([^|]*?)\s*\|\s*$')
    if (-not $m.Success) { continue }
    $key = $m.Groups[1].Value
    if ($script:metricOrder -notcontains $key) { continue }   # skips the "| metric | value |" header row
    $docValues[$key] = $m.Groups[2].Value
}
# An uninitialized block (every value still n/a) is a notice, not a failure: a freshly generated
# project must not be born red. Once the block holds real numbers it must stay accurate.
$realValues = @($docValues.Values | Where-Object { $_ -ne 'n/a' })
if ($docValues.Count -gt 0 -and $realValues.Count -eq 0) {
    Write-Host ("METRICS_NOTICE: the AUTO block in docs/{0} is still uninitialized (all n/a) - run tools/metrics.ps1 -Write" -f $blockHost.Name)
    exit 0
}
foreach ($k in $metricOrder) {
    if ($k -eq 'generated_at') { continue }
    $docVal = if ($docValues.ContainsKey($k)) { $docValues[$k] } else { '(missing)' }
    if ($docVal -ne $values[$k]) { $stale += ("{0}: doc says '{1}', recomputed '{2}'" -f $k, $docVal, $values[$k]) }
}
Write-Host ("OctopusSeed metrics check: block in docs/{0}, {1} metric(s) compared" -f $blockHost.Name, ($metricOrder.Count - 1))
foreach ($s in $stale) { Write-Host "::warning title=metrics::stale $s" }
if ($stale.Count -gt 0) {
    Write-Host ("METRICS_STALE: {0} metric(s) differ - run tools/metrics.ps1 -Write" -f $stale.Count)
    exit 1
}
Write-Host 'METRICS_OK'
exit 0

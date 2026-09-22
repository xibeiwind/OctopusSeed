<#
tools/assets.ps1 - the "stock dimension": what projects exist in this repo, who consumes them, and on what
terms they are allowed to stay.

Why this exists
---------------
The governance layer constrains TRANSITIONS (plan -> package -> commit -> backfill -> closeout). Nothing
constrains the STATE "which assets sit in this repo, who consumes them, and on what terms they may stay". A
project kept for a consumer that no longer exists is invisible to every other gate: the build passes, the
tests pass, and governance / kanban / metrics all look somewhere else - so it can survive indefinitely.

The case this was written against: a library imported once, kept because the test project referenced it as a
comparison target, then orphaned when that project dropped the reference - still compiled by the solution,
with no consumer, no ledger row, and no gate able to see it.

What it checks (read-only; it writes nothing)
--------------------------------------------
  1. enumerate projects from the solution file                        (mechanical)
  2. count consumers via <ProjectReference> across all csproj files    (mechanical)
  3. check whether each project has a ledger row in the numbered baseline document `02-*.md`, section 2
     ("engineering placement")                                        (mechanical: substring match)
  4. report: project | consumers | test | ledger | verdict

Finding rule
------------
  consumerCount = 0 AND not a test project AND (no ledger row OR the ledger row is EXPIRED)
                                                                          -> finding.
A zero-consumer project is NOT a finding by itself: a shipped library legitimately has no in-repo consumer.
What must not happen is a zero-consumer project that the ledger does not license with a reason and a
retention condition.

  Ledger convention: the retention-condition cell of a consumer-less project must state the condition. When
  that condition has ALREADY fired, the cell must carry the ASCII marker EXPIRED, and this script keeps
  reporting a finding until the row is written off. Without that rule a ledger row would launder dead weight
  instead of exposing it.

The ledger row must EXIST (completeness is the hard part, and it is mechanical). The "reason / retention
condition" cells are human-written and therefore a SOFT guarantee - this script must never be described as
enforcing them.

This script is a TOOL, not a gate: it is deliberately NOT wired into tools/verify.ps1. Promotion to a
criterion requires hitting it with a known defect first (CONTRIBUTING.md section 8.1 rule 3 / section 10
item 12) - and a criterion that never fires is worse than no criterion, because it buys false confidence.

Usage
-----
  powershell -ExecutionPolicy Bypass -File tools/assets.ps1
  powershell -ExecutionPolicy Bypass -File tools/assets.ps1 -Rev <commit>     # replay a revision

Exit codes: 0 no finding / 1 findings / 2 cannot run.

Replay mode (-Rev) reads the solution and the csproj files from that revision. The ledger is NOT consulted in
replay mode (the baseline document is not readable through git here without its name), so the rule degrades
to "consumerCount = 0 and not a test project".

Falsification (do this before trusting any of it)
-------------------------------------------------
  * control run : a revision where the orphan still had a consumer -> no finding;
  * signal run  : the revision where that consumer disappeared      -> a finding;
  * working tree: the orphan has no ledger row, or a row marked EXPIRED -> a finding.
A checker that fires on everything is not a checker, which is why the control run matters as much as the
signal one.

NOTE this script is ASCII-only on purpose (CONTRIBUTING.md section 10, item 10): PowerShell 5.1 parses
scripts by the local code page, so a CJK literal here would break. The baseline document is therefore
discovered by the pattern `02-*.md`, never spelled out.
#>
param(
    # Empty = read from the working tree. A revision = read the same files from that commit, which is what
    # makes "replay the moment it died" possible.
    [string]$Rev = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Get-RepoText {
    param([string]$RelPath)
    if ($Rev) {
        $lines = & git -C $repoRoot show ("{0}:{1}" -f $Rev, $RelPath) 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($lines -join "`n")
    }
    $full = Join-Path $repoRoot ($RelPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { return $null }
    return (Get-Content -LiteralPath $full -Raw -Encoding UTF8)
}

function Get-NormalizedPath {
    # Resolve a referenced csproj path (of the form ..\..\src\X\X.csproj) against the referencing project's
    # directory and return it repo-relative with forward slashes.
    param([string]$BaseDir, [string]$Relative)
    $combined = [System.IO.Path]::GetFullPath((Join-Path $BaseDir ($Relative -replace '/', '\')))
    $root = [System.IO.Path]::GetFullPath($repoRoot)
    if ($combined.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $combined = $combined.Substring($root.Length).TrimStart('\', '/')
    }
    return ($combined -replace '\\', '/')
}

# --- solution discovery (by pattern, never by a hard-coded name) ---------------
$slnFile = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.sln' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1)
$slnName = ''
if ($slnFile.Count -gt 0) { $slnName = $slnFile[0].Name }
$slnText = if ($slnName) { Get-RepoText $slnName } else { $null }
if (-not $slnText) {
    Write-Host ("assets: no readable solution at the repo root (rev '{0}') -> exit 2" -f $Rev)
    exit 2
}

# --- ledger location (working tree only; pattern-based, never spelled with CJK) ---
$ledgerPath = ''
$ledgerBlock = ''
if (-not $Rev) {
    $docsDir = Join-Path $repoRoot 'docs'
    $cand = @(Get-ChildItem -LiteralPath $docsDir -Filter '02-*.md' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($cand.Count -gt 0) {
        $ledgerPath = 'docs/' + $cand[0].Name
        $text = Get-Content -LiteralPath $cand[0].FullName -Raw -Encoding UTF8
        $start = $text.IndexOf('## 2.')
        if ($start -ge 0) {
            $next = $text.IndexOf("`n## ", $start + 4)
            $ledgerBlock = if ($next -ge 0) { $text.Substring($start, $next - $start) } else { $text.Substring($start) }
        }
    }
}

# --- 1. enumerate projects from the solution -------------------------------
$projects = @()
foreach ($m in [regex]::Matches($slnText, 'Project\("\{[^}]+\}"\)\s*=\s*"([^"]+)"\s*,\s*"([^"]+)"')) {
    $rel = $m.Groups[2].Value -replace '\\', '/'
    if ($rel -notmatch '\.csproj$') { continue }
    $projects += [pscustomobject]@{
        Name = $m.Groups[1].Value
        Path = $rel
        Text = (Get-RepoText $rel)
    }
}

# --- 2. consumer counts ---------------------------------------------------
$consumerOf = @{}
foreach ($p in $projects) { $consumerOf[$p.Path.ToLower()] = 0 }
foreach ($p in $projects) {
    if (-not $p.Text) { continue }
    $baseDir = Split-Path -Parent (Join-Path $repoRoot ($p.Path -replace '/', '\'))
    foreach ($rm in [regex]::Matches($p.Text, '<ProjectReference\s+Include="([^"]+)"')) {
        $target = (Get-NormalizedPath -BaseDir $baseDir -Relative $rm.Groups[1].Value).ToLower()
        if ($consumerOf.ContainsKey($target)) { $consumerOf[$target] = $consumerOf[$target] + 1 }
    }
}

# --- 3. report ------------------------------------------------------------
$label = if ($Rev) { "rev $Rev (ledger not consulted)" } else { 'working tree' }
Write-Host ''
Write-Host "assets: solution projects | consumers | ledger  ($label)"
Write-Host ("  {0,-28} {1,10}  {2,-6} {3,-8} {4}" -f 'project', 'consumers', 'test', 'ledger', 'verdict')
Write-Host ('  ' + ('-' * 84))

$findings = 0
foreach ($p in ($projects | Sort-Object Path)) {
    if (-not $p.Text) {
        Write-Host ("  {0,-28} {1,10}  {2,-6} {3,-8} {4}" -f $p.Name, '?', '?', '?', 'csproj unreadable')
        continue
    }
    $refs = $consumerOf[$p.Path.ToLower()]
    $isTest = ($p.Text -match 'Microsoft\.NET\.Test\.Sdk') -or ($p.Name -match '\.Tests$')
    # NOTE: Split-Path on Windows normalises to backslashes; the ledger uses forward slashes (as does the
    # solution file), so normalise back before matching. Missing this makes every ledger lookup fail
    # silently - which is itself the argument for running a script against a known defect first.
    $dir = (Split-Path -Parent $p.Path) -replace '\\', '/'
    $inLedger = $false
    $rowText = ''
    if ($ledgerBlock -and $dir) {
        foreach ($line in ($ledgerBlock -split "`n")) {
            if ($line -match [regex]::Escape($dir)) { $inLedger = $true; $rowText = $line; break }
        }
    }
    # A ledger row may only LICENCE a consumer-less project while its retention condition still holds. If the
    # condition has fired, the row must carry the ASCII marker EXPIRED - and the finding must stay visible
    # until the row is written off. Otherwise a ledger would launder dead weight instead of exposing it.
    $expired = ($rowText -match '\bEXPIRED\b')

    $verdict = 'ok'
    if ($refs -eq 0 -and -not $isTest) {
        if ($Rev) {
            $verdict = 'FINDING: no consumer (replay mode: ledger not consulted)'
            $findings++
        }
        elseif (-not $inLedger) {
            $verdict = 'FINDING: no consumer and no ledger row'
            $findings++
        }
        elseif ($expired) {
            $verdict = 'FINDING: ledger row marked EXPIRED - write-off pending'
            $findings++
        }
        else {
            $verdict = 'ok (zero consumers, licensed by a ledger row)'
        }
    }
    elseif ($refs -eq 0 -and $isTest) {
        $verdict = 'ok (test entry point)'
    }

    $ledgerCell = if ($Rev) { 'n/a' } elseif ($expired) { 'EXPIRED' } elseif ($inLedger) { 'yes' } else { 'no' }
    $testCell = if ($isTest) { 'yes' } else { 'no' }
    Write-Host ("  {0,-28} {1,10}  {2,-6} {3,-8} {4}" -f $p.Name, $refs, $testCell, $ledgerCell, $verdict)
}

Write-Host ''
if ($Rev) {
    Write-Host '  ledger source : not consulted (replay mode)'
}
else {
    $ledgerState = if ($ledgerBlock) { 'found' } else { 'NOT FOUND - completeness cannot be judged' }
    Write-Host ("  ledger source : {0} section 2 ({1})" -f $ledgerPath, $ledgerState)
}
Write-Host "  findings      : $findings"
if ($findings -gt 0) {
    Write-Host '  RESULT: FINDINGS - a project has no consumer and no VALID ledger licence (row missing or marked EXPIRED).'
    exit 1
}
Write-Host '  RESULT: OK - every consumer-less project is either a test entry point or licensed by the ledger.'
exit 0

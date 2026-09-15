<#
tools/claim.ps1 - claim a package id BEFORE work starts.

Why this exists
---------------
"Register before you use" was only enforced at COMMIT time, which is too late: two parallel
workstreams (a human plus one or more AI sessions) can pick the same id and only collide at
review. The branch name is the earliest observable signal that a package has started, so the
claim has to become an ATOMIC action taken before the branch is cut.

What it does
------------
  1. refuses if the id is already mentioned anywhere under docs/ (it is taken);
  2. otherwise inserts a placeholder row at the end of section 3 of the stage plan
     (the work-package table), which is what registers the id;
  3. prints the branch name to cut.

The file keeps its original line endings and is written as UTF-8 without BOM - a claim must not
turn into a whole-file rewrite (that is how uncommitted work gets lost).

Usage
-----
  powershell -ExecutionPolicy Bypass -File tools/claim.ps1 -Id P0-25
  powershell -ExecutionPolicy Bypass -File tools/claim.ps1 -Id P0-25 -Name process-template

Exit codes
----------
  0 claimed / 1 refused (id already taken) / 2 cannot claim (no stage plan or no section 3)

NOTE: kept ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI). The CJK
bits written into the plan are built from code points for exactly the same reason.
#>
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^P[0-9]+-[0-9]+$')][string]$Id,
    [string]$Name = '',
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$docsDir = Join-Path $RepoRoot 'docs'
$enc = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $docsDir)) { Write-Host "CLAIM_FAIL: no docs/ folder under $RepoRoot"; exit 2 }

# --- 1. is the id already taken? (same rule as the registry check: any mention under docs/) ---
$takenIn = @()
foreach ($doc in @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    $text = [IO.File]::ReadAllText($doc.FullName, $enc)
    if ([regex]::IsMatch($text, [regex]::Escape($Id) + '(?![0-9])')) { $takenIn += $doc.Name }
}
if ($takenIn.Count -gt 0) {
    Write-Host "CLAIM_REFUSED: $Id is already registered in: $($takenIn -join ', ')"
    Write-Host '  pick the next free id, or work on the existing one.'
    exit 1
}

# --- 2. locate the stage plan by file-name shape (ASCII test, no CJK literal needed) ---
$plans = @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^[0-9]+-P[0-9]+' } | Sort-Object Name -Descending)
if ($plans.Count -eq 0) {
    Write-Host 'CLAIM_FAIL: no stage plan found under docs/ (expected the shape NN-Px执行计划.md).'
    Write-Host '  create one from the stage-plan template first, then claim again.'
    exit 2
}
$plan = $plans[0]

$raw = [IO.File]::ReadAllText($plan.FullName, $enc)
$eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = @($raw -split "`r?`n")

$startIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^##\s*3\.') { $startIdx = $i; break }
}
if ($startIdx -lt 0) { Write-Host "CLAIM_FAIL: section '## 3.' not found in $($plan.Name)"; exit 2 }

$lastTable = -1
for ($i = $startIdx + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^##\s*[0-9]+\.') { break }
    if ($lines[$i].StartsWith('|')) { $lastTable = $i }
}
if ($lastTable -lt 0) { Write-Host "CLAIM_FAIL: no table under section 3 of $($plan.Name)"; exit 2 }

# --- 3. insert the placeholder row (CJK built from code points) ---
$occupied = [string]([char]0x5360) + [char]0x4F4D                       # "placeholder"
$dash = [string][char]0x2014                                             # em dash
$inProgress = [string][char]0xD83D + [string][char]0xDD04                # in-progress glyph (non-BMP: surrogate pair)
$what = if ($Name) { $Name } else { '(describe the package before work starts)' }
$row = "| **$Id** | $occupied (claimed): $what | $dash | $inProgress |"

$out = @()
$out += $lines[0..$lastTable]
$out += $row
if ($lastTable -lt ($lines.Count - 1)) { $out += $lines[($lastTable + 1)..($lines.Count - 1)] }
[IO.File]::WriteAllText($plan.FullName, ($out -join $eol), $enc)

Write-Host "CLAIM_OK: $Id registered in docs/$($plan.Name) (section 3)."
Write-Host "  now cut the branch:  git switch -c $Id-short-english-description"
Write-Host '  keep the row as the single place that registers this id; replace the placeholder text with the real scope.'
exit 0

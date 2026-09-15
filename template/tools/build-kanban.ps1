<#
Generate a static, self-contained browser kanban from the governance docs.

The board is rendered entirely client-side from data parsed out of
docs/03-P0执行计划.md (section 3 work packages + section 8 open decisions) and
docs/需求跟踪矩阵.md (RTM). This file is the offline/portable path: it writes one
static HTML (tools/kanban.html) with the data embedded. For a LIVE board that updates
in place when you edit the docs (no page reload), run tools/serve-kanban.ps1 instead.

Shared parsing lives in kanban-data.ps1 so the two entry points never drift.

Conventions: ASCII-only script (see kanban-data.ps1 header). Docs are the single source
of truth; re-run this to resync. Drag-and-drop reorders are stored only in the browser's
localStorage (a personal view) and never write back to the docs.

Usage
-----
  powershell -ExecutionPolicy Bypass -File tools/build-kanban.ps1
#>
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Continue'

. "$PSScriptRoot/kanban-data.ps1"

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$tmplPath = Join-Path $PSScriptRoot 'kanban.template.html'
$outPath  = Join-Path $PSScriptRoot 'kanban.html'

if (-not (Test-Path -LiteralPath $tmplPath)) { Write-Host "::notice title=kanban::template missing: $tmplPath"; exit 0 }

$json = Get-KanbanJson -RepoRoot $RepoRoot
$tmpl = Get-Content -LiteralPath $tmplPath -Raw -Encoding UTF8
$html = $tmpl.Replace('__DATA__', $json)
[System.IO.File]::WriteAllText($outPath, $html, [System.Text.UTF8Encoding]::new($false))

$m = $json | ConvertFrom-Json
Write-Host "KANBAN_OK: wrote $outPath"
Write-Host ("    packages: {0}, blockers: {1}, unassigned requirements: {2}" -f $m.packages.Count, $m.blockers.Count, $m.unassigned.Count)
Write-Host "    open in browser: file:///$outPath"
exit 0

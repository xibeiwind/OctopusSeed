<#
OctopusSeed - generator.

Renders the process template into a target directory:
  * copies template/** (stack-agnostic core) and variants/<stack>/** (if any);
  * replaces {{PLACEHOLDERS}} (see manifest.json / MANIFEST.md section 1);
  * injects the stack CI job into .github/workflows/verify-clean-build.yml at the
    {{STACK_JOB}} anchor (removed when -Stack generic);
  * prints the manual follow-up checklist.

Usage
-----
  powershell -ExecutionPolicy Bypass -File init.ps1 -Target C:\work\MyApp -ProjectName MyApp -Stack dotnet
  powershell -ExecutionPolicy Bypass -File init.ps1 -Target C:\work\MyApp -ProjectName MyApp -Stack dotnet -DryRun
  powershell -ExecutionPolicy Bypass -File init.ps1 -Target C:\work\api -ProjectName MyApi -Stack go `
      -IntegrationBranch trunk -CiRunner '["ubuntu-latest"]'

NOTE: kept ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI,
so a non-ASCII byte inside a script can garble output or even break parsing).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$ProjectName,
    [string]$AppKey = '',
    [ValidateSet('generic', 'dotnet', 'typescript', 'go')][string]$Stack = 'generic',
    [string]$IntegrationBranch = 'develop',
    [string]$ReleaseBranch = 'main',
    [string]$CiRunner = '["windows-latest"]',
    [string]$BuildCmd = '',
    [string]$TestCmd = '',
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$encNoBom = New-Object System.Text.UTF8Encoding($false)
$encBom = New-Object System.Text.UTF8Encoding($true)

function Read-Text([string]$p) { return [IO.File]::ReadAllText($p, $encNoBom) }

$meta = Read-Text (Join-Path $root 'manifest.json') | ConvertFrom-Json
$coreRoot = Join-Path $root ([string]$meta.roots.core)
$variantsRoot = Join-Path $root ([string]$meta.roots.variants)
$stackMeta = $meta.stacks.PSObject.Properties[$Stack].Value

if (-not (Test-Path -LiteralPath $coreRoot)) { throw "core root not found: $coreRoot" }

# --- parameters -> values ----------------------------------------------------
if (-not $AppKey) {
    $words = @($ProjectName -split '[^A-Za-z0-9]+' | Where-Object { $_ })
    $key = ($words -join '')
    if ($words.Count -gt 1 -and $key.Length -gt 8) { $key = ($words | ForEach-Object { $_.Substring(0, 1) }) -join '' }
    $AppKey = $key.ToLower()
}
if (-not $BuildCmd) { $BuildCmd = [string]$stackMeta.buildCmd }
if (-not $TestCmd) { $TestCmd = [string]$stackMeta.testCmd }
# I1 (mainline-runnable) has no stack-agnostic form: a real smoke command is project-specific.
# An empty smokeCmd renders the generic hint, and CONTRIBUTING.md section 6 declares the invariant
# UNGUARDED in that case - a gate that cannot fail is not a gate.
$SmokeCmd = [string]$stackMeta.smokeCmd
if (-not $SmokeCmd) { $SmokeCmd = '<your smoke command>' }

$map = [ordered]@{
    'PROJECT_NAME'       = $ProjectName
    'APP_KEY'            = $AppKey
    'STACK_NAME'         = [string]$stackMeta.display
    'STACK_ID'           = $Stack
    'BUILD_CMD'          = $BuildCmd
    'TEST_CMD'           = $TestCmd
    'SMOKE_CMD'          = $SmokeCmd
    'INTEGRATION_BRANCH' = $IntegrationBranch
    'RELEASE_BRANCH'     = $ReleaseBranch
    'CI_RUNNER'          = $CiRunner
}

function Render([string]$text) {
    foreach ($k in $map.Keys) { $text = $text.Replace('{{' + $k + '}}', [string]$map[$k]) }
    return $text
}

# --- stack CI job (injected at the {{STACK_JOB}} anchor) ---------------------
$jobText = ''
$jobRel = [string]$stackMeta.job
if ($jobRel) {
    $jobPath = Join-Path (Join-Path $variantsRoot $Stack) ($jobRel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $jobPath)) { throw "stack job not found: $jobPath" }
    $jobText = (Render (Read-Text $jobPath)).TrimEnd()
}

# --- stack gate section (injected into the generated README) ----------------
# The variant folder itself is NOT copied into the target, so the gate write-up has to travel
# with the generated docs - otherwise the reader of the new repo has no idea what enforces what.
$gateText = ''
$gatePath = Join-Path (Join-Path $variantsRoot $Stack) 'gate.md'
if ($Stack -ne 'generic' -and (Test-Path -LiteralPath $gatePath)) {
    $gateText = (Render (Read-Text $gatePath)).TrimEnd()
}

# --- target guard -----------------------------------------------------------
$TargetFull = [IO.Path]::GetFullPath($Target)
if (Test-Path -LiteralPath $TargetFull) {
    $existing = @(Get-ChildItem -LiteralPath $TargetFull -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0 -and -not $Force) {
        throw "target '$TargetFull' is not empty. Pass -Force to overwrite files with the same name."
    }
}

$plan = New-Object System.Collections.ArrayList
$written = 0

function Emit([string]$srcRoot, [System.IO.FileInfo]$file, [bool]$isVariant) {
    $rel = $file.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
    if ($isVariant) {
        $top = ($rel -split '[\\/]')[0]
        if (@($meta.variantOnlyDirs) -contains $top) { return }
        if (@($meta.variantOnlyFiles) -contains $rel) { return }
    }
    $dest = Join-Path $TargetFull $rel
    $ext = [IO.Path]::GetExtension($file.Name)
    $isText = (@($meta.textExtensions) -contains $ext) -or [string]::IsNullOrEmpty($ext)

    $script:plan.Add($rel) | Out-Null
    if ($DryRun) { return }

    $dir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    if (-not $isText) { Copy-Item -LiteralPath $file.FullName -Destination $dest -Force; $script:written++; return }

    $text = Render (Read-Text $file.FullName)
    if ($rel -like '.github\workflows\*' -and $text.Contains('{{STACK_JOB}}')) {
        if ($jobText) {
            $text = $text.Replace('{{STACK_JOB}}', $jobText)
        } else {
            $text = $text -replace '(?m)^[ \t*#]*\{\{STACK_JOB\}\}[ \t]*\r?\n', ''
        }
    }
    if ($text.Contains('{{STACK_GATE}}')) {
        if ($gateText) {
            $text = $text.Replace('{{STACK_GATE}}', $gateText)
        } else {
            $text = $text -replace '(?m)^[ \t]*\{\{STACK_GATE\}\}[ \t]*\r?\n', ''
        }
    }
    $useBom = ($ext -eq '.ps1')
    [IO.File]::WriteAllText($dest, $text, $(if ($useBom) { $encBom } else { $encNoBom }))
    $script:written++
}

foreach ($f in @(Get-ChildItem -LiteralPath $coreRoot -Recurse -File -Force)) { Emit $coreRoot $f $false }

$variantDir = Join-Path $variantsRoot $Stack
if ($Stack -ne 'generic' -and (Test-Path -LiteralPath $variantDir)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $variantDir -Recurse -File -Force)) { Emit $variantDir $f $true }
}

# --- report -----------------------------------------------------------------
Write-Host ''
Write-Host ("OctopusSeed -> {0}" -f $TargetFull)
Write-Host ("  project   : {0}   (app key: {1})" -f $ProjectName, $AppKey)
Write-Host ("  stack     : {0}   build: {1}   test: {2}" -f $Stack, $BuildCmd, $TestCmd)
Write-Host ("  branches  : {0} (integration) / {1} (release)" -f $IntegrationBranch, $ReleaseBranch)
Write-Host ("  runner    : {0}" -f $CiRunner)
if ($jobText) { Write-Host ("  ci job    : injected from variants/{0}/{1}" -f $Stack, $jobRel) }
else { Write-Host '  ci job    : none (-Stack generic -> governance line only)' }
Write-Host ''
Write-Host ("  files     : {0} {1}" -f $plan.Count, $(if ($DryRun) { '(dry run, nothing written)' } else { "planned, $written written" }))
foreach ($p in ($plan | Sort-Object)) { Write-Host ("    - " + $p) }

# Next-step hints are DERIVED from the generated tree, never written as CJK literals:
# this script is ASCII-only on purpose (PowerShell 5.1 would mis-parse a CJK literal here).
$docsDir = Join-Path $TargetFull 'docs'
$tplDirName = ''
$baselineNames = ''
if (Test-Path -LiteralPath $docsDir) {
    $sub = @(Get-ChildItem -LiteralPath $docsDir -Directory -Force)
    if ($sub.Count -gt 0) { $tplDirName = $sub[0].Name }
    $baselineNames = (@(Get-ChildItem -LiteralPath $docsDir -File -Filter '*.md' -Force | ForEach-Object { $_.Name }) -join ', ')
}

Write-Host ''
Write-Host 'Next steps (manual, once):'
Write-Host ("  1) git init -b {0} && git switch -c {1}" -f $ReleaseBranch, $IntegrationBranch)
Write-Host '  2) git config core.hooksPath .githooks        # enables the commit-prefix gate'
Write-Host ("  3) add the baselines beside these skeletons: docs/ [{0}]   (01 = requirements, 02 = design)" -f $baselineNames)
Write-Host ("  4) create the first stage plan in docs/ from docs/{0}/ ; fill its sections 3 and 8 FIRST" -f $tplDirName)
Write-Host '  5) powershell -ExecutionPolicy Bypass -File tools/governance-check.ps1'
Write-Host ("  6) push, then set repository variable CI_RUNNER_LABELS = {0}" -f $CiRunner)
Write-Host ''
Write-Host 'Gate discipline: read CONTRIBUTING.md section 1 (numbering) BEFORE the first commit.'
Write-Host 'Reminder: provoke one deliberate violation and confirm the gate catches it - an unproven gate is not a gate.'

<#
OctopusSeed - template self-check.

Why this exists: the template ships as a *copy*, so it can silently rot in ways a normal
repo gate cannot see - an unknown {{PLACEHOLDER}} left behind, a source-project token that
survived the extraction, a required file deleted, a doc reference pointing at nothing, or a
generator that no longer produces a usable project. This script IS that gate. Read-only
(except -Smoke, which writes to a temp folder and removes it again).

Checks
------
  1. required       every file listed in manifest.json "required" exists
  2. placeholder    every {{TOKEN}} used in template/ and variants/ is declared in manifest.json;
                    no forbidden source-project token survives
  3. docs-drift     MANIFEST.md section 1 and manifest.json declare the SAME placeholder set
  4. docref         relative references inside template/**/*.md and *.mdc resolve
                    (paths that only exist AFTER generation are skipped on purpose)
  5. smoke          -Smoke: generate every stack into a temp folder and assert the result is usable

Usage
-----
  powershell -ExecutionPolicy Bypass -File template-check.ps1
  powershell -ExecutionPolicy Bypass -File template-check.ps1 -Smoke

NOTE: kept ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI);
the CJK tokens this script must look for live in manifest.json (UTF-8, read explicitly).
#>
param(
    [switch]$Smoke,
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Continue'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$enc = New-Object System.Text.UTF8Encoding($false)
function Read-Text([string]$p) { return [IO.File]::ReadAllText($p, $enc) }

$findings = New-Object System.Collections.ArrayList
function Finding([string]$check, [string]$msg) { $script:findings.Add("[$check] $msg") | Out-Null; Write-Host "::warning title=seed/$check::$msg" }
function Notice([string]$check, [string]$msg) { Write-Host "::notice title=seed/$check::$msg" }
function Info([string]$msg) { Write-Host "    $msg" }

$metaPath = Join-Path $RepoRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $metaPath)) { Write-Host 'SEED_CHECK_FAIL: manifest.json not found'; exit 1 }
$meta = Read-Text $metaPath | ConvertFrom-Json

$coreRoot = Join-Path $RepoRoot ([string]$meta.roots.core)
$variantsRoot = Join-Path $RepoRoot ([string]$meta.roots.variants)
$textExts = @($meta.textExtensions)
$forbidden = @($meta.forbiddenInTemplate)
$laterPrefixes = @($meta.generatedLaterDocPrefixes)
$repoLevelRefs = @($meta.repoLevelRefs)
$generatedArtifacts = @($meta.generatedArtifacts)

$allowed = @{}
foreach ($p in $meta.placeholders.PSObject.Properties) { $allowed[$p.Name] = $true }

function Test-IsText([System.IO.FileInfo]$f) {
    $ext = [IO.Path]::GetExtension($f.Name)
    return (($script:textExts -contains $ext) -or [string]::IsNullOrEmpty($ext))
}
function Test-SkipRef([string]$r) {
    if ($r -match '^[a-z]+://' -or $r.StartsWith('#') -or $r -match '^mailto:') { return $true }
    if ($r.StartsWith('/')) { return $true }
    if ($r -match '[<>*{}\[\]]' -or $r -match '\s') { return $true }
    if ($r -match 'Px-y' -or $r -match '\.\.\.') { return $true }
    if ($r.EndsWith('/')) { return $true }                               # directory mention (bin/, obj/, node_modules/)
    if ($r.StartsWith('.git/')) { return $true }                         # git internals, never a repo file
    if ($r -match '^docs/[0-9]+$') { return $true }                      # docs/NN shorthand
    foreach ($ga in $script:generatedArtifacts) { if ($r -eq $ga) { return $true } }
    foreach ($pfx in $script:laterPrefixes) { if ($r.StartsWith($pfx)) { return $true } }
    foreach ($rl in $script:repoLevelRefs) { if ($r -eq $rl -or $r.StartsWith($rl)) { return $true } }
    return $false
}

# --- [1/5] required files ----------------------------------------------------
Write-Host ''
Write-Host '--- [1/5] required files (both directions) ---'
$missing = 0
$requiredSet = @{}
foreach ($rel in @($meta.required)) {
    $requiredSet[$rel] = $true
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot ($rel -replace '/', '\')))) { Finding 'required' "missing: $rel"; $missing++ }
}
# reverse direction: a file that ships with the template but is not declared would silently
# escape every other check (the manifest is what init.ps1 and this script trust).
$shipped = @()
foreach ($rt in @($coreRoot, $variantsRoot)) {
    if (Test-Path -LiteralPath $rt) {
        $shipped += @(Get-ChildItem -LiteralPath $rt -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($RepoRoot.Length).TrimStart('\') -replace '\\', '/' })
    }
}
$undeclared = 0
foreach ($s in $shipped) {
    if (-not $requiredSet.ContainsKey($s)) { Finding 'manifest' "shipped but not declared in manifest.json required : $s"; $undeclared++ }
}
Info ("declared {0}, shipped {1}, missing {2}, undeclared {3}" -f @($meta.required).Count, $shipped.Count, $missing, $undeclared)

# --- [2/5] placeholders & forbidden tokens ----------------------------------
Write-Host ''
Write-Host '--- [2/5] placeholders & forbidden tokens ---'
$files = @()
if (Test-Path -LiteralPath $coreRoot) { $files += @(Get-ChildItem -LiteralPath $coreRoot -Recurse -File -Force) }
if (Test-Path -LiteralPath $variantsRoot) { $files += @(Get-ChildItem -LiteralPath $variantsRoot -Recurse -File -Force) }
$unknown = 0
$usedKeys = @{}
foreach ($f in $files) {
    if (-not (Test-IsText $f)) { continue }
    $t = Read-Text $f.FullName
    $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart('\')
    foreach ($m in [regex]::Matches($t, '\{\{([A-Z][A-Z0-9_]*)\}\}')) {
        $k = $m.Groups[1].Value
        $usedKeys[$k] = $true
        if (-not $allowed.ContainsKey($k)) { Finding 'placeholder' "$rel : unknown placeholder {{$k}}"; $unknown++ }
    }
    foreach ($w in $forbidden) {
        if ($w -and $t.Contains($w)) { Finding 'forbidden' "$rel : contains source-project token '$w'"; $unknown++ }
    }
}
Info ("files scanned: {0}; placeholders in use: {1}" -f $files.Count, (($usedKeys.Keys | Sort-Object) -join ', '))
foreach ($k in $allowed.Keys) {
    if (-not $usedKeys.ContainsKey($k)) { Notice 'placeholder' "declared but unused (fine if the stack job needs it): {{$k}}" }
}

# --- [3/5] MANIFEST.md <-> manifest.json -----------------------------------
Write-Host ''
Write-Host '--- [3/5] placeholder documentation drift ---'
$manifestMd = Join-Path $RepoRoot 'MANIFEST.md'
if (Test-Path -LiteralPath $manifestMd) {
    $md = Read-Text $manifestMd
    $inMd = @{}
    foreach ($m in [regex]::Matches($md, '\{\{([A-Z][A-Z0-9_]*)\}\}')) { $inMd[$m.Groups[1].Value] = $true }
    foreach ($k in $allowed.Keys) {
        if (-not $inMd.ContainsKey($k)) { Finding 'docs-drift' "MANIFEST.md does not document {{$k}}" }
    }
    foreach ($k in $inMd.Keys) {
        if (-not $allowed.ContainsKey($k)) { Finding 'docs-drift' "MANIFEST.md documents {{$k}} but manifest.json does not declare it" }
    }
    Info ("manifest.json: {0} placeholders; MANIFEST.md: {1}" -f $allowed.Count, $inMd.Count)
} else {
    Finding 'docs-drift' 'MANIFEST.md not found'
}

# --- [4/5] relative references in the shipped docs -------------------------
Write-Host ''
Write-Host '--- [4/5] doc references resolve ---'
$docFiles = @()
if (Test-Path -LiteralPath $coreRoot) {
    $docFiles = @(Get-ChildItem -LiteralPath $coreRoot -Recurse -File -Force | Where-Object { $_.Extension -in '.md', '.mdc' })
}
$unresolved = 0
$checked = 0
foreach ($doc in $docFiles) {
    $docDir = Split-Path -Parent $doc.FullName
    $rel = $doc.FullName.Substring($RepoRoot.Length).TrimStart('\')
    $lineNo = 0
    foreach ($line in [IO.File]::ReadAllLines($doc.FullName, $enc)) {
        $lineNo++
        $cands = @()
        $linkScope = [regex]::Replace($line, '`[^`]*`', ' ')
        foreach ($m in [regex]::Matches($linkScope, '\]\(([^)\s]+)\)')) { $cands += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($line, '`([^`]+)`')) {
            $code = $m.Groups[1].Value.Trim()
            if ($code -match '/') { $cands += $code }
        }
        foreach ($raw in $cands) {
            $r = $raw.Trim()
            if (Test-SkipRef $r) { continue }
            $checked++
            $clean = ($r -split '#')[0].TrimEnd('/', '.')
            if (-not $clean) { continue }
            $ok = (Test-Path -LiteralPath (Join-Path $docDir $clean)) -or (Test-Path -LiteralPath (Join-Path $coreRoot $clean))
            if (-not $ok) { Finding 'docref' "${rel}:$lineNo : '$r' does not resolve"; $unresolved++ }
        }
    }
}
Info ("documents: {0}; references checked: {1}; unresolved: {2}" -f $docFiles.Count, $checked, $unresolved)

# --- [5/5] smoke: generate every stack ------------------------------------
if ($Smoke) {
    Write-Host ''
    Write-Host '--- [5/5] smoke: generate each stack into a temp folder ---'
    $init = Join-Path $RepoRoot 'init.ps1'
    if (-not (Test-Path -LiteralPath $init)) {
        Finding 'smoke' 'init.ps1 not found'
    } else {
        foreach ($stack in @('generic', 'dotnet', 'typescript', 'go')) {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('seed-smoke-' + $stack + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
            try {
                $null = & $init -Target $tmp -ProjectName DemoSeed -Stack $stack
                if (-not (Test-Path -LiteralPath (Join-Path $tmp 'CONTRIBUTING.md'))) { Finding 'smoke' "$stack : CONTRIBUTING.md missing after generation" }
                if (-not (Test-Path -LiteralPath (Join-Path $tmp '.githooks\commit-msg'))) { Finding 'smoke' "$stack : .githooks/commit-msg missing" }
                if (-not (Test-Path -LiteralPath (Join-Path $tmp '.gitignore'))) { Finding 'smoke' "$stack : .gitignore missing" }

                $left = @()
                foreach ($g in @(Get-ChildItem -LiteralPath $tmp -Recurse -File -Force)) {
                    if (-not (Test-IsText $g)) { continue }
                    # a bare '{{' would also match GitHub Actions '${{ ... }}' expressions, so look
                    # only for OUR token shape ({{UPPER_SNAKE}}) - otherwise every workflow is a false positive
                    if ([regex]::IsMatch((Read-Text $g.FullName), '\{\{[A-Z][A-Z0-9_]*\}\}')) {
                        $left += $g.FullName.Substring($tmp.Length).TrimStart('\')
                    }
                }
                if ($left.Count -gt 0) { Finding 'smoke' ("$stack : unresolved placeholders in " + ($left -join ', ')) }

                $hook = Read-Text (Join-Path $tmp '.githooks\commit-msg')
                if (-not $hook.StartsWith('#!')) { Finding 'smoke' "$stack : commit-msg must start with a shebang (BOM would break exec)" }

                $wf = Join-Path $tmp '.github\workflows\verify-clean-build.yml'
                if (Test-Path -LiteralPath $wf) {
                    $wt = Read-Text $wf
                    if ($wt.Contains('{{STACK_JOB}}')) { Finding 'smoke' "$stack : CI anchor STACK_JOB was not replaced" }
                    if ($stack -eq 'dotnet' -and -not $wt.Contains('dotnet:')) { Finding 'smoke' 'dotnet : stack job was not injected' }
                    if ($stack -eq 'generic' -and $wt.Contains('dotnet:')) { Finding 'smoke' 'generic : unexpected stack job present' }
                } else {
                    Finding 'smoke' "$stack : workflow missing"
                }

                # every shipped PowerShell tool must at least parse - a gate that cannot run is
                # indistinguishable from a gate that passed (CONTRIBUTING.md section 10, item 12).
                # Enumerated, not listed: a tool added to tools/ (by the core or by a variant) is covered
                # the moment it ships, instead of silently escaping the check until someone edits the list.
                $toolDir = Join-Path $tmp 'tools'
                if (-not (Test-Path -LiteralPath $toolDir)) {
                    Finding 'smoke' "$stack : tools/ missing after generation"
                } else {
                    $shippedTools = @(Get-ChildItem -LiteralPath $toolDir -Filter '*.ps1' -File | Sort-Object Name)
                    if ($shippedTools.Count -eq 0) { Finding 'smoke' "$stack : no PowerShell tool was generated" }
                    foreach ($tool in $shippedTools) {
                        $parseErrors = $null
                        [void][System.Management.Automation.Language.Parser]::ParseFile($tool.FullName, [ref]$null, [ref]$parseErrors)
                        if ($parseErrors.Count -gt 0) { Finding 'smoke' "$stack : tools/$($tool.Name) does not parse: $($parseErrors[0].Message)" }
                    }
                    # The judgement entry point is the one criterion carrier whose absence would be silent:
                    # a repo without tools/verify.ps1 still builds clean, so it is asserted explicitly.
                    if (-not (Test-Path -LiteralPath (Join-Path $toolDir 'verify.ps1'))) { Finding 'smoke' "$stack : tools/verify.ps1 missing" }
                }

                # the metrics assertion must actually be wired into the CI job
                if ($wt -and -not $wt.Contains('metrics.ps1 -Check')) { Finding 'smoke' "$stack : CI does not run tools/metrics.ps1 -Check" }

                Info ("{0}: generated {1} files - ok" -f $stack, @(Get-ChildItem -LiteralPath $tmp -Recurse -File -Force).Count)
            } catch {
                Finding 'smoke' "$stack : generation threw: $($_.Exception.Message)"
            } finally {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }
} else {
    Write-Host ''
    Write-Host '--- [5/5] smoke skipped (pass -Smoke to enable) ---'
}

# --- verdict ---------------------------------------------------------------
Write-Host ''
if ($findings.Count -gt 0) {
    Write-Host ("SEED_CHECK_FINDINGS: {0}" -f $findings.Count)
    exit 1
}
Write-Host 'SEED_CHECK_OK'
exit 0

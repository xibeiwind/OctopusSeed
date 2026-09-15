<#
Governance line for {{PROJECT_NAME}} - the "specs & docs" gate.

Why this exists
---------------
A repository with a code-only gate has exactly one blind spot: docs, rules and specs are the
ONLY assets with no check at all. Stale references and "ghost package ids" then can only be
found by hand, and structurally never by a gate. This script IS that gate. It is read-only:
it never edits anything.

Six checks
----------
  1. commitmsg  commit subjects of THIS change must start with a package prefix `[Px-y]`
                (CONTRIBUTING.md section 3). Historic subjects often do not comply (early
                prototype commits, stage-level `[P9]`, `style:`/`docs:` conventional commits),
                therefore the default scope is the CHANGED RANGE ONLY - never the whole
                history. Scanning history would be red forever and useless.
  2. docrefs    relative references inside the governance docs must resolve to real files.
                Only path-like tokens are checked: Markdown link targets (link syntax written
                INSIDE inline code is prose about links, not a reference - stripped before
                matching), inline code containing '/' plus a known extension, and bare
                `docs/NN` / `docs/NN/MM` shorthand (resolved as docs/NN-*.md). The token rules
                are deliberately narrow: a broad first cut produced mostly checker bugs
                (zero-padding) rather than real rot. Still warn-only by default.
  3. registry   package ids used by commits must be registered in the governance docs - catches
                "ghost packages" (an id that exists as a branch and a commit prefix before it
                is registered anywhere). Default scope is the changed range (same as commitmsg);
                use -RegistryAll for a full-history audit, which will surface known historical
                leftovers.
  4. claim      the BRANCH NAME is a claim on a package id, so `-Branch <name>` must carry an id
                that is already registered in docs/*.md. Rationale: "register before you use" was
                only enforced at commit time, which is too late - two parallel workstreams can
                pick the same id and only collide at review. The branch is the earliest
                OBSERVABLE signal of "this package has started", so it is where the check belongs.
  5. provenance unresolved values must have an owner. Every "to be measured / to be decided"
                marker inside the numbered baseline docs (01-/02-) must sit on a line (or under a
                heading) that names where the value will come from: a docs/ reference, or an
                I#/Q# gap id, or a package id. Rationale: when AI does the mechanical writing, a
                confident-looking but unsourced statement is the cheapest possible mistake - and
                no shape check catches it.
  6. hotdocs    one commit deleting more than -HotDocDeletes lines from any docs/*.md is
                reported. Rationale: "never rewrite a tracked document wholesale" cannot be
                judged mechanically, but the risky ACTION has a mechanical signature - mass
                deletion. The gate makes it visible before the accident, instead of banning it.

All six are read-only. An id can be CLAIMED (written into the stage plan) by tools/claim.ps1;
this script never writes.

Strictness
----------
Findings are warnings by default. `-Strict all` (or a comma list of check names) makes the
selected checks exit 1. Roll out per check: measure first, promote later. This mirrors the
fail-open gating philosophy of .github/workflows/verify-clean-build.yml.

"Cannot judge" is never a failure: an unresolvable git range, a missing git or a missing
documentation folder is reported as a notice and skipped.

Usage
-----
  powershell -ExecutionPolicy Bypass -File tools/governance-check.ps1
  powershell -ExecutionPolicy Bypass -File tools/governance-check.ps1 -Range origin/develop...HEAD
  powershell -ExecutionPolicy Bypass -File tools/governance-check.ps1 -Range <before>..<after> -Strict registry
  powershell -ExecutionPolicy Bypass -File tools/governance-check.ps1 -RegistryAll -Strict all

NOTE: kept ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI, so a
non-ASCII byte inside a script can garble output or even break parsing).
#>
param(
    # Git range for the commit-message and registry checks, e.g. "origin/develop...HEAD" or
    # "<before>..<after>". Empty (default) means "only the tip commit" - the useful local default.
    [string]$Range = '',
    # Which checks fail the build on findings: 'all' or a comma list of
    # commitmsg,docrefs,registry,claim,provenance,hotdocs.
    [string]$Strict = '',
    # Registry only: scan the whole history instead of just the changed range (audit mode).
    [switch]$RegistryAll,
    # Branch name of the change under review (CI passes github.head_ref). Used by the `claim`
    # check: the package id carried by the branch must already be registered. Empty skips it.
    [string]$Branch = '',
    # hotdocs only: how many lines deleted from ONE docs/*.md file by ONE commit is too many.
    [int]$HotDocDeletes = 60,
    # Draft a per-package table straight from git for a stage prefix (e.g. 'P12'), so the project
    # timeline's mechanical columns (date / package / PR) stop being copied by hand.
    # Only those columns are derived - the summary column stays human-written on purpose.
    [string]$Timeline = '',
    # Repository root; defaults to the parent folder of this script.
    [string]$RepoRoot = '',
    # Maximum findings printed per check (the rest is summarised).
    [int]$MaxPrinted = 40
)

$ErrorActionPreference = 'Continue'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$docsDir = Join-Path $RepoRoot 'docs'

$strictSet = @{}
foreach ($name in ($Strict -split ',' | ForEach-Object { $_.Trim().ToLower() })) {
    if ($name) { $strictSet[$name] = $true }
}
if ($strictSet['all']) {
    $strictSet['commitmsg'] = $true; $strictSet['docrefs'] = $true; $strictSet['registry'] = $true
    $strictSet['claim'] = $true; $strictSet['provenance'] = $true; $strictSet['hotdocs'] = $true
}

function Write-Finding {
    param([string]$Check, [string]$Where, [string]$Message)
    # GitHub annotation (also readable in a plain console).
    Write-Host "::warning title=governance/$Check::$Where : $Message"
}
function Write-Notice {
    param([string]$Check, [string]$Message)
    Write-Host "::notice title=governance/$Check::$Message"
}
function Invoke-Git {
    param([string[]]$GitArgs)
    $out = & git -C $RepoRoot @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return @($out)
}
function Test-GitRange {
    # A range (a..b, a...b) is NOT a revision: `rev-parse --verify` rejects it. Ask rev-list instead.
    param([string]$RevRange)
    & git -C $RepoRoot rev-list --max-count=1 $RevRange 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Get-RegisteredIds {
    # Package ids mentioned anywhere under docs/. Shared by `registry` (commit side) and `claim`
    # (branch side) so the two can never disagree about what "registered" means.
    $registered = @{}
    if (Test-Path -LiteralPath $docsDir) {
        foreach ($doc in (Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
            $text = Get-Content -LiteralPath $doc.FullName -Raw -Encoding UTF8
            foreach ($m in [regex]::Matches($text, 'P[0-9]+-[0-9]+')) { $registered[$m.Value] = $true }
        }
    }
    return $registered
}

$gitOk = ($null -ne (Invoke-Git @('rev-parse', '--git-dir')))
if (-not $gitOk) { Write-Notice 'git' 'not a git work tree -> commit-message and registry checks skipped' }

$failed = @()
$rangeUsable = $false
$range = $Range
if ($gitOk) {
    if (-not $range) { $range = 'HEAD~1..HEAD' }
    $rangeUsable = (Test-GitRange -RevRange $range)
}

# ---------------------------------------------------------------------------
# 1. commit subjects
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [1/6] commitmsg: package prefix on this change ---'
if (-not $gitOk) {
    Write-Notice 'commitmsg' 'skipped (no git)'
} elseif (-not $rangeUsable) {
    Write-Notice 'commitmsg' "range '$range' could not be resolved (first push / force push) -> skipped, fail-open"
} else {
    $subjects = Invoke-Git @('log', '--no-merges', '--pretty=format:%s', $range)
    if ($null -eq $subjects -or $subjects.Count -eq 0) {
        Write-Notice 'commitmsg' "range '$range' has no non-merge commits -> skipped"
    } else {
        $bad = @($subjects | Where-Object { $_ -notmatch '^\[P[0-9]+-[0-9]+\]' })
        Write-Host "    range: $range"
        Write-Host "    subjects: $($subjects.Count), non-conforming: $($bad.Count)"
        $i = 0
        foreach ($s in $bad) {
            $i++
            if ($i -gt $MaxPrinted) { continue }
            $shown = if ($s.Length -gt 80) { $s.Substring(0, 80) + '...' } else { $s }
            Write-Finding 'commitmsg' $range "'$shown' does not start with [Px-y] (CONTRIBUTING.md section 3)"
        }
        if ($bad.Count -gt $MaxPrinted) { Write-Host "    ... and $($bad.Count - $MaxPrinted) more" }
        if ($bad.Count -gt 0 -and $strictSet['commitmsg']) { $failed += 'commitmsg' }
    }
}

# ---------------------------------------------------------------------------
# 2. documentation references
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [2/6] docrefs: relative references must resolve ---'
$docRoots = @(
    $docsDir,
    (Join-Path $RepoRoot '.codebuddy\rules')
)
$targets = @()
foreach ($d in $docRoots) {
    if (Test-Path -LiteralPath $d) {
        $targets += @(Get-ChildItem -LiteralPath $d -Recurse -File -Include '*.md', '*.mdc' -ErrorAction SilentlyContinue)
    }
}
foreach ($f in @((Join-Path $RepoRoot 'CONTRIBUTING.md'), (Join-Path $RepoRoot 'README.md'))) {
    if (Test-Path -LiteralPath $f) { $targets += Get-Item -LiteralPath $f }
}

if ($targets.Count -eq 0) {
    Write-Notice 'docrefs' 'no governance documents found -> skipped'
} else {
    # A token counts as a document reference only when it is PATH-QUALIFIED (contains '/') and carries
    # a known extension, or when it is the bare docs/NN shorthand.
    # Deliberately NOT checked: bare file names such as `MappingEngine.cs` / `condition.ts`.
    # Those name a file somewhere in the tree, not a location, and they are not what rots
    # (docs/NN and moved paths are).
    $extRe = '\.(md|mdc|json|yml|yaml|ps1|py|cs|ts|tsx|csproj|sln|docx|conf)$'
    $docShorthandRe = '^`?docs/([0-9]+(?:/[0-9]+)*)`?$'
    $inlineCodeRe = '`([^`]+)`'
    $linkRe = '\]\(([^)\s]+)\)'
    $findingCount = 0
    $refCount = 0
    $printed = 0

    # All tracked-ish files, used for suffix resolution: docs legitimately write a reference relative
    # to a project root (`Host/Program.cs`, `Mapping/MappingEngine.cs`), so an exact repo-relative
    # match is too strict. Suffix matching accepts those while still catching moved files.
    $skipDirRe = '[\\/](node_modules|\.git|dist|bin|obj|\.vs|\.codebuddy[\\/]rules)[\\/]'
    $repoFiles = @()
    try {
        $repoFiles = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch $skipDirRe })
    } catch { $repoFiles = @() }
    $repoFiles = @($repoFiles)

    function Test-RefExists {
        param([string]$Ref, [string]$DocDir, [string[]]$Roots, [array]$Index)
        if ($Ref -match '^[a-z]+://' -or $Ref.StartsWith('#') -or $Ref -match '^mailto:') { return $true }
        if ($Ref.StartsWith('/')) { return $true }                          # URL path, not a repo path
        if ($Ref -match '[<>*{}\[\]]' -or $Ref -match '\s') { return $true } # placeholder / prose
        if ($Ref -match '(^|[\\/])NN' -or $Ref -match 'Px-y') { return $true }  # documented naming placeholder
        if ($Ref -match '\.\.\.') { return $true }                             # elided path (tests/.../X.cs)
        $clean = ($Ref -split '#')[0].TrimEnd('/', '.')
        if (-not $clean) { return $true }
        if ($DocDir -and (Test-Path -LiteralPath (Join-Path $DocDir $clean))) { return $true }
        foreach ($root in $Roots) {
            if (Test-Path -LiteralPath (Join-Path $root $clean)) { return $true }
        }
        # No leading separator: projects are named `Product.<Area>`, so `Host/Program.cs` must
        # match `src/Product.Host/Program.cs` (the char before `Host` is a dot, not a separator).
        $norm = ($clean -replace '/', '\')
        foreach ($f in $Index) {
            if ($f.FullName.EndsWith($norm, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    foreach ($doc in $targets) {
        $docDir = Split-Path -Parent $doc.FullName
        $rel = $doc.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $doc.FullName -Encoding UTF8)) {
            $lineNo++
            $candidates = @()
            # Strip inline-code spans BEFORE looking for Markdown links: the governance docs legitimately
            # write ABOUT link syntax (e.g. `](path)` in the rules for this very check), and a target
            # inside backticks is prose, not a reference.
            $linkScope = [regex]::Replace($line, '`[^`]*`', ' ')
            foreach ($m in [regex]::Matches($linkScope, $linkRe)) { $candidates += $m.Groups[1].Value }
            foreach ($m in [regex]::Matches($line, $inlineCodeRe)) {
                $code = $m.Groups[1].Value.Trim()
                if ($code -match $docShorthandRe -or ($code -match '/' -and $code -match $extRe)) {
                    $candidates += $code
                }
            }
            foreach ($raw in $candidates) {
                $ref = $raw.Trim()
                # Bare docs/NN and docs/NN/MM shorthand -> docs/NN-*.md must exist.
                if ($ref -match $docShorthandRe) {
                    foreach ($num in ($Matches[1] -split '/')) {
                        $refCount++
                        $padded = ([int]$num).ToString('00')
                        $hit = @(Get-ChildItem -LiteralPath $docsDir -Filter "$padded-*.md" -File -ErrorAction SilentlyContinue)
                        if ($hit.Count -eq 0) {
                            $findingCount++
                            $printed++
                            if ($printed -le $MaxPrinted) {
                                Write-Finding 'docrefs' "${rel}:$lineNo" "'$ref' -> no docs/$padded-*.md exists"
                            }
                        }
                    }
                    continue
                }
                $refCount++
                if (-not (Test-RefExists -Ref $ref -DocDir $docDir -Roots @($RepoRoot) -Index $repoFiles)) {
                    $findingCount++
                    $printed++
                    if ($printed -le $MaxPrinted) {
                        Write-Finding 'docrefs' "${rel}:$lineNo" "'$ref' does not resolve"
                    }
                }
            }
        }
    }
    Write-Host "    files: $($targets.Count), references: $refCount, unresolved: $findingCount"
    if ($findingCount -gt $MaxPrinted) { Write-Host "    (only the first $MaxPrinted findings are listed; $($findingCount - $MaxPrinted) more)" }
    if ($findingCount -gt 0 -and $strictSet['docrefs']) { $failed += 'docrefs' }
}

# ---------------------------------------------------------------------------
# 3. package registry (ghost packages)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [3/6] registry: ids used by commits must be registered in the docs ---'
if (-not $gitOk) {
    Write-Notice 'registry' 'skipped (no git)'
} elseif (-not $RegistryAll -and -not $rangeUsable) {
    Write-Notice 'registry' "range '$range' could not be resolved (first push / force push) -> skipped, fail-open"
} else {
    # Keep the git revision and its human-readable label apart: passing the label to git silently
    # yields "no commit subjects" and would have disabled the whole check.
    $scopeRev = if ($RegistryAll) { 'HEAD' } else { $range }
    $scopeLabel = if ($RegistryAll) { 'HEAD (full history)' } else { $range }
    $subjects = Invoke-Git @('log', '--no-merges', '--pretty=format:%s', $scopeRev)
    if ($null -eq $subjects -or $subjects.Count -eq 0) {
        Write-Notice 'registry' "no commit subjects in scope '$scopeLabel' -> skipped"
    } else {
        $used = @{}
        foreach ($s in $subjects) {
            foreach ($m in [regex]::Matches($s, '\[(P[0-9]+-[0-9]+)')) { $used[$m.Groups[1].Value] = $true }
        }
        $registered = Get-RegisteredIds
        $ghosts = @($used.Keys | Where-Object { -not $registered.ContainsKey($_) } | Sort-Object)
        Write-Host "    scope: $scopeLabel"
        Write-Host "    ids used by commits: $($used.Count), registered in docs: $($registered.Count), ghost: $($ghosts.Count)"
        $i = 0
        foreach ($g in $ghosts) {
            $i++
            if ($i -gt $MaxPrinted) { continue }
            Write-Finding 'registry' 'git history' "$g has commits but is registered in no docs/*.md (see the range-boundary list)"
        }
        if ($ghosts.Count -gt $MaxPrinted) { Write-Host "    ... and $($ghosts.Count - $MaxPrinted) more" }
        if ($ghosts.Count -gt 0 -and $strictSet['registry']) { $failed += 'registry' }
    }
}

# ---------------------------------------------------------------------------
# 4. claim - the branch name is a claim on a package id
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [4/6] claim: the branch name must carry an already-registered id ---'
if (-not $Branch) {
    Write-Notice 'claim' 'no -Branch given (local run) -> skipped'
} else {
    $claimMatch = [regex]::Match($Branch, 'P[0-9]+-[0-9]+')
    if (-not $claimMatch.Success) {
        Write-Notice 'claim' "branch '$Branch' carries no Px-y id -> skipped (not every branch is a package branch)"
    } else {
        $claimId = $claimMatch.Value
        $registeredForClaim = Get-RegisteredIds
        if ($registeredForClaim.ContainsKey($claimId)) {
            Write-Host "    branch: $Branch -> $claimId is registered"
        } else {
            Write-Finding 'claim' "branch $Branch" "$claimId is claimed by this branch but registered in no docs/*.md - register it BEFORE work starts (tools/claim.ps1, CONTRIBUTING.md section 9)"
            if ($strictSet['claim']) { $failed += 'claim' }
        }
    }
}

# ---------------------------------------------------------------------------
# 5. provenance - an unresolved value must name who will settle it
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [5/6] provenance: unresolved values must have an owner ---'
# The CJK markers are built from code points on purpose: this file stays ASCII-only.
$markMeasured = [string]([char]0x5F85) + [char]0x5B9E + [char]0x6D4B   # "to be measured"
$markDecided = [string]([char]0x5F85) + [char]0x5B9A                   # "to be decided"
$baselineDocs = @()
if (Test-Path -LiteralPath $docsDir) {
    $baselineDocs = @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^0[12]-' })
}
if ($baselineDocs.Count -eq 0) {
    Write-Notice 'provenance' 'no numbered baseline docs (01- / 02-) -> skipped'
} else {
    # An owner is any of: a docs/ reference, a gap id (I#), a decision id (Q#), a package id.
    $ownerRe = '(docs/) |(\bI[0-9]+\b)|(\bQ[0-9]+\b)|(P[0-9]+-[0-9]+)'
    $ownerRe = $ownerRe -replace ' ', ''
    $marked = 0
    $provFindings = 0
    foreach ($doc in $baselineDocs) {
        $rel = $doc.FullName.Substring($RepoRoot.Length).TrimStart('\')
        $heading = ''
        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $doc.FullName -Encoding UTF8)) {
            $lineNo++
            if ($line -match '^#{1,6}\s') { $heading = $line }
            if (-not ($line.Contains($markMeasured) -or $line.Contains($markDecided))) { continue }
            $marked++
            if ($line -notmatch $ownerRe -and $heading -notmatch $ownerRe) {
                $provFindings++
                if ($provFindings -le $MaxPrinted) {
                    Write-Finding 'provenance' "${rel}:$lineNo" 'unresolved value has no owner - name the docs reference / gap id / package that will settle it'
                }
            }
        }
    }
    Write-Host "    baseline docs: $($baselineDocs.Count), unresolved markers: $marked, without owner: $provFindings"
    if ($provFindings -gt 0 -and $strictSet['provenance']) { $failed += 'provenance' }
}

# ---------------------------------------------------------------------------
# 6. hotdocs - a single commit must not gut a governance document
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- [6/6] hotdocs: mass deletion from docs/*.md must be visible ---'
if (-not $gitOk) {
    Write-Notice 'hotdocs' 'skipped (no git)'
} elseif (-not $rangeUsable) {
    Write-Notice 'hotdocs' "range '$range' could not be resolved (first push / force push) -> skipped, fail-open"
} else {
    # --numstat plus a per-commit header: "<add>\t<del>\t<path>" rows follow each "@@<sha> <subject>".
    # core.quotepath=false is required: otherwise git escapes CJK paths as octal + quotes, and
    # both the "docs/" prefix test and the ".md" suffix test below would silently never match.
    $numstat = Invoke-Git @('-c', 'core.quotepath=false', 'log', '--no-merges', '--numstat', '--pretty=format:@@%h %s', $range)
    $hot = 0
    $cur = ''
    if ($numstat) {
        foreach ($line in $numstat) {
            if ($line.StartsWith('@@')) { $cur = $line.Substring(2); continue }
            if ($line -notmatch '^([0-9]*|-)\t([0-9]*|-)\t(.+)$') { continue }
            $del = $Matches[2]
            $path = $Matches[3].Trim('"')
            if ($del -eq '-' -or -not $path.StartsWith('docs/') -or -not $path.EndsWith('.md')) { continue }
            if ([int]$del -gt $HotDocDeletes) {
                $hot++
                Write-Finding 'hotdocs' $cur "deleted $del lines from $path (threshold $HotDocDeletes) - if this is an intentional rewrite, commit the current state first (CONTRIBUTING.md section 9)"
            }
        }
    }
    Write-Host "    scope: $range, threshold: $HotDocDeletes deleted lines per file per commit, hits: $hot"
    if ($hot -gt 0 -and $strictSet['hotdocs']) { $failed += 'hotdocs' }
}

# ---------------------------------------------------------------------------
# Optional: draft the project timeline's mechanical columns from git.
# Root cause is that the same fact (date / package / PR) is retyped into several documents
# and therefore rots; deriving it from git removes the retyping, not just the symptom.
# ---------------------------------------------------------------------------
if ($Timeline -and $gitOk) {
    Write-Host ''
    Write-Host "--- timeline draft for prefix '$Timeline' (the summary column stays manual) ---"
    $prefixRe = [regex]::Escape($Timeline)
    $firstDate = @{}
    $commitCount = @{}
    $subjects = Invoke-Git @('log', '--no-merges', '--pretty=format:%ad|%s', '--date=short')
    if ($subjects) {
        foreach ($line in $subjects) {
            $parts = $line -split '\|', 2
            if ($parts.Count -lt 2) { continue }
            foreach ($m in [regex]::Matches($parts[1], "\[($prefixRe-[0-9]+)")) {
                $id = $m.Groups[1].Value
                # git log is newest-first, so a plain string compare keeps the earliest date.
                if (-not $firstDate.ContainsKey($id) -or $parts[0] -lt $firstDate[$id]) { $firstDate[$id] = $parts[0] }
                if ($commitCount.ContainsKey($id)) { $commitCount[$id]++ } else { $commitCount[$id] = 1 }
            }
        }
    }
    # package -> PR: merge commits read "Merge pull request #122 from owner/P12-9-branch-name".
    $prOf = @{}
    $merges = Invoke-Git @('log', '--merges', '--pretty=format:%s')
    if ($merges) {
        foreach ($s in $merges) {
            $m = [regex]::Match($s, 'Merge pull request #([0-9]+) from [^/]+/(\S+)')
            if (-not $m.Success) { continue }
            $br = [regex]::Match($m.Groups[2].Value, "^($prefixRe-[0-9]+)")
            if ($br.Success) { $prOf[$br.Groups[1].Value] = '#' + $m.Groups[1].Value }
        }
    }
    if ($firstDate.Count -eq 0) {
        Write-Notice 'timeline' "no commit subject carries a [$Timeline-y] prefix"
    } else {
        Write-Host '    | Date | Package | Summary (manual) | PR |'
        Write-Host '    |---|---|---|---|'
        foreach ($id in ($firstDate.Keys | Sort-Object)) {
            $pr = if ($prOf.ContainsKey($id)) { $prOf[$id] } else { '(unrecognized, verify)' }
            Write-Host ("    | {0} | **{1}** |  | {2} |" -f $firstDate[$id], $id, $pr)
        }
        $counts = ($commitCount.Keys | Sort-Object | ForEach-Object { "$_=$($commitCount[$_])" }) -join ', '
        Write-Host "    packages: $($firstDate.Count); commits per package: $counts"
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "GOVERNANCE_FAIL: strict check(s) reported findings: $($failed -join ', ')"
    exit 1
}
Write-Host 'GOVERNANCE_OK (findings above are warnings unless listed under -Strict)'
exit 0

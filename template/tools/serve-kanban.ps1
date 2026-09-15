<#
Serve the kanban over a local HTTP server so the board stays LIVE.

When you edit docs/03-P0执行计划.md or docs/需求跟踪矩阵.md, the already-open page
updates in place (within ~2s) WITHOUT reloading. The page polls /data in the
background; this server re-parses the docs on every request, so there is no cached
copy that can go stale (responses carry `Cache-Control: no-store`, so a browser
reload also picks up a changed template). The DOM is re-rendered in place by the
page's own JS - the document is never re-fetched by a page reload.

Architecture
------------
  GET /            -> kanban.template.html with fresh data injected (initial load)
  GET /data        -> board model as JSON, re-parsed from docs on each call
  GET /kanban.html -> same as /
  GET /docs/<name> -> raw Markdown for the in-page drawer (read-only, single .md leaf, resolved in docs/)
The parsing logic is shared with build-kanban.ps1 via kanban-data.ps1.

Conventions: ASCII-only script (see kanban-data.ps1 header). No external dependencies
(System.Net.HttpListener is built into .NET / PowerShell).

Usage
-----
  powershell -ExecutionPolicy Bypass -File tools/serve-kanban.ps1 [-Port 5180] [-NoOpen]
Stop with Ctrl+C.
#>
param(
    [int]$Port = 5180,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/kanban-data.ps1"
$tmplPath = Join-Path $PSScriptRoot 'kanban.template.html'

if (-not (Test-Path -LiteralPath $tmplPath)) {
    Write-Host "::error::template missing: $tmplPath"
    exit 1
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try {
    $listener.Start()
}
catch {
    Write-Host ("::error::cannot start server on port {0}: {1}" -f $Port, $_.Exception.Message)
    exit 1
}

Write-Host ("KANBAN SERVER: http://localhost:{0}/  (Ctrl+C to stop)" -f $Port)
if (-not $NoOpen) {
    try { Start-Process ("http://localhost:{0}/" -f $Port) } catch { }
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req  = $ctx.Request
        $resp = $ctx.Response
        try {
            # Never let the browser reuse a copy it already has: the whole point of this server is that
            # the board reflects the template and the docs on disk right now. Without this, a page opened
            # before a template change can keep showing the old board and look like the change never ran.
            $resp.Headers['Cache-Control'] = 'no-store'
            $path = $req.Url.LocalPath
            if ($path -eq '/data') {
                $json = Get-KanbanJson -RepoRoot (Split-Path -Parent $PSScriptRoot)
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $resp.ContentType = 'application/json; charset=utf-8'
                $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($path -eq '/' -or $path -eq '/index.html' -or $path -eq '/kanban.html') {
                $json = Get-KanbanJson -RepoRoot (Split-Path -Parent $PSScriptRoot)
                $tmpl = Get-Content -LiteralPath $tmplPath -Raw -Encoding UTF8
                $html = $tmpl.Replace('__DATA__', $json)
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                $resp.ContentType = 'text/html; charset=utf-8'
                $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($path -like '/docs/*') {
                # Read-only raw text for the in-page drawer. The name is validated (a single .md leaf, no
                # separators, no traversal) and resolved INSIDE docs/, so this endpoint cannot become a way
                # to read arbitrary files off the disk. A name that does not resolve is a 404, not an error.
                $raw = $path.Substring(6)
                $cands = @($raw)
                try {
                    $dec = [System.Uri]::UnescapeDataString($raw)
                    if ($dec -ne $raw) { $cands += $dec }
                }
                catch { }
                $docsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs'
                $full = ''
                foreach ($c in $cands) {
                    if ($c -match '^[^\\/:*?"<>|]+\.md$') {
                        $candidate = Join-Path $docsDir $c
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $full = $candidate; break }
                    }
                }
                if ($full) {
                    $txt = Get-Content -LiteralPath $full -Raw -Encoding UTF8
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($txt)
                    $resp.ContentType = 'text/plain; charset=utf-8'
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else {
                    $resp.StatusCode = 404
                }
            }
            else {
                $resp.StatusCode = 404
            }
        }
        catch {
            try { $resp.StatusCode = 500 } catch { }
        }
        finally {
            $resp.Close()
        }
    }
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}

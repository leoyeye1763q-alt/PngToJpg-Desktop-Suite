$ErrorActionPreference = 'Stop'
$hostSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\modules\WebUiHost.cs') -Raw
if ($hostSource -notmatch 'ZoomFactor\s*=\s*1\.00\s*;') { throw 'WebView2 显示比例不是 100%。' }
if ($hostSource -match 'ZoomFactor\s*=\s*1\.08\s*;') { throw 'WebView2 仍保留 108% 显示比例。' }
$changelog = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\CHANGELOG.md') -Raw
if ($changelog -notmatch 'v2\.4\.16[\s\S]*?100%') { throw '更新日志未记录 100% 显示比例。' }
Write-Host 'PASS: WebView2 display ratio is fixed at 100%.'

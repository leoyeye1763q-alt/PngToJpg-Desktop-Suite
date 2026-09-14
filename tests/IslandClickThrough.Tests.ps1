$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\PngToJpg.ps1') -Raw
if ($source -notmatch 'parameters\.ExStyle \|= 0x00000020') { throw '缺少 WS_EX_TRANSPARENT 窗口样式。' }
if ($source -notmatch 'message\.Msg == 0x0084' -or $source -notmatch 'new IntPtr\(-1\)') { throw '缺少 HTTRANSPARENT 命中测试。' }
if ($source -match '\$island\.Add_Click') { throw '灵动岛仍注册了点击处理。' }
if ($source -match '\$island\.Cursor\s*=\s*\[System\.Windows\.Forms\.Cursors\]::Hand') { throw '灵动岛仍显示可点击手型光标。' }
Write-Host 'PASS: dynamic island is mouse-click-through and has no click action.'

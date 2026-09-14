$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\PngToJpg.ps1') -Raw
if ($source -notmatch 'titleFont\s*=\s*new Font\("Microsoft YaHei UI",\s*9\.5f,') { throw '灵动岛标题字体不是固定 9.5pt。' }
if ($source -notmatch 'detailFont\s*=\s*new Font\("Microsoft YaHei UI",\s*8f,') { throw '灵动岛详情字体不是固定 8pt。' }
if ($source -notmatch 'chevronFont\s*=\s*new Font\("Segoe UI",\s*17f,') { throw '灵动岛箭头字体不是固定 17pt。' }
if ($source -match '(titleFont|detailFont|chevronFont)\s*=\s*new Font\([^\r\n]+\* layoutScale') { throw '灵动岛字体仍跟随外框缩放。' }
if ($source -notmatch '\$layoutScale\s*=\s*1\.2') { throw '灵动岛未按 394 x 94 基准放大 20%。' }
if ($source -notmatch '\$islandWidth\s*=\s*\[Math\]::Round\(394 \* \$layoutScale\)') { throw '灵动岛宽度没有按比例计算。' }
if ($source -notmatch '\$islandHeight\s*=\s*\[Math\]::Round\(94 \* \$layoutScale\)') { throw '灵动岛高度没有按比例计算。' }
$width = [Math]::Round(394 * 1.2)
$height = [Math]::Round(94 * 1.2)
if ($width -ne 473 -or $height -ne 113) { throw "灵动岛放大 20% 后尺寸错误：$width x $height。" }
$originalRatio = 394 / 94
$scaledRatio = $width / $height
if ([Math]::Abs($originalRatio - $scaledRatio) -gt 0.03) { throw '缩放后的灵动岛比例偏差过大。' }
Write-Host 'PASS: island remains 473 x 113 while title, detail, and chevron fonts stay fixed.'

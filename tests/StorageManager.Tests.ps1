Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PngToJpg_StorageUnit_' + [Guid]::NewGuid().ToString('N'))
$script:dataDirectory = Join-Path $testRoot 'data'
. (Join-Path $PSScriptRoot '..\modules\StorageManager.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
try {
    foreach($relative in @('preview\a.png','temp\b.tmp','api_cache\c.bin','search_index\d.json','logs\app.log','webview-profile\Cache\e.bin')){$path=Join-Path $script:dataDirectory $relative;[void][IO.Directory]::CreateDirectory((Split-Path $path));[IO.File]::WriteAllText($path,('x'*1024))}
    [IO.File]::WriteAllText((Join-Path $script:dataDirectory 'history.json'),'protected')
    $outsideDirectory=Join-Path $testRoot 'outside-cache';[void][IO.Directory]::CreateDirectory($outsideDirectory);[IO.File]::WriteAllText((Join-Path $outsideDirectory 'must-stay.bin'),'outside')
    [void](New-Item -ItemType Junction -Path (Join-Path $script:dataDirectory 'thumbnail') -Target $outsideDirectory)
    $state=Get-StorageManagerWebState
    Assert-True ($state.Categories.Count -eq 6) '存储分类数量错误。'
    Assert-True ($state.TotalFiles -eq 7) 'APP data 总文件统计错误。'
    Assert-True ($state.ReleasableBytes -eq 3072) '可安全释放空间只能统计绿色类别。'
    Assert-True (($state.Categories|Where-Object Id -eq 'search').Level -eq 'protect') '搜索索引风险等级错误。'
    Assert-True (($state.Categories|Where-Object Id -eq 'preview').FileCount -eq 1) '目录联接不应被扫描。'
    $outside=Join-Path $testRoot 'outside.txt';[IO.File]::WriteAllText($outside,'keep')
    $invalid=Remove-StorageSelectedFiles 'preview' @('..\outside.txt','history.json')
    Assert-True ((Test-Path $outside) -and (Test-Path (Join-Path $script:dataDirectory 'history.json'))) '越界或受保护文件被删除。'
    Assert-True ($invalid.DeletedCount -eq 0 -and $invalid.SkippedCount -eq 2) '非法路径没有被拒绝。'
    $preview=(Get-StorageManagerWebState).Categories|Where-Object Id -eq 'preview'
    $result=Remove-StorageSelectedFiles 'preview' @($preview.Files[0].RelativePath)
    Assert-True ($result.DeletedCount -eq 1 -and $result.ReleasedBytes -eq 1024) '手动删除结果不正确。'
    Assert-True (-not (Test-Path (Join-Path $script:dataDirectory 'preview\a.png'))) '选中缓存未删除。'
    Assert-True (Test-Path (Join-Path $script:dataDirectory 'storage-manager.log')) '删除审计记录未生成。'
    Assert-True (-not (Test-StoragePathInsideData $outside)) 'data 范围边界校验失败。'
    Assert-True (Test-Path (Join-Path $outsideDirectory 'must-stay.bin')) '目录联接目标文件被修改。'
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\modules\StorageManager.ps1'),[ref]$tokens,[ref]$errors);Assert-True ($errors.Count -eq 0) 'StorageManager.ps1 存在语法错误。'
    Write-Host 'StorageManager unit tests passed.'
} finally {
    if (([IO.Path]::GetFullPath($testRoot)).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

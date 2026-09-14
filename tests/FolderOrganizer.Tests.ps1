param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\modules\FolderOrganizer.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "断言失败：$Message" }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('PngToJpg_FolderOrganizer_' + [guid]::NewGuid().ToString('N'))
$projectPath = Join-Path $testRoot 'MX-BZ-01-抱枕套绿'
try {
    $fakeDesktop = Join-Path $testRoot 'Desktop'
    [void][System.IO.Directory]::CreateDirectory($fakeDesktop)
    $dingTalkDownloadPath = Get-DingTalkDownloadDirectory -DesktopPath $fakeDesktop
    Assert-True ($dingTalkDownloadPath -eq (Join-Path $fakeDesktop '钉钉下载')) '默认监控目录应为桌面内的钉钉下载专用目录'
    Assert-True ((Resolve-DingTalkOrganizerPath -SavedPath $fakeDesktop -DesktopPath $fakeDesktop) -eq $dingTalkDownloadPath) '旧版桌面根目录设置应迁移到钉钉专用目录'
    Assert-True ((Resolve-DingTalkOrganizerPath -SavedPath $dingTalkDownloadPath -DesktopPath $fakeDesktop) -eq $dingTalkDownloadPath) '已配置的钉钉专用目录应保持不变'
    Assert-True (Test-IsDesktopRootPath -Path $fakeDesktop -DesktopPath $fakeDesktop) '应识别并拒绝桌面根目录'
    Assert-True (-not (Test-IsDesktopRootPath -Path $dingTalkDownloadPath -DesktopPath $fakeDesktop)) '钉钉专用目录不应被误判为桌面根目录'

    [void][System.IO.Directory]::CreateDirectory($dingTalkDownloadPath)
    $autoProjectPath = Join-Path $dingTalkDownloadPath 'MX-BZ-00-自动下载'
    [void][System.IO.Directory]::CreateDirectory($autoProjectPath)
    [System.IO.File]::WriteAllText((Join-Path $autoProjectPath '需求.xlsx'), 'sheet')
    $autoResult = Invoke-ProjectFolderOrganization -Path $autoProjectPath
    Assert-True $autoResult.Success '专用目录中的自动下载项目应完成整理'
    $desktopProjectPath = Move-OrganizedProjectFolder -Path $autoProjectPath -DestinationDirectory $fakeDesktop
    Assert-True ($desktopProjectPath -eq (Join-Path $fakeDesktop 'MX-BZ-00-自动下载')) '自动整理完成后应移到桌面根目录'
    Assert-True (Test-Path -LiteralPath (Join-Path $desktopProjectPath 'MX-BZ-00-自动下载 源文件\需求.xlsx') -PathType Leaf) '移到桌面后应保留完整整理结果'
    Assert-True (-not (Test-Path -LiteralPath $autoProjectPath)) '专用下载目录中不应残留已完成的项目'

    [void][System.IO.Directory]::CreateDirectory($projectPath)
    [System.IO.File]::WriteAllText((Join-Path $projectPath '主图1.png'), 'image')
    [void][System.IO.Directory]::CreateDirectory((Join-Path $projectPath '设计稿'))
    [System.IO.File]::WriteAllText((Join-Path $projectPath '设计稿\说明.txt'), 'note')
    [System.IO.File]::WriteAllText((Join-Path $projectPath '设计稿\需求明细.xlsx'), 'sheet')
    [System.IO.File]::WriteAllText((Join-Path $projectPath '设计稿\备用清单.csv'), 'csv')

    $result = Invoke-ProjectFolderOrganization -Path $projectPath
    Assert-True $result.Success '首次整理应成功'
    Assert-True ($result.MovedCount -eq 2) '应移动两个第一层项目'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectPath 'MX-BZ-01-抱枕套绿') -PathType Container) '应创建同名文件夹'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectPath 'MX-BZ-01-抱枕套绿 源文件\主图1.png') -PathType Leaf) '文件应移入源文件文件夹'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectPath 'MX-BZ-01-抱枕套绿 源文件\设计稿\说明.txt') -PathType Leaf) '子文件夹应整体移入源文件文件夹'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectPath '素材') -PathType Container) '应创建素材文件夹'
    $spreadsheetPath = Get-ProjectSpreadsheetPath -SourceFolderPath (Join-Path $projectPath 'MX-BZ-01-抱枕套绿 源文件')
    Assert-True ($spreadsheetPath -eq (Join-Path $projectPath 'MX-BZ-01-抱枕套绿 源文件\设计稿\需求明细.xlsx')) '整理后应优先找到 XLSX 表格供 APP 自动打开'
    Assert-True ((Get-ProjectSpreadsheetPathForFolder -Path $projectPath) -eq $spreadsheetPath) '备用批量打开页应能从项目根目录找到表格'
    Assert-True ((Get-ProjectSpreadsheetPathForFolder -Path (Join-Path $projectPath 'MX-BZ-01-抱枕套绿 源文件')) -eq $spreadsheetPath) '备用批量打开页应支持直接拖入源文件文件夹'

    $secondResult = Invoke-ProjectFolderOrganization -Path $projectPath
    Assert-True $secondResult.Success '重复整理应成功'
    Assert-True ($secondResult.MovedCount -eq 0) '重复整理不应移动三个受管理文件夹'

    [System.IO.File]::WriteAllText((Join-Path $projectPath '主图1.png'), 'new image')
    $collisionResult = Invoke-ProjectFolderOrganization -Path $projectPath
    Assert-True $collisionResult.Success '有同名文件时应成功'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectPath 'MX-BZ-01-抱枕套绿 源文件\主图1（2）.png') -PathType Leaf) '同名文件不应被覆盖'

    $snapshot = Get-FolderContentSnapshot -Path $projectPath
    Assert-True $snapshot.HasContent '快照应识别文件夹内容'

    $batchRoot = Join-Path $testRoot '批量项目'
    [void][System.IO.Directory]::CreateDirectory($batchRoot)
    $batchProjects = @('MX-BZ-02-抱枕套蓝', 'MX-BZ-03-抱枕套灰', 'MX-BZ-04-抱枕套米白')
    foreach ($projectName in $batchProjects) {
        $batchProjectPath = Join-Path $batchRoot $projectName
        [void][System.IO.Directory]::CreateDirectory($batchProjectPath)
        [System.IO.File]::WriteAllText((Join-Path $batchProjectPath '主图.png'), $projectName)
    }
    $batchResults = @($batchProjects | ForEach-Object { Invoke-ProjectFolderOrganization -Path (Join-Path $batchRoot $_) })
    Assert-True ($batchResults.Count -eq 3) '批量整理应处理全部三个文件夹'
    Assert-True (@($batchResults | Where-Object { -not $_.Success }).Count -eq 0) '批量整理不应有失败项'
    foreach ($projectName in $batchProjects) {
        Assert-True (Test-Path -LiteralPath (Join-Path $batchRoot "$projectName\$projectName 源文件\主图.png") -PathType Leaf) "批量项目 $projectName 应完成整理"
    }

    $manualDesktop = Join-Path $testRoot 'ManualDesktop'
    $manualProject = Join-Path $manualDesktop '123'
    foreach ($directory in @($manualDesktop, $manualProject, (Join-Path $manualProject '123'), (Join-Path $manualProject '123 源文件'), (Join-Path $manualProject '素材'))) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    [IO.File]::WriteAllText((Join-Path $manualProject '123 源文件\保留.txt'), 'do not touch')
    foreach ($name in @('123.psd','主图1.jpg','副图5.png','A1.webp','ChatGPT Image 2026.png','右侧图片.png')) {
        [IO.File]::WriteAllText((Join-Path $manualDesktop $name), $name)
    }
    $positions = @(
        [PSCustomObject]@{Name='123';X=100;Y=100},
        [PSCustomObject]@{Name='主图1';X=120;Y=220},
        [PSCustomObject]@{Name='副图5';X=150;Y=340},
        [PSCustomObject]@{Name='A1';X=180;Y=460},
        [PSCustomObject]@{Name='ChatGPT Image 2026';X=210;Y=580},
        [PSCustomObject]@{Name='右侧图片';X=1750;Y=220}
    )
    $bounds = [PSCustomObject]@{Left=0;Top=0;Width=1920;Height=1080}
    Assert-True (Test-DesktopPositionInScope -X 100 -Y 100 -Scope left -ScreenBounds $bounds) '左侧图标应属于左侧范围'
    Assert-True (Test-DesktopPositionInScope -X 900 -Y 100 -Scope center -ScreenBounds $bounds) '中间图标应属于中间范围'
    Assert-True (Test-DesktopPositionInScope -X 1750 -Y 100 -Scope right -ScreenBounds $bounds) '右侧图标应属于右侧范围'
    Assert-True (-not (Test-DesktopPositionInScope -X 1750 -Y 100 -Scope left -ScreenBounds $bounds)) '右侧图标不得被左侧范围选中'
    $historyPath = Join-Path $testRoot 'desktop-history'
    $manualResult = Invoke-DesktopProductOrganization -DesktopPath $manualDesktop -HistoryPath $historyPath -Scope left -IconPositions $positions -ScreenBounds $bounds
    Assert-True $manualResult.Success '桌面成品整理应成功'
    Assert-True ($manualResult.MovedCount -eq 5) '左侧范围应移动 PSD 与四张左侧图片'
    Assert-True (Test-Path -LiteralPath (Join-Path $manualProject '123.psd') -PathType Leaf) 'PSD 应放在编号母文件夹第一层'
    foreach ($name in @('主图1.jpg','副图5.png','A1.webp')) { Assert-True (Test-Path -LiteralPath (Join-Path $manualProject "123\$name") -PathType Leaf) "$name 应放入同名成品文件夹" }
    Assert-True (Test-Path -LiteralPath (Join-Path $manualProject '素材\ChatGPT Image 2026.png') -PathType Leaf) '未命名图片应放入素材文件夹'
    Assert-True (Test-Path -LiteralPath (Join-Path $manualProject '123 源文件\保留.txt') -PathType Leaf) '源文件文件夹必须保持不动'
    Assert-True (Test-Path -LiteralPath (Join-Path $manualDesktop '右侧图片.png') -PathType Leaf) '左侧范围不得移动右侧图片'
    $history = @(Get-DesktopOrganizationHistory -HistoryPath $historyPath)
    Assert-True ($history.Count -eq 1 -and $history[0].Id -eq $manualResult.RecordId) '整理完成后应保存独立恢复记录'

    $secondProject = Join-Path $manualDesktop '456'
    foreach ($directory in @($secondProject, (Join-Path $secondProject '456'), (Join-Path $secondProject '素材'))) { [void][IO.Directory]::CreateDirectory($directory) }
    foreach ($name in @('456.psd','主图2.jpg')) { [IO.File]::WriteAllText((Join-Path $manualDesktop $name), $name) }
    $secondPositions = @([PSCustomObject]@{Name='456';X=100;Y=100},[PSCustomObject]@{Name='主图2';X=130;Y=220})
    $secondResult = Invoke-DesktopProductOrganization -DesktopPath $manualDesktop -HistoryPath $historyPath -Scope left -IconPositions $secondPositions -ScreenBounds $bounds
    Assert-True $secondResult.Success '存在旧记录时应允许继续整理'
    $history = @(Get-DesktopOrganizationHistory -HistoryPath $historyPath)
    Assert-True ($history.Count -eq 2) '两次整理应显示两条独立恢复记录'
    Assert-True ($manualResult.RecordId -ne $secondResult.RecordId) '每次整理记录编号应唯一'

    $undoResult = Undo-DesktopProductOrganization -HistoryPath $historyPath -RecordId $manualResult.RecordId
    Assert-True $undoResult.Success '应能点击指定记录恢复第一次整理'
    Assert-True ($undoResult.UndoneCount -eq 5) '指定记录应放回第一次移动的全部文件'
    foreach ($name in @('123.psd','主图1.jpg','副图5.png','A1.webp','ChatGPT Image 2026.png','右侧图片.png')) { Assert-True (Test-Path -LiteralPath (Join-Path $manualDesktop $name) -PathType Leaf) "恢复后 $name 应位于桌面" }
    $history = @(Get-DesktopOrganizationHistory -HistoryPath $historyPath)
    Assert-True ($history.Count -eq 1 -and $history[0].Id -eq $secondResult.RecordId) '恢复第一次后应只移除对应记录'
    $secondUndo = Undo-DesktopProductOrganization -HistoryPath $historyPath -RecordId $secondResult.RecordId
    Assert-True ($secondUndo.Success -and $secondUndo.UndoneCount -eq 2) '第二次整理记录应可独立恢复'
    Assert-True (@(Get-DesktopOrganizationHistory -HistoryPath $historyPath).Count -eq 0) '全部恢复后历史应为空'

    $expiredId = New-DesktopOrganizationRecordId
    $expiredManifest = [PSCustomObject]@{Version=2;RecordId=$expiredId;CreatedAt=[DateTimeOffset]::Now.AddDays(-31).ToString('o');DesktopPath=$manualDesktop;Code='expired';ProjectFolder=$manualProject;CreatedDirectories=@();Moves=@()}
    $expiredPath = Join-Path $historyPath ($expiredId + '.json')
    Save-DesktopOrganizationManifest -Path $expiredPath -Manifest $expiredManifest
    [void](Get-DesktopOrganizationHistory -HistoryPath $historyPath -RetentionDays 30)
    Assert-True (-not (Test-Path -LiteralPath $expiredPath)) '超过 30 天的恢复记录应自动清理'

    $legacyPath = Join-Path $testRoot 'desktop-product-organizer-undo.json'
    $migrationHistory = Join-Path $testRoot 'migration-history'
    $legacyManifest = [PSCustomObject]@{Version=1;CreatedAt=[DateTimeOffset]::Now.ToString('o');DesktopPath=$manualDesktop;Code='legacy';ProjectFolder=$manualProject;CreatedDirectories=@();Moves=@()}
    Save-DesktopOrganizationManifest -Path $legacyPath -Manifest $legacyManifest
    Initialize-DesktopOrganizationHistory -HistoryPath $migrationHistory -LegacyUndoPath $legacyPath
    Assert-True (-not (Test-Path -LiteralPath $legacyPath)) '旧版单条撤回记录应完成迁移'
    Assert-True (@(Get-DesktopOrganizationHistory -HistoryPath $migrationHistory).Count -eq 1) '迁移后的旧记录应在 30 天列表中可见'
    Write-Host 'FolderOrganizer tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

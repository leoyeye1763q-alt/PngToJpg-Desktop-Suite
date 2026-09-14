param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "断言失败：$Message" }
}

function Invoke-NativeChecked {
    param([string]$FileName, [string[]]$Arguments)
    & $FileName @Arguments
    if ($LASTEXITCODE -ne 0) { throw "命令失败（$LASTEXITCODE）：$FileName $($Arguments -join ' ')" }
}

$appRoot = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $appRoot 'PngToJpg.ps1'
$previewWorker = Join-Path $appRoot 'modules\PreviewWorker.ps1'
$organizerWorker = Join-Path $appRoot 'modules\FolderOrganizerWorker.ps1'
$organizerModule = Join-Path $appRoot 'modules\FolderOrganizer.ps1'
$magickPath = Join-Path $appRoot 'tools\imagemagick\magick.exe'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('PngToJpg_Performance_' + [Guid]::NewGuid().ToString('N'))

try {
    [void][System.IO.Directory]::CreateDirectory($testRoot)
    $largePng = Join-Path $testRoot 'large-8000x5000.png'
    $jpegPath = Join-Path $testRoot 'photo-1600x1200.jpg'
    $webpPath = Join-Path $testRoot 'sample-1280x720.webp'
    Invoke-NativeChecked $magickPath @('-size', '8000x5000', 'xc:#32689A', $largePng)
    Invoke-NativeChecked $magickPath @('-size', '1600x1200', 'gradient:#13253A-#DDEEFF', '-quality', '92', $jpegPath)
    Invoke-NativeChecked $magickPath @('-size', '1280x720', 'xc:#52A875', $webpPath)

    Write-Host 'Testing lightweight image headers...'
    $headerTimer = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($imagePath in @($largePng, $jpegPath, $webpPath)) {
        Invoke-NativeChecked 'pwsh' @('-NoLogo', '-NoProfile', '-File', $mainScript, '-InputFiles', $imagePath, '-SmokeTest')
    }
    $headerTimer.Stop()

    $previewDirectory = Join-Path $testRoot 'preview-job'
    [void][System.IO.Directory]::CreateDirectory($previewDirectory)
    $previewJobPath = Join-Path $previewDirectory 'job.json'
    $previewResultPath = Join-Path $previewDirectory 'result.json'
    $previewOutputPath = Join-Path $previewDirectory 'preview.png'
    $previewJob = [PSCustomObject]@{
        SourcePath = $largePng
        ResultSourcePath = ''
        MagickPath = $magickPath
        MaxWidth = 1000
        MaxHeight = 1000
        OriginalPreviewPath = $previewOutputPath
        ResultPreviewPath = (Join-Path $previewDirectory 'result-preview.png')
        ResponsePath = $previewResultPath
    }
    Write-Host 'Testing background preview...'
    [System.IO.File]::WriteAllText($previewJobPath, ($previewJob | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    $previewTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-NativeChecked 'pwsh' @('-NoLogo', '-NoProfile', '-File', $previewWorker, '-JobPath', $previewJobPath)
    $previewTimer.Stop()
    $previewResult = Get-Content -LiteralPath $previewResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([bool]$previewResult.Success) '后台缩略预览应成功'
    Assert-True ((Test-Path -LiteralPath $previewOutputPath -PathType Leaf)) '应生成缩略图文件'
    $previewDimensions = (& $magickPath identify -ping -format '%w|%h' $previewOutputPath).Trim().Split('|')
    Assert-True ([int]$previewDimensions[0] -le 1000 -and [int]$previewDimensions[1] -le 1000) '预览不应解码回超大画布'

    Write-Host 'Testing direct in-app preview...'
    $directPreviewOutput = (& 'pwsh' -NoLogo -NoProfile -File $mainScript -InputFiles $largePng -SmokeTest -SmokeTestPreview 6>&1 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "APP 直接预览测试失败：$directPreviewOutput" }
    Assert-True ($directPreviewOutput -match 'Preview visible:\s+([\d,]+) ms') 'APP 应报告首张预览可见时间'
    $directPreviewMilliseconds = [double]($Matches[1].Replace(',', ''))
    Assert-True ($directPreviewMilliseconds -lt 3000) '8000 × 5000 图片的首张预览应在 3 秒内显示'

    $projectPath = Join-Path $testRoot 'MX-BZ-01-抱枕套绿'
    [void][System.IO.Directory]::CreateDirectory($projectPath)
    [System.IO.File]::WriteAllText((Join-Path $projectPath '需求明细.xlsx'), 'test')
    $organizerJobPath = Join-Path $testRoot 'organizer-job.json'
    $organizerResultPath = Join-Path $testRoot 'organizer-result.json'
    $organizerJob = [PSCustomObject]@{ FolderPath = $projectPath; ModulePath = $organizerModule; ResultPath = $organizerResultPath }
    [System.IO.File]::WriteAllText($organizerJobPath, ($organizerJob | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    Write-Host 'Testing background folder organizer...'
    Invoke-NativeChecked 'pwsh' @('-NoLogo', '-NoProfile', '-File', $organizerWorker, '-JobPath', $organizerJobPath)
    $organizerResult = Get-Content -LiteralPath $organizerResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([bool]$organizerResult.Success) '后台文件夹整理应成功'
    $expectedSpreadsheet = Join-Path $projectPath 'MX-BZ-01-抱枕套绿 源文件\需求明细.xlsx'
    Assert-True ((Test-Path -LiteralPath $expectedSpreadsheet -PathType Leaf)) '后台整理应移动原内容'
    Assert-True ([string]$organizerResult.SpreadsheetPath -eq $expectedSpreadsheet) '后台整理结果应返回可自动打开的表格路径'

    Write-Host 'Testing direct normal conversion...'
    $conversionTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-NativeChecked 'pwsh' @('-NoLogo', '-NoProfile', '-File', $mainScript, '-InputFiles', $jpegPath, '-SmokeTestConversion')
    $conversionTimer.Stop()
    $convertedPath = Join-Path $testRoot 'photo-1600x1200_JPG.jpg'
    Assert-True ((Test-Path -LiteralPath $convertedPath -PathType Leaf)) '快速普通转换应生成 JPG'
    $convertedInfo = (& $magickPath identify -ping -format '%m|%w|%h|%Q' $convertedPath).Trim().Split('|')
    Assert-True ($convertedInfo[0] -eq 'JPEG' -and [int]$convertedInfo[1] -eq 1600 -and [int]$convertedInfo[2] -eq 1200 -and [int]$convertedInfo[3] -eq 100) '快速转换应保持尺寸并使用 JPEG 质量 100'

    Write-Host ('Performance tests passed. Header smoke total: {0:N0} ms; preview worker: {1:N0} ms; direct in-app preview: {2:N0} ms; app cold-start + conversion: {3:N0} ms.' -f $headerTimer.Elapsed.TotalMilliseconds, $previewTimer.Elapsed.TotalMilliseconds, $directPreviewMilliseconds, $conversionTimer.Elapsed.TotalMilliseconds)
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

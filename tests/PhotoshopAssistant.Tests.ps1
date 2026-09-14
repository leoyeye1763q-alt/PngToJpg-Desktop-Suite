Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PngToJpg_PhotoshopUnit_' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:dataDirectory = Join-Path $testRoot 'data'
. (Join-Path $PSScriptRoot '..\modules\PhotoshopAssistant.ps1')
Initialize-PhotoshopAssistant

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\modules\PhotoshopAssistant.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ('PhotoshopAssistant.ps1 语法错误：' + (($errors | ForEach-Object Message) -join '；')) }

    Assert-True ((Get-PhotoshopVersionLabel '21.2.0') -like 'Photoshop 2020*') 'Photoshop 2020 版本映射失败。'
    Assert-True ((Get-PhotoshopVersionLabel '26.5.0') -like 'Photoshop 2025*') 'Photoshop 2025 版本映射失败。'
    Assert-True ((Get-PhotoshopVersionLabel '27.2.0') -like 'Photoshop 2026*') '更高 Photoshop 版本兼容映射失败。'

    $detectScript = New-PhotoshopDetectJsx (Join-Path $testRoot 'detect.json')
    $exportScript = New-PhotoshopExportJsx -ResultPath (Join-Path $testRoot 'export.json') -OutputPath $testRoot -Formats @('JPG', 'PNG', 'PSD') -JpgQuality 10 -PreserveTransparency $false
    $combined = $detectScript + $exportScript
    foreach ($forbidden in @('Invoke-WebRequest', 'Invoke-RestMethod', 'XMLHttpRequest', 'fetch(', 'http://', 'https://')) {
        Assert-True (-not $combined.Contains($forbidden)) "离线 JSX 中出现禁止的网络调用：$forbidden"
    }
    foreach ($required in @('JPEGSaveOptions', 'PNGSaveOptions', 'PhotoshopSaveOptions', "'_export'", "slice(-3)", 'DONOTSAVECHANGES', '白色背景')) {
        Assert-True $exportScript.Contains($required) "导出脚本缺少安全行为：$required"
    }

    Set-PhotoshopAssistantOptions @{ formats = @('jpg', 'png', 'bad'); jpgQuality = 99; preserveTransparency = $false; outputMode = 'custom'; outputPath = $testRoot }
    Assert-True (($script:photoshopAssistant.Formats -join ',') -eq 'JPG,PNG') '导出格式过滤失败。'
    Assert-True ($script:photoshopAssistant.JpgQuality -eq 12) 'JPG 质量范围限制失败。'
    Assert-True (-not $script:photoshopAssistant.PreserveTransparency) 'PNG 白底选项绑定失败。'

    $script:photoshopAssistantOperation = @{ Kind = 'detect' }
    Complete-PhotoshopAssistantOperation @{ ok = $true; version = '26.5.0'; name = 'ABC123.psd'; path = 'D:\Work\ABC123.psd'; width = 1650; height = 1650; saved = $true; message = '已读取当前 Photoshop 文件' }
    Assert-True ($script:photoshopAssistant.PsdPath -eq 'D:\Work\ABC123.psd' -and $script:photoshopAssistant.Saved) '检测结果状态转换失败。'

    $script:photoshopAssistantOperation = @{ Kind = 'export' }
    Complete-PhotoshopAssistantOperation @{ ok = $true; path = 'D:\Work\ABC123.psd'; outputs = "D:\Work\ABC123.jpg`nD:\Work\ABC123.png"; formats = 'JPG,PNG'; message = '导出完成，共 2 个文件' }
    Assert-True ($script:photoshopAssistant.OutputFiles.Count -eq 2) '多格式导出结果解析失败。'
    Assert-True (Test-Path -LiteralPath $script:photoshopAssistantLogPath -PathType Leaf) 'Photoshop 本地日志未写入。'
    $log = Get-Content -LiteralPath $script:photoshopAssistantLogPath -Raw
    Assert-True ($log.Contains('ABC123.psd') -and $log.Contains('JPG,PNG')) 'Photoshop 本地日志字段不完整。'

    Write-Host 'PhotoshopAssistant unit tests passed.'
} finally {
    if (([IO.Path]::GetFullPath($testRoot)).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

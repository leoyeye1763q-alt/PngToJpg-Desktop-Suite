Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$photoshop = Get-CimInstance Win32_Process -Filter "Name='Photoshop.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $photoshop) { Write-Host 'SKIP: Photoshop is not running.'; return }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PngToJpg_PhotoshopIntegration_' + [Guid]::NewGuid().ToString('N'))
$outputRoot = Join-Path $testRoot 'output'
[void][IO.Directory]::CreateDirectory($outputRoot)
$script:dataDirectory = Join-Path $testRoot 'data'
. (Join-Path $PSScriptRoot '..\modules\PhotoshopAssistant.ps1')
Initialize-PhotoshopAssistant

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$psdPath = Join-Path $testRoot 'OfflineFixture.psd'
$detectResult = Join-Path $testRoot 'fixture-detect.json'
$writer = New-PhotoshopResultWriterJsx $detectResult
$psdLiteral = ConvertTo-PhotoshopJsxLiteral $psdPath
$fixtureScript = @"
#target photoshop
app.bringToFront();
$writer
var document = app.documents.add(32, 24, 72, 'OfflineFixture', NewDocumentMode.RGB, DocumentFill.TRANSPARENT);
document.saveAs(new File($psdLiteral), new PhotoshopSaveOptions(), false, Extension.LOWERCASE);
pngToJpgWriteResult('{"ok":true,"version":' + pngToJpgQuote(app.version) + ',"name":' + pngToJpgQuote(document.name) + ',"path":' + pngToJpgQuote(document.fullName.fsName) + ',"width":32,"height":24,"saved":true,"message":"已创建离线测试 PSD"}');
"@

try {
    Start-PhotoshopAssistantOperation -Kind detect -ScriptText $fixtureScript -ResultPath $detectResult
    $state = Wait-PhotoshopAssistantOperation
    Assert-True ($state.Saved -and $state.Width -eq 32 -and $state.Height -eq 24) '未能通过 JSX 读取活动 PSD 状态。'
    Assert-True (Test-Path -LiteralPath $psdPath -PathType Leaf) '离线测试 PSD 未保存。'
    $sourceHash = (Get-FileHash -LiteralPath $psdPath -Algorithm SHA256).Hash

    Start-PhotoshopExport @{ formats = @('JPG', 'PNG', 'PSD'); jpgQuality = 10; preserveTransparency = $true; outputMode = 'custom'; outputPath = $outputRoot }
    $state = Wait-PhotoshopAssistantOperation
    Assert-True (-not $state.LastError) ('多格式导出失败：' + $state.LastError)
    Assert-True ($state.OutputFiles.Count -eq 3) '未生成 JPG、PNG、PSD 三种输出。'
    foreach ($path in $state.OutputFiles) { Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "导出文件不存在：$path" }
    Assert-True ((Get-FileHash -LiteralPath $psdPath -Algorithm SHA256).Hash -eq $sourceHash) '导出过程修改了原 PSD。'
    Assert-True (@($state.OutputFiles | Where-Object { $_ -like '*_export.psd' }).Count -eq 1) 'PSD 副本命名不符合 _export.psd 规则。'

    Start-PhotoshopExport @{ formats = @('PSD'); jpgQuality = 10; preserveTransparency = $true; outputMode = 'custom'; outputPath = $outputRoot }
    $state = Wait-PhotoshopAssistantOperation
    Assert-True (@($state.OutputFiles | Where-Object { $_ -like '*_export_001.psd' }).Count -eq 1) 'PSD 重名时未生成 _export_001.psd。'

    Start-PhotoshopExport @{ formats = @('PNG'); jpgQuality = 10; preserveTransparency = $false; outputMode = 'custom'; outputPath = $outputRoot }
    $state = Wait-PhotoshopAssistantOperation
    $whitePng = @($state.OutputFiles | Where-Object { $_ -like '*.png' })[0]
    $magick = Join-Path $PSScriptRoot '..\tools\imagemagick\magick.exe'
    if (Test-Path -LiteralPath $magick) {
        $minimumAlpha = (& $magick $whitePng -format '%[fx:minima.a]' info:).Trim()
        Assert-True ([double]::Parse($minimumAlpha, [Globalization.CultureInfo]::InvariantCulture) -ge 0.999) '关闭透明背景后 PNG 仍包含透明像素。'
    }
    Assert-True (Test-Path -LiteralPath $script:photoshopAssistantLogPath -PathType Leaf) '真实导出未写入本地日志。'
    Write-Host 'PhotoshopAssistant integration tests passed.'
} finally {
    try {
        if (-not $script:photoshopAssistant.Busy) {
            $cleanupResult = Join-Path $testRoot 'cleanup.json'
            $cleanupWriter = New-PhotoshopResultWriterJsx $cleanupResult
            $cleanupScript = @"
#target photoshop
$cleanupWriter
try { if (app.documents.length && app.activeDocument.name.indexOf('OfflineFixture') === 0) { app.activeDocument.close(SaveOptions.DONOTSAVECHANGES); } } catch (error) { }
pngToJpgWriteResult('{"ok":false,"code":"NO_DOCUMENT","version":' + pngToJpgQuote(app.version) + ',"message":"测试文件已关闭"}');
"@
            Start-PhotoshopAssistantOperation -Kind detect -ScriptText $cleanupScript -ResultPath $cleanupResult
            [void](Wait-PhotoshopAssistantOperation)
        }
    } catch { Write-Warning ('关闭 Photoshop 测试文件失败：' + $_.Exception.Message) }
    if (([IO.Path]::GetFullPath($testRoot)).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

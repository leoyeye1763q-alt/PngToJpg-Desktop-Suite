$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$main = Get-Content -LiteralPath (Join-Path $root 'PngToJpg.ps1') -Raw -Encoding UTF8
$bridge = Get-Content -LiteralPath (Join-Path $root 'modules\WebUi.ps1') -Raw -Encoding UTF8
$html = Get-Content -LiteralPath (Join-Path $root 'web\conversion.html') -Raw -Encoding UTF8
$worker = Get-Content -LiteralPath (Join-Path $root 'modules\DocumentWorker.ps1') -Raw -Encoding UTF8

foreach ($extension in @('pdf', 'doc', 'docx', 'ppt', 'pptx')) {
    if ($main -notmatch [regex]::Escape($extension)) { throw "主程序缺少输入格式：$extension" }
}
foreach ($format in @('value="pdf"', 'value="docx"', 'value="pptx"')) {
    if (-not $html.Contains($format)) { throw "界面缺少输出格式：$format" }
}
foreach ($mapping in @("'pdf'{4}", "'docx'{5}", "'pptx'{6}")) {
    if (-not $bridge.Contains($mapping)) { throw "Web 桥接缺少格式映射：$mapping" }
}
foreach ($required in @('modules\DocumentWorker.ps1', 'tools\poppler\bin\pdftoppm.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { throw "缺少离线转换组件：$required" }
}
foreach ($phase in @('正在渲染 PDF 页面', '正在创建第 {0} / {1} 张幻灯片', '正在保存 PowerPoint')) {
    if (-not $worker.Contains($phase)) { throw "文档转换缺少可见进度阶段：$phase" }
}
Write-Host 'PASS: document inputs, output options, Web bridge mappings, progress phases and offline components are present.'

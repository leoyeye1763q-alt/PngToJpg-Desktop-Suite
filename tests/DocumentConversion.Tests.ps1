$ErrorActionPreference = 'Stop'
$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$worker = Join-Path $appRoot 'modules\DocumentWorker.ps1'
$magick = Join-Path $appRoot 'tools\imagemagick\magick.exe'
$pdftoppm = Join-Path $appRoot 'tools\poppler\bin\pdftoppm.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PngToJpg_DocumentTests_' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

function Invoke-DocumentWorkerTest([string]$Source, [string]$Format, [string]$Destination) {
    $jobRoot = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($jobRoot)
    $jobPath = Join-Path $jobRoot 'job.json'
    $resultPath = Join-Path $jobRoot 'result.json'
    $job = [ordered]@{
        SourcePath = $Source; OutputPath = $Destination; OutputFormat = $Format
        FinalWidth = 0; FinalHeight = 0; Background = '#FFFFFF'
        MagickPath = $magick; PdfToPpmPath = $pdftoppm; TempDirectory = $jobRoot
        ProgressPath = (Join-Path $jobRoot 'progress.json'); ResultPath = $resultPath
    }
    [IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    & ([Environment]::ProcessPath) -NoLogo -NoProfile -File $worker -JobPath $jobPath
    if (-not (Test-Path -LiteralPath $resultPath)) { throw "后台未返回结果：$Format" }
    $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $result.Success) { throw "$Format 转换失败：$($result.Error)" }
    foreach ($output in @($result.OutputPaths)) {
        if (-not (Test-Path -LiteralPath $output -PathType Leaf) -or (Get-Item -LiteralPath $output).Length -le 0) { throw "无效输出：$output" }
    }
    return $result
}

try {
    foreach ($required in @($worker, $magick, $pdftoppm)) { if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少组件：$required" } }
    $image = Join-Path $testRoot '测试图片.png'
    & $magick -size 640x360 'gradient:#ff5e36-#ffffff' -gravity center -pointsize 32 -fill '#222222' -annotate +0+0 'Offline document test' $image
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $image)) { throw '无法创建测试图片。' }

    $pdf = Join-Path $testRoot '图片转PDF.pdf'
    $docx = Join-Path $testRoot '图片转Word.docx'
    $pptx = Join-Path $testRoot '图片转PPT.pptx'
    Invoke-DocumentWorkerTest $image pdf $pdf | Out-Null
    Invoke-DocumentWorkerTest $image docx $docx | Out-Null
    Invoke-DocumentWorkerTest $image pptx $pptx | Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($package in @($docx, $pptx)) {
        $zip = [IO.Compression.ZipFile]::OpenRead($package)
        try { if (-not ($zip.Entries | Where-Object FullName -eq '[Content_Types].xml')) { throw "Office 包结构无效：$package" } }
        finally { $zip.Dispose() }
    }

    $jpg = Join-Path $testRoot 'PDF转图片.jpg'
    $result = Invoke-DocumentWorkerTest $pdf jpg $jpg
    if ([int]$result.PageCount -lt 1) { throw 'PDF 页面输出数量无效。' }

    $pdfToPptx = Join-Path $testRoot 'PDF转PPT.pptx'
    Invoke-DocumentWorkerTest $pdf pptx $pdfToPptx | Out-Null

    $wordToPdf = Join-Path $testRoot 'Word转PDF.pdf'
    $wordToJpg = Join-Path $testRoot 'Word转图片.jpg'
    $wordToPptx = Join-Path $testRoot 'Word转PPT.pptx'
    Invoke-DocumentWorkerTest $docx pdf $wordToPdf | Out-Null
    Invoke-DocumentWorkerTest $docx jpg $wordToJpg | Out-Null
    Invoke-DocumentWorkerTest $docx pptx $wordToPptx | Out-Null

    $pptToPdf = Join-Path $testRoot 'PPT转PDF.pdf'
    $pptToJpg = Join-Path $testRoot 'PPT转图片.jpg'
    $pptToDocx = Join-Path $testRoot 'PPT转Word.docx'
    Invoke-DocumentWorkerTest $pptx pdf $pptToPdf | Out-Null
    Invoke-DocumentWorkerTest $pptx jpg $pptToJpg | Out-Null
    Invoke-DocumentWorkerTest $pptx docx $pptToDocx | Out-Null

    $multiPptx = Join-Path $testRoot '两页演示.pptx'
    $wps = $null
    $presentation = $null
    try {
        $wps = New-Object -ComObject KWPP.Application
        $presentation = $wps.Presentations.Open($pptx, -1, 0, 0)
        $secondSlide = $presentation.Slides.Add(2, 12)
        $secondPicture = $secondSlide.Shapes.AddPicture($image, 0, -1, 0, 0, [single]$presentation.PageSetup.SlideWidth, [single]$presentation.PageSetup.SlideHeight)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($secondPicture)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($secondSlide)
        $presentation.SaveAs($multiPptx, 24)
    }
    finally {
        if ($presentation) { try { $presentation.Close() } catch { }; [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($presentation) }
        if ($wps) { try { $wps.Quit() } catch { }; [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wps) }
    }
    $multiJpg = Join-Path $testRoot '两页输出.jpg'
    $multiResult = Invoke-DocumentWorkerTest $multiPptx jpg $multiJpg
    if ([int]$multiResult.PageCount -ne 2 -or @($multiResult.OutputPaths).Count -ne 2) { throw '多页文档没有逐页输出。' }
    Write-Host 'Document conversion: image, PDF, Word and PPT round trips passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

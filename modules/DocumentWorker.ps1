param([Parameter(Mandatory)][string]$JobPath)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Write-JsonAtomic([string]$Path, [object]$Value) {
    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $Path, $true)
}

function Set-Progress([string]$Phase, [int]$Percent) {
    Write-JsonAtomic ([string]$job.ProgressPath) ([ordered]@{ Phase = $Phase; Percent = [Math]::Clamp($Percent, 0, 100) })
}

function Release-ComObject($Value) {
    if ($null -ne $Value -and [Runtime.InteropServices.Marshal]::IsComObject($Value)) {
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Value) } catch { }
    }
}

function Test-ImageExtension([string]$Extension) {
    return $Extension -in @('.png', '.jpg', '.jpeg', '.jfif', '.webp')
}

function Start-CheckedProcess([string]$FileName, [string[]]$Arguments, [scriptblock]$Heartbeat = $null) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.WorkingDirectory = [IO.Path]::GetDirectoryName($FileName)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "无法启动组件：$FileName" }
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    while (-not $process.WaitForExit(400)) {
        if ($Heartbeat) { & $Heartbeat }
    }
    $process.WaitForExit()
    $output = $standardOutput.GetAwaiter().GetResult()
    $errorText = $standardError.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    if ($exitCode -ne 0) {
        $message = ($errorText + "`n" + $output).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) { $message = "组件退出代码：$exitCode" }
        throw $message
    }
}

function Get-ImageSizePoints([string]$Path, [double]$MaximumWidth, [double]$MaximumHeight) {
    Add-Type -AssemblyName System.Drawing.Common
    $image = [Drawing.Image]::FromFile($Path)
    try {
        $ratio = [Math]::Min($MaximumWidth / $image.Width, $MaximumHeight / $image.Height)
        return [PSCustomObject]@{ Width = $image.Width * $ratio; Height = $image.Height * $ratio }
    }
    finally { $image.Dispose() }
}

function Open-WpsWriter {
    try { return New-Object -ComObject KWPS.Application }
    catch { throw 'Word 文档转换需要本机安装 WPS Office（文字）。' }
}

function Open-WpsPresentation {
    try { return New-Object -ComObject KWPP.Application }
    catch { throw 'PPT 文档转换需要本机安装 WPS Office（演示）。' }
}

function Save-WriterDocument($Document, [string]$Destination, [int]$Format) {
    try { $Document.SaveAs2($Destination, $Format) }
    catch { $Document.SaveAs($Destination, $Format) }
}

function New-WordFromImages([string[]]$Images, [string]$Destination, [switch]$Pdf) {
    $application = $null
    $document = $null
    try {
        $application = Open-WpsWriter
        $application.Visible = $false
        try { $application.DisplayAlerts = 0 } catch { }
        try { $application.AutomationSecurity = 3 } catch { }
        $document = $application.Documents.Add()
        $page = $document.Sections.Item(1).PageSetup
        $usableWidth = [double]$page.PageWidth - [double]$page.LeftMargin - [double]$page.RightMargin
        $usableHeight = [double]$page.PageHeight - [double]$page.TopMargin - [double]$page.BottomMargin
        for ($index = 0; $index -lt $Images.Count; $index++) {
            $range = $document.Range($document.Content.End - 1, $document.Content.End - 1)
            if ($index -gt 0) {
                $range.InsertBreak(7)
                $range = $document.Range($document.Content.End - 1, $document.Content.End - 1)
            }
            $shape = $range.InlineShapes.AddPicture($Images[$index], $false, $true)
            $size = Get-ImageSizePoints $Images[$index] $usableWidth $usableHeight
            $shape.LockAspectRatio = -1
            $shape.Width = [single]$size.Width
            $shape.Height = [single]$size.Height
            Release-ComObject $shape
            Release-ComObject $range
        }
        if ($Pdf) { $document.ExportAsFixedFormat($Destination, 17) }
        else { Save-WriterDocument $document $Destination 12 }
    }
    finally {
        if ($document) { try { $document.Close(0) } catch { } }
        if ($application) { try { $application.Quit() } catch { } }
        Release-ComObject $document
        Release-ComObject $application
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}

function New-PresentationFromImages([string[]]$Images, [string]$Destination, [switch]$Pdf) {
    $application = $null
    $presentation = $null
    try {
        $application = Open-WpsPresentation
        try { $application.Visible = $false } catch { }
        try { $application.DisplayAlerts = 0 } catch { }
        try { $application.AutomationSecurity = 3 } catch { }
        $presentation = $application.Presentations.Add()
        $slideWidth = [double]$presentation.PageSetup.SlideWidth
        $slideHeight = [double]$presentation.PageSetup.SlideHeight
        for ($index = 0; $index -lt $Images.Count; $index++) {
            $slide = $presentation.Slides.Add($index + 1, 12)
            $size = Get-ImageSizePoints $Images[$index] $slideWidth $slideHeight
            $left = ($slideWidth - $size.Width) / 2
            $top = ($slideHeight - $size.Height) / 2
            $shape = $slide.Shapes.AddPicture($Images[$index], 0, -1, [single]$left, [single]$top, [single]$size.Width, [single]$size.Height)
            Release-ComObject $shape
            Release-ComObject $slide
            $percent = 60 + [Math]::Floor((($index + 1) / [double]$Images.Count) * 30)
            Set-Progress ("正在创建第 {0} / {1} 张幻灯片" -f ($index + 1), $Images.Count) $percent
        }
        Set-Progress ("正在保存 PowerPoint · 共 {0} 张幻灯片" -f $Images.Count) 92
        $presentation.SaveAs($Destination, $(if ($Pdf) { 32 } else { 24 }))
        Set-Progress 'PowerPoint 已生成，正在完成收尾' 98
    }
    finally {
        if ($presentation) { try { $presentation.Close() } catch { } }
        if ($application) { try { $application.Quit() } catch { } }
        Release-ComObject $presentation
        Release-ComObject $application
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}

function Convert-WordTo([string]$Source, [string]$Destination, [ValidateSet('pdf','docx')]$Format) {
    $application = $null
    $document = $null
    try {
        $application = Open-WpsWriter
        $application.Visible = $false
        try { $application.DisplayAlerts = 0 } catch { }
        try { $application.AutomationSecurity = 3 } catch { }
        $document = $application.Documents.Open($Source, $false, $true)
        if ($Format -eq 'pdf') { $document.ExportAsFixedFormat($Destination, 17) }
        else { Save-WriterDocument $document $Destination 12 }
    }
    finally {
        if ($document) { try { $document.Close(0) } catch { } }
        if ($application) { try { $application.Quit() } catch { } }
        Release-ComObject $document
        Release-ComObject $application
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}

function Convert-PresentationTo([string]$Source, [string]$Destination, [ValidateSet('pdf','pptx')]$Format) {
    $application = $null
    $presentation = $null
    try {
        $application = Open-WpsPresentation
        try { $application.DisplayAlerts = 0 } catch { }
        try { $application.AutomationSecurity = 3 } catch { }
        $presentation = $application.Presentations.Open($Source, -1, 0, 0)
        $presentation.SaveAs($Destination, $(if ($Format -eq 'pdf') { 32 } else { 24 }))
    }
    finally {
        if ($presentation) { try { $presentation.Close() } catch { } }
        if ($application) { try { $application.Quit() } catch { } }
        Release-ComObject $presentation
        Release-ComObject $application
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}

function Convert-SourceToPdf([string]$Source, [string]$Destination) {
    $extension = [IO.Path]::GetExtension($Source).ToLowerInvariant()
    switch ($extension) {
        '.pdf' { Copy-Item -LiteralPath $Source -Destination $Destination -Force }
        { $_ -in @('.doc', '.docx') } { Convert-WordTo $Source $Destination pdf }
        { $_ -in @('.ppt', '.pptx') } { Convert-PresentationTo $Source $Destination pdf }
        { Test-ImageExtension $_ } { New-WordFromImages @((Get-PreparedSourceImage $Source)) $Destination -Pdf }
        default { throw "不支持的源文件格式：$extension" }
    }
}

function Get-PreparedSourceImage([string]$Source) {
    if ([int]$job.FinalWidth -le 0 -or [int]$job.FinalHeight -le 0) { return $Source }
    $prepared = Join-Path ([string]$job.TempDirectory) 'prepared-source.png'
    Start-CheckedProcess ([string]$job.MagickPath) @(
        $Source, '-auto-orient', '-colorspace', 'sRGB', '-filter', 'Lanczos',
        '-resize', ("{0}x{1}" -f $job.FinalWidth, $job.FinalHeight), '-gravity', 'center',
        '-background', [string]$job.Background, '-extent', ("{0}x{1}" -f $job.FinalWidth, $job.FinalHeight),
        '-define', 'png:compression-level=6', $prepared
    )
    return $prepared
}

function Convert-PdfToPageImages([string]$PdfPath, [string]$WorkingDirectory) {
    $prefix = Join-Path $WorkingDirectory 'page'
    $started = [DateTime]::UtcNow
    Start-CheckedProcess ([string]$job.PdfToPpmPath) @('-png', '-r', '160', $PdfPath, $prefix) {
        $pageCount = @(Get-ChildItem -LiteralPath $WorkingDirectory -Filter 'page-*.png' -File -ErrorAction SilentlyContinue).Count
        $elapsed = [Math]::Max(1, [Math]::Floor(([DateTime]::UtcNow - $started).TotalSeconds))
        $percent = [Math]::Min(55, 38 + [Math]::Min(12, [Math]::Floor($elapsed / 2)) + [Math]::Min(5, [Math]::Floor($pageCount / 10)))
        Set-Progress ("正在渲染 PDF 页面 · 已生成 {0} 页 · {1} 秒" -f $pageCount, $elapsed) $percent
    }
    $pages = @(Get-ChildItem -LiteralPath $WorkingDirectory -Filter 'page-*.png' -File | Sort-Object { if ($_.BaseName -match '(\d+)$') { [int]$Matches[1] } else { 0 } } | ForEach-Object FullName)
    if ($pages.Count -eq 0) { throw 'PDF 没有可渲染的页面。' }
    Set-Progress ("PDF 页面渲染完成 · 共 {0} 页" -f $pages.Count) 58
    return $pages
}

function New-PageOutputPath([string]$FirstPath, [int]$PageNumber) {
    if ($PageNumber -eq 1) { return $FirstPath }
    $directory = [IO.Path]::GetDirectoryName($FirstPath)
    $extension = [IO.Path]::GetExtension($FirstPath)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($FirstPath)
    $candidate = Join-Path $directory ("{0}_第{1}页{2}" -f $baseName, $PageNumber, $extension)
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory ("{0}_第{1}页_{2}{3}" -f $baseName, $PageNumber, $suffix, $extension)
        $suffix++
    }
    return $candidate
}

function Convert-PagesToImages([string[]]$Pages, [string]$FirstDestination, [string]$Format) {
    $outputs = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Pages.Count; $index++) {
        $destination = New-PageOutputPath $FirstDestination ($index + 1)
        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($value in @($Pages[$index], '-auto-orient', '-colorspace', 'sRGB')) { $arguments.Add($value) }
        if ([int]$job.FinalWidth -gt 0 -and [int]$job.FinalHeight -gt 0) {
            foreach ($value in @('-filter','Lanczos','-resize',("{0}x{1}" -f $job.FinalWidth,$job.FinalHeight),'-gravity','center','-background',[string]$job.Background,'-extent',("{0}x{1}" -f $job.FinalWidth,$job.FinalHeight))) { $arguments.Add($value) }
        }
        if ($Format -eq 'jpg') { foreach ($value in @('-background',[string]$job.Background,'-alpha','remove','-alpha','off','-sampling-factor','4:4:4','-quality','100')) { $arguments.Add($value) } }
        elseif ($Format -eq 'webp') { foreach ($value in @('-quality','100','-define','webp:lossless=true')) { $arguments.Add($value) } }
        else { foreach ($value in @('-define','png:compression-level=6')) { $arguments.Add($value) } }
        $arguments.Add($destination)
        Start-CheckedProcess ([string]$job.MagickPath) $arguments.ToArray()
        $outputs.Add($destination)
        Set-Progress ("正在输出第 {0} / {1} 页" -f ($index + 1), $Pages.Count) (55 + [Math]::Floor((($index + 1) / [double]$Pages.Count) * 40))
    }
    return $outputs.ToArray()
}

$workingDirectory = [string]$job.TempDirectory
[void][IO.Directory]::CreateDirectory($workingDirectory)
$source = [string]$job.SourcePath
$destination = [string]$job.OutputPath
$outputFormat = ([string]$job.OutputFormat).ToLowerInvariant()
$sourceExtension = [IO.Path]::GetExtension($source).ToLowerInvariant()

try {
    Set-Progress '正在准备本地文档转换' 5
    $outputs = @()
    if ($outputFormat -eq 'pdf') {
        Set-Progress '正在生成 PDF' 35
        Convert-SourceToPdf $source $destination
        $outputs = @($destination)
    }
    elseif ($outputFormat -eq 'docx') {
        Set-Progress '正在生成 Word 文档' 35
        if ($sourceExtension -in @('.doc', '.docx')) { Convert-WordTo $source $destination docx }
        elseif (Test-ImageExtension $sourceExtension) { New-WordFromImages @((Get-PreparedSourceImage $source)) $destination }
        else {
            $pdf = Join-Path $workingDirectory 'source.pdf'
            Convert-SourceToPdf $source $pdf
            $pages = @(Convert-PdfToPageImages $pdf $workingDirectory)
            New-WordFromImages $pages $destination
        }
        $outputs = @($destination)
    }
    elseif ($outputFormat -eq 'pptx') {
        Set-Progress '正在生成 PowerPoint 演示文稿' 35
        if ($sourceExtension -in @('.ppt', '.pptx')) { Convert-PresentationTo $source $destination pptx }
        elseif (Test-ImageExtension $sourceExtension) { New-PresentationFromImages @((Get-PreparedSourceImage $source)) $destination }
        else {
            $pdf = Join-Path $workingDirectory 'source.pdf'
            Convert-SourceToPdf $source $pdf
            $pages = @(Convert-PdfToPageImages $pdf $workingDirectory)
            New-PresentationFromImages $pages $destination
        }
        $outputs = @($destination)
    }
    elseif ($outputFormat -in @('jpg','png','webp')) {
        Set-Progress '正在将文档渲染为页面' 25
        $pdf = Join-Path $workingDirectory 'source.pdf'
        Convert-SourceToPdf $source $pdf
        $pages = @(Convert-PdfToPageImages $pdf $workingDirectory)
        $outputs = @(Convert-PagesToImages $pages $destination $outputFormat)
    }
    else { throw "不支持的输出格式：$outputFormat" }

    foreach ($path in $outputs) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "输出文件生成失败：$path" }
    }
    Set-Progress '正在验证输出文件' 100
    Write-JsonAtomic ([string]$job.ResultPath) ([ordered]@{ Success = $true; OutputPath = $outputs[0]; OutputPaths = $outputs; PageCount = $outputs.Count; Error = $null })
    exit 0
}
catch {
    Write-JsonAtomic ([string]$job.ResultPath) ([ordered]@{ Success = $false; OutputPath = $null; OutputPaths = @(); PageCount = 0; Error = $_.Exception.Message })
    exit 1
}

param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 8 -Compress
    $temporaryPath = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($temporaryPath, $Path, $true)
}

function Set-WorkerProgress {
    param([string]$Phase, [int]$Percent)
    Write-JsonAtomic $job.ProgressPath ([PSCustomObject]@{
        Phase = $Phase
        Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
        UpdatedAt = [DateTime]::UtcNow.ToString('o')
    })
}

function Invoke-ExternalTool {
    param([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "无法启动：$FileName" }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $message = ($standardError + "`n" + $standardOutput).Trim()
            if ($message.Length -gt 3000) { $message = $message.Substring($message.Length - 3000) }
            throw "处理引擎退出代码 $($process.ExitCode)：$message"
        }
        return [PSCustomObject]@{ Output = $standardOutput; Error = $standardError }
    }
    finally { $process.Dispose() }
}

function Invoke-Magick {
    param([string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $job.MagickPath -PathType Leaf)) { throw '保守清晰引擎不可用：找不到 ImageMagick。' }
    return Invoke-ExternalTool $job.MagickPath $Arguments ([System.IO.Path]::GetDirectoryName($job.MagickPath))
}

function Get-ImageInformation {
    param([string]$Path)
    $result = Invoke-Magick @('identify', '-ping', '-format', '%w|%h|%[channels]', $Path)
    $parts = $result.Output.Trim().Split('|')
    if ($parts.Count -lt 3) { throw "无法识别图片信息：$Path" }
    return [PSCustomObject]@{ Width = [int]$parts[0]; Height = [int]$parts[1]; HasAlpha = ([string]$parts[2] -match 'a') }
}

function Get-StrengthProfile {
    param([string]$Strength)
    switch ($Strength) {
        '轻微' { return [PSCustomObject]@{ Bilateral = '3x3+2+1'; Clahe = '25x25%+128+1.35'; Unsharp = '0x0.55+0.45+0.02' } }
        '较强' { return [PSCustomObject]@{ Bilateral = '5x5+3+1.5'; Clahe = '25x25%+128+1.85'; Unsharp = '0x0.75+0.70+0.025' } }
        default { return [PSCustomObject]@{ Bilateral = '3x3+2.5+1.2'; Clahe = '25x25%+128+1.55'; Unsharp = '0x0.65+0.55+0.02' } }
    }
}

function Get-WorkingSize {
    param([object]$Information)
    if ([int]$job.FinalWidth -gt 0 -and [int]$job.FinalHeight -gt 0) { return [PSCustomObject]@{ Width = [int]$job.FinalWidth; Height = [int]$job.FinalHeight } }
    $scale = [Math]::Max(1, [int]$job.Scale)
    return [PSCustomObject]@{ Width = $Information.Width * $scale; Height = $Information.Height * $scale }
}

function Add-FitCanvasArguments {
    param([System.Collections.Generic.List[string]]$Arguments, [int]$Width, [int]$Height, [string]$Background)
    if ($Width -gt 0 -and $Height -gt 0) {
        foreach ($argument in @('-filter', 'Lanczos', '-resize', "${Width}x${Height}", '-gravity', 'center', '-background', $Background, '-extent', "${Width}x${Height}")) { $Arguments.Add($argument) }
    }
}

function Export-FinalImage {
    param([string]$WorkingPath, [object]$Information)
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @($WorkingPath, '-auto-orient', '-colorspace', 'sRGB')) { $arguments.Add($argument) }
    $keepAlpha = [bool]$job.PreserveAlpha -and $Information.HasAlpha -and ([string]$job.OutputFormat -ne 'jpg')
    $background = if ($keepAlpha) { 'none' } else { [string]$job.Background }
    Add-FitCanvasArguments $arguments ([int]$job.FinalWidth) ([int]$job.FinalHeight) $background
    if (-not $keepAlpha) { foreach ($argument in @('-background', [string]$job.Background, '-alpha', 'remove', '-alpha', 'off')) { $arguments.Add($argument) } }
    switch ([string]$job.OutputFormat) {
        'jpg' { foreach ($argument in @('-sampling-factor', '4:4:4', '-quality', '100')) { $arguments.Add($argument) } }
        'webp' { foreach ($argument in @('-quality', '100', '-define', 'webp:lossless=true')) { $arguments.Add($argument) } }
        default { foreach ($argument in @('-define', 'png:compression-level=6')) { $arguments.Add($argument) } }
    }
    $arguments.Add([string]$job.OutputPath)
    [void](Invoke-Magick $arguments.ToArray())
}

function Invoke-PlainConversion {
    param([object]$Information)
    Set-WorkerProgress '调整尺寸和格式' 35
    Export-FinalImage $job.SourcePath $Information
}

function Invoke-ConservativeEnhancement {
    param([object]$Information)
    $profile = Get-StrengthProfile ([string]$job.Strength)
    $workSize = Get-WorkingSize $Information
    $enhancedPath = Join-Path $job.TempDirectory 'conservative.png'
    $alphaPath = Join-Path $job.TempDirectory 'alpha.png'
    $colorPath = Join-Path $job.TempDirectory 'color.png'
    Set-WorkerProgress '轻度去噪' 15
    $colorArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @([string]$job.SourcePath, '-auto-orient', '-alpha', 'off', '-colorspace', 'Lab', '-channel', 'R', '-bilateral-blur', $profile.Bilateral, '+channel', '-colorspace', 'sRGB')) { $colorArguments.Add($argument) }
    Add-FitCanvasArguments $colorArguments $workSize.Width $workSize.Height ([string]$job.Background)
    foreach ($argument in @('-colorspace', 'Lab', '-channel', 'R', '-unsharp', $profile.Unsharp, '-clahe', $profile.Clahe, '+channel', '-colorspace', 'sRGB', $colorPath)) { $colorArguments.Add($argument) }
    [void](Invoke-Magick $colorArguments.ToArray())
    if ($Information.HasAlpha -and [bool]$job.PreserveAlpha) {
        Set-WorkerProgress '恢复透明边缘' 62
        [void](Invoke-Magick @(
            [string]$job.SourcePath, '-auto-orient', '-alpha', 'extract', '-filter', 'Lanczos',
            '-resize', "$($workSize.Width)x$($workSize.Height)", '-gravity', 'center', '-background', 'black',
            '-extent', "$($workSize.Width)x$($workSize.Height)", $alphaPath
        ))
        [void](Invoke-Magick @($colorPath, $alphaPath, '-alpha', 'off', '-compose', 'CopyAlpha', '-composite', $enhancedPath))
    } else { [System.IO.File]::Copy($colorPath, $enhancedPath, $true) }
    Set-WorkerProgress '输出保守清晰结果' 82
    Export-FinalImage $enhancedPath (Get-ImageInformation $enhancedPath)
}

function Invoke-AiEnhancement {
    param([object]$Information)
    if (-not (Test-Path -LiteralPath $job.RealEsrganPath -PathType Leaf)) { throw 'AI 高清引擎不可用：找不到 Real-ESRGAN。' }
    foreach ($extension in @('param', 'bin')) {
        $modelFile = Join-Path $job.ModelPath (([string]$job.ModelName) + '.' + $extension)
        if (-not (Test-Path -LiteralPath $modelFile -PathType Leaf)) { throw "缺少 AI 模型文件：$modelFile" }
    }
    $stagedInput = Join-Path $job.TempDirectory 'input.png'
    $rawAiPath = Join-Path $job.TempDirectory 'ai-4x.png'
    $aiPath = Join-Path $job.TempDirectory 'ai.png'
    $normalPath = Join-Path $job.TempDirectory 'normal.png'
    $mixedRgbPath = Join-Path $job.TempDirectory 'mixed-rgb.png'
    $mixedPath = Join-Path $job.TempDirectory 'mixed.png'
    $alphaPath = Join-Path $job.TempDirectory 'alpha.png'
    $requestedScale = [Math]::Max(2, [Math]::Min(4, [int]$job.Scale))
    Set-WorkerProgress '准备 AI 输入' 8
    # Real-ESRGAN NCNN 对带 Alpha 的 PNG 会自行处理透明通道，部分图片会造成 RGB 与原始 Alpha 偏移。
    # 因此 AI 只接收 RGB，最终始终恢复由原图 Lanczos 缩放得到的 Alpha。
    [void](Invoke-Magick @([string]$job.SourcePath, '-auto-orient', '-alpha', 'off', '-colorspace', 'sRGB', $stagedInput))
    Set-WorkerProgress 'AI 模型高清处理中' 18
    # x4plus 系列模型按原生 4× 推理最稳定；该便携引擎直接 -s 2 会在部分高对比图片上造成内容偏移。
    [void](Invoke-ExternalTool $job.RealEsrganPath @('-i', $stagedInput, '-o', $rawAiPath, '-m', [string]$job.ModelPath, '-n', [string]$job.ModelName, '-s', '4', '-t', [string]$job.TileSize, '-g', '0', '-j', '1:2:2', '-f', 'png', '-v') ([System.IO.Path]::GetDirectoryName($job.RealEsrganPath)))
    if ($requestedScale -eq 2) {
        Set-WorkerProgress '生成 2× AI 结果' 58
        [void](Invoke-Magick @($rawAiPath, '-filter', 'Lanczos', '-resize', "$($Information.Width * 2)x$($Information.Height * 2)!", $aiPath))
    } else {
        [System.IO.File]::Copy($rawAiPath, $aiPath, $true)
    }
    $aiInformation = Get-ImageInformation $aiPath
    Set-WorkerProgress '生成忠实放大基准' 64
    [void](Invoke-Magick @($stagedInput, '-alpha', 'off', '-filter', 'Lanczos', '-resize', "$($aiInformation.Width)x$($aiInformation.Height)!", $normalPath))
    $aiWeight = switch ([string]$job.Strength) { '保守' { 0.50 } '明显' { 1.00 } default { 0.75 } }
    if ($aiWeight -ge 1) { [void](Invoke-Magick @($aiPath, '-alpha', 'off', $mixedRgbPath)) }
    else {
        $normalWeight = 1.0 - $aiWeight
        $blendArguments = "compose:args=0,{0},{1},0" -f $aiWeight.ToString([Globalization.CultureInfo]::InvariantCulture), $normalWeight.ToString([Globalization.CultureInfo]::InvariantCulture)
        [void](Invoke-Magick @($normalPath, '(', $aiPath, '-alpha', 'off', ')', '-compose', 'Mathematics', '-define', $blendArguments, '-composite', $mixedRgbPath))
    }
    if ($Information.HasAlpha -and [bool]$job.PreserveAlpha) {
        Set-WorkerProgress '恢复透明边缘' 78
        [void](Invoke-Magick @([string]$job.SourcePath, '-auto-orient', '-alpha', 'extract', '-filter', 'Lanczos', '-resize', "$($aiInformation.Width)x$($aiInformation.Height)!", $alphaPath))
        [void](Invoke-Magick @($mixedRgbPath, $alphaPath, '-alpha', 'off', '-compose', 'CopyAlpha', '-composite', $mixedPath))
    } else { [System.IO.File]::Copy($mixedRgbPath, $mixedPath, $true) }
    Set-WorkerProgress '调整最终尺寸和格式' 88
    Export-FinalImage $mixedPath (Get-ImageInformation $mixedPath)
}

$job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
[System.IO.Directory]::CreateDirectory([string]$job.TempDirectory) | Out-Null
$result = [PSCustomObject]@{ Success = $false; OutputPath = [string]$job.OutputPath; Error = $null; Mode = [string]$job.Mode }
try {
    Set-WorkerProgress '读取图片' 2
    $information = Get-ImageInformation ([string]$job.SourcePath)
    switch ([string]$job.Mode) {
        '保守清晰' { Invoke-ConservativeEnhancement $information }
        'AI 模型高清' { Invoke-AiEnhancement $information }
        'API 大模型清晰' {
            . (Join-Path $PSScriptRoot 'ImageApi.ps1')
            Set-WorkerProgress '上传图片并等待大模型处理' 10
            $apiConfig = $job.ApiConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
            $apiSource = Join-Path $job.TempDirectory 'api-input.png'
            [void](Invoke-Magick @([string]$job.SourcePath, '-auto-orient', $apiSource))
            $apiResult = Join-Path $job.TempDirectory 'api-result.png'
            Invoke-ImageApi $apiConfig $apiSource $apiResult
            Set-WorkerProgress '验证结果并转换输出格式' 90
            Export-FinalImage $apiResult (Get-ImageInformation $apiResult)
        }
        default { Invoke-PlainConversion $information }
    }
    if (-not (Test-Path -LiteralPath $job.OutputPath -PathType Leaf)) { throw '处理完成但未生成输出文件。' }
    $result.Success = $true
    Set-WorkerProgress '完成' 100
} catch {
    $result.Error = $_.Exception.Message
    Set-WorkerProgress '失败' 100
} finally { Write-JsonAtomic ([string]$job.ResultPath) $result }
if (-not $result.Success) { exit 1 }

param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $temporaryPath = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporaryPath, ($Value | ConvertTo-Json -Depth 6 -Compress), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($temporaryPath, $Path, $true)
}

function Invoke-Magick {
    param([string[]]$Arguments)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$job.MagickPath
    $startInfo.WorkingDirectory = [System.IO.Path]::GetDirectoryName([string]$job.MagickPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '无法启动预览引擎。' }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $outputTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $message = ($errorText + "`n" + $output).Trim()
            if ($message.Length -gt 1200) { $message = $message.Substring($message.Length - 1200) }
            throw $message
        }
        return $output
    }
    finally { $process.Dispose() }
}

function New-Preview {
    param([string]$SourcePath, [string]$DestinationPath)

    # 一次 ImageMagick 调用同时读取原始尺寸并生成缩略图，避免预览时重复启动进程。
    $information = Invoke-Magick @(
        $SourcePath,
        '-auto-orient',
        '-print', '%w|%h',
        '-thumbnail', ("{0}x{1}>" -f [int]$job.MaxWidth, [int]$job.MaxHeight),
        '-background', '#EEF2F8',
        '-alpha', 'background',
        '-strip',
        $DestinationPath
    )
    $parts = $information.Trim().Split('|')
    if ($parts.Count -lt 2) { throw '无法读取图片尺寸。' }
    return [PSCustomObject]@{ Width = [int]$parts[0]; Height = [int]$parts[1] }
}

$job = $null
$result = $null
try {
    $job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath ([string]$job.MagickPath) -PathType Leaf)) { throw '预览引擎不存在。' }
    if (-not (Test-Path -LiteralPath ([string]$job.SourcePath) -PathType Leaf)) { throw '原图不存在。' }

    $originalSize = New-Preview ([string]$job.SourcePath) ([string]$job.OriginalPreviewPath)
    $resultSize = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$job.ResultSourcePath) -and (Test-Path -LiteralPath ([string]$job.ResultSourcePath) -PathType Leaf)) {
        $resultSize = New-Preview ([string]$job.ResultSourcePath) ([string]$job.ResultPreviewPath)
    }
    $result = [PSCustomObject]@{
        Success = $true
        SourcePath = [string]$job.SourcePath
        OriginalPreviewPath = [string]$job.OriginalPreviewPath
        OriginalWidth = $originalSize.Width
        OriginalHeight = $originalSize.Height
        ResultPreviewPath = if ($resultSize) { [string]$job.ResultPreviewPath } else { $null }
        ResultWidth = if ($resultSize) { $resultSize.Width } else { 0 }
        ResultHeight = if ($resultSize) { $resultSize.Height } else { 0 }
        Error = $null
    }
}
catch {
    $result = [PSCustomObject]@{
        Success = $false
        SourcePath = if ($job -and $job.PSObject.Properties['SourcePath']) { [string]$job.SourcePath } else { $null }
        Error = $_.Exception.Message
    }
}
finally {
    if ($job -and $job.PSObject.Properties['ResponsePath']) {
        Write-JsonAtomic ([string]$job.ResponsePath) $result
    }
}

param([Parameter(Mandatory)][string]$JobPath)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type -AssemblyName System.Drawing.Common
$featureCache=@{}
$featureCacheChanged=$false
if($job.PSObject.Properties.Name -contains 'FeatureCachePath' -and $job.FeatureCachePath -and (Test-Path -LiteralPath ([string]$job.FeatureCachePath) -PathType Leaf)){
    try{$loadedCache=Get-Content -LiteralPath ([string]$job.FeatureCachePath) -Raw -Encoding UTF8|ConvertFrom-Json -AsHashtable;if($loadedCache){$featureCache=$loadedCache}}catch{$featureCache=@{}}
}

function Write-JsonAtomic([string]$Path, [object]$Value, [int]$Attempts = 12) {
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            try {
                [IO.File]::Move($temporary, $Path, $true)
                return
            }
            catch [IO.IOException] {
                if ($attempt -ge $Attempts) { throw }
                Start-Sleep -Milliseconds ([Math]::Min(150, 15 * $attempt))
            }
            catch [UnauthorizedAccessException] {
                if ($attempt -ge $Attempts) { throw }
                Start-Sleep -Milliseconds ([Math]::Min(150, 15 * $attempt))
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-SearchProgress([string]$Phase, [int]$Percent, [int]$Scanned, [int]$Matched) {
    try {
        Write-JsonAtomic ([string]$job.ProgressPath) ([ordered]@{ Phase=$Phase; Percent=[Math]::Clamp($Percent,0,100); Scanned=$Scanned; Matched=$Matched }) 4
    }
    catch {
        # Progress is advisory. A briefly locked progress file must never abort the search.
    }
}

function Get-SearchFiles([string]$Root) {
    $options = [IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true
    $options.IgnoreInaccessible = $true
    $options.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
    return [IO.Directory]::EnumerateFiles($Root, '*', $options)
}

function Get-SearchEntries([string]$Root) {
    $options = [IO.EnumerationOptions]::new()
    $options.RecurseSubdirectories = $true
    $options.IgnoreInaccessible = $true
    $options.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
    return [IO.Directory]::EnumerateFileSystemEntries($Root, '*', $options)
}

function Get-FileKind([string]$Path) {
    $extension = [IO.Path]::GetExtension($Path).TrimStart('.').ToUpperInvariant()
    if (-not $extension) { return '文件' }
    return $extension
}

function Get-ImageFeature([string]$Path) {
    $decodePath = $Path
    $convertedPath = ''
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -in @('.webp','.avif','.heic','.heif')) {
        if (-not $job.MagickPath -or -not (Test-Path -LiteralPath ([string]$job.MagickPath) -PathType Leaf)) { throw '当前安装缺少图片解码组件。' }
        $convertedPath = Join-Path ([IO.Path]::GetTempPath()) ('local-search-'+[Guid]::NewGuid().ToString('N')+'.png')
        & ([string]$job.MagickPath) ($Path+'[0]') $convertedPath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $convertedPath -PathType Leaf)) { throw '无法解码图片。' }
        $decodePath = $convertedPath
    }
    $stream = $null
    $source = $null
    $bitmap = $null
    $graphics = $null
    try {
        $stream = [IO.File]::Open($decodePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $source = [Drawing.Image]::FromStream($stream, $true, $false)
        $bitmap = [Drawing.Bitmap]::new(9, 8, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($source, 0, 0, 9, 8)
        [UInt64]$hash = 0
        [double]$red = 0; [double]$green = 0; [double]$blue = 0
        for ($y=0; $y -lt 8; $y++) {
            for ($x=0; $x -lt 8; $x++) {
                $left = $bitmap.GetPixel($x,$y); $right = $bitmap.GetPixel($x+1,$y)
                $leftLuma = 0.299*$left.R + 0.587*$left.G + 0.114*$left.B
                $rightLuma = 0.299*$right.R + 0.587*$right.G + 0.114*$right.B
                if ($leftLuma -gt $rightLuma) { $hash = $hash -bor ([UInt64]1 -shl ($y*8+$x)) }
                $red += $left.R; $green += $left.G; $blue += $left.B
            }
        }
        return [PSCustomObject]@{ Hash=$hash; Red=$red/64; Green=$green/64; Blue=$blue/64; Width=$source.Width; Height=$source.Height }
    }
    finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($source) { $source.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($convertedPath) { Remove-Item -LiteralPath $convertedPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-CachedImageFeature([string]$Path) {
    $info=[IO.FileInfo]::new($Path);$key=$info.FullName.ToLowerInvariant();$ticks=$info.LastWriteTimeUtc.Ticks
    if($featureCache.ContainsKey($key)){
        $cached=$featureCache[$key]
        if([long]$cached.Length -eq $info.Length -and [long]$cached.LastWriteTimeUtcTicks -eq $ticks){return [PSCustomObject]@{Hash=[UInt64]::Parse([string]$cached.Hash);Red=[double]$cached.Red;Green=[double]$cached.Green;Blue=[double]$cached.Blue;Width=[int]$cached.Width;Height=[int]$cached.Height}}
    }
    $feature=Get-ImageFeature $Path
    $featureCache[$key]=[ordered]@{Length=$info.Length;LastWriteTimeUtcTicks=$ticks;Hash=([string][UInt64]$feature.Hash);Red=$feature.Red;Green=$feature.Green;Blue=$feature.Blue;Width=$feature.Width;Height=$feature.Height}
    $script:featureCacheChanged=$true
    return $feature
}

function Save-ImageFeatureCache {
    if(-not$featureCacheChanged -or -not($job.PSObject.Properties.Name -contains 'FeatureCachePath') -or -not$job.FeatureCachePath){return}
    $cachePath=[string]$job.FeatureCachePath;$cacheDirectory=Split-Path -Parent $cachePath
    if($cacheDirectory){[void][IO.Directory]::CreateDirectory($cacheDirectory)}
    Write-JsonAtomic $cachePath $featureCache 4
}

function Get-BitCount([UInt64]$Value) {
    $count = 0
    while ($Value) { $Value = $Value -band ($Value - 1); $count++ }
    return $count
}

function Get-ImageSimilarity($Reference, $Candidate) {
    $distance = Get-BitCount ([UInt64]$Reference.Hash -bxor [UInt64]$Candidate.Hash)
    $shapeSimilarity = 1.0 - ($distance / 64.0)
    $colorDistance = [Math]::Sqrt(
        [Math]::Pow($Reference.Red-$Candidate.Red,2) +
        [Math]::Pow($Reference.Green-$Candidate.Green,2) +
        [Math]::Pow($Reference.Blue-$Candidate.Blue,2)
    ) / 441.673
    $colorSimilarity = [Math]::Max(0, 1.0-$colorDistance)
    $referenceRatio = $Reference.Width / [double]$Reference.Height
    $candidateRatio = $Candidate.Width / [double]$Candidate.Height
    $ratioPenalty = [Math]::Min(0.2, [Math]::Abs([Math]::Log($referenceRatio/$candidateRatio))*0.25)
    return [Math]::Max(0, ($shapeSimilarity*0.55 + $colorSimilarity*0.45) - $ratioPenalty)
}

function Get-ImagePreview([string]$Path) {
    $decodePath=$Path;$convertedPath=''
    if([IO.Path]::GetExtension($Path).ToLowerInvariant() -in @('.webp','.avif','.heic','.heif')){
        try{$convertedPath=Join-Path ([IO.Path]::GetTempPath()) ('local-search-preview-'+[Guid]::NewGuid().ToString('N')+'.png');& ([string]$job.MagickPath) ($Path+'[0]') $convertedPath;if($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $convertedPath -PathType Leaf)){$decodePath=$convertedPath}}catch{}
    }
    $stream=$null;$source=$null;$thumb=$null;$graphics=$null;$memory=$null
    try {
        $stream=[IO.File]::Open($decodePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $source=[Drawing.Image]::FromStream($stream,$true,$false)
        $scale=[Math]::Min(180.0/$source.Width,120.0/$source.Height)
        $width=[Math]::Max(1,[int]($source.Width*$scale));$height=[Math]::Max(1,[int]($source.Height*$scale))
        $thumb=[Drawing.Bitmap]::new($width,$height,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics=[Drawing.Graphics]::FromImage($thumb);$graphics.Clear([Drawing.Color]::White);$graphics.CompositingQuality=[Drawing.Drawing2D.CompositingQuality]::HighSpeed;$graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::Bilinear;$graphics.PixelOffsetMode=[Drawing.Drawing2D.PixelOffsetMode]::HighSpeed;$graphics.DrawImage($source,0,0,$width,$height)
        $memory=[IO.MemoryStream]::new();$thumb.Save($memory,[Drawing.Imaging.ImageFormat]::Jpeg)
        return 'data:image/jpeg;base64,'+[Convert]::ToBase64String($memory.ToArray())
    }
    catch { return '' }
    finally { if($memory){$memory.Dispose()};if($graphics){$graphics.Dispose()};if($thumb){$thumb.Dispose()};if($source){$source.Dispose()};if($stream){$stream.Dispose()};if($convertedPath){Remove-Item -LiteralPath $convertedPath -Force -ErrorAction SilentlyContinue} }
}

try {
    $root = [IO.Path]::GetFullPath([string]$job.Root)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw '搜索目录不存在。' }
    $mode = [string]$job.Mode
    $maximum = [Math]::Clamp([int]$job.MaximumResults, 1, 500)
    $results = [Collections.Generic.List[object]]::new()
    $scanned = 0
    $filesSeen = 0
    $progressWatch = [Diagnostics.Stopwatch]::StartNew()
    $lastProgressAt = 0L
    Set-SearchProgress '正在读取目录并搜索…' 0 0 0

    if ($mode -eq 'number') {
        $query = ([string]$job.Query).Trim()
        if (-not $query) { throw '请输入要查找的编号。' }
        foreach ($path in (Get-SearchEntries $root)) {
            $scanned++
            $relative = [IO.Path]::GetRelativePath($root,$path)
            if ($relative.IndexOf($query,[StringComparison]::CurrentCultureIgnoreCase) -ge 0) {
                $isDirectory = [IO.Directory]::Exists($path)
                if ($isDirectory) {
                    $info = [IO.DirectoryInfo]::new($path)
                    $results.Add([ordered]@{ Name=$info.Name; Path=$info.FullName; RelativePath=$relative; Kind='文件夹'; Size=0; IsDirectory=$true; Similarity=100; Exact=$true; Preview='' })
                }
                else {
                    $info = [IO.FileInfo]::new($path)
                    $results.Add([ordered]@{ Name=$info.Name; Path=$info.FullName; RelativePath=$relative; Kind=(Get-FileKind $path); Size=$info.Length; IsDirectory=$false; Similarity=100; Exact=$true; Preview='' })
                }
                if ($results.Count -ge $maximum) { break }
            }
            if ($progressWatch.ElapsedMilliseconds-$lastProgressAt -ge 350) {
                Set-SearchProgress "正在匹配编号：已扫描 $scanned 个项目 · $([IO.Path]::GetFileName($path))" 0 $scanned $results.Count
                $lastProgressAt=$progressWatch.ElapsedMilliseconds
            }
        }
    }
    elseif ($mode -eq 'image') {
        $referencePath = [IO.Path]::GetFullPath([string]$job.ReferencePath)
        if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) { throw '请选择用于查找的参考图片。' }
        $referenceInfo = [IO.FileInfo]::new($referencePath)
        $referenceHash = (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash
        $threshold = [Math]::Clamp([double]$job.Threshold,0.5,1.0)
        $exactOnly = $threshold -ge 0.999
        $reference = if($exactOnly){$null}else{Get-CachedImageFeature $referencePath}
        $imageExtensions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($extension in @('.png','.jpg','.jpeg','.jfif','.bmp','.gif','.tif','.tiff','.webp','.avif','.heic','.heif')){[void]$imageExtensions.Add($extension)}
        foreach ($path in (Get-SearchFiles $root)) {
            $filesSeen++
            if (-not $imageExtensions.Contains([IO.Path]::GetExtension($path))) {
                if($progressWatch.ElapsedMilliseconds-$lastProgressAt -ge 500){Set-SearchProgress "正在扫描目录：已发现 $filesSeen 个文件，检查 $scanned 张图片" 0 $filesSeen $results.Count;$lastProgressAt=$progressWatch.ElapsedMilliseconds}
                continue
            }
            $scanned++
            try {
                $info=[IO.FileInfo]::new($path)
                $exact = $info.Length -eq $referenceInfo.Length -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $referenceHash
                $similarity = if ($exact) { 1.0 } elseif($exactOnly){0.0} else { Get-ImageSimilarity $reference (Get-CachedImageFeature $path) }
                if ($similarity -ge $threshold) {
                    $results.Add([ordered]@{ Name=$info.Name; Path=$info.FullName; RelativePath=[IO.Path]::GetRelativePath($root,$path); Kind=(Get-FileKind $path); Size=$info.Length; IsDirectory=$false; Similarity=[Math]::Round($similarity*100,1); Exact=$exact; Preview='' })
                }
            } catch { }
            if ($progressWatch.ElapsedMilliseconds-$lastProgressAt -ge 350) {
                Set-SearchProgress "正在比较第 $scanned 张图片 · 已发现 $filesSeen 个文件" 0 $filesSeen $results.Count
                $lastProgressAt=$progressWatch.ElapsedMilliseconds
            }
        }
        Save-ImageFeatureCache
        $ordered = @($results | Sort-Object @{Expression='Exact';Descending=$true},@{Expression='Similarity';Descending=$true},Name | Select-Object -First $maximum)
        $results = [Collections.Generic.List[object]]::new()
        $previewLimit=[Math]::Min(60,$ordered.Count)
        for($index=0;$index -lt $ordered.Count;$index++){
            $entry=$ordered[$index]
            if($index -lt $previewLimit){
                if(($index%5)-eq 0){Set-SearchProgress "正在整理结果预览：$($index+1) / $previewLimit" (96+[Math]::Floor(($index/[Math]::Max(1,$previewLimit))*3)) $scanned $ordered.Count}
                $entry.Preview=Get-ImagePreview ([string]$entry.Path)
            }
            $results.Add($entry)
        }
    }
    else { throw '未知搜索方式。' }

    Set-SearchProgress "搜索完成：找到 $($results.Count) 项" 100 $scanned $results.Count
    Write-JsonAtomic ([string]$job.ResultPath) ([ordered]@{ Success=$true; Results=$results.ToArray(); Scanned=$scanned; Error=$null })
    exit 0
}
catch {
    Write-JsonAtomic ([string]$job.ResultPath) ([ordered]@{ Success=$false; Results=@(); Scanned=0; Error=$_.Exception.Message })
    exit 1
}

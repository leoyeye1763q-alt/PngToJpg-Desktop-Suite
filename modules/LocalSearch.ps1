function Initialize-LocalSearch {
    $defaultRoot = [Environment]::GetFolderPath('DesktopDirectory')
    $script:localSearch = [ordered]@{
        Root=$defaultRoot; Mode='number'; Query=''; ReferencePath=''; ReferenceName=''; ReferencePreview=''; Threshold=0.92
        Status='选择目录后输入编号，或上传一张参考图片'; Progress=0; Scanned=0; Busy=$false; Results=@()
        Process=$null; JobDirectory=''; ProgressPath=''; ResultPath=''
    }
    $settingsPath = Join-Path $script:dataDirectory 'local-search.json'
    if(Test-Path -LiteralPath $settingsPath -PathType Leaf){
        try{$saved=Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8|ConvertFrom-Json;if($saved.Root -and (Test-Path -LiteralPath $saved.Root -PathType Container)){$script:localSearch.Root=[string]$saved.Root};if($saved.Threshold){$script:localSearch.Threshold=[double]$saved.Threshold}}catch{}
    }
}

function Save-LocalSearchSettings {
    [void][IO.Directory]::CreateDirectory($script:dataDirectory)
    $path=Join-Path $script:dataDirectory 'local-search.json'
    $saved=[ordered]@{Root=[string]$script:localSearch.Root;Threshold=[double]$script:localSearch.Threshold}
    [IO.File]::WriteAllText(($path+'.tmp'),($saved|ConvertTo-Json),[Text.UTF8Encoding]::new($false));[IO.File]::Move(($path+'.tmp'),$path,$true)
}

function Set-LocalSearchOptions($Options) {
    if($script:localSearch.Busy){return}
    $mode=[string]$Options.mode;$script:localSearch.Mode=if($mode -eq 'image'){'image'}else{'number'}
    $script:localSearch.Query=[string]$Options.query
    $script:localSearch.Threshold=[Math]::Clamp([double]$Options.threshold,0.5,1.0)
    Save-LocalSearchSettings
}

function Set-LocalSearchRoot([string]$Path) {
    if($script:localSearch.Busy){return}
    $full=[IO.Path]::GetFullPath($Path);if(-not(Test-Path -LiteralPath $full -PathType Container)){throw '搜索目录不存在。'}
    $script:localSearch.Root=$full;$script:localSearch.Results=@();$script:localSearch.Status='搜索目录已就绪';Save-LocalSearchSettings
}

function Set-LocalSearchReference([string]$Path) {
    if($script:localSearch.Busy){return}
    $full=[IO.Path]::GetFullPath($Path);if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw '参考图片不存在。'}
    if([IO.Path]::GetExtension($full).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.jfif','.bmp','.gif','.tif','.tiff')){throw '请选择 PNG、JPG、BMP、GIF 或 TIFF 图片。'}
    $script:localSearch.ReferencePath=$full;$script:localSearch.ReferenceName=[IO.Path]::GetFileName($full);$script:localSearch.ReferencePreview=Get-LocalSearchReferencePreview $full;$script:localSearch.Mode='image';$script:localSearch.Results=@();$script:localSearch.Status='参考图片已就绪'
}

function Get-LocalSearchReferencePreview([string]$Path) {
    Add-Type -AssemblyName System.Drawing.Common
    $stream=$null;$source=$null;$thumb=$null;$graphics=$null;$memory=$null
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $source=[Drawing.Image]::FromStream($stream,$true,$false)
        $scale=[Math]::Min(320.0/$source.Width,180.0/$source.Height)
        $width=[Math]::Max(1,[int]($source.Width*$scale));$height=[Math]::Max(1,[int]($source.Height*$scale))
        $thumb=[Drawing.Bitmap]::new($width,$height,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics=[Drawing.Graphics]::FromImage($thumb);$graphics.Clear([Drawing.Color]::White);$graphics.CompositingQuality=[Drawing.Drawing2D.CompositingQuality]::HighSpeed;$graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear;$graphics.DrawImage($source,0,0,$width,$height)
        $memory=[IO.MemoryStream]::new();$thumb.Save($memory,[Drawing.Imaging.ImageFormat]::Jpeg)
        return 'data:image/jpeg;base64,'+[Convert]::ToBase64String($memory.ToArray())
    }catch{return ''}
    finally{if($memory){$memory.Dispose()};if($graphics){$graphics.Dispose()};if($thumb){$thumb.Dispose()};if($source){$source.Dispose()};if($stream){$stream.Dispose()}}
}

function Clear-LocalSearch {
    if($script:localSearch.Busy){return}
    $script:localSearch.Query='';$script:localSearch.ReferencePath='';$script:localSearch.ReferenceName='';$script:localSearch.ReferencePreview='';$script:localSearch.Results=@();$script:localSearch.Progress=0;$script:localSearch.Scanned=0;$script:localSearch.Status='已清空搜索条件和结果'
}

function Remove-LocalSearchJob {
    if($script:localSearch.Process){try{$script:localSearch.Process.Dispose()}catch{};$script:localSearch.Process=$null}
    if($script:localSearch.JobDirectory -and (Test-Path -LiteralPath $script:localSearch.JobDirectory)){
        $root=[IO.Path]::GetFullPath($script:taskTempRoot).TrimEnd('\')+'\';$target=[IO.Path]::GetFullPath($script:localSearch.JobDirectory).TrimEnd('\')+'\'
        if($target.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $script:localSearch.JobDirectory -Recurse -Force -ErrorAction SilentlyContinue}
    }
    $script:localSearch.JobDirectory='';$script:localSearch.ProgressPath='';$script:localSearch.ResultPath='';$script:localSearch.Busy=$false
}

function Stop-LocalSearch([switch]$Cancelled) {
    if($script:localSearch.Process -and -not $script:localSearch.Process.HasExited){try{$script:localSearch.Process.Kill($true)}catch{}}
    Remove-LocalSearchJob
    if($Cancelled){$script:localSearch.Status='搜索已取消';$script:localSearch.Progress=0}
}

function Start-LocalSearch {
    if($script:localSearch.Busy){return}
    if(-not(Test-Path -LiteralPath $script:localSearch.Root -PathType Container)){throw '请先选择有效的本地搜索目录。'}
    if($script:localSearch.Mode -eq 'number' -and [string]::IsNullOrWhiteSpace($script:localSearch.Query)){throw '请输入要查找的编号。'}
    if($script:localSearch.Mode -eq 'image' -and -not(Test-Path -LiteralPath $script:localSearch.ReferencePath -PathType Leaf)){throw '请先上传一张参考图片。'}
    $directory=Join-Path $script:taskTempRoot ('LocalSearch_'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($directory)
    $jobPath=Join-Path $directory 'job.json';$progressPath=Join-Path $directory 'progress.json';$resultPath=Join-Path $directory 'result.json'
    $job=[ordered]@{Root=$script:localSearch.Root;Mode=$script:localSearch.Mode;Query=$script:localSearch.Query;ReferencePath=$script:localSearch.ReferencePath;Threshold=$script:localSearch.Threshold;MaximumResults=200;ProgressPath=$progressPath;ResultPath=$resultPath;MagickPath=$script:magickPath;FeatureCachePath=(Join-Path $script:dataDirectory 'local-search-feature-cache.json')}
    [IO.File]::WriteAllText($jobPath,($job|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$script:powerShellPath;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    foreach($argument in @('-NoLogo','-NoProfile','-File',$script:localSearchWorkerScriptPath,'-JobPath',$jobPath)){[void]$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;if(-not$process.Start()){throw '无法启动本地搜索进程。'}
    $script:localSearch.Process=$process;$script:localSearch.JobDirectory=$directory;$script:localSearch.ProgressPath=$progressPath;$script:localSearch.ResultPath=$resultPath;$script:localSearch.Results=@();$script:localSearch.Progress=0;$script:localSearch.Scanned=0;$script:localSearch.Busy=$true;$script:localSearch.Status='正在读取目录并搜索…'
}

function Poll-LocalSearch {
    if(-not$script:localSearch.Busy -or -not$script:localSearch.Process){return}
    if(Test-Path -LiteralPath $script:localSearch.ProgressPath -PathType Leaf){try{$progress=Get-Content -LiteralPath $script:localSearch.ProgressPath -Raw -Encoding UTF8|ConvertFrom-Json;$script:localSearch.Status=[string]$progress.Phase;$script:localSearch.Progress=[int]$progress.Percent;$script:localSearch.Scanned=[int]$progress.Scanned}catch{}}
    if(-not$script:localSearch.Process.HasExited){return}
    try{
        if(-not(Test-Path -LiteralPath $script:localSearch.ResultPath -PathType Leaf)){throw '搜索进程没有返回结果。'}
        $result=Get-Content -LiteralPath $script:localSearch.ResultPath -Raw -Encoding UTF8|ConvertFrom-Json
        if(-not$result.Success){throw [string]$result.Error}
        $script:localSearch.Results=@($result.Results);$script:localSearch.Scanned=[int]$result.Scanned;$script:localSearch.Progress=100;$script:localSearch.Status="搜索完成：扫描 $($script:localSearch.Scanned) 项，找到 $($script:localSearch.Results.Count) 项"
    }catch{$script:localSearch.Results=@();$script:localSearch.Progress=0;$script:localSearch.Status='搜索失败：'+$_.Exception.Message}
    finally{Remove-LocalSearchJob}
}

function Open-LocalSearchResult([int]$Index,[switch]$Folder) {
    if($Index -lt 0 -or $Index -ge $script:localSearch.Results.Count){return}
    $result=$script:localSearch.Results[$Index];$path=[string]$result.Path;$isDirectory=[bool]$result.IsDirectory
    if($isDirectory){if(-not(Test-Path -LiteralPath $path -PathType Container)){throw '结果文件夹已经不存在。'}}elseif(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw '结果文件已经不存在。'}
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName='explorer.exe';$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    if($Folder){[void]$start.ArgumentList.Add('/select,'+$path)}else{[void]$start.ArgumentList.Add($path)}
    [void][Diagnostics.Process]::Start($start)
}

function Get-LocalSearchWebState {
    return [ordered]@{root=[string]$script:localSearch.Root;mode=[string]$script:localSearch.Mode;query=[string]$script:localSearch.Query;referenceName=[string]$script:localSearch.ReferenceName;referencePreview=[string]$script:localSearch.ReferencePreview;threshold=[double]$script:localSearch.Threshold;status=[string]$script:localSearch.Status;progress=[int]$script:localSearch.Progress;scanned=[int]$script:localSearch.Scanned;busy=[bool]$script:localSearch.Busy;results=@($script:localSearch.Results)}
}

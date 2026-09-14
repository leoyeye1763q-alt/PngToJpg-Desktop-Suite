$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$worker=Join-Path $root 'modules\LocalSearchWorker.ps1'
$magick=Join-Path $root 'tools\imagemagick\magick.exe'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('PngToJpg_Search_'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'SKU-ABC123'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'LZ-CJ009'))

function Invoke-Search([string]$Mode,[string]$Query,[string]$Reference,[double]$Threshold=0.92){
    $jobRoot=Join-Path $fixture ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($jobRoot)
    $jobPath=Join-Path $jobRoot 'job.json';$resultPath=Join-Path $jobRoot 'result.json'
    $job=[ordered]@{Root=$fixture;Mode=$Mode;Query=$Query;ReferencePath=$Reference;Threshold=$Threshold;MaximumResults=200;ProgressPath=(Join-Path $jobRoot 'progress.json');ResultPath=$resultPath;MagickPath=$magick}
    [IO.File]::WriteAllText($jobPath,($job|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    & ([Environment]::ProcessPath) -NoLogo -NoProfile -File $worker -JobPath $jobPath
    $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not$result.Success){throw [string]$result.Error}
    return $result
}

function Invoke-SearchWithLockedProgress([string]$Query){
    $jobRoot=Join-Path $fixture ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($jobRoot)
    $jobPath=Join-Path $jobRoot 'job.json';$progressPath=Join-Path $jobRoot 'progress.json';$resultPath=Join-Path $jobRoot 'result.json'
    $job=[ordered]@{Root=$fixture;Mode='number';Query=$Query;ReferencePath='';Threshold=0.92;MaximumResults=200;ProgressPath=$progressPath;ResultPath=$resultPath;MagickPath=$magick}
    [IO.File]::WriteAllText($jobPath,($job|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $lock=[IO.File]::Open($progressPath,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
    $process=$null
    try{
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[Environment]::ProcessPath;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        foreach($argument in @('-NoLogo','-NoProfile','-File',$worker,'-JobPath',$jobPath)){[void]$start.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::Start($start)
        if(-not$process.WaitForExit(30000)){try{$process.Kill($true)}catch{};throw '锁定进度文件测试超时。'}
    }finally{if($process){$process.Dispose()};$lock.Dispose()}
    $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not$result.Success){throw [string]$result.Error}
    return $result
}

try{
    $reference=Join-Path $fixture 'SKU-ABC123\主图.png'
    & $magick -size 640x360 gradient:'#ff5e36-#ffffff' -fill '#172033' -gravity center -pointsize 48 -annotate +0+0 'ABC123' $reference
    $exact=Join-Path $fixture 'SKU-ABC123\主图副本.png';Copy-Item -LiteralPath $reference -Destination $exact
    $resized=Join-Path $fixture '调整尺寸.jpg';& $magick $reference -resize 320x180 -quality 82 $resized
    $webp=Join-Path $fixture '调整尺寸.webp';& $magick $reference -resize 320x180 -quality 82 $webp
    $other=Join-Path $fixture '其他图片.png';& $magick -size 320x180 xc:blue $other

    $number=Invoke-Search number 'ABC123' ''
    if(@($number.Results).Count -lt 2){throw '编号搜索没有匹配文件夹名和文件名。'}
    $folderSearch=Invoke-Search number 'LZ-CJ009' ''
    $folderResult=$folderSearch.Results|Where-Object Path -eq (Join-Path $fixture 'LZ-CJ009')|Select-Object -First 1
    if(-not$folderResult -or -not$folderResult.IsDirectory -or $folderResult.Kind -ne '文件夹'){throw '编号搜索没有返回匹配的空文件夹。'}
    $lockedProgress=Invoke-SearchWithLockedProgress 'LZ-CJ009'
    if(-not$lockedProgress.Success -or @($lockedProgress.Results).Count -lt 1){throw '进度文件被界面占用时搜索被中断。'}
    $image=Invoke-Search image '' $reference 0.88
    $paths=@($image.Results|ForEach-Object Path)
    if($exact -notin $paths){throw '图片搜索没有找到完全相同文件。'}
    if($resized -notin $paths){throw '图片搜索没有找到调整尺寸和压缩后的同图。'}
    if($webp -notin $paths){throw '图片搜索没有找到 WebP 格式的同图。'}
    if($other -in $paths){throw '图片搜索错误匹配无关图片。'}
    $exactResult=$image.Results|Where-Object Path -eq $exact|Select-Object -First 1
    if(-not$exactResult.Exact -or [double]$exactResult.Similarity -ne 100){throw '完全一致标记不正确。'}
    Write-Host 'PASS: folder and file path matching, locked progress recovery, exact hashing, resized/recompressed and WebP similarity search.'
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue}}

$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$worker=Join-Path $root 'modules\LocalSearchWorker.ps1'
$magick=Join-Path $root 'tools\imagemagick\magick.exe'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('PngToJpg_SearchCache_'+[Guid]::NewGuid().ToString('N'))
$images=Join-Path $fixture 'images';$cachePath=Join-Path $fixture 'feature-cache.json'
[void][IO.Directory]::CreateDirectory($images)

function Invoke-CachedSearch([string]$RunName){
    $jobRoot=Join-Path $fixture $RunName;[void][IO.Directory]::CreateDirectory($jobRoot)
    $jobPath=Join-Path $jobRoot 'job.json';$resultPath=Join-Path $jobRoot 'result.json'
    $job=[ordered]@{Root=$images;Mode='image';Query='';ReferencePath=$reference;Threshold=0.85;MaximumResults=200;ProgressPath=(Join-Path $jobRoot 'progress.json');ResultPath=$resultPath;MagickPath=$magick;FeatureCachePath=$cachePath}
    [IO.File]::WriteAllText($jobPath,($job|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $watch=[Diagnostics.Stopwatch]::StartNew();& ([Environment]::ProcessPath) -NoLogo -NoProfile -File $worker -JobPath $jobPath;$watch.Stop()
    $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not$result.Success){throw [string]$result.Error}
    return [PSCustomObject]@{ElapsedMs=$watch.ElapsedMilliseconds;Count=@($result.Results).Count}
}

try{
    $reference=Join-Path $fixture 'reference.png'
    & $magick -size 900x600 gradient:'#ff5e36-#ffffff' -fill '#172033' -gravity center -pointsize 72 -annotate +0+0 'CACHE' $reference
    $variant=Join-Path $fixture 'variant.jpg';& $magick $reference -resize 600x400 -quality 82 $variant
    1..160|ForEach-Object{Copy-Item -LiteralPath $variant -Destination (Join-Path $images ('variant-{0:D3}.jpg'-f $_))}
    $cold=Invoke-CachedSearch 'cold';if(-not(Test-Path -LiteralPath $cachePath) -or $cold.Count -ne 160){throw 'Cold search did not create a complete feature cache.'}
    $warm=Invoke-CachedSearch 'warm';if($warm.Count -ne $cold.Count){throw 'Cached search changed result accuracy.'}
    if($warm.ElapsedMs -ge $cold.ElapsedMs*.75){throw "Cached search was not materially faster: cold $($cold.ElapsedMs) ms, warm $($warm.ElapsedMs) ms."}
    & $magick -size 600x400 xc:blue (Join-Path $images 'variant-160.jpg')
    $changed=Invoke-CachedSearch 'changed';if($changed.Count -ne 159){throw 'Changed image did not invalidate its cached feature.'}
    Write-Host ('PASS: similarity feature cache preserved {0} matches; cold {1:N0} ms, warm {2:N0} ms.'-f $warm.Count,$cold.ElapsedMs,$warm.ElapsedMs)
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue}}

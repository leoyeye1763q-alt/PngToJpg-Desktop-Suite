$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$worker=Join-Path $root 'modules\LocalSearchWorker.ps1'
$magick=Join-Path $root 'tools\imagemagick\magick.exe'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('PngToJpg_SearchPerf_'+[Guid]::NewGuid().ToString('N'))
$images=Join-Path $fixture 'images';$other=Join-Path $fixture 'documents';$jobRoot=Join-Path $fixture 'job'
[void][IO.Directory]::CreateDirectory($images);[void][IO.Directory]::CreateDirectory($other);[void][IO.Directory]::CreateDirectory($jobRoot)

try{
    $reference=Join-Path $fixture 'reference.png'
    & $magick -size 800x600 gradient:'#ff5e36-#ffffff' -fill '#172033' -gravity center -pointsize 64 -annotate +0+0 'SEARCH' $reference
    if($LASTEXITCODE -ne 0){throw 'Fixture image creation failed'}
    1..220|ForEach-Object{Copy-Item -LiteralPath $reference -Destination (Join-Path $images ('same-{0:D3}.png'-f $_))}
    1..1500|ForEach-Object{[IO.File]::WriteAllText((Join-Path $other ('item-{0:D4}.txt'-f $_)),'fixture')}

    $jobPath=Join-Path $jobRoot 'job.json';$progressPath=Join-Path $jobRoot 'progress.json';$resultPath=Join-Path $jobRoot 'result.json'
    $job=[ordered]@{Root=$fixture;Mode='image';Query='';ReferencePath=$reference;Threshold=1.0;MaximumResults=200;ProgressPath=$progressPath;ResultPath=$resultPath;MagickPath=$magick}
    [IO.File]::WriteAllText($jobPath,($job|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[Environment]::ProcessPath;$start.UseShellExecute=$false
    foreach($argument in @('-NoLogo','-NoProfile','-File',$worker,'-JobPath',$jobPath)){[void]$start.ArgumentList.Add($argument)}
    $watch=[Diagnostics.Stopwatch]::StartNew();$process=[Diagnostics.Process]::Start($start);$liveProgressSeen=$false
    while(-not $process.HasExited -and $watch.ElapsedMilliseconds -lt 15000){
        Start-Sleep -Milliseconds 100
        if(Test-Path -LiteralPath $progressPath){try{$progress=Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8|ConvertFrom-Json;if([int]$progress.Scanned -gt 0){$liveProgressSeen=$true}}catch{}}
    }
    if(-not $process.HasExited){$process.Kill($true);throw 'Search exceeded 15 seconds'}
    if($process.ExitCode -ne 0){throw 'Search worker failed'}
    if(-not $liveProgressSeen){throw 'No live scan progress was published'}
    $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
    if(-not$result.Success -or @($result.Results).Count -ne 200){throw 'Expected result cap was not preserved'}
    $previewCount=@($result.Results|Where-Object Preview).Count
    if($previewCount -gt 60){throw "Too many previews generated: $previewCount"}
    Write-Host ('PASS: streamed 1,721 files, capped 200 results and generated {0} previews in {1:N0} ms.'-f $previewCount,$watch.ElapsedMilliseconds)
}finally{
    if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue}
}

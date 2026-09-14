function Initialize-ImageLink([string]$Endpoint = '') {
    $migratePostimagesConfig=$false
    $script:imageLink = [ordered]@{
        Endpoint=$Endpoint; Path=''; Name=''; Status='请选择或拖入一张图片'; Busy=$false; Progress=0
        Resize=$false; Width=1600; Height=1600; KeepRatio=$true
        AccountId=''; Bucket=''; PublicBaseUrl=''; ProtectedAccessKey=''; ProtectedSecretKey=''
        UsageMonth=(Get-Date -Format 'yyyy-MM'); UploadCount=0; UploadedBytes=[long]0
        StorageLimitBytes=[long](8GB); MonthlyUploadLimit=10000; SingleFileLimitBytes=[long](20MB)
        Result=$null; Task=$null; Client=$null; Content=$null; Stream=$null; Cancellation=$null
        UploadPath=''; TempPath=''; PendingBytes=[long]0; PendingPublicUrl=''
    }
    $configPath = Join-Path $script:dataDirectory 'image-link.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
            $migratePostimagesConfig=$saved.Contains('ProtectedKey')
            foreach ($key in @('Resize','Width','Height','KeepRatio','AccountId','Bucket','PublicBaseUrl','ProtectedAccessKey','ProtectedSecretKey','UsageMonth','UploadCount','UploadedBytes')) {
                if ($saved.Contains($key)) { $script:imageLink[$key] = $saved[$key] }
            }
        } catch { Write-Warning '图片链接设置读取失败，将使用默认值。' }
    }
    Reset-ImageLinkMonthlyUsage
    if($migratePostimagesConfig){Save-ImageLinkSettings}
}

function Reset-ImageLinkMonthlyUsage {
    $month = Get-Date -Format 'yyyy-MM'
    if ($script:imageLink.UsageMonth -ne $month) {
        $script:imageLink.UsageMonth = $month
        $script:imageLink.UploadCount = 0
        Save-ImageLinkSettings
    }
}

function Remove-ImageLinkPasteArtifacts([string]$Value) {
    if([string]::IsNullOrEmpty($Value)){return ''}
    return ($Value -replace '[\s\u200B-\u200D\u2060\uFEFF]','').Trim()
}

function Resolve-ImageLinkAccountId([string]$Value) {
    $clean=Remove-ImageLinkPasteArtifacts $Value
    if($clean -match '^[a-fA-F0-9]{32}$'){return $clean.ToLowerInvariant()}
    $match=[regex]::Match($Value,'(?i)(?<![0-9a-f])([0-9a-f]{32})(?![0-9a-f])')
    if($match.Success){return $match.Groups[1].Value.ToLowerInvariant()}
    throw "无法识别 Cloudflare 账户 ID。请粘贴 32 位 Account ID，或直接粘贴包含该 ID 的 Cloudflare 页面地址（清理后检测到 $($clean.Length) 个字符）。"
}

function Save-ImageLinkSettings(
    [string]$AccountId='', [string]$Bucket='', [string]$PublicBaseUrl='',
    [string]$AccessKey='', [string]$SecretKey='', [switch]$ClearCredentials
) {
    $accountClean=if($AccountId.Trim()){if($script:imageLink.Endpoint){Remove-ImageLinkPasteArtifacts $AccountId}else{Resolve-ImageLinkAccountId $AccountId}}else{''}
    $bucketClean=($Bucket -replace '[\u200B-\u200D\u2060\uFEFF]','').Trim()
    $publicUrlClean=($PublicBaseUrl -replace '[\u200B-\u200D\u2060\uFEFF]','').Trim().TrimEnd('/')
    $accessKeyClean=Remove-ImageLinkPasteArtifacts $AccessKey
    $secretKeyClean=Remove-ImageLinkPasteArtifacts $SecretKey
    if($bucketClean -and $bucketClean -notmatch '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'){throw 'R2 存储桶名称格式不正确，请只填写存储桶名称。'}
    if($publicUrlClean){try{$publicUri=[Uri]$publicUrlClean}catch{throw 'R2 公开网址格式不正确。'};if($publicUri.Scheme -ne 'https'){throw 'R2 公开网址必须使用 HTTPS。'};if($publicUri.Host -like '*.r2.cloudflarestorage.com'){throw '这里需要填写公开网址（r2.dev 或自定义域名），不能填写 S3 API 端点。'}}
    if ($ClearCredentials) { $script:imageLink.ProtectedAccessKey=''; $script:imageLink.ProtectedSecretKey='' }
    if($accountClean){$script:imageLink.AccountId=$accountClean}
    if($bucketClean){$script:imageLink.Bucket=$bucketClean}
    if($publicUrlClean){$script:imageLink.PublicBaseUrl=$publicUrlClean}
    if($accessKeyClean){$script:imageLink.ProtectedAccessKey=ConvertFrom-SecureString (ConvertTo-SecureString $accessKeyClean -AsPlainText -Force)}
    if($secretKeyClean){$script:imageLink.ProtectedSecretKey=ConvertFrom-SecureString (ConvertTo-SecureString $secretKeyClean -AsPlainText -Force)}
    [void][IO.Directory]::CreateDirectory($script:dataDirectory)
    $saved = [ordered]@{
        Resize=[bool]$script:imageLink.Resize; Width=[int]$script:imageLink.Width; Height=[int]$script:imageLink.Height; KeepRatio=[bool]$script:imageLink.KeepRatio
        AccountId=[string]$script:imageLink.AccountId; Bucket=[string]$script:imageLink.Bucket; PublicBaseUrl=[string]$script:imageLink.PublicBaseUrl
        ProtectedAccessKey=[string]$script:imageLink.ProtectedAccessKey; ProtectedSecretKey=[string]$script:imageLink.ProtectedSecretKey
        UsageMonth=[string]$script:imageLink.UsageMonth; UploadCount=[int]$script:imageLink.UploadCount; UploadedBytes=[long]$script:imageLink.UploadedBytes
    }
    $path = Join-Path $script:dataDirectory 'image-link.json'
    [IO.File]::WriteAllText(($path+'.tmp'),($saved|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move(($path+'.tmp'),$path,$true)
}

function Set-ImageLinkOptions($Options) {
    if ($script:imageLink.Busy) { return }
    $script:imageLink.Resize=[bool]$Options.resize
    $script:imageLink.Width=[Math]::Clamp([int]$Options.width,1,10000)
    $script:imageLink.Height=[Math]::Clamp([int]$Options.height,1,10000)
    $script:imageLink.KeepRatio=[bool]$Options.keepRatio
    Save-ImageLinkSettings
}

function Test-ImageLinkConfiguration {
    return [bool]($script:imageLink.AccountId -and $script:imageLink.Bucket -and $script:imageLink.PublicBaseUrl -and $script:imageLink.ProtectedAccessKey -and $script:imageLink.ProtectedSecretKey)
}

function Test-ImageLinkLimitReached([long]$AdditionalBytes=0) {
    Reset-ImageLinkMonthlyUsage
    return $script:imageLink.UploadCount -ge $script:imageLink.MonthlyUploadLimit -or ($script:imageLink.UploadedBytes+$AdditionalBytes) -gt $script:imageLink.StorageLimitBytes
}

function Add-ImageLinkImage([string]$Path) {
    if ($script:imageLink.Busy -or [string]::IsNullOrWhiteSpace($Path)) { return }
    $fullPath=[IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw '图片文件不存在。' }
    if ([IO.Path]::GetExtension($fullPath).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.jfif','.webp','.bmp','.gif','.tif','.tiff','.avif')) { throw '请选择常见图片文件。' }
    if ((Get-Item -LiteralPath $fullPath).Length -gt $script:imageLink.SingleFileLimitBytes) { throw '免费额度保护：单张图片最大 20 MB。' }
    $script:imageLink.Path=$fullPath; $script:imageLink.Name=[IO.Path]::GetFileName($fullPath)
    $script:imageLink.Status=if(Test-ImageLinkLimitReached){'免费额度已用完，不可继续使用'}else{'图片已就绪，等待上传'}
    $script:imageLink.Progress=0; $script:imageLink.Result=$null
}

function Clear-ImageLinkImage {
    if ($script:imageLink.Busy) { return }
    $script:imageLink.Path=''; $script:imageLink.Name=''; $script:imageLink.Progress=0; $script:imageLink.Result=$null
    $script:imageLink.Status=if(Test-ImageLinkLimitReached){'免费额度已用完，不可继续使用'}else{'请选择或拖入一张图片'}
}

function Get-ImageLinkContentType([string]$Path) {
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.png' {'image/png'}; {$_ -in @('.jpg','.jpeg','.jfif')} {'image/jpeg'}; '.webp' {'image/webp'}; '.gif' {'image/gif'}
        '.bmp' {'image/bmp'}; {$_ -in @('.tif','.tiff')} {'image/tiff'}; '.avif' {'image/avif'}; default {'application/octet-stream'}
    }
}

function Get-ImageLinkSha256Hex([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-ImageLinkHmacBytes([byte[]]$Key,[string]$Value) {
    $hmac=[Security.Cryptography.HMACSHA256]::new($Key)
    try { $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) } finally { $hmac.Dispose() }
}

function New-ImageLinkR2Authorization([string]$AccessKey,[string]$SecretKey,[Uri]$Uri,[string]$ContentType,[string]$PayloadHash,[DateTime]$Timestamp) {
    $amzDate=$Timestamp.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'); $date=$Timestamp.ToUniversalTime().ToString('yyyyMMdd')
    $canonicalHeaders="content-type:$ContentType`nhost:$($Uri.Authority.ToLowerInvariant())`nx-amz-content-sha256:$PayloadHash`nx-amz-date:$amzDate`n"
    $signedHeaders='content-type;host;x-amz-content-sha256;x-amz-date'
    $canonicalRequest="PUT`n$($Uri.AbsolutePath)`n`n$canonicalHeaders`n$signedHeaders`n$PayloadHash"
    $scope="$date/auto/s3/aws4_request"
    $stringToSign="AWS4-HMAC-SHA256`n$amzDate`n$scope`n$(Get-ImageLinkSha256Hex ([Text.Encoding]::UTF8.GetBytes($canonicalRequest)))"
    $dateKey=Get-ImageLinkHmacBytes ([Text.Encoding]::UTF8.GetBytes("AWS4$SecretKey")) $date
    $regionKey=Get-ImageLinkHmacBytes $dateKey 'auto'; $serviceKey=Get-ImageLinkHmacBytes $regionKey 's3'; $signingKey=Get-ImageLinkHmacBytes $serviceKey 'aws4_request'
    $signature=([BitConverter]::ToString((Get-ImageLinkHmacBytes $signingKey $stringToSign))).Replace('-','').ToLowerInvariant()
    [ordered]@{AmzDate=$amzDate;Authorization="AWS4-HMAC-SHA256 Credential=$AccessKey/$scope, SignedHeaders=$signedHeaders, Signature=$signature"}
}

function ConvertTo-ImageLinkResult([string]$Direct,[string]$FileName) {
    $safeName=[IO.Path]::GetFileName($FileName).Replace('[','').Replace(']','')
    [ordered]@{
        Link=$Direct; Direct=$Direct; Markdown="[$safeName]($Direct)"; ImageMarkdown="![$safeName]($Direct)"
        ForumThumbnail="[url=$Direct][img]$Direct[/img][/url]"; WebsiteThumbnail="<a href='$Direct' target='_blank'><img src='$Direct' alt='$safeName'></a>"
        ForumHotlink="[url=$Direct][img]$Direct[/img][/url]"; WebsiteHotlink="<a href='$Direct' target='_blank'><img src='$Direct' alt='$safeName'></a>"; Delete=''
    }
}

function Stop-ImageLinkRequest([switch]$Cancelled) {
    if ($Cancelled -and $script:imageLink.Cancellation) { try{$script:imageLink.Cancellation.Cancel()}catch{} }
    foreach($item in @($script:imageLink.Content,$script:imageLink.Stream,$script:imageLink.Client,$script:imageLink.Cancellation)){if($item){try{$item.Dispose()}catch{}}}
    if($script:imageLink.TempPath -and (Test-Path -LiteralPath $script:imageLink.TempPath)){try{Remove-Item -LiteralPath $script:imageLink.TempPath -Force}catch{}}
    $script:imageLink.Task=$null; $script:imageLink.Client=$null; $script:imageLink.Content=$null; $script:imageLink.Stream=$null; $script:imageLink.Cancellation=$null
    $script:imageLink.UploadPath=''; $script:imageLink.TempPath=''; $script:imageLink.PendingBytes=[long]0; $script:imageLink.PendingPublicUrl=''; $script:imageLink.Busy=$false
}

function Start-ImageLinkUpload {
    if($script:imageLink.Busy){return}; if(-not $script:imageLink.Path){throw '请先选择一张图片。'}
    if(-not(Test-ImageLinkConfiguration)){throw '请先填写并保存完整的 Cloudflare R2 配置。'}
    if(Test-ImageLinkLimitReached){throw '免费额度已用完，不可继续使用。'}
    $uploadPath=$script:imageLink.Path
    if($script:imageLink.Resize){
        $tempDirectory=Join-Path ([IO.Path]::GetTempPath()) 'PngToJpg-ImageLink'; [void][IO.Directory]::CreateDirectory($tempDirectory)
        $tempPath=Join-Path $tempDirectory (([Guid]::NewGuid().ToString('N'))+[IO.Path]::GetExtension($uploadPath))
        $geometry=if($script:imageLink.KeepRatio){"{0}x{1}>" -f $script:imageLink.Width,$script:imageLink.Height}else{"{0}x{1}!" -f $script:imageLink.Width,$script:imageLink.Height}
        & $script:magickPath $uploadPath -auto-orient -resize $geometry $tempPath
        if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $tempPath)){throw '上传前调整尺寸失败。'}
        $uploadPath=$tempPath; $script:imageLink.TempPath=$tempPath
    }
    $file=Get-Item -LiteralPath $uploadPath
    if($file.Length -gt $script:imageLink.SingleFileLimitBytes){throw '免费额度保护：处理后的图片仍超过 20 MB。'}
    if(Test-ImageLinkLimitReached $file.Length){throw '免费额度已用完，不可继续使用。'}
    $accessKey=[Net.NetworkCredential]::new('',(ConvertTo-SecureString $script:imageLink.ProtectedAccessKey)).Password
    $secretKey=[Net.NetworkCredential]::new('',(ConvertTo-SecureString $script:imageLink.ProtectedSecretKey)).Password
    $extension=[IO.Path]::GetExtension($uploadPath).ToLowerInvariant(); $objectKey='images/{0}/{1}{2}' -f (Get-Date -Format 'yyyy/MM'),([Guid]::NewGuid().ToString('N')),$extension
    $baseEndpoint=if($script:imageLink.Endpoint){$script:imageLink.Endpoint.TrimEnd('/')}else{"https://$($script:imageLink.AccountId).r2.cloudflarestorage.com"}
    $uri=[Uri]("$baseEndpoint/$($script:imageLink.Bucket)/$objectKey"); $directUrl="$($script:imageLink.PublicBaseUrl.TrimEnd('/'))/$objectKey"
    $contentType=Get-ImageLinkContentType $uploadPath; $payloadHash=(Get-FileHash -LiteralPath $uploadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $signature=New-ImageLinkR2Authorization $accessKey $secretKey $uri $contentType $payloadHash ([DateTime]::UtcNow)
    $client=[Net.Http.HttpClient]::new(); $client.Timeout=[TimeSpan]::FromSeconds(120); $stream=[IO.File]::OpenRead($uploadPath); $content=[Net.Http.StreamContent]::new($stream)
    $content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new($contentType); $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put,$uri); $request.Content=$content; $request.Headers.Host=$uri.Authority
    [void]$request.Headers.TryAddWithoutValidation('x-amz-content-sha256',$payloadHash); [void]$request.Headers.TryAddWithoutValidation('x-amz-date',$signature.AmzDate); [void]$request.Headers.TryAddWithoutValidation('Authorization',$signature.Authorization)
    $cancellation=[Threading.CancellationTokenSource]::new(); $script:imageLink.Client=$client; $script:imageLink.Content=$content; $script:imageLink.Stream=$stream; $script:imageLink.Cancellation=$cancellation
    $script:imageLink.UploadPath=$uploadPath; $script:imageLink.PendingBytes=[long]$file.Length; $script:imageLink.PendingPublicUrl=$directUrl; $script:imageLink.Task=$client.SendAsync($request,$cancellation.Token)
    $script:imageLink.Busy=$true; $script:imageLink.Progress=45; $script:imageLink.Status='正在上传到 Cloudflare R2（免费额度保护中）…'
}

function Poll-ImageLinkUpload {
    if(-not $script:imageLink.Busy -or -not $script:imageLink.Task -or -not $script:imageLink.Task.IsCompleted){return}
    try{
        $response=$script:imageLink.Task.GetAwaiter().GetResult(); $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if(-not $response.IsSuccessStatusCode){$detail=if($body.Trim()){'：'+(($body-replace'<[^>]+>',' '-replace'\s+',' ').Trim())}else{''};throw "R2 上传失败：HTTP $([int]$response.StatusCode)$detail"}
        $directUrl=[string]$script:imageLink.PendingPublicUrl; $pendingBytes=[long]$script:imageLink.PendingBytes
        $script:imageLink.Result=ConvertTo-ImageLinkResult $directUrl $script:imageLink.Name; $script:imageLink.UploadCount=[int]$script:imageLink.UploadCount+1; $script:imageLink.UploadedBytes=[long]$script:imageLink.UploadedBytes+$pendingBytes
        Save-ImageLinkSettings; $script:imageLink.Progress=100; $script:imageLink.Status='上传完成，永久 HTTPS 直链已生成'
    }catch{if($_.Exception -is [OperationCanceledException]){$script:imageLink.Status='上传已取消'}else{$script:imageLink.Status='上传失败：'+$_.Exception.Message};$script:imageLink.Progress=0}finally{Stop-ImageLinkRequest}
}

function Get-ImageLinkWebState {
    Reset-ImageLinkMonthlyUsage
    $remainingBytes=[Math]::Max([long]0,([long]$script:imageLink.StorageLimitBytes-[long]$script:imageLink.UploadedBytes)); $remainingUploads=[Math]::Max(0,([int]$script:imageLink.MonthlyUploadLimit-[int]$script:imageLink.UploadCount))
    [ordered]@{
        name=[string]$script:imageLink.Name; path=[string]$script:imageLink.Path; status=[string]$script:imageLink.Status; busy=[bool]$script:imageLink.Busy; progress=[int]$script:imageLink.Progress
        resize=[bool]$script:imageLink.Resize; width=[int]$script:imageLink.Width; height=[int]$script:imageLink.Height; keepRatio=[bool]$script:imageLink.KeepRatio
        accountId=[string]$script:imageLink.AccountId; bucket=[string]$script:imageLink.Bucket; publicBaseUrl=[string]$script:imageLink.PublicBaseUrl
        hasCredentials=[bool]($script:imageLink.ProtectedAccessKey -and $script:imageLink.ProtectedSecretKey); hasConfig=[bool](Test-ImageLinkConfiguration); limitReached=[bool](Test-ImageLinkLimitReached)
        uploadCount=[int]$script:imageLink.UploadCount; monthlyUploadLimit=[int]$script:imageLink.MonthlyUploadLimit; uploadedBytes=[long]$script:imageLink.UploadedBytes; storageLimitBytes=[long]$script:imageLink.StorageLimitBytes
        remainingBytes=[long]$remainingBytes; remainingUploads=[int]$remainingUploads; result=$script:imageLink.Result
    }
}

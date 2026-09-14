$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$script:dataDirectory=Join-Path ([IO.Path]::GetTempPath()) ('PngToJpg_ImageLinkTest_'+[Guid]::NewGuid().ToString('N'))
$script:magickPath=Join-Path $root 'tools\imagemagick\magick.exe'
. (Join-Path $root 'modules\ImageLink.ps1')
try {
    $expectedAccountId='cf520ab28be0d68f568b3a654bcfda7a'
    $dirtyAccountId=([char]0x200B)+'  cf520ab28be0d68f568b3a654bcfda7a  '+"`r`n"
    if((Resolve-ImageLinkAccountId $dirtyAccountId) -ne $expectedAccountId){throw '账户 ID 粘贴清理失败。'}
    $dashboardUrl="https://dash.cloudflare.com/$expectedAccountId/r2/default/buckets"
    if((Resolve-ImageLinkAccountId $dashboardUrl) -ne $expectedAccountId){throw 'Cloudflare 页面地址中的账户 ID 提取失败。'}
    try { Resolve-ImageLinkAccountId 'not-an-account-id'; throw '无效账户 ID 未被拒绝。' } catch { if($_.Exception.Message -notmatch '清理后检测到'){throw} }

    [void][IO.Directory]::CreateDirectory($script:dataDirectory)
    [IO.File]::WriteAllText((Join-Path $script:dataDirectory 'image-link.json'),'{"Resize":false,"ProtectedKey":"legacy-postimages-key"}',[Text.UTF8Encoding]::new($false))
    Initialize-ImageLink -Endpoint 'http://127.0.0.1:38197'
    if((Get-Content (Join-Path $script:dataDirectory 'image-link.json') -Raw).Contains('ProtectedKey')){throw '旧 Postimages 配置未安全移除。'}
    $image=Join-Path $script:dataDirectory 'fixture.png'
    & $script:magickPath -size 40x30 'xc:#ff5e36' $image
    Add-ImageLinkImage $image
    Set-ImageLinkOptions @{resize=$true;width=20;height=20;keepRatio=$true}
    Save-ImageLinkSettings -AccountId 'test-account' -Bucket 'amazon-images' -PublicBaseUrl 'https://pub-example.r2.dev' -AccessKey 'local-access-key' -SecretKey 'local-secret-key'
    $settings=Get-Content (Join-Path $script:dataDirectory 'image-link.json') -Raw
    if($settings.Contains('local-access-key') -or $settings.Contains('local-secret-key')){throw 'R2 凭证未加密保存。'}
    if(-not(Test-ImageLinkConfiguration)){throw 'R2 配置状态错误。'}
    $parsed=ConvertTo-ImageLinkResult 'https://pub-example.r2.dev/images/test.png' 'test.png'
    if($parsed.Direct -ne 'https://pub-example.r2.dev/images/test.png' -or $parsed.ImageMarkdown -notmatch '^!\[test.png\]'){throw '链接结果生成失败。'}
    if($parsed.PSObject.Properties.Name -contains 'Email'){throw '结果中不应包含邮箱代码。'}

    $listener=[Net.HttpListener]::new();$listener.Prefixes.Add('http://127.0.0.1:38197/');$listener.Start()
    try {
        $requestTask=$listener.GetContextAsync();Start-ImageLinkUpload
        if(-not $requestTask.Wait(10000)){throw '本地模拟 R2 上传未收到请求。'}
        $context=$requestTask.Result
        if($context.Request.HttpMethod -ne 'PUT' -or $context.Request.RawUrl -notmatch '^/amazon-images/images/'){throw 'R2 PUT 路径错误。'}
        if($context.Request.Headers['Authorization'] -notmatch '^AWS4-HMAC-SHA256 Credential=local-access-key/' -or -not $context.Request.Headers['x-amz-content-sha256']){throw 'R2 SigV4 请求头缺失。'}
        $reader=[IO.StreamReader]::new($context.Request.InputStream);try{$requestBody=$reader.ReadToEnd()}finally{$reader.Dispose()}
        if(-not $requestBody){throw 'R2 上传正文为空。'}
        $context.Response.StatusCode=200;$context.Response.Close()
        $deadline=[DateTime]::UtcNow.AddSeconds(10)
        while($script:imageLink.Busy -and [DateTime]::UtcNow -lt $deadline){Poll-ImageLinkUpload;Start-Sleep -Milliseconds 20}
        if($script:imageLink.Busy -or $script:imageLink.Result.Direct -notmatch '^https://pub-example\.r2\.dev/images/'){throw '本地模拟 R2 上传未完成。'}
        if($script:imageLink.UploadCount -ne 1 -or $script:imageLink.UploadedBytes -le 0){throw '免费额度计数未更新。'}
    } finally {$listener.Stop();$listener.Close()}

    $script:imageLink.UploadCount=$script:imageLink.MonthlyUploadLimit
    try { Start-ImageLinkUpload; throw '月上传上限没有阻止上传。' } catch { if($_.Exception.Message -notmatch '免费额度已用完'){throw} }
    $script:imageLink.UploadCount=0;$script:imageLink.UploadedBytes=$script:imageLink.StorageLimitBytes
    try { Start-ImageLinkUpload; throw '存储上限没有阻止上传。' } catch { if($_.Exception.Message -notmatch '免费额度已用完'){throw} }
    Write-Host 'R2 account ID cleanup, encryption, SigV4 PUT, permanent link and free-quota hard stop: passed.'
} finally {
    if(Test-Path -LiteralPath $script:dataDirectory){Remove-Item -LiteralPath $script:dataDirectory -Recurse -Force}
}

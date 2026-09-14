Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $appRoot 'modules/ImageApi.ps1')
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ImageApiTest_' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$source = Join-Path $testRoot 'source.png'
& (Join-Path $appRoot 'tools/imagemagick/magick.exe') -size 16x12 xc:blue $source
if ($LASTEXITCODE) { throw 'Fixture creation failed.' }
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
$server = Start-Job -ArgumentList $port, $source, $testRoot -ScriptBlock {
    param($Port, $Source, $Root)
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$Port/"); $listener.Start()
    [IO.File]::WriteAllText((Join-Path $Root 'ready'), 'ready')
    $bytes = [IO.File]::ReadAllBytes($Source)
    $encoded = [Convert]::ToBase64String($bytes)
    try {
        while ($true) {
            $pending = $listener.GetContextAsync()
            while (-not $pending.IsCompleted) { Start-Sleep -Milliseconds 25 }
            $context = $pending.GetAwaiter().GetResult()
            $route = $context.Request.Url.AbsolutePath.Trim('/')
            $reader = [IO.StreamReader]::new($context.Request.InputStream)
            $body = $reader.ReadToEnd(); $reader.Dispose()
            @{ Body = $body; Auth = $context.Request.Headers['Authorization']; GoogleAuth = $context.Request.Headers['x-goog-api-key']; ContentType = $context.Request.ContentType } |
                ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Root ($route + '.json'))
            $context.Response.ContentType = 'application/json'
            $data = switch ($route) {
                'gemini' { @{ candidates = @(@{ content = @{ parts = @(@{ text = 'done' }, @{ inlineData = @{ data = $encoded }; thought = $true }, @{ inlineData = @{ data = $encoded } }) } }) } }
                'interactions' { @{ steps = @(@{ type = 'model_output'; content = @(@{ type = 'text'; text = 'done' }, @{ type = 'image'; data = $encoded }) }) } }
                'url' { @{ data = @(@{ url = "http://localhost:$Port/download" }) } }
                'error' { $context.Response.StatusCode = 401; @{ error = 'sensitive-server-detail' } }
                'text' { @{ candidates = @(@{ content = @{ parts = @(@{ text = 'no image' }) } }) } }
                'custom' { @{ result = @{ image = $encoded } } }
                'business-error' { @{ error = @{ message = 'sensitive-server-detail' } } }
                default { @{ data = @(@{ b64_json = $encoded }) } }
            }
            if ($route -in @('binary', 'download')) { $payload = $bytes; $context.Response.ContentType = 'image/png' }
            else { $payload = [Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Depth 16 -Compress)) }
            $context.Response.ContentLength64 = $payload.Length
            $context.Response.OutputStream.Write($payload, 0, $payload.Length)
            $context.Response.Close()
        }
    } finally { $listener.Close() }
}
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path (Join-Path $testRoot 'ready'))) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Mock server startup timed out.' }
        Start-Sleep -Milliseconds 50
    }
    foreach ($case in @(@('OpenAI Images','openai'), @('Gemini','gemini'), @('Gemini Interactions','interactions'), @('JSON','json'), @('Multipart','multipart'), @('Binary','binary'))) {
        $config = New-ImageApiConfig
        $config.Protocol = $case[0]; $config.Endpoint = "http://localhost:$port/$($case[1])"
        $config.ProtectedKey = ConvertFrom-SecureString (ConvertTo-SecureString 'test-only-key' -AsPlainText -Force)
        if ($config.Protocol -like 'Gemini*') { $config.AuthHeader = 'x-goog-api-key'; $config.AuthPrefix = '' }
        if ($config.Protocol -eq 'Binary') { $config.ResponseType = 'binary' }
        $destination = Join-Path $testRoot ($case[1] + '.png')
        Invoke-ImageApi $config $source $destination
        Assert-True ((Get-FileHash $source).Hash -eq (Get-FileHash $destination).Hash) "$($case[0]) result differs"
        $request = Get-Content (Join-Path $testRoot ($case[1] + '.json')) -Raw | ConvertFrom-Json
        if ($config.Protocol -eq 'OpenAI Images') {
            Assert-True ($request.Body.Contains('gpt-image-2') -and $request.Body.Contains('name=image') -and $request.Body.Contains('name=prompt')) 'OpenAI multipart fields missing'
        }
        if ($config.Protocol -eq 'Gemini') {
            $body = $request.Body | ConvertFrom-Json
            Assert-True ($body.contents[0].parts[1].inlineData.data -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))) 'Gemini input image missing'
            Assert-True ($request.GoogleAuth -eq 'test-only-key') 'Gemini auth missing'
        }
        Write-Host "$($case[0]): passed"
    }
    $config = New-ImageApiConfig
    $config.Endpoint = "http://localhost:$port/url"; $config.ResponseType = 'url'; $config.ResponsePath = 'data.0.url'
    $config.ProtectedKey = ConvertFrom-SecureString (ConvertTo-SecureString 'test-only-key' -AsPlainText -Force)
    Invoke-ImageApi $config $source (Join-Path $testRoot 'url.png')
    $downloadRequest = Get-Content (Join-Path $testRoot 'download.json') -Raw | ConvertFrom-Json
    Assert-True ([string]::IsNullOrEmpty($downloadRequest.Auth)) 'API credential leaked to download'
    $config.ResponseType = 'base64'; $config.ResponsePath = 'data.0.b64_json'
    $fallbackPath = Join-Path $testRoot 'url-fallback.png'
    Invoke-ImageApi $config $source $fallbackPath
    Assert-True ((Get-FileHash $source).Hash -eq (Get-FileHash $fallbackPath).Hash) 'OpenAI URL fallback differs'
    Write-Host 'OpenAI standard URL fallback with base64 preference: passed'
    foreach ($route in @('error','text','business-error','custom')) {
        $config = New-ImageApiConfig; $config.Endpoint = "http://localhost:$port/$route"
        if ($route -eq 'text') { $config.Protocol = 'Gemini' }
        $failed = $false
        $diagnostics = Join-Path $testRoot ($route + '-diagnostics')
        try { Invoke-ImageApi $config $source (Join-Path $testRoot 'failure.png') -DiagnosticDirectory $diagnostics } catch {
            $failed = $true
            Assert-True (-not $_.Exception.Message.Contains('sensitive-server-detail')) 'Server error body leaked'
        }
        Assert-True $failed "$route should fail"
        $savedFiles = @(Get-ChildItem -LiteralPath $diagnostics -Filter '*.response.bin')
        Assert-True ($savedFiles.Count -eq 1) 'Failure response was not saved'
        $cipher = [IO.File]::ReadAllBytes($savedFiles[0].FullName)
        Assert-True (-not [Text.Encoding]::UTF8.GetString($cipher).Contains('sensitive-server-detail')) 'Raw response persisted without encryption'
        if ($route -eq 'custom') { $recoveryFile = $savedFiles[0].FullName }
        if ($route -eq 'error') {
            $rejected = $false
            try { Restore-ImageApiResponse $savedFiles[0].FullName (Join-Path $testRoot 'http-error.png') } catch { $rejected = $true }
            Assert-True $rejected 'HTTP error response incorrectly recovered'
        }
    }
    # Exercise the real background worker, validation and final format conversion.
    $config = New-ImageApiConfig; $config.Endpoint = "http://localhost:$port/openai"
    $jobConfig = @{
        Mode = 'API 大模型清晰'; SourcePath = $source; OutputPath = (Join-Path $testRoot 'worker.jpg'); OutputFormat = 'jpg'
        TempDirectory = $testRoot; ProgressPath = (Join-Path $testRoot 'progress.json'); ResultPath = (Join-Path $testRoot 'result.json')
        MagickPath = (Join-Path $appRoot 'tools/imagemagick/magick.exe'); ApiConfig = $config
        FinalWidth = 0; FinalHeight = 0; PreserveAlpha = $false; Background = '#FFFFFF'; Scale = 1
    }
    $jobPath = Join-Path $testRoot 'job.json'
    $jobConfig | ConvertTo-Json -Depth 12 | Set-Content $jobPath
    & pwsh -NoProfile -File (Join-Path $appRoot 'modules/ImageWorker.ps1') -JobPath $jobPath
    Assert-True ($LASTEXITCODE -eq 0) 'API worker failed'
    $result = Get-Content $jobConfig.ResultPath -Raw | ConvertFrom-Json
    Assert-True $result.Success 'API worker result unsuccessful'
    Stop-Job $server
    $recovered = Join-Path $testRoot 'recovered.png'
    & pwsh -NoProfile -File (Join-Path $appRoot 'tools/RestoreApiResponse.ps1') -ResponseFile $recoveryFile -OutputPath $recovered -ImageFieldPath 'result.image'
    Assert-True ($LASTEXITCODE -eq 0) 'Offline recovery CLI failed'
    Assert-True ((Get-FileHash $source).Hash -eq (Get-FileHash $recovered).Hash) 'Recovered image differs'
    $overwriteRejected = $false
    try { Restore-ImageApiResponse $recoveryFile $recovered -ImageFieldPath 'result.image' } catch { $overwriteRejected = $true }
    Assert-True $overwriteRejected 'Recovery overwrote an existing result'
    Write-Host 'Encrypted failure capture, HTTP/business errors and offline recovery without server: passed'
    Write-Host 'URL download, credential isolation, errors and API worker export: passed'
} finally {
    Stop-Job $server; Remove-Job $server -Force
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('ImageApiTest_')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

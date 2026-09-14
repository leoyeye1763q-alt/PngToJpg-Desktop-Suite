# Shared parser for live responses and recovery; never submits a generation request.
function Export-ImageApiResponse {
    param([System.Collections.IDictionary]$Config, [byte[]]$ResponseBytes, [string]$DestinationPath, [System.Net.Http.HttpClient]$Client)
    $download = $null
    try {
        if ($Config.ResponseType -eq 'binary') {
            $resultBytes = $ResponseBytes
        } else {
            $json = [Text.Encoding]::UTF8.GetString($ResponseBytes) | ConvertFrom-Json -AsHashtable
            if ($json -isnot [System.Collections.IDictionary]) { throw '响应不是预期的 JSON 对象。' }
            if ($json['error']) { throw '接口返回了业务错误，需检查已保存的响应；HTTP 成功不代表图片生成成功。' }
            $value = $null
            $responseType = $Config.ResponseType
            if ($Config.Protocol -eq 'Gemini') {
                foreach ($candidate in @($json['candidates'])) {
                    if (-not $candidate -or -not $candidate['content']) { continue }
                    foreach ($part in @($candidate['content']['parts'])) {
                        if ($part['inlineData'] -and -not $part['thought']) { $value = $part['inlineData']['data']; break }
                    }
                    if ($value) { break }
                }
            } elseif ($Config.Protocol -eq 'Gemini Interactions') {
                foreach ($step in @($json['steps'])) {
                    if (-not $step -or $step['type'] -ne 'model_output') { continue }
                    foreach ($part in @($step['content'])) {
                        if ($part['type'] -eq 'image') { $value = $part['data']; break }
                    }
                    if ($value) { break }
                }
            } elseif ($Config.Protocol -eq 'OpenAI Images' -and $Config.ResponsePath -in @('data.0.b64_json', 'data.0.url')) {
                # Compatible image services may return a URL even when base64 is preferred.
                # Only standard image fields are used; never treat arbitrary response text as an image URL.
                $entry = Get-ImageApiResponseValue $json 'data.0'
                if ($entry -is [System.Collections.IDictionary]) {
                    if ($entry['b64_json'] -is [string] -and -not [string]::IsNullOrWhiteSpace($entry['b64_json'])) {
                        $value = $entry['b64_json']; $responseType = 'base64'
                    } elseif ($entry['url'] -is [string] -and -not [string]::IsNullOrWhiteSpace($entry['url'])) {
                        $value = $entry['url']; $responseType = 'url'
                    }
                }
            } else { $value = Get-ImageApiResponseValue $json $Config.ResponsePath }
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { throw '响应图片字段不是有效字符串。' }
            if ($responseType -eq 'url') {
                # The download request intentionally carries no API credential.
                $download = $client.GetAsync((Assert-ImageApiUri $value)).GetAwaiter().GetResult()
                if (-not $download.IsSuccessStatusCode) { throw "结果图片下载失败（HTTP $([int]$download.StatusCode)）。" }
                $resultBytes = $download.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            } else {
                $resultBytes = [Convert]::FromBase64String(($value -replace '^data:image/[^;]+;base64,', ''))
            }
        }
        if ($resultBytes.Length -eq 0) { throw '接口返回了空图片。' }
        [IO.File]::WriteAllBytes($DestinationPath, $resultBytes)
    } finally { if ($download) { $download.Dispose() } }
}

function Save-ImageApiFailureResponse {
    param([System.Collections.IDictionary]$Config, [byte[]]$ResponseBytes, [int]$StatusCode, [string]$Directory)
    $record = @{
        Version = 1; StatusCode = $StatusCode; SavedAt = [DateTime]::UtcNow.ToString('o')
        # Keep only parsing preferences, never API credentials or submitted source/prompt.
        Config = @{ Protocol = $Config.Protocol; ResponseType = $Config.ResponseType; ResponsePath = $Config.ResponsePath }
        Body = [Convert]::ToBase64String($ResponseBytes)
    }
    $plain = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 8 -Compress))
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [void][IO.Directory]::CreateDirectory($Directory)
    $path = Join-Path $Directory (([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')) + '-' + [Guid]::NewGuid().ToString('N') + '.response.bin')
    [IO.File]::WriteAllBytes($path, $encrypted)
    return $path
}

function Restore-ImageApiResponse {
    param([string]$ResponseFile, [string]$DestinationPath, [string]$ImageFieldPath = '',
        [ValidateSet('', 'base64', 'url', 'binary')][string]$ResponseType = '')
    if (Test-Path -LiteralPath $DestinationPath) { throw '恢复输出文件已存在，请使用新文件名。' }
    $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($ResponseFile), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $record = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json -AsHashtable
    if ($record.Version -ne 1) { throw '不支持的失败响应文件版本。' }
    if ([int]$record.StatusCode -lt 200 -or [int]$record.StatusCode -ge 300) { throw '保存的是 HTTP 错误响应，无法直接恢复图片。' }
    $config = $record.Config
    if ($ImageFieldPath) { $config.Protocol = 'JSON'; $config.ResponsePath = $ImageFieldPath }
    if ($ResponseType) { $config.ResponseType = $ResponseType }
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(60)
    try {
        Export-ImageApiResponse $config ([Convert]::FromBase64String($record.Body)) $DestinationPath $client
    } finally { $client.Dispose() }
}

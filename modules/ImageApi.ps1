# Configurable synchronous HTTP image enhancement adapter. No provider-specific assumptions.
. (Join-Path $PSScriptRoot 'ImageApiResponse.ps1')
function New-ImageApiConfig {
    return @{
        Endpoint = 'https://api.openai.com/v1/images/edits'; Protocol = 'OpenAI Images'; AuthHeader = 'Authorization'; AuthPrefix = 'Bearer '
        ProtectedKey = ''; ImageField = 'image'; ImageEncoding = 'data-url'
        FieldsJson = '{}'; ResponseType = 'base64'; ResponsePath = 'data.0.b64_json'
        Model = 'gpt-image-2'; Prompt = '请基于原图提高图片清晰度，减少模糊和噪点。保持主体、构图、颜色、文字、Logo和背景一致，不新增或删除内容，返回处理后的图片。'
        TimeoutSeconds = 300
    }
}

function Assert-ImageApiUri {
    param([string]$Address)
    $uri = $null
    if (-not [Uri]::TryCreate($Address, [UriKind]::Absolute, [ref]$uri) -or
        ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback)) -or $uri.UserInfo) {
        throw '接口和结果地址必须使用 HTTPS（本机调试允许 HTTP），且不能在地址中包含用户名或密码。'
    }
    return $uri
}

function Test-ImageApiConfig {
    param([System.Collections.IDictionary]$Config)
    [void](Assert-ImageApiUri $Config.Endpoint)
    if ($Config.Protocol -notin @('OpenAI Images', 'Gemini', 'Gemini Interactions', 'JSON', 'Multipart', 'Binary')) { throw '不支持的请求格式。' }
    if ($Config.Protocol -in @('OpenAI Images', 'Gemini', 'Gemini Interactions') -and
        ([string]::IsNullOrWhiteSpace($Config.Model) -or [string]::IsNullOrWhiteSpace($Config.Prompt))) { throw '请填写模型名称和清晰化提示词。' }
    if ($Config.ResponseType -notin @('base64', 'url', 'binary')) { throw '不支持的返回格式。' }
    if ($Config.Protocol -in @('Gemini', 'Gemini Interactions') -and $Config.ResponseType -ne 'base64') { throw '不支持的返回格式：Gemini 使用 base64 图片。' }
    if ($Config.ImageEncoding -notin @('data-url', 'base64')) { throw '不支持的图片编码。' }
    if ([string]::IsNullOrWhiteSpace($Config.ImageField)) { throw '请填写图片字段名。' }
    if ($Config.AuthHeader -notmatch '^[A-Za-z0-9-]+$' -or $Config.AuthPrefix -match '[\r\n]') { throw '鉴权请求头格式不正确。' }
    if ([int]$Config.TimeoutSeconds -lt 10 -or [int]$Config.TimeoutSeconds -gt 1800) { throw '超时范围为 10–1800 秒。' }
    $fields = ConvertFrom-Json -InputObject $Config.FieldsJson -AsHashtable
    if ($fields -isnot [System.Collections.IDictionary]) { throw '附加参数必须是 JSON 对象。' }
    foreach ($reserved in @($Config.ImageField, 'model', 'prompt', 'contents', 'input', 'stream')) {
        if ($fields.Contains($reserved)) { throw "附加参数不能包含 $reserved 字段；请使用相应的配置项。" }
    }
    if ($Config.Protocol -eq 'Binary' -and $fields.Count -gt 0) { throw '附加参数不适用于原始二进制上传。' }
}

function Get-ImageApiResponseValue {
    param($Value, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Value }
    foreach ($part in $Path.Split('.')) {
        if ($Value -is [System.Collections.IDictionary] -and $Value.Contains($part)) { $Value = $Value[$part] }
        elseif ($Value -is [System.Collections.IList] -and $part -match '^\d+$' -and [int]$part -lt $Value.Count) { $Value = $Value[[int]$part] }
        else { throw '响应中找不到配置的图片路径，请检查接口返回格式。' }
    }
    return $Value
}

function Invoke-ImageApi {
    param([System.Collections.IDictionary]$Config, [string]$SourcePath, [string]$DestinationPath,
        [string]$DiagnosticDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PngToJpg\ApiResponses'))
    Test-ImageApiConfig $Config
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds([int]$Config.TimeoutSeconds)
    $endpoint = $Config.Endpoint.Replace('{model}', [Uri]::EscapeDataString($Config.Model))
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, (Assert-ImageApiUri $endpoint))
    $response = $null; $responseBytes = $null
    try {
        if ($Config.ProtectedKey) {
            $secure = ConvertTo-SecureString $Config.ProtectedKey
            $key = [System.Net.NetworkCredential]::new('', $secure).Password
            if ($key -match '[\r\n]') { throw '鉴权密钥不能包含换行。' }
            if (-not $request.Headers.TryAddWithoutValidation($Config.AuthHeader, ($Config.AuthPrefix + $key))) { throw '无法设置鉴权请求头。' }
            $key = $null
        }
        $bytes = [System.IO.File]::ReadAllBytes($SourcePath)
        $mime = switch ([IO.Path]::GetExtension($SourcePath).ToLowerInvariant()) { '.png' { 'image/png' } '.webp' { 'image/webp' } default { 'image/jpeg' } }
        $fields = ConvertFrom-Json -InputObject $Config.FieldsJson -AsHashtable
        $protocol = $Config.Protocol
        if ($protocol -eq 'OpenAI Images') {
            $fields['model'] = $Config.Model; $fields['prompt'] = $Config.Prompt
            $protocol = 'Multipart'
        }
        switch ($protocol) {
            { $_ -in @('Gemini', 'Gemini Interactions') } {
                $encoded = [Convert]::ToBase64String($bytes)
                if ($protocol -eq 'Gemini') {
                    $fields['contents'] = @(@{ role = 'user'; parts = @(@{ text = $Config.Prompt }, @{ inlineData = @{ mimeType = $mime; data = $encoded } }) })
                    if (-not $fields.Contains('generationConfig')) { $fields['generationConfig'] = @{ responseModalities = @('TEXT', 'IMAGE') } }
                } else {
                    $fields['model'] = $Config.Model
                    $fields['input'] = @(@{ type = 'text'; text = $Config.Prompt }, @{ type = 'image'; mime_type = $mime; data = $encoded })
                    if (-not $fields.Contains('response_format')) { $fields['response_format'] = @{ type = 'image' } }
                }
                $request.Content = [System.Net.Http.StringContent]::new(($fields | ConvertTo-Json -Depth 32 -Compress), [Text.Encoding]::UTF8, 'application/json')
            }
            'JSON' {
                $encoded = [Convert]::ToBase64String($bytes)
                if ($Config.ImageEncoding -eq 'data-url') { $encoded = "data:${mime};base64,$encoded" }
                $fields[$Config.ImageField] = $encoded
                $request.Content = [System.Net.Http.StringContent]::new(($fields | ConvertTo-Json -Depth 32 -Compress), [Text.Encoding]::UTF8, 'application/json')
            }
            'Multipart' {
                $body = [System.Net.Http.MultipartFormDataContent]::new()
                $request.Content = $body
                foreach ($name in $fields.Keys) {
                    $value = $fields[$name]
                    if ($value -is [System.Collections.IDictionary] -or $value -is [array]) { $value = ConvertTo-Json -InputObject $value -Depth 32 -Compress }
                    $body.Add([System.Net.Http.StringContent]::new([string]$value), [string]$name)
                }
                $file = [System.Net.Http.ByteArrayContent]::new($bytes)
                $file.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new($mime)
                $body.Add($file, $Config.ImageField, [IO.Path]::GetFileName($SourcePath))
            }
            'Binary' {
                $request.Content = [System.Net.Http.ByteArrayContent]::new($bytes)
                $request.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new($mime)
            }
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $responseBytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "图片接口请求失败（HTTP $([int]$response.StatusCode)）。请检查地址、鉴权、额度与参数。" }
        Export-ImageApiResponse $Config $responseBytes $DestinationPath $client
    }
    catch {
        $failure = $_.Exception
        # History only gets a safe message and local path. Raw response stays encrypted.
        $diagnosticNote = ''
        if ($null -ne $responseBytes) {
            try {
                $savedPath = Save-ImageApiFailureResponse $Config $responseBytes ([int]$response.StatusCode) $DiagnosticDirectory
                $diagnosticNote = " 失败响应已加密保存在：$savedPath；可重新解析，无需重新生成。"
            } catch { $diagnosticNote = ' 失败响应未能保存，请检查本地目录权限或磁盘空间。' }
        }
        $safeMessage = '图片 API 处理失败，请检查配置、密钥是否属于当前 Windows 用户，以及返回数据是否符合所选格式。'
        if ($failure -is [System.Threading.Tasks.TaskCanceledException]) { $safeMessage = '图片 API 请求超时；请先检查平台任务记录，避免重复计费。' }
        elseif ($failure -is [System.Net.Http.HttpRequestException]) { $safeMessage = '图片 API 网络连接失败，请检查服务地址和网络。' }
        elseif ($failure -is [System.Management.Automation.RuntimeException] -and $failure.Message -match '^(图片接口|结果图片|响应|接口返回|接口和结果|附加参数|不支持|请填写|鉴权|超时范围|无法设置)') { $safeMessage = $failure.Message }
        throw ($safeMessage + $diagnosticNote)
    }
    finally {
        if ($response) { $response.Dispose() }
        $request.Dispose(); $client.Dispose()
    }
}

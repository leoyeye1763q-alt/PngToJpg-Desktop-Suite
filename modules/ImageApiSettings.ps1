function Show-ImageApiSettings {
    param([string]$SmokeScreenshotPath)
    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = '图片清晰 · API 配置'
    $dialog.Size = [Drawing.Size]::new(820, 780)
    $dialog.MinimumSize = [Drawing.Size]::new(720, 600)
    $dialog.StartPosition = 'CenterParent'
    $dialog.Font = $form.Font
    $dialog.BackColor = [Drawing.ColorTranslator]::FromHtml('#EDF2FA')
    $panel = [Windows.Forms.Panel]::new()
    $panel.Dock = 'Fill'; $panel.AutoScroll = $true
    $dialog.Controls.Add($panel)
    $footer = [Windows.Forms.Panel]::new()
    $footer.Dock = 'Bottom'; $footer.Height = 58
    $dialog.Controls.Add($footer)
    $inputs = @{}
    $definitions = @(
        @('Protocol', '接口协议', @('OpenAI Images', 'Gemini', 'Gemini Interactions', 'JSON', 'Multipart', 'Binary')),
        @('Endpoint', '完整接口地址', $null),
        @('Model', '模型名称', $null),
        @('ApiKey', 'API Key', $null),
        @('Prompt', '清晰化提示词', $null),
        @('AuthHeader', '鉴权请求头', $null),
        @('AuthPrefix', '密钥前缀（含空格）', $null),
        @('ImageField', '图片字段名', $null),
        @('ImageEncoding', 'JSON 图片编码', @('data-url', 'base64')),
        @('ResponseType', '返回图片格式', @('base64', 'url', 'binary')),
        @('ResponsePath', '返回字段路径', $null),
        @('TimeoutSeconds', '超时（秒）', $null),
        @('FieldsJson', '附加参数 JSON', $null)
    )
    $y = 18
    foreach ($definition in $definitions) {
        $name = $definition[0]
        $label = [Windows.Forms.Label]::new()
        $label.Text = $definition[1]; $label.AutoSize = $true
        $label.Location = [Drawing.Point]::new(18, $y + 5)
        $panel.Controls.Add($label)
        if ($definition[2]) {
            $input = [Windows.Forms.ComboBox]::new()
            $input.DropDownStyle = 'DropDownList'; $input.Items.AddRange($definition[2])
            $input.SelectedItem = [string]$script:imageApiConfig[$name]
        } else {
            $input = [Windows.Forms.TextBox]::new()
            if ($name -ne 'ApiKey') { $input.Text = [string]$script:imageApiConfig[$name] }
        }
        $input.Location = [Drawing.Point]::new(184, $y)
        $input.Width = 580; $input.Anchor = 'Top,Left,Right'
        if ($name -in @('Prompt', 'FieldsJson')) { $input.Multiline = $true; $input.Height = 64; $input.ScrollBars = 'Vertical' }
        if ($name -eq 'ApiKey') {
            $input.UseSystemPasswordChar = $true
            if ($script:imageApiConfig.ProtectedKey) { $input.Text = '************'; $input.Tag = 'saved-key-mask' }
            $input.PlaceholderText = if ($script:imageApiConfig.ProtectedKey) { '密钥已加密保存；保留星号即继续使用' } else { '输入服务商或中转平台的 API Key' }
            $input.Add_TextChanged({ if ($inputs.ApiKey.Tag -eq 'saved-key-mask' -and $inputs.ApiKey.Text -ne '************') { $inputs.ApiKey.Tag = $null } })
        }
        $panel.Controls.Add($input); $inputs[$name] = $input
        $y += [Math]::Max(36, $input.Height + 10)
    }
    $clearKey = [Windows.Forms.CheckBox]::new()
    $clearKey.Text = '清除已保存的密钥'; $clearKey.AutoSize = $true
    $clearKey.Location = [Drawing.Point]::new(184, $y)
    $panel.Controls.Add($clearKey); $y += 32
    $help = [Windows.Forms.Label]::new()
    $help.Text = "OpenAI：填写 /v1/images/edits 完整地址，模型可改为平台提供的 image2 等别名。`nGemini：地址中的 {model} 自动替换；支持 generateContent 和 Interactions。`n通用接口：路径示例 data.0.url。仅支持同步返回，异步任务/签名接口需专门适配。`n点击开始处理会上传所选图片，可能消耗 API 额度。密钥仅当前 Windows 用户可解密。"
    $help.Location = [Drawing.Point]::new(18, $y); $help.Size = [Drawing.Size]::new(745, 90)
    $panel.Controls.Add($help); $y += 96
    $save = New-Button '保存配置' 130 ([Drawing.ColorTranslator]::FromHtml('#4B86F8')) ([Drawing.Color]::White)
    $save.Location = [Drawing.Point]::new(184, 10)
    $footer.Controls.Add($save)
    $panel.AutoScrollMinSize = [Drawing.Size]::new(0, $y + 12)
    $inputs.Protocol.Add_SelectedIndexChanged({
        switch ([string]$inputs.Protocol.SelectedItem) {
            'OpenAI Images' {
                $inputs.Endpoint.Text = 'https://api.openai.com/v1/images/edits'
                $inputs.Model.Text = 'gpt-image-2'; $inputs.AuthHeader.Text = 'Authorization'; $inputs.AuthPrefix.Text = 'Bearer '
                $inputs.ImageField.Text = 'image'; $inputs.ResponseType.SelectedItem = 'base64'; $inputs.ResponsePath.Text = 'data.0.b64_json'
            }
            'Gemini' {
                $inputs.Endpoint.Text = 'https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent'
                $inputs.Model.Text = 'gemini-3.1-flash-image'; $inputs.AuthHeader.Text = 'x-goog-api-key'; $inputs.AuthPrefix.Text = ''
                $inputs.ResponseType.SelectedItem = 'base64'
            }
            'Gemini Interactions' {
                $inputs.Endpoint.Text = 'https://generativelanguage.googleapis.com/v1beta/interactions'
                $inputs.Model.Text = 'gemini-3.1-flash-image'; $inputs.AuthHeader.Text = 'x-goog-api-key'; $inputs.AuthPrefix.Text = ''
                $inputs.ResponseType.SelectedItem = 'base64'
            }
        }
        # Switching providers never silently sends the previous provider's credential.
        $clearKey.Checked = $true
        $inputs.ApiKey.Text = ''
        $inputs.ApiKey.Tag = $null
        $inputs.ApiKey.PlaceholderText = '协议已切换，请输入对应服务商密钥'
        $inputs.FieldsJson.Text = '{}'
    })
    $save.Add_Click({
        try {
            $config = $script:imageApiConfig.Clone()
            foreach ($name in $inputs.Keys) {
                if ($name -ne 'ApiKey') { $config[$name] = $inputs[$name].Text }
            }
            $config.TimeoutSeconds = [int]$config.TimeoutSeconds
            if ($clearKey.Checked) { $config.ProtectedKey = '' }
            if ($inputs.ApiKey.Text -and $inputs.ApiKey.Tag -ne 'saved-key-mask' -and $inputs.ApiKey.Text -ne '************') { $config.ProtectedKey = ConvertFrom-SecureString (ConvertTo-SecureString $inputs.ApiKey.Text -AsPlainText -Force) }
            Test-ImageApiConfig $config
            [void][IO.Directory]::CreateDirectory($script:dataDirectory)
            $path = Join-Path $script:dataDirectory 'image-api.json'
            [IO.File]::WriteAllText(($path + '.tmp'), ($config | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move(($path + '.tmp'), $path, $true)
            $script:imageApiConfig = $config
            $dialog.DialogResult = 'OK'; $dialog.Close()
        } catch { [void][Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, '配置未保存', 'OK', 'Warning') }
    })
    try {
        if ($SmokeScreenshotPath) {
            if ($inputs.Protocol.SelectedItem -ne 'OpenAI Images') { throw 'API 协议初始值未选中。' }
            Initialize-SmokeControlTree $dialog
            $bitmap = [Drawing.Bitmap]::new($dialog.Width, $dialog.Height)
            try {
                $dialog.DrawToBitmap($bitmap, [Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height))
                $bitmap.Save($SmokeScreenshotPath, [Drawing.Imaging.ImageFormat]::Png)
            } finally { $bitmap.Dispose() }
            $inputs.Protocol.SelectedItem = 'Gemini'
            if ($inputs.AuthHeader.Text -ne 'x-goog-api-key' -or -not $clearKey.Checked) { throw 'Gemini 配置切换失败。' }
            $inputs.ApiKey.Text = 'smoke-test-key'
            $saveClick = [Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$saveClick.Invoke($save, @([EventArgs]::Empty))
            $saved = Get-Content (Join-Path $script:dataDirectory 'image-api.json') -Raw
            if ($saved.Contains('smoke-test-key') -or $script:imageApiConfig.Protocol -ne 'Gemini') { throw 'API 配置保存或密钥保护失败。' }
            Write-Host 'API settings preset and encrypted persistence: passed.'
        } else { [void]$dialog.ShowDialog($form) }
    } finally { $dialog.Dispose() }
}

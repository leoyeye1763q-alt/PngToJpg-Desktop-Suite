function ConvertTo-PhotoshopJsxLiteral([string]$Value) {
    return ($Value | ConvertTo-Json -Compress)
}

function Get-PhotoshopProcessInfo {
    $process = Get-CimInstance Win32_Process -Filter "Name='Photoshop.exe'" -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) } |
        Select-Object -First 1
    if (-not $process) { return $null }
    $version = ''
    try { $version = [Diagnostics.FileVersionInfo]::GetVersionInfo([string]$process.ExecutablePath).ProductVersion } catch { }
    [PSCustomObject]@{ ProcessId = [int]$process.ProcessId; ExecutablePath = [string]$process.ExecutablePath; Version = [string]$version }
}

function Get-PhotoshopVersionLabel([string]$Version) {
    $major = 0
    if ($Version -match '^(\d+)') { $major = [int]$Matches[1] }
    $year = switch ($major) { 21 { 2020 } 22 { 2021 } 23 { 2022 } 24 { 2023 } 25 { 2024 } 26 { 2025 } 27 { 2026 } default { 0 } }
    if ($year) { return "Photoshop $year ($Version)" }
    if ($Version) { return "Photoshop $Version" }
    return 'Photoshop（版本未知）'
}

function Initialize-PhotoshopAssistant {
    $script:photoshopAssistant = [ordered]@{
        Running = $false
        Detected = $false
        Busy = $false
        Version = ''
        VersionLabel = ''
        ProcessId = 0
        FileName = ''
        PsdPath = ''
        Width = 0
        Height = 0
        Saved = $false
        Status = '点击“检测 PS”读取本机 Photoshop 状态'
        OutputMode = 'current'
        OutputPath = ''
        JpgQuality = 10
        PreserveTransparency = $true
        Formats = @('JPG')
        OutputFiles = @()
        LastError = ''
    }
    $script:photoshopAssistantOperation = $null
    $script:photoshopAssistantTempRoot = Join-Path ([IO.Path]::GetTempPath()) 'PngToJpg-PhotoshopAssistant'
    $script:photoshopAssistantLogPath = Join-Path $script:dataDirectory 'logs\photoshop_export.log'
}

function Get-PhotoshopAssistantWebState {
    $state = @{} + $script:photoshopAssistant
    $state.Formats = @($script:photoshopAssistant.Formats)
    $state.OutputFiles = @($script:photoshopAssistant.OutputFiles)
    return $state
}

function Set-PhotoshopAssistantOptions($Options) {
    if (-not $Options) { return }
    $formats = @([string[]]$Options.formats | ForEach-Object { $_.ToUpperInvariant() } | Where-Object { $_ -in @('JPG', 'PNG', 'PSD') } | Select-Object -Unique)
    $script:photoshopAssistant.Formats = $formats
    $script:photoshopAssistant.JpgQuality = [Math]::Clamp([int]$Options.jpgQuality, 1, 12)
    $script:photoshopAssistant.PreserveTransparency = [bool]$Options.preserveTransparency
    $script:photoshopAssistant.OutputMode = if ([string]$Options.outputMode -eq 'custom') { 'custom' } else { 'current' }
    if ($Options.ContainsKey('outputPath')) { $script:photoshopAssistant.OutputPath = [string]$Options.outputPath }
}

function New-PhotoshopResultWriterJsx([string]$ResultPath) {
    $resultLiteral = ConvertTo-PhotoshopJsxLiteral $ResultPath
    return @"
function pngToJpgQuote(value) {
    return '"' + String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r/g, '\\r').replace(/\n/g, '\\n') + '"';
}
function pngToJpgWriteResult(value) {
    var file = new File($resultLiteral);
    file.encoding = 'UTF8';
    if (!file.open('w')) { throw new Error('无法写入本机结果文件'); }
    file.write(value);
    file.close();
}
"@
}

function New-PhotoshopDetectJsx([string]$ResultPath) {
    $writer = New-PhotoshopResultWriterJsx $ResultPath
    return @"
#target photoshop
app.bringToFront();
$writer
try {
    if (!app.documents.length) {
        pngToJpgWriteResult('{"ok":false,"code":"NO_DOCUMENT","version":' + pngToJpgQuote(app.version) + ',"message":"Photoshop 已运行，但没有打开文件"}');
    } else {
        var document = app.activeDocument;
        var fullPath = '';
        try { fullPath = document.fullName.fsName; } catch (pathError) { }
        var saved = fullPath.length > 0;
        pngToJpgWriteResult('{"ok":true,"version":' + pngToJpgQuote(app.version) + ',"name":' + pngToJpgQuote(document.name) + ',"path":' + pngToJpgQuote(fullPath) + ',"width":' + Math.round(document.width.as('px')) + ',"height":' + Math.round(document.height.as('px')) + ',"saved":' + (saved ? 'true' : 'false') + ',"message":' + pngToJpgQuote(saved ? '已读取当前 Photoshop 文件' : '当前文件尚未保存') + '}');
    }
} catch (error) {
    pngToJpgWriteResult('{"ok":false,"code":"SCRIPT_ERROR","version":' + pngToJpgQuote(app.version) + ',"message":' + pngToJpgQuote('读取 Photoshop 状态失败：' + error.message) + '}');
}
"@
}

function New-PhotoshopExportJsx([string]$ResultPath, [string]$OutputPath, [string[]]$Formats, [int]$JpgQuality, [bool]$PreserveTransparency) {
    $writer = New-PhotoshopResultWriterJsx $ResultPath
    $outputLiteral = ConvertTo-PhotoshopJsxLiteral $OutputPath
    $formatsLiteral = ConvertTo-PhotoshopJsxLiteral (($Formats | ForEach-Object { $_.ToUpperInvariant() }) -join ',')
    $quality = [Math]::Clamp($JpgQuality, 1, 12)
    $preserve = if ($PreserveTransparency) { 'true' } else { 'false' }
    return @"
#target photoshop
app.bringToFront();
$writer
function pngToJpgUniqueFile(folder, baseName, suffix, extension) {
    var candidate = new File(folder.fsName + '/' + baseName + suffix + extension);
    var index = 1;
    while (candidate.exists) {
        var serial = ('000' + index).slice(-3);
        candidate = new File(folder.fsName + '/' + baseName + suffix + '_' + serial + extension);
        index++;
    }
    return candidate;
}
function pngToJpgMakeRgbEightBit(document) {
    if (document.mode != DocumentMode.RGB) { document.changeMode(ChangeMode.RGB); }
    if (document.bitsPerChannel != BitsPerChannelType.EIGHT) { document.bitsPerChannel = BitsPerChannelType.EIGHT; }
}
function pngToJpgAddWhiteBackground(document) {
    var white = new SolidColor();
    white.rgb.red = 255; white.rgb.green = 255; white.rgb.blue = 255;
    var layer = document.artLayers.add();
    layer.name = '白色背景';
    if (document.layers.length > 1) { layer.move(document.layers[document.layers.length - 1], ElementPlacement.PLACEAFTER); }
    document.activeLayer = layer;
    document.selection.selectAll();
    document.selection.fill(white, ColorBlendMode.NORMAL, 100, false);
    document.selection.deselect();
}
var outputs = [];
var errors = [];
var sourcePath = '';
var requestedFormats = $formatsLiteral.split(',');
try {
    if (!app.documents.length) { throw new Error('Photoshop 已关闭或没有打开 PSD 文件'); }
    var source = app.activeDocument;
    try { sourcePath = source.fullName.fsName; } catch (pathError) { throw new Error('当前 PSD 尚未保存，请先保存后再导出'); }
    if (!sourcePath || !(new File(sourcePath)).exists) { throw new Error('当前 PSD 文件不存在，请重新保存后再试'); }
    if (!/\.(psd|psb)$/i.test(sourcePath)) { throw new Error('当前活动文件不是 PSD 或 PSB 文件'); }
    var outputFolder = $outputLiteral ? new Folder($outputLiteral) : source.fullName.parent;
    if (!outputFolder.exists) { throw new Error('输出目录不存在或无权访问'); }
    var baseName = source.name.replace(/\.[^.]+$/, '');
    var oldDialogs = app.displayDialogs;
    app.displayDialogs = DialogModes.NO;
    try {
        for (var i = 0; i < requestedFormats.length; i++) {
            var format = requestedFormats[i];
            var copy = null;
            try {
                if (format == 'PSD') {
                    var psdTarget = pngToJpgUniqueFile(outputFolder, baseName, '_export', '.psd');
                    copy = source.duplicate();
                    copy.saveAs(psdTarget, new PhotoshopSaveOptions(), true, Extension.LOWERCASE);
                    outputs.push(psdTarget.fsName);
                } else if (format == 'JPG') {
                    var jpgTarget = pngToJpgUniqueFile(outputFolder, baseName, '', '.jpg');
                    copy = source.duplicate();
                    pngToJpgMakeRgbEightBit(copy);
                    copy.flatten();
                    var jpgOptions = new JPEGSaveOptions();
                    jpgOptions.quality = $quality;
                    jpgOptions.embedColorProfile = true;
                    jpgOptions.formatOptions = FormatOptions.STANDARDBASELINE;
                    jpgOptions.matte = MatteType.WHITE;
                    copy.saveAs(jpgTarget, jpgOptions, true, Extension.LOWERCASE);
                    outputs.push(jpgTarget.fsName);
                } else if (format == 'PNG') {
                    var pngTarget = pngToJpgUniqueFile(outputFolder, baseName, '', '.png');
                    copy = source.duplicate();
                    pngToJpgMakeRgbEightBit(copy);
                    if (!$preserve) { pngToJpgAddWhiteBackground(copy); }
                    var pngOptions = new PNGSaveOptions();
                    pngOptions.interlaced = false;
                    copy.saveAs(pngTarget, pngOptions, true, Extension.LOWERCASE);
                    outputs.push(pngTarget.fsName);
                }
            } catch (formatError) {
                errors.push(format + '：' + formatError.message);
            } finally {
                if (copy) { try { copy.close(SaveOptions.DONOTSAVECHANGES); } catch (closeError) { } }
            }
        }
    } finally {
        app.displayDialogs = oldDialogs;
    }
    var ok = errors.length === 0 && outputs.length === requestedFormats.length;
    var message = ok ? ('导出完成，共 ' + outputs.length + ' 个文件') : (outputs.length ? ('部分导出完成：' + errors.join('；')) : ('导出失败：' + errors.join('；')));
    pngToJpgWriteResult('{"ok":' + (ok ? 'true' : 'false') + ',"path":' + pngToJpgQuote(sourcePath) + ',"outputs":' + pngToJpgQuote(outputs.join('\n')) + ',"formats":' + pngToJpgQuote(requestedFormats.join(',')) + ',"message":' + pngToJpgQuote(message) + '}');
} catch (error) {
    pngToJpgWriteResult('{"ok":false,"code":"EXPORT_ERROR","path":' + pngToJpgQuote(sourcePath) + ',"outputs":"","formats":' + pngToJpgQuote(requestedFormats.join(',')) + ',"message":' + pngToJpgQuote(error.message) + '}');
}
"@
}

function Start-PhotoshopAssistantOperation([ValidateSet('detect', 'export')] [string]$Kind, [string]$ScriptText, [string]$ResultPath) {
    if ($script:photoshopAssistant.Busy) { throw 'Photoshop 助手正在执行，请稍候。' }
    $process = Get-PhotoshopProcessInfo
    if (-not $process) {
        $script:photoshopAssistant.Running = $false
        $script:photoshopAssistant.Detected = $true
        $script:photoshopAssistant.Status = '未检测到 Photoshop'
        $script:photoshopAssistant.LastError = '未检测到 Photoshop，请先启动 Photoshop。'
        throw $script:photoshopAssistant.LastError
    }
    [void][IO.Directory]::CreateDirectory($script:photoshopAssistantTempRoot)
    $id = [Guid]::NewGuid().ToString('N')
    $jsxPath = Join-Path $script:photoshopAssistantTempRoot ($id + '.jsx')
    [IO.File]::WriteAllText($jsxPath, $ScriptText, [Text.UTF8Encoding]::new($false))
    $script:photoshopAssistant.Running = $true
    $script:photoshopAssistant.Detected = $true
    $script:photoshopAssistant.Busy = $true
    $script:photoshopAssistant.ProcessId = $process.ProcessId
    $script:photoshopAssistant.Version = $process.Version
    $script:photoshopAssistant.VersionLabel = Get-PhotoshopVersionLabel $process.Version
    $script:photoshopAssistant.Status = if ($Kind -eq 'detect') { '正在读取 Photoshop 状态…' } else { 'Photoshop 正在本机导出…' }
    $script:photoshopAssistant.LastError = ''
    $script:photoshopAssistant.OutputFiles = @()
    $script:photoshopAssistantOperation = [ordered]@{ Kind = $Kind; JsxPath = $jsxPath; ResultPath = $resultPath; Deadline = [DateTime]::UtcNow.AddSeconds(90) }
    try {
        Start-Process -FilePath $process.ExecutablePath -ArgumentList '-r', ('"' + $jsxPath + '"') | Out-Null
    } catch {
        $script:photoshopAssistant.Busy = $false
        $script:photoshopAssistantOperation = $null
        throw ('无法调用本机 Photoshop 执行脚本：' + $_.Exception.Message)
    }
}

function Start-PhotoshopDetection {
    $resultPath = Join-Path $script:photoshopAssistantTempRoot ([Guid]::NewGuid().ToString('N') + '.json')
    $scriptText = New-PhotoshopDetectJsx $resultPath
    Start-PhotoshopAssistantOperation -Kind detect -ScriptText $scriptText -ResultPath $resultPath
}

function Start-PhotoshopExport($Options) {
    Set-PhotoshopAssistantOptions $Options
    if (-not $script:photoshopAssistant.Formats.Count) { throw '请至少选择一种导出格式。' }
    $outputPath = ''
    if ($script:photoshopAssistant.OutputMode -eq 'custom') {
        $outputPath = [string]$script:photoshopAssistant.OutputPath
        if ([string]::IsNullOrWhiteSpace($outputPath) -or -not (Test-Path -LiteralPath $outputPath -PathType Container)) { throw '请选择有效的输出目录。' }
    }
    $resultPath = Join-Path $script:photoshopAssistantTempRoot ([Guid]::NewGuid().ToString('N') + '.json')
    $scriptText = New-PhotoshopExportJsx -ResultPath $resultPath -OutputPath $outputPath -Formats $script:photoshopAssistant.Formats -JpgQuality $script:photoshopAssistant.JpgQuality -PreserveTransparency $script:photoshopAssistant.PreserveTransparency
    Start-PhotoshopAssistantOperation -Kind export -ScriptText $scriptText -ResultPath $resultPath
}

function Write-PhotoshopAssistantLog([string]$PsdPath, [string]$Formats, [string]$Result, [string]$ErrorReason) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:photoshopAssistantLogPath))
    $clean = { param($value) ([string]$value).Replace("`r", ' ').Replace("`n", ' ') }
    $line = "{0}`tPSD={1}`t格式={2}`t结果={3}`t错误={4}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (& $clean $PsdPath), (& $clean $Formats), (& $clean $Result), (& $clean $ErrorReason)
    [IO.File]::AppendAllText($script:photoshopAssistantLogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Complete-PhotoshopAssistantOperation($Result) {
    $operation = $script:photoshopAssistantOperation
    if ($operation.Kind -eq 'detect') {
        $script:photoshopAssistant.Version = [string]$Result.version
        $script:photoshopAssistant.VersionLabel = Get-PhotoshopVersionLabel ([string]$Result.version)
        if ([bool]$Result.ok) {
            $script:photoshopAssistant.FileName = [string]$Result.name
            $script:photoshopAssistant.PsdPath = [string]$Result.path
            $script:photoshopAssistant.Width = [int]$Result.width
            $script:photoshopAssistant.Height = [int]$Result.height
            $script:photoshopAssistant.Saved = [bool]$Result.saved
            $script:photoshopAssistant.Status = [string]$Result.message
            $script:photoshopAssistant.LastError = if ($script:photoshopAssistant.Saved) { '' } else { '当前 PSD 尚未保存，请先保存后再导出。' }
        } else {
            $script:photoshopAssistant.FileName = ''
            $script:photoshopAssistant.PsdPath = ''
            $script:photoshopAssistant.Width = 0
            $script:photoshopAssistant.Height = 0
            $script:photoshopAssistant.Saved = $false
            $script:photoshopAssistant.Status = [string]$Result.message
            $script:photoshopAssistant.LastError = [string]$Result.message
        }
    } else {
        $outputs = if ([string]::IsNullOrWhiteSpace([string]$Result.outputs)) { @() } else { @(([string]$Result.outputs) -split "`n" | Where-Object { $_ }) }
        $script:photoshopAssistant.OutputFiles = $outputs
        $script:photoshopAssistant.Status = [string]$Result.message
        $script:photoshopAssistant.LastError = if ([bool]$Result.ok) { '' } else { [string]$Result.message }
        Write-PhotoshopAssistantLog -PsdPath ([string]$Result.path) -Formats ([string]$Result.formats) -Result $(if ($outputs.Count) { $outputs -join '; ' } else { '失败' }) -ErrorReason $script:photoshopAssistant.LastError
    }
}

function Clear-PhotoshopAssistantOperation {
    $operation = $script:photoshopAssistantOperation
    $script:photoshopAssistant.Busy = $false
    $script:photoshopAssistantOperation = $null
    if ($operation) {
        foreach ($path in @($operation.JsxPath, $operation.ResultPath)) {
            if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Poll-PhotoshopAssistant {
    if (-not $script:photoshopAssistant.Busy -or -not $script:photoshopAssistantOperation) { return }
    $operation = $script:photoshopAssistantOperation
    if (Test-Path -LiteralPath $operation.ResultPath -PathType Leaf) {
        try {
            $result = Get-Content -LiteralPath $operation.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            Complete-PhotoshopAssistantOperation $result
        } catch {
            $script:photoshopAssistant.Status = 'Photoshop 返回结果读取失败'
            $script:photoshopAssistant.LastError = 'Photoshop 脚本执行失败：' + $_.Exception.Message
            if ($operation.Kind -eq 'export') { Write-PhotoshopAssistantLog -PsdPath $script:photoshopAssistant.PsdPath -Formats ($script:photoshopAssistant.Formats -join ',') -Result '失败' -ErrorReason $script:photoshopAssistant.LastError }
        } finally { Clear-PhotoshopAssistantOperation }
        return
    }
    if ([DateTime]::UtcNow -ge $operation.Deadline) {
        $script:photoshopAssistant.Status = 'Photoshop 脚本执行超时'
        $script:photoshopAssistant.LastError = 'Photoshop 脚本执行失败或 Photoshop 正忙，请稍后重试。'
        if ($operation.Kind -eq 'export') { Write-PhotoshopAssistantLog -PsdPath $script:photoshopAssistant.PsdPath -Formats ($script:photoshopAssistant.Formats -join ',') -Result '失败' -ErrorReason $script:photoshopAssistant.LastError }
        Clear-PhotoshopAssistantOperation
    }
}

function Wait-PhotoshopAssistantOperation([int]$TimeoutSeconds = 95) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($script:photoshopAssistant.Busy -and [DateTime]::UtcNow -lt $deadline) { Poll-PhotoshopAssistant; Start-Sleep -Milliseconds 100 }
    if ($script:photoshopAssistant.Busy) { throw '等待 Photoshop 助手操作超时。' }
    return Get-PhotoshopAssistantWebState
}

function Select-PhotoshopOutputDirectory([Windows.Forms.IWin32Window]$Owner) {
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = '选择 Photoshop 导出目录'
    if ($script:photoshopAssistant.OutputPath -and (Test-Path -LiteralPath $script:photoshopAssistant.OutputPath -PathType Container)) { $dialog.SelectedPath = $script:photoshopAssistant.OutputPath }
    try {
        if ($dialog.ShowDialog($Owner) -eq 'OK') {
            $script:photoshopAssistant.OutputPath = $dialog.SelectedPath
            $script:photoshopAssistant.OutputMode = 'custom'
        }
    } finally { $dialog.Dispose() }
}

function Open-PhotoshopOutputDirectory {
    $path = ''
    if ($script:photoshopAssistant.OutputFiles.Count) { $path = [IO.Path]::GetDirectoryName([string]$script:photoshopAssistant.OutputFiles[0]) }
    elseif ($script:photoshopAssistant.OutputMode -eq 'custom') { $path = [string]$script:photoshopAssistant.OutputPath }
    elseif ($script:photoshopAssistant.PsdPath) { $path = [IO.Path]::GetDirectoryName([string]$script:photoshopAssistant.PsdPath) }
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { throw '尚无可打开的输出目录。' }
    Start-Process explorer.exe -ArgumentList ('"' + $path + '"') | Out-Null
}

# Independent enhancement workspace; only the image processing engines and API profile are shared.
$script:clarity = @{
    Busy = $false; Process = $null; JobDirectory = $null; Queue = @(); Index = 0; Success = 0; Failed = 0; Cancelled = $false
    Results = @{}; PreviewProcess = $null; PreviewDirectory = $null; Loading = $true
}
function New-ClarityLabel([string]$Text, [int]$X, [int]$Y) {
    $c = [Windows.Forms.Label]::new(); $c.Text = $Text; $c.AutoSize = $true
    $c.Location = [Drawing.Point]::new($X,$Y); return $c
}
function New-ClarityCombo([string[]]$Items, [int]$Y) {
    $c = [Windows.Forms.ComboBox]::new(); $c.DropDownStyle = 'DropDownList'; $c.Items.AddRange($Items)
    $c.SelectedIndex = 0; $c.Location = [Drawing.Point]::new(20,$Y); $c.Width = 272; return $c
}
function New-ClarityButton([string]$Text, [int]$Width = 120) {
    return New-Button $Text $Width ([Drawing.ColorTranslator]::FromHtml('#E8ECF4')) ([Drawing.ColorTranslator]::FromHtml('#364158'))
}
$clarityPage = [Windows.Forms.TableLayoutPanel]::new()
$clarityPage.Dock = 'Fill'; $clarityPage.Padding = [Windows.Forms.Padding]::new(10,4,10,4)
$clarityPage.ColumnCount = 1; $clarityPage.RowCount = 2
[void]$clarityPage.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
[void]$clarityPage.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',108))
[void]$clarityPage.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',100))
$clarityPage.Visible = $false
$clarityHeader = [ReferenceUiCard]::new(); $clarityHeader.Dock = 'Fill'; $clarityHeader.CornerRadius = 18
$clarityHeading = New-ClarityLabel '图片清晰' 24 16
$clarityHeading.Font = [Drawing.Font]::new('Microsoft YaHei UI',21,[Drawing.FontStyle]::Bold)
$clarityHeading.ForeColor = [Drawing.ColorTranslator]::FromHtml('#172033')
$clarityHeader.Controls.Add($clarityHeading)
$clarityHeader.Controls.Add((New-ClarityLabel '独立图片清晰工作台 · 本地增强与大模型 API · 原图 / 结果对比' 26 62))
$clarityPage.Controls.Add($clarityHeader,0,0)
$clarityBody = [Windows.Forms.TableLayoutPanel]::new(); $clarityBody.Dock = 'Fill'; $clarityBody.ColumnCount = 2; $clarityBody.RowCount = 1
[void]$clarityBody.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute',322))
[void]$clarityBody.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
[void]$clarityBody.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',100))
$clarityPage.Controls.Add($clarityBody,0,1)
$claritySettings = [ReferenceUiCard]::new(); $claritySettings.Dock = 'Fill'; $claritySettings.CornerRadius = 18; $claritySettings.AutoScroll = $true
$claritySettings.Margin = [Windows.Forms.Padding]::new(0,4,8,4)
$clarityBody.Controls.Add($claritySettings,0,0)
$claritySettings.Controls.Add((New-ClarityLabel '清晰方式' 20 18))
$script:clarity.Mode = New-ClarityCombo @('API 大模型清晰','保守清晰','AI 模型高清') 44
$claritySettings.Controls.Add($script:clarity.Mode)
$script:clarity.ApiButton = New-ClarityButton '配置 API 与模型' 272; $script:clarity.ApiButton.Location = [Drawing.Point]::new(20,82)
$script:clarity.ApiButton.Add_Click({ Show-ImageApiSettings; Update-ClarityMode })
$claritySettings.Controls.Add($script:clarity.ApiButton)
$script:clarity.ModelHint = New-ClarityLabel '' 20 127; $script:clarity.ModelHint.AutoSize = $false; $script:clarity.ModelHint.Size = [Drawing.Size]::new(272,42)
$claritySettings.Controls.Add($script:clarity.ModelHint)
$claritySettings.Controls.Add((New-ClarityLabel '本地增强强度' 20 179))
$script:clarity.Strength = New-ClarityCombo @('标准','轻微','较强') 204; $claritySettings.Controls.Add($script:clarity.Strength)
$claritySettings.Controls.Add((New-ClarityLabel '本地放大倍数' 20 245))
$script:clarity.Scale = New-ClarityCombo @('不放大','2×','4×') 270; $claritySettings.Controls.Add($script:clarity.Scale)
$claritySettings.Controls.Add((New-ClarityLabel '本地 AI 图片类型' 20 310))
$script:clarity.ImageType = New-ClarityCombo @('商品照片','插画') 336; $claritySettings.Controls.Add($script:clarity.ImageType)
$claritySettings.Controls.Add((New-ClarityLabel '清晰结果格式' 20 378))
$script:clarity.Format = New-ClarityCombo @('PNG','JPG','WebP') 404; $claritySettings.Controls.Add($script:clarity.Format)
$script:clarity.SameFolder = [Windows.Forms.CheckBox]::new(); $script:clarity.SameFolder.Text = '保存到原图文件夹'; $script:clarity.SameFolder.Checked = $true
$script:clarity.SameFolder.AutoSize = $true; $script:clarity.SameFolder.Location = [Drawing.Point]::new(20,446); $claritySettings.Controls.Add($script:clarity.SameFolder)
$script:clarity.Output = [Windows.Forms.TextBox]::new(); $script:clarity.Output.Location = [Drawing.Point]::new(20,476); $script:clarity.Output.Width = 272; $script:clarity.Output.ReadOnly = $true
$script:clarity.Output.PlaceholderText = '选择结果保存位置'; $claritySettings.Controls.Add($script:clarity.Output)
$script:clarity.Browse = New-ClarityButton '选择输出文件夹' 272; $script:clarity.Browse.Location = [Drawing.Point]::new(20,511); $claritySettings.Controls.Add($script:clarity.Browse)
$script:clarity.Notice = New-ClarityLabel '' 20 563; $script:clarity.Notice.AutoSize = $false; $script:clarity.Notice.Size = [Drawing.Size]::new(272,80)
$script:clarity.Notice.ForeColor = [Drawing.ColorTranslator]::FromHtml('#A15C00'); $claritySettings.Controls.Add($script:clarity.Notice)
$claritySettings.AutoScrollMinSize = [Drawing.Size]::new(0,655)
$clarityWork = [ReferenceUiCard]::new(); $clarityWork.Dock = 'Fill'; $clarityWork.CornerRadius = 18; $clarityWork.Padding = [Windows.Forms.Padding]::new(16)
$clarityWork.Margin = [Windows.Forms.Padding]::new(4)
$clarityBody.Controls.Add($clarityWork,1,0)
$clarityWorkLayout = [Windows.Forms.TableLayoutPanel]::new(); $clarityWorkLayout.Dock = 'Fill'; $clarityWorkLayout.RowCount = 4; $clarityWorkLayout.ColumnCount = 1
[void]$clarityWorkLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
foreach ($height in @(50,145)) { [void]$clarityWorkLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',$height)) }
[void]$clarityWorkLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',100))
[void]$clarityWorkLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',94))
$clarityWork.Controls.Add($clarityWorkLayout)
$clarityActions = [Windows.Forms.FlowLayoutPanel]::new(); $clarityActions.Dock = 'Fill'
$clarityActions.BackColor = [Drawing.ColorTranslator]::FromHtml('#F8FAFE')
$script:clarity.Add = New-ClarityButton '+ 添加清晰图片' 140
$script:clarity.Clear = New-ClarityButton '清空列表' 100
$script:clarity.SelectAll = New-ClarityButton '全选 / 取消' 110
foreach ($button in @($script:clarity.Add,$script:clarity.Clear,$script:clarity.SelectAll)) { $clarityActions.Controls.Add($button) }
$clarityWorkLayout.Controls.Add($clarityActions,0,0)
$script:clarity.List = [Windows.Forms.ListView]::new(); $script:clarity.List.Dock = 'Fill'; $script:clarity.List.View = 'Details'
$script:clarity.List.CheckBoxes = $true; $script:clarity.List.FullRowSelect = $true; $script:clarity.List.HideSelection = $false
$script:clarity.List.MultiSelect = $false; $script:clarity.List.ShowItemToolTips = $true
[void]$script:clarity.List.Columns.Add('待清晰图片',260); [void]$script:clarity.List.Columns.Add('处理状态',300)
$clarityWorkLayout.Controls.Add($script:clarity.List,0,1)
$clarityPreview = [Windows.Forms.TableLayoutPanel]::new(); $clarityPreview.Dock = 'Fill'; $clarityPreview.RowCount = 2; $clarityPreview.ColumnCount = 2
foreach ($i in 0..1) { [void]$clarityPreview.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',50)) }
[void]$clarityPreview.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',30)); [void]$clarityPreview.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',100))
$clarityPreview.Controls.Add((New-ClarityLabel '原图' 0 0),0,0); $clarityPreview.Controls.Add((New-ClarityLabel '清晰结果' 0 0),1,0)
foreach ($name in @('Original','Result')) {
    $box = [Windows.Forms.PictureBox]::new(); $box.Dock = 'Fill'; $box.SizeMode = 'Zoom'; $box.BackColor = [Drawing.ColorTranslator]::FromHtml('#F4F7FC')
    $script:clarity[$name] = $box; $clarityPreview.Controls.Add($box, $(if ($name -eq 'Original') {0} else {1}),1)
}
$clarityWorkLayout.Controls.Add($clarityPreview,0,2)
$clarityFooter = [Windows.Forms.Panel]::new(); $clarityFooter.Dock = 'Fill'
$clarityFooter.BackColor = [Drawing.ColorTranslator]::FromHtml('#F8FAFE')
$script:clarity.Start = New-Button '上传并清晰' 140 ([Drawing.ColorTranslator]::FromHtml('#4B86F8')) ([Drawing.Color]::White)
$script:clarity.Cancel = New-ClarityButton '取消处理' 105; $script:clarity.Cancel.Enabled = $false
$script:clarity.Status = New-ClarityLabel '添加图片，选择清晰方式后开始处理' 0 62
$script:clarity.Status.AutoSize = $false; $script:clarity.Status.Height = 30
$script:clarity.Progress = [Windows.Forms.ProgressBar]::new(); $script:clarity.Progress.Location = [Drawing.Point]::new(0,19); $script:clarity.Progress.Height = 18
foreach ($control in @($script:clarity.Start,$script:clarity.Cancel,$script:clarity.Status,$script:clarity.Progress)) { $clarityFooter.Controls.Add($control) }
$clarityFooter.Add_Resize({
    $script:clarity.Start.Location = [Drawing.Point]::new([Math]::Max(0,$clarityFooter.Width-140),6)
    $script:clarity.Cancel.Location = [Drawing.Point]::new([Math]::Max(0,$clarityFooter.Width-255),6)
    $script:clarity.Progress.Width = [Math]::Max(40,$clarityFooter.Width-275)
    $script:clarity.Status.Width = $clarityFooter.Width
})
$clarityWorkLayout.Controls.Add($clarityFooter,0,3)

function Save-ClarityState {
    param([switch]$ForTest)
    if ($script:clarity.Loading -or ($script:isSmokeRun -and -not $ForTest)) { return }
    try {
        $state = @{ Records = @($script:clarity.List.Items | ForEach-Object { @{ Path = [string]$_.Tag; Checked = $_.Checked; Result = $script:clarity.Results[[string]$_.Tag] } }); SameFolder = $script:clarity.SameFolder.Checked; Output = $script:clarity.Output.Text }
        foreach ($key in @('Mode','Strength','Scale','ImageType','Format')) { $state[$key] = $script:clarity[$key].Text }
        [void][IO.Directory]::CreateDirectory($script:dataDirectory)
        $path = Join-Path $script:dataDirectory 'clarity-state.json'
        [IO.File]::WriteAllText(($path+'.tmp'),($state | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false)); [IO.File]::Move(($path+'.tmp'),$path,$true)
    } catch { $script:clarity.Status.Text = '清晰页面记录保存失败。' }
}
function Update-ClarityMode {
    $api = $script:clarity.Mode.Text -eq 'API 大模型清晰'; $ai = $script:clarity.Mode.Text -eq 'AI 模型高清'
    $script:clarity.Strength.Enabled = -not $api -and -not $script:clarity.Busy
    $script:clarity.Scale.Enabled = -not $api -and -not $script:clarity.Busy
    $script:clarity.ImageType.Enabled = $ai -and -not $script:clarity.Busy
    if ($ai -and $script:clarity.Scale.SelectedIndex -eq 0) { $script:clarity.Scale.SelectedIndex = 1 }
    $script:clarity.Start.Text = if ($api) { '上传并清晰' } else { '开始清晰' }
    $script:clarity.ModelHint.Text = if ($api) { '当前模型：'+$script:imageApiConfig.Model } else { '本地处理，不上传图片' }
    $script:clarity.Notice.Text = if ($api) { '开始处理会上传勾选图片并消耗 API 额度。模型可能改变细节，请检查结果。API 输出尺寸请在附加参数中配置。' } else { '本地 AI 可能推测细节。含重要文字或 Logo 的图片建议选择保守清晰。输出保留透明背景（JPG 除外）。' }
    $script:clarity.Output.Enabled = -not $script:clarity.SameFolder.Checked -and -not $script:clarity.Busy
    $script:clarity.Browse.Enabled = $script:clarity.Output.Enabled
    Save-ClarityState
}
function Add-ClarityImages([string[]]$Paths) {
    if ($script:clarity.Busy) { return }
    $newItems = [System.Collections.Generic.List[System.Windows.Forms.ListViewItem]]::new()
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or [IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.jfif','.webp')) { continue }
        $full = [IO.Path]::GetFullPath($path)
        if (@($script:clarity.List.Items | Where-Object { $_.Tag -eq $full }).Count) { continue }
        $item = [Windows.Forms.ListViewItem]::new([IO.Path]::GetFileName($full)); $item.Tag = $full; $item.Checked = $true
        [void]$item.SubItems.Add('等待处理'); [void]$script:clarity.List.Items.Add($item)
        $newItems.Add($item)
    }
    if (-not $script:clarity.Loading -and $newItems.Count) {
        foreach ($existing in $script:clarity.List.Items) { $existing.Checked = $false; $existing.Selected = $false }
        foreach ($newItem in $newItems) { $newItem.Checked = $true }
        $newItems[0].Selected = $true
    } elseif ($script:clarity.List.Items.Count -and -not $script:clarity.List.SelectedItems.Count) { $script:clarity.List.Items[0].Selected = $true }
    $script:clarity.Status.Text = '清晰列表：'+$script:clarity.List.Items.Count+' 张图片'
    Save-ClarityState
}
function Stop-ClarityPreview {
    if ($script:clarity.PreviewProcess) {
        if (-not $script:clarity.PreviewProcess.HasExited) { $script:clarity.PreviewProcess.Kill($true); $script:clarity.PreviewProcess.WaitForExit() }
        $script:clarity.PreviewProcess.Dispose(); $script:clarity.PreviewProcess = $null
    }
    if ($script:clarity.PreviewDirectory) { Remove-JobTemporaryDirectory $script:clarity.PreviewDirectory; $script:clarity.PreviewDirectory = $null }
}
function Start-ClarityProcess([string]$ScriptPath,[string]$JobPath) {
    $info = [Diagnostics.ProcessStartInfo]::new(); $info.FileName = $script:powerShellPath; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    foreach ($arg in @('-NoLogo','-NoProfile','-File',$ScriptPath,'-JobPath',$JobPath)) { [void]$info.ArgumentList.Add($arg) }
    return [Diagnostics.Process]::Start($info)
}
function Update-ClarityPreview {
    Stop-ClarityPreview
    foreach ($key in @('Original','Result')) { if ($script:clarity[$key].Image) { $script:clarity[$key].Image.Dispose(); $script:clarity[$key].Image = $null } }
    if (-not $script:clarity.List.SelectedItems.Count) { return }
    $source = [string]$script:clarity.List.SelectedItems[0].Tag
    $dir = Join-Path $script:taskTempRoot ([Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($dir)
    $script:clarity.PreviewDirectory = $dir
    $job = @{ SourcePath=$source; ResultSourcePath=[string]$script:clarity.Results[$source]; MagickPath=$script:magickPath; MaxWidth=1100; MaxHeight=1100; OriginalPreviewPath=(Join-Path $dir 'original.png'); ResultPreviewPath=(Join-Path $dir 'processed.png'); ResultPath=(Join-Path $dir 'result.json') }
    $jobPath = Join-Path $dir 'job.json'; $job | ConvertTo-Json | Set-Content $jobPath
    $script:clarity.PreviewProcess = Start-ClarityProcess $script:previewWorkerScriptPath $jobPath
}
function Set-ClarityBusy([bool]$Busy) {
    $script:clarity.Busy = $Busy
    foreach ($key in @('Mode','Strength','Scale','ImageType','Format','ApiButton','SameFolder','Browse','Add','Clear','SelectAll','Start')) { $script:clarity[$key].Enabled = -not $Busy }
    $script:clarity.Cancel.Enabled = $Busy
    Update-ClarityMode
}
function Start-NextClarityJob {
    if ($script:clarity.Cancelled -or $script:clarity.Index -ge $script:clarity.Queue.Count) {
        Set-ClarityBusy $false
        $script:clarity.Status.Text = "$(if ($script:clarity.Cancelled) {'已取消'} else {'完成'})：成功 $($script:clarity.Success)，失败 $($script:clarity.Failed)"
        Save-ClarityState; return
    }
    $item = $script:clarity.Queue[$script:clarity.Index]; $options = $script:clarity.Options
    try {
        $dir = Join-Path $script:taskTempRoot ([Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($dir); $script:clarity.JobDirectory = $dir
        $destinationDirectory = if ($options.SameFolder) { Split-Path -Parent ([string]$item.Tag) } else { $options.Output }
        [void][IO.Directory]::CreateDirectory($destinationDirectory)
        $destination = New-ProcessedOutputPath $destinationDirectory ([IO.Path]::GetFileNameWithoutExtension([string]$item.Tag)) $options.Format '_清晰'
        $job = @{ SourcePath=[string]$item.Tag; OutputPath=$destination; OutputFormat=$options.Format; Mode=$options.Mode; Strength=$options.Strength; Scale=$options.Scale; ImageType=$options.ImageType; FinalWidth=0; FinalHeight=0; PreserveAlpha=$true; Background='#FFFFFF'; TileSize=256; ModelName=$(if ($options.ImageType -eq '插画') {'realesrgan-x4plus-anime'} else {'realesrgan-x4plus'}); MagickPath=$script:magickPath; RealEsrganPath=$script:realEsrganPath; ModelPath=$script:realEsrganModelPath; TempDirectory=$dir; ProgressPath=(Join-Path $dir 'progress.json'); ResultPath=(Join-Path $dir 'result.json'); ApiConfig=$options.ApiConfig }
        if ($options.Mode -eq 'AI 模型高清') { $job.Strength = switch ($options.Strength) { '轻微' {'保守'} '较强' {'明显'} default {'标准'} } }
        $jobPath = Join-Path $dir 'job.json'; $job | ConvertTo-Json -Depth 8 | Set-Content $jobPath
        $script:clarity.Process = Start-ClarityProcess $script:workerScriptPath $jobPath
        $item.SubItems[1].Text = '处理中'; $script:clarity.Status.Text = "正在清晰 $($script:clarity.Index+1) / $($script:clarity.Queue.Count)"
    } catch {
        $item.SubItems[1].Text = '启动失败'; $item.ToolTipText = $_.Exception.Message; $script:clarity.Failed++; $script:clarity.Index++
        if ($script:clarity.JobDirectory) { Remove-JobTemporaryDirectory $script:clarity.JobDirectory; $script:clarity.JobDirectory = $null }
        Start-NextClarityJob
    }
}
function Start-ClarityBatch {
    if ($script:clarity.Busy) { return }
    try {
        $queue = @($script:clarity.List.Items | Where-Object Checked)
        if (-not $queue.Count) { throw '请先添加并勾选需要清晰的图片。' }
        if (-not $script:clarity.SameFolder.Checked -and -not $script:clarity.Output.Text) { throw '请选择输出文件夹。' }
        if ($script:clarity.Mode.Text -eq 'API 大模型清晰') { Test-ImageApiConfig $script:imageApiConfig }
        $script:clarity.Options = @{ Mode=$script:clarity.Mode.Text; Strength=$script:clarity.Strength.Text; Scale=@(1,2,4)[$script:clarity.Scale.SelectedIndex]; ImageType=$script:clarity.ImageType.Text; Format=$script:clarity.Format.Text.ToLowerInvariant(); SameFolder=$script:clarity.SameFolder.Checked; Output=$script:clarity.Output.Text; ApiConfig=$script:imageApiConfig.Clone() }
        if ($script:clarity.ContainsKey('Prompt')) { $script:clarity.Options.ApiConfig.Prompt=$script:clarity.Prompt.Text }
        $script:clarity.Queue=$queue; $script:clarity.Index=0; $script:clarity.Success=0; $script:clarity.Failed=0; $script:clarity.Cancelled=$false; $script:clarity.Progress.Value=0
        Set-ClarityBusy $true; Start-NextClarityJob
    } catch { [void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'图片清晰','OK','Warning') }
}
$script:clarity.Timer = [Windows.Forms.Timer]::new(); $script:clarity.Timer.Interval = 150
$script:clarity.Timer.Add_Tick({
    if ($script:clarity.PreviewProcess -and $script:clarity.PreviewProcess.HasExited) {
        try {
            foreach ($entry in @(@('Original','original.png'),@('Result','processed.png'))) {
                $path = Join-Path $script:clarity.PreviewDirectory $entry[1]
                if (Test-Path $path) { $image = [Drawing.Image]::FromFile($path); try { $script:clarity[$entry[0]].Image = [Drawing.Bitmap]::new($image) } finally { $image.Dispose() } }
            }
        } catch { $script:clarity.Status.Text = '预览加载失败。' } finally { Stop-ClarityPreview }
    }
    if (-not $script:clarity.Process) { return }
    $item = $script:clarity.Queue[$script:clarity.Index]
    if (-not $script:clarity.Process.HasExited) {
        $progressPath = Join-Path $script:clarity.JobDirectory 'progress.json'
        if (Test-Path $progressPath) { try { $progress=Get-Content $progressPath -Raw | ConvertFrom-Json; $item.SubItems[1].Text=$progress.Phase; $script:clarity.Progress.Value=[Math]::Min(100,[int](100*($script:clarity.Index+$progress.Percent/100)/$script:clarity.Queue.Count)) } catch {} }
        return
    }
    try {
        if ($script:clarity.Cancelled) { $item.SubItems[1].Text='已取消' }
        else {
            $result=Get-Content (Join-Path $script:clarity.JobDirectory 'result.json') -Raw | ConvertFrom-Json
            if (-not $result.Success) { throw $result.Error }
            $script:clarity.Results[[string]$item.Tag]=[string]$result.OutputPath; $item.SubItems[1].Text='完成'; $item.ToolTipText=[string]$result.OutputPath; $script:clarity.Success++
            if ($item.Selected) { Update-ClarityPreview }
        }
    } catch { $item.SubItems[1].Text='失败（悬停查看原因）'; $item.ToolTipText=$_.Exception.Message; $script:clarity.Failed++ }
    finally {
        $script:clarity.Process.Dispose(); $script:clarity.Process=$null
        Remove-JobTemporaryDirectory $script:clarity.JobDirectory; $script:clarity.JobDirectory=$null
        $script:clarity.Index++
        $script:clarity.Progress.Value=[Math]::Min(100,[int](100*$script:clarity.Index/$script:clarity.Queue.Count))
        Start-NextClarityJob
    }
})
$script:clarity.Timer.Start()
$script:clarity.Add.Add_Click({ $dialog=[Windows.Forms.OpenFileDialog]::new(); $dialog.Multiselect=$true; $dialog.Filter='图片|*.png;*.jpg;*.jpeg;*.jfif;*.webp'; try { if ($dialog.ShowDialog($form) -eq 'OK') { Add-ClarityImages $dialog.FileNames } } finally {$dialog.Dispose()} })
$script:clarity.Clear.Add_Click({ Stop-ClarityPreview; $script:clarity.List.Items.Clear(); $script:clarity.Results.Clear(); Update-ClarityPreview; Save-ClarityState })
$script:clarity.SelectAll.Add_Click({ $check=@($script:clarity.List.Items | Where-Object { -not $_.Checked }).Count -gt 0; foreach ($item in $script:clarity.List.Items) {$item.Checked=$check}; Save-ClarityState })
$script:clarity.Start.Add_Click({ Start-ClarityBatch })
$script:clarity.Cancel.Add_Click({ $script:clarity.Cancelled=$true; $script:clarity.Cancel.Enabled=$false; if ($script:clarity.Process -and -not $script:clarity.Process.HasExited) { $script:clarity.Process.Kill($true) } })
$script:clarity.List.Add_SelectedIndexChanged({ Update-ClarityPreview })
$script:clarity.Browse.Add_Click({ $dialog=[Windows.Forms.FolderBrowserDialog]::new(); try { if ($dialog.ShowDialog($form) -eq 'OK') { $script:clarity.Output.Text=$dialog.SelectedPath; Save-ClarityState } } finally {$dialog.Dispose()} })
foreach ($key in @('Mode','Strength','Scale','ImageType','Format')) { $script:clarity[$key].Add_SelectedIndexChanged({Update-ClarityMode}) }
$script:clarity.SameFolder.Add_CheckedChanged({Update-ClarityMode})
foreach ($target in @($clarityPage,$clarityWork,$script:clarity.List,$script:clarity.Original,$script:clarity.Result)) {
    $target.AllowDrop=$true
    $target.Add_DragEnter({ if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop) -and -not $script:clarity.Busy) {$_.Effect='Copy'} })
    $target.Add_DragDrop({ Add-ClarityImages ([string[]]$_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)) })
}
function Initialize-ClarityState {
    $path=Join-Path $script:dataDirectory 'clarity-state.json'
    if (Test-Path $path) { try {
        $state=Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        foreach ($key in @('Mode','Strength','Scale','ImageType','Format')) { if ($script:clarity[$key].Items.Contains([string]$state[$key])) {$script:clarity[$key].SelectedItem=[string]$state[$key]} }
        $script:clarity.SameFolder.Checked=[bool]$state.SameFolder; $script:clarity.Output.Text=[string]$state.Output
        foreach ($record in $state.Records) { Add-ClarityImages @([string]$record.Path); $item=$script:clarity.List.Items | Where-Object Tag -eq $record.Path | Select-Object -First 1; if ($item) { $item.Checked=[bool]$record.Checked; if ($record.Result -and (Test-Path -LiteralPath $record.Result)) {$script:clarity.Results[[string]$record.Path]=[string]$record.Result;$item.SubItems[1].Text='完成';$item.ToolTipText=[string]$record.Result} } }
    } catch {$script:clarity.Status.Text='清晰页记录未能完整加载。'} }
    $script:clarity.Loading=$false; Update-ClarityMode; Update-ClarityPreview
}
function Close-ClarityWorkspace {
    if ($script:clarity.ContainsKey('Closed') -and $script:clarity.Closed) { return }
    $script:clarity.Closed=$true
    Save-ClarityState; $script:clarity.Timer.Stop(); $script:clarity.Timer.Dispose(); Stop-ClarityPreview
    if ($script:clarity.Process) { if (-not $script:clarity.Process.HasExited) {$script:clarity.Process.Kill($true); $script:clarity.Process.WaitForExit()}; $script:clarity.Process.Dispose(); $script:clarity.Process=$null }
    if ($script:clarity.JobDirectory) {Remove-JobTemporaryDirectory $script:clarity.JobDirectory; $script:clarity.JobDirectory=$null}
    foreach ($key in @('Original','Result')) {if ($script:clarity[$key].Image) {$script:clarity[$key].Image.Dispose();$script:clarity[$key].Image=$null}}
}

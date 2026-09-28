function Invoke-WebControlClick($Control) {
    $method=[Windows.Forms.Control].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($Control,@([EventArgs]::Empty))
}
function Set-WebOptions($Options,[string]$Page) {
    if($Page -eq 'clarity') {
        if($script:clarity.Busy){return}
        $script:clarity.Mode.SelectedItem=[string]$Options.mode
        $script:clarity.Prompt.Text=[string]$Options.prompt
        $script:clarity.Format.SelectedItem=[string]$Options.format
        $script:clarity.SameFolder.Checked=[bool]$Options.sameFolder
        $script:clarity.Strength.SelectedItem=[string]$Options.strength
        $script:clarity.Scale.SelectedIndex=[Math]::Clamp([int]$Options.scale,0,2)
        $script:clarity.ImageType.SelectedItem=[string]$Options.imageType
    } else {
        if($script:isConverting){return}
        $formatCombo.SelectedIndex=switch([string]$Options.format){'png'{1}'webp'{2}'source'{3}'pdf'{4}'docx'{5}'pptx'{6}default{0}}
        $sizeCombo.SelectedIndex=[Math]::Clamp([int]$Options.size,0,4)
        $finalWidthBox.Value=[Math]::Clamp([int]$Options.width,1,50000);$finalHeightBox.Value=[Math]::Clamp([int]$Options.height,1,50000)
        $preserveAlphaCheck.Checked=[bool]$Options.alpha;$sameFolder.Checked=[bool]$Options.sameFolder;$openFolderCheck.Checked=[bool]$Options.openFolder
        $script:customNamingEnabled=[bool]$Options.customNameEnabled
        $requestedPrefix=[string]$Options.namePrefix
        $script:customNamePrefix=if($requestedPrefix -in @('主图','副图','A','A+')){$requestedPrefix}else{'主图'}
        $script:customNameStart=[Math]::Clamp([int]$Options.nameSuffix,1,999999)
        if($script:customNamePrefix -eq 'A'){$sizeCombo.SelectedIndex=2;$finalWidthBox.Value=1464;$finalHeightBox.Value=600}else{$sizeCombo.SelectedIndex=1;$finalWidthBox.Value=1650;$finalHeightBox.Value=1650}
        Save-AppState
    }
}
function Get-WebPreview($Box) {
    if(-not $Box.Image){return ''}
    $stream=[IO.MemoryStream]::new()
    try{$Box.Image.Save($stream,[Drawing.Imaging.ImageFormat]::Png);return 'data:image/png;base64,'+[Convert]::ToBase64String($stream.ToArray())}finally{$stream.Dispose()}
}
function Send-WebState([switch]$IncludePreviews) {
    if(-not $script:webHost.Loaded){return}
    $config=@{};foreach($key in @('Protocol','Endpoint','Model','Prompt','AuthHeader','AuthPrefix','ImageField','ImageEncoding','ResponseType','ResponsePath','TimeoutSeconds','FieldsJson')){$config[$key]=$script:imageApiConfig[$key]}
    $reportContent=''; if(-not [string]::IsNullOrWhiteSpace([string]$script:lastBatchReportPath) -and (Test-Path -LiteralPath $script:lastBatchReportPath -PathType Leaf)){try{$reportContent=[IO.File]::ReadAllText($script:lastBatchReportPath,[Text.Encoding]::UTF8)}catch{}}
    $conversion=@{items=@($list.Items|ForEach-Object{@{name=$_.Text;checked=$_.Checked;dimensions=$_.SubItems[1].Text;size=$_.SubItems[2].Text;status=$_.SubItems[3].Text}});busy=$script:isConverting;status=$status.Text;progress=$progressBar.Value;format=@('jpg','png','webp','source','pdf','docx','pptx')[$formatCombo.SelectedIndex];size=$sizeCombo.SelectedIndex;width=$finalWidthBox.Value;height=$finalHeightBox.Value;alpha=$preserveAlphaCheck.Checked;sameFolder=$sameFolder.Checked;openFolder=$openFolderCheck.Checked;output=$outputBox.Text;customNameEnabled=[bool]$script:customNamingEnabled;namePrefix=[string]$script:customNamePrefix;nameSuffix=[int]$script:customNameStart;batchReportPath=[string]$script:lastBatchReportPath;batchReportContent=$reportContent;batchReportOutputDirectory=[string]$script:lastOutputDirectory}
    $clarityState=@{items=@($script:clarity.List.Items|ForEach-Object{@{name=$_.Text;checked=$_.Checked;status=$_.SubItems[1].Text;reason=$_.ToolTipText}});busy=$script:clarity.Busy;status=$script:clarity.Status.Text;progress=$script:clarity.Progress.Value;format=$script:clarity.Format.Text;mode=$script:clarity.Mode.Text;strength=$script:clarity.Strength.Text;scale=$script:clarity.Scale.SelectedIndex;imageType=$script:clarity.ImageType.Text;sameFolder=$script:clarity.SameFolder.Checked;output=$script:clarity.Output.Text}
    foreach($pair in @(@('conversion','original',$conversion,$previewBox),@('conversion','result',$conversion,$resultPreviewBox),@('clarity','original',$clarityState,$script:clarity.Original),@('clarity','result',$clarityState,$script:clarity.Result))){
        $key=$pair[0]+'-'+$pair[1]
        $image=$pair[3].Image
        $changed=-not $script:webPreviewCache.ContainsKey($key) -or -not [object]::ReferenceEquals($script:webPreviewCache[$key].Image,$image)
        if($changed){$script:webPreviewCache[$key]=@{Image=$image;Data=(Get-WebPreview $pair[3])}}
        if($IncludePreviews -or $changed){$pair[2][$pair[1]]=$script:webPreviewCache[$key].Data}
    }
    $organizerState=@{enabled=[bool]$script:organizerEnabled;path=$organizerPathBox.Text;pending=$script:organizerPending.Count;log=@($script:organizerLog);openSheet=$script:organizerOpenSpreadsheetEnabled;targetScreenEnabled=$script:organizerSpreadsheetScreenEnabled;targetScreen=($script:organizerSpreadsheetScreenIndex+1);screenCount=@([Windows.Forms.Screen]::AllScreens).Count;island=$script:dynamicIslandEnabled;sheets=@($spreadsheetList.Items|ForEach-Object {($_.SubItems|ForEach-Object Text)-join ' · '});sheetStatus=$spreadsheetStatus.Text;desktopScope=[string]$script:desktopOrganizeScope;desktopHistory=@(Get-DesktopOrganizationHistory -HistoryPath $script:desktopProductHistoryPath -RetentionDays 30)}
    $script:webHost.Send((@{type='state';conversion=$conversion;clarity=$clarityState;organizer=$organizerState;imageLink=(Get-ImageLinkWebState);localSearch=(Get-LocalSearchWebState);photoshop=(Get-PhotoshopAssistantWebState);storage=(Get-StorageManagerWebState);changelog=$script:webChangelog;config=$config;hasKey=[bool]$script:imageApiConfig.ProtectedKey}|ConvertTo-Json -Depth 10 -Compress))
}
function Send-WebToast([string]$Message) {
    if ($script:webHost.Loaded) { $script:webHost.Send((@{type='toast';message=$Message}|ConvertTo-Json -Compress)) }
}
function Invoke-OnlineUpdateCheck {
    $installDir = Split-Path $PSScriptRoot -Parent
    $configPath = Join-Path $installDir 'update-config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { Send-WebToast '未找到在线更新配置：update-config.json。'; return }
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not [bool]$config.enabled) { Send-WebToast '在线更新服务尚未启用。'; return }
        $manifestUrl = [string]$config.manifestUrl
        if ([string]$config.provider -eq 'github') {
            $repository = [string]$config.repository
            if ([string]::IsNullOrWhiteSpace($repository)) { Send-WebToast 'GitHub 仓库地址尚未配置。'; return }
            $manifestUrl = 'https://api.github.com/repos/' + $repository.Trim('/') + '/releases/latest'
        }
        if ([string]::IsNullOrWhiteSpace($manifestUrl) -or $manifestUrl -match 'your-domain\.example') { Send-WebToast '在线更新地址尚未配置。'; return }
        $timeout = [Math]::Max(1, [int]$config.timeoutSeconds)
        $response = Invoke-RestMethod -Uri $manifestUrl -TimeoutSec $timeout -Headers @{ 'Cache-Control' = 'no-cache'; 'User-Agent' = 'ZhangLangQiang-App-Updater' }
        if ([string]$config.provider -eq 'github') {
            $asset = @($response.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1)
            if (-not $asset) { Send-WebToast 'GitHub 最新 Release 尚未上传 ZIP 更新包。'; return }
            $version = ([string]$response.tag_name).TrimStart('v')
            $versionPath = Join-Path $installDir 'version.json'
            $current = if (Test-Path -LiteralPath $versionPath) { [string](Get-Content $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json).version } else { '3.0.12' }
            if ([version]$version -le [version]$current) { Send-WebToast ("当前已是最新版本 v{0}。" -f $current); return }
            $digest = [string]$asset.digest
            if ($digest -match '^sha256:') { $digest = $digest.Substring(7) }
            if ([string]::IsNullOrWhiteSpace($digest)) {
                $shaNames = @($asset.name + '.sha256', ([IO.Path]::GetFileNameWithoutExtension($asset.name) + '.sha256'))
                $shaAsset = @($response.assets | Where-Object { $_.name -in $shaNames } | Select-Object -First 1)
                if ($shaAsset) {
                    $digest = ((Invoke-WebRequest -Uri ([string]$shaAsset.browser_download_url) -UseBasicParsing -TimeoutSec $timeout -Headers @{ 'User-Agent' = 'ZhangLangQiang-App-Updater' }).Content.Trim() -split '\s+')[0]
                }
            }
            if ([string]::IsNullOrWhiteSpace($digest)) { Send-WebToast 'GitHub 更新包缺少 SHA-256 校验值。'; return }
            $manifest = [pscustomobject]@{ version=$version; notes=[string]$response.body; packageUrl=[string]$asset.browser_download_url; sha256=$digest }
        } else { $manifest = $response }
        $versionPath = Join-Path $installDir 'version.json'
        $current = if (Test-Path -LiteralPath $versionPath) { [string](Get-Content $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json).version } else { '3.0.12' }
        $available = [string]$manifest.version
        if ([version]$available -le [version]$current) { Send-WebToast ("当前已是最新版本 v{0}。" -f $current); return }
        $answer = [Windows.Forms.MessageBox]::Show(("发现新版本 v{0}。`n`n{1}`n`n现在下载并安装吗？" -f $available,[string]$manifest.notes),'蟑螂强 APP · 发现更新','YesNo','Information')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
        $updater = Join-Path $installDir 'PngToJpgUpdater.exe'
        if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) { Send-WebToast '当前安装缺少更新器，请先安装包含在线更新组件的版本。'; return }
        $updaterCopy = Join-Path ([IO.Path]::GetTempPath()) ('PngToJpgUpdater_' + [guid]::NewGuid().ToString('N') + '.exe')
        Copy-Item -LiteralPath $updater -Destination $updaterCopy -Force
        Start-Process -FilePath $updaterCopy -ArgumentList @('--install-dir',$installDir,'--package-url',[string]$manifest.packageUrl,'--sha256',[string]$manifest.sha256,'--restart',(Join-Path $installDir 'PngToJpgLauncher.exe'))
        Send-WebToast '更新包已开始下载，程序将自动重启完成更新。'
        $form.BeginInvoke([Action]{ $form.Close() }) | Out-Null
    } catch { Send-WebToast ('检查在线更新失败：' + $_.Exception.Message) }
}
function Handle-WebMessage($Message) {
    if ($null -eq $Message -or $null -eq $Message['action']) { return }
    $page=[string]$Message['page']
    switch([string]$Message.action) {
        'ready' {if($page -eq 'storage'){[void](Get-StorageManagerWebState -Refresh)}}
        'readyShell' {$script:webForcePreviewState=$true}
        'checkForUpdate' { Invoke-OnlineUpdateCheck }
        'uiError' {throw ('HTML script error: '+$Message.message)}
        'drop' {$paths=[string[]]@();if($script:webHost.DroppedFiles.TryDequeue([ref]$paths)){if($page -eq 'clarity'){if(-not $script:clarity.Busy){Add-ClarityImages $paths}}elseif($page -eq 'organizer'){if([string]$Message.dropTarget -eq 'spreadsheets'){Add-SpreadsheetFoldersBatch -Paths $paths;Send-WebState}else{Add-OrganizerFoldersBatch -Paths $paths}}elseif($page -eq 'imageLink'){if($paths.Count){Add-ImageLinkImage $paths[0]}}elseif($page -eq 'localSearch'){if($paths.Count){Set-LocalSearchReference $paths[0]}}elseif($page -eq 'conversion' -and -not $script:isConverting){Add-ImageFiles $paths}}}
        'captured' {
            if($SmokeTestWebUi){
                $script:webTestStage++
                if($script:webTestStage -lt 9){[void]$script:webHost.CoreWebView2.ExecuteScriptAsync("navigatePage('$(@('conversion','clarity','organizer','imageLink','localSearch','photoshop','storage','changelog','preferences')[$script:webTestStage])')")}
                elseif($script:webTestStage -eq 9){$script:webTestLaunchedStage=9;[void]$script:webHost.CoreWebView2.ExecuteScriptAsync((Get-Content (Join-Path $PSScriptRoot '..\tests\Settings.Nested.Smoke.js') -Raw))}
                else{$form.Close();Write-Host 'WebView2: conversion, clarity, organizer, image link, local search, Photoshop assistant, storage manager, changelog, preferences and clarity API settings passed.'}
            }
        }
        'uiCheck' {
            if($SmokeTestWebUi){
                if($page -ne @('conversion','clarity','organizer','imageLink','localSearch','photoshop','storage','changelog','preferences','settings')[$script:webTestStage] -or $script:webCaptureStage -eq $script:webTestStage){return}
                if(-not $Message.ok){$script:webTestError=[string]$Message.detail;$form.Close();return}
                $script:webCaptureStage=$script:webTestStage
                $script:webHost.CapturePage((Join-Path $script:webArtifactDirectory (@('web-conversion.png','web-clarity.png','web-organizer.png','web-image-link.png','web-local-search.png','web-photoshop.png','web-storage.png','web-changelog.png','web-preferences.png','web-settings.png')[$script:webTestStage])))
            }
        }
        'options' {Set-WebOptions $Message.options $page}
        'imageLinkOptions' {Set-ImageLinkOptions $Message.options}
        'add' {
            $dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.Multiselect=$true;$dialog.Filter=if($page -eq 'conversion'){'图片与文档|*.png;*.jpg;*.jpeg;*.jfif;*.webp;*.pdf;*.doc;*.docx;*.ppt;*.pptx|图片|*.png;*.jpg;*.jpeg;*.jfif;*.webp|PDF|*.pdf|Word|*.doc;*.docx|PowerPoint|*.ppt;*.pptx'}else{'图片|*.png;*.jpg;*.jpeg;*.jfif;*.webp'}
            try{if($dialog.ShowDialog($form) -eq 'OK'){if($page -eq 'clarity'){Add-ClarityImages $dialog.FileNames}elseif($page -eq 'imageLink'){Add-ImageLinkImage $dialog.FileNames[0]}else{Add-ImageFiles $dialog.FileNames}}}finally{$dialog.Dispose()}
        }
        'clear' {if($page -eq 'clarity'){if(-not $script:clarity.Busy){Invoke-WebControlClick $script:clarity.Clear}}elseif(-not $script:isConverting){Invoke-WebControlClick $clearButton}}
        'select' {
            $targetList=if($page -eq 'clarity'){$script:clarity.List}else{$list};$index=[int]$Message.index
            if($index -ge 0 -and $index -lt $targetList.Items.Count){foreach($item in $targetList.Items){$item.Selected=$false};$targetList.Items[$index].Selected=$true;if($page -eq 'clarity'){Update-ClarityPreview}else{Show-ImagePreview ([string]$targetList.Items[$index].Tag)}}
        }
        'check' {$targetList=if($page -eq 'clarity'){$script:clarity.List}else{$list};$i=[int]$Message.index;if($i -ge 0 -and $i -lt $targetList.Items.Count){$targetList.Items[$i].Checked=[bool]$Message.value}}
        'checkAll' {$targetList=if($page -eq 'clarity'){$script:clarity.List}else{$list};foreach($item in $targetList.Items){$item.Checked=[bool]$Message.value};if($page -eq 'clarity'){Save-ClarityState}}
        'invert' {Invoke-WebControlClick $invertButton}
        'searchText' {$searchBox.Text=[string]$Message.value}
        'browse' {if($page -eq 'clarity'){Invoke-WebControlClick $script:clarity.Browse}else{Invoke-WebControlClick $browseButton}}
        'start' {Set-WebOptions $Message.options $page;if($page -eq 'clarity'){if(-not $script:clarity.Busy){Start-ClarityBatch}}elseif(-not $script:isConverting){Invoke-WebControlClick $convertButton}}
        'cancel' {if($page -eq 'clarity'){Invoke-WebControlClick $script:clarity.Cancel}else{Invoke-WebControlClick $cancelButton}}
        'saveConfig' {try{Save-WebApiConfig $Message.config}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'validateConfig' {try{Save-WebApiConfig $Message.config -ValidateOnly}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'imageLinkSaveConfig' {try{Save-ImageLinkSettings -AccountId ([string]$Message.accountId) -Bucket ([string]$Message.bucket) -PublicBaseUrl ([string]$Message.publicBaseUrl) -AccessKey ([string]$Message.accessKey) -SecretKey ([string]$Message.secretKey) -ClearCredentials:([bool]$Message.clearCredentials);Send-WebState;$script:webHost.Send('{"type":"imageLinkSaved"}')}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'imageLinkStart' {try{Set-ImageLinkOptions $Message.options;Start-ImageLinkUpload}catch{$script:imageLink.Status='上传失败：'+$_.Exception.Message;$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'imageLinkCancel' {Stop-ImageLinkRequest -Cancelled;$script:imageLink.Status='上传已取消';$script:imageLink.Progress=0}
        'imageLinkClear' {Clear-ImageLinkImage}
        'localSearchOptions' {Set-LocalSearchOptions $Message.options}
        'localSearchBrowseRoot' {$dialog=[Windows.Forms.FolderBrowserDialog]::new();$dialog.Description='选择要递归搜索的本地文件夹';try{if($dialog.ShowDialog($form) -eq 'OK'){Set-LocalSearchRoot $dialog.SelectedPath}}finally{$dialog.Dispose()}}
        'localSearchRemoveRoot' {Remove-LocalSearchRoot ([int]$Message.index)}
        'localSearchChooseImage' {$dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.Multiselect=$false;$dialog.Filter='图片|*.png;*.jpg;*.jpeg;*.jfif;*.bmp;*.gif;*.tif;*.tiff;*.webp;*.avif;*.heic;*.heif';try{if($dialog.ShowDialog($form) -eq 'OK'){Set-LocalSearchReference $dialog.FileName}}finally{$dialog.Dispose()}}
        'localSearchStart' {try{Set-LocalSearchOptions $Message.options;Start-LocalSearch}catch{$script:localSearch.Status='搜索失败：'+$_.Exception.Message;$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'localSearchCancel' {Stop-LocalSearch -Cancelled}
        'localSearchClear' {Clear-LocalSearch}
        'localSearchOpenFile' {try{Open-LocalSearchResult ([int]$Message.index)}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'localSearchOpenFolder' {try{Open-LocalSearchResult ([int]$Message.index) -Folder}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'photoshopOptions' {Set-PhotoshopAssistantOptions $Message.options}
        'photoshopDetect' {try{Start-PhotoshopDetection}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'photoshopRefresh' {try{Start-PhotoshopDetection}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'photoshopBrowseOutput' {try{Select-PhotoshopOutputDirectory $form}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'photoshopExport' {try{Start-PhotoshopExport $Message.options}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'photoshopOpenOutput' {try{Open-PhotoshopOutputDirectory}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'storageScan' {try{[void](Get-StorageManagerWebState -Refresh);Send-WebState}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'storageOpen' {try{Open-StorageCategory ([string]$Message.category)}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'storageDelete' {try{$result=Remove-StorageSelectedFiles ([string]$Message.category) ([string[]]$Message.paths);[void](Get-StorageManagerWebState -Refresh);Send-WebState;$script:webHost.Send((@{type='storageDeleteResult';result=$result}|ConvertTo-Json -Depth 6 -Compress))}catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'organizerBrowse' {Invoke-WebControlClick $organizerPathBrowseButton;Send-WebState}
        'organizerStart' {if(-not $script:organizerEnabled){[void](Start-DesktopOrganizer -Path $organizerPathBox.Text)}}
        'organizerStop' {Stop-DesktopOrganizer}
        'organizerSingle' {Invoke-WebControlClick $organizerSingleButton}
        'organizerBatch' {Invoke-WebControlClick $organizerBatchButton}
        'organizerOpen' {Open-DesktopOrganizerPath}
        'organizerClearLog' {$script:organizerLog.Clear();$organizerLogList.Items.Clear()}
        'organizerOptions' {$organizerSpreadsheetToggle.Checked=[bool]$Message.openSheet;$organizerSpreadsheetScreenToggle.Checked=[bool]$Message.targetScreenEnabled;$targetScreen=[Math]::Max(1,[Math]::Min($organizerSpreadsheetScreenCombo.Items.Count,[int]$Message.targetScreen));$organizerSpreadsheetScreenCombo.SelectedIndex=$targetScreen-1;$organizerIslandToggle.Checked=[bool]$Message.island}
        'desktopOrganizeScope' {if(([string]$Message.scope) -in @('left','center','right','all')){$script:desktopOrganizeScope=[string]$Message.scope}}
        'desktopProductOrganize' {try{$result=Invoke-DesktopProductOrganizationUi -Scope $script:desktopOrganizeScope;Send-WebState;$script:webHost.Send((@{type='organizerResult';message=("整理完成：编号 {0}，已移动 {1} 个文件。" -f $result.Code,$result.MovedCount)}|ConvertTo-Json -Compress))}catch{Write-DesktopOrganizerLog ('桌面成品整理已停止：'+$_.Exception.Message);Send-WebState;$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'desktopProductUndo' {try{$result=Undo-DesktopProductOrganizationUi -RecordId ([string]$Message.recordId);Send-WebState;$script:webHost.Send((@{type='organizerResult';message=("恢复完成：已放回桌面 {0} 个文件。" -f $result.UndoneCount)}|ConvertTo-Json -Compress))}catch{Write-DesktopOrganizerLog ('恢复失败：'+$_.Exception.Message);Send-WebState;$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress))}}
        'spreadsheetAdd' {Invoke-WebControlClick $spreadsheetAddParentButton}
        'spreadsheetClear' {Clear-SpreadsheetFolderQueue}
        'spreadsheetOpen' {Open-QueuedSpreadsheets}
        'openBatchReport' { Open-LastBatchReport }
        'openBatchReportFolder' {
            if([string]::IsNullOrWhiteSpace([string]$script:lastOutputDirectory) -or -not (Test-Path -LiteralPath $script:lastOutputDirectory -PathType Container)){throw '当前没有可打开的批次输出文件夹。'}
            Start-Process -FilePath 'explorer.exe' -ArgumentList @($script:lastOutputDirectory)
        }
        'exportLog' {$dialog=[Windows.Forms.SaveFileDialog]::new();$dialog.Filter='Markdown|*.md';$dialog.FileName='蟑螂强-更新日志.md';try{if($dialog.ShowDialog($form) -eq 'OK'){[IO.File]::WriteAllText($dialog.FileName,$script:webChangelog,[Text.UTF8Encoding]::new($false))}}finally{$dialog.Dispose()}}
    }
}
function Save-WebApiConfig($Fields,[switch]$ValidateOnly) {
    $config=$script:imageApiConfig.Clone()
    foreach($key in @('Protocol','Endpoint','Model','Prompt','AuthHeader','AuthPrefix','ImageField','ImageEncoding','ResponseType','ResponsePath','TimeoutSeconds','FieldsJson')){if($Fields.Contains($key)){$config[$key]=$Fields[$key]}}
    $config.TimeoutSeconds=[int]$config.TimeoutSeconds
    if($Fields.ClearKey){$config.ProtectedKey=''}
    if($Fields.ApiKey -and [string]$Fields.ApiKey -ne '************'){$config.ProtectedKey=ConvertFrom-SecureString (ConvertTo-SecureString ([string]$Fields.ApiKey) -AsPlainText -Force)}
    Test-ImageApiConfig $config
    if($ValidateOnly){$script:webHost.Send('{"type":"validated","message":"配置格式检查通过；未发起图片请求，也未检测服务在线状态。"}');return}
    $path=Join-Path $script:dataDirectory 'image-api.json';[void][IO.Directory]::CreateDirectory($script:dataDirectory)
    [IO.File]::WriteAllText(($path+'.tmp'),($config|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));[IO.File]::Move(($path+'.tmp'),$path,$true)
    $script:imageApiConfig=$config;$script:clarity.Prompt.Text=[string]$config.Prompt;Update-ClarityMode
    Send-WebState
    $script:webHost.Send('{"type":"saved"}')
}
function Start-FileConverterService {
    $script:fileConverterPort = 8765
    $script:fileConverterScript = Join-Path $PSScriptRoot '..\web\file-converter\Server.ps1'
    $script:fileConverterProcess = $null
    if (-not (Test-Path $script:fileConverterScript)) { return }
    try {
        $script:fileConverterProcess = Start-Process -FilePath 'pwsh.exe' -ArgumentList '-NoLogo','-NoProfile','-File',"$script:fileConverterScript" -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
        if ($script:fileConverterProcess) {
            Write-Host "File Converter service started (PID: $($script:fileConverterProcess.Id))" -ForegroundColor Gray
        }
    } catch {
        Write-Host "Failed to start File Converter service: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
function Stop-FileConverterService {
    if ($script:fileConverterProcess -and -not $script:fileConverterProcess.HasExited) {
        try { $script:fileConverterProcess | Stop-Process -Force -ErrorAction SilentlyContinue }
        catch {}
    }
    $script:fileConverterProcess = $null
}
function Start-WebUi {
    $script:webChangelog=Get-Content (Join-Path $PSScriptRoot '..\CHANGELOG.md') -Raw
    $script:clarity.Prompt=[Windows.Forms.TextBox]::new();$script:clarity.Prompt.Text=[string]$script:imageApiConfig.Prompt
    $dll=Join-Path $PSScriptRoot '..\tools\webview2'
    [void][Runtime.InteropServices.NativeLibrary]::Load((Join-Path $dll 'WebView2Loader.dll'))
    $core=Join-Path $dll 'Microsoft.Web.WebView2.Core.dll';$forms=Join-Path $dll 'Microsoft.Web.WebView2.WinForms.dll'
    Add-Type -Path $core;Add-Type -Path $forms
    $references=@(Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName)+@($winFormsTypeReferences)+@($core,$forms,[Collections.Concurrent.ConcurrentQueue[string]].Assembly.Location,(Join-Path $PSHOME 'ref\System.Collections.dll'),(Join-Path $PSHOME 'ref\System.Runtime.dll'),(Join-Path $PSHOME 'ref\System.Runtime.InteropServices.dll'))
    Add-Type -Path (Join-Path $PSScriptRoot 'WebUiHost.cs') -ReferencedAssemblies ($references|Select-Object -Unique) -CompilerOptions /nowarn:1701,1702
    $script:webHost=[StitchWebHost]::new();$script:webHost.Dock='Fill';$script:webHost.DefaultBackgroundColor=[Drawing.Color]::White
    $script:webPreviewCache=@{}
    $script:webForcePreviewState=$true
    $script:webNextStateUtc=[DateTime]::MinValue
    if($SmokeTestWebUi) {
        [void][IO.Directory]::CreateDirectory($script:dataDirectory)
        $fixture=Join-Path $script:dataDirectory 'web-fixture.png'
        & $script:magickPath -size 160x120 gradient:blue-white $fixture
        Add-ImageFiles @($fixture);Add-ClarityImages @($fixture)
        Add-ImageLinkImage $fixture
        $script:imageLink.AccountId='test-account';$script:imageLink.Bucket='amazon-images';$script:imageLink.PublicBaseUrl='https://pub-example.r2.dev';$script:imageLink.ProtectedAccessKey=ConvertFrom-SecureString (ConvertTo-SecureString 'test-access' -AsPlainText -Force);$script:imageLink.ProtectedSecretKey=ConvertFrom-SecureString (ConvertTo-SecureString 'test-secret' -AsPlainText -Force)
        $script:imageLink.Result=ConvertTo-ImageLinkResult 'https://pub-example.r2.dev/images/fixture.png' 'fixture.png'
        $script:imageLink.Status='离线界面测试：示例链接已生成';$script:imageLink.Progress=100
        $script:localSearch.Root=$script:dataDirectory;$script:localSearch.Query='ABC123';$script:localSearch.Status='离线界面测试：找到 3 项';$script:localSearch.Progress=100
        $script:localSearch.ReferencePath=$fixture;$script:localSearch.ReferenceName='web-fixture.png';$script:localSearch.ReferencePreview=Get-LocalSearchReferencePreview $fixture
        $script:localSearch.Results=@([PSCustomObject]@{Name='ABC123';Path=(Join-Path $script:dataDirectory 'ABC123');RelativePath='商品\ABC123';Kind='文件夹';Size=0;IsDirectory=$true;Similarity=100;Exact=$true;Preview=''},[PSCustomObject]@{Name='ABC123_主图.jpg';Path=(Join-Path $script:dataDirectory 'ABC123_主图.jpg');RelativePath='商品\ABC123_主图.jpg';Kind='JPG';Size=245760;IsDirectory=$false;Similarity=100;Exact=$true;Preview=(Get-WebPreview $previewBox)},[PSCustomObject]@{Name='ABC123_副图.png';Path=(Join-Path $script:dataDirectory 'ABC123_副图.png');RelativePath='商品\ABC123_副图.png';Kind='PNG';Size=181240;IsDirectory=$false;Similarity=96.8;Exact=$false;Preview=(Get-WebPreview $previewBox)})
        $script:photoshopAssistant.Running=$true;$script:photoshopAssistant.Detected=$true;$script:photoshopAssistant.Version='26.5.0';$script:photoshopAssistant.VersionLabel='Photoshop 2025 (26.5.0)';$script:photoshopAssistant.ProcessId=24680;$script:photoshopAssistant.FileName='ABC123.psd';$script:photoshopAssistant.PsdPath=(Join-Path $script:dataDirectory 'ABC123.psd');$script:photoshopAssistant.Width=1650;$script:photoshopAssistant.Height=1650;$script:photoshopAssistant.Saved=$true;$script:photoshopAssistant.Status='已读取当前 Photoshop 文件';$script:photoshopAssistant.OutputFiles=@()
        foreach($storageFixture in @('preview\preview-fixture.png','temp\conversion-fixture.tmp','search_index\index-fixture.json','logs\fixture.log')){$storageFixturePath=Join-Path $script:dataDirectory $storageFixture;[void][IO.Directory]::CreateDirectory((Split-Path $storageFixturePath));[IO.File]::WriteAllText($storageFixturePath,('x'*2048))}
        $openFolderCheck.Checked=$false
        $script:organizerPath=Join-Path $script:dataDirectory 'MonitorFixture';[void][IO.Directory]::CreateDirectory($script:organizerPath);$organizerPathBox.Text=$script:organizerPath
        $historyFixtureId=New-DesktopOrganizationRecordId;$historyFixture=[PSCustomObject]@{Version=2;RecordId=$historyFixtureId;CreatedAt=[DateTimeOffset]::Now.ToString('o');DesktopPath=$script:dataDirectory;Code='ABC123';ProjectFolder=$script:organizerPath;CreatedDirectories=@();Moves=@()};Save-DesktopOrganizationManifest -Path (Join-Path $script:desktopProductHistoryPath ($historyFixtureId+'.json')) -Manifest $historyFixture
    }
    $script:webTestStage=0;$script:webTestError='';$script:webCheckQueued=$false;$script:webTestStarted=[DateTime]::UtcNow
    $script:webTestLaunchedStage=-1;$script:webCaptureStage=-1
    $script:webArtifactDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\tests\artifacts'))
    [void][IO.Directory]::CreateDirectory($script:webArtifactDirectory)
    $form.Text='蟑螂强';$form.Padding=[Windows.Forms.Padding]::new(0);$appShell.Visible=$false
    $verticalScrollSyncTimer.Stop()
    $dpiScale=$form.DeviceDpi/96.0
    $workArea=[Windows.Forms.Screen]::FromControl($form).WorkingArea
    $form.MinimumSize=[Drawing.Size]::new([Math]::Min(1180*$dpiScale,$workArea.Width),[Math]::Min(780*$dpiScale,$workArea.Height))
    $form.Size=[Drawing.Size]::new([Math]::Min(1320*$dpiScale,$workArea.Width),[Math]::Min(900*$dpiScale,$workArea.Height))
    if($SmokeTestWebUi){Write-Host "DPI mode: $([Windows.Forms.Application]::HighDpiMode); window DPI: $($form.DeviceDpi); physical size: $($form.Width)x$($form.Height)"}
    [void]$list.Handle;[void]$script:clarity.List.Handle
    foreach($control in @($minimizeButton,$maximizeButton,$closeWindowButton)){$control.Visible=$false}
    $form.Controls.Add($script:webHost);$script:webHost.BringToFront()
    Start-FileConverterService
    $form.Add_Shown({$verticalScrollSyncTimer.Stop();$script:webHost.BringToFront();$script:webHost.Start((Join-Path $PSScriptRoot '..\web'),(Join-Path $script:dataDirectory 'webview-profile'))})
    foreach($button in @($homeNavigationButton,$imageApiNavigationButton)){$button.Add_Click({$script:webHost.Visible=$true;$form.Padding=[Windows.Forms.Padding]::new(0);$script:webHost.BringToFront();[void]$script:webHost.CoreWebView2.ExecuteScriptAsync("navigatePage('$(if($script:activePage -eq 'Enhancement'){'clarity'}else{'conversion'})')")})}
    $script:webTimer=[Windows.Forms.Timer]::new();$script:webTimer.Interval=100
    $script:webTimer.Add_Tick({
        try {
            if($script:webHost.Failure){throw $script:webHost.Failure}
            $handledMessage=$false
            $message='';while($script:webHost.Messages.TryDequeue([ref]$message)) {
                $handledMessage=$true
                $parsed=$message|ConvertFrom-Json -AsHashtable
                if($SmokeTestWebUi -and $parsed.action -eq 'ready' -and $script:webTestLaunchedStage -ne $script:webTestStage -and $parsed.page -eq @('conversion','clarity','organizer','imageLink','localSearch','photoshop','storage','changelog','preferences','settings')[$script:webTestStage]){
                    $script:webTestLaunchedStage=$script:webTestStage
                    if($parsed.page -eq 'storage'){[void](Get-StorageManagerWebState -Refresh)}
                    Send-WebState -IncludePreviews
                    $testCode=Get-Content (Join-Path $PSScriptRoot '..\tests\WebUi.Smoke.js') -Raw
                    if($script:webTestStage -lt 9){$testCode="document.querySelector('iframe.active').contentWindow.eval("+($testCode|ConvertTo-Json -Compress)+")"}
                    [void]$script:webHost.CoreWebView2.ExecuteScriptAsync($testCode)
                }
                Handle-WebMessage $parsed
            }
            $now=[DateTime]::UtcNow
            Poll-ImageLinkUpload
            Poll-LocalSearch
            Poll-PhotoshopAssistant
            if($handledMessage -or $now -ge $script:webNextStateUtc){
                Send-WebState -IncludePreviews:$script:webForcePreviewState
                $script:webForcePreviewState=$false
                $isActive=[bool]($script:isConverting -or $script:clarity.Busy -or $script:imageLink.Busy -or $script:localSearch.Busy -or $script:photoshopAssistant.Busy -or $script:previewProcess -or $script:clarity.PreviewProcess -or $script:organizerWorkerProcess -or $script:organizerPending.Count)
                $script:webTimer.Interval=if($isActive){100}else{150}
                $script:webNextStateUtc=$now.AddMilliseconds($(if($isActive){350}else{1500}))
            }
            if($SmokeTestWebUi -and ([DateTime]::UtcNow-$script:webTestStarted).TotalSeconds -gt 180){throw "Web UI test timed out at stage $($script:webTestStage)"}
        }catch{$script:webHost.Send((@{type='error';message=$_.Exception.Message}|ConvertTo-Json -Compress));if($SmokeTestWebUi){$script:webTestError=$_.Exception.Message;$form.Close()}}
    });$script:webTimer.Start()
    $form.Add_FormClosed({$script:webTimer.Stop();$script:webTimer.Dispose();Stop-FileConverterService})
}








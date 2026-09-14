param([string]$AppPath = (Join-Path $PSScriptRoot '..\PngToJpg.ps1'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot '..\modules\FolderOrganizer.ps1')
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($AppPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'App parse failed' }
foreach ($name in @('Start-DesktopOrganizer','Stop-DesktopOrganizer','Add-DesktopOrganizerPending','Remove-DesktopOrganizerPending','Invoke-DesktopOrganizerQueue')) {
    $node = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    Invoke-Expression $node.Extent.Text
}
function Write-DesktopOrganizerLog { param($Message) }
function Update-DynamicIslandContent {}
function Update-DesktopOrganizerUi {}
function Save-AppState {}
function Set-DynamicIslandTemporaryMessage { param($Title,$Detail) }
function Remove-JobTemporaryDirectory { param($Path) }
function Assert { param($Value,$Message) if (-not $Value) { throw $Message } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('OrganizerStartup_' + [guid]::NewGuid().ToString('N'))
$defaultDesktopPath = Join-Path $root 'Desktop'
$download = Join-Path $root 'Downloads'
$offline = Join-Path $download 'OfflineProject'
[void][IO.Directory]::CreateDirectory($defaultDesktopPath)
[void][IO.Directory]::CreateDirectory($offline)
[IO.File]::WriteAllText((Join-Path $offline 'download.txt'), 'offline download')
$outside = Join-Path $defaultDesktopPath 'Unrelated'
[void][IO.Directory]::CreateDirectory($outside)
$form = [Windows.Forms.Form]::new()
[void]$form.Handle
$script:organizerTimer = [Windows.Forms.Timer]::new()
$script:organizerPending = @{}
$script:organizerProcessed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:organizerWatcher = $null
$script:organizerWorkerProcess = $null
$script:organizerWorkerJob = $null
$script:organizerEnabled = $false
$script:organizerMinimumAgeSeconds = 5
$script:organizerIdlePollMilliseconds = 2000
$script:organizerActivePollMilliseconds = 200
$script:organizerQueueRunning = $false
$script:organizerOpenSpreadsheetEnabled = $false
$script:taskTempRoot = Join-Path $root 'Jobs'
$script:folderOrganizerScriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\modules\FolderOrganizer.ps1'))
$script:folderOrganizerWorkerScriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\modules\FolderOrganizerWorker.ps1'))
$script:powerShellPath = (Get-Process -Id $PID).Path
try {
    Assert (Start-DesktopOrganizer -Path $download -Quiet) 'Startup failed'
    Assert ($script:organizerPending.ContainsKey($offline)) 'Missed folder downloaded before startup'
    Assert ($script:organizerPending.Count -eq 1) 'Queued unrelated folder'
    Add-DesktopOrganizerPending -Path $offline
    Assert ($script:organizerPending.Count -eq 1) 'Duplicate queued'
    Invoke-DesktopOrganizerQueue
    Assert ($null -eq $script:organizerWorkerProcess) 'Skipped download stability wait'
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    $destination = Join-Path $defaultDesktopPath 'OfflineProject\OfflineProject 源文件\download.txt'
    while (-not (Test-Path -LiteralPath $destination) -and [DateTime]::UtcNow -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
        Invoke-DesktopOrganizerQueue
        Start-Sleep -Milliseconds 100
    }
    Assert (Test-Path -LiteralPath $destination) 'Offline download not organized and moved'
    Assert ((Get-Content -LiteralPath $destination -Raw) -eq 'offline download') 'Content changed'
    Assert (Start-DesktopOrganizer -Path $download -Quiet) 'Restart failed'
    Assert ($script:organizerPending.Count -eq 0) 'Processed folder queued again'
    $online = Join-Path $download 'OnlineProject'
    [void][IO.Directory]::CreateDirectory($online)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not $script:organizerPending.ContainsKey($online) -and [DateTime]::UtcNow -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    Assert ($script:organizerPending.ContainsKey($online)) 'Live monitoring regressed'
    Assert (Test-Path -LiteralPath $outside) 'Unrelated desktop folder changed'
    Write-Output 'PASS: offline catch-up, stability wait, deduplication, real worker output, restart and live monitoring.'
}
finally {
    Stop-DesktopOrganizer -PreserveEnabledPreference
    $script:organizerTimer.Dispose()
    $form.Dispose()
}

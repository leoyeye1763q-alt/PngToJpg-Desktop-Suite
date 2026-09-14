param(
    [string]$AppPath = (Join-Path $PSScriptRoot '..\PngToJpg.ps1'),
    [string]$ReportPath,
    [switch]$BenchmarkOnly,
    [int]$FolderCount = 6
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$appRoot = Split-Path -Parent ([IO.Path]::GetFullPath($AppPath))
. (Join-Path $appRoot 'modules\FolderOrganizer.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($AppPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'App parse failed' }
foreach ($name in @('Start-DesktopOrganizer','Stop-DesktopOrganizer','Add-DesktopOrganizerPending','Remove-DesktopOrganizerPending','Invoke-DesktopOrganizerQueue','Add-OrganizerFoldersBatch')) {
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}, $true)
    Invoke-Expression $node.Extent.Text
}
$script:organizerIdlePollMilliseconds = 2000
$script:organizerActivePollMilliseconds = 200
$script:organizerQueueRunning = $false
$script:queueFailure = $null
foreach ($name in @('organizerMinimumAgeSeconds','organizerIdlePollMilliseconds','organizerActivePollMilliseconds')) {
    $variableName = '$script:' + $name
    $node = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $variableName}, $true)
    if ($node) { Invoke-Expression $node.Extent.Text }
}
function Assert { param($Value,$Message) if (-not $Value) { throw $Message } }
function Write-DesktopOrganizerLog { param($Message) $script:logs.Add([string]$Message) }
function Update-DynamicIslandContent {}
function Update-DesktopOrganizerUi {}
function Save-AppState {}
function Set-DynamicIslandTemporaryMessage { param($Title,$Detail) }
function Remove-JobTemporaryDirectory { param($Path) }
function Open-SpreadsheetFile { param($Path) $script:opened.Add([string]$Path) }
function Wait-Queue {
    param([int]$TimeoutSeconds = 45)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (($script:organizerPending.Count -gt 0 -or $script:organizerWorkerProcess) -and [DateTime]::UtcNow -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
        if ($script:queueFailure) { throw $script:queueFailure }
        Start-Sleep -Milliseconds 10
    }
    Assert ($script:organizerPending.Count -eq 0 -and -not $script:organizerWorkerProcess) ('Queue timeout: ' + ($script:logs -join '; '))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('OrganizerQueue_' + [guid]::NewGuid().ToString('N'))
$defaultDesktopPath = Join-Path $root 'Desktop'
$download = Join-Path $root 'Downloads'
$manual = Join-Path $root 'Manual'
foreach ($directory in @($defaultDesktopPath,$download,$manual)) { [void][IO.Directory]::CreateDirectory($directory) }
$form = [Windows.Forms.Form]::new()
[void]$form.Handle
$script:organizerTimer = [Windows.Forms.Timer]::new()
$script:organizerTimer.Interval = $script:organizerIdlePollMilliseconds
$script:organizerTimer.Add_Tick({
    try { Invoke-DesktopOrganizerQueue }
    catch { $script:queueFailure = $_; $script:organizerTimer.Stop() }
})
$script:organizerPending = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$script:organizerProcessed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:organizerWatcher = $null
$script:organizerWorkerProcess = $null
$script:organizerWorkerJob = $null
$script:organizerEnabled = $false
$script:organizerOpenSpreadsheetEnabled = $false
$script:organizerPath = $download
$script:taskTempRoot = Join-Path $root 'Jobs'
$script:folderOrganizerScriptPath = Join-Path $appRoot 'modules\FolderOrganizer.ps1'
$script:folderOrganizerWorkerScriptPath = Join-Path $appRoot 'modules\FolderOrganizerWorker.ps1'
$script:powerShellPath = (Get-Process -Id $PID).Path
$script:logs = [Collections.Generic.List[string]]::new()
$script:opened = [Collections.Generic.List[string]]::new()
try {
    $folders = foreach ($number in 1..$FolderCount) {
        $folder = Join-Path $manual ('Project' + $number)
        [void][IO.Directory]::CreateDirectory($folder)
        foreach ($fileNumber in 1..20) {
            $file = Join-Path $folder ('file' + $fileNumber + '.txt')
            [IO.File]::WriteAllText($file, "fixture $number $fileNumber")
            [IO.File]::SetLastWriteTimeUtc($file,[DateTime]::UtcNow.AddSeconds(-30))
        }
        $folder
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Add-OrganizerFoldersBatch -Paths $folders
    if (-not $BenchmarkOnly) {
        Assert ($script:organizerTimer.Interval -eq 200) 'Active worker polling is not 200 ms'
        $firstProcess = $script:organizerWorkerProcess.Id
        Invoke-DesktopOrganizerQueue
        Assert ($script:organizerWorkerProcess.Id -eq $firstProcess) 'Started a second worker while the first was running'
        $script:organizerQueueRunning = $true
        Invoke-DesktopOrganizerQueue
        Assert ($script:organizerWorkerProcess.Id -eq $firstProcess) 'Queue reentered during completion'
        $script:organizerQueueRunning = $false
    }
    Wait-Queue
    $watch.Stop()
    $batchMilliseconds = [Math]::Round($watch.Elapsed.TotalMilliseconds,1)
    foreach ($folder in $folders) {
        $name = [IO.Path]::GetFileName($folder)
        $file = Join-Path $folder ($name + ' 源文件\file20.txt')
        Assert ([IO.File]::ReadAllText($file) -eq "fixture $($name.Substring(7)) 20") 'Batch output content mismatch'
    }
    Assert ($script:opened.Count -eq 0) 'Disabled spreadsheet switch opened a file'
    if (-not $BenchmarkOnly) {
        Assert ($script:organizerTimer.Interval -eq 2000 -and -not $script:organizerTimer.Enabled) 'Idle timer not restored/stopped'
        Assert ($script:organizerMinimumAgeSeconds -eq 5) 'Production download stability window changed'
        # The worker runs in its own process. Any call here is an unwanted UI-thread rescan.
        function Get-ProjectSpreadsheetPathForFolder { param($Path) throw 'UI thread rescanned the project' }
        $script:organizerOpenSpreadsheetEnabled = $true
        $autoFolder = Join-Path $download 'AutoProject'
        [void][IO.Directory]::CreateDirectory($autoFolder)
        [void][IO.Directory]::CreateDirectory((Join-Path $defaultDesktopPath 'AutoProject'))
        $sheet = Join-Path $autoFolder 'sheet.csv'
        [IO.File]::WriteAllText($sheet,'title,value')
        Assert (Start-DesktopOrganizer -Path $download -Quiet) 'Could not start fixture monitoring'
        $pending = $script:organizerPending[$autoFolder]
        $pending.LastChangedUtc = [DateTime]::UtcNow.AddSeconds(-30)
        [IO.File]::AppendAllText($sheet,"`nhello,1")
        $changedAt = [DateTime]::UtcNow
        $activityDeadline = $changedAt.AddSeconds(2)
        while ($pending.LastChangedUtc -lt $changedAt.AddMilliseconds(-100) -and [DateTime]::UtcNow -lt $activityDeadline) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 10
        }
        Assert ($pending.LastChangedUtc -ge $changedAt.AddMilliseconds(-100)) 'Download write did not reset the quiet window'
        Invoke-DesktopOrganizerQueue
        Assert (-not $script:organizerWorkerProcess) 'Active download bypassed the stability window'
        Wait-Queue
        $stableMilliseconds = [Math]::Round(([DateTime]::UtcNow - $changedAt).TotalMilliseconds,1)
        Assert ($stableMilliseconds -ge 5000) 'Automatic organization did not preserve 5 seconds of quiet'
        Assert ($stableMilliseconds -lt 8000) "Automatic organization waited too long after becoming stable: $stableMilliseconds ms"
        Assert ($script:opened.Count -eq 1) ('Spreadsheet not opened exactly once: ' + ($script:logs -join '; '))
        $openedPath = $script:opened[0]
        Assert ($openedPath.StartsWith($defaultDesktopPath + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Spreadsheet path not remapped into desktop'
        Assert (Test-Path -LiteralPath $openedPath -PathType Leaf) 'Remapped spreadsheet is missing'
        Assert ($openedPath -notlike '*\AutoProject\*') 'Collision did not remap the spreadsheet into the renamed project'
        Assert ([IO.File]::ReadAllText($openedPath) -eq "title,value`nhello,1") 'Download content changed'
        Stop-DesktopOrganizer -PreserveEnabledPreference
        # Ignore a malformed worker response that points outside its project.
        $fakeProject = Join-Path $manual 'BadResponse'
        [void][IO.Directory]::CreateDirectory($fakeProject)
        $fakeJob = Join-Path $root 'BadResponseJob'
        [void][IO.Directory]::CreateDirectory($fakeJob)
        $resultPath = Join-Path $fakeJob 'result.json'
        @{ Success=$true; FolderPath=$fakeProject; ProjectName='BadResponse'; MovedCount=0; SpreadsheetPath=$openedPath } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
        $script:organizerWorkerProcess = [pscustomobject]@{HasExited=$true}
        $script:organizerWorkerProcess | Add-Member ScriptMethod WaitForExit {}
        $script:organizerWorkerProcess | Add-Member ScriptMethod Dispose {}
        $script:organizerWorkerJob = [pscustomobject]@{ FolderPath=$fakeProject; Directory=$fakeJob; ResultPath=$resultPath }
        Invoke-DesktopOrganizerQueue
        Assert ($script:opened.Count -eq 1) 'External spreadsheet path was opened'
        Assert (-not $script:organizerQueueRunning) 'Queue guard was not reset'
    }
    $report = [ordered]@{ AppPath=$AppPath; FolderCount=$FolderCount; FilesPerFolder=20; BatchMilliseconds=$batchMilliseconds; StableMilliseconds=$stableMilliseconds; Passed=$true; FixtureRoot=$root }
    if ($ReportPath) { $report | ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding UTF8 }
    $report | ConvertTo-Json
}
finally {
    Stop-DesktopOrganizer -PreserveEnabledPreference
    $script:organizerTimer.Dispose()
    $form.Dispose()
}

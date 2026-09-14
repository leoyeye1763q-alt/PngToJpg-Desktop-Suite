param(
    [Parameter(Mandatory)][string]$BaselineModulePath,
    [string]$CandidateModulePath = (Join-Path $PSScriptRoot '..\modules\FolderOrganizer.ps1'),
    [ValidateRange(100, 10000)][int]$FileCount = 2000,
    [ValidateRange(3, 15)][int]$Rounds = 5,
    [string]$OutputPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-InFixture([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    Assert-True ($resolved -eq $testRoot -or $resolved.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) "Path escapes temporary fixture: $resolved"
}

function Add-FixtureFile([string]$Path, [string]$Content) {
    Assert-InFixture $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Content)
}

function Invoke-ModuleOperation($Module, [string]$Operation, [string]$Path) {
    Assert-InFixture $Path
    & $Module {
        param($Operation, $Path)
        switch ($Operation) {
            'Snapshot' { Get-FolderContentSnapshot -Path $Path }
            'FilesAvailable' { Test-FolderFilesAvailable -Path $Path }
            'SpreadsheetSelection' { Get-ProjectSpreadsheetPath -SourceFolderPath $Path }
            'Organize' { Invoke-ProjectFolderOrganization -Path $Path }
            default { throw "Unknown operation: $Operation" }
        }
    } $Operation $Path
}

function Get-ResultKey($Result) {
    if ($null -eq $Result) { return '<null>' }
    return ConvertTo-Json -InputObject $Result -Depth 6 -Compress
}

function Assert-MatchingOperation([string]$Operation, [string]$Path) {
    $before = Invoke-ModuleOperation $baseline $Operation $Path
    $after = Invoke-ModuleOperation $candidate $Operation $Path
    Assert-True ((Get-ResultKey $before) -ceq (Get-ResultKey $after)) "$Operation differs between baseline and candidate: baseline=$(Get-ResultKey $before); candidate=$(Get-ResultKey $after)"
    return $after
}

function Get-Median($Samples) {
    $ordered = @($Samples | Sort-Object)
    $middle = [int][Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2) { return [double]$ordered[$middle] }
    return ([double]$ordered[$middle - 1] + [double]$ordered[$middle]) / 2
}

function Get-ContentManifest([string]$Path) {
    Assert-InFixture $Path
    return @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File | ForEach-Object {
        '{0}|{1}' -f [IO.Path]::GetRelativePath($Path, $_.FullName), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    } | Sort-Object) -join "`n"
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot ('OrganizerPerformance_' + [guid]::NewGuid().ToString('N'))))
Assert-True ([IO.Path]::GetDirectoryName($testRoot) -eq $tempRoot) 'Fixture must be a direct child of the temporary directory'
Assert-True ([IO.Path]::GetFileName($testRoot) -like 'OrganizerPerformance_*') 'Unexpected fixture directory name'
$baselinePath = (Resolve-Path -LiteralPath $BaselineModulePath).Path
$candidatePath = (Resolve-Path -LiteralPath $CandidateModulePath).Path
$baseline = New-Module -Name ('OrganizerBaseline_' + [guid]::NewGuid().ToString('N')) -ScriptBlock { param($Path) . $Path } -ArgumentList $baselinePath
$candidate = New-Module -Name ('OrganizerCandidate_' + [guid]::NewGuid().ToString('N')) -ScriptBlock { param($Path) . $Path } -ArgumentList $candidatePath
$scanRoot = Join-Path $testRoot 'Scan'
$junction = $null

try {
    for ($index = 0; $index -lt $FileCount; $index++) {
        $relative = 'group{0:d2}\batch{1:d2}\files\item{2:d5}.txt' -f ($index % 10), ([int][Math]::Floor($index / 10) % 10), $index
        Add-FixtureFile (Join-Path $scanRoot $relative) ('fixture-' + $index)
    }
    Add-FixtureFile (Join-Path $scanRoot 'z-workbook.xlsx') 'xlsx-z'
    Add-FixtureFile (Join-Path $scanRoot 'A-workbook.XLSX') 'xlsx-a'
    Add-FixtureFile (Join-Path $scanRoot '00-priority.xls') 'xls'
    Add-FixtureFile (Join-Path $scanRoot '00-priority.csv') 'csv'
    $hiddenSheet = Join-Path $scanRoot '00-hidden.xlsx'
    Add-FixtureFile $hiddenSheet 'hidden spreadsheet'
    [IO.File]::SetAttributes($hiddenSheet, [IO.FileAttributes]::Hidden)
    $systemSheet = Join-Path $scanRoot '00-system.xlsx'
    Add-FixtureFile $systemSheet 'system spreadsheet'
    [IO.File]::SetAttributes($systemSheet, [IO.FileAttributes]::System)
    $hiddenDirectory = Join-Path $scanRoot '00-hidden-directory'
    Add-FixtureFile (Join-Path $hiddenDirectory '00-hidden.xlsx') 'hidden directory spreadsheet'
    [IO.File]::SetAttributes($hiddenDirectory, [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Directory)
    $systemDirectory = Join-Path $scanRoot '00-system-directory'
    Add-FixtureFile (Join-Path $systemDirectory '00-system.xlsx') 'system directory spreadsheet'
    [IO.File]::SetAttributes($systemDirectory, [IO.FileAttributes]::System -bor [IO.FileAttributes]::Directory)

    $snapshot = Assert-MatchingOperation 'Snapshot' $scanRoot
    Assert-True ($snapshot.FileCount -eq $FileCount + 8) 'Snapshot omitted hidden/system files'
    Assert-True (-not $snapshot.HasTemporaryFile) 'Completed files were marked temporary'
    Assert-True (Assert-MatchingOperation 'FilesAvailable' $scanRoot) 'Unlocked files were considered unavailable'
    Assert-True ((Assert-MatchingOperation 'SpreadsheetSelection' $scanRoot) -eq (Join-Path $systemDirectory '00-system.xlsx')) 'Spreadsheet priority or hidden/system filtering changed'

    $measurements = [Collections.Generic.List[object]]::new()
    foreach ($operation in @('Snapshot', 'FilesAvailable', 'SpreadsheetSelection')) {
        for ($warmup = 0; $warmup -lt 2; $warmup++) {
            [void](Invoke-ModuleOperation $baseline $operation $scanRoot)
            [void](Invoke-ModuleOperation $candidate $operation $scanRoot)
        }
        $baselineSamples = [Collections.Generic.List[double]]::new()
        $candidateSamples = [Collections.Generic.List[double]]::new()
        for ($round = 0; $round -lt $Rounds; $round++) {
            $order = if ($round % 2) { @('candidate', 'baseline') } else { @('baseline', 'candidate') }
            $results = @{}
            foreach ($variant in $order) {
                $module = if ($variant -eq 'baseline') { $baseline } else { $candidate }
                $stopwatch = [Diagnostics.Stopwatch]::StartNew()
                $results[$variant] = Invoke-ModuleOperation $module $operation $scanRoot
                $stopwatch.Stop()
                if ($variant -eq 'baseline') { $baselineSamples.Add($stopwatch.Elapsed.TotalMilliseconds) }
                else { $candidateSamples.Add($stopwatch.Elapsed.TotalMilliseconds) }
            }
            Assert-True ((Get-ResultKey $results.baseline) -ceq (Get-ResultKey $results.candidate)) "Measured $operation results differ"
        }
        $baselineMedian = Get-Median $baselineSamples
        $candidateMedian = Get-Median $candidateSamples
        $measurements.Add([pscustomobject]@{
            Operation = $operation
            BaselineMedianMs = [Math]::Round($baselineMedian, 3)
            CandidateMedianMs = [Math]::Round($candidateMedian, 3)
            Speedup = [Math]::Round($baselineMedian / $candidateMedian, 3)
            BaselineSamplesMs = @($baselineSamples | ForEach-Object { [Math]::Round($_, 3) })
            CandidateSamplesMs = @($candidateSamples | ForEach-Object { [Math]::Round($_, 3) })
        })
    }

    foreach ($extension in @('crdownload', 'download', 'partial', 'tmp', 'td', 'dingtalk')) {
        $temporaryPath = Join-Path $testRoot ('Temporary\' + $extension + '\active.' + $extension.ToUpperInvariant())
        Add-FixtureFile $temporaryPath 'unfinished download'
        $temporarySnapshot = Assert-MatchingOperation 'Snapshot' ([IO.Path]::GetDirectoryName($temporaryPath))
        Assert-True $temporarySnapshot.HasTemporaryFile "Temporary extension not detected: $extension"
    }

    $lockPath = Join-Path $testRoot 'Locks\hidden.lock'
    Add-FixtureFile $lockPath 'locked download'
    [IO.File]::SetAttributes($lockPath, [IO.FileAttributes]::Hidden)
    $stream = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert-True (-not (Assert-MatchingOperation 'FilesAvailable' ([IO.Path]::GetDirectoryName($lockPath)))) 'Exclusive lock was ignored'
    }
    finally { $stream.Dispose() }
    Assert-True (Assert-MatchingOperation 'FilesAvailable' ([IO.Path]::GetDirectoryName($lockPath))) 'Released lock remained unavailable'

    $emptyRoot = Join-Path $testRoot 'Empty'
    [void][IO.Directory]::CreateDirectory($emptyRoot)
    Assert-True (-not (Assert-MatchingOperation 'Snapshot' $emptyRoot).HasContent) 'Empty folder was considered populated'
    Assert-True ($null -eq (Assert-MatchingOperation 'SpreadsheetSelection' $emptyRoot)) 'Empty folder returned a spreadsheet'

    $linkTarget = Join-Path $testRoot 'LinkTarget'
    Add-FixtureFile (Join-Path $linkTarget '00-linked.xlsx') 'junction target must not be traversed'
    $junction = Join-Path $scanRoot '00-junction'
    Assert-InFixture $junction
    Assert-InFixture $linkTarget
    [void](New-Item -ItemType Junction -Path $junction -Target $linkTarget)
    $linkedSnapshot = Assert-MatchingOperation 'Snapshot' $scanRoot
    Assert-True ($linkedSnapshot.FileCount -eq $snapshot.FileCount) 'Directory junction was traversed'
    Assert-True ((Assert-MatchingOperation 'SpreadsheetSelection' $scanRoot) -eq (Join-Path $systemDirectory '00-system.xlsx')) 'Junction contents changed selected spreadsheet'

    $organizationResults = @{}
    foreach ($variant in @('baseline', 'candidate')) {
        $project = Join-Path $testRoot ($variant + '\Project')
        foreach ($relative in @('Project 源文件\image.png', 'image.png', 'design\notes.txt', 'design\requirements.xlsx', '素材\keep.txt', 'Project\keep.txt', 'hidden.txt')) {
            Add-FixtureFile (Join-Path $project $relative) ('fixture:' + $relative)
        }
        [IO.File]::SetAttributes((Join-Path $project 'hidden.txt'), [IO.FileAttributes]::Hidden)
        Assert-InFixture $project
        Assert-InFixture (Join-Path $project 'Project 源文件')
        $module = if ($variant -eq 'baseline') { $baseline } else { $candidate }
        $result = Invoke-ModuleOperation $module 'Organize' $project
        Assert-True $result.Success "$variant organization failed"
        Assert-True ([IO.File]::ReadAllText((Join-Path $project 'Project 源文件\image.png')) -eq 'fixture:Project 源文件\image.png') 'Existing destination was overwritten'
        Assert-True ([IO.File]::ReadAllText((Join-Path $project 'Project 源文件\image（2）.png')) -eq 'fixture:image.png') 'Incoming collision file was lost'
        $repeat = Invoke-ModuleOperation $module 'Organize' $project
        Assert-True ($repeat.Success -and $repeat.MovedCount -eq 0) 'Repeated organization moved managed folders'
        $organizationResults[$variant] = Get-ContentManifest $project
    }
    Assert-True ($organizationResults.baseline -ceq $organizationResults.candidate) 'Organized files differ from baseline'

    $report = [pscustomobject]@{
        Passed = $true
        FixtureFiles = $snapshot.FileCount
        FixtureDirectories = $snapshot.DirectoryCount
        Rounds = $Rounds
        WarmupRounds = 2
        BaselineModuleSha256 = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash
        CandidateModuleSha256 = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash
        Checks = @('snapshot signature', 'hidden/system files and directories', 'spreadsheet priority', 'six temporary extensions', 'exclusive lock and release', 'empty folder', 'directory junction', 'same-name preservation', 'organization content hashes', 'repeat organization')
        Measurements = @($measurements)
        Note = 'Measured local warm-cache timings, not end-to-end download timings; no performance threshold is enforced.'
    }
    $json = $report | ConvertTo-Json -Depth 8
    if ($OutputPath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json, [Text.UTF8Encoding]::new($false)) }
    Write-Output $json
}
finally {
    if ($junction -and (Test-Path -LiteralPath $junction)) {
        Assert-InFixture $junction
        Remove-Item -LiteralPath $junction -Force
    }
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedCleanup = [IO.Path]::GetFullPath($testRoot)
        Assert-True ([IO.Path]::GetDirectoryName($resolvedCleanup) -eq $tempRoot -and [IO.Path]::GetFileName($resolvedCleanup) -like 'OrganizerPerformance_*') 'Unsafe cleanup target'
        Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force
    }
}

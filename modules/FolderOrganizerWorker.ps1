param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $temporaryPath = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporaryPath, ($Value | ConvertTo-Json -Depth 8 -Compress), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($temporaryPath, $Path, $true)
}

$job = $null
$result = $null
try {
    $job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
    . ([string]$job.ModulePath)
    $snapshot = Get-FolderContentSnapshot -Path ([string]$job.FolderPath)
    if ($snapshot.HasTemporaryFile) {
        $result = [PSCustomObject]@{ Success = $false; Retry = $true; FolderPath = [string]$job.FolderPath; Error = '仍有临时下载文件。' }
    }
    elseif (-not (Test-FolderFilesAvailable -Path ([string]$job.FolderPath))) {
        $result = [PSCustomObject]@{ Success = $false; Retry = $true; FolderPath = [string]$job.FolderPath; Error = '仍有文件被占用。' }
    }
    else {
        $organization = Invoke-ProjectFolderOrganization -Path ([string]$job.FolderPath)
        $spreadsheetPath = if ($organization.Success) {
            Get-ProjectSpreadsheetPath -SourceFolderPath ([string]$organization.SourceFolderPath)
        } else { $null }
        $result = [PSCustomObject]@{
            Success = [bool]$organization.Success
            Retry = -not [bool]$organization.Success
            FolderPath = [string]$job.FolderPath
            ProjectName = [string]$organization.ProjectName
            MovedCount = [int]$organization.MovedCount
            SpreadsheetPath = $spreadsheetPath
            Errors = @($organization.Errors)
            Error = if ($organization.Success) { $null } else { $organization.Errors -join '；' }
        }
    }
}
catch {
    $result = [PSCustomObject]@{
        Success = $false
        Retry = $true
        FolderPath = if ($job -and $job.PSObject.Properties['FolderPath']) { [string]$job.FolderPath } else { $null }
        Error = $_.Exception.Message
    }
}
finally {
    if ($job -and $job.PSObject.Properties['ResultPath']) {
        Write-JsonAtomic ([string]$job.ResultPath) $result
    }
}

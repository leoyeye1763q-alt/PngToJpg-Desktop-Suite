param(
    [Parameter(Mandatory)][string]$ResponseFile,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ImageFieldPath = '',
    [ValidateSet('', 'base64', 'url', 'binary')][string]$ResponseType = ''
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/ImageApi.ps1')
Restore-ImageApiResponse -ResponseFile $ResponseFile -DestinationPath $OutputPath -ImageFieldPath $ImageFieldPath -ResponseType $ResponseType
Write-Host '已恢复响应中的图片数据；未提交生图请求。'

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CockroachQiang-CustomNaming-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    Add-Type -AssemblyName System.Drawing.Common
    $inputs = @()
    foreach ($index in 1..2) {
        $path = Join-Path $testRoot ("input$index.png")
        $bitmap = [Drawing.Bitmap]::new(8, 8)
        try {
            $bitmap.SetPixel(0, 0, [Drawing.Color]::FromArgb(255, 40 * $index, 80, 120))
            $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose() }
        $inputs += $path
    }
    & (Join-Path $PSScriptRoot '..\PngToJpg.ps1') -InputFiles $inputs -SmokeTestConversion -SmokeTestCustomNaming
    foreach ($expected in @('主图1.jpg', '主图2.jpg')) {
        if (-not (Test-Path -LiteralPath (Join-Path $testRoot $expected) -PathType Leaf)) { throw "未生成 $expected。" }
    }
    Write-Host 'PASS: custom naming generated 主图1.jpg and 主图2.jpg.'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

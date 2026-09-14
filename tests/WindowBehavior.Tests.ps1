param([string]$AppPath = (Join-Path $PSScriptRoot '..\PngToJpg.ps1'))

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing.Common

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "断言失败：$Message" }
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WindowBehaviorNativeTest {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
}
'@

$source = [IO.File]::ReadAllText([IO.Path]::GetFullPath($AppPath))
$match = [regex]::Match($source, '(?s)\$winFormsTypeDefinition\s*=\s*@''\r?\n(.*?)\r?\n''@')
Assert-True $match.Success '未找到主程序的窗口类型定义'
$references = @(
    [Windows.Forms.Control].Assembly.Location,
    [Windows.Forms.Message].Assembly.Location,
    [ComponentModel.Component].Assembly.Location,
    [Threading.Interlocked].Assembly.Location,
    [Drawing.Graphics].Assembly.Location,
    [Drawing.Rectangle].Assembly.Location,
    (Join-Path ([IO.Path]::GetDirectoryName([Drawing.Graphics].Assembly.Location)) 'System.Private.Windows.GdiPlus.dll'),
    (Join-Path ([IO.Path]::GetDirectoryName([Drawing.Graphics].Assembly.Location)) 'System.Private.Windows.Core.dll'),
    (Join-Path ([IO.Path]::GetDirectoryName([Drawing.Graphics].Assembly.Location)) 'System.Threading.dll'),
    (Join-Path ([IO.Path]::GetDirectoryName([Drawing.Graphics].Assembly.Location)) 'System.Threading.Thread.dll'),
    (Join-Path ([IO.Path]::GetDirectoryName([Drawing.Graphics].Assembly.Location)) 'System.Threading.Timer.dll')
) | Select-Object -Unique
Add-Type -TypeDefinition $match.Groups[1].Value -ReferencedAssemblies $references -CompilerOptions /nowarn:1701,1702

$form = [ReferenceUiForm]::new()
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $true
$form.Size = [Drawing.Size]::new(720, 480)
try {
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $style = [WindowBehaviorNativeTest]::GetWindowLong($form.Handle, -16)
    Assert-True (($style -band 0x00020000) -ne 0) '无边框窗口缺少系统最小化样式'
    Assert-True (($style -band 0x00080000) -ne 0) '无边框窗口缺少系统菜单样式'

    [void][WindowBehaviorNativeTest]::SendMessage($form.Handle, 0x0112, [IntPtr]0xF020, [IntPtr]::Zero)
    [Windows.Forms.Application]::DoEvents()
    Assert-True ([WindowBehaviorNativeTest]::IsIconic($form.Handle)) '系统最小化命令未把窗口缩到任务栏'
    [void][WindowBehaviorNativeTest]::SendMessage($form.Handle, 0x0112, [IntPtr]0xF120, [IntPtr]::Zero)
    [Windows.Forms.Application]::DoEvents()
    Assert-True (-not [WindowBehaviorNativeTest]::IsIconic($form.Handle)) '系统还原命令未恢复窗口'

    $webRoot = Split-Path -Parent ([IO.Path]::GetFullPath($AppPath))
    $dllRoot = Join-Path $webRoot 'tools\webview2'
    Add-Type -Path (Join-Path $dllRoot 'Microsoft.Web.WebView2.Core.dll')
    Add-Type -Path (Join-Path $dllRoot 'Microsoft.Web.WebView2.WinForms.dll')
    $webReferences = @(Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName) + $references + @(
        (Join-Path $dllRoot 'Microsoft.Web.WebView2.Core.dll'),
        (Join-Path $dllRoot 'Microsoft.Web.WebView2.WinForms.dll'),
        [Collections.Concurrent.ConcurrentQueue[string]].Assembly.Location,
        (Join-Path $PSHOME 'ref\System.Collections.dll'),
        (Join-Path $PSHOME 'ref\System.Runtime.dll'),
        (Join-Path $PSHOME 'ref\System.Runtime.InteropServices.dll')
    )
    Add-Type -Path (Join-Path $webRoot 'modules\WebUiHost.cs') -ReferencedAssemblies ($webReferences | Select-Object -Unique) -CompilerOptions /nowarn:1701,1702
    $webHostControl = [StitchWebHost]::new()
    $webHostControl.Dock = 'Fill'
    $form.Controls.Add($webHostControl)
    [void]$webHostControl.Handle
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Assert-True ($webHostControl.RequestWindowCommand('minimize')) '即时窗口命令未接受最小化操作'
    $deadline = [DateTime]::UtcNow.AddMilliseconds(500)
    while ($form.WindowState -ne 'Minimized' -and [DateTime]::UtcNow -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
    }
    $timer.Stop()
    Assert-True ($form.WindowState -eq 'Minimized') '右上角最小化命令未生效'
    Assert-True ($timer.ElapsedMilliseconds -lt 150) "右上角最小化响应过慢：$($timer.ElapsedMilliseconds) ms"
    Write-Output "PASS: native taskbar minimize/restore and immediate window command ($($timer.ElapsedMilliseconds) ms)."
}
finally {
    if (-not $form.IsDisposed) { $form.Close(); $form.Dispose() }
}

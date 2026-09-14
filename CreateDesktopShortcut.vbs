Option Explicit

Dim shell, fso, desktop, shortcutPath, tempPath, shortcut, verified
Dim launcherPath, iconPath, workingDirectory, shortcutName

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
workingDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
launcherPath = fso.BuildPath(workingDirectory, "PngToJpgLauncher.exe")
iconPath = fso.BuildPath(workingDirectory, "PngToJpg.ico")
If Not fso.FileExists(launcherPath) Then
    WScript.Echo "LauncherMissing=" & launcherPath
    WScript.Quit 3
End If
If Not fso.FileExists(iconPath) Then
    WScript.Echo "IconMissing=" & iconPath
    WScript.Quit 4
End If

desktop = shell.SpecialFolders("Desktop")
shortcutName = "PNG" & ChrW(&H8F6C) & "JPG.lnk"
shortcutPath = fso.BuildPath(desktop, shortcutName)
tempPath = fso.BuildPath(desktop, "PngToJpg-new.lnk")

If fso.FileExists(tempPath) Then fso.DeleteFile tempPath, True
Set shortcut = shell.CreateShortcut(tempPath)
shortcut.TargetPath = launcherPath
shortcut.Arguments = ""
shortcut.WorkingDirectory = workingDirectory
shortcut.Description = "PNG/JPG/JFIF image conversion and resizing"
shortcut.IconLocation = iconPath & ",0"
shortcut.Save
Set shortcut = Nothing

If fso.FileExists(shortcutPath) Then fso.DeleteFile shortcutPath, True
fso.MoveFile tempPath, shortcutPath
WScript.Echo shortcutPath
Set verified = shell.CreateShortcut(shortcutPath)
WScript.Echo "Target=" & verified.TargetPath
WScript.Echo "Arguments=" & verified.Arguments

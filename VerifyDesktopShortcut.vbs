Option Explicit

Dim shell, fso, shortcutPath, shortcut
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
shortcutPath = fso.BuildPath(shell.SpecialFolders("Desktop"), "PNG" & ChrW(&H8F6C) & "JPG.lnk")

If Not fso.FileExists(shortcutPath) Then
    WScript.Echo "Exists=False"
    WScript.Quit 2
End If

Set shortcut = shell.CreateShortcut(shortcutPath)
WScript.Echo "Exists=True"
WScript.Echo "Path=" & shortcutPath
WScript.Echo "Target=" & shortcut.TargetPath
WScript.Echo "Arguments=" & shortcut.Arguments
WScript.Echo "WorkingDirectory=" & shortcut.WorkingDirectory

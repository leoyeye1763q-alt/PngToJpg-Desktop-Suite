Set-StrictMode -Version 3.0

function Get-DingTalkDownloadDirectory {
    param([Parameter(Mandatory)][string]$DesktopPath)

    return Join-Path ([System.IO.Path]::GetFullPath($DesktopPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)) '钉钉下载'
}

function Resolve-DingTalkOrganizerPath {
    param(
        [string]$SavedPath,
        [Parameter(Mandatory)][string]$DesktopPath
    )

    $desktop = [System.IO.Path]::GetFullPath($DesktopPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($SavedPath)) { return Get-DingTalkDownloadDirectory -DesktopPath $desktop }
    $resolved = [System.IO.Path]::GetFullPath($SavedPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ([string]::Equals($resolved, $desktop, [System.StringComparison]::OrdinalIgnoreCase)) {
        return Get-DingTalkDownloadDirectory -DesktopPath $desktop
    }
    return $resolved
}

function Test-IsDesktopRootPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DesktopPath
    )

    $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $desktop = [System.IO.Path]::GetFullPath($DesktopPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    return [string]::Equals($resolved, $desktop, [System.StringComparison]::OrdinalIgnoreCase)
}

function Move-OrganizedProjectFolder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "待移动的项目文件夹不存在：$Path" }
    [void][System.IO.Directory]::CreateDirectory($DestinationDirectory)
    $source = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $destinationRoot = [System.IO.Path]::GetFullPath($DestinationDirectory).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $sourceParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $source)).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ([string]::Equals($sourceParent, $destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $source }

    $destination = Get-UniqueMoveDestination -Directory $destinationRoot -Name ([System.IO.Path]::GetFileName($source))
    [System.IO.Directory]::Move($source, $destination)
    return $destination
}

function Get-UniqueMoveDestination {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name
    )

    $candidate = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }

    $extension = [System.IO.Path]::GetExtension($Name)
    $baseName = if ([string]::IsNullOrEmpty($extension)) {
        $Name
    } else {
        [System.IO.Path]::GetFileNameWithoutExtension($Name)
    }
    $index = 2
    do {
        $candidate = Join-Path $Directory ("{0}（{1}）{2}" -f $baseName, $index, $extension)
        $index++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function Get-OrganizerFileSystemEntries {
    param([Parameter(Mandatory)][string]$Path, [switch]$FilesOnly, [switch]$IncludeHidden, [switch]$IgnoreInaccessible)

    # Read filesystem metadata directly and never recurse through directory links.
    $folders = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $folders.Push([System.IO.DirectoryInfo]::new($Path))
    $entries = [System.Collections.Generic.List[System.IO.FileSystemInfo]]::new()
    while ($folders.Count) {
        try { $children = $folders.Pop().GetFileSystemInfos() }
        catch { if ($IgnoreInaccessible) { continue }; throw }
        foreach ($entry in $children) {
            $isDirectory = [bool]($entry.Attributes -band [IO.FileAttributes]::Directory)
            if (-not $IncludeHidden -and ($entry.Attributes -band [IO.FileAttributes]::Hidden)) { continue }
            if (-not $IncludeHidden -and -not $isDirectory -and ($entry.Attributes -band [IO.FileAttributes]::System)) { continue }
            if (-not $FilesOnly -or -not $isDirectory) { $entries.Add($entry) }
            if ($isDirectory -and -not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $folders.Push($entry) }
        }
    }
    return $entries
}

function Get-FolderContentSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    $fileCount = 0L
    $directoryCount = 0L
    $totalBytes = 0L
    $latestWriteTicks = 0L
    $hasTemporaryFile = $false

    foreach ($entry in Get-OrganizerFileSystemEntries -Path $Path -IncludeHidden) {
        if ($entry.Attributes -band [IO.FileAttributes]::Directory) {
            $directoryCount++
        } else {
            $fileCount++
            $totalBytes += [long]$entry.Length
            if ($entry.Name -match '(?i)(\.crdownload|\.download|\.partial|\.tmp|\.td|\.dingtalk)$') {
                $hasTemporaryFile = $true
            }
        }
        if ($entry.LastWriteTimeUtc.Ticks -gt $latestWriteTicks) {
            $latestWriteTicks = $entry.LastWriteTimeUtc.Ticks
        }
    }

    [PSCustomObject]@{
        Signature = '{0}:{1}:{2}:{3}' -f $fileCount, $directoryCount, $totalBytes, $latestWriteTicks
        FileCount = $fileCount
        DirectoryCount = $directoryCount
        HasContent = ($fileCount + $directoryCount) -gt 0
        HasTemporaryFile = $hasTemporaryFile
    }
}

function Test-FolderFilesAvailable {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($file in Get-OrganizerFileSystemEntries -Path $Path -FilesOnly -IncludeHidden) {
        $stream = $null
        try {
            $stream = [System.IO.File]::Open(
                $file.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::None
            )
        }
        catch {
            return $false
        }
        finally {
            if ($stream) { $stream.Dispose() }
        }
    }
    return $true
}

function Get-ProjectSpreadsheetPath {
    param([Parameter(Mandatory)][string]$SourceFolderPath)

    if (-not (Test-Path -LiteralPath $SourceFolderPath -PathType Container)) { return $null }
    $extensionPriority = @{
        '.xlsx' = 0
        '.xls' = 1
        '.csv' = 2
        '.ods' = 3
        '.et' = 4
    }
    $spreadsheets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($file in Get-OrganizerFileSystemEntries -Path $SourceFolderPath -FilesOnly -IgnoreInaccessible) {
        $extension = $file.Extension.ToLowerInvariant()
        if (-not $extensionPriority.ContainsKey($extension)) { continue }
        $spreadsheets.Add($file)
    }
    if (-not $spreadsheets.Count) { return $null }
    # Sort only matching spreadsheet candidates to preserve the established choice.
    return [string]($spreadsheets | Sort-Object @{ Expression = { $extensionPriority[$_.Extension.ToLowerInvariant()] } }, FullName | Select-Object -First 1).FullName
}

function Get-ProjectSpreadsheetPathForFolder {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    $folder = Get-Item -LiteralPath $Path -Force
    $sourceFolderPath = if ($folder.Name.EndsWith(' 源文件', [System.StringComparison]::OrdinalIgnoreCase)) {
        $folder.FullName
    } else {
        $managedSourcePath = Join-Path $folder.FullName ($folder.Name + ' 源文件')
        if (Test-Path -LiteralPath $managedSourcePath -PathType Container) { $managedSourcePath } else { $folder.FullName }
    }
    return Get-ProjectSpreadsheetPath -SourceFolderPath $sourceFolderPath
}

function Invoke-ProjectFolderOrganization {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "文件夹不存在：$Path"
    }

    $folder = Get-Item -LiteralPath $Path -Force
    $projectName = $folder.Name
    if ([string]::IsNullOrWhiteSpace($projectName)) {
        throw "无法从路径取得项目名称：$Path"
    }

    $projectFolderPath = Join-Path $folder.FullName $projectName
    $sourceFolderPath = Join-Path $folder.FullName ($projectName + ' 源文件')
    $materialFolderPath = Join-Path $folder.FullName '素材'
    $managedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($managedPath in @($projectFolderPath, $sourceFolderPath, $materialFolderPath)) {
        [void]$managedPaths.Add([System.IO.Path]::GetFullPath($managedPath))
    }

    # 先记录原有第一层内容，再创建目标文件夹，保证重复执行时不会把三个目标文件夹互相移动。
    $originalChildren = @(
        Get-ChildItem -LiteralPath $folder.FullName -Force |
            Where-Object { -not $managedPaths.Contains([System.IO.Path]::GetFullPath($_.FullName)) }
    )
    foreach ($managedPath in @($projectFolderPath, $sourceFolderPath, $materialFolderPath)) {
        [void][System.IO.Directory]::CreateDirectory($managedPath)
    }

    $moved = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($child in $originalChildren) {
        try {
            $destination = Get-UniqueMoveDestination -Directory $sourceFolderPath -Name $child.Name
            if ($child.PSIsContainer) {
                [System.IO.Directory]::Move($child.FullName, $destination)
            } else {
                [System.IO.File]::Move($child.FullName, $destination)
            }
            $moved.Add([PSCustomObject]@{ Source = $child.FullName; Destination = $destination })
        }
        catch {
            $errors.Add("$($child.Name)：$($_.Exception.Message)")
        }
    }

    [PSCustomObject]@{
        ProjectName = $projectName
        ProjectFolderPath = $projectFolderPath
        SourceFolderPath = $sourceFolderPath
        MaterialFolderPath = $materialFolderPath
        MovedCount = $moved.Count
        Moved = @($moved)
        Errors = @($errors)
        Success = $errors.Count -eq 0
    }
}

function Initialize-DesktopIconPositionReader {
    if ('PngToJpg.DesktopIconReader' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace PngToJpg {
    public sealed class DesktopIconEntry {
        public string Name { get; set; }
        public string Path { get; set; }
        public int X { get; set; }
        public int Y { get; set; }
        public int ImageIndex { get; set; }
    }

    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IServiceProvider {
        [PreserveSig] int QueryService(ref Guid service, ref Guid riid, out IntPtr result);
    }

    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellBrowser {
        [PreserveSig] int GetWindow(out IntPtr hwnd);
        [PreserveSig] int ContextSensitiveHelp(bool enterMode);
        [PreserveSig] int InsertMenusSB(IntPtr sharedMenu, IntPtr widths);
        [PreserveSig] int SetMenuSB(IntPtr sharedMenu, IntPtr holeMenu, IntPtr activeObject);
        [PreserveSig] int RemoveMenusSB(IntPtr sharedMenu);
        [PreserveSig] int SetStatusTextSB([MarshalAs(UnmanagedType.LPWStr)] string text);
        [PreserveSig] int EnableModelessSB(bool enable);
        [PreserveSig] int TranslateAcceleratorSB(IntPtr message, ushort id);
        [PreserveSig] int BrowseObject(IntPtr pidl, uint flags);
        [PreserveSig] int GetViewStateStream(uint mode, out IntPtr stream);
        [PreserveSig] int GetControlWindow(uint id, out IntPtr hwnd);
        [PreserveSig] int SendControlMsg(uint id, uint message, IntPtr wParam, IntPtr lParam, out IntPtr result);
        [PreserveSig] int QueryActiveShellView([MarshalAs(UnmanagedType.Interface)] out IShellView view);
        [PreserveSig] int OnViewWindowActive([MarshalAs(UnmanagedType.Interface)] IShellView view);
        [PreserveSig] int SetToolbarItems(IntPtr buttons, uint count, uint flags);
    }

    [ComImport, Guid("000214E3-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellView { }

    [ComImport, Guid("cde725b0-ccc9-4519-917e-325d72fab4ce"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFolderView {
        [PreserveSig] int GetCurrentViewMode(out uint viewMode);
        [PreserveSig] int SetCurrentViewMode(uint viewMode);
        [PreserveSig] int GetFolder(ref Guid riid, out IntPtr folder);
        [PreserveSig] int Item(int index, out IntPtr pidl);
        [PreserveSig] int ItemCount(uint flags, out int count);
        [PreserveSig] int Items(uint flags, ref Guid riid, out IntPtr items);
        [PreserveSig] int GetSelectionMarkedItem(out int index);
        [PreserveSig] int GetFocusedItem(out int index);
        [PreserveSig] int GetItemPosition(IntPtr pidl, out NativePoint point);
        [PreserveSig] int GetSpacing(out NativePoint point);
        [PreserveSig] int GetDefaultSpacing(out NativePoint point);
        [PreserveSig] int GetAutoArrange();
        [PreserveSig] int SelectItem(int index, uint flags);
        [PreserveSig] int SelectAndPositionItems(uint count, IntPtr pidls, IntPtr points, uint flags);
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NativePoint { public int X; public int Y; }

    public static class DesktopIconReader {
        private const uint LVM_FIRST = 0x1000;
        private const uint LVM_GETITEMCOUNT = LVM_FIRST + 4;
        private const uint LVM_GETITEMPOSITION = LVM_FIRST + 16;
        private const uint LVM_GETITEMTEXTW = LVM_FIRST + 115;
        private const uint LVM_GETITEMW = LVM_FIRST + 75;
        private const uint LVIF_IMAGE = 0x0002;
        private const uint PROCESS_VM_OPERATION = 0x0008;
        private const uint PROCESS_VM_READ = 0x0010;
        private const uint PROCESS_VM_WRITE = 0x0020;
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint MEM_COMMIT = 0x1000;
        private const uint MEM_RESERVE = 0x2000;
        private const uint MEM_RELEASE = 0x8000;
        private const uint PAGE_READWRITE = 0x04;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int X; public int Y; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct LVITEM {
            public uint mask;
            public int iItem;
            public int iSubItem;
            public uint state;
            public uint stateMask;
            public IntPtr pszText;
            public int cchTextMax;
            public int iImage;
            public IntPtr lParam;
            public int iIndent;
            public int iGroupId;
            public uint cColumns;
            public IntPtr puColumns;
            public IntPtr piColFmt;
            public int iGroup;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SHFILEINFO {
            public IntPtr hIcon;
            public int iIcon;
            public uint dwAttributes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
        }

        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint allocationType, uint protect);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool VirtualFreeEx(IntPtr process, IntPtr address, UIntPtr size, uint freeType);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool WriteProcessMemory(IntPtr process, IntPtr address, IntPtr buffer, UIntPtr size, out UIntPtr written);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, IntPtr buffer, UIntPtr size, out UIntPtr read);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SHGetFileInfo(string path, uint attributes, out SHFILEINFO info, uint size, uint flags);
        [DllImport("shell32.dll")] private static extern int SHGetSpecialFolderLocation(IntPtr hwnd, int folder, out IntPtr pidl);
        [DllImport("shell32.dll")] private static extern IntPtr ILCombine(IntPtr parent, IntPtr child);
        [DllImport("shell32.dll")] private static extern void ILFree(IntPtr pidl);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool SHGetPathFromIDList(IntPtr pidl, StringBuilder path);

        private static IntPtr FindDesktopListView() {
            IntPtr defView = FindWindowEx(FindWindow("Progman", null), IntPtr.Zero, "SHELLDLL_DefView", null);
            IntPtr listView = defView == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(defView, IntPtr.Zero, "SysListView32", "FolderView");
            if (listView != IntPtr.Zero) return listView;
            EnumWindows(delegate(IntPtr top, IntPtr ignored) {
                IntPtr view = FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null);
                if (view == IntPtr.Zero) return true;
                listView = FindWindowEx(view, IntPtr.Zero, "SysListView32", "FolderView");
                return listView == IntPtr.Zero;
            }, IntPtr.Zero);
            return listView;
        }

        public static int GetSystemIconIndex(string path) {
            SHFILEINFO info;
            IntPtr result = SHGetFileInfo(path, 0, out info, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), 0x00004000);
            return result == IntPtr.Zero ? -1 : info.iIcon;
        }

        public static DesktopIconEntry[] ReadFromDesktopDispatch(object desktopDispatch) {
            IServiceProvider provider = (IServiceProvider)desktopDispatch;
            Guid service = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");
            Guid browserId = typeof(IShellBrowser).GUID;
            IntPtr browserPointer;
            int hr = provider.QueryService(ref service, ref browserId, out browserPointer);
            if (hr != 0 || browserPointer == IntPtr.Zero) Marshal.ThrowExceptionForHR(hr);
            IShellBrowser browser = null;
            IShellView shellView = null;
            IntPtr desktopPidl = IntPtr.Zero;
            try {
                browser = (IShellBrowser)Marshal.GetObjectForIUnknown(browserPointer);
                hr = browser.QueryActiveShellView(out shellView);
                if (hr != 0 || shellView == null) Marshal.ThrowExceptionForHR(hr);
                IFolderView folderView = (IFolderView)shellView;
                int count;
                hr = folderView.ItemCount(0x2, out count);
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);
                hr = SHGetSpecialFolderLocation(IntPtr.Zero, 0, out desktopPidl);
                if (hr != 0 || desktopPidl == IntPtr.Zero) Marshal.ThrowExceptionForHR(hr);
                IntPtr listView = FindDesktopListView();
                RECT bounds;
                if (listView == IntPtr.Zero || !GetWindowRect(listView, out bounds)) throw new InvalidOperationException("无法取得桌面区域。");
                List<DesktopIconEntry> result = new List<DesktopIconEntry>();
                for (int index = 0; index < count; index++) {
                    IntPtr child;
                    NativePoint point;
                    if (folderView.Item(index, out child) != 0 || child == IntPtr.Zero) continue;
                    if (folderView.GetItemPosition(child, out point) != 0) continue;
                    IntPtr absolute = ILCombine(desktopPidl, child);
                    if (absolute == IntPtr.Zero) continue;
                    try {
                        StringBuilder path = new StringBuilder(32768);
                        if (!SHGetPathFromIDList(absolute, path) || path.Length == 0) continue;
                        string fullPath = path.ToString();
                        result.Add(new DesktopIconEntry { Name = System.IO.Path.GetFileNameWithoutExtension(fullPath), Path = fullPath, X = bounds.Left + point.X + 24, Y = bounds.Top + point.Y + 24, ImageIndex = -1 });
                    }
                    finally { ILFree(absolute); }
                }
                return result.ToArray();
            }
            finally {
                if (desktopPidl != IntPtr.Zero) Marshal.FreeCoTaskMem(desktopPidl);
                if (shellView != null) Marshal.ReleaseComObject(shellView);
                if (browser != null) Marshal.ReleaseComObject(browser);
                Marshal.Release(browserPointer);
            }
        }

        public static DesktopIconEntry[] Read() {
            IntPtr listView = FindDesktopListView();
            if (listView == IntPtr.Zero) throw new InvalidOperationException("找不到 Windows 桌面图标视图。");
            uint processId;
            GetWindowThreadProcessId(listView, out processId);
            IntPtr process = OpenProcess(PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_QUERY_INFORMATION, false, processId);
            if (process == IntPtr.Zero) throw new InvalidOperationException("无法读取 Windows 桌面图标位置。");

            const int textChars = 520;
            int itemSize = Marshal.SizeOf(typeof(LVITEM));
            int pointSize = Marshal.SizeOf(typeof(POINT));
            int textBytes = textChars * 2;
            int totalSize = itemSize + pointSize + textBytes;
            IntPtr remote = IntPtr.Zero;
            IntPtr localItem = IntPtr.Zero;
            IntPtr localPoint = IntPtr.Zero;
            IntPtr localText = IntPtr.Zero;
            try {
                remote = VirtualAllocEx(process, IntPtr.Zero, (UIntPtr)totalSize, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
                if (remote == IntPtr.Zero) throw new InvalidOperationException("无法分配桌面图标读取缓冲区。");
                IntPtr remotePoint = IntPtr.Add(remote, itemSize);
                IntPtr remoteText = IntPtr.Add(remotePoint, pointSize);
                localItem = Marshal.AllocHGlobal(itemSize);
                localPoint = Marshal.AllocHGlobal(pointSize);
                localText = Marshal.AllocHGlobal(textBytes);
                RECT bounds;
                if (!GetWindowRect(listView, out bounds)) throw new InvalidOperationException("无法取得桌面区域。");
                int count = SendMessage(listView, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32();
                List<DesktopIconEntry> result = new List<DesktopIconEntry>();
                for (int index = 0; index < count; index++) {
                    LVITEM item = new LVITEM { iItem = index, iSubItem = 0, pszText = remoteText, cchTextMax = textChars };
                    Marshal.StructureToPtr(item, localItem, false);
                    UIntPtr transferred;
                    if (!WriteProcessMemory(process, remote, localItem, (UIntPtr)itemSize, out transferred)) continue;
                    SendMessage(listView, LVM_GETITEMTEXTW, (IntPtr)index, remote);
                    if (!ReadProcessMemory(process, remoteText, localText, (UIntPtr)textBytes, out transferred)) continue;
                    string name = Marshal.PtrToStringUni(localText) ?? String.Empty;
                    item = new LVITEM { mask = LVIF_IMAGE, iItem = index, iSubItem = 0, iImage = -1 };
                    Marshal.StructureToPtr(item, localItem, false);
                    WriteProcessMemory(process, remote, localItem, (UIntPtr)itemSize, out transferred);
                    SendMessage(listView, LVM_GETITEMW, IntPtr.Zero, remote);
                    ReadProcessMemory(process, remote, localItem, (UIntPtr)itemSize, out transferred);
                    item = (LVITEM)Marshal.PtrToStructure(localItem, typeof(LVITEM));
                    SendMessage(listView, LVM_GETITEMPOSITION, (IntPtr)index, remotePoint);
                    if (!ReadProcessMemory(process, remotePoint, localPoint, (UIntPtr)pointSize, out transferred)) continue;
                    POINT point = (POINT)Marshal.PtrToStructure(localPoint, typeof(POINT));
                    result.Add(new DesktopIconEntry { Name = name, X = bounds.Left + point.X + 24, Y = bounds.Top + point.Y + 24, ImageIndex = item.iImage });
                }
                return result.ToArray();
            }
            finally {
                if (localText != IntPtr.Zero) Marshal.FreeHGlobal(localText);
                if (localPoint != IntPtr.Zero) Marshal.FreeHGlobal(localPoint);
                if (localItem != IntPtr.Zero) Marshal.FreeHGlobal(localItem);
                if (remote != IntPtr.Zero) VirtualFreeEx(process, remote, UIntPtr.Zero, MEM_RELEASE);
                CloseHandle(process);
            }
        }
    }
}
'@
}

function Get-DesktopIconPositions {
    Initialize-DesktopIconPositionReader
    $shell = $null
    $windows = $null
    $desktopDispatch = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $windows = $shell.Windows()
        $location = $null
        $locationRoot = $null
        $windowHandle = 0
        $desktopDispatch = $windows.FindWindowSW([ref]$location, [ref]$locationRoot, 8, [ref]$windowHandle, 1)
        if (-not $desktopDispatch) { throw 'Windows 桌面 Shell 视图不可用。' }
        return @([PngToJpg.DesktopIconReader]::ReadFromDesktopDispatch($desktopDispatch))
    }
    finally {
        foreach ($comObject in @($desktopDispatch, $windows, $shell)) {
            if ($comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) }
        }
    }
}

function Test-DesktopPositionInScope {
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)][ValidateSet('left','center','right','all')][string]$Scope,
        [Parameter(Mandatory)]$ScreenBounds
    )

    if ($Scope -eq 'all') { return $true }
    $left = [double]$ScreenBounds.Left
    $top = [double]$ScreenBounds.Top
    $right = $left + [double]$ScreenBounds.Width
    $bottom = $top + [double]$ScreenBounds.Height
    if ($X -lt $left -or $X -ge $right -or $Y -lt $top -or $Y -ge $bottom) { return $false }
    $third = [double]$ScreenBounds.Width / 3.0
    switch ($Scope) {
        'left' { return $X -lt ($left + $third) }
        'center' { return $X -ge ($left + $third) -and $X -lt ($left + (2.0 * $third)) }
        'right' { return $X -ge ($left + (2.0 * $third)) }
    }
}

function Get-DesktopFilesForOrganization {
    param(
        [Parameter(Mandatory)][string]$DesktopPath,
        [Parameter(Mandatory)][ValidateSet('left','center','right','all')][string]$Scope,
        [object[]]$IconPositions,
        $ScreenBounds
    )

    $files = @(Get-ChildItem -LiteralPath $DesktopPath -File -Force)
    if ($Scope -eq 'all') { return $files }
    if (-not $IconPositions -or -not $ScreenBounds) {
        throw '无法读取桌面图标位置，已停止整理。请保持桌面可用后重试，或手动选择“全局”。'
    }
    $positionByName = @{}
    foreach ($position in $IconPositions) {
        $name = [string]$position.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (-not $positionByName.ContainsKey($name)) { $positionByName[$name] = [System.Collections.Generic.List[object]]::new() }
        $positionByName[$name].Add($position)
    }
    $selected = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($file in $files) {
        $position = $null
        $fullFilePath = [IO.Path]::GetFullPath($file.FullName)
        $exactPathPosition = @($IconPositions | Where-Object { $_.PSObject.Properties['Path'] -and $_.Path -and [string]::Equals([IO.Path]::GetFullPath([string]$_.Path), $fullFilePath, [StringComparison]::OrdinalIgnoreCase) })
        if ($exactPathPosition.Count -eq 1) { $position = $exactPathPosition[0] }
        foreach ($key in @($file.Name, $file.BaseName)) {
            if ($position) { break }
            if (-not $positionByName.ContainsKey($key)) { continue }
            $candidates = @($positionByName[$key])
            if ($candidates.Count -gt 1 -and ('PngToJpg.DesktopIconReader' -as [type])) {
                $fileIconIndex = [PngToJpg.DesktopIconReader]::GetSystemIconIndex($file.FullName)
                $typedCandidates = @($candidates | Where-Object { [int]$_.ImageIndex -eq $fileIconIndex })
                if ($typedCandidates.Count -eq 1) { $position = $typedCandidates[0] }
            } elseif ($candidates.Count -eq 1) { $position = $candidates[0] }
            if ($position) { break }
        }
        if ($position -and (Test-DesktopPositionInScope -X ([int]$position.X) -Y ([int]$position.Y) -Scope $Scope -ScreenBounds $ScreenBounds)) {
            $selected.Add($file)
        }
    }
    return @($selected)
}

function Get-DesktopProductFolder {
    param([Parameter(Mandatory)][string]$DesktopPath, [Parameter(Mandatory)][string]$Code)

    $matches = @(
        Get-OrganizerFileSystemEntries -Path $DesktopPath -IgnoreInaccessible |
            Where-Object {
                ($_.Attributes -band [IO.FileAttributes]::Directory) -and
                [string]::Equals($_.Name, $Code, [StringComparison]::OrdinalIgnoreCase) -and
                ((Test-Path -LiteralPath (Join-Path $_.FullName $Code) -PathType Container) -or
                 (Test-Path -LiteralPath (Join-Path $_.FullName ($Code + ' 源文件')) -PathType Container) -or
                 (Test-Path -LiteralPath (Join-Path $_.FullName '素材') -PathType Container))
            }
    )
    if ($matches.Count -eq 0) { throw ('桌面中未找到编号为「{0}」的母文件夹（需包含同名、源文件或素材子文件夹）。' -f $Code) }
    if ($matches.Count -gt 1) { throw ('找到多个编号为「{0}」的母文件夹，为避免误放已停止整理。' -f $Code) }
    return $matches[0]
}

function Save-DesktopOrganizationManifest {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Manifest)

    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $temporaryPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
        [IO.File]::Move($temporaryPath, $Path)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { [IO.File]::Delete($temporaryPath) }
    }
}

function New-DesktopOrganizationRecordId {
    return ([DateTime]::Now.ToString('yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Get-DesktopOrganizationHistory {
    param(
        [Parameter(Mandatory)][string]$HistoryPath,
        [ValidateRange(1,3650)][int]$RetentionDays = 30
    )

    [void][IO.Directory]::CreateDirectory($HistoryPath)
    $cutoff = [DateTimeOffset]::Now.AddDays(-$RetentionDays)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $HistoryPath -Filter '*.json' -File)) {
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $created = [DateTimeOffset]::Parse([string]$manifest.CreatedAt)
            if ($created -lt $cutoff) { [IO.File]::Delete($file.FullName); continue }
            $records.Add([PSCustomObject]@{
                Id = $file.BaseName
                CreatedAt = $created.ToString('o')
                ExpiresAt = $created.AddDays($RetentionDays).ToString('o')
                Code = [string]$manifest.Code
                ProjectFolder = [string]$manifest.ProjectFolder
                MovedCount = @($manifest.Moves).Count
            })
        }
        catch {
            continue
        }
    }
    return @($records | Sort-Object { [DateTimeOffset]::Parse($_.CreatedAt) } -Descending)
}

function Initialize-DesktopOrganizationHistory {
    param(
        [Parameter(Mandatory)][string]$HistoryPath,
        [string]$LegacyUndoPath,
        [ValidateRange(1,3650)][int]$RetentionDays = 30
    )

    [void][IO.Directory]::CreateDirectory($HistoryPath)
    if (-not [string]::IsNullOrWhiteSpace($LegacyUndoPath) -and (Test-Path -LiteralPath $LegacyUndoPath -PathType Leaf)) {
        try {
            $manifest = Get-Content -LiteralPath $LegacyUndoPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $manifest.CreatedAt -or -not $manifest.DesktopPath -or -not $manifest.ProjectFolder) { throw '旧撤回记录格式无效。' }
            $recordId = New-DesktopOrganizationRecordId
            $manifest | Add-Member -NotePropertyName RecordId -NotePropertyValue $recordId -Force
            Save-DesktopOrganizationManifest -Path (Join-Path $HistoryPath ($recordId + '.json')) -Manifest $manifest
            [IO.File]::Delete($LegacyUndoPath)
        }
        catch {
            throw ('无法迁移原有桌面整理撤回记录：' + $_.Exception.Message)
        }
    }
    [void](Get-DesktopOrganizationHistory -HistoryPath $HistoryPath -RetentionDays $RetentionDays)
}

function Invoke-DesktopProductOrganization {
    param(
        [Parameter(Mandatory)][string]$DesktopPath,
        [Parameter(Mandatory)][string]$HistoryPath,
        [Parameter(Mandatory)][ValidateSet('left','center','right','all')][string]$Scope,
        [object[]]$IconPositions,
        $ScreenBounds
    )

    if (-not (Test-Path -LiteralPath $DesktopPath -PathType Container)) { throw "桌面目录不存在：$DesktopPath" }
    [void][IO.Directory]::CreateDirectory($HistoryPath)
    $sourceFiles = @(Get-DesktopFilesForOrganization -DesktopPath $DesktopPath -Scope $Scope -IconPositions $IconPositions -ScreenBounds $ScreenBounds)
    $photoshopFiles = @($sourceFiles | Where-Object { $_.Extension -in @('.psd', '.psb') })
    if ($photoshopFiles.Count -eq 0) { throw '所选识别范围内没有找到 PSD/PSB 文件，未移动任何文件。' }
    if ($photoshopFiles.Count -gt 1) { throw '所选识别范围内找到多个 PSD/PSB 文件，无法唯一确定编号，未移动任何文件。' }

    $photoshopFile = $photoshopFiles[0]
    $code = $photoshopFile.BaseName.Trim()
    if ([string]::IsNullOrWhiteSpace($code)) { throw 'PSD 文件名为空，无法确定编号。' }
    $projectFolder = Get-DesktopProductFolder -DesktopPath $DesktopPath -Code $code
    $contentFolder = Join-Path $projectFolder.FullName $code
    $materialFolder = Join-Path $projectFolder.FullName '素材'
    $createdDirectories = [System.Collections.Generic.List[string]]::new()
    foreach ($directory in @($contentFolder, $materialFolder)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void][IO.Directory]::CreateDirectory($directory)
            $createdDirectories.Add($directory)
        }
    }

    $imageExtensions = @('.png','.jpg','.jpeg','.jfif','.webp','.bmp','.gif','.tif','.tiff')
    $moves = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $namedCount = 0
    $materialCount = 0
    $movePlans = [System.Collections.Generic.List[object]]::new()
    $movePlans.Add([PSCustomObject]@{ File = $photoshopFile; Destination = $projectFolder.FullName; Kind = 'PSD' })
    foreach ($file in $sourceFiles) {
        if ($file.FullName -eq $photoshopFile.FullName -or $file.Extension.ToLowerInvariant() -notin $imageExtensions) { continue }
        $isNamed = $file.BaseName -match '^(?i:主图|副图|A)[\s_-]*\d+'
        $movePlans.Add([PSCustomObject]@{ File = $file; Destination = $(if ($isNamed) { $contentFolder } else { $materialFolder }); Kind = $(if ($isNamed) { 'Named' } else { 'Material' }) })
    }
    foreach ($plan in $movePlans) {
        try {
            $destination = Get-UniqueMoveDestination -Directory $plan.Destination -Name $plan.File.Name
            [IO.File]::Move($plan.File.FullName, $destination)
            $moves.Add([PSCustomObject]@{ Source = $plan.File.FullName; Destination = $destination })
            if ($plan.Kind -eq 'Named') { $namedCount++ }
            elseif ($plan.Kind -eq 'Material') { $materialCount++ }
        }
        catch { $errors.Add("$($plan.File.Name)：$($_.Exception.Message)") }
    }
    if ($moves.Count -eq 0) { throw ('没有文件移动成功。' + $(if ($errors.Count) { ' ' + ($errors -join '；') } else { '' })) }
    $recordId = New-DesktopOrganizationRecordId
    $manifest = [PSCustomObject]@{
        Version = 2
        RecordId = $recordId
        CreatedAt = [DateTime]::Now.ToString('o')
        DesktopPath = [IO.Path]::GetFullPath($DesktopPath)
        Code = $code
        ProjectFolder = $projectFolder.FullName
        CreatedDirectories = @($createdDirectories)
        Moves = @($moves)
    }
    Save-DesktopOrganizationManifest -Path (Join-Path $HistoryPath ($recordId + '.json')) -Manifest $manifest
    return [PSCustomObject]@{ RecordId=$recordId; Code=$code; ProjectFolder=$projectFolder.FullName; MovedCount=$moves.Count; NamedImageCount=$namedCount; MaterialImageCount=$materialCount; Errors=@($errors); Success=($errors.Count -eq 0); CanUndo=$true }
}

function Undo-DesktopProductOrganization {
    param(
        [Parameter(Mandatory)][string]$HistoryPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$RecordId
    )

    $manifestPath = Join-Path $HistoryPath ($RecordId + '.json')
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw '这条桌面整理记录已不存在或已经恢复。' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.Version -notin @(1,2) -or -not $manifest.DesktopPath -or -not $manifest.ProjectFolder) { throw '恢复记录格式无效，未移动任何文件。' }
    $desktop = [IO.Path]::GetFullPath([string]$manifest.DesktopPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $project = [IO.Path]::GetFullPath([string]$manifest.ProjectFolder).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $remaining = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $undone = 0
    $movesToUndo = @($manifest.Moves)
    [array]::Reverse($movesToUndo)
    foreach ($move in $movesToUndo) {
        $source = [IO.Path]::GetFullPath([string]$move.Source)
        $destination = [IO.Path]::GetFullPath([string]$move.Destination)
        $sourceParent = [IO.Path]::GetFullPath((Split-Path -Parent $source)).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if (-not [string]::Equals($sourceParent, $desktop, [StringComparison]::OrdinalIgnoreCase) -or -not $destination.StartsWith($project + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add("不安全的撤回路径：$destination")
            $remaining.Add($move)
            continue
        }
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { $errors.Add("文件已不存在：$destination"); $remaining.Add($move); continue }
        if (Test-Path -LiteralPath $source) { $errors.Add("桌面已有同名文件，未覆盖：$source"); $remaining.Add($move); continue }
        try { [IO.File]::Move($destination, $source); $undone++ }
        catch { $errors.Add("$destination：$($_.Exception.Message)"); $remaining.Add($move) }
    }
    if ($remaining.Count -eq 0) {
        $createdDirectories = @($manifest.CreatedDirectories)
        [array]::Reverse($createdDirectories)
        foreach ($directory in $createdDirectories) {
            if ((Test-Path -LiteralPath $directory -PathType Container) -and -not (Get-ChildItem -LiteralPath $directory -Force | Select-Object -First 1)) { [IO.Directory]::Delete([string]$directory) }
        }
        [IO.File]::Delete($manifestPath)
    } else {
        $manifest.Moves = @($remaining)
        Save-DesktopOrganizationManifest -Path $manifestPath -Manifest $manifest
    }
    return [PSCustomObject]@{ RecordId=$RecordId; UndoneCount=$undone; Errors=@($errors); Success=($errors.Count -eq 0); CanUndo=($remaining.Count -gt 0) }
}

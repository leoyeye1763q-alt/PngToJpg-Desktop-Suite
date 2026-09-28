using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class WindowsInstall
{
    const string Product = "蟑螂强（PNG转JPG）";
    const string Id = "PngToJpg.DesktopSuite";
    const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + Id;
    const string AppPath = @"Software\Microsoft\Windows\CurrentVersion\App Paths\PngToJpgLauncher.exe";
    const string Marker = "pngtojpg-install.id";
    static string Root { get { return Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar); } }
    static string Menu { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "蟑螂强 PNG转JPG"); } }
    static string Launcher(string root) { return Path.Combine(root, "PngToJpgLauncher.exe"); }
    static string Quote(string value) { return "\"" + value + "\""; }

    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        try {
            string action = args.Length == 0 ? "--install" : args[0];
            if (action == "--self-test") { SelfTest(); return 0; }
            if (action == "--verify") { Verify(Root); return 0; }
            if (action == "--register" || action == "--install") {
                Register(Root);
                Verify(Root);
                if (action == "--install") MessageBox.Show("已登记到 Windows 已安装的应用，并添加开始菜单入口。", Product);
                return 0;
            }
            if (action == "--uninstall") {
                Verify(Root);
                string temp = Path.Combine(Path.GetTempPath(), Id + "-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(temp);
                string worker = Path.Combine(temp, "WindowsInstall.exe");
                File.Copy(Assembly.GetExecutingAssembly().Location, worker);
                Process.Start(new ProcessStartInfo(worker, "--remove " + Quote(Root)) { UseShellExecute = false });
                return 0;
            }
            if (action == "--remove" && args.Length == 2) { Uninstall(args[1]); return 0; }
            throw new InvalidOperationException("未知安装参数。");
        } catch (Exception e) {
            MessageBox.Show(e.Message, Product + " · 安装管理", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static void ValidateRoot(string root)
    {
        string full = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
        if (!String.Equals(full, root, StringComparison.OrdinalIgnoreCase) ||
            String.Equals(full, Path.GetPathRoot(full).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(Launcher(full)) || !File.Exists(Path.Combine(full, "PngToJpg.ps1")))
            throw new InvalidOperationException("不是有效的 PNG转JPG 程序目录，操作已拒绝。");
        for (DirectoryInfo directory = new DirectoryInfo(full); directory != null; directory = directory.Parent)
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("程序路径包含目录链接，操作已拒绝。");
    }

    static void WriteRegistration(RegistryKey key, string root)
    {
        key.SetValue("DisplayName", Product);
        key.SetValue("DisplayVersion", "3.0.12");
        key.SetValue("Publisher", "蟑螂强");
        key.SetValue("DisplayIcon", Launcher(root) + ",0");
        key.SetValue("InstallLocation", root);
        key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
        key.SetValue("UninstallString", Quote(Path.Combine(root, "WindowsInstall.exe")) + " --uninstall");
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        long bytes = 0;
        foreach (string file in Directory.GetFiles(root, "*", SearchOption.AllDirectories))
            bytes += new FileInfo(file).Length;
        key.SetValue("EstimatedSize", (int)Math.Min(Int32.MaxValue, (bytes + 1023) / 1024), RegistryValueKind.DWord);
    }

    static void Register(string root)
    {
        ValidateRoot(root);
        using (RegistryKey old = Registry.CurrentUser.OpenSubKey(KeyPath)) {
            if (old != null && !String.Equals(Convert.ToString(old.GetValue("InstallLocation")), root, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("另一个安装位置已登记，请先处理已有安装，避免覆盖。");
        }
        File.WriteAllText(Path.Combine(root, Marker), Id);
        Directory.CreateDirectory(Menu);
        Shortcut(Path.Combine(Menu, Product + ".lnk"), Launcher(root), "", root);
        Shortcut(Path.Combine(Menu, "卸载蟑螂强.lnk"), Path.Combine(root, "WindowsInstall.exe"), "--uninstall", root);
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(KeyPath)) WriteRegistration(key, root);
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(AppPath)) {
            key.SetValue("", Launcher(root));
            key.SetValue("Path", root);
        }
    }

    static object Shell { get { return Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell", true)); } }
    static object GetShortcut(object shell, string path)
    {
        return shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
    }
    static void Shortcut(string path, string target, string arguments, string root)
    {
        object shell = Shell;
        object link = GetShortcut(shell, path);
        foreach (object[] pair in new[] {
            new object[] {"TargetPath", target}, new object[] {"Arguments", arguments},
            new object[] {"WorkingDirectory", root}, new object[] {"IconLocation", Launcher(root) + ",0"}
        }) link.GetType().InvokeMember((string)pair[0], BindingFlags.SetProperty, null, link, new object[] { pair[1] });
        link.GetType().InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
    }
    static bool PointsTo(string path, string target)
    {
        if (!File.Exists(path)) return false;
        object shell = Shell, link = GetShortcut(shell, path);
        string actual = Convert.ToString(link.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, link, null));
        return String.Equals(actual, target, StringComparison.OrdinalIgnoreCase);
    }
    static void Verify(string root)
    {
        ValidateRoot(root);
        if (File.ReadAllText(Path.Combine(root, Marker)) != Id) throw new InvalidOperationException("缺少有效安装标记。");
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(KeyPath)) {
            if (key == null || Convert.ToString(key.GetValue("DisplayName")) != Product ||
                !String.Equals(Convert.ToString(key.GetValue("InstallLocation")), root, StringComparison.OrdinalIgnoreCase) ||
                Convert.ToString(key.GetValue("UninstallString")) != Quote(Path.Combine(root, "WindowsInstall.exe")) + " --uninstall")
                throw new InvalidOperationException("Windows 安装登记验证失败。");
        }
        if (!PointsTo(Path.Combine(Menu, Product + ".lnk"), Launcher(root)))
            throw new InvalidOperationException("开始菜单入口验证失败。");
    }

    static void Uninstall(string root)
    {
        Verify(root);
        foreach (Process process in Process.GetProcessesByName("PngToJpgLauncher")) {
            try {
                if (String.Equals(process.MainModule.FileName, Launcher(root), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("请正常退出蟑螂强 APP 后再卸载，避免中断整理任务。");
            } finally { process.Dispose(); }
        }
        string backup = root + "_已卸载回退_" + DateTime.Now.ToString("yyyyMMdd_HHmmss_fff");
        string parent = Path.GetDirectoryName(root);
        if (!String.Equals(Path.GetDirectoryName(Path.GetFullPath(backup)), parent, StringComparison.OrdinalIgnoreCase) || Directory.Exists(backup))
            throw new InvalidOperationException("回退路径验证失败。");
        if (MessageBox.Show("确定卸载 Windows 应用入口？\r\n程序、历史和加密配置将整体保留到本机回退目录，不删除个人数据。\r\n\r\n" + backup,
            Product, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        // Checked absolute sibling paths; no recursive deletion or broad-directory move.
        Directory.Move(root, backup);
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        foreach (string desktopLink in Directory.GetFiles(desktop, "*.lnk"))
            if (PointsTo(desktopLink, Launcher(root))) File.Delete(desktopLink);
        string appLink = Path.Combine(Menu, Product + ".lnk");
        string uninstallLink = Path.Combine(Menu, "卸载蟑螂强.lnk");
        if (PointsTo(appLink, Launcher(root))) File.Delete(appLink);
        if (PointsTo(uninstallLink, Path.Combine(root, "WindowsInstall.exe"))) File.Delete(uninstallLink);
        if (Directory.Exists(Menu) && Directory.GetFileSystemEntries(Menu).Length == 0) Directory.Delete(Menu);
        Registry.CurrentUser.DeleteSubKeyTree(KeyPath, false);
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(AppPath)) {
            if (key != null && String.Equals(Convert.ToString(key.GetValue("")), Launcher(root), StringComparison.OrdinalIgnoreCase))
                Registry.CurrentUser.DeleteSubKeyTree(AppPath, false);
        }
        MessageBox.Show("已卸载。历史和程序回退目录：\r\n" + backup, Product);
    }

    static void SelfTest()
    {
        string temporary = Path.Combine(Path.GetTempPath(), Id + "-test-" + Guid.NewGuid().ToString("N"));
        string testKey = @"Software\PngToJpgInstallTests\" + Guid.NewGuid().ToString("N");
        Directory.CreateDirectory(temporary);
        try {
            File.WriteAllText(Launcher(temporary), "test");
            File.WriteAllText(Path.Combine(temporary, "PngToJpg.ps1"), "test");
            ValidateRoot(temporary);
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(testKey)) {
                WriteRegistration(key, temporary);
                if (Convert.ToString(key.GetValue("DisplayName")) != Product ||
                    key.GetValueKind("EstimatedSize") != RegistryValueKind.DWord ||
                    !Convert.ToString(key.GetValue("UninstallString")).Contains("--uninstall")) throw new Exception("登记字段测试失败。");
            }
            string link = Path.Combine(temporary, "test.lnk");
            Shortcut(link, Launcher(temporary), "", temporary);
            if (!PointsTo(link, Launcher(temporary))) throw new Exception("快捷方式测试失败。");
            bool rejected = false;
            try { ValidateRoot(Path.GetPathRoot(temporary)); } catch (InvalidOperationException) { rejected = true; }
            if (!rejected) throw new Exception("根目录安全测试失败。");
        } finally {
            Registry.CurrentUser.DeleteSubKeyTree(testKey, false);
            foreach (string file in Directory.GetFiles(temporary)) File.Delete(file);
            Directory.Delete(temporary);
        }
    }
}

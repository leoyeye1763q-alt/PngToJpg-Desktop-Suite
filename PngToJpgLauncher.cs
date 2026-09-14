using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class PngToJpgLauncher
{
    [STAThread]
    private static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        try
        {
            string appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            string scriptPath = Path.Combine(appDirectory, "PngToJpg.ps1");
            if (!File.Exists(scriptPath))
            {
                MessageBox.Show("找不到程序脚本：\r\n" + scriptPath, "PNG/JPG 转 JPG", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string bundledRuntime = Path.Combine(
                userProfile,
                @".cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"
            );
            string runtimePath = File.Exists(bundledRuntime) ? bundledRuntime : "pwsh.exe";

            StringBuilder arguments = new StringBuilder();
            AppendArgument(arguments, "-NoLogo");
            AppendArgument(arguments, "-NoProfile");
            AppendArgument(arguments, "-File");
            AppendArgument(arguments, scriptPath);
            foreach (string argument in args)
            {
                AppendArgument(arguments, argument);
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = runtimePath;
            startInfo.Arguments = arguments.ToString();
            startInfo.WorkingDirectory = appDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardError = true;

            using (Process process = Process.Start(startInfo))
            {
                string errorText = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    if (string.IsNullOrWhiteSpace(errorText))
                    {
                        errorText = "程序异常退出，退出代码：" + process.ExitCode;
                    }
                    MessageBox.Show(errorText, "PNG/JPG 转 JPG · 启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "PNG/JPG 转 JPG · 启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static void AppendArgument(StringBuilder commandLine, string argument)
    {
        if (commandLine.Length > 0)
        {
            commandLine.Append(' ');
        }
        commandLine.Append(QuoteArgument(argument ?? string.Empty));
    }

    private static string QuoteArgument(string argument)
    {
        if (argument.Length > 0 && argument.IndexOfAny(new[] { ' ', '\t', '\r', '\n', '"' }) < 0)
        {
            return argument;
        }

        StringBuilder result = new StringBuilder();
        result.Append('"');
        int backslashCount = 0;
        foreach (char character in argument)
        {
            if (character == '\\')
            {
                backslashCount++;
            }
            else if (character == '"')
            {
                result.Append('\\', backslashCount * 2 + 1);
                result.Append('"');
                backslashCount = 0;
            }
            else
            {
                result.Append('\\', backslashCount);
                result.Append(character);
                backslashCount = 0;
            }
        }
        result.Append('\\', backslashCount * 2);
        result.Append('"');
        return result.ToString();
    }
}

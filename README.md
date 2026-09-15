# 蟑螂强 Desktop Suite

一款面向 Windows 的本地图片处理与文件整理桌面工具。当前开源版本为 v3.0.9。

v3.0.9 新增“存储管理中心”：仅扫描 APP 自身 `data/` 目录，展示缓存、临时文件、索引与日志占用；用户手动选择并二次确认后才会删除，全程离线且不扫描用户图片、PSD 或项目目录。

## 功能

- PNG、JPG、JPEG、JFIF、WebP 互转与批量尺寸处理
- 保守清晰增强与 Real-ESRGAN 本地高清
- 可选的图片编辑 API 接入
- 钉钉下载文件夹后台监控与批量整理
- 按 PSD/PSB 编号整理桌面成品并提供 30 天逐次恢复
- 图片转链接、本地文件名搜索与相似图片搜索
- 完全离线的本地 Photoshop 助手，通过临时 JSX 检测活动 PSD 并导出 JPG、PNG、PSD 副本
- 七套界面主题（新增液态水晶玻璃）和多屏表格打开位置选择

默认图片转换、文件夹整理和本地搜索都在本机完成。只有用户主动选择 API 清晰或图片转链接并执行上传时，文件才会发送到用户配置的服务。

## 系统要求

- Windows 10 或 Windows 11
- PowerShell 7
- Microsoft Edge WebView2 Runtime

完整功能还依赖 ImageMagick、Poppler、Real-ESRGAN NCNN Vulkan 和 WebView2 SDK 文件。为避免把第三方大型二进制直接放入源码仓库，它们未纳入 Git；请按 `PACKAGING.md` 中的目录结构放入 `tools`。各组件许可证与声明位于 `licenses`。

## 从源码运行

1. 克隆仓库。
2. 准备 `PACKAGING.md` 列出的第三方依赖。
3. 使用下面的命令编译无终端窗口的启动器：

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /win32icon:PngToJpg.ico /out:PngToJpgLauncher.exe PngToJpgLauncher.cs
```

4. 双击 `PngToJpgLauncher.exe`，或运行 `pwsh -NoProfile -File .\PngToJpg.ps1`。

## 测试

```powershell
pwsh -NoProfile -File .\tests\FolderOrganizer.Tests.ps1
pwsh -NoProfile -File .\tests\PhotoshopAssistant.Tests.ps1
pwsh -NoProfile -File .\PngToJpg.ps1 -SmokeTestWebUi
```

Web UI 冒烟测试需要 WebView2 SDK 文件已放入 `tools\webview2`。
Photoshop 集成测试需要本机已启动 Photoshop；模块本身不连接网络或上传文件。

## 隐私与配置

- `data` 保存本地历史、偏好、缓存和当前 Windows 用户加密的凭证，已被 `.gitignore` 排除。
- 不要提交 API Key、Cloudflare R2 凭证、用户图片、整理恢复记录、WebView 缓存或测试产物。
- API 失败响应可能保存在 `%LOCALAPPDATA%\PngToJpg\ApiResponses`，排查后请自行管理。

## 贡献

欢迎通过 Issue 报告可复现问题，并通过 Pull Request 提交聚焦、可验证的改动。涉及文件移动或恢复逻辑的改动，请同时补充相应测试。

## 许可证

本项目源码采用 [MIT License](LICENSE)。第三方组件继续适用各自许可证，详见 `licenses`。

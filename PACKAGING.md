# 安装、打包与回退

## 直接运行

双击 `PngToJpgLauncher.exe`。桌面快捷方式应继续指向这个 GUI 启动器，不需要终端窗口、`ExecutionPolicy Bypass` 或隐藏启动参数。

## 目录要求

以下文件必须保持相对位置：

- `PngToJpg.ps1`
- `PngToJpgLauncher.exe`
- `modules\ImageWorker.ps1`
- `modules\DocumentWorker.ps1`
- `modules\ImageApi.ps1`
- `modules\ImageApiResponse.ps1`
- `modules\ImageApiSettings.ps1`
- `modules\ImageLink.ps1`
- `modules\ClarityPage.ps1`
- `tools\RestoreApiResponse.ps1`
- `modules\FolderOrganizer.ps1`
- `modules\FolderOrganizerWorker.ps1`
- `modules\PreviewWorker.ps1`
- `tools\imagemagick\magick.exe` 及同目录组件
- `tools\poppler\bin\pdftoppm.exe`、相关 DLL 及 `tools\poppler\share` 数据
- `tools\realesrgan\realesrgan-ncnn-vulkan.exe`
- `tools\realesrgan\models\*.param` 和 `*.bin`

## 更新已有安装

覆盖程序文件时不要覆盖或删除 `data\history.json`。发布压缩包默认不包含用户历史记录；APP 在首次启动时会自行创建 `data` 目录。

同样保留用户的 `data\image-api.json`，发布压缩包排除该文件，其中包含当前用户加密的 API 密钥。
保留独立图片清晰页面的 `data\clarity-state.json`，避免更新时丢失清晰页的图片列表和输出设置。
同样保留 `data\image-link.json`；其中包含当前 Windows 用户级加密的 Cloudflare R2 访问凭证、图片链接页面选项及 APP 免费额度保护计数。
同样保留 `data\local-search.json`；其中包含用户选择的搜索根目录与相似度阈值。

本地内容搜索功能需要随包包含：

- `modules\LocalSearch.ps1`
- `modules\LocalSearchWorker.ps1`
- `web\local-search.html`
- `web\local-search.css`
- `web\new-pages-unified.css`

## 回退

关闭 APP 后，把当前程序目录改名留存，再将已验证的旧版本备份解压到新的目录中运行。确认旧版正常后，再复制回桌面快捷方式指向的安装位置。

如果需要保留新版本运行期间新增的历史，先单独复制当前 `data\history.json`，不要直接删除。

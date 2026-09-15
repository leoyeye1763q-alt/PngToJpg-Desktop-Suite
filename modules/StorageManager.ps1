function Get-StorageCategoryDefinitions {
    @(
        [PSCustomObject]@{ Id='preview'; Name='图片预览缓存'; Level='safe'; Recommendation='建议删除'; Description='删除后会在需要时重新生成预览。'; Roots=@('preview','thumbnail','preview-cache','thumbnails') }
        [PSCustomObject]@{ Id='temp'; Name='转换临时文件'; Level='safe'; Recommendation='建议删除'; Description='任务完成后的中间文件。'; Roots=@('temp','upload_temp','conversion-temp') }
        [PSCustomObject]@{ Id='ai'; Name='AI 增强缓存'; Level='caution'; Recommendation='谨慎删除'; Description='删除后可能需要重新生成增强结果。'; Roots=@('api_cache','ai_cache','enhancement_cache') }
        [PSCustomObject]@{ Id='search'; Name='本地搜索索引缓存'; Level='protect'; Recommendation='不建议删除'; Description='删除后需要重新扫描建立索引。'; Roots=@('search_index','search-cache','local-search-cache') }
        [PSCustomObject]@{ Id='logs'; Name='日志文件'; Level='safe'; Recommendation='可以删除'; Description='删除不会影响功能；存储管理删除记录会单独保留。'; Roots=@('logs') }
        [PSCustomObject]@{ Id='webview'; Name='界面运行缓存'; Level='caution'; Recommendation='谨慎删除'; Description='APP 运行时可能占用，无法删除的文件会自动跳过。'; Roots=@('webview-profile') }
    )
}

function Test-StoragePathInsideData([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $dataRoot = [IO.Path]::GetFullPath($script:dataDirectory).TrimEnd('\','/')
    $root = $dataRoot + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    return $full.Equals($dataRoot,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Get-StorageFilesFromRoot([string]$RootPath) {
    $result = [Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container) -or -not (Test-StoragePathInsideData $RootPath)) { return @() }
    $rootItem = Get-Item -LiteralPath $RootPath -Force -ErrorAction SilentlyContinue
    if (-not $rootItem -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return @() }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($RootPath))
    while ($pending.Count) {
        $directory = $pending.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if (-not (Test-StoragePathInsideData $entry.FullName)) { continue }
            if ($entry.PSIsContainer) { $pending.Push($entry.FullName); continue }
            $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($script:dataDirectory), $entry.FullName)
            $result.Add([PSCustomObject]@{ Name=$entry.Name; RelativePath=$relative; FullPath=$entry.FullName; Size=[long]$entry.Length; CreatedAt=$entry.CreationTime.ToString('yyyy-MM-dd HH:mm:ss') })
        }
    }
    return $result.ToArray()
}

function Get-StorageCategorySnapshot($Definition) {
    $files = [Collections.Generic.List[object]]::new()
    $locations = [Collections.Generic.List[string]]::new()
    foreach ($relativeRoot in $Definition.Roots) {
        $root = Join-Path $script:dataDirectory $relativeRoot
        $locations.Add($root)
        foreach ($file in @(Get-StorageFilesFromRoot $root)) { $files.Add($file) }
    }
    $bytes = [long]0
    foreach ($file in $files) { $bytes += [long]$file.Size }
    [PSCustomObject]@{ Id=$Definition.Id; Name=$Definition.Name; Level=$Definition.Level; Recommendation=$Definition.Recommendation; Description=$Definition.Description; Bytes=$bytes; FileCount=$files.Count; Locations=$locations.ToArray(); Exists=[bool](@($locations | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count); Files=@($files | Sort-Object Size -Descending) }
}

function Get-StorageManagerWebState {
    $categories = @(Get-StorageCategoryDefinitions | ForEach-Object { Get-StorageCategorySnapshot $_ })
    $allFiles = @(Get-StorageFilesFromRoot $script:dataDirectory)
    $total = [long]0; foreach ($file in $allFiles) { $total += [long]$file.Size }
    $releasable = [long]0; foreach ($category in $categories) { if ($category.Level -eq 'safe') { $releasable += [long]$category.Bytes } }
    [PSCustomObject]@{ DataRoot=[IO.Path]::GetFullPath($script:dataDirectory); TotalBytes=$total; ReleasableBytes=$releasable; TotalFiles=$allFiles.Count; Categories=$categories; LastScan=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); AuditPath=(Join-Path $script:dataDirectory 'storage-manager.log'); Offline=$true }
}

function Get-StorageDefinition([string]$CategoryId) {
    $definition = Get-StorageCategoryDefinitions | Where-Object Id -eq $CategoryId | Select-Object -First 1
    if (-not $definition) { throw '未知的数据分类，操作已拒绝。' }
    return $definition
}

function Open-StorageCategory([string]$CategoryId) {
    $definition = Get-StorageDefinition $CategoryId
    $existing = @($definition.Roots | ForEach-Object { Join-Path $script:dataDirectory $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Container }) | Select-Object -First 1
    if (-not $existing) { throw '该分类当前没有可打开的目录。' }
    if (-not (Test-StoragePathInsideData $existing)) { throw '目录超出 APP 数据范围，操作已拒绝。' }
    Start-Process explorer.exe -ArgumentList @($existing)
}

function Write-StorageDeletionAudit($Result) {
    [void][IO.Directory]::CreateDirectory($script:dataDirectory)
    $line = '{0} | 删除类型：{1} | 文件：{2} 个 | 释放：{3} 字节 | 跳过：{4} 个 | 结果：{5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Result.CategoryName,$Result.DeletedCount,$Result.ReleasedBytes,$Result.SkippedCount,$Result.Message
    Add-Content -LiteralPath (Join-Path $script:dataDirectory 'storage-manager.log') -Value $line -Encoding UTF8
}

function Remove-StorageSelectedFiles([string]$CategoryId, [string[]]$RelativePaths) {
    $definition = Get-StorageDefinition $CategoryId
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @(Get-StorageCategorySnapshot $definition).Files) { [void]$allowed.Add([string]$file.RelativePath) }
    $deleted = 0; $released = [long]0; $skipped = [Collections.Generic.List[object]]::new()
    foreach ($relative in @($RelativePaths | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($relative) -or -not $allowed.Contains($relative)) { $skipped.Add([PSCustomObject]@{Path=$relative;Reason='不在该分类白名单或文件已变化'}) ; continue }
        $path = [IO.Path]::GetFullPath((Join-Path $script:dataDirectory $relative))
        if (-not (Test-StoragePathInsideData $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { $skipped.Add([PSCustomObject]@{Path=$relative;Reason='文件不存在或路径不安全'}); continue }
        try {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '链接文件不允许删除' }
            $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
            $stream.Dispose()
            $size = [long]$item.Length
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            $deleted++; $released += $size
        } catch { $skipped.Add([PSCustomObject]@{Path=$relative;Reason=$_.Exception.Message}) }
    }
    $message = if ($skipped.Count) { "已删除 $deleted 个文件，跳过 $($skipped.Count) 个被占用或无法删除的文件。" } else { "已删除 $deleted 个文件。" }
    $result = [PSCustomObject]@{ Category=$CategoryId; CategoryName=$definition.Name; DeletedCount=$deleted; ReleasedBytes=$released; SkippedCount=$skipped.Count; Skipped=$skipped.ToArray(); Message=$message }
    Write-StorageDeletionAudit $result
    return $result
}

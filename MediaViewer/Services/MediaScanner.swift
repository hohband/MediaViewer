import Foundation

/// 扫描文件夹，得到按文件名自然排序的媒体列表。
///
/// 这里刻意保持为纯函数（不依赖 UI、不依赖主线程），
/// 这样命令行探针可以直接调用同一份实现做验证。
enum MediaScanner {
    /// 扫描 `folder` 里第一层的媒体文件（不递归子目录，跳过隐藏文件）。
    static func scan(folder: URL) throws -> [MediaItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
        )

        var items: [MediaItem] = []
        items.reserveCapacity(urls.count)

        for url in urls {
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegularFile, let kind = MediaFormats.kind(for: url) else { continue }
            items.append(MediaItem(url: url, kind: kind))
        }

        return items.sorted { lhs, rhs in
            let result = lhs.fileName.localizedStandardCompare(rhs.fileName)
            if result == .orderedSame { return lhs.fileName < rhs.fileName }
            return result == .orderedAscending
        }
    }
}
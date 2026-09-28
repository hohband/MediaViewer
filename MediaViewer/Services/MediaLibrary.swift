import AppKit
import Combine
import Foundation

/// 当前打开的文件夹，以及“上一个 / 下一个”的导航状态。
///
/// 这里刻意用 `ObservableObject` 而不是 `@Observable`：
/// 后者依赖 Swift 宏插件（swift-plugin-server），在部分受限的构建环境里无法运行。
@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var folderURL: URL?
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var message: String?

    var currentItem: MediaItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var canGoPrevious: Bool {
        guard let currentIndex else { return false }
        return currentIndex > 0
    }

    var canGoNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < items.count
    }

    var positionText: String {
        guard let currentIndex, !items.isEmpty else { return "0 / 0" }
        return "\(currentIndex + 1) / \(items.count)"
    }

    /// 打开文件夹：扫描媒体文件并选中第一个。
    func load(folder url: URL) {
        do {
            let scanned = try MediaScanner.scan(folder: url)
            folderURL = url
            items = scanned
            currentIndex = scanned.isEmpty ? nil : 0
            message = scanned.isEmpty ? "这个文件夹里没有可预览的图片或视频。" : nil
        } catch {
            folderURL = url
            items = []
            currentIndex = nil
            message = error.localizedDescription
        }
    }

    /// 重新扫描当前文件夹，并尽量停留在原来那个文件上。
    func reload() {
        guard let folderURL else { return }
        let previous = currentItem?.url
        load(folder: folderURL)
        if let previous, let index = items.firstIndex(where: { $0.url == previous }) {
            currentIndex = index
        }
    }

    /// 如果 `url` 是一个目录就打开它；返回是否打开成功。
    @discardableResult
    func loadIfDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        load(folder: url)
        return true
    }

    func goToPrevious() {
        guard let currentIndex, currentIndex > 0 else { return }
        self.currentIndex = currentIndex - 1
    }

    func goToNext() {
        guard let currentIndex, currentIndex + 1 < items.count else { return }
        self.currentIndex = currentIndex + 1
    }

    /// 弹出系统文件夹选择面板。
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "打开"
        panel.message = "选择包含图片或视频的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            load(folder: url)
        }
    }
}
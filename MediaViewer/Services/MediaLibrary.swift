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

    /// 界面偏好：元数据面板 / 胶片栏 / 幻灯片放映。
    /// 放在这里而不是 ContentView 的 @State 里，这样工具栏和菜单命令都能直接改。
    @Published var showsInspector = true
    @Published var showsFilmstrip = true
    @Published var isSlideshow = false

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

    /// 打开任意路径：目录当成素材文件夹，文件则打开它所在的文件夹并选中它。
    ///
    /// 这是对外的统一入口：打开面板、命令行参数、Finder「打开方式」都走这里。
    /// 返回是否打开成功（路径不存在，或文件格式不在 `MediaFormats` 里时为 false）。
    @discardableResult
    func open(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            load(folder: url)
            return true
        }
        return load(file: url)
    }

    /// 打开单个媒体文件：扫描它所在的文件夹，并把它选为当前项。
    @discardableResult
    func load(file url: URL) -> Bool {
        guard MediaFormats.kind(for: url) != nil else {
            // 右键「打开方式」里选了 MediaViewer，但格式不在支持列表里：
            // 给出明确提示，而不是留一个空窗口。
            folderURL = nil
            items = []
            currentIndex = nil
            let ext = url.pathExtension
            message = ext.isEmpty
                ? "「\(url.lastPathComponent)」不是可预览的图片或视频。"
                : "暂不支持 .\(ext.lowercased()) 格式。"
            return false
        }

        load(folder: url.deletingLastPathComponent())
        if let index = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            currentIndex = index
        }
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

    /// 跳到指定位置（给胶片栏点击用）。
    func select(index: Int) {
        guard items.indices.contains(index) else { return }
        if currentIndex != index {
            currentIndex = index
        }
    }

    /// 幻灯片放映用的步进：到末尾后回到开头，方便循环播放。
    func advanceForSlideshow() {
        guard !items.isEmpty else { return }
        guard let currentIndex else {
            self.currentIndex = 0
            return
        }
        self.currentIndex = (currentIndex + 1) % items.count
    }

    /// 弹出系统打开面板：可以选文件夹，也可以直接选一个或多个媒体文件。
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "打开"
        panel.message = "选择图片 / 视频，或包含它们的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }
}
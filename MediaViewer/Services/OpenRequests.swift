import AppKit
import Foundation

/// Finder（双击 / 右键「打开方式」/ 拖到 Dock 图标）和 `open -a` 送来的打开请求。
///
/// 这类请求走的是 LaunchServices 的「打开文稿」事件，不是命令行参数，所以拿不到
/// `CommandLine.arguments`。请求可能在窗口还没建好时就到了（App 刚被拉起），
/// 于是先塞进队列；界面起来后由 `ContentView` 取走。App 已经在运行时靠通知即时取走。
@MainActor
enum OpenRequests {
    /// 队列有变化（新请求入队）时发出，`ContentView` 收到后立刻取走。
    static let didChange = Notification.Name("MediaViewer.openRequestsDidChange")

    private static var pending: [URL] = []

    static func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.append(contentsOf: urls)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 取走并清空队列。
    static func drain() -> [URL] {
        defer { pending.removeAll() }
        return pending
    }
}

/// 接收 LaunchServices 的打开事件。
///
/// SwiftUI 的 `.onOpenURL` 也能接住一部分，但「App 未运行 + 双击文件」这条路径并不可靠，
/// 所以这里用 AppDelegate 兜底；两条路径最终都汇到 `OpenRequests`，重复打开同一个文件
/// 只是重新选中一次，没有副作用。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenRequests.enqueue(urls)
    }

    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        OpenRequests.enqueue([URL(fileURLWithPath: filename)])
        return true
    }
}

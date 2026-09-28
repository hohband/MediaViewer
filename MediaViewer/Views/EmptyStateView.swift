import SwiftUI

/// 还没有打开文件夹时的引导页。
struct EmptyStateView: View {
    @EnvironmentObject private var library: MediaLibrary

    let message: String?

    var body: some View {
        ContentUnavailableView {
            Label("打开一个文件夹", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(message ?? "选择一个包含图片或视频的文件夹，就能预览、播放，并用工具栏的上一个 / 下一个按钮翻看同文件夹里的其他媒体。")
        } actions: {
            Button("打开文件夹…") {
                library.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}
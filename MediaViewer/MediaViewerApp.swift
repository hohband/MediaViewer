import AppKit
import SwiftUI

@main
struct MediaViewerApp: App {
    /// 接住 Finder / LaunchServices 的「用 MediaViewer 打开」事件（见 OpenRequests.swift）。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = MediaLibrary()

    init() {
        MediaViewerDiagnostics.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开…") {
                    library.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("浏览") {
                Button("上一个") {
                    library.goToPrevious()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!library.canGoPrevious)

                Button("下一个") {
                    library.goToNext()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!library.canGoNext)

                Divider()

                Button(library.isSlideshow ? "停止幻灯片放映" : "开始幻灯片放映") {
                    library.isSlideshow.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(library.items.isEmpty)

                Button(library.showsFilmstrip ? "隐藏胶片栏" : "显示胶片栏") {
                    library.showsFilmstrip.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(library.items.isEmpty)

                Button(library.showsInspector ? "隐藏元数据面板" : "显示元数据面板") {
                    library.showsInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: .command)

                Divider()

                Button("在访达中显示当前文件") {
                    if let url = library.currentItem?.url {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(library.currentItem == nil)

                Button("重新载入文件夹") {
                    library.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(library.folderURL == nil)
            }
        }
    }
}

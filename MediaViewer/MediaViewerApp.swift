import SwiftUI

@main
struct MediaViewerApp: App {
    @StateObject private var library = MediaLibrary()

    init() {
        MediaViewerDiagnostics.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") {
                    library.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("浏览") {
                Button("上一个") {
                    library.goToPrevious()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button("下一个") {
                    library.goToNext()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)

                Divider()

                Button("重新载入文件夹") {
                    library.reload()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
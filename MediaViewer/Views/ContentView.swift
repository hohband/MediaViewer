import SwiftUI

/// 主窗口：预览区 + 底部状态栏 + 右侧元数据面板。
struct ContentView: View {
    @EnvironmentObject private var library: MediaLibrary

    @State private var sections: [MetadataSection] = []
    @State private var loadState: MetadataLoadState = .idle
    @State private var showsInspector = true

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 460)
            .navigationTitle(library.currentItem?.fileName ?? "MediaViewer")
            .navigationSubtitle(subtitle)
            .toolbar { toolbarItems }
            .inspector(isPresented: $showsInspector) {
                MetadataInspectorView(item: library.currentItem, sections: sections, state: loadState)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
            }
            .task { openInitialPaths() }
            .task(id: library.currentItem?.url) { await loadMetadata() }
            .onOpenURL { url in
                library.open(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: OpenRequests.didChange)) { _ in
                openPendingRequests()
            }
    }

    @ViewBuilder
    private var content: some View {
        if library.items.isEmpty {
            EmptyStateView(message: library.message)
        } else {
            VStack(spacing: 0) {
                MediaStageView(item: library.currentItem)
                Divider()
                StatusBarView()
            }
        }
    }

    private var subtitle: String {
        guard let folderURL = library.folderURL else { return "" }
        guard !library.items.isEmpty else { return folderURL.lastPathComponent }
        return "\(folderURL.lastPathComponent) · \(library.positionText)"
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                library.goToPrevious()
            } label: {
                Label("上一个", systemImage: "chevron.left")
            }
            .disabled(!library.canGoPrevious)
            .help("上一个（⌘←）")

            Button {
                library.goToNext()
            } label: {
                Label("下一个", systemImage: "chevron.right")
            }
            .disabled(!library.canGoNext)
            .help("下一个（⌘→）")

            Text(library.positionText)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                library.presentOpenPanel()
            } label: {
                Label("打开文件夹", systemImage: "folder")
            }
            .help("打开文件夹（⌘O）")

            Button {
                library.reload()
            } label: {
                Label("重新载入", systemImage: "arrow.clockwise")
            }
            .disabled(library.folderURL == nil)
            .help("重新载入文件夹（⌘R）")

            Toggle(isOn: $showsInspector) {
                Label("元数据", systemImage: "info.circle")
            }
            .help("显示或隐藏元数据面板（⌘I）")
        }
    }

    /// 启动时决定看什么：先命令行参数（`MediaViewer.app/Contents/MacOS/MediaViewer <路径>`），
    /// 再 Finder / LaunchServices 送来的「打开方式」请求。
    private func openInitialPaths() {
        guard library.folderURL == nil else { return }

        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            if library.open(URL(fileURLWithPath: argument)) { return }
        }

        openPendingRequests()
    }

    /// 处理 Finder 双击 / 右键「打开方式」/ 拖到 Dock 图标打开的文件。
    /// 多选时按顺序打开，最后停在最后一个文件上。
    private func openPendingRequests() {
        for url in OpenRequests.drain() {
            library.open(url)
        }
    }

    private func loadMetadata() async {
        guard let item = library.currentItem else {
            sections = []
            loadState = .idle
            return
        }

        loadState = .loading
        sections = []

        let loaded = await MetadataReader.sections(for: item)

        // 读取过程中用户可能已经翻到别的文件，丢弃过期结果。
        guard item.url == library.currentItem?.url else { return }

        sections = loaded
        loadState = loaded.isEmpty ? .failed("没有可显示的元数据。") : .loaded
    }
}

/// 底部状态栏：当前文件名、所在文件夹、第几个 / 共几个。
struct StatusBarView: View {
    @EnvironmentObject private var library: MediaLibrary

    var body: some View {
        HStack(spacing: 8) {
            if let item = library.currentItem {
                Image(systemName: item.kind.systemImageName)
                    .foregroundStyle(.secondary)
                Text(item.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 12)

            if let folderURL = library.folderURL {
                Text(folderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Text(library.positionText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
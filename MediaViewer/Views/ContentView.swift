import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口：预览区 + 胶片栏 + 底部状态栏 + 右侧元数据面板。
struct ContentView: View {
    @EnvironmentObject private var library: MediaLibrary

    @State private var sections: [MetadataSection] = []
    @State private var loadState: MetadataLoadState = .idle

    var body: some View {
        content
            .frame(minWidth: 920, minHeight: 600)
            .navigationTitle(library.currentItem?.fileName ?? "MediaViewer")
            .navigationSubtitle(subtitle)
            .toolbar { toolbarItems }
            .inspector(isPresented: inspectorBinding) {
                MetadataInspectorView(item: library.currentItem, sections: sections, state: loadState)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
            }
            .task { openInitialPaths() }
            .task(id: library.currentItem?.url) { await loadMetadata() }
            .task(id: library.isSlideshow) { await runSlideshow() }
            .onOpenURL { url in
                library.open(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: OpenRequests.didChange)) { _ in
                openPendingRequests()
            }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
            .onKeyPress(.leftArrow) {
                guard library.canGoPrevious else { return .ignored }
                library.goToPrevious()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard library.canGoNext else { return .ignored }
                library.goToNext()
                return .handled
            }
            .onKeyPress(.space) {
                guard library.canGoNext else { return .ignored }
                library.goToNext()
                return .handled
            }
    }

    // MARK: - 布局

    @ViewBuilder
    private var content: some View {
        if library.items.isEmpty {
            EmptyStateView(message: library.message)
        } else {
            VStack(spacing: 0) {
                MediaStageView(
                    item: library.currentItem,
                    canGoPrevious: library.canGoPrevious,
                    canGoNext: library.canGoNext,
                    onPrevious: { library.goToPrevious() },
                    onNext: { library.goToNext() }
                )
                .layoutPriority(1)

                if library.showsFilmstrip, library.items.count > 1 {
                    Divider()
                    FilmstripView(
                        items: library.items,
                        currentIndex: library.currentIndex,
                        onSelect: { library.select(index: $0) }
                    )
                }

                Divider()
                StatusBarView()
            }
        }
    }

    private var subtitle: String {
        // 计数只在工具栏胶囊里出现一次，副标题只留文件夹名，标题区不再拥挤。
        guard let folderURL = library.folderURL else { return "" }
        return folderURL.lastPathComponent
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // 和预览区悬浮箭头同款的独立圆钮：去掉外框胶囊，不再局促。
            HStack(spacing: 8) {
                navButton(
                    systemImage: "chevron.left",
                    tip: "上一个（←）",
                    disabled: !library.canGoPrevious
                ) {
                    library.goToPrevious()
                }

                navButton(
                    systemImage: "chevron.right",
                    tip: "下一个（→ / 空格）",
                    disabled: !library.canGoNext
                ) {
                    library.goToNext()
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)

            Text(library.positionText)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                library.presentOpenPanel()
            } label: {
                Label("打开", systemImage: "folder")
            }
            .quickTip("打开文件夹或文件（⌘O）")

            Button {
                library.reload()
            } label: {
                Label("重新载入", systemImage: "arrow.clockwise")
            }
            .disabled(library.folderURL == nil)
            .quickTip("重新载入文件夹（⌘R）")

            Button {
                library.showsFilmstrip.toggle()
            } label: {
                Label(
                    "胶片栏",
                    systemImage: library.showsFilmstrip ? "film.stack.fill" : "film.stack"
                )
            }
            .quickTip("显示或隐藏胶片栏（⇧⌘F）")

            Button {
                library.isSlideshow.toggle()
            } label: {
                Label(
                    library.isSlideshow ? "停止放映" : "幻灯片",
                    systemImage: library.isSlideshow ? "pause.circle.fill" : "play.circle"
                )
            }
            .tint(library.isSlideshow ? .accentColor : nil)
            .quickTip(library.isSlideshow ? "停止幻灯片放映（⇧⌘P）" : "开始幻灯片放映（⇧⌘P）")

            Toggle(isOn: inspectorBinding) {
                Label("元数据", systemImage: "info.circle")
            }
            .quickTip("显示或隐藏元数据面板（⌘I）")
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { library.showsInspector },
            set: { library.showsInspector = $0 }
        )
    }

    /// 工具栏里的圆形翻页钮：玻璃圆底，和预览区悬浮箭头呼应。
    /// 禁用时变灰（plain 样式不会自动变灰，所以手动处理）。
    private func navButton(
        systemImage: String,
        tip: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(disabled ? .tertiary : .primary)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: Circle())
                .opacity(disabled ? 0.45 : 1)
                .contentShape(Circle())
        }
        .disabled(disabled)
        .quickTip(tip)
    }

    // MARK: - 幻灯片放映

    /// 打开后循环步进：图片停留约 3 秒，视频给 8 秒看完再切。
    private func runSlideshow() async {
        guard library.isSlideshow else { return }
        while library.isSlideshow, !Task.isCancelled {
            let delay: UInt64 = library.currentItem?.kind == .video
                ? 8_000_000_000
                : 2_800_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard library.isSlideshow, !Task.isCancelled else { break }
            withAnimation(.easeOut(duration: 0.22)) {
                library.advanceForSlideshow()
            }
        }
    }

    // MARK: - 打开路径

    /// 把从 Finder 拖进来的文件 / 文件夹直接打开。
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    library.open(url)
                }
            }
        }
        return accepted
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

/// 底部状态栏：当前文件徽标、所在文件夹、第几个 / 共几个。
struct StatusBarView: View {
    @EnvironmentObject private var library: MediaLibrary

    var body: some View {
        HStack(spacing: 10) {
            if let item = library.currentItem {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill((item.kind == .video ? Color.purple : Color.blue).gradient)
                        .frame(width: 22, height: 22)
                    Image(systemName: item.kind.systemImageName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(item.fileName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                if library.isSlideshow {
                    Label("放映中", systemImage: "play.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            } else {
                Text("就绪")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if let folderURL = library.folderURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                } label: {
                    Label(folderURL.lastPathComponent, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("在访达中显示文件夹：\(folderURL.path)")
            }

            Text(library.positionText)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

import AppKit
import SwiftUI

/// 右侧元数据面板：顶部文件卡 + 分组信息卡。
struct MetadataInspectorView: View {
    let item: MediaItem?
    let sections: [MetadataSection]
    let state: MetadataLoadState

    var body: some View {
        Group {
            if item == nil {
                ContentUnavailableView("没有选中的文件", systemImage: "photo.on.rectangle")
            } else if sections.isEmpty, case .loading = state {
                loadingPlaceholder
            } else if sections.isEmpty {
                ContentUnavailableView(
                    "没有元数据",
                    systemImage: "questionmark.circle",
                    description: Text(emptyMessage)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        fileCard
                        ForEach(orderedSections) { section in
                            sectionCard(section)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) { header }
    }

    private var emptyMessage: String {
        if case .failed(let message) = state { return message }
        return "这个文件里没有可以显示的元数据。"
    }

    /// 分组排序：「文件」这一组信息量最低，沉到底部，其他分组保持原顺序。
    private var orderedSections: [MetadataSection] {
        let (file, rest) = sections.reduce(into: ([MetadataSection](), [MetadataSection]())) { acc, section in
            if section.title == "文件" {
                acc.0.append(section)
            } else {
                acc.1.append(section)
            }
        }
        return rest + file
    }

    // MARK: - 顶部条

    private var header: some View {
        HStack(spacing: 8) {
            Text("元数据")
                .font(.headline)
            Spacer()
            if case .loading = state {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("\(sections.reduce(0) { $0 + $1.fields.count }) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - 文件卡

    @ViewBuilder
    private var fileCard: some View {
        if let item {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(kindTint.gradient)
                            .frame(width: 40, height: 40)
                        Image(systemName: item.kind.systemImageName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.fileName)
                            .font(.headline)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack(spacing: 6) {
                            Text(item.kind.displayName)
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            if let sizeText = fileSizeText(for: item.url) {
                                Text(sizeText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button {
                        copyAll()
                    } label: {
                        Label("拷贝", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        revealInFinder()
                    } label: {
                        Label("访达", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sections.isEmpty)
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
    }

    private var kindTint: Color {
        item?.kind == .video ? .purple : .blue
    }

    // MARK: - 分组卡

    private func sectionCard(_ section: MetadataSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(sectionTint(for: section).opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: section.systemImageName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(sectionTint(for: section))
                }
                Text(section.title)
                    .font(.headline)
                Spacer()
                Text("\(section.fields.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().padding(.leading, 12)

            ForEach(Array(section.fields.enumerated()), id: \.element.id) { index, field in
                fieldRow(field)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                if index < section.fields.count - 1 {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .textSelection(.enabled)
        .contextMenu {
            Button("拷贝本组") {
                copySection(section)
            }
        }
    }

    private func fieldRow(_ field: MetadataField) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .layoutPriority(1)
            Text(field.value)
                .font(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            Button("拷贝「\(field.label)」") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(field.label): \(field.value)", forType: .string)
            }
        }
    }

    // MARK: - 加载骨架

    private var loadingPlaceholder: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                            .frame(width: 120, height: 16)
                        ForEach(0 ..< 4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.quaternary)
                                .frame(height: 13)
                        }
                    }
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    }
                    .redacted(reason: .placeholder)
                }
                Text("正在读取元数据…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(12)
        }
    }

    // MARK: - 小工具

    private func sectionTint(for section: MetadataSection) -> Color {
        let title = section.title
        if title.contains("文件") || title.contains("容器") { return .blue }
        if title.contains("图像") || title.contains("视频") || title.contains("尺寸") { return .purple }
        if title.contains("设备") || title.contains("镜头") { return .green }
        if title.contains("参数") || title.contains("曝光") || title.contains("拍摄") { return .orange }
        if title.contains("GPS") || title.contains("位置") { return .red }
        if title.contains("音频") { return .pink }
        return .gray
    }

    private func fileSizeText(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func copyAll() {
        var lines: [String] = []
        if let item {
            lines.append(item.fileName)
            lines.append("")
        }
        for section in sections {
            lines.append("[\(section.title)]")
            for field in section.fields {
                lines.append("\(field.label): \(field.value)")
            }
            lines.append("")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func copySection(_ section: MetadataSection) {
        let lines = ["[\(section.title)]"] + section.fields.map { "\($0.label): \($0.value)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func revealInFinder() {
        guard let item else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}

import AppKit
import SwiftUI

/// 右侧元数据面板。
struct MetadataInspectorView: View {
    let item: MediaItem?
    let sections: [MetadataSection]
    let state: MetadataLoadState

    var body: some View {
        Group {
            if item == nil {
                ContentUnavailableView("没有选中的文件", systemImage: "photo.on.rectangle")
            } else if sections.isEmpty, case .loading = state {
                ProgressView("正在读取元数据…")
            } else if sections.isEmpty {
                ContentUnavailableView(
                    "没有元数据",
                    systemImage: "questionmark.circle",
                    description: Text(emptyMessage)
                )
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.fields) { field in
                                row(field)
                            }
                        } header: {
                            Label(section.title, systemImage: section.systemImageName)
                        }
                    }
                }
                .listStyle(.inset)
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) { header }
    }

    private var emptyMessage: String {
        if case .failed(let message) = state { return message }
        return "这个文件里没有可以显示的元数据。"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item?.fileName ?? "元数据")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button {
                    copyAll()
                } label: {
                    Label("拷贝", systemImage: "doc.on.doc")
                }
                .help("把全部元数据拷贝成文本")

                Button {
                    revealInFinder()
                } label: {
                    Label("访达", systemImage: "folder")
                }
                .help("在访达中显示")

                Spacer()

                if case .loading = state {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(item == nil || sections.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ field: MetadataField) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(field.value)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
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

    private func revealInFinder() {
        guard let item else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
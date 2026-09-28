import SwiftUI

/// 还没有打开文件夹时的引导页。
struct EmptyStateView: View {
    @EnvironmentObject private var library: MediaLibrary

    let message: String?

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)
                    .shadow(color: .purple.opacity(0.35), radius: 20, y: 8)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("把文件夹拖进来，就能开始翻看")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(message ?? "选择一个包含图片或视频的文件夹，就能预览、播放，并用上一个 / 下一个翻看同文件夹里的其他媒体。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 10) {
                Button("打开文件夹…") {
                    library.presentOpenPanel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)

                Button("选择文件…") {
                    library.presentOpenPanel()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(spacing: 10) {
                tipCard(icon: "folder", title: "⌘O 打开", subtitle: "文件夹或单个文件")
                tipCard(icon: "arrow.left.arrow.right", title: "← → 翻页", subtitle: "空格播下一张")
                tipCard(icon: "play.circle", title: "幻灯片", subtitle: "自动循环播放")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor).opacity(0.6),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func tipCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 148)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}

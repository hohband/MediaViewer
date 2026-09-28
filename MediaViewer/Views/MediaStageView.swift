import AppKit
import SwiftUI

/// 预览区：暗色影院背景 + 悬浮翻页按钮 + 左右滑动切换。
///
/// 图片走缩放视图，视频走播放器；切换文件时做淡入 + 轻微缩放过渡。
struct MediaStageView: View {
    let item: MediaItem?
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            stageBackground

            if let item {
                switch item.kind {
                case .image:
                    ZoomableImageView(url: item.url)
                        .id(item.url)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                case .video:
                    VideoStageView(item: item)
                        .id(item.url)
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }

            // 悬浮翻页按钮：鼠标移入舞台才浮现，保持画面干净。
            if item != nil {
                HStack {
                    hoverArrow(
                        systemImage: "chevron.left",
                        help: "上一个（←）",
                        disabled: !canGoPrevious,
                        action: onPrevious
                    )
                    Spacer(minLength: 0)
                    hoverArrow(
                        systemImage: "chevron.right",
                        help: "下一个（→ / 空格）",
                        disabled: !canGoNext,
                        action: onNext
                    )
                }
                .padding(.horizontal, 14)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: isHovering)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.22), value: item?.url)
        .onHover { isHovering = $0 }
        .gesture(swipeGesture)
        .contextMenu {
            Button("上一个") { onPrevious() }.disabled(!canGoPrevious)
            Button("下一个") { onNext() }.disabled(!canGoNext)
            if let item {
                Divider()
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                Button("拷贝文件路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url.path, forType: .string)
                }
            }
        }
    }

    // MARK: - 背景

    /// 暗色渐变 + 四周暗角：图片和视频都更突出，翻页时也没有白闪。
    private var stageBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .underPageBackgroundColor),
                    Color.black.opacity(item?.kind == .video ? 1 : 0.82),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [.clear, .black.opacity(0.28)],
                center: .center,
                startRadius: 80,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 悬浮箭头

    private func hoverArrow(
        systemImage: String,
        help message: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(disabled ? .tertiary : .primary)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(message)
    }

    /// 横滑切换：水平位移为主、超过阈值就翻页，竖滑不干扰缩放滚动。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) * 1.4,
                      abs(horizontal) > 64
                else { return }
                if horizontal < 0 {
                    if canGoNext { onNext() }
                } else {
                    if canGoPrevious { onPrevious() }
                }
            }
    }
}

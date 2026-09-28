import SwiftUI

/// 快捷提示：悬停约 0.25 秒就弹出，比系统 tooltip 快得多，而且自己绘制、必定可见。
///
/// 背景：`.help()` 的弹出时机由系统控制（约 1 秒且不可调），
/// 在工具栏里还偶尔不显示；这里用 SwiftUI 状态驱动，时机完全可控。
struct QuickTipModifier: ViewModifier {
    let text: String

    @State private var visible = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if visible {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Color.black.opacity(0.82),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .offset(y: 32)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .onHover { hovering in
                pending?.cancel()
                pending = nil
                if hovering {
                    pending = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            withAnimation(.easeOut(duration: 0.12)) {
                                visible = true
                            }
                        }
                    }
                } else {
                    visible = false
                }
            }
            .onDisappear {
                pending?.cancel()
                pending = nil
                visible = false
            }
    }
}

extension View {
    /// 在目标下方弹出黑色快捷提示（含快捷键说明），替代 `.help()`。
    func quickTip(_ text: String) -> some View {
        modifier(QuickTipModifier(text: text))
    }
}

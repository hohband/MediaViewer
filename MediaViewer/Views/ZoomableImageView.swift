import AppKit
import SwiftUI

/// 图片预览：适应窗口、双指缩放、双击切换 100%、拖拽平移。
struct ZoomableImageView: View {
    let url: URL

    @State private var image: NSImage?
    @State private var failureMessage: String?
    @State private var scale: CGFloat = 1
    @State private var gestureBaseScale: CGFloat = 1

    private let minimumScale: CGFloat = 0.05
    private let maximumScale: CGFloat = 40
    private let zoomStep: CGFloat = 1.25

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    imageContent(image: image, viewport: proxy.size)
                } else if let failureMessage {
                    failureCard(message: failureMessage)
                } else {
                    loadingCard
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: url) { await loadImage() }
    }

    // MARK: - 内容

    private func imageContent(image: NSImage, viewport: CGSize) -> some View {
        let fitted = fittedSize(for: image, in: viewport)
        let isFitted = abs(scale - 1) < 0.01

        return ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: fitted.width * scale, height: fitted.height * scale)
                .frame(minWidth: viewport.width, minHeight: viewport.height)
                // 适应窗口时给图片加圆角 + 投影，像画框一样浮在暗色舞台上；
                // 放大后去掉装饰，方便检查像素。
                .clipShape(RoundedRectangle(cornerRadius: isFitted ? 8 : 0, style: .continuous))
                .shadow(color: .black.opacity(isFitted ? 0.5 : 0), radius: 28, y: 10)
        }
        .scrollIndicators(scale > 1.001 ? .automatic : .hidden)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    scale = clamp(gestureBaseScale * value.magnification)
                }
                .onEnded { _ in
                    gestureBaseScale = scale
                }
        )
        .onTapGesture(count: 2) {
            if abs(scale - 1) < 0.01 {
                setScale(actualSizeScale(for: image, viewport: viewport))
            } else {
                setScale(1)
            }
        }
        .overlay(alignment: .bottom) {
            controls(for: image, viewport: viewport)
        }
    }

    /// 底部悬浮缩放条：缩小 / 滑杆 / 放大 / 百分比 / 适应窗口 / 100%。
    private func controls(for image: NSImage, viewport: CGSize) -> some View {
        HStack(spacing: 10) {
            Button {
                setScale(scale / zoomStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("缩小（−）")
            .keyboardShortcut("-", modifiers: [])

            Slider(value: logScaleBinding, in: 0 ... 1)
                .frame(width: 110)
                .help("拖动缩放")

            Button {
                setScale(scale * zoomStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("放大（+）")
            .keyboardShortcut("=", modifiers: [])

            Text("\(Int(displayedPercent(for: image, viewport: viewport).rounded()))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 46)
                .help("相对原始像素的显示比例，双击图片可在适应窗口和 100% 间切换")

            Divider().frame(height: 14)

            Button("适应窗口") {
                setScale(1)
            }
            .help("缩放到适合窗口（0）")
            .keyboardShortcut("0", modifiers: [])

            Button("100%") {
                setScale(actualSizeScale(for: image, viewport: viewport))
            }
            .help("按原始像素显示（1）")
            .keyboardShortcut("1", modifiers: [])
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .padding(.bottom, 14)
    }

    /// 滑杆用对数刻度：小比例微调不跳变，大比例也能一把拉到。
    private var logScaleBinding: Binding<Double> {
        let minLog = log(minimumScale)
        let maxLog = log(maximumScale)
        return Binding(
            get: { (log(max(scale, minimumScale)) - minLog) / (maxLog - minLog) },
            set: { setScale(exp(minLog + $0 * (maxLog - minLog))) }
        )
    }

    private var loadingCard: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("正在载入图片…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func failureCard(message: String) -> some View {
        ContentUnavailableView(
            "无法显示图片",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding()
    }

    // MARK: - 缩放计算

    /// 图片按比例放进窗口后的显示尺寸（scale == 1 时就按这个尺寸画）。
    private func fittedSize(for image: NSImage, in viewport: CGSize) -> CGSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, viewport.width > 0, viewport.height > 0 else {
            return viewport
        }
        let ratio = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }

    /// 原始像素尺寸（Retina 图取真实像素，而不是 point）。
    private func pixelSize(for image: NSImage) -> CGSize {
        let largest = image.representations.max { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }
        if let largest, largest.pixelsWide > 0, largest.pixelsHigh > 0 {
            return CGSize(width: largest.pixelsWide, height: largest.pixelsHigh)
        }
        return image.size
    }

    /// 当前显示比例（相对原始像素，100% 表示一个像素对屏幕一个像素）。
    private func displayedPercent(for image: NSImage, viewport: CGSize) -> Double {
        let fitted = fittedSize(for: image, in: viewport)
        let pixels = pixelSize(for: image)
        guard fitted.width > 0, pixels.width > 0 else { return 100 }
        return Double(fitted.width * scale / pixels.width) * 100
    }

    private func actualSizeScale(for image: NSImage, viewport: CGSize) -> CGFloat {
        let fitted = fittedSize(for: image, in: viewport)
        let pixels = pixelSize(for: image)
        guard fitted.width > 0, pixels.width > 0 else { return 1 }
        return clamp(pixels.width / fitted.width)
    }

    private func setScale(_ newValue: CGFloat) {
        let clamped = clamp(newValue)
        scale = clamped
        gestureBaseScale = clamped
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, value))
    }

    // MARK: - 载入

    private func loadImage() async {
        image = nil
        failureMessage = nil
        setScale(1)

        let url = url
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value

        guard let data, let loaded = NSImage(data: data) else {
            failureMessage = "无法读取这个文件，可能是不受支持的图片格式。"
            return
        }
        image = loaded
    }
}

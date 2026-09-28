import AppKit
import AVFoundation
import SwiftUI

/// 底部胶片栏：横向缩略图，点一下就跳过去，自动跟随当前选中。
struct FilmstripView: View {
    let items: [MediaItem]
    let currentIndex: Int?
    let onSelect: (Int) -> Void

    @State private var isHovering = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(items.indices, id: \.self) { index in
                        FilmstripCell(
                            item: items[index],
                            selected: index == currentIndex
                        )
                        .id(index)
                        .onTapGesture { onSelect(index) }
                        .help(items[index].fileName)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: currentIndex) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onAppear {
                if let currentIndex {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
        .frame(height: 92)
        .background(.bar)
        .onHover { isHovering = $0 }
    }
}

/// 胶片栏里的一格缩略图。
private struct FilmstripCell: View {
    let item: MediaItem
    let selected: Bool

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
                .frame(width: 112, height: 70)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 112, height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: item.kind.systemImageName)
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            selected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: selected ? 2.5 : 1
                        )
                }
                .shadow(
                    color: selected ? Color.accentColor.opacity(0.35) : .black.opacity(0.18),
                    radius: selected ? 8 : 3,
                    y: 2
                )
                .opacity(selected ? 1 : (isHovering ? 0.95 : 0.72))
                .scaleEffect(selected ? 1.03 : (isHovering ? 1.01 : 1))
                .animation(.easeOut(duration: 0.18), value: selected)
                .animation(.easeOut(duration: 0.15), value: isHovering)

            if item.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(5)
            }
        }
        .onHover { isHovering = $0 }
        .task(id: item.url) {
            thumbnail = await ThumbnailCache.shared.thumbnail(for: item)
        }
    }
}

/// 缩略图缓存：图片走 ImageIO  embedded thumbnail，视频截首帧。
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    func thumbnail(for item: MediaItem) async -> NSImage? {
        let key = item.url as NSURL
        if let cached = cache.object(forKey: key) { return cached }

        let url = item.url
        let kind = item.kind
        let image: NSImage? = await Task.detached(priority: .utility) {
            switch kind {
            case .image:
                return Self.imageThumbnail(for: url)
            case .video:
                return Self.videoThumbnail(for: url)
            }
        }.value

        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    private static func imageThumbnail(for url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private static func videoThumbnail(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        } catch {
            return nil
        }
    }
}

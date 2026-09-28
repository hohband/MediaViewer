import AppKit
import SwiftUI

/// 预览区：图片走缩放视图，视频走播放器。
struct MediaStageView: View {
    let item: MediaItem?

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            if let item {
                switch item.kind {
                case .image:
                    ZoomableImageView(url: item.url)
                        .id(item.url)
                case .video:
                    VideoStageView(item: item)
                        .id(item.url)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
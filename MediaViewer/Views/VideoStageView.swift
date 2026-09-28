import AVFoundation
import AVKit
import SwiftUI

/// 视频播放：标准播放器控件，切文件时销毁播放器。
struct VideoStageView: View {
    let item: MediaItem

    @State private var player: AVPlayer?
    @State private var failureMessage: String?

    var body: some View {
        ZStack {
            Color.black

            if let player {
                PlayerView(player: player)
            } else if let failureMessage {
                ContentUnavailableView(
                    "无法播放视频",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failureMessage)
                )
                .background(.regularMaterial)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.url) { await preparePlayer() }
        .onDisappear { teardown() }
    }

    private func preparePlayer() async {
        teardown()

        let asset = AVURLAsset(url: item.url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                failureMessage = "系统解码器不支持这个文件（容器或编码不受支持）。"
                return
            }
            guard !Task.isCancelled else { return }

            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            newPlayer.actionAtItemEnd = .pause
            player = newPlayer

            // 停在开头并渲染首帧，这样打开视频就能看到画面而不是一片黑。
            await newPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        } catch {
            failureMessage = error.localizedDescription
        }
    }

    private func teardown() {
        player?.pause()
        player = nil
    }
}

/// 用 AppKit 的 `AVPlayerView` 包一层。
///
/// 这里没有用 SwiftUI 自带的 `VideoPlayer`：它只链接 `_AVKit_SwiftUI` 这个 overlay，
/// 在部分系统上运行时找不到 AVKit 的 `AVPlayerView` 类，会直接
/// `failed to demangle superclass of VideoPlayerView` 并 abort。
/// 自己引用 `AVPlayerView` 既能保证 AVKit 被真正链接，也能控制控件样式。
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFrameSteppingButtons = true
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
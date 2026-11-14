import AVFoundation
import AVKit
import SwiftUI

/// 视频播放：标准播放器控件，切文件时销毁播放器。
struct VideoStageView: View {
    let item: MediaItem

    @State private var player: AVPlayer?
    @State private var failureMessage: String?
    @State private var isConverting = false

    var body: some View {
        ZStack {
            Color.black

            if let player {
                PlayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 28, y: 10)
                    .padding(1)
            } else if let failureMessage {
                ContentUnavailableView(
                    "无法播放视频",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failureMessage)
                )
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding()
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text(isConverting ? "正在转换兼容格式…" : "正在准备视频…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if isConverting {
                        Text("首次打开需要等待，转换结果会缓存；原文件不会修改。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.url) { await preparePlayer() }
        .onDisappear { teardown() }
    }

    private func preparePlayer() async {
        teardown()
        failureMessage = nil
        isConverting = false

        do {
            let sourceAsset = AVURLAsset(url: item.url)
            // 部分 DV 文件只能解出首帧，AVPlayer 的播放指针不会前进。
            let requiresTranscoding = item.url.pathExtension.lowercased() == "dv"
            let systemPlayable = (try? await sourceAsset.load(.isPlayable)) ?? false
            let isNativePlayable = !requiresTranscoding && systemPlayable
            let playbackURL: URL
            if isNativePlayable {
                playbackURL = item.url
            } else {
                guard !Task.isCancelled else { return }
                isConverting = true
                playbackURL = try await VideoCompatibilityService.shared.compatibleVideoURL(for: item.url)
            }
            guard !Task.isCancelled else { return }

            let asset = AVURLAsset(url: playbackURL)
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                failureMessage = "转换后的视频仍无法由系统播放器解码。"
                return
            }
            guard !Task.isCancelled else { return }

            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            newPlayer.actionAtItemEnd = .pause
            player = newPlayer

            // 停在开头并渲染首帧，这样打开视频就能看到画面而不是一片黑。
            await newPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        } catch is CancellationError {
            return
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

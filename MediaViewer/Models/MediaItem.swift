import Foundation

/// 媒体文件的类型。
enum MediaKind: String, Hashable, Sendable {
    case image
    case video

    var displayName: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        }
    }

    var systemImageName: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        }
    }
}

/// 支持的文件扩展名。
///
/// 只列出当前解码链路（图片用 ImageIO，视频用 AVFoundation）确实能处理的格式，
/// 避免把无法预览的文件混进导航列表。要扩展格式，改这两个集合即可。
enum MediaFormats {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "heic", "heif", "tif", "tiff",
        "bmp", "webp", "avif", "jp2", "dng", "cr2", "cr3", "nef", "arw",
        "orf", "raf", "rw2", "srw", "pef",
    ]

    static let videoExtensions: Set<String> = [
        "mov", "qt", "mp4", "m4v", "avi", "mpg", "mpeg", "mpe", "m2v",
        "ts", "m2ts", "mts", "3gp", "3g2", "dv",
    ]

    static func kind(forFileExtension fileExtension: String) -> MediaKind? {
        let lowered = fileExtension.lowercased()
        if imageExtensions.contains(lowered) { return .image }
        if videoExtensions.contains(lowered) { return .video }
        return nil
    }

    static func kind(for url: URL) -> MediaKind? {
        kind(forFileExtension: url.pathExtension)
    }
}

/// 列表里的一个媒体文件。
struct MediaItem: Identifiable, Hashable, Sendable {
    let url: URL
    let kind: MediaKind

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
}
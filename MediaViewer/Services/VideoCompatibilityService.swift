import CryptoKit
import Foundation

actor VideoCompatibilityService {
    static let shared = VideoCompatibilityService()

    private let cacheVersion = 1

    func compatibleVideoURL(for sourceURL: URL) async throws -> URL {
        guard let ffmpegURL = Self.findFFmpeg() else {
            throw VideoCompatibilityError.ffmpegNotFound
        }

        let fileManager = FileManager.default
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = [
            String(cacheVersion),
            sourceURL.standardizedFileURL.path,
            String(values.fileSize ?? 0),
            String(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        guard let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw VideoCompatibilityError.cacheUnavailable
        }
        let cacheDirectory = cachesDirectory
            .appendingPathComponent("MediaViewer", isDirectory: true)
            .appendingPathComponent("Compatible Videos", isDirectory: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let cachedURL = cacheDirectory.appendingPathComponent(digest).appendingPathExtension("mp4")
        if let size = try? cachedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            return cachedURL
        }

        let temporaryURL = cacheDirectory
            .appendingPathComponent("\(digest)-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let videoStreamIndex = try Self.mainVideoStreamIndex(for: sourceURL, ffmpegURL: ffmpegURL)
        do {
            try await Self.transcode(
                sourceURL: sourceURL,
                destinationURL: temporaryURL,
                ffmpegURL: ffmpegURL,
                videoStreamIndex: videoStreamIndex
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard !Task.isCancelled else { throw CancellationError() }
        guard let size = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw VideoCompatibilityError.conversionFailed("转换后没有生成有效文件。")
        }

        if fileManager.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        try fileManager.moveItem(at: temporaryURL, to: cachedURL)
        return cachedURL
    }

    private static func findFFmpeg() -> URL? {
        let fileManager = FileManager.default
        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + pathDirectories
        for directory in directories {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("ffmpeg")
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func mainVideoStreamIndex(for sourceURL: URL, ffmpegURL: URL) throws -> Int? {
        let ffprobeURL = ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else { return nil }

        let streams = try probeStreams(sourceURL: sourceURL, ffprobeURL: ffprobeURL, countPackets: false)
        let candidates = streams.filter { $0.codecType == "video" && $0.disposition?.attachedPic != 1 }
        guard candidates.count > 1 else { return candidates.first?.index }

        let countedStreams = try probeStreams(sourceURL: sourceURL, ffprobeURL: ffprobeURL, countPackets: true)
        let countedCandidates = countedStreams.filter { $0.codecType == "video" && $0.disposition?.attachedPic != 1 }
        guard countedCandidates.contains(where: { $0.packetCount != nil }) else { return nil }
        return countedCandidates.max { lhs, rhs in
            let lhsPackets = Double(lhs.packetCount ?? "") ?? 0
            let rhsPackets = Double(rhs.packetCount ?? "") ?? 0
            if lhsPackets != rhsPackets { return lhsPackets < rhsPackets }
            let lhsDuration = Double(lhs.duration ?? "") ?? 0
            let rhsDuration = Double(rhs.duration ?? "") ?? 0
            return lhsDuration < rhsDuration
        }?.index
    }

    private static func probeStreams(sourceURL: URL, ffprobeURL: URL, countPackets: Bool) throws -> [FFProbeStream] {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = ffprobeURL
        var arguments = ["-v", "error"]
        if countPackets { arguments.append("-count_packets") }
        arguments += [
            "-show_entries", "stream=index,codec_type,duration,nb_read_packets:stream_disposition=attached_pic",
            "-of", "json",
            sourceURL.path,
        ]
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw VideoCompatibilityError.conversionFailed(detail.isEmpty ? "ffprobe 无法读取视频流。" : detail)
        }
        return try JSONDecoder().decode(FFProbeResult.self, from: outputData).streams
    }

    private static func transcode(
        sourceURL: URL,
        destinationURL: URL,
        ffmpegURL: URL,
        videoStreamIndex: Int?
    ) async throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = ffmpegURL
        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
        ]
        if let videoStreamIndex {
            arguments += ["-map", "0:\(videoStreamIndex)", "-map", "0:a:0?"]
        }
        arguments += [
            "-sn",
            "-dn",
            "-vf", "scale='min(iw,3840)':'min(ih,2160)':force_original_aspect_ratio=decrease:force_divisible_by=2",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "19",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            destinationURL.path,
        ]
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { finishedProcess in
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let detail = String(decoding: errorData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if finishedProcess.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: VideoCompatibilityError.conversionFailed(
                            detail.isEmpty ? "FFmpeg 退出码 \(finishedProcess.terminationStatus)。" : detail
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: VideoCompatibilityError.conversionFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

private struct FFProbeResult: Decodable {
    let streams: [FFProbeStream]
}

private struct FFProbeStream: Decodable {
    let index: Int
    let codecType: String
    let duration: String?
    let packetCount: String?
    let disposition: FFProbeDisposition?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case duration
        case packetCount = "nb_read_packets"
        case disposition
    }
}

private struct FFProbeDisposition: Decodable {
    let attachedPic: Int?

    enum CodingKeys: String, CodingKey {
        case attachedPic = "attached_pic"
    }
}

enum VideoCompatibilityError: LocalizedError {
    case ffmpegNotFound
    case cacheUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "这个视频需要 FFmpeg 转换后才能播放。请先安装 FFmpeg（brew install ffmpeg），再重新打开。"
        case .cacheUnavailable:
            return "无法创建兼容视频缓存目录。"
        case .conversionFailed(let detail):
            return "FFmpeg 无法转换这个视频：\(detail)"
        }
    }
}

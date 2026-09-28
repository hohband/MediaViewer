import Foundation

/// 命令行探针：直接调用 App 里的同一份扫描 / 元数据实现，做端到端验证。
///
/// 用法：
///   metadata-probe <文件夹>            打印扫描结果与每个文件的元数据
///   metadata-probe <文件夹> --check    额外校验样例文件夹的固定契约（自检 / CI）
@main
enum MetadataProbe {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let shouldCheck = arguments.contains("--check")
        arguments.removeAll { $0 == "--check" }

        guard let path = arguments.first else {
            FileHandle.standardError.write(Data("用法: metadata-probe <文件夹> [--check]\n".utf8))
            exit(2)
        }

        let folder = URL(fileURLWithPath: path)
        let items: [MediaItem]
        do {
            items = try MediaScanner.scan(folder: folder)
        } catch {
            FileHandle.standardError.write(Data("扫描失败: \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        print("文件夹: \(folder.path)")
        print("媒体文件: \(items.count) 个")
        for (index, item) in items.enumerated() {
            print("  [\(index)] \(item.kind.displayName)  \(item.fileName)")
        }

        var metadata: [String: [MetadataSection]] = [:]
        for item in items {
            let sections = await MetadataReader.sections(for: item)
            metadata[item.fileName] = sections

            print("\n=== \(item.fileName) ===")
            for section in sections {
                print("[\(section.title)]")
                for field in section.fields {
                    print("  \(field.label): \(field.value)")
                }
            }
        }

        guard shouldCheck else { return }

        let failures = checkContract(items: items, metadata: metadata)
        if failures.isEmpty {
            print("\n契约校验：全部通过 ✅")
            exit(0)
        }
        print("\n契约校验：\(failures.count) 项失败 ❌")
        for failure in failures {
            print("  ✗ \(failure)")
        }
        exit(1)
    }

    /// 样例文件（scripts/make-samples.sh 生成）的读取契约。
    private static func checkContract(items: [MediaItem], metadata: [String: [MetadataSection]]) -> [String] {
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append(message()) }
        }

        func value(_ fileName: String, _ sectionTitle: String, _ label: String) -> String? {
            metadata[fileName]?
                .first { $0.title == sectionTitle }?
                .fields.first { $0.label == label }?
                .value
        }

        // 1. 扫描与自然排序：img-2 必须排在 img-10 之前（纯字典序会反过来）
        let names = items.map(\.fileName)
        expect(
            names == ["img-1.jpg", "img-2.jpg", "img-10.png", "vid-1.mp4", "vid-2.mov"],
            "文件列表或排序不符合预期：\(names)"
        )
        expect(!names.contains("notes.txt"), "非媒体文件被错误地列进了列表")

        // 2. 图片基础信息 + EXIF
        expect(value("img-1.jpg", "图像", "尺寸") == "800 × 600 像素", "img-1.jpg 尺寸读取失败：\(value("img-1.jpg", "图像", "尺寸") ?? "nil")")
        expect(value("img-1.jpg", "拍摄设备", "制造商") == "Probe Cam", "img-1.jpg 制造商读取失败")
        expect(value("img-1.jpg", "拍摄设备", "机型") == "Probe Cam X", "img-1.jpg 机型读取失败")
        expect(value("img-1.jpg", "拍摄设备", "镜头") == "Probe Lens 50mm f/1.8", "img-1.jpg 镜头读取失败")
        expect(value("img-1.jpg", "拍摄设备", "软件") == "MediaViewer Probe", "img-1.jpg 软件读取失败")
        expect(value("img-1.jpg", "拍摄参数", "拍摄时间") == "2024:05:06 07:08:09", "img-1.jpg 拍摄时间读取失败")
        expect(value("img-1.jpg", "拍摄参数", "光圈") == "f/1.8", "img-1.jpg 光圈读取失败：\(value("img-1.jpg", "拍摄参数", "光圈") ?? "nil")")
        expect(value("img-1.jpg", "拍摄参数", "快门") == "1/250 秒", "img-1.jpg 快门读取失败：\(value("img-1.jpg", "拍摄参数", "快门") ?? "nil")")
        expect(value("img-1.jpg", "拍摄参数", "ISO") == "200", "img-1.jpg ISO 读取失败：\(value("img-1.jpg", "拍摄参数", "ISO") ?? "nil")")
        expect(value("img-1.jpg", "拍摄参数", "焦距") == "50 mm", "img-1.jpg 焦距读取失败：\(value("img-1.jpg", "拍摄参数", "焦距") ?? "nil")")
        expect(value("img-1.jpg", "文件", "文件大小") != nil, "img-1.jpg 缺少文件大小")

        // 3. GPS：37.7749 / -122.4194
        let latitude = value("img-2.jpg", "位置", "纬度")
        expect(latitude?.hasPrefix("37.774") == true, "img-2.jpg 纬度读取失败：\(latitude ?? "nil")")
        let longitude = value("img-2.jpg", "位置", "经度")
        expect(longitude?.hasPrefix("-122.41") == true, "img-2.jpg 经度读取失败：\(longitude ?? "nil")")
        let altitude = value("img-2.jpg", "位置", "海拔")
        expect(altitude?.hasPrefix("12.5") == true, "img-2.jpg 海拔读取失败：\(altitude ?? "nil")")

        // 4. 视频
        expect(value("vid-1.mp4", "视频", "分辨率") == "640 × 480 像素", "vid-1.mp4 分辨率读取失败：\(value("vid-1.mp4", "视频", "分辨率") ?? "nil")")
        let duration = value("vid-1.mp4", "视频", "时长")
        expect(duration?.hasPrefix("0:03") == true, "vid-1.mp4 时长读取失败：\(duration ?? "nil")")
        let videoCodec = value("vid-1.mp4", "视频轨", "编码")
        expect(videoCodec?.contains("H.264") == true, "vid-1.mp4 视频编码读取失败：\(videoCodec ?? "nil")")
        let audioCodec = value("vid-1.mp4", "音频轨", "编码")
        expect(audioCodec?.contains("AAC") == true, "vid-1.mp4 音频编码读取失败：\(audioCodec ?? "nil")")
        expect(value("vid-1.mp4", "元数据", "标题") == "Probe Video", "vid-1.mp4 标题读取失败：\(value("vid-1.mp4", "元数据", "标题") ?? "nil")")
        expect(value("vid-2.mov", "视频", "分辨率") == "320 × 240 像素", "vid-2.mov 分辨率读取失败：\(value("vid-2.mov", "视频", "分辨率") ?? "nil")")

        return failures
    }
}
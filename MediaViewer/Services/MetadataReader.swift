import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 读取媒体文件的元数据，产出可以直接渲染的分组字段。
///
/// - 图片：ImageIO（尺寸 / 色彩 / EXIF / GPS / TIFF / IPTC / PNG）
/// - 视频：AVFoundation（时长、视频轨、音频轨、容器里的元数据）
///
/// 这一层不依赖 UI，命令行探针会直接调用同一份实现做验证。
enum MetadataReader {

    /// 读取一个媒体文件的全部元数据。
    static func sections(for item: MediaItem) async -> [MetadataSection] {
        var sections: [MetadataSection] = [fileSection(for: item)]
        switch item.kind {
        case .image:
            sections.append(contentsOf: imageSections(for: item.url))
        case .video:
            sections.append(contentsOf: await videoSections(for: item.url))
        }
        return sections.filter { !$0.fields.isEmpty }
    }

    // MARK: - 文件信息

    private static func fileSection(for item: MediaItem) -> MetadataSection {
        let url = item.url
        var fields: [MetadataField] = [
            MetadataField("文件名", item.fileName),
            MetadataField("类型", "\(item.kind.displayName) · \(typeDescription(for: url))"),
        ]

        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .typeIdentifierKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            if let size = values.fileSize {
                fields.append(MetadataField("文件大小", MetadataFormat.bytes(Int64(size))))
            }
            if let created = values.creationDate {
                fields.append(MetadataField("创建时间", MetadataFormat.date(created)))
            }
            if let modified = values.contentModificationDate {
                fields.append(MetadataField("修改时间", MetadataFormat.date(modified)))
            }
            if let identifier = values.typeIdentifier {
                fields.append(MetadataField("UTI", identifier))
            }
        }

        fields.append(MetadataField("文件夹", url.deletingLastPathComponent().path))
        fields.append(MetadataField("完整路径", url.path))

        return MetadataSection(title: "文件", systemImageName: "doc", fields: fields)
    }

    private static func typeDescription(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let description = type.localizedDescription {
            return description
        }
        let fileExtension = url.pathExtension.uppercased()
        return fileExtension.isEmpty ? "未知格式" : fileExtension
    }

    // MARK: - 图片

    private static func imageSections(for url: URL) -> [MetadataSection] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [
                MetadataSection(
                    title: "图片",
                    systemImageName: "exclamationmark.triangle",
                    fields: [MetadataField("无法读取", "这个文件不是可以解析的图片格式。")]
                )
            ]
        }

        let tiff = dictionary(properties, kCGImagePropertyTIFFDictionary)
        let exif = dictionary(properties, kCGImagePropertyExifDictionary)

        var sections: [MetadataSection] = []
        var handledExifKeys: Set<String> = []

        if let section = imageBasicsSection(properties: properties, source: source) { sections.append(section) }
        if let section = cameraSection(tiff: tiff, exif: exif, handledExifKeys: &handledExifKeys) { sections.append(section) }
        if let section = captureSection(exif: exif, handledExifKeys: &handledExifKeys) { sections.append(section) }
        if let section = gpsSection(properties: properties) { sections.append(section) }
        sections.append(contentsOf: textSections(properties: properties))
        if let section = extraExifSection(exif: exif, handledExifKeys: handledExifKeys) { sections.append(section) }

        return sections
    }

    private static func imageBasicsSection(properties: [CFString: Any], source: CGImageSource) -> MetadataSection? {
        var fields: [MetadataField] = []

        let pixelWidth = integer(properties, kCGImagePropertyPixelWidth)
        let pixelHeight = integer(properties, kCGImagePropertyPixelHeight)
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            fields.append(MetadataField("尺寸", "\(pixelWidth) × \(pixelHeight) 像素"))
            fields.append(MetadataField("总像素", String(format: "%.1f MP", Double(pixelWidth * pixelHeight) / 1_000_000)))
            fields.append(MetadataField("宽高比", aspectRatioDescription(width: pixelWidth, height: pixelHeight)))
        }
        if let depth = integer(properties, kCGImagePropertyDepth) {
            fields.append(MetadataField("位深", "\(depth) 位/通道"))
        }
        if let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue {
            fields.append(MetadataField("透明通道", hasAlpha ? "有" : "无"))
        }
        append(&fields, "色彩模型", text(properties, kCGImagePropertyColorModel))
        append(&fields, "颜色配置文件", text(properties, kCGImagePropertyProfileName))
        if let orientation = integer(properties, kCGImagePropertyOrientation), orientation != 1 {
            fields.append(MetadataField("方向", orientationDescription(orientation)))
        }
        if let dpiWidth = number(properties, kCGImagePropertyDPIWidth), dpiWidth > 0 {
            if let dpiHeight = number(properties, kCGImagePropertyDPIHeight), abs(dpiHeight - dpiWidth) > 0.01 {
                fields.append(MetadataField("分辨率", "\(MetadataFormat.integer(dpiWidth)) × \(MetadataFormat.integer(dpiHeight)) DPI"))
            } else {
                fields.append(MetadataField("分辨率", "\(MetadataFormat.integer(dpiWidth)) DPI"))
            }
        }
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            fields.append(MetadataField("帧数", "\(frameCount) 帧（动图）"))
        }

        return fields.isEmpty ? nil : MetadataSection(title: "图像", systemImageName: "photo", fields: fields)
    }

    private static func cameraSection(
        tiff: [CFString: Any],
        exif: [CFString: Any],
        handledExifKeys: inout Set<String>
    ) -> MetadataSection? {
        var fields: [MetadataField] = []
        append(&fields, "制造商", text(tiff, kCGImagePropertyTIFFMake))
        append(&fields, "机型", text(tiff, kCGImagePropertyTIFFModel))
        append(&fields, "镜头", firstText(text(exif, kCGImagePropertyExifLensModel), text(exif, kCGImagePropertyExifLensMake)))
        append(&fields, "软件", text(tiff, kCGImagePropertyTIFFSoftware))
        append(&fields, "作者", text(tiff, kCGImagePropertyTIFFArtist))
        append(&fields, "版权", text(tiff, kCGImagePropertyTIFFCopyright))
        append(&fields, "主机", text(tiff, kCGImagePropertyTIFFHostComputer))

        mark(&handledExifKeys, kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake)

        return fields.isEmpty ? nil : MetadataSection(title: "拍摄设备", systemImageName: "camera", fields: fields)
    }

    private static func captureSection(
        exif: [CFString: Any],
        handledExifKeys: inout Set<String>
    ) -> MetadataSection? {
        var fields: [MetadataField] = []

        let dateTimeOriginal = firstText(
            text(exif, kCGImagePropertyExifDateTimeOriginal),
            text(exif, kCGImagePropertyExifDateTimeDigitized)
        )
        append(&fields, "拍摄时间", dateTimeOriginal)
        if let fNumber = number(exif, kCGImagePropertyExifFNumber) {
            fields.append(MetadataField("光圈", String(format: "f/%.1f", fNumber)))
        }
        if let exposureTime = number(exif, kCGImagePropertyExifExposureTime) {
            fields.append(MetadataField("快门", MetadataFormat.shutterSpeed(exposureTime)))
        }
        if let iso = firstNumber(exif, kCGImagePropertyExifISOSpeedRatings) {
            fields.append(MetadataField("ISO", MetadataFormat.integer(iso)))
        }
        if let focalLength = number(exif, kCGImagePropertyExifFocalLength) {
            fields.append(MetadataField("焦距", "\(MetadataFormat.integer(focalLength)) mm"))
        }
        if let equivalent = number(exif, kCGImagePropertyExifFocalLenIn35mmFilm) {
            fields.append(MetadataField("35mm 等效焦距", "\(MetadataFormat.integer(equivalent)) mm"))
        }
        if let bias = number(exif, kCGImagePropertyExifExposureBiasValue) {
            fields.append(MetadataField("曝光补偿", String(format: "%+.1f EV", bias)))
        }
        if let program = integer(exif, kCGImagePropertyExifExposureProgram) {
            fields.append(MetadataField("曝光程序", exposureProgramDescription(program)))
        }
        if let mode = integer(exif, kCGImagePropertyExifExposureMode) {
            fields.append(MetadataField("曝光模式", exposureModeDescription(mode)))
        }
        if let metering = integer(exif, kCGImagePropertyExifMeteringMode) {
            fields.append(MetadataField("测光模式", meteringModeDescription(metering)))
        }
        if let flash = integer(exif, kCGImagePropertyExifFlash) {
            fields.append(MetadataField("闪光灯", flashDescription(flash)))
        }
        if let whiteBalance = integer(exif, kCGImagePropertyExifWhiteBalance) {
            fields.append(MetadataField("白平衡", whiteBalance == 1 ? "手动" : "自动"))
        }
        if let scene = integer(exif, kCGImagePropertyExifSceneCaptureType) {
            fields.append(MetadataField("场景类型", sceneCaptureTypeDescription(scene)))
        }
        if let colorSpace = integer(exif, kCGImagePropertyExifColorSpace) {
            fields.append(MetadataField("色彩空间", colorSpace == 1 ? "sRGB" : (colorSpace == 65_535 ? "未校准" : "\(colorSpace)")))
        }
        if let version = exif[kCGImagePropertyExifVersion] as? Data, let versionText = String(data: version, encoding: .ascii) {
            fields.append(MetadataField("Exif 版本", versionText))
        }
        if let pixelWidth = integer(exif, kCGImagePropertyExifPixelXDimension),
           let pixelHeight = integer(exif, kCGImagePropertyExifPixelYDimension) {
            fields.append(MetadataField("Exif 尺寸", "\(pixelWidth) × \(pixelHeight) 像素"))
        }

        mark(
            &handledExifKeys,
            kCGImagePropertyExifDateTimeOriginal,
            kCGImagePropertyExifDateTimeDigitized,
            kCGImagePropertyExifFNumber,
            kCGImagePropertyExifExposureTime,
            kCGImagePropertyExifISOSpeedRatings,
            kCGImagePropertyExifFocalLength,
            kCGImagePropertyExifFocalLenIn35mmFilm,
            kCGImagePropertyExifExposureBiasValue,
            kCGImagePropertyExifExposureProgram,
            kCGImagePropertyExifExposureMode,
            kCGImagePropertyExifMeteringMode,
            kCGImagePropertyExifFlash,
            kCGImagePropertyExifWhiteBalance,
            kCGImagePropertyExifSceneCaptureType,
            kCGImagePropertyExifColorSpace,
            kCGImagePropertyExifVersion,
            kCGImagePropertyExifPixelXDimension,
            kCGImagePropertyExifPixelYDimension
        )

        return fields.isEmpty ? nil : MetadataSection(title: "拍摄参数", systemImageName: "camera.aperture", fields: fields)
    }

    private static func gpsSection(properties: [CFString: Any]) -> MetadataSection? {
        let gps = dictionary(properties, kCGImagePropertyGPSDictionary)
        guard !gps.isEmpty else { return nil }

        var fields: [MetadataField] = []
        if let latitude = coordinate(gps, valueKey: kCGImagePropertyGPSLatitude, referenceKey: kCGImagePropertyGPSLatitudeRef) {
            fields.append(MetadataField("纬度", MetadataFormat.coordinate(latitude)))
        }
        if let longitude = coordinate(gps, valueKey: kCGImagePropertyGPSLongitude, referenceKey: kCGImagePropertyGPSLongitudeRef) {
            fields.append(MetadataField("经度", MetadataFormat.coordinate(longitude)))
        }
        if let altitude = number(gps, kCGImagePropertyGPSAltitude) {
            let belowSeaLevel = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1
            fields.append(MetadataField("海拔", "\(MetadataFormat.decimal(belowSeaLevel ? -altitude : altitude, places: 1)) 米"))
        }
        let dateStamp = text(gps, kCGImagePropertyGPSDateStamp)
        let timeStamp = componentText(gps, kCGImagePropertyGPSTimeStamp, separator: ":")
        if let dateStamp, let timeStamp {
            fields.append(MetadataField("GPS 时间", "\(dateStamp) \(timeStamp) UTC"))
        } else if let dateStamp {
            fields.append(MetadataField("GPS 日期", "\(dateStamp) UTC"))
        }
        if let speed = number(gps, kCGImagePropertyGPSSpeed) {
            let unit = text(gps, kCGImagePropertyGPSSpeedRef).map(speedUnitDescription) ?? ""
            fields.append(MetadataField("速度", "\(MetadataFormat.decimal(speed, places: 2)) \(unit)".trimmingCharacters(in: .whitespaces)))
        }
        if let direction = number(gps, kCGImagePropertyGPSImgDirection) {
            fields.append(MetadataField("拍摄方向", "\(MetadataFormat.decimal(direction, places: 1))°"))
        }
        if let processingMethod = text(gps, kCGImagePropertyGPSProcessingMethod) {
            fields.append(MetadataField("定位方式", processingMethod))
        }

        return fields.isEmpty ? nil : MetadataSection(title: "位置", systemImageName: "location", fields: fields)
    }

    private static func textSections(properties: [CFString: Any]) -> [MetadataSection] {
        var sections: [MetadataSection] = []

        let iptc = dictionary(properties, kCGImagePropertyIPTCDictionary)
        if !iptc.isEmpty {
            var fields: [MetadataField] = []
            append(&fields, "标题", text(iptc, kCGImagePropertyIPTCObjectName))
            append(&fields, "说明", text(iptc, kCGImagePropertyIPTCCaptionAbstract))
            append(&fields, "关键词", text(iptc, kCGImagePropertyIPTCKeywords))
            append(&fields, "作者", text(iptc, kCGImagePropertyIPTCByline))
            append(&fields, "版权", text(iptc, kCGImagePropertyIPTCCopyrightNotice))
            append(&fields, "城市", text(iptc, kCGImagePropertyIPTCCity))
            append(&fields, "国家/地区", text(iptc, kCGImagePropertyIPTCCountryPrimaryLocationName))
            append(
                &fields,
                "创建时间",
                firstText(text(iptc, kCGImagePropertyIPTCDateCreated), text(iptc, kCGImagePropertyIPTCTimeCreated))
            )
            if !fields.isEmpty {
                sections.append(MetadataSection(title: "说明 (IPTC)", systemImageName: "text.alignleft", fields: fields))
            }
        }

        let png = dictionary(properties, kCGImagePropertyPNGDictionary)
        if !png.isEmpty {
            var fields: [MetadataField] = []
            append(&fields, "标题", text(png, kCGImagePropertyPNGTitle))
            append(&fields, "描述", text(png, kCGImagePropertyPNGDescription))
            append(&fields, "作者", text(png, kCGImagePropertyPNGAuthor))
            append(&fields, "版权", text(png, kCGImagePropertyPNGCopyright))
            append(&fields, "软件", text(png, kCGImagePropertyPNGSoftware))
            append(&fields, "创建时间", text(png, kCGImagePropertyPNGCreationTime))
            append(&fields, "备注", text(png, kCGImagePropertyPNGComment))
            if !fields.isEmpty {
                sections.append(MetadataSection(title: "说明 (PNG)", systemImageName: "text.alignleft", fields: fields))
            }
        }

        return sections
    }

    /// EXIF 里没有单独映射的标签，兜底列出来，避免漏掉信息。
    private static func extraExifSection(exif: [CFString: Any], handledExifKeys: Set<String>) -> MetadataSection? {
        var fields: [MetadataField] = []
        for (key, value) in exif {
            let name = key as String
            guard !handledExifKeys.contains(name), !opaqueExifKeys.contains(name) else { continue }
            guard let display = plainDescription(of: value) else { continue }
            fields.append(MetadataField(name, display))
        }
        guard !fields.isEmpty else { return nil }
        let sorted = fields.sorted { $0.label < $1.label }
        return MetadataSection(title: "其他 EXIF", systemImageName: "list.bullet", fields: Array(sorted.prefix(40)))
    }

    // MARK: - 视频

    private static func videoSections(for url: URL) async -> [MetadataSection] {
        let asset = AVURLAsset(url: url)

        let isPlayable: Bool
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            isPlayable = try await asset.load(.isPlayable)
            duration = try await asset.load(.duration)
            tracks = try await asset.load(.tracks)
        } catch {
            return [
                MetadataSection(
                    title: "视频",
                    systemImageName: "exclamationmark.triangle",
                    fields: [MetadataField("无法读取", error.localizedDescription)]
                )
            ]
        }

        let seconds = CMTimeGetSeconds(duration)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        let subtitleTracks = tracks.filter { $0.mediaType == .subtitle || $0.mediaType == .text }

        var sections: [MetadataSection] = []

        var basic: [MetadataField] = []
        if seconds.isFinite, seconds > 0 {
            basic.append(MetadataField("时长", MetadataFormat.duration(seconds)))
        }
        if !isPlayable {
            basic.append(MetadataField("可播放", "否 · 系统解码器不支持这个容器或编码"))
        }
        if let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, seconds.isFinite, seconds > 0 {
            basic.append(MetadataField("总码率", String(format: "%.2f Mbps", Double(fileSize) * 8 / seconds / 1_000_000)))
        }
        if let videoTrack = videoTracks.first {
            let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
            let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            let displaySize = naturalSize.applying(transform)
            let width = Int(abs(displaySize.width).rounded())
            let height = Int(abs(displaySize.height).rounded())
            if width > 0, height > 0 {
                basic.append(MetadataField("分辨率", "\(width) × \(height) 像素"))
                basic.append(MetadataField("宽高比", aspectRatioDescription(width: width, height: height)))
            }
            let frameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
            if frameRate > 0 {
                basic.append(MetadataField("帧率", String(format: "%.2f fps", Double(frameRate))))
            }
            let dataRate = (try? await videoTrack.load(.estimatedDataRate)) ?? 0
            if dataRate > 0 {
                basic.append(MetadataField("视频码率", String(format: "%.2f Mbps", Double(dataRate) / 1_000_000)))
            }
        }
        if audioTracks.count > 0 { basic.append(MetadataField("音轨", "\(audioTracks.count) 条")) }
        if subtitleTracks.count > 0 { basic.append(MetadataField("字幕轨", "\(subtitleTracks.count) 条")) }
        if !basic.isEmpty {
            sections.append(MetadataSection(title: "视频", systemImageName: "film", fields: basic))
        }

        for (index, track) in videoTracks.enumerated() {
            var fields: [MetadataField] = []
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            if let format = formats.first {
                append(&fields, "编码", codecDescription(for: format))
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                if dimensions.width > 0, dimensions.height > 0 {
                    fields.append(MetadataField("编码尺寸", "\(dimensions.width) × \(dimensions.height) 像素"))
                }
                let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any]
                if let extensions {
                    append(&fields, "色彩原色", colorPrimariesDescription(text(extensions, kCMFormatDescriptionExtension_ColorPrimaries)))
                    append(&fields, "传输函数", transferFunctionDescription(text(extensions, kCMFormatDescriptionExtension_TransferFunction)))
                    append(&fields, "YCbCr 矩阵", text(extensions, kCMFormatDescriptionExtension_YCbCrMatrix))
                    if let depth = integer(extensions, kCMFormatDescriptionExtension_Depth) {
                        fields.append(MetadataField("位深", "\(depth) 位"))
                    }
                }
                if CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC || CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVCWithAlpha {
                    fields.append(MetadataField("编码标准", "HEVC (H.265)"))
                }
            }
            let dataRate = (try? await track.load(.estimatedDataRate)) ?? 0
            if dataRate > 0 {
                fields.append(MetadataField("码率", String(format: "%.2f Mbps", Double(dataRate) / 1_000_000)))
            }
            let timeRange = (try? await track.load(.timeRange)) ?? .zero
            let trackSeconds = CMTimeGetSeconds(timeRange.duration)
            if trackSeconds.isFinite, trackSeconds > 0 {
                fields.append(MetadataField("轨时长", MetadataFormat.duration(trackSeconds)))
            }
            if (try? await track.load(.isPlayable)) == false {
                fields.append(MetadataField("可解码", "否"))
            }
            if !fields.isEmpty {
                let title = videoTracks.count > 1 ? "视频轨 \(index + 1)" : "视频轨"
                sections.append(MetadataSection(title: title, systemImageName: "video", fields: fields))
            }
        }

        for (index, track) in audioTracks.enumerated() {
            var fields: [MetadataField] = []
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            if let format = formats.first {
                append(&fields, "编码", codecDescription(for: format))
                if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    if streamDescription.mSampleRate > 0 {
                        fields.append(MetadataField("采样率", "\(MetadataFormat.integer(streamDescription.mSampleRate)) Hz"))
                    }
                    if streamDescription.mChannelsPerFrame > 0 {
                        fields.append(MetadataField("声道数", "\(streamDescription.mChannelsPerFrame)"))
                    }
                    if streamDescription.mBitsPerChannel > 0 {
                        fields.append(MetadataField("位深", "\(streamDescription.mBitsPerChannel) 位"))
                    }
                }
            }
            let dataRate = (try? await track.load(.estimatedDataRate)) ?? 0
            if dataRate > 0 {
                fields.append(MetadataField("码率", String(format: "%.2f Mbps", Double(dataRate) / 1_000_000)))
            }
            if !fields.isEmpty {
                let title = audioTracks.count > 1 ? "音频轨 \(index + 1)" : "音频轨"
                sections.append(MetadataSection(title: title, systemImageName: "waveform", fields: fields))
            }
        }

        if let metadataSection = await metadataSection(for: asset) {
            sections.append(metadataSection)
        }

        return sections.filter { !$0.fields.isEmpty }
    }

    private static func metadataSection(for asset: AVAsset) async -> MetadataSection? {
        var fields: [MetadataField] = []
        var seen = Set<String>()

        if let creationDateItem = try? await asset.load(.creationDate),
           let date = try? await creationDateItem.load(.dateValue) {
            let formatted = MetadataFormat.date(date)
            fields.append(MetadataField("创建时间", formatted))
            seen.insert("创建时间\u{1}\(formatted)")
        }

        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let allMetadata = (try? await asset.load(.metadata)) ?? []
        var items = commonMetadata
        items.append(contentsOf: allMetadata)

        for item in items {
            guard let value = await metadataValue(for: item) else { continue }
            let label = metadataLabel(for: item)
            guard seen.insert("\(label)\u{1}\(value)").inserted else { continue }
            fields.append(MetadataField(label, value))
            if fields.count >= 40 { break }
        }

        return fields.isEmpty ? nil : MetadataSection(title: "元数据", systemImageName: "tag", fields: fields)
    }

    private static func metadataValue(for item: AVMetadataItem) async -> String? {
        if let string = try? await item.load(.stringValue), !string.isEmpty {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = try? await item.load(.numberValue) {
            return number.stringValue
        }
        if let date = try? await item.load(.dateValue) {
            return MetadataFormat.date(date)
        }
        return nil
    }

    private static func metadataLabel(for item: AVMetadataItem) -> String {
        if let commonKey = item.commonKey?.rawValue {
            return commonKeyLabel(commonKey)
        }
        if let identifier = item.identifier?.rawValue {
            return friendlyMetadataKey(shortMetadataKey(identifier))
        }
        if let key = item.key as? String, !key.isEmpty {
            return friendlyMetadataKey(key)
        }
        return "元数据"
    }

    private static func shortMetadataKey(_ identifier: String) -> String {
        if let slashIndex = identifier.firstIndex(of: "/") {
            return String(identifier[identifier.index(after: slashIndex)...])
        }
        return identifier
    }

    private static func commonKeyLabel(_ raw: String) -> String {
        switch raw {
        case "title": return "标题"
        case "artist": return "艺术家"
        case "albumName": return "专辑"
        case "creationDate": return "创建时间"
        case "make": return "制造商"
        case "model": return "机型"
        case "software": return "软件"
        case "creator": return "创建者"
        case "subject": return "主题"
        case "description": return "描述"
        case "publisher": return "发布者"
        case "contributor": return "贡献者"
        case "date": return "日期"
        case "type": return "类型"
        case "format": return "格式"
        case "identifier": return "标识"
        case "source": return "来源"
        case "language": return "语言"
        case "relation": return "关系"
        case "coverage": return "覆盖范围"
        case "copyright": return "版权"
        case "keywords": return "关键词"
        case "location": return "位置"
        default: return raw
        }
    }

    private static func friendlyMetadataKey(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let table: [String: String] = [
            "title": "标题", "©nam": "标题", "displayname": "显示名称",
            "artist": "艺术家", "©art": "艺术家", "album": "专辑", "©alb": "专辑", "albumname": "专辑",
            "author": "作者", "©aut": "作者", "creator": "创建者",
            "make": "制造商", "©mak": "制造商", "model": "机型", "©mod": "机型",
            "software": "软件", "©swr": "软件", "encoder": "编码器", "©too": "编码器",
            "creationdate": "创建时间", "©day": "创建时间", "date": "日期",
            "location.iso6709": "位置 (ISO6709)", "©xyz": "位置 (ISO6709)",
            "comment": "备注", "©cmt": "备注", "description": "描述", "desc": "描述",
            "copyright": "版权", "cprt": "版权", "©cpy": "版权",
            "genre": "类型", "©gen": "类型", "keywords": "关键词", "keyw": "关键词",
            "com.apple.quicktime.make": "制造商", "com.apple.quicktime.model": "机型",
            "com.apple.quicktime.software": "软件", "com.apple.quicktime.author": "作者",
            "com.apple.quicktime.displayname": "显示名称",
        ]
        if let mapped = table[lowered] { return mapped }
        if let last = lowered.split(separator: ".").last, let mapped = table[String(last)] { return mapped }
        return raw
    }

    // MARK: - 编码 / 枚举描述

    private static func codecDescription(for format: CMFormatDescription) -> String {
        let subType = CMFormatDescriptionGetMediaSubType(format)
        let fourCC = fourCharacterCode(subType)
        if let name = codecNames[fourCC] {
            return "\(name) (\(fourCC))"
        }
        return fourCC
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        let characters = bytes.map { byte -> Character in
            guard (0x20...0x7E).contains(byte), let scalar = UnicodeScalar(UInt32(byte)) else { return "?" }
            return Character(scalar)
        }
        let text = String(characters).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "未知" : text
    }

    private static let codecNames: [String: String] = [
        "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC (H.265)", "hev1": "HEVC (H.265)",
        "mp4v": "MPEG-4 Video", "jpeg": "Motion JPEG", "mjpa": "Motion JPEG A", "mjpb": "Motion JPEG B",
        "apch": "Apple ProRes 422 HQ", "apcn": "Apple ProRes 422", "apcs": "Apple ProRes 422 LT",
        "apco": "Apple ProRes 422 Proxy", "ap4h": "Apple ProRes 4444", "ap4x": "Apple ProRes 4444 XQ",
        "vp09": "VP9", "av01": "AV1", "dvh1": "Dolby Vision (HEVC)", "dvhe": "Dolby Vision (HEVC)",
        "mp4a": "AAC", "aac": "AAC", "alac": "Apple Lossless", "lpcm": "PCM", "sowt": "PCM (小端)",
        "twos": "PCM (大端)", "in24": "PCM 24 位", "in32": "PCM 32 位", "fl32": "PCM 浮点 32 位",
        "ac-3": "AC-3", "ec-3": "E-AC-3", "Opus": "Opus", "opus": "Opus", "flac": "FLAC",
        "ima4": "IMA 4:1", "ulaw": "μ-law", "alaw": "A-law",
    ]

    private static func colorPrimariesDescription(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value {
        case "ITU_R_709_2": return "ITU-R BT.709"
        case "ITU_R_2020": return "ITU-R BT.2020"
        case "SMPTE_C": return "SMPTE-C"
        case "EBU_3213": return "EBU 3213"
        case "P3_D65": return "Display P3"
        case "DCI_P3": return "DCI-P3"
        default: return value
        }
    }

    private static func transferFunctionDescription(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value {
        case "ITU_R_709_2": return "ITU-R BT.709"
        case "ITU_R_2020": return "ITU-R BT.2020"
        case "SMPTE_240M_1995": return "SMPTE 240M"
        case "PQ": return "SMPTE ST 2084 (PQ)"
        case "HLG": return "HLG (BT.2100)"
        case "LINEAR": return "线性"
        case "sRGB": return "sRGB"
        default: return value
        }
    }

    private static func aspectRatioDescription(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        let divisor = greatestCommonDivisor(width, height)
        let reducedWidth = width / divisor
        let reducedHeight = height / divisor
        let decimal = String(format: "%.2f:1", Double(width) / Double(height))
        if reducedWidth <= 50, reducedHeight <= 50, reducedWidth != width || reducedHeight != height {
            return "\(reducedWidth):\(reducedHeight)（\(decimal)）"
        }
        return decimal
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x == 0 ? 1 : x
    }

    private static func orientationDescription(_ value: Int) -> String {
        switch value {
        case 2: return "水平镜像"
        case 3: return "旋转 180°"
        case 4: return "垂直镜像"
        case 5: return "水平镜像后旋转 270°"
        case 6: return "顺时针旋转 90°"
        case 7: return "水平镜像后旋转 90°"
        case 8: return "逆时针旋转 90°"
        default: return "\(value)"
        }
    }

    private static func exposureProgramDescription(_ value: Int) -> String {
        switch value {
        case 0: return "未定义"
        case 1: return "手动"
        case 2: return "程序自动"
        case 3: return "光圈优先"
        case 4: return "快门优先"
        case 5: return "创意（慢速）"
        case 6: return "动作（高速）"
        case 7: return "人像"
        case 8: return "风景"
        default: return "\(value)"
        }
    }

    private static func exposureModeDescription(_ value: Int) -> String {
        switch value {
        case 0: return "自动曝光"
        case 1: return "手动曝光"
        case 2: return "自动包围曝光"
        default: return "\(value)"
        }
    }

    private static func meteringModeDescription(_ value: Int) -> String {
        switch value {
        case 0: return "未知"
        case 1: return "平均"
        case 2: return "中央重点平均"
        case 3: return "点测光"
        case 4: return "多点测光"
        case 5: return "评价测光"
        case 6: return "局部测光"
        case 255: return "其他"
        default: return "\(value)"
        }
    }

    private static func flashDescription(_ value: Int) -> String {
        switch value {
        case 0x00: return "未闪光"
        case 0x01: return "闪光"
        case 0x05: return "闪光（未检测到反射光）"
        case 0x07: return "闪光（检测到反射光）"
        case 0x08: return "未闪光（强制关闭）"
        case 0x09: return "闪光（强制）"
        case 0x0D: return "闪光（强制，未检测到反射光）"
        case 0x0F: return "闪光（强制，检测到反射光）"
        case 0x10: return "未闪光（自动）"
        case 0x18: return "未闪光（自动，强制关闭）"
        case 0x19: return "闪光（自动）"
        case 0x1D: return "闪光（自动，未检测到反射光）"
        case 0x1F: return "闪光（自动，检测到反射光）"
        case 0x20: return "未闪光（无闪光灯）"
        case 0x41: return "闪光（红眼消除）"
        case 0x45: return "闪光（红眼消除，未检测到反射光）"
        case 0x47: return "闪光（红眼消除，检测到反射光）"
        case 0x49: return "闪光（强制，红眼消除）"
        case 0x4D: return "闪光（强制，红眼消除，未检测到反射光）"
        case 0x4F: return "闪光（强制，红眼消除，检测到反射光）"
        case 0x50: return "未闪光（自动，红眼消除）"
        case 0x58: return "未闪光（自动，强制关闭，红眼消除）"
        case 0x59: return "闪光（自动，红眼消除）"
        case 0x5D: return "闪光（自动，红眼消除，未检测到反射光）"
        case 0x5F: return "闪光（自动，红眼消除，检测到反射光）"
        default: return String(format: "0x%02X", value)
        }
    }

    private static func sceneCaptureTypeDescription(_ value: Int) -> String {
        switch value {
        case 0: return "标准"
        case 1: return "风景"
        case 2: return "人像"
        case 3: return "夜景"
        default: return "\(value)"
        }
    }

    private static func speedUnitDescription(_ reference: String) -> String {
        switch reference.uppercased() {
        case "K": return "km/h"
        case "M": return "mph"
        case "N": return "节"
        default: return ""
        }
    }

    // MARK: - 取值辅助

    private static func dictionary(_ properties: [CFString: Any], _ key: CFString) -> [CFString: Any] {
        properties[key] as? [CFString: Any] ?? [:]
    }

    private static func number(_ dictionary: [CFString: Any], _ key: CFString) -> Double? {
        (dictionary[key] as? NSNumber)?.doubleValue
    }

    /// 取数值，兼容“包在数组里的单值”（例如 EXIF 的 ISOSpeedRatings）。
    private static func firstNumber(_ dictionary: [CFString: Any], _ key: CFString) -> Double? {
        if let value = number(dictionary, key) { return value }
        if let array = dictionary[key] as? [Any] {
            return array.compactMap { ($0 as? NSNumber)?.doubleValue }.first
        }
        return nil
    }

    private static func integer(_ dictionary: [CFString: Any], _ key: CFString) -> Int? {
        (dictionary[key] as? NSNumber)?.intValue
    }

    /// 把任意可打印的值转成展示文本（字符串 / 数字 / 数组）。
    private static func text(_ dictionary: [CFString: Any], _ key: CFString) -> String? {
        guard let value = dictionary[key] else { return nil }
        return plainDescription(of: value)
    }

    private static func componentText(_ dictionary: [CFString: Any], _ key: CFString, separator: String) -> String? {
        guard let value = dictionary[key] else { return nil }
        if let parts = value as? [Any] {
            let joined = parts.compactMap { plainDescription(of: $0) }.joined(separator: separator)
            return joined.isEmpty ? nil : joined
        }
        return plainDescription(of: value)
    }

    private static func plainDescription(of value: Any) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let joined = array.compactMap { plainDescription(of: $0) }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        default:
            return nil
        }
    }

    private static func coordinate(_ dictionary: [CFString: Any], valueKey: CFString, referenceKey: CFString) -> Double? {
        // 多数情况下 ImageIO 已经给出十进制度数；少数文件会保留 [度, 分, 秒] 数组。
        var magnitude: Double?
        if let value = number(dictionary, valueKey) {
            magnitude = abs(value)
        } else if let parts = dictionary[valueKey] as? [Any] {
            let components = parts.compactMap { ($0 as? NSNumber)?.doubleValue }
            if components.count >= 3 {
                magnitude = abs(components[0] + components[1] / 60 + components[2] / 3600)
            }
        }
        guard let magnitude else { return nil }

        var signed = magnitude
        let reference = text(dictionary, referenceKey)?.uppercased() ?? ""
        if reference == "S" || reference == "W" { signed = -signed }
        return signed
    }

    private static func firstText(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    private static func append(_ fields: inout [MetadataField], _ label: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        fields.append(MetadataField(label, value))
    }

    private static func mark(_ handled: inout Set<String>, _ keys: CFString...) {
        for key in keys {
            handled.insert(key as String)
        }
    }

    private static let opaqueExifKeys: Set<String> = ["MakerNote"]
}
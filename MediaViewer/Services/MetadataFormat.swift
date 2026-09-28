import Foundation

/// 元数据数值的展示格式化。
enum MetadataFormat {
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: count)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 时长：`1:02.345` / `1:02:03.456`
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let totalMilliseconds = Int((seconds * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secondsPart = totalSeconds % 60
        let minutesPart = (totalSeconds / 60) % 60
        let hoursPart = totalSeconds / 3600
        if hoursPart > 0 {
            return String(format: "%d:%02d:%02d.%03d", hoursPart, minutesPart, secondsPart, milliseconds)
        }
        return String(format: "%d:%02d.%03d", minutesPart, secondsPart, milliseconds)
    }

    static func decimal(_ value: Double, places: Int = 2) -> String {
        String(format: "%.\(places)f", value)
    }

    static func integer(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// 快门速度：`1/250 秒` / `2.50 秒`
    static func shutterSpeed(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.2f 秒", seconds) }
        return String(format: "1/%.0f 秒", (1 / seconds).rounded())
    }

    /// 经纬度：`37.774900°`
    static func coordinate(_ value: Double) -> String {
        String(format: "%.6f°", value)
    }
}
import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// UI 冒烟测试用的小工具（`scripts/ui-smoke.sh` 调用）。
///
///   window-probe window <owner>                     打印 "x y w h 标题"
///   window-probe stats <png> [x0 x1 y0 y1]          打印区域的量化颜色数 / 彩色比例（归一化坐标）
@main
enum WindowProbe {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            usage()
            exit(2)
        }
        arguments.removeFirst()

        switch command {
        case "window":
            window(owner: arguments.first ?? "")
        case "stats":
            stats(arguments)
        default:
            usage()
            exit(2)
        }
    }

    private static func usage() {
        FileHandle.standardError.write(Data("用法: window-probe window <owner> | window-probe stats <png> [x0 x1 y0 y1]\n".utf8))
    }

    /// 打印指定 App 最大那个窗口的位置与标题。
    private static func window(owner: String) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            FileHandle.standardError.write(Data("无法读取窗口列表\n".utf8))
            exit(1)
        }

        var best: (rect: CGRect, title: String)?
        for entry in list {
            let entryOwner = entry[kCGWindowOwnerName as String] as? String ?? ""
            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            guard entryOwner == owner, layer == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }

            if best == nil || rect.width * rect.height > best!.rect.width * best!.rect.height {
                best = (rect, entry[kCGWindowName as String] as? String ?? "")
            }
        }

        guard let best else {
            FileHandle.standardError.write(Data("没有找到 \(owner) 的窗口（App 没起来？）\n".utf8))
            exit(1)
        }

        print("\(Int(best.rect.minX)) \(Int(best.rect.minY)) \(Int(best.rect.width)) \(Int(best.rect.height)) \(best.title)")
    }

    /// 统计截图里某个区域的颜色分布，用来判断“画出来的是不是内容”。
    private static func stats(_ arguments: [String]) {
        guard let path = arguments.first,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            FileHandle.standardError.write(Data("无法读取图片: \(arguments.first ?? "-")\n".utf8))
            exit(1)
        }

        var fractions: [Double] = [0, 1, 0, 1]
        if arguments.count >= 5 {
            fractions = arguments[1...4].compactMap(Double.init)
            guard fractions.count == 4 else {
                FileHandle.standardError.write(Data("区域参数需要 4 个 0~1 的浮点数\n".utf8))
                exit(2)
            }
        }

        // 缩到最多 1200 像素宽，够统计用而且快。
        let scale = min(1.0, 1200.0 / Double(image.width))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { exit(1) }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x0 = Int(Double(width) * fractions[0])
        let x1 = Int(Double(width) * fractions[1])
        let y0 = Int(Double(height) * fractions[2])
        let y1 = Int(Double(height) * fractions[3])

        var colors: [Int: Int] = [:]
        var total = 0, colorful = 0, dark = 0, light = 0
        var sumR = 0, sumG = 0, sumB = 0
        var y = max(0, y0)
        while y < min(height, y1) {
            let flipped = height - 1 - y // CoreGraphics 原点在左下
            var x = max(0, x0)
            while x < min(width, x1) {
                let index = (flipped * width + x) * 4
                let r = Int(buffer[index]), g = Int(buffer[index + 1]), b = Int(buffer[index + 2])
                colors[((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4), default: 0] += 1
                if max(r, g, b) - min(r, g, b) > 40 { colorful += 1 }
                let luma = (r * 299 + g * 587 + b * 114) / 1000
                if luma < 100 { dark += 1 }
                if luma > 200 { light += 1 }
                sumR += r; sumG += g; sumB += b
                total += 1
                x += 2
            }
            y += 2
        }

        let divisor = Double(max(total, 1))
        print("pixels=\(total)")
        print("colors=\(colors.count)")
        print(String(format: "colorful_percent=%.1f", Double(colorful) * 100 / divisor))
        print(String(format: "dark_percent=%.1f", Double(dark) * 100 / divisor))
        print(String(format: "light_percent=%.1f", Double(light) * 100 / divisor))
        print("mean_rgb=\(sumR / max(total, 1)),\(sumG / max(total, 1)),\(sumB / max(total, 1))")
        if let top = colors.max(by: { $0.value < $1.value }) {
            let r = (top.key >> 8) << 4, g = ((top.key >> 4) & 0xF) << 4, b = (top.key & 0xF) << 4
            print(String(format: "dominant=%d,%d,%d,%.0f", r, g, b, Double(top.value) * 100 / divisor))
        }
    }
}
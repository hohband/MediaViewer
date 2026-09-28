import AppKit
import Foundation

/// 「Finder 打开方式」验证用的小工具（`scripts/verify-handler.sh` 调用）。
///
///   handler-probe handlers <文件>   打印系统认为能打开该文件的 App（第一行是默认程序）
///
/// 数据来自 LaunchServices，也就是 Finder 右键菜单 / 「显示简介 → 打开方式」用的同一份信息。
@main
enum HandlerProbe {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            usage()
            exit(2)
        }
        arguments.removeFirst()

        switch command {
        case "handlers":
            handlers(path: arguments.first ?? "")
        default:
            usage()
            exit(2)
        }
    }

    private static func usage() {
        FileHandle.standardError.write(Data("用法: handler-probe handlers <文件>\n".utf8))
    }

    private static func handlers(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("文件不存在: \(path)\n".utf8))
            exit(1)
        }

        if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url) {
            print(line(role: "default", app: defaultApp))
        } else {
            print("default\t-\t-")
        }

        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) {
            print(line(role: "handler", app: app))
        }
    }

    /// 制表符分隔，方便脚本里 awk/grep：角色、App 路径、bundle id。
    private static func line(role: String, app: URL) -> String {
        let identifier = Bundle(url: app)?.bundleIdentifier ?? "-"
        return "\(role)\t\(app.path)\t\(identifier)"
    }
}

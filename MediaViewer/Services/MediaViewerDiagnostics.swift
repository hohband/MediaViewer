import Foundation

/// 命令行诊断：只跑“读取参数 -> 打开文件夹 -> 选中第一个文件”的数据链路，不创建窗口。
///
///   MediaViewer --dump-state <输出文件> [文件夹]
///
/// `scripts/smoke-test.sh` 用它验证启动参数与扫描结果，不需要人工操作界面。
/// 没有 `--dump-state` 时这个类型什么也不做。
enum MediaViewerDiagnostics {
    @MainActor
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--dump-state") else { return }

        let outputPath = arguments.indices.contains(flagIndex + 1) ? arguments[flagIndex + 1] : nil

        let library = MediaLibrary()
        var opened: String?
        for argument in arguments.dropFirst() where !argument.hasPrefix("-") && argument != outputPath {
            if library.loadIfDirectory(URL(fileURLWithPath: argument)) {
                opened = argument
                break
            }
        }

        var report: [String] = []
        report.append("arguments=\(arguments.dropFirst().joined(separator: " "))")
        report.append("opened=\(opened ?? "-")")
        report.append("folder=\(library.folderURL?.path ?? "-")")
        report.append("message=\(library.message ?? "-")")
        report.append("count=\(library.items.count)")
        report.append("current=\(library.currentItem?.fileName ?? "-")")
        report.append("position=\(library.positionText)")
        report.append("canGoNext=\(library.canGoNext)")
        report.append("items=\(library.items.map(\.fileName).joined(separator: ","))")
        library.goToNext()
        report.append("afterNext=\(library.currentItem?.fileName ?? "-")")

        let text = report.joined(separator: "\n") + "\n"
        if let outputPath {
            try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
        } else {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        exit(0)
    }
}
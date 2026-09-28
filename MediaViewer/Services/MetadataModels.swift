import Foundation

/// 元数据面板里的一行。
struct MetadataField: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// 元数据面板里的一个分组。
struct MetadataSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let systemImageName: String
    let fields: [MetadataField]

    init(title: String, systemImageName: String, fields: [MetadataField]) {
        self.title = title
        self.systemImageName = systemImageName
        self.fields = fields
    }
}

/// 元数据的加载状态。
enum MetadataLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}
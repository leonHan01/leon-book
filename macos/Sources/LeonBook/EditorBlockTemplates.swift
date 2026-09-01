import Foundation

struct EditorBlockTemplate: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var body: String

    init(id: String = UUID().uuidString.lowercased(), name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }
}

enum EditorBlockTemplateCatalog {
    private static let defaultsKey = "leonBook.editor.blockTemplates.v1"

    static let builtIn: [EditorBlockTemplate] = [
        EditorBlockTemplate(
            id: "builtin-meeting",
            name: "会议记录",
            body: """
            ## 会议信息

            - 时间
              - 待填写
            - 参与者
              - 待填写

            ## 议题

            - 讨论事项

            ## 行动项

            - [ ] 后续任务
            """
        ),
        EditorBlockTemplate(
            id: "builtin-reading",
            name: "读书笔记",
            body: """
            ## 核心观点

            > 写下最重要的观点

            ## 摘录

            - 关键摘录

            ## 我的思考

            写下理解、质疑与连接。
            """
        ),
        EditorBlockTemplate(
            id: "builtin-review",
            name: "周复盘",
            body: """
            ## 本周完成

            - [x] 已完成事项

            ## 下周计划

            - [ ] 下一步行动

            ## 数据回顾

            | 指标 | 结果 |
            | --- | --- |
            | 进度 | 待填写 |
            """
        ),
    ]

    static func loadCustom(defaults: UserDefaults = .standard) -> [EditorBlockTemplate] {
        guard let data = defaults.data(forKey: defaultsKey),
              let templates = try? JSONDecoder().decode([EditorBlockTemplate].self, from: data) else {
            return []
        }
        return templates
    }

    static func saveCustom(
        _ templates: [EditorBlockTemplate],
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

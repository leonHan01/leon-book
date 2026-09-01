import AppKit
import Foundation
import SwiftUI

struct NativeArticlePageTemplate: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var systemImage: String
    var title: String
    var category: String
    var excerpt: String
    var tags: String
    var body: String
    var properties: [String: NativeArticlePropertyValue]

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        systemImage: String = "doc.text",
        title: String = "",
        category: String = "Notes",
        excerpt: String = "",
        tags: String = "",
        body: String = "",
        properties: [String: NativeArticlePropertyValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.title = title
        self.category = category
        self.excerpt = excerpt
        self.tags = tags
        self.body = body
        self.properties = properties
    }

    init(id: String = UUID().uuidString.lowercased(), name: String, draft: NativeEditorDraft) {
        self.init(
            id: id,
            name: name,
            title: draft.title,
            category: draft.category,
            excerpt: draft.excerpt,
            tags: draft.tags,
            body: draft.body,
            properties: draft.properties
        )
    }

    func apply(
        to draft: inout NativeEditorDraft,
        at date: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        draft.title = rendered(title, at: date, timeZone: timeZone)
        draft.category = rendered(category, at: date, timeZone: timeZone)
        draft.excerpt = rendered(excerpt, at: date, timeZone: timeZone)
        draft.tags = rendered(tags, at: date, timeZone: timeZone)
        draft.body = rendered(body, at: date, timeZone: timeZone)
        draft.properties = properties.mapValues { property in
            NativeArticlePropertyValue(
                kind: property.kind,
                value: rendered(property.value, at: date, timeZone: timeZone)
            )
        }
        draft.banner = nil
        draft.media = []
        draft.status = .draft
        draft.updatedAt = nil
    }

    static func canCapture(_ draft: NativeEditorDraft) -> Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.category != "Notes"
            || !draft.properties.isEmpty
    }

    private func rendered(_ source: String, at date: Date, timeZone: TimeZone) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.calendar = dateFormatter.calendar
        timeFormatter.locale = dateFormatter.locale
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "HH:mm"

        return source
            .replacingOccurrences(of: "{{date}}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{{time}}", with: timeFormatter.string(from: date))
    }
}

enum NativeArticlePageTemplateCatalog {
    private static let defaultsKeyPrefix = "leonBook.editor.pageTemplates.v1"
    static let maximumCustomTemplateCount = 50

    static let builtIn: [NativeArticlePageTemplate] = [
        NativeArticlePageTemplate(
            id: "builtin-page-meeting",
            name: "会议记录",
            systemImage: "person.3",
            title: "会议记录 · {{date}}",
            category: "Meetings",
            excerpt: "记录本次会议的结论与下一步行动。",
            tags: "#会议",
            body: """
            ## 会议信息

            - 时间：{{date}} {{time}}
            - 参与者：

            ## 议题与结论

            - 

            ## 行动项

            - [ ] 待办事项
            """,
            properties: [
                "日期": .date("{{date}}"),
                "状态": .status("进行中"),
            ]
        ),
        NativeArticlePageTemplate(
            id: "builtin-page-project",
            name: "项目计划",
            systemImage: "flag.checkered",
            title: "项目计划 · ",
            category: "Projects",
            excerpt: "明确目标、范围、里程碑与风险。",
            tags: "#项目",
            body: """
            ## 目标

            描述希望达成的结果。

            ## 范围

            - 包含：
            - 不包含：

            ## 里程碑

            - [ ] 第一个里程碑

            ## 风险与依赖

            - 
            """,
            properties: [
                "状态": .status("规划中"),
                "目标日期": .date("{{date}}"),
            ]
        ),
        NativeArticlePageTemplate(
            id: "builtin-page-weekly-review",
            name: "周复盘",
            systemImage: "calendar.badge.checkmark",
            title: "周复盘 · {{date}}",
            category: "Reviews",
            excerpt: "回顾本周成果、阻碍与下周重点。",
            tags: "#复盘",
            body: """
            ## 本周完成

            - [x] 

            ## 阻碍与收获

            - 

            ## 下周重点

            - [ ] 
            """,
            properties: ["日期": .date("{{date}}")]
        ),
    ]

    static func loadCustom(
        for userID: String,
        defaults: UserDefaults = .standard
    ) -> [NativeArticlePageTemplate] {
        guard let data = defaults.data(forKey: defaultsKey(for: userID)),
              let templates = try? JSONDecoder().decode([NativeArticlePageTemplate].self, from: data) else {
            return []
        }
        return normalizedCustomTemplates(templates)
    }

    @discardableResult
    static func saveCustom(
        _ templates: [NativeArticlePageTemplate],
        for userID: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(normalizedCustomTemplates(templates)) else {
            return false
        }
        defaults.set(data, forKey: defaultsKey(for: userID))
        return true
    }

    private static func defaultsKey(for userID: String) -> String {
        "\(defaultsKeyPrefix).\(userID)"
    }

    private static func normalizedCustomTemplates(
        _ templates: [NativeArticlePageTemplate]
    ) -> [NativeArticlePageTemplate] {
        var seenIDs = Set<String>()
        return templates.compactMap { template in
            var template = template
            template.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !template.name.isEmpty,
                  !builtIn.contains(where: { $0.id == template.id }),
                  seenIDs.insert(template.id).inserted else { return nil }
            template.name = String(template.name.prefix(80))
            return template
        }
        .prefix(maximumCustomTemplateCount)
        .map { $0 }
    }
}

@MainActor
final class NativeArticlePageTemplateLibrary: ObservableObject {
    @Published private(set) var customTemplates: [NativeArticlePageTemplate] = []

    private let defaults: UserDefaults
    private var currentUserID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func prepare(for userID: String) {
        currentUserID = userID
        customTemplates = NativeArticlePageTemplateCatalog.loadCustom(
            for: userID,
            defaults: defaults
        )
    }

    @discardableResult
    func save(_ draft: NativeEditorDraft, named rawName: String) -> Bool {
        guard let currentUserID else { return false }
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty else { return false }

        if let index = customTemplates.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            customTemplates[index] = NativeArticlePageTemplate(
                id: customTemplates[index].id,
                name: name,
                draft: draft
            )
        } else {
            guard customTemplates.count < NativeArticlePageTemplateCatalog.maximumCustomTemplateCount else {
                return false
            }
            customTemplates.append(NativeArticlePageTemplate(name: name, draft: draft))
        }
        customTemplates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return NativeArticlePageTemplateCatalog.saveCustom(
            customTemplates,
            for: currentUserID,
            defaults: defaults
        )
    }

    @discardableResult
    func delete(_ template: NativeArticlePageTemplate) -> Bool {
        guard let currentUserID else { return false }
        customTemplates.removeAll { $0.id == template.id }
        return NativeArticlePageTemplateCatalog.saveCustom(
            customTemplates,
            for: currentUserID,
            defaults: defaults
        )
    }
}

struct ArticlePageTemplatePicker: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var library: NativeArticlePageTemplateLibrary

    var body: some View {
        Menu {
            templateButtons
        } label: {
            Label("使用模板", systemImage: "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help("一次预填标题、正文、分类、标签和页面属性")
    }

    @ViewBuilder
    private var templateButtons: some View {
        Section("内置模板") {
            ForEach(NativeArticlePageTemplateCatalog.builtIn) { template in
                templateButton(template)
            }
        }
        if !library.customTemplates.isEmpty {
            Section("我的模板") {
                ForEach(library.customTemplates) { template in
                    templateButton(template)
                }
            }
        }
    }

    private func templateButton(_ template: NativeArticlePageTemplate) -> some View {
        Button {
            model.applyArticlePageTemplate(template)
        } label: {
            Label(template.name, systemImage: template.systemImage)
        }
    }
}

struct ArticlePageTemplateActions: View {
    @ObservedObject var model: NativeAppModel
    @ObservedObject var library: NativeArticlePageTemplateLibrary

    var body: some View {
        Menu("页面模板", systemImage: "doc.on.doc") {
            if model.editor.isNew {
                Section("应用到新页面") {
                    ForEach(NativeArticlePageTemplateCatalog.builtIn) { template in
                        Button(template.name) { model.applyArticlePageTemplate(template) }
                    }
                    ForEach(library.customTemplates) { template in
                        Button(template.name) { model.applyArticlePageTemplate(template) }
                    }
                }
            }

            Button("将当前页面保存为模板…", systemImage: "square.and.arrow.down") {
                saveCurrentPage()
            }
            .disabled(!NativeArticlePageTemplate.canCapture(model.editor))

            if !library.customTemplates.isEmpty {
                Menu("删除自定义模板", systemImage: "trash") {
                    ForEach(library.customTemplates) { template in
                        Button(template.name, role: .destructive) {
                            if !library.delete(template) {
                                model.errorMessage = "无法删除页面模板。"
                            }
                        }
                    }
                }
            }
        }
    }

    private func saveCurrentPage() {
        let alert = NSAlert()
        alert.messageText = "保存页面模板"
        alert.informativeText = "模板会保存标题、摘要、正文、分类、标签和页面属性；附件与发布状态不会写入模板。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let suggestedName = model.editor.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = NSTextField(string: suggestedName.isEmpty ? "我的页面模板" : suggestedName)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !library.save(model.editor, named: input.stringValue) {
            model.errorMessage = "页面模板名称不能为空，且每个工作区最多保存 50 个模板。"
        } else {
            model.errorMessage = nil
        }
    }
}

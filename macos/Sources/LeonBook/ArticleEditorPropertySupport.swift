import Foundation
import SwiftUI

struct EditorPropertyRow: Identifiable, Equatable {
    let id: UUID
    var key: String
    var kind: NativeArticlePropertyKind
    var value: String

    init(
        id: UUID = UUID(),
        key: String = "",
        kind: NativeArticlePropertyKind = .text,
        value: String = ""
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.value = value
    }

    var typedValue: NativeArticlePropertyValue {
        NativeArticlePropertyValue.fromEditor(kind: kind, text: value)
    }
}

struct EditorPropertyRenameRequest: Identifiable {
    let id = UUID()
    let oldKey: String
}

struct EditorPropertyValueField: View {
    @Binding var row: EditorPropertyRow
    let rows: [EditorPropertyRow]
    let articles: [NativeArticleSummary]
    let sourceSlug: String

    var body: some View {
        switch row.kind {
        case .checkbox:
            Toggle("已选中", isOn: Binding(
                get: { row.typedValue.booleanValue },
                set: { row.value = $0 ? "true" : "false" }
            ))
            .toggleStyle(.checkbox)
        case .date:
            DatePicker(
                "日期",
                selection: Binding(
                    get: { propertyDate(from: row.value) ?? Date() },
                    set: { row.value = propertyDateString(from: $0) }
                ),
                displayedComponents: .date
            )
            .datePickerStyle(.field)
        case .number:
            TextField("数字", text: $row.value).textFieldStyle(.roundedBorder)
        case .list:
            TextField("用逗号或换行分隔列表项", text: $row.value, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
        case .tags:
            TextField("用逗号分隔标签", text: $row.value, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
        case .select, .status:
            HStack(spacing: 6) {
                TextField(row.kind == .select ? "单选值" : "状态", text: $row.value)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(scalarOptions, id: \.self) { option in
                        Button {
                            row.value = option
                        } label: {
                            Label(option, systemImage: row.value == option ? "checkmark" : row.kind.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .help("复用工作区中已有的选项")
            }
        case .relation:
            VStack(alignment: .leading, spacing: 6) {
                TextField("关联页面标题或 slug，用逗号分隔", text: $row.value, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                Menu {
                    ForEach(articles.filter { $0.slug != sourceSlug }) { article in
                        Button {
                            toggleRelation(article)
                        } label: {
                            Label(
                                article.title,
                                systemImage: relationContains(article) ? "checkmark" : "doc.text"
                            )
                        }
                    }
                } label: {
                    Label("选择关联页面", systemImage: "arrow.triangle.branch")
                }
                .menuStyle(.borderlessButton)
            }
        case .rollup:
            VStack(alignment: .leading, spacing: 6) {
                Picker("关联", selection: rollupRelationBinding) {
                    if relationKeys.isEmpty { Text("先添加关联属性").tag("") }
                    ForEach(relationKeys, id: \.self) { Text($0).tag($0) }
                }
                Picker("目标", selection: rollupTargetBinding) {
                    Text("页面本身（用于计数）").tag("")
                    ForEach(targetPropertyKeys, id: \.self) { Text($0).tag($0) }
                }
                Picker("计算", selection: rollupCalculationBinding) {
                    ForEach(NativeArticleRollupCalculation.allCases, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
            }
            .pickerStyle(.menu)
            .disabled(relationKeys.isEmpty)
        case .text:
            TextField("属性值", text: $row.value, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...5)
        }
    }

    private func propertyDate(from value: String) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    private func propertyDateString(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private var scalarOptions: [String] {
        var values = row.kind == .status ? ["未开始", "进行中", "已完成"] : []
        if !row.value.isEmpty { values.append(row.value) }
        for article in articles {
            guard let value = article.properties.first(where: {
                $0.key.caseInsensitiveCompare(row.key) == .orderedSame
            })?.value.editorText, !value.isEmpty else { continue }
            values.append(value)
        }
        var unique: [String] = []
        for value in values where !unique.contains(where: {
            $0.caseInsensitiveCompare(value) == .orderedSame
        }) {
            unique.append(value)
        }
        return unique
    }

    private var relationValues: [String] {
        NativeArticlePropertyValue.fromEditor(kind: .relation, text: row.value).listValues
    }

    private func relationContains(_ article: NativeArticleSummary) -> Bool {
        relationValues.contains(where: { reference in
            article.slug.caseInsensitiveCompare(reference) == .orderedSame
                || article.title.caseInsensitiveCompare(reference) == .orderedSame
                || article.aliases.contains(where: { $0.caseInsensitiveCompare(reference) == .orderedSame })
        })
    }

    private func toggleRelation(_ article: NativeArticleSummary) {
        var values = relationValues.filter { reference in
            article.slug.caseInsensitiveCompare(reference) != .orderedSame
                && article.title.caseInsensitiveCompare(reference) != .orderedSame
                && !article.aliases.contains(where: { $0.caseInsensitiveCompare(reference) == .orderedSame })
        }
        if !relationContains(article) { values.append(article.slug) }
        row.value = values.joined(separator: ", ")
    }

    private var relationKeys: [String] {
        rows.filter { $0.kind == .relation && NativeArticleProperties.isValidKey($0.key) }.map(\.key)
    }

    private var targetPropertyKeys: [String] {
        Array(Set(articles.flatMap { $0.properties.keys })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var rollupSpecification: NativeArticleRollupSpecification? {
        NativeArticleRollupSpecification(row.value)
    }

    private var rollupRelationBinding: Binding<String> {
        Binding(
            get: { rollupSpecification?.relationKey ?? relationKeys.first ?? "" },
            set: { updateRollup(relationKey: $0) }
        )
    }

    private var rollupTargetBinding: Binding<String> {
        Binding(
            get: { rollupSpecification?.targetKey ?? "" },
            set: { updateRollup(targetKey: $0) }
        )
    }

    private var rollupCalculationBinding: Binding<NativeArticleRollupCalculation> {
        Binding(
            get: { rollupSpecification?.calculation ?? .count },
            set: { updateRollup(calculation: $0) }
        )
    }

    private func updateRollup(
        relationKey: String? = nil,
        targetKey: String? = nil,
        calculation: NativeArticleRollupCalculation? = nil
    ) {
        let relation = relationKey ?? rollupSpecification?.relationKey ?? relationKeys.first ?? ""
        let target = targetKey ?? rollupSpecification?.targetKey ?? ""
        let operation = calculation ?? rollupSpecification?.calculation ?? .count
        row.value = "\(relation) | \(target) | \(operation.rawValue)"
    }
}

struct EditorPropertyRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let oldKey: String
    let isRenaming: Bool
    let onRename: (String) -> Void
    @State private var newKey: String

    init(oldKey: String, isRenaming: Bool, onRename: @escaping (String) -> Void) {
        self.oldKey = oldKey
        self.isRenaming = isRenaming
        self.onRename = onRename
        _newKey = State(initialValue: oldKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("统一重命名属性").font(.title3.weight(.semibold))
            Text("所有文章中的“\(oldKey)”都会一起修改；如果目标名称已有不同值，操作会取消，不会覆盖数据。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("新属性名", text: $newKey).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("全部重命名") {
                    onRename(newKey.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isRenaming
                        || !NativeArticleProperties.isValidKey(newKey)
                        || newKey.caseInsensitiveCompare(oldKey) == .orderedSame
                )
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct EditorWikiLink: Identifiable {
    let id: String
    let reference: NativeArticleLink.Reference
    let destination: NativeArticleLinkDestination
}

struct EditorDocumentAnalysis: @unchecked Sendable {
    let source: String
    let document: NativeMarkdownArticleDocument
    let wikiReferences: [NativeArticleLink.Reference]
    let wordCount: Int

    static let empty = EditorDocumentAnalysis(source: "")

    init(source: String) {
        self.source = source
        document = NativeMarkdownArticleDocumentCache.shared.document(for: source)
        wikiReferences = NativeArticleLink.parsedReferences(in: source)
        wordCount = NativeWritingMetrics.characterCount(of: source)
    }
}

@MainActor
final class EditorDocumentAnalysisModel: ObservableObject {
    @Published private(set) var value = EditorDocumentAnalysis.empty
    private var task: Task<Void, Never>?
    private var generation = 0

    func update(source: String, debounce: Bool = true) {
        if source == value.source {
            generation += 1
            task?.cancel()
            return
        }
        generation += 1
        let requestedGeneration = generation
        task?.cancel()
        task = Task { [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled else { return }
            let analysis = await Task.detached(priority: .userInitiated) {
                EditorDocumentAnalysis(source: source)
            }.value
            guard !Task.isCancelled,
                  let self,
                  requestedGeneration == self.generation else { return }
            self.value = analysis
        }
    }

    deinit { task?.cancel() }
}

import AppKit
import SwiftUI

struct QAndAView: View {
    @ObservedObject var model: NativeAppModel
    @State private var isPresentingQuestionComposer = false
    @State private var detailQuestionID: String?

    var body: some View {
        VStack(spacing: 0) {
            if detailQuestionID != nil, model.selectedQuestion?.id == detailQuestionID {
                detailHeader
                Divider()
                QuestionDetailView(model: model) { tag in
                    model.selectQuestionTag(tag)
                    detailQuestionID = nil
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                filters
                Divider()
                listContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isPresentingQuestionComposer) {
            QuestionComposerSheet(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("问答")
                    .font(.system(size: 28, weight: .bold))
                Text("发布问题，围绕问题沉淀答案")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.totalQuestionCount) 个问题")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                isPresentingQuestionComposer = true
            } label: {
                Label("发布问题", systemImage: "plus.bubble.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isPublishingQuestion || model.isBackingUp)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var detailHeader: some View {
        HStack(spacing: 14) {
            Button {
                detailQuestionID = nil
            } label: {
                Label("问题列表", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("返回问题列表")

            Divider()
                .frame(height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("问答 · 问题详情")
                    .font(.headline)
                Text("阅读回答或写下你的答案")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let question = model.selectedQuestion {
                Label("\(question.answerCount) 个回答", systemImage: "text.bubble")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                isPresentingQuestionComposer = true
            } label: {
                Label("发布问题", systemImage: "plus.bubble")
            }
            .disabled(model.isPublishingQuestion || model.isBackingUp)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("搜索问题标题、正文或标签", text: $model.questionSearchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.questionSearchText) { _ in
                        model.refreshQuestionList(after: 0.25)
                    }

                Menu {
                    Button {
                        model.selectQuestionTag(nil)
                    } label: {
                        if model.selectedQuestionTag == nil {
                            Label("全部标签", systemImage: "checkmark")
                        } else {
                            Text("全部标签")
                        }
                    }
                    if !model.questionTagFacets.isEmpty { Divider() }
                    ForEach(model.questionTagFacets) { facet in
                        Button {
                            model.selectQuestionTag(facet.tag)
                        } label: {
                            if facet.tag.caseInsensitiveCompare(model.selectedQuestionTag ?? "") == .orderedSame {
                                Label("\(facet.tag) · \(facet.count)", systemImage: "checkmark")
                            } else {
                                Text("\(facet.tag) · \(facet.count)")
                            }
                        }
                    }
                } label: {
                    Label(model.selectedQuestionTag ?? "全部标签", systemImage: "tag")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if model.isFilteringQuestions {
                    Button("清除") { model.clearQuestionFilters() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }

            if !model.questionTagFacets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.questionTagFacets) { facet in
                            let isSelected = facet.tag.caseInsensitiveCompare(model.selectedQuestionTag ?? "") == .orderedSame
                            Button {
                                model.selectQuestionTag(isSelected ? nil : facet.tag)
                            } label: {
                                HStack(spacing: 5) {
                                    Text(facet.tag)
                                    Text("\(facet.count)")
                                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                                }
                            }
                            .buttonStyle(QuestionTagButtonStyle(isSelected: isSelected))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var listContent: some View {
        if model.questions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: model.isFilteringQuestions ? "magnifyingglass" : "questionmark.bubble")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(model.isFilteringQuestions ? "没有找到符合条件的问题" : "还没有问题")
                    .font(.title3.weight(.semibold))
                Text(model.isFilteringQuestions ? "换一个标签或搜索词试试" : "发布第一个问题，其他人可以进入问题详情回答。")
                    .foregroundStyle(.secondary)
                if !model.isFilteringQuestions {
                    Button("发布问题") { isPresentingQuestionComposer = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            questionList
        }
    }

    private var questionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.isFilteringQuestions ? "筛选结果" : "全部问题")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(model.questions.count) 条")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                ForEach(model.questions) { question in
                    Button {
                        if model.selectQuestion(question) {
                            detailQuestionID = question.id
                        }
                    } label: {
                        QuestionListRow(question: question)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.32))
    }
}

private struct QuestionListRow: View {
    let question: NativeQuestion
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(question.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !question.body.isEmpty {
                    Text(question.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 8) {
                    ForEach(question.tags.prefix(4), id: \.self) { tag in
                        Text(tag)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.09), in: Capsule())
                    }
                    if question.tags.count > 4 {
                        Text("+\(question.tags.count - 4)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(question.createdAt.nativeDateLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Label("\(question.answerCount) 个回答", systemImage: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(
                    isHovered ? Color.accentColor : Color(nsColor: .tertiaryLabelColor)
                )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHovered ? Color.accentColor.opacity(0.07) : Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isHovered ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.07))
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onHover { isHovered = $0 }
    }
}

private enum QuestionAnswerComposerMode: String, CaseIterable, Identifiable {
    case edit
    case preview

    var id: String { rawValue }
    var title: String { self == .edit ? "编辑" : "预览" }
    var systemImage: String { self == .edit ? "chevron.left.forwardslash.chevron.right" : "eye" }
}

private struct QuestionDetailView: View {
    @ObservedObject var model: NativeAppModel
    let onSelectTag: (String) -> Void
    @StateObject private var answerEditorController = MomentRichTextController()
    @State private var answerComposerMode = QuestionAnswerComposerMode.edit

    var body: some View {
        if let question = model.selectedQuestion {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    questionHeader(question)
                    Divider()
                    answersSection
                    answerComposer
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            Text("选择一个问题查看答案")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func questionHeader(_ question: NativeQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(question.title)
                .font(.system(size: 26, weight: .bold))
                .textSelection(.enabled)
            if !question.body.isEmpty {
                Text(question.body)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                ForEach(question.tags, id: \.self) { tag in
                    Button {
                        onSelectTag(tag)
                    } label: {
                        Label(tag, systemImage: "tag.fill")
                    }
                    .buttonStyle(QuestionTagButtonStyle(
                        isSelected: tag.caseInsensitiveCompare(model.selectedQuestionTag ?? "") == .orderedSame
                    ))
                }
                Spacer()
                Text(question.createdAt.nativeDateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var answersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(model.questionAnswers.count) 个回答")
                .font(.title3.weight(.semibold))
            if model.isLoadingQuestionAnswers {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在加载回答…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if model.questionAnswers.isEmpty {
                Text("还没有回答。写下第一个答案吧。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(model.questionAnswers.enumerated()), id: \.element.id) { index, answer in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("回答 \(index + 1)", systemImage: "person.crop.circle")
                                    .font(.callout.weight(.medium))
                                Spacer()
                                if answer.updatedAt != answer.createdAt {
                                    Text("已编辑")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(answer.createdAt.nativeDateLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    model.beginEditingQuestionAnswer(answer)
                                    answerComposerMode = .edit
                                } label: {
                                    Label(
                                        model.editingQuestionAnswerID == answer.id ? "正在编辑" : "编辑",
                                        systemImage: "pencil"
                                    )
                                }
                                .buttonStyle(.borderless)
                                .disabled(
                                    model.isPublishingQuestionAnswer
                                        || model.isUploadingMedia
                                        || model.isBackingUp
                                )
                            }
                            if !answer.body.isEmpty {
                                MarkdownArticleBody(
                                    body: answer.body,
                                    store: model.store,
                                    articleLinks: model.articles,
                                    onOpenArticle: model.openArticleLink
                                )
                            }
                            if !answer.images.isEmpty {
                                QuestionAnswerImageGrid(
                                    images: answer.images,
                                    store: model.store,
                                    onOpen: model.openMedia
                                )
                            }
                        }
                        .padding(16)
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.12))
                        }
                        .shadow(
                            color: Color.black.opacity(0.05),
                            radius: 4,
                            y: 2
                        )
                    }
                }
            }
        }
    }

    private var answerComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    model.editingQuestionAnswerID == nil ? "写回答" : "编辑回答",
                    systemImage: model.editingQuestionAnswerID == nil ? "square.and.pencil" : "pencil"
                )
                .font(.title3.weight(.semibold))
                Spacer()
                Picker("回答模式", selection: $answerComposerMode) {
                    ForEach(QuestionAnswerComposerMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            if answerComposerMode == .edit {
                ZStack(alignment: .topLeading) {
                    if model.questionAnswerDraft.body.isEmpty {
                        Text("使用 Markdown 写下你的回答…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 13)
                            .allowsHitTesting(false)
                    }
                    MomentRichTextEditor(
                        text: $model.questionAnswerDraft.body,
                        textRuns: $model.questionAnswerDraft.textRuns,
                        controller: answerEditorController,
                        onPasteImages: model.uploadQuestionAnswerPastedImages,
                        maximumLength: 10_000
                    )
                }
                .frame(minHeight: 170)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12))
                }
            } else {
                Group {
                    if model.questionAnswerDraft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "text.document")
                                .font(.title2)
                            Text("输入 Markdown 后可在这里预览")
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        MarkdownArticleBody(
                            body: model.questionAnswerDraft.body,
                            store: model.store,
                            articleLinks: model.articles,
                            onOpenArticle: model.openArticleLink
                        )
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12))
                }
            }

            if !model.questionAnswerDraft.images.isEmpty {
                QuestionAnswerImageGrid(
                    images: model.questionAnswerDraft.images,
                    store: model.store,
                    onOpen: model.openMedia,
                    onRemove: model.removeQuestionAnswerImage
                )
            }

            HStack {
                Label("支持 Markdown；可直接粘贴或拖入图片，最多 9 张", systemImage: "text.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isUploadingMedia {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在保存图片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.questionAnswerDraft.body.count) / 10000")
                    .font(.caption)
                    .foregroundStyle(model.questionAnswerDraft.body.count > 10_000 ? .red : .secondary)
                if model.editingQuestionAnswerID != nil {
                    Button("取消编辑") {
                        model.cancelQuestionAnswerEditing()
                        answerComposerMode = .edit
                    }
                    .disabled(model.isPublishingQuestionAnswer || model.isUploadingMedia)
                }
                Button {
                    Task {
                        _ = await model.publishQuestionAnswer()
                    }
                } label: {
                    if model.isPublishingQuestionAnswer {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(
                            model.editingQuestionAnswerID == nil ? "发布回答" : "保存修改",
                            systemImage: model.editingQuestionAnswerID == nil ? "paperplane.fill" : "checkmark"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.questionAnswerDraft.isEmpty
                        || model.questionAnswerDraft.body.count > 10_000
                        || model.isPublishingQuestionAnswer
                        || model.isUploadingMedia
                        || model.isBackingUp
                )
            }
        }
        .padding(18)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct QuestionComposerSheet: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var tagsText = ""

    private var parsedTags: [String] { NativeQuestionTag.parse(tagsText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发布问题")
                    .font(.title2.weight(.bold))
                Text("把问题描述清楚，并添加便于检索的标签。")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("问题标题").font(.headline)
                TextField("一句话说明你想问什么", text: $title)
                    .textFieldStyle(.roundedBorder)
                Text("\(title.count) / 200")
                    .font(.caption)
                    .foregroundStyle(title.count > 200 ? .red : .secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("问题描述（可选）").font(.headline)
                TextEditor(text: $bodyText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(minHeight: 150)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12)) }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("标签").font(.headline)
                TextField("例如：Swift, macOS, 产品设计", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                Text("用逗号分隔，最多 8 个标签，每个标签最多 30 个字符。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !parsedTags.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(parsedTags, id: \.self) { tag in
                            Label(tag, systemImage: "tag.fill")
                                .font(.caption)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        if await model.publishQuestion(title: title, body: bodyText, tagsText: tagsText) {
                            dismiss()
                        }
                    }
                } label: {
                    if model.isPublishingQuestion {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("发布")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || title.count > 200
                        || model.isPublishingQuestion
                        || model.isBackingUp
                )
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

private struct QuestionAnswerImageGrid: View {
    let images: [NativeMedia]
    let store: LocalBlogStore
    let onOpen: (NativeMedia) -> Void
    var onRemove: ((NativeMedia) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(images) { media in
                ZStack(alignment: .topTrailing) {
                    Button {
                        onOpen(media)
                    } label: {
                        QuestionAnswerImage(media: media, store: store)
                    }
                    .buttonStyle(.plain)
                    .help("打开原图")

                    if let onRemove {
                        Button {
                            onRemove(media)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .padding(7)
                        .help("移除图片")
                    }
                }
            }
        }
    }
}

private struct QuestionAnswerImage: View {
    let media: NativeMedia
    let store: LocalBlogStore
    @State private var image: NSImage?
    @State private var didFinishLoading = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if didFinishLoading {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08))
        }
        .task(id: media.url) {
            image = nil
            didFinishLoading = false
            guard let url = await store.mediaURL(for: media.url) else {
                didFinishLoading = true
                return
            }
            let result = await NativeImagePipeline.shared.image(
                from: url,
                mode: .thumbnail(maxPixelSize: 720)
            )
            guard !Task.isCancelled else { return }
            image = result.image
            didFinishLoading = true
        }
        .accessibilityLabel(media.name.isEmpty ? "回答图片" : media.name)
    }
}

private struct QuestionTagButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor : Color.accentColor.opacity(configuration.isPressed ? 0.18 : 0.1),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

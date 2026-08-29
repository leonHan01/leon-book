import SwiftUI

struct ZhihuView: View {
    @ObservedObject var model: NativeAppModel
    @State private var isPresentingQuestionComposer = false

    var body: some View {
        VStack(spacing: 0) {
            header
            filters
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isPresentingQuestionComposer) {
            QuestionComposerSheet(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("知乎")
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
    private var content: some View {
        if model.questions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: model.isFilteringQuestions ? "magnifyingglass" : "questionmark.bubble")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(model.isFilteringQuestions ? "没有找到符合条件的问题" : "还没有问题")
                    .font(.title3.weight(.semibold))
                Text(model.isFilteringQuestions ? "换一个标签或搜索词试试" : "发布第一个问题，答案会集中显示在问题下方。")
                    .foregroundStyle(.secondary)
                if !model.isFilteringQuestions {
                    Button("发布问题") { isPresentingQuestionComposer = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                questionList
                    .frame(minWidth: 280, idealWidth: 350, maxWidth: 440)
                QuestionDetailView(model: model)
                    .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var questionList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.questions) { question in
                    Button {
                        model.selectQuestion(question)
                    } label: {
                        QuestionListRow(
                            question: question,
                            isSelected: model.selectedQuestion?.id == question.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }
}

private struct QuestionListRow: View {
    let question: NativeQuestion
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(question.title)
                .font(.headline)
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
            HStack(spacing: 7) {
                ForEach(question.tags.prefix(2), id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                if question.tags.count > 2 {
                    Text("+\(question.tags.count - 2)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Label("\(question.answerCount)", systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.07))
        }
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct QuestionDetailView: View {
    @ObservedObject var model: NativeAppModel
    @State private var answerBody = ""

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
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: question.id) { _ in answerBody = "" }
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
                        model.selectQuestionTag(tag)
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
            if model.questionAnswers.isEmpty {
                Text("还没有回答。写下第一个答案吧。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(model.questionAnswers.enumerated()), id: \.element.id) { index, answer in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("回答 \(index + 1)", systemImage: "person.crop.circle")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text(answer.createdAt.nativeDateLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(answer.body)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.07))
                    }
                }
            }
        }
    }

    private var answerComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("写回答", systemImage: "square.and.pencil")
                .font(.title3.weight(.semibold))
            ZStack(alignment: .topLeading) {
                if answerBody.isEmpty {
                    Text("分享你的知识、经验和判断…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $answerBody)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(2)
            }
            .frame(minHeight: 130)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12))
            }
            HStack {
                Text("\(answerBody.count) / 10000")
                    .font(.caption)
                    .foregroundStyle(answerBody.count > 10_000 ? .red : .secondary)
                Spacer()
                Button {
                    Task {
                        if await model.publishQuestionAnswer(body: answerBody) {
                            answerBody = ""
                        }
                    }
                } label: {
                    if model.isPublishingQuestionAnswer {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("发布回答", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    answerBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || answerBody.count > 10_000
                        || model.isPublishingQuestionAnswer
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

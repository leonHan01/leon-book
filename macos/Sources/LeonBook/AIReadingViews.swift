import AppKit
import SwiftUI

private struct AIReadingModelPicker: View {
    @Binding var configuration: AIReadingConfiguration
    let account: AIReadingAccountStore
    var enteredKey: () -> String = { "" }
    @State private var models: [String] = []
    @State private var hasCatalog = false
    @State private var isFetching = false
    @State private var error: String?

    private var choices: [String] {
        if hasCatalog { return models }
        return [configuration.openAIModel].filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if configuration.provider == .deepSeek {
                    Picker("模型", selection: .constant("deepseek-flash")) {
                        Text("deepseek-flash").tag("deepseek-flash")
                    }
                    .pickerStyle(.menu)
                } else {
                    Picker("模型", selection: $configuration.openAIModel) {
                        if choices.isEmpty { Text("暂无可用模型").tag("") }
                        ForEach(choices, id: \.self) { model in Text(model).tag(model) }
                    }
                    .pickerStyle(.menu)
                    .disabled(choices.isEmpty)
                    Button {
                        Task { await refresh(useEnteredKey: true) }
                    } label: {
                        NativeIcon.image("arrow.clockwise", size: 13)
                    }
                    .buttonStyle(.borderless).help("刷新模型列表").disabled(isFetching)
                    if isFetching { ProgressView().controlSize(.small) }
                }
            }
            if configuration.provider == .openAI, let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: configuration.provider) {
            loadCachedModels()
            if configuration.provider == .openAI { await refresh(useEnteredKey: false) }
        }
    }

    private func loadCachedModels() {
        if let cached = account.loadOpenAIModels() {
            models = cached
            hasCatalog = true
            if !cached.contains(configuration.openAIModel) { configuration.openAIModel = cached.first ?? "" }
        }
    }

    private func refresh(useEnteredKey: Bool) async {
        guard !isFetching, configuration.provider == .openAI else { return }
        let key: String
        do {
            let supplied = useEnteredKey ? enteredKey() : ""
            key = supplied.isEmpty ? try account.key(for: .openAI) : supplied
        } catch {
            self.error = NativeLocalization.text("保存 API Key 后可刷新模型列表。")
            return
        }
        isFetching = true
        defer { isFetching = false }
        do {
            let available = try await AIReadingClient().models(key: key)
            try Task.checkCancellation()
            guard configuration.provider == .openAI else { return }
            account.saveOpenAIModels(available)
            models = available
            hasCatalog = true
            if !available.contains(configuration.openAIModel) { configuration.openAIModel = available.first ?? "" }
            error = available.isEmpty ? NativeLocalization.text("当前账号没有可用的文字模型，请检查 API 权限后刷新。") : nil
        } catch {
            guard !Task.isCancelled, configuration.provider == .openAI else { return }
            self.error = error.localizedDescription
        }
    }
}

struct AIReadingSettingsPanel: View {
    let account: AIReadingAccountStore
    @State private var config = AIReadingConfiguration()
    @State private var key = ""
    @State private var status: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("AI 服务", selection: $config.provider) {
                ForEach(AIReadingProvider.allCases) { provider in Text(provider.title).tag(provider) }
            }
            AIReadingModelPicker(configuration: $config, account: account, enteredKey: { key })
            SecureField("API Key（留空保留已保存值）", text: $key)
            Text("发送时会把当前文章或问题正文及聊天记录发送给所选 AI 服务。密钥保存在本机钥匙串，聊天记录保存在当前资料库。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存 AI 设置") {
                    do {
                        _ = try config.validated()
                        if !key.isEmpty { try account.saveKey(key, for: config.provider) }
                        else { _ = try account.key(for: config.provider) }
                        try account.saveConfiguration(config)
                        key = ""; failed = false
                        status = NativeLocalization.text("AI 设置已保存。")
                    } catch { failed = true; status = error.localizedDescription }
                }
                Button("移除当前密钥", role: .destructive) {
                    do {
                        try account.forgetKey(for: config.provider)
                        key = ""; failed = false
                        status = NativeLocalization.text("当前服务的密钥已移除。")
                    } catch { failed = true; status = error.localizedDescription }
                }
            }
            if let status { Text(status).font(.caption).foregroundStyle(failed ? Color.red : .secondary).textSelection(.enabled) }
        }
        .onAppear { config = account.load() }
        .onChange(of: config.provider) { _ in key = ""; status = nil }
    }

}

private struct AIReadingExport: Identifiable {
    let id: String
    var text: String
}

struct AIReadingChatView: View {
    @Environment(\.nativeAppPalette) private var palette
    @ObservedObject var model: NativeAppModel
    let context: AIReadingContext
    @StateObject private var chat: AIReadingChat
    @State private var showsSettings = false
    @State private var confirmsClear = false
    @State private var pendingExport: AIReadingExport?
    @State private var isExporting = false
    @State private var saveStatus: String?
    @State private var modelPickerRevision = 0

    init(model: NativeAppModel, context: AIReadingContext) {
        self.model = model; self.context = context
        _chat = StateObject(wrappedValue: AIReadingChat(store: model.store, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .background(palette.sidebar)
        .task { await chat.load() }
        .onDisappear { chat.stop() }
        .onChange(of: chat.configuration) { value in try? chat.account.saveConfiguration(value) }
        .sheet(isPresented: $showsSettings, onDismiss: {
            chat.configuration = chat.account.load()
            modelPickerRevision += 1
        }) {
            VStack(alignment: .leading, spacing: 20) {
                Text("AI 阅读设置").font(.title2.weight(.semibold))
                AIReadingSettingsPanel(account: chat.account)
                HStack { Spacer(); Button("完成") { showsSettings = false }.keyboardShortcut(.cancelAction) }
            }
            .padding(24).frame(width: 610)
        }
        .sheet(item: $pendingExport) { export in
            AIReadingExportSheet(context: context, text: export.text) { text in
                try await model.saveAIReadingOutput(text, context: context, sourceStore: chat.store)
                chat.exportedIDs.insert(export.id)
                saveStatus = savedMessage
            }
        }
        .confirmationDialog("清空当前内容的聊天记录？", isPresented: $confirmsClear) {
            Button("清空聊天", role: .destructive) { Task { await chat.clear(); saveStatus = nil } }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI 阅读助手", nativeIcon: "sparkles").font(.headline)
                Spacer()
                Button { showsSettings = true } label: { NativeIcon.image("gearshape", size: 14) }
                    .buttonStyle(.borderless).help("AI 阅读设置").disabled(chat.isSending)
                Menu {
                    Button(LocalizedStringKey(context.exportTitle)) {
                        export(AIReadingMessage.transcript(chat.messages), id: "all:" + (chat.messages.last?.id ?? ""))
                    }
                    .disabled(chat.messages.isEmpty || chat.isSending || isExporting)
                    Button("清空聊天", role: .destructive) { confirmsClear = true }
                        .disabled(chat.messages.isEmpty || chat.isSending || chat.isLoading || isExporting)
                } label: { NativeIcon.image("ellipsis", size: 14) }
                .menuStyle(.borderlessButton).fixedSize()
                .help("聊天操作")
            }
            Picker("AI 服务", selection: $chat.configuration.provider) {
                ForEach(AIReadingProvider.allCases) { provider in Text(provider.title).tag(provider) }
            }
            .pickerStyle(.segmented).disabled(chat.isSending)
            AIReadingModelPicker(configuration: $chat.configuration, account: chat.account)
                .id(modelPickerRevision)
                .font(.caption).disabled(chat.isSending)
            Label(context.title, nativeIcon: context.kind == .article ? "doc.text" : "questionmark.bubble", iconSize: 11)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(context.title)
            Button {
                export(AIReadingMessage.transcript(chat.messages), id: "all:" + (chat.messages.last?.id ?? ""))
            } label: {
                Label("转存整段聊天", nativeIcon: "text.badge.plus", iconSize: 12)
            }
            .font(.caption).buttonStyle(.borderless)
            .disabled(chat.messages.isEmpty || chat.isSending || isExporting
                      || chat.exportedIDs.contains("all:" + (chat.messages.last?.id ?? "")))
        }
        .padding(12)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.isLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
                    } else if chat.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("围绕当前内容提问、梳理观点或解释难点。")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(["概括核心观点", "解释难懂的地方", "有哪些值得质疑的观点？"], id: \.self) { suggestion in
                                Button(LocalizedStringKey(suggestion)) { chat.draft = NativeLocalization.string(suggestion, language: NativeLocalization.currentLanguage) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    ForEach(chat.messages) { message in messageView(message) }
                    if chat.isSending {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.mini)
                                Text("AI 正在回复…").font(.caption).foregroundStyle(.secondary)
                            }
                            if !chat.streamingText.isEmpty { Text(chat.streamingText).font(.callout).textSelection(.enabled) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(12)
            }
            .onChange(of: chat.messages.count) { _ in proxy.scrollTo("latest", anchor: .bottom) }
            .onChange(of: chat.streamingText) { _ in proxy.scrollTo("latest", anchor: .bottom) }
            .onChange(of: chat.isLoading) { loading in if !loading { proxy.scrollTo("latest", anchor: .bottom) } }
        }
    }

    private func messageView(_ message: AIReadingMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.role == .user ? NativeLocalization.text("我") : message.provider.title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if !message.isComplete { Text("回复未完成").font(.caption2).foregroundStyle(.secondary) }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                } label: { NativeIcon.image("doc.on.doc", size: 11) }
                .buttonStyle(.borderless).help("复制")
            }
            Text(LocalizedStringKey(message.content)).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.role == .assistant {
                HStack {
                    Text(message.model).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if chat.exportedIDs.contains(message.id) {
                        Label("已转存", nativeIcon: "checkmark", iconSize: 10).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Button(LocalizedStringKey(context.exportTitle)) { export(message.content, id: message.id) }
                            .buttonStyle(.borderless).font(.caption)
                            .disabled(isExporting || chat.isSending)
                    }
                }
            }
        }
        .padding(11)
        .background(message.role == .user ? Color.accentColor.opacity(0.08) : palette.surface,
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = chat.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if chat.messages.last?.role == .user, !chat.isSending {
                    Button("重试回复") { chat.send(context: context, retry: true) }.font(.caption)
                }
            }
            if let saveStatus { Text(saveStatus).font(.caption).foregroundStyle(.secondary) }
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text("向 AI 提问…").foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $chat.draft).font(.callout).scrollContentBackground(.hidden)
                    .padding(2).frame(minHeight: 65, maxHeight: 110)
            }
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border) }
            .disabled(chat.isLoading || chat.isSending)
            HStack {
                Text("包含当前正文与聊天上下文").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if chat.isSending {
                    Button("停止") { chat.stop() }.controlSize(.small)
                } else {
                    Button("发送") { chat.send(context: context) }
                        .nativePrimaryButton().controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(chat.isLoading || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
    }

    private var savedMessage: String {
        context.kind == .article ? NativeLocalization.text("已保存为文章评论。") : NativeLocalization.text("已保存为问题回答。")
    }

    private func export(_ text: String, id: String) {
        guard !isExporting, !chat.exportedIDs.contains(id) else { return }
        if text.count > context.exportLimit {
            pendingExport = .init(id: id, text: text)
            return
        }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                try await model.saveAIReadingOutput(text, context: context, sourceStore: chat.store)
                chat.exportedIDs.insert(id)
                saveStatus = savedMessage
                chat.error = nil
            } catch { chat.error = error.localizedDescription }
        }
    }
}

private struct AIReadingExportSheet: View {
    let context: AIReadingContext
    @State var text: String
    let onSave: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(context.exportTitle)).font(.title2.weight(.semibold))
            Text(context.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Text("内容超过字数限制，请编辑后保存。") .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).frame(minHeight: 270)
                .border(Color.secondary.opacity(0.2))
            Text("\(text.count)/\(context.exportLimit)").font(.caption.monospacedDigit())
                .foregroundStyle(text.count > context.exportLimit ? Color.red : .secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("保存") {
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        do { try await onSave(text); dismiss() } catch { self.error = error.localizedDescription }
                    }
                }
                .nativePrimaryButton().disabled(isSaving || text.count > context.exportLimit || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 610).disabled(isSaving).interactiveDismissDisabled(isSaving)
    }
}

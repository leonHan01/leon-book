import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MentionEditorState: ObservableObject {
    @Published var visible = false
    @Published var candidates: [AgentInfo] = []
    @Published var selectedIndex = 0
    @Published var commandMode = false
    @Published var commandCandidates: [ChatCommand] = []
    var onCommand: ((ChatCommand) -> Void)?
    weak var editor: NSTextView?
    var eligible: [AgentInfo] = []
    var group = false
    var conversationId = ""
    private var currentKey = ""
    private var dismissedKey = ""
    private var candidateKey = ""

    func refresh() {
        guard let editor, editor.window?.firstResponder === editor, !editor.hasMarkedText() else { hide(); return }
        if let query = ChatCommand.query(in: editor.string, selection: editor.selectedRange()) {
            let key = "\(conversationId):command:\(query)"
            guard key != dismissedKey else { hide(); return }
            if key != currentKey { selectedIndex = 0 }
            currentKey = key
            let matching = ChatCommand.matching(query)
            if commandCandidates != matching { commandCandidates = matching }
            if !commandMode { commandMode = true }
            if !visible { visible = true }
            return
        }
        if commandMode { commandMode = false }
        guard group, let token = MentionCompletion.token(in: editor.string, selection: editor.selectedRange()) else {
            hide(); dismissedKey = ""; currentKey = ""; return
        }
        let key = "\(conversationId):\(token.range):\(editor.selectedRange().location):\(token.query)"
        guard key != dismissedKey else { hide(); return }
        let matching = Array(eligible.filter { MentionCompletion.matches(name: $0.name, handle: $0.handle, query: token.query) }.prefix(8))
        if key != currentKey { selectedIndex = 0 }
        currentKey = key
        let signature = matching.map { "\($0.id):\($0.name):\($0.handle):\($0.avatarId ?? "")" }.joined(separator: "|")
        if signature != candidateKey { candidateKey = signature; candidates = matching }
        if selectedIndex >= candidates.count, selectedIndex != 0 { selectedIndex = 0 }
        if !visible { visible = true }
    }
    func hide(dismiss: Bool = false) {
        if dismiss { dismissedKey = currentKey }
        if visible { visible = false }
    }
    func choose(_ index: Int) {
        if commandMode {
            guard commandCandidates.indices.contains(index), let editor, !editor.hasMarkedText(),
                  let query = ChatCommand.query(in: editor.string, selection: editor.selectedRange()),
                  ChatCommand.matching(query).contains(commandCandidates[index]) else { return }
            let command = commandCandidates[index]
            editor.window?.makeFirstResponder(editor)
            editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            hide(); currentKey = ""; dismissedKey = ""
            onCommand?(command)
            return
        }
        guard candidates.indices.contains(index), let editor, !editor.hasMarkedText(),
              let token = MentionCompletion.token(in: editor.string, selection: editor.selectedRange()),
              eligible.contains(where: { $0.id == candidates[index].id }),
              MentionCompletion.matches(name: candidates[index].name, handle: candidates[index].handle, query: token.query) else { return }
        let selected = candidates[index]
        let result = MentionCompletion.replacing(token, in: editor.string, with: selected.handle)
        editor.window?.makeFirstResponder(editor)
        editor.insertText(result.insertion, replacementRange: token.range)
        editor.setSelectedRange(NSRange(location: result.caret, length: 0))
        hide(); currentKey = ""; dismissedKey = ""
    }
    func command(_ selector: Selector) -> Bool {
        guard let editor, !editor.hasMarkedText() else { return false }
        refresh()
        guard visible else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { hide(dismiss: true); return true }
        let count = commandMode ? commandCandidates.count : candidates.count
        guard count > 0 else { return false }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            selectedIndex = (selectedIndex + delta + count) % count; return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:)) {
            choose(selectedIndex); return true
        }
        return false
    }
}

final class ComposerTextView: NSTextView {
    var send: (() -> Void)?
    var confirmMention: (() -> Bool)?
    var focusChanged: (() -> Void)?
    var pastedImages: (([Data]) -> Void)?
    var imagePasteboard: NSPasteboard = .general
    override func paste(_ sender: Any?) {
        let images = ChatImagePasteboard.images(in: imagePasteboard)
        if !images.isEmpty { pastedImages?(images); return }
        super.paste(sender)
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !hasMarkedText(), [36, 76].contains(event.keyCode), modifiers.isEmpty || modifiers == .command {
            guard !event.isARepeat else { return }
            if modifiers.isEmpty, confirmMention?() == true { return }
            send?(); return
        }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); focusChanged?(); return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); focusChanged?(); return result }
    override func unmarkText() { super.unmarkText(); focusChanged?() }
}

private struct NativeMentionEditor: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var state: MentionEditorState
    let agents: [AgentInfo]
    let group: Bool
    let conversationId: String
    let onSend: () -> Void
    let onImages: ([Data]) -> Void
    let onCommand: (ChatCommand) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = ComposerTextView(frame: .zero)
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14); editor.textColor = .textColor
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 82)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 82)
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = .width; editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.setAccessibilityLabel("消息")
        editor.string = text; editor.delegate = context.coordinator
        scroll.documentView = editor; state.editor = editor; state.onCommand = onCommand
        let coordinator = context.coordinator
        editor.focusChanged = { [weak coordinator] in coordinator?.scheduleRefresh() }
        editor.send = { [weak coordinator] in coordinator?.parent.onSend() }
        editor.confirmMention = { [weak coordinator] in
            coordinator?.parent.state.command(#selector(NSResponder.insertNewline(_:))) ?? false
        }
        editor.pastedImages = { [weak coordinator] in coordinator?.parent.onImages($0) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        state.onCommand = onCommand; state.editor = editor; state.eligible = agents; state.group = group; state.conversationId = conversationId
        context.coordinator.scheduleRefresh()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeMentionEditor
        private var refreshQueued = false
        init(_ parent: NativeMentionEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; scheduleRefresh()
        }
        func textViewDidChangeSelection(_ notification: Notification) { scheduleRefresh() }
        func textDidEndEditing(_ notification: Notification) { parent.state.hide() }
        func scheduleRefresh() {
            guard !refreshQueued else { return }; refreshQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.refreshQueued = false; self.parent.state.refresh()
            }
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty == false { return false }
            return parent.state.command(commandSelector)
        }
    }
}

struct MentionComposer: View {
    @ObservedObject var store: ChatStore
    @Binding var text: String
    let onSend: () -> Void
    let onCommand: (ChatCommand) -> Void
    @StateObject private var state = MentionEditorState()
    var body: some View {
        VStack(spacing: 8) {
            if state.visible {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(state.commandMode ? "聊天命令" : "提及 Agent").font(.caption.bold())
                        Spacer()
                        Text("↑↓ 选择 · Enter/Tab 确认 · Esc 关闭").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 9).padding(.top, 5)
                    if state.commandMode {
                        if state.commandCandidates.isEmpty { Text("没有匹配的命令").font(.caption).foregroundStyle(.secondary).padding(10) }
                        ForEach(state.commandCandidates.indices, id: \.self) { index in
                            let command = state.commandCandidates[index]
                            Button { state.choose(index) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: command.symbol).frame(width: 30)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("/" + command.rawValue + "  " + command.title).font(.callout)
                                        Text(command.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }.padding(8).background(index == state.selectedIndex ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).accessibilityLabel("/" + command.rawValue + " " + command.title)
                        }
                    } else if state.candidates.isEmpty { Text("没有匹配的 Agent").font(.caption).foregroundStyle(.secondary).padding(10) }
                    else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(state.candidates.indices, id: \.self) { index in
                                        let agent = state.candidates[index]
                                        Button { state.choose(index) } label: {
                                            HStack(spacing: 10) {
                                                AgentAvatarView(store: store, avatarId: agent.avatarId ?? "alfred", size: 30)
                                                Text(agent.name).font(.callout)
                                                Text("@\(agent.handle)").font(.caption).foregroundStyle(.secondary)
                                                Spacer()
                                            }.padding(7).background(index == state.selectedIndex ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                        }.buttonStyle(.plain).id(index)
                                    }
                                }
                            }.frame(height: min(CGFloat(state.candidates.count) * 46, 184))
                                .onChange(of: state.selectedIndex) { proxy.scrollTo($0, anchor: .center) }
                        }
                    }
                }.padding(6).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 12) {
                Button { chooseImages() } label: { Label("选择图片", systemImage: "photo") }
                    .buttonStyle(.borderless).disabled(!store.hasConnection || store.configuring || store.preparingImages || store.draftImages.count >= 4)
                Text(store.preparingImages ? "正在处理图片…" : "可 ⌘V 粘贴图片 · 每条最多 4 张")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if !store.draftImages.isEmpty {
                HStack(spacing: 10) {
                    ForEach(store.draftImages) { attachment in
                        ZStack(alignment: .topTrailing) {
                            if let image = NSImage(data: attachment.data) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 76, height: 64)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                            Button { store.draftImages.removeAll { $0.id == attachment.id } } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                            }.buttonStyle(.plain).help("移除图片")
                        }
                    }
                    Spacer()
                }
            }
            NativeMentionEditor(text: $text, state: state, agents: store.availableAgents,
                group: store.selectedConversation?.kind == "group", conversationId: store.selectedConversationId,
                onSend: onSend, onImages: { images in Task { await store.addImages(images) } },
                onCommand: onCommand)
                .frame(height: 82).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.15)))
        }
        .onChange(of:store.quotedMessage?.id) {_ in if store.quotedMessage != nil,let editor=state.editor {editor.window?.makeFirstResponder(editor)}}
    }
    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "添加图片"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task {
                do {
                    let data = try await Task.detached { try urls.prefix(5).map(ChatImagePasteboard.readFile) }.value
                    await store.addImages(data)
                } catch { store.error = error.localizedDescription }
            }
        }
    }
}

enum ChatImagePasteboard {
    static func readFile(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw ClientError.message("图片文件过大，请选择小于 64 MB 的图片。") }
        return try Data(contentsOf: url)
    }
    static func images(in pasteboard: NSPasteboard) -> [Data] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.prefix(5).filter { url in
                (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
            }.compactMap { try? readFile($0) }
            if !images.isEmpty { return images }
        }
        for type: NSPasteboard.PasteboardType in [.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return [data] }
        }
        return []
    }
}

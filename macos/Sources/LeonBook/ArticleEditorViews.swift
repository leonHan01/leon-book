import AVKit
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private enum ArticleEditorLayout {
    static let contentInset: CGFloat = 20
    static let titleVerticalInset: CGFloat = 20
    static let writingInset: CGFloat = 28
    static let writingWidth: CGFloat = 860
}

enum NativeBodyEditorAppearance {
    case source
    case livePreview
}

@MainActor
final class EditorSlashCommandController: ObservableObject {
    private weak var textView: NSTextView?
    var onExecute: ((NativeCommandDefinition, NSRange) -> Void)?
    @Published private(set) var activeQuery: String?

    func attach(to textView: NSTextView) {
        self.textView = textView
    }

    func completeSuggestion(_ definition: NativeCommandDefinition) {
        guard let textView,
              !textView.hasMarkedText(),
              definition.textInsertion != nil,
              let context = slashContext(in: textView.string, selectedRange: textView.selectedRange()) else {
            return
        }
        onExecute?(definition, context.range)
        activeQuery = nil
        textView.window?.makeFirstResponder(textView)
    }

    func dismissSuggestions() {
        if activeQuery != nil { activeQuery = nil }
    }

    func updateQuery(from textView: NSTextView) {
        let query = textView.hasMarkedText() ? nil
            : slashContext(in: textView.string, selectedRange: textView.selectedRange())?.query
        if activeQuery != query { activeQuery = query }
    }

    private func slashContext(
        in text: String,
        selectedRange: NSRange
    ) -> (range: NSRange, query: String)? {
        guard selectedRange.length == 0, selectedRange.location >= 0 else { return nil }
        let source = text as NSString
        guard selectedRange.location <= source.length else { return nil }
        let lineRange = source.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let prefixRange = NSRange(
            location: lineRange.location,
            length: selectedRange.location - lineRange.location
        )
        let linePrefix = source.substring(with: prefixRange)
        let leadingWhitespace = linePrefix.prefix { $0 == " " || $0 == "\t" }
        let commandText = String(linePrefix.dropFirst(leadingWhitespace.count))
        guard commandText.hasPrefix("/"), !commandText.hasPrefix("//") else { return nil }
        let slashOffset = (String(leadingWhitespace) as NSString).length
        let range = NSRange(
            location: lineRange.location + slashOffset,
            length: selectedRange.location - lineRange.location - slashOffset
        )
        return (range, String(commandText.dropFirst()))
    }
}

struct NativeBodyEditor: NSViewRepresentable {
    @Environment(\.nativeAppPalette) private var appPalette

    @Binding var text: String
    @Binding var selectedRange: NSRange
    let isEditable: Bool
    let linkController: ArticleLinkAutocompleteController
    let slashController: EditorSlashCommandController
    let appearance: NativeBodyEditorAppearance
    let typography: NativeReadingTypography
    let onPasteImage: (NSImage, String) -> Void
    let onRunCommand: (NativeCommandDefinition, NSRange) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let textView = PastingTextView()
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = NSColor(appPalette.surface)
        textView.delegate = context.coordinator
        textView.font = typography.bodyFont.nsFont(size: typography.fontSize)
        textView.isHorizontallyResizable = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.string = text
        textView.textColor = .labelColor
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // The editor itself has a 10-point outer inset and its placeholder has
        // an 18-point inset. Keep the editable glyphs (and therefore caret)
        // on that same 18-point leading edge.
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainer?.widthTracksTextView = true
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.onPasteImage = { [weak textView, weak coordinator = context.coordinator] image, selectedRange in
            guard let textView else { return }
            coordinator?.insertPastedImage(image, at: selectedRange, into: textView)
        }
        linkController.attach(to: textView)
        slashController.attach(to: textView)
        slashController.onExecute = onRunCommand
        context.coordinator.applyStyling(to: textView, immediately: true, editedRange: nil)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        textView.backgroundColor = NSColor(appPalette.surface)
        linkController.attach(to: textView)
        slashController.attach(to: textView)
        slashController.onExecute = onRunCommand
        guard !textView.hasMarkedText() else { return }
        let textChanged = textView.string != text
        if textChanged {
            textView.string = text
        }
        let maximum = (textView.string as NSString).length
        let clampedSelection = NSRange(
            location: min(max(0, selectedRange.location), maximum),
            length: min(max(0, selectedRange.length), max(0, maximum - min(max(0, selectedRange.location), maximum)))
        )
        if textView.selectedRange() != clampedSelection {
            textView.setSelectedRange(clampedSelection)
        }
        if textChanged
            || context.coordinator.lastAppearance != appearance
            || context.coordinator.lastTypography != typography
            || context.coordinator.lastPalette != appPalette {
            context.coordinator.applyStyling(to: textView, immediately: true, editedRange: nil)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelStyling()
        (scrollView.documentView as? NSTextView)?.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeBodyEditor
        fileprivate var lastAppearance: NativeBodyEditorAppearance?
        fileprivate var lastTypography: NativeReadingTypography?
        fileprivate var lastPalette: NativeAppPalette?
        private var styleWorkItem: DispatchWorkItem?
        private var pendingStylingRange: NSRange?

        init(parent: NativeBodyEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.linkController.updateLinkQuery(from: textView)
            parent.slashController.updateQuery(from: textView)
            guard !textView.hasMarkedText() else {
                styleWorkItem?.cancel()
                return
            }
            parent.text = textView.string
            parent.selectedRange = textView.selectedRange()
            let fallbackRange = NSRange(location: textView.selectedRange().location, length: 0)
            applyStyling(
                to: textView,
                immediately: false,
                editedRange: pendingStylingRange ?? fallbackRange
            )
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let replacementLength = ((replacementString ?? "") as NSString).length
            if var pending = pendingStylingRange {
                let delta = replacementLength - affectedCharRange.length
                if NSMaxRange(affectedCharRange) <= pending.location {
                    pending.location = max(0, pending.location + delta)
                }
                pendingStylingRange = NSUnionRange(
                    pending,
                    NSRange(location: affectedCharRange.location, length: replacementLength)
                )
            } else {
                pendingStylingRange = NSRange(
                    location: affectedCharRange.location,
                    length: replacementLength
                )
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.linkController.updateLinkQuery(from: textView)
            parent.slashController.updateQuery(from: textView)
            guard !textView.hasMarkedText(), parent.selectedRange != textView.selectedRange() else { return }
            parent.selectedRange = textView.selectedRange()
        }

        func insertPastedImage(_ image: NSImage, at selectedRange: NSRange, into textView: NSTextView) {
            let placeholder = "[[正在上传图片:\(UUID().uuidString.lowercased())]]"
            textView.insertText(placeholder, replacementRange: selectedRange)
            parent.text = textView.string
            parent.onPasteImage(image, placeholder)
        }

        func applyStyling(
            to textView: NSTextView,
            immediately: Bool,
            editedRange: NSRange?
        ) {
            styleWorkItem?.cancel()
            if !immediately, let editedRange {
                pendingStylingRange = pendingStylingRange.map {
                    NSUnionRange($0, editedRange)
                } ?? editedRange
            }
            let appearance = parent.appearance
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView, !textView.hasMarkedText() else { return }
                let range = immediately ? editedRange : self.pendingStylingRange
                self.pendingStylingRange = nil
                NativeMarkdownLiveStyler.apply(
                    appearance,
                    typography: self.parent.typography,
                    to: textView,
                    editedRange: range,
                    palette: self.parent.appPalette
                )
                self.lastAppearance = appearance
                self.lastTypography = self.parent.typography
                self.lastPalette = self.parent.appPalette
            }
            styleWorkItem = workItem
            if immediately {
                pendingStylingRange = nil
                workItem.perform()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: workItem)
            }
        }

        func cancelStyling() {
            styleWorkItem?.cancel()
            styleWorkItem = nil
            pendingStylingRange = nil
        }
    }
}

private final class PastingTextView: NSTextView {
    var onPasteImage: ((NSImage, NSRange) -> Void)?
    private var requestedInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !requestedInitialFocus else { return }
        requestedInitialFocus = true

        // NSViewRepresentable creates the editor before it has a window. Wait
        // until it is attached, then focus it only if the user has not already
        // chosen another control, such as the article title or excerpt.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditable, let window = self.window,
                  window.firstResponder == nil || window.firstResponder === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for imageType in [.png, .tiff, .fileURL] as [NSPasteboard.PasteboardType] where !types.contains(imageType) {
            types.append(imageType)
        }
        return types
    }

    override func paste(_ sender: Any?) {
        if insertPastedImage(from: .general, at: selectedRange()) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if insertPastedImage(from: .general, at: selectedRange()) { return }
        super.pasteAsPlainText(sender)
    }

    override func readSelection(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        if insertPastedImage(from: pasteboard, at: selectedRange()) { return true }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pastedImage(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropPoint = convert(sender.draggingLocation, from: nil)
        let location = characterIndexForInsertion(at: dropPoint)
        guard insertPastedImage(
            from: sender.draggingPasteboard,
            at: NSRange(location: location, length: 0)
        ) else {
            return super.performDragOperation(sender)
        }
        return true
    }

    @discardableResult
    private func insertPastedImage(from pasteboard: NSPasteboard, at range: NSRange) -> Bool {
        guard let image = pastedImage(from: pasteboard), let onPasteImage else { return false }
        onPasteImage(image, range)
        return true
    }

    private func pastedImage(from pasteboard: NSPasteboard) -> NSImage? {
        // Some apps expose copied images as an NSImage object instead of
        // advertising a concrete PNG/TIFF representation.
        if let image = pasteboard
            .readObjects(forClasses: [NSImage.self])?
            .compactMap({ $0 as? NSImage })
            .first {
            return image
        }

        // Prefer the original image representation so JPEG, HEIC, WebP,
        // and other image formats copied by browsers/design tools work too.
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard let uniformType = UTType(type.rawValue),
                      uniformType.conforms(to: .image),
                      let data = item.data(forType: type),
                      let image = NSImage(data: data) else { continue }
                return image
            }
        }

        // Keep the explicit AppKit fallbacks for screenshots and older apps
        // that provide data lazily through these pasteboard types.
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.lazy.compactMap(NSImage.init(contentsOf:)).first
    }
}

private struct MarkdownPreview: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let analysis: EditorDocumentAnalysis
    let store: LocalBlogStore
    let articleLinks: [NativeArticleSummary]
    let onOpenArticle: (NativeArticleLinkDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("实时预览", nativeIcon: "eye")
                    .font(.headline)
                Spacer()
                Text("随输入更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                if analysis.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 10) {
                        NativeIcon.image("text.document", size: 24)
                            .foregroundStyle(.secondary)
                        Text("开始输入 Markdown")
                            .font(.headline)
                        Text("标题、强调、链接和图片会在这里实时渲染。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    MarkdownArticleBody(
                        document: analysis.document,
                        store: store,
                        articleLinks: articleLinks,
                        onOpenArticle: onOpenArticle
                    )
                        .padding(.vertical, 4)
                }
            }
            .padding(16)
            .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(ArticleEditorLayout.contentInset)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ArticleEditorView: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @ObservedObject private var editorSession: NativeEditorSessionState
    @ObservedObject var workspaceLayout: NativeWorkspaceLayoutState
    @ObservedObject var readingPreferences: NativeReadingPreferences
    @Environment(\.locale) private var locale
    @StateObject private var articleLinkController = ArticleLinkAutocompleteController()
    @StateObject private var slashCommandController = EditorSlashCommandController()
    @StateObject private var documentAnalysis = EditorDocumentAnalysisModel()
    @StateObject private var pageTemplateLibrary = NativeArticlePageTemplateLibrary()
    @State private var isPresentingHistory = false
    @State private var propertyRows: [EditorPropertyRow] = []
    @State private var propertyRenameRequest: EditorPropertyRenameRequest?
    @State private var editorSidebarDragStart: Double?
    @State private var splitDragStart: Double?
    @State private var blockLinkSuggestions: [EditorArticleLinkSuggestion] = []
    @State private var showsWritingReference = false

    init(
        model: NativeAppModel,
        workspaceLayout: NativeWorkspaceLayoutState,
        readingPreferences: NativeReadingPreferences
    ) {
        self.model = model
        _editorSession = ObservedObject(wrappedValue: model.editorSession)
        self.workspaceLayout = workspaceLayout
        self.readingPreferences = readingPreferences
    }

    private var editorMode: ArticleEditorMode {
        workspaceLayout.editorMode
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            GeometryReader { proxy in
                let settingsWidth = min(
                    max(CGFloat(workspaceLayout.editorSidebarWidth), 240),
                    max(240, proxy.size.width * 0.46)
                )
                let showsSidebar = editorMode != .focus && workspaceLayout.isEditorSidebarVisible
                let dividerWidth: CGFloat = 7

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        titleSection
                            .disabled(model.isMarkdownSourceReadOnly)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, ArticleEditorLayout.titleVerticalInset)

                        writingSection
                    }
                    .frame(maxWidth: ArticleEditorLayout.writingWidth, maxHeight: .infinity, alignment: .topLeading)
                    .frame(
                        width: showsSidebar ? max(0, proxy.size.width - settingsWidth - dividerWidth) : proxy.size.width,
                        alignment: .top
                    )

                    if showsSidebar {
                        Rectangle()
                            .fill(appPalette.sidebar)
                            .frame(width: dividerWidth)
                            .overlay { appPalette.border.frame(width: 1) }
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { NSCursor.resizeLeftRight.push() }
                                else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        if editorSidebarDragStart == nil {
                                            editorSidebarDragStart = workspaceLayout.editorSidebarWidth
                                        }
                                        let start = editorSidebarDragStart ?? workspaceLayout.editorSidebarWidth
                                        workspaceLayout.editorSidebarWidth = min(
                                            max(start - Double(value.translation.width), 240),
                                            460
                                        )
                                    }
                                    .onEnded { _ in editorSidebarDragStart = nil }
                            )

                        editorInspectorSidebar
                        .disabled(model.isMarkdownSourceReadOnly)
                        .frame(width: settingsWidth)
                        .background(appPalette.sidebar)
                    }
                }
            }
        }
        .background(appPalette.canvas)
        .environment(\.colorScheme, .light)
        .environment(\.nativeReadingTypography, readingPreferences.typography)
        .onChange(of: model.editor) { _ in
            model.scheduleEditorAutosave()
        }
        .onAppear {
            model.editor.body = RichArticleDocument.convertingLegacyBody(model.editor.body)
            pageTemplateLibrary.prepare(for: model.currentUser.id)
            synchronizePropertyRows()
            documentAnalysis.update(source: model.editor.body, debounce: false)
        }
        .onChange(of: model.currentUser.id) { pageTemplateLibrary.prepare(for: $0) }
        .onChange(of: model.editor.body) { body in
            documentAnalysis.update(source: body)
        }
        .task(id: articleBlockSuggestionTaskID) {
            await reloadBlockLinkSuggestions()
        }
        .onChange(of: model.editor.recoveryID) { _ in
            model.editor.body = RichArticleDocument.convertingLegacyBody(model.editor.body)
            synchronizePropertyRows()
        }
        .onChange(of: model.editor.properties) { _ in synchronizePropertyRowsIfNeeded() }
        .onChange(of: propertyRows) { _ in commitPropertyRows() }
        .sheet(isPresented: $isPresentingHistory) {
            ArticleHistoryView(model: model)
        }
        .sheet(item: $propertyRenameRequest) { request in
            EditorPropertyRenameSheet(
                oldKey: request.oldKey,
                isRenaming: model.isRenamingArticleProperty,
                onRename: { model.renameArticleProperty(from: request.oldKey, to: $0) }
            )
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            ArticleActionIcon(kind: .writing)
                .foregroundStyle(appPalette.accent)

            Text(LocalizedStringKey(model.editor.status.label))
                .font(.caption.weight(.medium))
                .foregroundStyle(model.editor.status == .published ? appPalette.accent : appPalette.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    model.editor.status == .published ? appPalette.lightBlue : appPalette.surfaceSecondary,
                    in: Capsule()
                )

            HStack(spacing: 6) {
                if model.isEditorAutosaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    ArticleActionIcon(kind: .saved, size: 14)
                        .foregroundStyle(appPalette.textSecondary)
                }
                editorAutosaveStatusText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("编辑内容停止变化 3 秒后自动保存恢复快照")

            if model.isMarkdownSourceReadOnly {
                Label("只读挂载", nativeIcon: "lock.fill", iconSize: 12)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .help("可阅读和监听外部修改，不能在 LeonBook 中写回")
            }

            Spacer()

            HStack(spacing: 4) {
                NativeWorkspaceLayoutMenu(model: model, workspaceLayout: workspaceLayout, usesArticleActionIcon: true)
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(appPalette.textSecondary)
                    .fixedSize()

                Button {
                    workspaceLayout.isEditorSidebarVisible.toggle()
                } label: {
                    ArticleActionIcon(kind: .inspector)
                        .foregroundStyle(workspaceLayout.isEditorSidebarVisible ? appPalette.accent : appPalette.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NativeChromeIconButtonStyle(isSelected: workspaceLayout.isEditorSidebarVisible))
                .accessibilityLabel(Text(LocalizedStringKey(workspaceLayout.isEditorSidebarVisible ? "隐藏右栏" : "显示右栏")))
                .accessibilityAddTraits(workspaceLayout.isEditorSidebarVisible ? .isSelected : [])
                .opacity(editorMode == .focus ? 0.4 : 1)
                .disabled(editorMode == .focus)
                .help(Text(LocalizedStringKey(editorMode == .focus ? "专注写作模式会隐藏右侧面板" : "显示或隐藏编辑右侧面板")))

                Menu {
                    Section(NativeLocalization.text("编辑视图")) {
                        modeMenuButton(.blocks, shortcut: "1")
                        modeMenuButton(.focus, shortcut: "2")
                    }

                    Button {
                        model.executeCommand(.saveDraft)
                    } label: {
                        Label(LocalizedStringKey(model.isSaving ? "保存中…" : "保存草稿"), nativeIcon: "tray.and.arrow.down")
                    }
                    .disabled(model.isSaving || model.isMarkdownSourceReadOnly)

                    Button {
                        model.refreshArticleHistory()
                        isPresentingHistory = true
                    } label: {
                        Label("版本历史", nativeIcon: "clock.arrow.circlepath")
                    }

                    Menu("内容重构") {
                        Button("提取选区为新文章…", nativeIcon: "scissors") {
                            model.promptToExtractArticleSelection(model.editorBodySelection)
                        }
                        .disabled(model.editor.isNew || model.editorBodySelection.length == 0)

                        Button("按二级标题拆分…", nativeIcon: "square.split.2x1") {
                            model.promptToSplitArticleByLevel2Headings()
                        }
                        .disabled(model.editor.isNew)

                        Button("合并到其他文章…", nativeIcon: "arrow.triangle.merge") {
                            model.promptToMergeEditedArticle()
                        }
                        .disabled(model.editor.isNew || model.articles.count < 2)
                    }
                    .disabled(model.isMarkdownSourceReadOnly)

                    ArticlePageTemplateActions(model: model, library: pageTemplateLibrary)
                        .disabled(model.isMarkdownSourceReadOnly)

                    Menu {
                        Button("添加封面") {
                            model.chooseAndUpload(kind: .image, forArticle: model.editor.slug, banner: true)
                        }
                        Button("添加图片") {
                            model.chooseAndUpload(kind: .image, forArticle: model.editor.slug)
                        }
                        Button("添加视频") {
                            model.chooseAndUpload(kind: .video, forArticle: model.editor.slug)
                        }
                    } label: {
                        Label("添加素材", nativeIcon: "paperclip")
                    }
                    .disabled(model.isMarkdownSourceReadOnly)
                } label: {
                    Label {
                        Text("页面操作")
                    } icon: {
                        ArticleActionIcon.menuImage(kind: .more)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(appPalette.textSecondary)
                .fixedSize()
                .help("切换编辑视图、保存草稿或打开更多页面操作")
            }

            Button {
                model.executeCommand(.publishArticle)
            } label: {
                Label {
                    Text("发布")
                        .font(.system(size: 12, weight: .medium))
                } icon: {
                    ArticleActionIcon(kind: .publish)
                }
                .padding(.horizontal, 4)
            }
            .nativePrimaryButton()
            .disabled(model.isSaving || model.isMarkdownSourceReadOnly)
        }
        .controlSize(.regular)
        .padding(.horizontal, ArticleEditorLayout.contentInset)
        .padding(.vertical, 8)
    }

    private func modeMenuButton(_ mode: ArticleEditorMode, shortcut: KeyEquivalent) -> some View {
        Button {
            workspaceLayout.editorMode = mode
        } label: {
            Label(LocalizedStringKey(mode.title), nativeIcon: editorMode == mode ? "checkmark" : mode.systemImage)
        }
        .keyboardShortcut(shortcut, modifiers: [.command, .option])
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ArticlePathBreadcrumb(
                    sourceRelativePath: model.editor.isNew ? nil : model.selectedArticle?.sourceRelativePath,
                    draftFolderPath: model.pendingNewArticleFolderPath,
                    showsCreateArticle: false,
                    onSelectRoot: { model.showAllArticles() },
                    onSelectFolder: { model.showArticleFolder($0) },
                    onCreateArticle: { model.newArticle(inFolder: $0) }
                )
                Spacer()
                if model.editor.isNew {
                    ArticlePageTemplatePicker(model: model, library: pageTemplateLibrary)
                }
            }

            TextField("无标题", text: $editorSession.draft.title)
                .font(.system(size: 30, weight: .semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel("文章标题")
        }
        .padding(.horizontal, ArticleEditorLayout.writingInset)
    }

    private var writingSection: some View {
        RichArticleEditor(
            html: $editorSession.draft.body,
            documentID: model.editor.recoveryID,
            isEditable: !model.isMarkdownSourceReadOnly,
            fontSize: readingPreferences.typography.fontSize,
            store: model.store,
            sourceRelativePath: model.editor.isNew ? nil : model.selectedArticle?.sourceRelativePath,
            onImportAudio: { try await model.importEditorAudio(from: $0) },
            onAudioInserted: { model.registerEditorAudio($0) },
            onOpenLink: { url in
                if url.scheme == "leonbook" { model.handleAutomationURL(url) }
                else { NSWorkspace.shared.open(url) }
            }
        )
        .frame(minHeight: 280, maxHeight: .infinity)
    }

    private func editorPane(appearance: NativeBodyEditorAppearance) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    LocalizedStringKey(appearance == .livePreview ? "行内实时预览" : "Markdown 源码"),
                    nativeIcon: appearance == .livePreview ? "textformat" : "pencil.line", iconSize: 14
                )
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    insertHTMLComponentTemplate()
                } label: {
                    Label("HTML 组件", nativeIcon: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.borderless)
                .help("插入可直接渲染的 HTML 组件")
                Text("⌘Z 可撤销")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            NativeBodyEditor(
                text: $editorSession.draft.body,
                selectedRange: $editorSession.bodySelection,
                isEditable: !model.isMarkdownSourceReadOnly,
                linkController: articleLinkController,
                slashController: slashCommandController,
                appearance: appearance,
                typography: readingPreferences.typography,
                onPasteImage: { image, placeholder in
                    model.uploadPastedImage(image, placeholder: placeholder)
                },
                onRunCommand: { definition, range in
                    model.executeCommand(.editorInsertion(id: definition.id, replacing: range))
                }
            )
            .id(model.editor.recoveryID)
            .padding(10)
            .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary)
            }
            .overlay(alignment: .topLeading) {
                if model.editor.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("从这里开始写……")
                        .font(readingPreferences.profile.bodyFont.swiftUIFont(
                            size: readingPreferences.typography.fontSize
                        ))
                        .foregroundStyle(.secondary)
                        // Text's CJK glyphs begin slightly inside their layout
                        // box, while the NSTextView caret does not. Offset the
                        // prompt by 6 points so its visible first glyph aligns
                        // with the caret.
                        .padding(.leading, 12)
                        // The caret spans the full line height while the text
                        // glyph itself is shorter. Center the prompt vertically
                        // within that line rather than aligning its top edge.
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }

            if let query = slashCommandController.activeQuery, !slashCommandSuggestions.isEmpty {
                EditorSlashCommandMenu(
                    query: query,
                    commands: slashCommandSuggestions,
                    onSelect: slashCommandController.completeSuggestion,
                    onDismiss: slashCommandController.dismissSuggestions
                )
            } else if let query = articleLinkController.activeLinkQuery, !articleLinkSuggestions.isEmpty {
                ArticleLinkSuggestionMenu(
                    query: query,
                    articles: articleLinkSuggestions,
                    onSelect: articleLinkController.completeSuggestion,
                    onDismiss: articleLinkController.dismissSuggestions
                )
            }
        }
        .padding(ArticleEditorLayout.contentInset)
    }

    private var editorInspectorSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label {
                        Text("编辑面板")
                    } icon: {
                        ArticleActionIcon(kind: .inspector, size: 16)
                    }
                    .font(.headline)
                    Spacer()
                    Text(LocalizedStringKey(workspaceLayout.editorSidebarPane.title))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("编辑面板", selection: $workspaceLayout.editorSidebarPane) {
                    ForEach(NativeEditorSidebarPane.allCases) { pane in
                        Label(LocalizedStringKey(pane.title), nativeIcon: pane.systemImage)
                            .tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("在设置、属性、大纲和链接之间切换")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                Group {
                    switch workspaceLayout.editorSidebarPane {
                    case .settings:
                        editorSettingsSidebar
                    case .properties:
                        editorPropertiesSidebar
                    case .outline:
                        editorOutlineSidebar
                    case .links:
                        editorLinksSidebar
                    }
                }
                .padding(ArticleEditorLayout.contentInset)
            }
        }
    }

    private var editorSettingsSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorCard(title: "文章信息", icon: .document) {
                if model.editor.isNew {
                    Picker("所属目录", selection: Binding(
                        get: { model.pendingNewArticleFolderPath ?? NativeArticleDirectoryPolicy.defaultFolderPath },
                        set: { model.pendingNewArticleFolderPath = $0 }
                    )) {
                        ForEach(model.articleCreationFolderPaths, id: \.self) { path in
                            Text(path).tag(path)
                        }
                    }
                    .help("文章必须归属目录，目录最多 5 级。")
                }

                TextField("摘要（可选）", text: $editorSession.draft.excerpt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                    .accessibilityLabel("摘要（可选）")

                if let updatedAt = model.editor.updatedAt {
                    Text(NativeLocalization.text("最近保存：\(updatedAt.nativeDateLabel)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            EditorCard(title: "分类与标签", icon: .tag) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("分类", text: $editorSession.draft.category)
                        .textFieldStyle(.roundedBorder)
                    TextField("标签，例如 #Swift #随笔", text: $editorSession.draft.tags)
                        .textFieldStyle(.roundedBorder)

                    if !tagSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tagSuggestions, id: \.self) { tag in
                                    Button("#\(tag)") {
                                        appendTag(tag)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    Text("输入 #标签，使用空格继续添加；也兼容原来的逗号分隔。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            EditorCard(title: "封面图", icon: .image) {
                if let banner = model.editor.banner {
                    HStack(spacing: 10) {
                        NativeImageView(url: banner.url, alt: banner.alt, store: model.store)
                            .frame(width: 64, height: 52)
                            .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(banner.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            Text("已添加")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                } else {
                    Button {
                        model.chooseAndUpload(kind: .image, forArticle: model.editor.slug, banner: true)
                    } label: {
                        VStack(spacing: 6) {
                            ArticleActionIcon(kind: .image, size: 22)
                                .foregroundStyle(appPalette.textSecondary)
                            Text("添加一张封面图")
                                .font(.caption.weight(.medium))
                            Text("推荐横向图片")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5]))
                        }
                    }
                    .buttonStyle(.plain)
                }

                if model.editor.banner != nil {
                    Button("更换封面") {
                        model.chooseAndUpload(kind: .image, forArticle: model.editor.slug, banner: true)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            EditorCard(title: "附件", icon: .attachment) {
                if model.editor.media.isEmpty {
                    Text("还没有图片、视频、音频或文件附件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.editor.media) { media in
                            EditorAttachmentRow(
                                media: media,
                                savedTimestamp: model.videoTimestampLabel(for: media),
                                onInsertTimestamp: { model.insertVideoTimestamp(media) },
                                onRemove: { model.removeEditorMedia(media) }
                            )
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("图片") {
                        model.chooseAndUpload(kind: .image, forArticle: model.editor.slug)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("视频") {
                        model.chooseAndUpload(kind: .video, forArticle: model.editor.slug)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if model.isUploadingMedia {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在后台导入媒体，可继续编辑")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            EditorCard(title: "文章概览", icon: .statistics) {
                HStack {
                    EditorMetric(value: "\(wordCount)", label: "字")
                    Divider().frame(height: 26)
                    EditorMetric(value: "\(readingMinutes)", label: "分钟")
                    Divider().frame(height: 26)
                    EditorMetric(value: "\(model.editor.media.count)", label: "个附件")
                }
            }
        }
    }

    @ViewBuilder
    private var editorAutosaveStatusText: some View {
        let status = model.editorAutosaveStatus
        if status.hasPrefix("已自动保存：") {
            let detail = localizedAutosaveDate(String(status.dropFirst("已自动保存：".count)))
            Text(NativeLocalization.text("已自动保存：\(detail)"))
        } else if status.hasPrefix("已恢复自动保存：") {
            let detail = localizedAutosaveDate(String(status.dropFirst("已恢复自动保存：".count)))
            Text(NativeLocalization.text("已恢复自动保存：\(detail)"))
        } else {
            Text(LocalizedStringKey(status))
        }
    }

    private func localizedAutosaveDate(_ value: String) -> String {
        let chineseFormatter = DateFormatter()
        chineseFormatter.locale = Locale(identifier: "zh-Hans")
        chineseFormatter.dateFormat = "yyyy年M月d日"
        guard let date = chineseFormatter.date(from: value) else { return value }
        return date.formatted(.dateTime.year().month(.wide).day().locale(locale))
    }

    private var editorPropertiesSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Properties")
                .font(.title3.weight(.semibold))
            Text("属性支持文本、列表、数字、日期、复选框和标签。它们会写入 YAML、参与全文搜索，也可用 [属性名:值] 精确筛选。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.articlePropertyStatus.isEmpty {
                Text(LocalizedStringKey(model.articlePropertyStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if propertyRows.isEmpty {
                Text("还没有自定义属性")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            }

            ForEach($propertyRows) { $row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("属性名", text: $row.key)
                            .textFieldStyle(.roundedBorder)
                        Picker("类型", selection: $row.kind) {
                            ForEach(NativeArticlePropertyKind.allCases) { kind in
                                Label(LocalizedStringKey(kind.label), nativeIcon: kind.systemImage).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 104)
                        Button {
                            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
                            if NativeArticleProperties.isValidKey(key) {
                                propertyRenameRequest = EditorPropertyRenameRequest(oldKey: key)
                            }
                        } label: {
                            NativeIcon.image("arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!NativeArticleProperties.isValidKey(row.key) || model.isRenamingArticleProperty)
                        .help("在整个工作区统一重命名")
                        Button(role: .destructive) {
                            propertyRows.removeAll(where: { $0.id == row.id })
                        } label: {
                            NativeIcon.image("trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除属性")
                    }
                    EditorPropertyValueField(
                        row: $row,
                        rows: propertyRows,
                        articles: model.articles,
                        sourceSlug: model.editor.slug
                    )
                    if !row.typedValue.isValid {
                        Label("值与所选类型不匹配", nativeIcon: "exclamationmark.triangle.fill", iconSize: 12)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary)
                }
                .onChange(of: row.kind) { kind in
                    switch kind {
                    case .checkbox:
                        row.value = NativeArticlePropertyValue.fromEditor(kind: .checkbox, text: row.value).editorText
                    case .date:
                        if !NativeArticlePropertyValue.fromEditor(kind: .date, text: row.value).isValid {
                            let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                            row.value = String(
                                format: "%04d-%02d-%02d",
                                components.year ?? 0,
                                components.month ?? 0,
                                components.day ?? 0
                            )
                        }
                    case .number:
                        if !NativeArticlePropertyValue.fromEditor(kind: .number, text: row.value).isValid {
                            row.value = "0"
                        }
                    case .rollup:
                        let relationKey = propertyRows.first(where: {
                            $0.kind == .relation && NativeArticleProperties.isValidKey($0.key)
                        })?.key ?? ""
                        row.value = "\(relationKey) |  | count"
                    case .text, .list, .tags, .select, .status, .relation:
                        break
                    }
                }
            }

            Button {
                propertyRows.append(EditorPropertyRow())
            } label: {
                Label("添加属性", nativeIcon: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var editorOutlineSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("正文大纲")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(editorOutline.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if editorOutline.isEmpty {
                ArticleInspectorEmpty(message: "使用 /h1、/h2 或 /h3 添加标题后会在这里生成大纲")
            } else {
                ForEach(editorOutline) { item in
                    HStack(spacing: 8) {
                        NativeIcon.image("textformat.size")
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .font(item.level <= 2 ? .subheadline.weight(.semibold) : .subheadline)
                    .padding(.leading, CGFloat(max(0, item.level - 1)) * 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var editorLinksSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("文章链接")
                .font(.title3.weight(.semibold))

            EditorCard(title: "正文出链", systemImage: "arrow.up.forward") {
                if editorWikiLinks.isEmpty {
                    ArticleInspectorEmpty(message: "正文中还没有 [[双链]]")
                } else {
                    ForEach(editorWikiLinks) { link in
                        Button {
                            model.openArticleLink(link.destination)
                        } label: {
                            HStack(spacing: 8) {
                                NativeIcon.image(link.destination.resolvedSlug == nil ? "doc.badge.plus" : "doc.text")
                                    .foregroundStyle(link.destination.resolvedSlug == nil ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(link.reference.label)
                                        .lineLimit(1)
                                    if let heading = link.reference.heading {
                                        Text("#\(heading)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else if link.destination.resolvedSlug == nil {
                                        Text("点击创建文章")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            EditorCard(title: "反向链接", systemImage: "arrow.uturn.backward") {
                if editorBacklinks.isEmpty {
                    ArticleInspectorEmpty(message: model.editor.isNew ? "保存文章后可查看反向链接" : "还没有文章链接到这里")
                } else {
                    ForEach(editorBacklinks) { article in
                        ArticleInspectorLinkRow(article: article) {
                            model.openArticleLink(article.slug)
                        }
                    }
                }
            }

            if !model.editor.isNew && !model.selectedArticleRelations.unlinkedMentions.isEmpty {
                EditorCard(title: "未链接提及", systemImage: "text.magnifyingglass") {
                    ForEach(model.selectedArticleRelations.unlinkedMentions) { mention in
                        ArticleUnlinkedMentionRow(
                            mention: mention,
                            onOpen: { model.openArticleLink(mention.article.slug) },
                            onConvert: { model.convertUnlinkedMention(mention) }
                        )
                    }
                }
            }
        }
    }

    private var editorOutline: [MarkdownOutlineItem] {
        documentAnalysis.value.document.outline
    }

    private var editorWikiLinks: [EditorWikiLink] {
        documentAnalysis.value.wikiReferences.enumerated().compactMap { offset, reference in
            let value = wikiReferenceValue(reference)
            let destination = NativeArticleLinkDestination(
                target: reference.target,
                resolvedSlug: model.resolveArticleLink(value)?.slug,
                heading: reference.heading,
                label: reference.label
            )
            return EditorWikiLink(
                id: "\(offset)-\(reference.target)-\(reference.heading ?? "")",
                reference: reference,
                destination: destination
            )
        }
    }

    private var editorBacklinks: [NativeArticleSummary] {
        guard !model.editor.isNew,
              model.selectedArticle?.slug == model.editor.slug else { return [] }
        return model.selectedArticleRelations.incoming
    }

    private func wikiReferenceValue(_ reference: NativeArticleLink.Reference) -> String {
        var value = reference.target
        if let heading = reference.heading { value += "#\(heading)" }
        if reference.label != value { value += "|\(reference.label)" }
        return value
    }

    private func properties(from rows: [EditorPropertyRow]) -> [String: NativeArticlePropertyValue] {
        rows.reduce(into: [:]) { result, row in
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = row.typedValue
        }
    }

    private func synchronizePropertyRows() {
        propertyRows = model.editor.properties.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.compactMap { key in
            guard let value = model.editor.properties[key] else { return nil }
            return EditorPropertyRow(key: key, kind: value.kind, value: value.editorText)
        }
    }

    private func synchronizePropertyRowsIfNeeded() {
        guard properties(from: propertyRows) != model.editor.properties else { return }
        synchronizePropertyRows()
    }

    private func commitPropertyRows() {
        let nextProperties = properties(from: propertyRows)
        guard model.editor.properties != nextProperties else { return }
        model.editor.properties = nextProperties
    }

    private var wordCount: Int {
        documentAnalysis.value.wordCount
    }

    private var readingMinutes: Int {
        max(1, Int(ceil(Double(max(wordCount, 1)) / 500)))
    }

    private var tagSuggestions: [String] {
        let chosen = NativeArticleTag.parse(model.editor.tags)
        return model.availableArticleTags.filter { suggestion in
            !chosen.contains { $0.caseInsensitiveCompare(suggestion) == .orderedSame }
        }
    }

    private var articleLinkSuggestions: [EditorArticleLinkSuggestion] {
        guard let query = articleLinkController.activeLinkQuery else { return [] }
        if EditorBlockLinkQuery(query) != nil { return blockLinkSuggestions }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.articles.lazy.filter { article in
            normalized.isEmpty
                || article.title.localizedCaseInsensitiveContains(normalized)
                || article.slug.localizedCaseInsensitiveContains(normalized)
        }
        .prefix(8)
        .map(EditorArticleLinkSuggestion.article)
    }

    private var articleBlockSuggestionTaskID: String {
        let query = articleLinkController.activeLinkQuery ?? ""
        let bodyHash = EditorBlockLinkQuery(query)?.target.isEmpty == true
            ? model.editor.body.hashValue : 0
        return "\(query)|\(bodyHash)|\(model.editor.recoveryID)"
    }

    @MainActor
    private func reloadBlockLinkSuggestions() async {
        guard let rawQuery = articleLinkController.activeLinkQuery,
              let query = EditorBlockLinkQuery(rawQuery) else {
            blockLinkSuggestions = []
            return
        }

        let source: String
        let targetTitle: String
        if query.target.isEmpty
            || (!model.editor.slug.isEmpty
                && (query.target.caseInsensitiveCompare(model.editor.slug) == .orderedSame
                    || query.target.caseInsensitiveCompare(model.editor.title) == .orderedSame)) {
            source = model.editor.body
            targetTitle = model.editor.title.isEmpty ? "当前笔记" : model.editor.title
        } else if let summary = NativeArticleLink.resolve(query.target, in: model.articles),
                  let article = try? await model.store.getArticle(slug: summary.slug) {
            source = article.body
            targetTitle = article.title
        } else {
            blockLinkSuggestions = []
            return
        }

        guard articleLinkController.activeLinkQuery == rawQuery else { return }
        let normalizedSearch = query.searchText.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        blockLinkSuggestions = NativeArticleEmbed.blockReferences(in: source).lazy
            .filter { block in
                normalizedSearch.isEmpty
                    || block.id.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    ).contains(normalizedSearch)
                    || block.preview.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    ).contains(normalizedSearch)
            }
            .prefix(8)
            .map { block in
                let reference = query.target.isEmpty
                    ? "#^\(block.id)"
                    : "\(query.target)#^\(block.id)"
                return EditorArticleLinkSuggestion(
                    id: "block:\(query.target):\(block.id)",
                    title: "^\(block.id)",
                    detail: "\(targetTitle) · \(block.preview)",
                    systemImage: "scope",
                    reference: reference
                )
            }
    }

    private var slashCommandSuggestions: [NativeCommandDefinition] {
        guard let query = slashCommandController.activeQuery else { return [] }
        return model.commandRegistry.matches(
            query,
            on: .editorSlash,
            context: model.commandContext
        )
        .prefix(8)
        .map(\.definition)
    }

    private func appendTag(_ tag: String) {
        guard !NativeArticleTag.parse(model.editor.tags).contains(where: {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }) else {
            return
        }
        let separator = model.editor.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " "
        model.editor.tags += "\(separator)#\(tag)"
    }

    private func insertHTMLComponentTemplate() {
        let template = """
        ```html-render height=360
        <div style="padding: 20px; border-radius: 12px; background: #2563eb; color: white;">
          <h2 style="margin-top: 0;">HTML 组件</h2>
          <p>在这里输入 HTML、CSS 或 JavaScript。</p>
        </div>
        ```
        """
        let separator = model.editor.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : (model.editor.body.hasSuffix("\n") ? "\n" : "\n\n")
        model.editor.body += separator + template
    }
}

private struct EditorSlashCommandMenu: View {
    let query: String
    let commands: [NativeCommandDefinition]
    let onSelect: (NativeCommandDefinition) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(LocalizedStringKey(query.isEmpty ? "插入内容" : "匹配的插入命令"), nativeIcon: "command", iconSize: 12)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    NativeIcon.image("xmark", size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭 / 命令菜单")
            }

            ForEach(commands) { command in
                Button { onSelect(command) } label: {
                    HStack(spacing: 8) {
                        NativeIcon.image(command.systemImage)
                            .frame(width: 20)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(LocalizedStringKey(command.title)).font(.callout.weight(.medium))
                            Text(LocalizedStringKey(command.detail))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
    }
}

private struct ArticleLinkSuggestionMenu: View {
    let query: String
    let articles: [EditorArticleLinkSuggestion]
    let onSelect: (EditorArticleLinkSuggestion) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(
                    LocalizedStringKey(query.isEmpty ? "关联到文章" : "匹配的文章"),
                    nativeIcon: "link", iconSize: 12
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) {
                    NativeIcon.image("xmark", size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("关闭文章联想")
            }

            ForEach(articles) { article in
                Button {
                    onSelect(article)
                } label: {
                    HStack(spacing: 8) {
                        NativeIcon.image(article.systemImage)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(article.title)
                                .font(.callout.weight(.medium))
                            Text(article.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text("插入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文章关联建议")
    }
}

private struct EditorCard<Content: View>: View {
    @Environment(\.nativeAppPalette) private var appPalette

    private enum Icon {
        case line(ArticleActionIcon.Kind)
        case system(String)
    }

    let title: LocalizedStringKey
    private let icon: Icon
    let content: Content

    init(title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = .system(systemImage)
        self.content = content()
    }

    init(title: LocalizedStringKey, icon: ArticleActionIcon.Kind, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = .line(icon)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title)
            } icon: {
                Group {
                    switch icon {
                    case .line(let kind): ArticleActionIcon(kind: kind, size: 16)
                    case .system(let name): NativeIcon.image(name)
                    }
                }
                .foregroundStyle(appPalette.textSecondary)
                .frame(width: 20, height: 20)
            }
            .font(.subheadline.weight(.semibold))

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
        }
    }
}

private struct EditorMetric: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

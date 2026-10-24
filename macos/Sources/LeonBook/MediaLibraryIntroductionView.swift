import SwiftUI

struct NativeMediaIntroductionSheet: View {
    let item: NativeLibraryMedia
    @ObservedObject var library: NativeMediaLibraryModel
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(item.media.name, nativeIcon: item.media.isAudio ? "waveform" : "film")
                .font(.headline).lineLimit(1).truncationMode(.middle)
            Divider()
            NativeMediaIntroductionSection(item: item, library: library, initiallyEditing: true,
                                           onChange: onChange, onFinish: { dismiss() })
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct NativeMediaIntroductionSection: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let item: NativeLibraryMedia
    @ObservedObject var library: NativeMediaLibraryModel
    let onChange: () -> Void
    let onFinish: (() -> Void)?
    @State private var isEditing: Bool
    @State private var draft: String
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var editorIsFocused: Bool

    init(item: NativeLibraryMedia, library: NativeMediaLibraryModel, initiallyEditing: Bool = false,
         onChange: @escaping () -> Void, onFinish: (() -> Void)? = nil) {
        self.item = item
        self.library = library
        self.onChange = onChange
        self.onFinish = onFinish
        _isEditing = State(initialValue: initiallyEditing)
        _draft = State(initialValue: item.introduction)
    }

    private var introduction: String {
        library.items.first(where: { $0.id == item.id })?.introduction ?? item.introduction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("介绍").font(.headline)
                Spacer()
                if !isEditing {
                    Button {
                        draft = introduction
                        saveError = nil
                        isEditing = true
                    } label: {
                        Label(LocalizedStringKey(introduction.isEmpty ? "添加介绍" : "编辑介绍"), nativeIcon: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if isEditing {
                TextEditor(text: $draft)
                    .font(.body)
                    .focused($editorIsFocused)
                    .frame(height: 120)
                    .padding(8)
                    .background(appPalette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(appPalette.border) }
                    .accessibilityLabel("影音介绍")
                    .disabled(isSaving)
                    .onAppear { editorIsFocused = true }
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
                HStack(spacing: 12) {
                    Text("为这个视频或音频写一段介绍。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                    Button("取消") { finish() }.disabled(isSaving)
                    Button("保存") { save() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(isSaving || library.isBusy)
                }
            } else if introduction.isEmpty {
                Text("还没有介绍").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(introduction).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                try await library.saveIntroduction(draft, for: item, onChange: onChange)
                finish()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func finish() {
        isEditing = false
        if let onFinish { onFinish() }
    }
}

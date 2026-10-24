import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeMediaLibraryView: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @ObservedObject private var library: NativeMediaLibraryModel
    @State private var playing: NativeLibraryMedia?
    @State private var editingIntroduction: NativeLibraryMedia?
    @State private var isDropTargeted = false

    init(model: NativeAppModel) {
        self.model = model
        library = model.mediaLibrary
    }

    var body: some View {
        let items = library.visibleItems
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                if items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 20) {
                        ForEach(items) { item in tile(item) }
                    }
                    .padding(24)
                }
            }
            .background(isDropTargeted ? Color.accentColor.opacity(0.07) : .clear)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(8).allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) {
                library.acceptDrop($0, onChange: changed)
            }
            Divider()
            HStack {
                Text(NativeLocalization.text("\(items.count) 个文件")).foregroundStyle(.secondary)
                Spacer()
                Text("点击卡片播放 · 支持从 Finder 拖入文件").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .task { await library.load() }
        .sheet(item: $playing) { item in
            NativeMediaLibraryPlaybackView(item: item, library: library, onChange: changed)
        }
        .sheet(item: $editingIntroduction) { item in
            NativeMediaIntroductionSheet(item: item, library: library, onChange: changed)
        }
        .alert("影音库操作失败", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(library.title).font(.title2.weight(.semibold))
                    Text("集中浏览和播放本地视频、音乐与录音")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if library.isBusy { ProgressView().controlSize(.small) }
                Button { Task { await library.load() } } label: { NativeIcon.image("arrow.clockwise") }
                    .help("刷新影音库").accessibilityLabel("刷新影音库")
                    .disabled(library.isBusy)
                Button { library.importFiles(onChange: changed) } label: {
                    Label("导入影音", nativeIcon: "plus")
                }
                .disabled(library.isBusy)
            }
            HStack(spacing: 16) {
                Picker("类型", selection: $library.filter) {
                    ForEach(NativeMediaLibraryFilter.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Spacer(minLength: 0)
                TextField("搜索名称或介绍", text: $library.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Picker("排序", selection: $library.sort) {
                    ForEach(NativeMediaLibrarySort.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 115)
            }
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if library.isBusy {
                ProgressView("正在读取影音库…")
            } else {
                NativeIcon.image(library.search.isEmpty ? "play.rectangle.on.rectangle" : "magnifyingglass", size: 48)
                Text(LocalizedStringKey(library.search.isEmpty ? "这里还没有影音文件" : "没有匹配的影音文件"))
                    .font(.headline)
                Text("导入 MP4、MOV 视频或 MP3、M4A、WAV 等音频，也可以从 Finder 拖入。")
                    .font(.callout).multilineTextAlignment(.center)
                if library.search.isEmpty {
                    Button("导入影音") { library.importFiles(onChange: changed) }
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private func tile(_ item: NativeLibraryMedia) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { playing = item } label: {
                VStack(alignment: .leading, spacing: 9) {
                    NativeMediaLibraryThumbnail(media: item.media, store: library.store)
                        .frame(height: 142)
                        .frame(maxWidth: .infinity)
                        .background(appPalette.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .bottomLeading) {
                            Text(LocalizedStringKey(item.media.isAudio ? "音频" : "视频"))
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(9)
                        }
                    Text(item.media.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Text(URL(fileURLWithPath: item.media.name).pathExtension.uppercased())
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.media.size), countStyle: .file))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.media.name)
            .accessibilityLabel(item.media.name)
            if !item.introduction.isEmpty {
                Text(item.introduction).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button {
                    editingIntroduction = item
                } label: {
                    Label(LocalizedStringKey(item.introduction.isEmpty ? "添加介绍" : "编辑介绍"), nativeIcon: "square.and.pencil")
                }
                Spacer(minLength: 4)
                moveMenu(item)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(appPalette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(appPalette.border.opacity(0.6)) }
        .contextMenu {
            Button("播放") { playing = item }
            Button("编辑介绍") { editingIntroduction = item }
            moveMenu(item)
            Button("在 Finder 中显示") { library.reveal(item.media) }
        }
    }

    private func moveMenu(_ item: NativeLibraryMedia) -> some View {
        Menu("移到分组") {
            Button("默认分组") { Task { await library.move([item.media], to: nil, onChange: changed) } }
                .disabled(item.groupID == nil)
            ForEach(library.groups) { group in
                Button(group.name) { Task { await library.move([item.media], to: group.id, onChange: changed) } }
                    .disabled(item.groupID == group.id)
            }
        }
        .disabled(library.isBusy)
    }

    private func changed() {
        guard model.store.rootURL.path == library.workspace else { return }
        model.scheduleBackup()
    }
}

private struct NativeMediaLibraryThumbnail: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let media: NativeMedia
    let store: LocalBlogStore
    @State private var poster: NSImage?

    var body: some View {
        ZStack {
            if let poster {
                GeometryReader { geometry in
                    Image(nsImage: poster).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.12), appPalette.surfaceSecondary],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                NativeIcon.image(media.isAudio ? "waveform" : "film", size: 48).foregroundStyle(Color.accentColor.opacity(0.65))
            }
            NativeIcon.image("play.circle.fill", size: 32).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        }
        .task(id: media.url) {
            guard media.isVideo, let url = await store.mediaURL(for: media.url), !Task.isCancelled else { return }
            let result = await NativeVideoThumbnailPipeline.shared.thumbnail(for: url, maxPixelSize: 600)
            guard !Task.isCancelled else { return }
            poster = result.image
        }
    }
}

private struct NativeMediaLibraryPlaybackView: View {
    let item: NativeLibraryMedia
    @ObservedObject var library: NativeMediaLibraryModel
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback: NativeInlineVideoPlayerModel

    private var media: NativeMedia { item.media }
    private var store: LocalBlogStore { library.store }

    init(item: NativeLibraryMedia, library: NativeMediaLibraryModel, onChange: @escaping () -> Void) {
        self.item = item
        self.library = library
        self.onChange = onChange
        _playback = StateObject(wrappedValue: NativeInlineVideoPlayerModel(mediaID: item.id, isAudio: item.media.isAudio))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(media.name, nativeIcon: media.isAudio ? "waveform" : "film")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            if media.isAudio {
                NativeIcon.image("waveform.circle.fill", size: 80)
                    .symbolRenderingMode(.monochrome).foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity).padding(36)
            }
            ZStack {
                if let player = playback.player {
                    NativeAVPlayerView(player: player, isAudio: media.isAudio)
                }
                switch playback.phase {
                case let .failed(message):
                    VStack(spacing: 14) {
                        Label("无法播放此文件", nativeIcon: "exclamationmark.triangle")
                        Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("重试") { Task { await start() } }
                    }
                    .padding(24)
                case .ready: EmptyView()
                default: ProgressView("正在准备播放…")
                }
            }
            .frame(height: playbackHeight)
            .padding(media.isAudio ? 20 : 0)
            Divider()
            NativeMediaIntroductionSection(item: item, library: library, onChange: onChange)
                .padding(20)
            Divider()
            HStack {
                Text(playback.progressLabel).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("在 Finder 中显示") {
                    Task {
                        if let url = await store.mediaURL(for: media.url) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
            .font(.caption).padding(16)
        }
        .frame(width: 800)
        .task { await start() }
        .onDisappear { playback.release() }
    }

    private func start() async {
        await playback.resolve(using: store)
        guard !Task.isCancelled, playback.phase == .poster else { return }
        await playback.play()
    }

    private var playbackHeight: CGFloat {
        guard media.isAudio else { return 400 }
        if case .failed = playback.phase { return 160 }
        return 64
    }
}

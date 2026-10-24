import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativePhotoLibraryView: View {
    @Environment(\.nativeAppPalette) private var appPalette

    @ObservedObject var model: NativeAppModel
    @StateObject private var library: NativePhotoLibraryModel
    @AppStorage("leonbook.photos.tileSize") private var tileSize = 170.0
    @State private var browser: NativePhotoBrowserState?
    @State private var gridIsTargeted = false

    init(model: NativeAppModel) {
        self.model = model
        _library = StateObject(wrappedValue: NativePhotoLibraryModel(store: model.store, workspace: model.store.rootURL.path))
    }

    private var visiblePhotos: [NativeLibraryPhoto] { library.visiblePhotos }

    var body: some View {
        HStack(spacing: 0) {
            albumList
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                photoGrid
                Divider()
                statusBar
            }
        }
        .task { await library.load() }
        .sheet(item: $browser) { state in
            NativePhotoBrowserView(images: state.images, initialIndex: state.initialIndex, store: library.store)
        }
        .alert("相册操作失败", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
    }

    private var albumList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("相册").font(.title2.weight(.semibold))
                Spacer()
                Button { library.editAlbum(onChange: changed) } label: { NativeIcon.image("plus") }
                    .buttonStyle(.plain)
                    .help("新建相册")
                    .accessibilityLabel("新建相册")
                    .disabled(library.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            ScrollView {
                VStack(spacing: 4) {
                    albumRow("全部图片", icon: "photo.on.rectangle", scope: .all, count: library.photos.count)
                    albumRow("未分类", icon: "tray", scope: .unfiled, count: library.photos.filter { $0.albumID == nil }.count)
                    Divider().padding(.vertical, 10)
                    ForEach(library.albums) { album in
                        albumRow(album.name, icon: "rectangle.stack", scope: .album(album.id),
                                 count: library.photos.filter { $0.albumID == album.id }.count)
                            .contextMenu {
                                Button("重命名相册…") { library.editAlbum(album, onChange: changed) }
                                Button("删除相册…", role: .destructive) { library.deleteAlbum(album, onChange: changed) }
                            }
                    }
                    if library.albums.isEmpty {
                        Text("新建相册后，将图片拖到相册名称上即可归类。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 10)
            }
            Button { library.editAlbum(onChange: changed) } label: { Label("新建相册", nativeIcon: "plus") }
                .buttonStyle(.plain)
                .padding(16)
                .disabled(library.isBusy)
        }
        .frame(width: 205)
        .background(appPalette.surface)
    }

    private func albumRow(_ title: String, icon: String, scope: NativePhotoScope, count: Int) -> some View {
        NativePhotoAlbumRow(title: scope.albumID == nil ? NativeLocalization.string(title, language: NativeLocalization.currentLanguage) : title,
                            icon: icon, count: count, isSelected: library.scope == scope,
                            acceptsDrop: scope != .all && !library.isBusy,
                            select: { library.show(scope) },
                            drop: { library.acceptDrop($0, to: scope.albumID, onChange: changed) })
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.title).font(.title2.weight(.semibold)).lineLimit(1)
                    Text("双击看大图 · ⌘点选多张 · 拖到左侧相册归类")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if library.isBusy { ProgressView().controlSize(.small) }
                Button { Task { await library.load() } } label: { NativeIcon.image("arrow.clockwise") }
                    .help("刷新图片")
                    .disabled(library.isBusy)
                Button { library.importPhotos(onChange: changed) } label: { Label("导入图片", nativeIcon: "plus") }
                    .disabled(library.isBusy)
            }
            HStack(spacing: 12) {
                TextField("搜索图片名称", text: $library.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Picker("排序", selection: $library.sort) {
                    ForEach(NativePhotoSort.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 115)
                Spacer(minLength: 0)
                NativeIcon.image("square.grid.3x3").foregroundStyle(.secondary)
                Slider(value: $tileSize, in: 110...260).frame(width: 100).accessibilityLabel("缩略图大小")
            }
        }
        .padding(20)
    }

    private var photoGrid: some View {
        let photos = visiblePhotos
        return ScrollView {
            if photos.isEmpty {
                VStack(spacing: 12) {
                    NativeIcon.image(library.search.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass", size: 48)
                    Text(LocalizedStringKey(library.search.isEmpty ? "这里还没有图片" : "没有匹配的图片")).font(.headline)
                    Text(LocalizedStringKey(library.search.isEmpty ? "从 Finder 拖入图片，或将已有图片拖到左侧相册。" : "试试其他名称，或清除搜索条件。"))
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 350)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(tileSize)), spacing: 14)], spacing: 18) {
                    ForEach(photos) { photo in
                        photoTile(photo, photos: photos)
                    }
                }
                .padding(20)
            }
        }
        .background(gridIsTargeted ? Color.accentColor.opacity(0.07) : .clear)
        .overlay { if gridIsTargeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2).padding(6).allowsHitTesting(false) } }
        .onDrop(of: [UTType.leonBookPhotos.identifier, UTType.fileURL.identifier], isTargeted: $gridIsTargeted) {
            // Dropping inside All Photos keeps the existing organization.
            if library.scope == .all, $0.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.leonBookPhotos.identifier) }) { return false }
            return library.acceptDrop($0, to: library.scope.albumID, onChange: changed)
        }
    }

    private func photoTile(_ photo: NativeLibraryPhoto, photos: [NativeLibraryPhoto]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            NativePhotoThumbnail(media: photo.media, store: library.store, pixelSize: 600)
                .frame(height: CGFloat(tileSize) * 0.8)
                .frame(maxWidth: .infinity)
                .background(appPalette.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .topTrailing) {
                    if library.selection.contains(photo.id) {
                        NativeIcon.image("checkmark", size: NativeIcon.Size.metadata)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(appPalette.accent, in: Circle())
                            .padding(8)
                    }
                }
            Text(photo.media.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: Int64(photo.media.size), countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(7)
        .background(library.selection.contains(photo.id) ? appPalette.selection : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(photo, in: photos) }
        .onTapGesture { library.select(photo, in: photos) }
        .onDrag { library.dragProvider(for: photo) }
        .contextMenu {
            Button("查看大图") { open(photo, in: photos) }
            Menu("移到相册") {
                ForEach(library.albums) { album in
                    Button(album.name) { library.move(library.contextualPhotos(photo), to: album.id, onChange: changed) }
                }
                Divider()
                Button("移到未分类") { library.move(library.contextualPhotos(photo), to: nil, onChange: changed) }
            }
            .disabled(library.isBusy)
            Button("在 Finder 中显示") {
                Task { if let url = await library.store.mediaURL(for: photo.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.media.name)
        .accessibilityAddTraits(library.selection.contains(photo.id) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open(photo, in: photos) }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(NativeLocalization.text("\(visiblePhotos.count) 张图片")).foregroundStyle(.secondary)
            if !library.selection.isEmpty {
                Text(NativeLocalization.text("已选择 \(library.selection.count) 张"))
                Menu("移到相册") {
                    ForEach(library.albums) { album in
                        Button(album.name) { moveSelection(to: album.id) }
                    }
                    Divider()
                    Button("移到未分类") { moveSelection(to: nil) }
                }
                .disabled(library.isBusy)
                Button("取消选择") { library.selection = [] }
            }
            Spacer()
            Button("浏览图片") {
                let photos = visiblePhotos
                if let photo = photos.first(where: { library.selection.contains($0.id) }) ?? photos.first { open(photo, in: photos) }
            }
            .disabled(visiblePhotos.isEmpty)
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .onChange(of: library.search) { _ in library.selection = [] }
    }

    private func moveSelection(to albumID: String?) {
        library.move(library.photos.filter { library.selection.contains($0.id) }.map(\.media), to: albumID, onChange: changed)
    }

    private func open(_ photo: NativeLibraryPhoto, in photos: [NativeLibraryPhoto]) {
        guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        browser = NativePhotoBrowserState(images: photos.map(\.media), initialIndex: index)
    }

    private func changed() {
        guard model.store.rootURL.path == library.workspace else { return }
        model.scheduleBackup()
    }
}

private struct NativePhotoAlbumRow: View {
    @Environment(\.nativeAppPalette) private var appPalette

    let title: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let acceptsDrop: Bool
    let select: () -> Void
    let drop: ([NSItemProvider]) -> Bool
    @State private var targeted = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                NativeIcon.image(icon).frame(width: 18)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(targeted && acceptsDrop ? Color.accentColor.opacity(0.18) : isSelected ? appPalette.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay { if targeted && acceptsDrop { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .onDrop(of: [UTType.leonBookPhotos.identifier, UTType.fileURL.identifier], isTargeted: $targeted) {
            acceptsDrop && drop($0)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

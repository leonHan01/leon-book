import AppKit
import Foundation
import LeonBookPublishingModule
import UniformTypeIdentifiers

extension NativeAppModel {
    func chooseMomentImages() {
        guard !isBackingUp, !isUploadingMedia else { return }
        let remaining = max(0, 9 - momentDraft.images.count)
        guard remaining > 0 else {
            errorMessage = NativeLocalization.text("每条微博最多添加 9 个图片、视频或音频。")
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        let selectedURLs = Array(panel.urls.prefix(remaining))
        guard !selectedURLs.isEmpty else { return }

        let activeStore = store
        Task {
            let generation = beginUpload()
            defer { endUpload() }
            do {
                let uploadedImages = try await NativeMediaUpload.files(
                    selectedURLs,
                    kind: .image,
                    destination: .moments,
                    store: activeStore
                )
                guard generation == workspaceGeneration else {
                    try? await activeStore.discardUnreferencedMedia(uploadedImages)
                    return
                }
                momentDraft.images.append(contentsOf: uploadedImages)
                try await refreshActivity()
                scheduleBackup()
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseMomentVideo() {
        chooseMomentAVMedia(isAudio: false)
    }

    func chooseMomentAudio() {
        chooseMomentAVMedia(isAudio: true)
    }

    private func chooseMomentAVMedia(isAudio: Bool) {
        guard !isBackingUp, !isUploadingMedia else { return }
        guard momentDraft.images.count < 9 else {
            errorMessage = NativeLocalization.text("每条微博最多添加 9 个图片、视频或音频。")
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = isAudio ? [.mp3] : [.mpeg4Movie]
        panel.message = isAudio ? NativeLocalization.text("选择一个 MP3 音频") : NativeLocalization.text("选择一个 MP4 视频")
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        guard fileURL.pathExtension.caseInsensitiveCompare(isAudio ? "mp3" : "mp4") == .orderedSame else {
            errorMessage = isAudio ? NativeLocalization.text("微博音频仅支持 MP3 格式。") : NativeLocalization.text("微博视频仅支持 MP4 格式。")
            return
        }

        if !isAudio {
            uploadMomentVideos([fileURL])
            return
        }

        let activeStore = store
        Task {
            let generation = beginUpload()
            defer { endUpload() }
            do {
                guard let uploaded = try await NativeMediaUpload.files(
                    [fileURL],
                    kind: isAudio ? .audio : .video,
                    destination: .moments,
                    store: activeStore
                ).first else { return }
                guard generation == workspaceGeneration else {
                    try? await activeStore.discardUnreferencedMedia([uploaded])
                    return
                }
                momentDraft.images.append(uploaded)
                try await refreshActivity()
                scheduleBackup()
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func acceptMomentVideoDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isBackingUp, !isUploadingMedia else { return false }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let generation = workspaceGeneration
        Task {
            do {
                var urls: [URL] = []
                for provider in files {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: NativeStoreError.fileSystem(NativeLocalization.text("无法读取拖入的文件。"))) }
                        }
                    }
                    guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                        throw NativeStoreError.fileSystem(NativeLocalization.text("无法读取拖入的文件。"))
                    }
                    if !urls.contains(url) { urls.append(url) }
                }
                guard generation == workspaceGeneration else { return }
                uploadMomentVideos(urls)
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
        return true
    }

    func uploadMomentVideos(_ urls: [URL]) {
        guard !isBackingUp, !isUploadingMedia, !urls.isEmpty else { return }
        guard urls.allSatisfy({ $0.isFileURL && $0.pathExtension.caseInsensitiveCompare("mp4") == .orderedSame }) else {
            errorMessage = NativeLocalization.text("微博视频仅支持 MP4 格式。")
            return
        }
        let remaining = max(0, 9 - momentDraft.images.count)
        guard remaining > 0 else {
            errorMessage = NativeLocalization.text("每条微博最多添加 9 个图片、视频或音频。")
            return
        }
        let selectedURLs = Array(urls.prefix(remaining))
        let activeStore = store
        Task {
            let generation = beginUpload()
            defer { endUpload() }
            do {
                let uploaded = try await NativeMediaUpload.files(
                    selectedURLs, kind: .video, destination: .moments, store: activeStore
                )
                guard generation == workspaceGeneration else {
                    try? await activeStore.discardUnreferencedMedia(uploaded)
                    return
                }
                momentDraft.images.append(contentsOf: uploaded)
                try await refreshActivity()
                scheduleBackup()
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeMomentMedia(_ media: NativeMedia) {
        momentDraft.images.removeAll { $0.id == media.id }
        discardUnreferencedMedia([media])
    }

    func beginEditingMoment(_ moment: NativeMoment) {
        guard !isPublishingMoment else { return }
        if isMomentDraftDirty {
            guard confirmDiscardMomentDraft() else { return }
            discardUnreferencedMedia(momentDraft.images)
        }
        editingMomentID = moment.id
        momentDraft = editableMomentDraft(from: moment)
        errorMessage = nil
    }

    func toggleMomentTagFilter(_ tag: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let selectedTag = selectedMomentTags.first(where: {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            selectedMomentTags.remove(selectedTag)
        } else {
            selectedMomentTags.insert(normalized)
        }
        refreshMomentFeed()
    }

    func isMomentTagSelected(_ tag: String) -> Bool {
        selectedMomentTags.contains {
            $0.caseInsensitiveCompare(tag) == .orderedSame
        }
    }

    func selectMomentDateFilter(_ filter: NativeMomentDateFilter) {
        guard momentDateFilter != filter else { return }
        momentDateFilter = filter
        refreshMomentFeed()
    }

    func toggleFavoriteMomentFilter() {
        showsOnlyFavoriteMoments.toggle()
        refreshMomentFeed()
    }

    @discardableResult
    func toggleMomentFavorite(_ moment: NativeMoment) -> Task<Void, Never>? {
        guard !isBackingUp, !isRestoringBackup, !isSwitchingWorkspace else { return nil }
        let activeStore = store
        let generation = workspaceGeneration
        let feedGeneration = momentFeedGeneration
        let wasLoadingFeed = isLoadingMoreMoments
        return Task {
            do {
                let updated = try await activeStore.setMomentFavorite(id: moment.id, isFavorite: !moment.isFavorite)
                guard generation == workspaceGeneration, store === activeStore else { return }
                if wasLoadingFeed || isLoadingMoreMoments || feedGeneration != momentFeedGeneration {
                    // A concurrent refresh may have read its count or page before
                    // this write. Invalidate that snapshot and read a consistent feed.
                    try await reloadMomentFeed()
                    guard generation == workspaceGeneration, store === activeStore else { return }
                } else if let index = moments.firstIndex(where: { $0.id == updated.id }) {
                    // Stable feeds retain loaded history and their exclusive cursor,
                    // including when the cursor's row is no longer a favorite.
                    if showsOnlyFavoriteMoments && !updated.isFavorite {
                        moments.remove(at: index)
                        filteredMomentCount = max(0, filteredMomentCount - 1)
                        // The empty-state view has no "load more" button. Pull
                        // the next page if the last loaded favorite was removed.
                        if moments.isEmpty, hasMoreMoments { loadMoreMoments() }
                    } else {
                        moments[index] = updated
                    }
                }
                scheduleBackup()
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration, store === activeStore else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearMomentFilters() {
        momentSearchText = ""
        selectedMomentTags = []
        momentDateFilter = .all
        showsOnlyFavoriteMoments = false
        refreshMomentFeed()
    }

    func cancelMomentEditing() {
        guard !isPublishingMoment else { return }
        let discardedMedia = momentDraft.images
        editingMomentID = nil
        momentDraft = NativeMomentDraft()
        discardUnreferencedMedia(discardedMedia)
        errorMessage = nil
    }

    func deleteMoment(_ moment: NativeMoment) {
        guard !isBackingUp else { return }
        if editingMomentID == moment.id {
            cancelMomentEditing()
        }
        let loadingID = loadingOperations.begin(.trash)
        Task {
            defer { loadingOperations.end(loadingID) }
            do {
                try await store.deleteMoment(id: moment.id)
                try await reloadMomentFeed(refreshesFacets: true)
                trashItems = try await store.listTrash()
                scheduleBackup()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func uploadMomentPastedImages(_ images: [NSImage]) {
        guard !isBackingUp, !isUploadingMedia else { return }
        let remaining = max(0, 9 - momentDraft.images.count)
        guard remaining > 0 else {
            errorMessage = NativeLocalization.text("每条微博最多添加 9 个图片、视频或音频。")
            return
        }

        let imagesToUpload = Array(images.prefix(remaining))
        guard !imagesToUpload.isEmpty else { return }

        let activeStore = store
        Task {
            let generation = beginUpload()
            defer { endUpload() }
            do {
                let uploadedImages = try await NativeMediaUpload.images(
                    imagesToUpload,
                    destination: .moments,
                    temporaryNamePrefix: "moment-image",
                    store: activeStore
                )
                guard generation == workspaceGeneration else {
                    try? await activeStore.discardUnreferencedMedia(uploadedImages)
                    return
                }
                momentDraft.images.append(contentsOf: uploadedImages)
                try await refreshActivity()
                scheduleBackup()
                errorMessage = nil
            } catch {
                guard generation == workspaceGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func confirmDiscardMomentDraft() -> Bool {
        guard isMomentDraftDirty else { return true }
        let alert = NSAlert()
        alert.messageText = NativeLocalization.text("放弃未发布的微博？")
        alert.informativeText = NativeLocalization.text("当前微博草稿中的文字和媒体将被放弃。")
        alert.addButton(withTitle: NativeLocalization.text("放弃并编辑"))
        alert.addButton(withTitle: NativeLocalization.text("继续编辑"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func editableMomentDraft(from moment: NativeMoment) -> NativeMomentDraft {
        let content = moment.displayContent
        let tagsText = moment.tags.map { "#\($0)" }.joined(separator: " ")
        guard !tagsText.isEmpty else {
            return NativeMomentDraft(text: content.text, textRuns: content.runs, images: moment.images)
        }

        let separator = content.text.isEmpty ? "" : " "
        return NativeMomentDraft(
            text: content.text + separator + tagsText,
            textRuns: content.runs + [
                NativeMomentTextRun(text: separator + tagsText, bold: false, color: nil),
            ],
            images: moment.images
        )
    }

    var isMomentDraftDirty: Bool {
        !momentDraft.isEmpty || editingMomentID != nil
    }
}

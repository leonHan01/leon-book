import AVFoundation
import AppKit
import Foundation
import SwiftUI

struct NativeVideoThumbnailResult: @unchecked Sendable {
    let image: NSImage?
}

actor NativeVideoThumbnailPipeline {
    typealias Decoder = @Sendable (URL, Int) -> NSImage?
    static let shared = NativeVideoThumbnailPipeline(scheduler: .shared)

    private let cache = NativeMediaImageCache(byteLimit: 32 * 1_024 * 1_024, countLimit: 96)
    private let scheduler: NativeMediaDecodeScheduler
    private let decoder: Decoder

    init(maximumConcurrentDecodes: Int = 2, scheduler: NativeMediaDecodeScheduler? = nil,
         decoder: @escaping Decoder = { NativeVideoThumbnailDecoder.load(from: $0, maxPixelSize: $1) }) {
        self.scheduler = scheduler ?? NativeMediaDecodeScheduler(maximumConcurrentDecodes: maximumConcurrentDecodes)
        self.decoder = decoder
    }

    func thumbnail(for url: URL, maxPixelSize: Int = 1_280) async -> NativeVideoThumbnailResult {
        guard !Task.isCancelled else { return NativeVideoThumbnailResult(image: nil) }
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.image(for: key) {
            return NativeVideoThumbnailResult(image: cached)
        }
        let cache = self.cache
        let decoder = self.decoder
        let result = await scheduler.decode(key: "video|\(key)") {
            if let cached = cache.image(for: key) { return cached }
            guard let image = decoder(url, maxPixelSize), !Task.isCancelled else { return nil }
            cache.insert(image, for: key)
            return image
        }
        return NativeVideoThumbnailResult(image: result.image)
    }

    var cachedByteCount: Int { cache.retainedBytes }

    private func cacheKey(for url: URL, maxPixelSize: Int) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(fileSize)|\(modifiedAt)|\(maxPixelSize)"
    }

}

private enum NativeVideoThumbnailDecoder {
    static func load(from url: URL, maxPixelSize: Int) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var actualTime = CMTime.zero
        guard let image = try? generator.copyCGImage(
            at: CMTime(seconds: 0.5, preferredTimescale: 600),
            actualTime: &actualTime
        ), !Task.isCancelled else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

@MainActor
final class NativeVideoPlaybackCoordinator {
    static let shared = NativeVideoPlaybackCoordinator()

    private static let positionsKey = "nativeVideoPlaybackPositions.v1"
    private weak var activePlayer: AVPlayer?
    private var activeMediaID: String?
    private var positions: [String: Double]
    private var lastPersistedSecond: [String: Int] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        positions = defaults.dictionary(forKey: Self.positionsKey)?.compactMapValues { value in
            (value as? NSNumber)?.doubleValue
        } ?? [:]
    }

    func activate(_ player: AVPlayer, mediaID: String) {
        if let activePlayer, activePlayer !== player {
            if let activeMediaID {
                record(
                    mediaID: activeMediaID,
                    seconds: activePlayer.currentTime().seconds,
                    duration: activePlayer.currentItem?.duration.seconds ?? 0,
                    forcePersistence: true
                )
            }
            activePlayer.pause()
        }
        activePlayer = player
        activeMediaID = mediaID
    }

    func resumePosition(for mediaID: String, duration: Double) -> Double? {
        guard let seconds = positions[mediaID], seconds >= 3,
              duration <= 0 || seconds < duration - 3 else { return nil }
        return seconds
    }

    func record(
        mediaID: String,
        seconds: Double,
        duration: Double,
        forcePersistence: Bool = false
    ) {
        guard seconds.isFinite, duration.isFinite else { return }
        if seconds < 3 || (duration > 0 && seconds >= duration - 3) {
            clear(mediaID: mediaID)
            return
        }
        positions[mediaID] = seconds
        let wholeSecond = Int(seconds)
        let shouldPersist = forcePersistence
            || abs(wholeSecond - (lastPersistedSecond[mediaID] ?? -10)) >= 10
        guard shouldPersist else { return }
        lastPersistedSecond[mediaID] = wholeSecond
        persist()
    }

    func release(_ player: AVPlayer, mediaID: String, seconds: Double, duration: Double) {
        record(
            mediaID: mediaID,
            seconds: seconds,
            duration: duration,
            forcePersistence: true
        )
        if activePlayer === player {
            activePlayer = nil
            activeMediaID = nil
        }
    }

    func clear(mediaID: String) {
        guard positions.removeValue(forKey: mediaID) != nil else { return }
        lastPersistedSecond[mediaID] = nil
        persist()
    }

    private func persist() {
        if positions.count > 200 {
            positions = Dictionary(uniqueKeysWithValues: positions
                .sorted { $0.value > $1.value }
                .prefix(200)
                .map { ($0.key, $0.value) })
        }
        defaults.set(positions, forKey: Self.positionsKey)
    }
}

@MainActor
final class NativeInlineVideoPlayerModel: ObservableObject {
    enum Phase: Equatable {
        case resolving
        case poster
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .resolving
    @Published private(set) var player: AVPlayer?
    @Published private(set) var poster: NSImage?
    @Published private(set) var currentSeconds = 0.0
    @Published private(set) var duration = 0.0

    let mediaID: String
    let isAudio: Bool
    private var fileURL: URL?
    private weak var resolvedStore: LocalBlogStore?
    private var hasResolvedPoster = false
    private var resolvedPosterMaxPixelSize: Int?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var periodicTimeObserver: Any?
    private var didReachEndObserver: NSObjectProtocol?
    private var loadGeneration = 0

    init(mediaID: String, isAudio: Bool = false) {
        self.mediaID = mediaID
        self.isAudio = isAudio
    }

    private var mediaTypeLabel: String { isAudio ? NativeLocalization.text("音频") : NativeLocalization.text("视频") }

    var resumeLabel: String? {
        guard let seconds = NativeVideoPlaybackCoordinator.shared.resumePosition(
            for: mediaID,
            duration: duration
        ) else { return nil }
        return NativeLocalization.text("从 \(Self.timeLabel(seconds)) 继续")
    }

    var progressLabel: String {
        guard duration > 0 else { return Self.timeLabel(currentSeconds) }
        return "\(Self.timeLabel(currentSeconds)) / \(Self.timeLabel(duration))"
    }

    func resolve(using store: LocalBlogStore, posterMaxPixelSize: Int = 1_280) async {
        // Lazy feed cells reappear as the viewport moves. Keep a completed
        // poster (and resume state) instead of publishing a loading cycle.
        if resolvedStore === store, resolvedPosterMaxPixelSize == posterMaxPixelSize, phase == .poster {
            if hasResolvedPoster { return }
            if let url = fileURL {
                let generation = loadGeneration
                let result = await NativeVideoThumbnailPipeline.shared.thumbnail(for: url, maxPixelSize: posterMaxPixelSize)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                poster = result.image
                hasResolvedPoster = true
                return
            }
        }
        releasePlayer(nextPhase: .resolving)
        let generation = loadGeneration
        resolvedStore = nil
        hasResolvedPoster = false
        poster = nil
        fileURL = nil
        currentSeconds = 0
        duration = 0
        let url = await store.mediaURL(for: mediaID)
        guard !Task.isCancelled, generation == loadGeneration else { return }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            phase = .failed(NativeLocalization.text("\(mediaTypeLabel)文件不存在"))
            return
        }
        fileURL = url
        if !isAudio {
            let result = await NativeVideoThumbnailPipeline.shared.thumbnail(for: url, maxPixelSize: posterMaxPixelSize)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            poster = result.image
        }
        resolvedStore = store
        hasResolvedPoster = true
        resolvedPosterMaxPixelSize = posterMaxPixelSize
        phase = .poster
    }

    func play() async {
        guard let fileURL else {
            phase = .failed(NativeLocalization.text("\(mediaTypeLabel)文件不存在"))
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        releasePlayer(nextPhase: .preparing, invalidatingLoad: false)
        let asset = AVURLAsset(url: fileURL)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            let assetDuration = try await asset.load(.duration)
            guard !Task.isCancelled, generation == loadGeneration else { return }
            guard isPlayable else {
                phase = .failed(NativeLocalization.text("不支持此\(mediaTypeLabel)格式或文件已损坏"))
                return
            }
            let seconds = assetDuration.seconds
            duration = seconds.isFinite ? max(0, seconds) : 0
            installPlayer(for: asset)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() async {
        await play()
    }

    func release(discardPoster: Bool = false) {
        loadGeneration += 1
        if player != nil || (phase != .poster && !(phase == .resolving && fileURL == nil)) {
            releasePlayer(nextPhase: fileURL == nil ? .resolving : .poster, invalidatingLoad: false)
        }
        if discardPoster, !isAudio {
            if poster != nil { poster = nil }
            hasResolvedPoster = false
        }
    }

    func copyTimestamp(named name: String) {
        let label = Self.timeLabel(currentSeconds)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(mediaTypeLabel)《\(name)》@ \(label)", forType: .string)
    }

    static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func installPlayer(for asset: AVAsset) {
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.handleStatus(of: item) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, player.timeControlStatus == .playing else { return }
                NativeVideoPlaybackCoordinator.shared.activate(player, mediaID: self.mediaID)
            }
        }
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.record(time: time.seconds) }
        }
        didReachEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentSeconds = self.duration
                NativeVideoPlaybackCoordinator.shared.clear(mediaID: self.mediaID)
            }
        }
    }

    private func handleStatus(of item: AVPlayerItem) {
        guard item === player?.currentItem else { return }
        switch item.status {
        case .unknown:
            phase = .preparing
        case .readyToPlay:
            if let player {
                let resume = NativeVideoPlaybackCoordinator.shared.resumePosition(
                    for: mediaID,
                    duration: duration
                ) ?? 0
                currentSeconds = resume
                if resume > 0 {
                    player.seek(
                        to: CMTime(seconds: resume, preferredTimescale: 600),
                        toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                        toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
                    ) { [weak self, weak player] _ in
                        Task { @MainActor [weak self, weak player] in
                            guard let self, let player, player === self.player else { return }
                            self.startPlayback(player)
                        }
                    }
                } else {
                    startPlayback(player)
                }
            } else {
                phase = .failed(NativeLocalization.text("播放器初始化失败"))
            }
        case .failed:
            phase = .failed(item.error?.localizedDescription ?? NativeLocalization.text("\(mediaTypeLabel)解码失败"))
            releasePlayer(nextPhase: phase)
        @unknown default:
            phase = .failed(NativeLocalization.text("未知的\(mediaTypeLabel)播放错误"))
            releasePlayer(nextPhase: phase)
        }
    }

    private func startPlayback(_ player: AVPlayer) {
        guard player === self.player else { return }
        phase = .ready
        NativeVideoPlaybackCoordinator.shared.activate(player, mediaID: mediaID)
        player.play()
    }

    private func record(time: Double) {
        guard phase == .ready, time.isFinite else { return }
        currentSeconds = max(0, time)
        NativeVideoPlaybackCoordinator.shared.record(
            mediaID: mediaID,
            seconds: currentSeconds,
            duration: duration
        )
    }

    private func releasePlayer(nextPhase: Phase, invalidatingLoad: Bool = true) {
        if invalidatingLoad { loadGeneration += 1 }
        itemStatusObservation = nil
        timeControlObservation = nil
        if let didReachEndObserver {
            NotificationCenter.default.removeObserver(didReachEndObserver)
            self.didReachEndObserver = nil
        }
        if let player, let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        periodicTimeObserver = nil
        if let player {
            player.pause()
            NativeVideoPlaybackCoordinator.shared.release(
                player,
                mediaID: mediaID,
                seconds: currentSeconds,
                duration: duration
            )
            player.replaceCurrentItem(with: nil)
        }
        player = nil
        phase = nextPhase
    }
}

import CoreServices
import Foundation

struct NativeMarkdownSourceChangeSet: Sendable {
    var relativePaths = Set<String>()
    var directoryPrefixes = Set<String>()
    var requiresFullScan = false
    var reloadsResources = false
    var reloadsPortableSidecar = false

    var isEmpty: Bool {
        !requiresFullScan && relativePaths.isEmpty && directoryPrefixes.isEmpty
            && !reloadsResources && !reloadsPortableSidecar
    }

    mutating func merge(_ other: NativeMarkdownSourceChangeSet) {
        requiresFullScan = requiresFullScan || other.requiresFullScan
        reloadsResources = reloadsResources || other.reloadsResources
        reloadsPortableSidecar = reloadsPortableSidecar || other.reloadsPortableSidecar
        relativePaths.formUnion(other.relativePaths)
        directoryPrefixes.formUnion(other.directoryPrefixes)
    }
}

final class MarkdownSourceEventMonitor: @unchecked Sendable {
    typealias Handler = @Sendable (NativeMarkdownSourceChangeSet) -> Void

    private let rootURL: URL
    private let queue = DispatchQueue(label: "leon-book.markdown-source-events", qos: .utility)
    private var stream: FSEventStreamRef?
    private var handler: Handler?

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    deinit {
        stop()
    }

    func start(handler: @escaping Handler) throws {
        stop()
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let nextStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            markdownSourceEventCallback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        ) else {
            self.handler = nil
            throw NativeStoreError.fileSystem("无法创建 Markdown 目录事件监听器")
        }
        stream = nextStream
        FSEventStreamSetDispatchQueue(nextStream, queue)
        guard FSEventStreamStart(nextStream) else {
            FSEventStreamInvalidate(nextStream)
            FSEventStreamRelease(nextStream)
            stream = nil
            self.handler = nil
            throw NativeStoreError.fileSystem("无法启动 Markdown 目录事件监听器")
        }
    }

    func stop() {
        guard let stream else {
            handler = nil
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        handler = nil
    }

    fileprivate func consume(
        paths: [String],
        flags: [FSEventStreamEventFlags]
    ) {
        var changes = NativeMarkdownSourceChangeSet()
        let rootPath = rootURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )

        for (path, eventFlags) in zip(paths, flags) {
            if eventFlags & rescanFlags != 0 {
                changes.requiresFullScan = true
                changes.reloadsResources = true
                break
            }
            guard path.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(path.dropFirst(rootPrefix.count))
                .precomposedStringWithCanonicalMapping
            guard !relativePath.isEmpty else { continue }
            if relativePath == NativePortableSidecarRepository.directoryName
                || relativePath.hasPrefix(NativePortableSidecarRepository.directoryName + "/") {
                changes.reloadsPortableSidecar = true
                continue
            }
            guard !relativePath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
                continue
            }
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                changes.directoryPrefixes.insert(relativePath)
                changes.reloadsResources = true
            } else if URL(fileURLWithPath: relativePath).pathExtension
                .caseInsensitiveCompare("md") == .orderedSame {
                changes.relativePaths.insert(relativePath)
                changes.reloadsResources = true
            } else {
                changes.reloadsResources = true
            }
        }
        if !changes.isEmpty { handler?(changes) }
    }
}

private let markdownSourceEventCallback: FSEventStreamCallback = {
    _, clientInfo, eventCount, eventPaths, eventFlags, _ in
    guard let clientInfo else { return }
    let monitor = Unmanaged<MarkdownSourceEventMonitor>
        .fromOpaque(clientInfo)
        .takeUnretainedValue()
    let pathArray = Unmanaged<CFArray>
        .fromOpaque(eventPaths)
        .takeUnretainedValue() as NSArray
    guard let paths = pathArray as? [String] else { return }
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))
    monitor.consume(paths: paths, flags: flags)
}

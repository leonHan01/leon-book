import CryptoKit
import Foundation

/// JSON Canvas 1.0 geometry, with namespaced metadata for live LeonBook references.
struct InfiniteCanvasDocument: Codable, Equatable {
    var nodes: [Node] = []
    var edges: [Edge] = []
    var leonbook = Metadata()

    struct Metadata: Codable, Equatable {
        var title = "未命名画布"
        var viewport = Viewport()
    }
    struct Viewport: Codable, Equatable {
        var x: Double = 80
        var y: Double = 80
        var zoom: Double = 1
    }
    struct Reference: Codable, Equatable {
        var kind: String
        var id: String
        var title: String
    }
    struct Node: Codable, Equatable {
        var id: String
        var type: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var text: String?
        var file: String?
        var url: String?
        var label: String?
        var color: String?
        var subpath: String?
        var background: String?
        var backgroundStyle: String?
        var leonbook: Reference?
    }
    struct Edge: Codable, Equatable {
        var id: String
        var fromNode: String
        var toNode: String
        var fromSide: String?
        var toSide: String?
        var fromEnd: String?
        var toEnd: String?
        var label: String?
        var color: String?
    }

    enum CodingKeys: CodingKey { case nodes, edges, leonbook }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try values.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        edges = try values.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        leonbook = try values.decodeIfPresent(Metadata.self, forKey: .leonbook) ?? Metadata()
    }

    static let maximumBytes = 8 * 1024 * 1024

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw InfiniteCanvasError.invalid("画布超过 8 MB。") }
        let document = try JSONDecoder().decode(Self.self, from: data)
        try document.validate()
        return document
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw InfiniteCanvasError.invalid("画布超过 8 MB。") }
        return data
    }

    func validate() throws {
        func require(_ value: Bool) throws {
            if !value { throw InfiniteCanvasError.invalid("画布包含无效的卡片、连线或坐标。") }
        }
        let viewport = leonbook.viewport
        try require(nodes.count <= 1_500 && edges.count <= 5_000 && leonbook.title.count <= 200)
        try require(viewport.x.isFinite && viewport.y.isFinite && (0.1...3).contains(viewport.zoom))
        var ids = Set<String>()
        for node in nodes {
            try require(!node.id.isEmpty && node.id.count <= 200 && ids.insert(node.id).inserted)
            try require([node.x, node.y].allSatisfy { $0.isFinite && abs($0) <= 10_000_000 })
            try require([node.width, node.height].allSatisfy { $0.isFinite && (32...20_000).contains($0) })
            switch node.type {
            case "text": try require(node.text != nil)
            case "file": try require(node.file != nil && Self.safeRelativePath(node.file!))
            case "link": try require(Self.webURL(node.url ?? "") != nil)
            case "group": break
            default: try require(false)
            }
            if let reference = node.leonbook {
                try require(["article", "moment", "attachment"].contains(reference.kind))
                try require(!reference.id.isEmpty && reference.id.count <= 2_000 && reference.title.count <= 1_000)
            }
        }
        let sides = ["top", "right", "bottom", "left"]
        for edge in edges {
            try require(!edge.id.isEmpty && ids.insert(edge.id).inserted)
            try require(nodes.contains { $0.id == edge.fromNode } && nodes.contains { $0.id == edge.toNode })
            try require(edge.fromSide.map(sides.contains) ?? true)
            try require(edge.toSide.map(sides.contains) ?? true)
            try require(edge.fromEnd.map { ["none", "arrow"].contains($0) } ?? true)
            try require(edge.toEnd.map { ["none", "arrow"].contains($0) } ?? true)
        }
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func safeRelativePath(_ path: String) -> Bool {
        let decoded = path.removingPercentEncoding ?? path
        return !decoded.isEmpty && !decoded.hasPrefix("/") && !decoded.contains("\\")
            && !decoded.contains("\0") && URL(string: decoded)?.scheme == nil
            && !decoded.split(separator: "/").contains("..")
    }
}

enum InfiniteCanvasError: LocalizedError {
    case conflict
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .conflict: return "画布已被其他窗口修改。当前修改将另存为冲突副本。"
        case .invalid(let reason): return reason
        }
    }
}

struct InfiniteCanvasSnapshot {
    var id: String
    var document: InfiniteCanvasDocument
    var revision: String
}

extension LocalBlogStore {
    func listCanvases() throws -> [[String: String]] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(
            at: canvasDirectory(), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "canvas" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            let title = (try? loadCanvas(id: id).document.leonbook.title) ?? "无法读取的画布 · \(id.prefix(8))"
            return ["id": id, "title": title]
        }
    }

    func loadCanvas(id: String) throws -> InfiniteCanvasSnapshot {
        try prepare()
        let data = try canvasData(at: canvasURL(id: id))
        return InfiniteCanvasSnapshot(id: id, document: try .decode(data), revision: canvasRevision(data))
    }

    func saveCanvas(id: String, document: InfiniteCanvasDocument, expectedRevision: String?) throws -> InfiniteCanvasSnapshot {
        try prepare()
        let url = try canvasURL(id: id)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let expectedRevision, canvasRevision(try canvasData(at: url)) == expectedRevision else {
                throw InfiniteCanvasError.conflict
            }
        } else if expectedRevision != nil { throw InfiniteCanvasError.conflict }
        let data = try document.encoded()
        try data.write(to: url, options: .atomic)
        return InfiniteCanvasSnapshot(id: id, document: document, revision: canvasRevision(data))
    }

    func deleteCanvas(id: String, expectedRevision: String) throws {
        try prepare()
        let url = try canvasURL(id: id)
        guard canvasRevision(try canvasData(at: url)) == expectedRevision else { throw InfiniteCanvasError.conflict }
        // Keep a recoverable file inside the workspace and its regular backups.
        let trash = try canvasDirectory().appendingPathComponent(".trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        guard trash.resolvingSymlinksInPath() == trash.standardizedFileURL else {
            throw InfiniteCanvasError.invalid("画布回收目录不能是符号链接。")
        }
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent("\(id)-\(UUID().uuidString).canvas"))
    }

    /// Only workspace-owned resources are readable, including after symlink resolution.
    func canvasResourceURL(path: String, source: String? = nil) -> URL? {
        if path.hasPrefix("/media/") || path.hasPrefix("media/") {
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard InfiniteCanvasDocument.safeRelativePath(relative) else { return nil }
            let root = mediaURL.standardizedFileURL.resolvingSymlinksInPath()
            let file = rootURL.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            return file.path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
        guard InfiniteCanvasDocument.safeRelativePath(path) else { return nil }
        let root = articlesURL.standardizedFileURL.resolvingSymlinksInPath()
        let relative = path.hasPrefix("articles/") ? String(path.dropFirst(9)) : path
        let base = source.map { root.appendingPathComponent($0).deletingLastPathComponent() } ?? root
        let file = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        return file.path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func canvasDirectory() throws -> URL {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("canvases", isDirectory: true)
        guard directory.resolvingSymlinksInPath() == directory else {
            throw InfiniteCanvasError.invalid("画布目录不能是符号链接。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func canvasURL(id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw InfiniteCanvasError.invalid("画布 ID 无效。") }
        let file = try canvasDirectory().appendingPathComponent(id + ".canvas")
        guard file.resolvingSymlinksInPath() == file else { throw InfiniteCanvasError.invalid("画布文件不能是符号链接。") }
        return file
    }

    private func canvasData(at url: URL) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= InfiniteCanvasDocument.maximumBytes else { throw InfiniteCanvasError.invalid("画布超过 8 MB。") }
        return try Data(contentsOf: url)
    }

    private func canvasRevision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

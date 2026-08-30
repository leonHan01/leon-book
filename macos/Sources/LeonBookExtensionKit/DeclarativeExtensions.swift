import Foundation

public enum DeclarativeExtensionCommandActionType: String, Codable, Hashable, Sendable {
    case insertText
    case newNote
}

public struct DeclarativeExtensionCommandAction: Codable, Hashable, Sendable {
    public let type: DeclarativeExtensionCommandActionType
    public let text: String?
    public let cursorOffset: Int?
    public let title: String?
    public let body: String?
    public let folder: String?

    public init(
        type: DeclarativeExtensionCommandActionType,
        text: String? = nil,
        cursorOffset: Int? = nil,
        title: String? = nil,
        body: String? = nil,
        folder: String? = nil
    ) {
        self.type = type
        self.text = text
        self.cursorOffset = cursorOffset
        self.title = title
        self.body = body
        self.folder = folder
    }
}

public struct DeclarativeExtensionCommand: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let keywords: String
    public let icon: String
    public let action: DeclarativeExtensionCommandAction

    public init(
        id: String,
        title: String,
        description: String = "",
        keywords: String = "",
        icon: String = "puzzlepiece.extension",
        action: DeclarativeExtensionCommandAction
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.keywords = keywords
        self.icon = icon
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, keywords, icon, action
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        keywords = try values.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        icon = try values.decodeIfPresent(String.self, forKey: .icon) ?? "puzzlepiece.extension"
        action = try values.decode(DeclarativeExtensionCommandAction.self, forKey: .action)
    }
}

public enum DeclarativeExtensionImporterFormat: String, Codable, Hashable, Sendable {
    case text
    case json
}

public struct DeclarativeExtensionImporter: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let fileExtensions: [String]
    public let format: DeclarativeExtensionImporterFormat
    public let titleTemplate: String
    public let bodyTemplate: String
    public let folderTemplate: String?
    public let maximumBytes: Int

    public init(
        id: String,
        title: String,
        description: String = "",
        fileExtensions: [String],
        format: DeclarativeExtensionImporterFormat = .text,
        titleTemplate: String = "{{basename}}",
        bodyTemplate: String = "{{content}}",
        folderTemplate: String? = nil,
        maximumBytes: Int = 1_048_576
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.fileExtensions = fileExtensions
        self.format = format
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
        self.folderTemplate = folderTemplate
        self.maximumBytes = maximumBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, description, fileExtensions, format
        case titleTemplate, bodyTemplate, folderTemplate, maximumBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        fileExtensions = try values.decode([String].self, forKey: .fileExtensions)
        format = try values.decodeIfPresent(DeclarativeExtensionImporterFormat.self, forKey: .format) ?? .text
        titleTemplate = try values.decodeIfPresent(String.self, forKey: .titleTemplate) ?? "{{basename}}"
        bodyTemplate = try values.decodeIfPresent(String.self, forKey: .bodyTemplate) ?? "{{content}}"
        folderTemplate = try values.decodeIfPresent(String.self, forKey: .folderTemplate)
        maximumBytes = try values.decodeIfPresent(Int.self, forKey: .maximumBytes) ?? 1_048_576
    }
}

public enum DeclarativeExtensionRendererStyle: String, Codable, Hashable, Sendable {
    case card
    case callout
    case quote
}

public struct DeclarativeExtensionRenderer: Codable, Hashable, Sendable {
    public let language: String
    public let titleTemplate: String
    public let bodyTemplate: String
    public let style: DeclarativeExtensionRendererStyle
    public let icon: String

    public init(
        language: String,
        titleTemplate: String,
        bodyTemplate: String = "{{content}}",
        style: DeclarativeExtensionRendererStyle = .card,
        icon: String = "rectangle.3.group"
    ) {
        self.language = language
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
        self.style = style
        self.icon = icon
    }

    private enum CodingKeys: String, CodingKey {
        case language, titleTemplate, bodyTemplate, style, icon
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decode(String.self, forKey: .language)
        titleTemplate = try values.decode(String.self, forKey: .titleTemplate)
        bodyTemplate = try values.decodeIfPresent(String.self, forKey: .bodyTemplate) ?? "{{content}}"
        style = try values.decodeIfPresent(DeclarativeExtensionRendererStyle.self, forKey: .style) ?? .card
        icon = try values.decodeIfPresent(String.self, forKey: .icon) ?? "rectangle.3.group"
    }
}

public struct DeclarativeExtensionBaseFunction: Codable, Hashable, Sendable {
    public let name: String
    public let parameters: [String]
    public let expression: String
    public let description: String

    public init(
        name: String,
        parameters: [String],
        expression: String,
        description: String = ""
    ) {
        self.name = name
        self.parameters = parameters
        self.expression = expression
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case name, parameters, expression, description
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        parameters = try values.decodeIfPresent([String].self, forKey: .parameters) ?? []
        expression = try values.decode(String.self, forKey: .expression)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

public struct DeclarativeExtensionManifest: Codable, Hashable, Sendable {
    public let manifestVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let author: String?
    public let commands: [DeclarativeExtensionCommand]
    public let templateVariables: [String: String]
    public let importers: [DeclarativeExtensionImporter]
    public let renderers: [DeclarativeExtensionRenderer]
    public let baseFunctions: [DeclarativeExtensionBaseFunction]

    public init(
        manifestVersion: Int = 1,
        id: String,
        name: String,
        version: String,
        description: String = "",
        author: String? = nil,
        commands: [DeclarativeExtensionCommand] = [],
        templateVariables: [String: String] = [:],
        importers: [DeclarativeExtensionImporter] = [],
        renderers: [DeclarativeExtensionRenderer] = [],
        baseFunctions: [DeclarativeExtensionBaseFunction] = []
    ) {
        self.manifestVersion = manifestVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.commands = commands
        self.templateVariables = templateVariables
        self.importers = importers
        self.renderers = renderers
        self.baseFunctions = baseFunctions
    }

    private enum CodingKeys: String, CodingKey {
        case manifestVersion, id, name, version, description, author
        case commands, templateVariables, importers, renderers, baseFunctions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        manifestVersion = try values.decode(Int.self, forKey: .manifestVersion)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(String.self, forKey: .version)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try values.decodeIfPresent(String.self, forKey: .author)
        commands = try values.decodeIfPresent([DeclarativeExtensionCommand].self, forKey: .commands) ?? []
        templateVariables = try values.decodeIfPresent([String: String].self, forKey: .templateVariables) ?? [:]
        importers = try values.decodeIfPresent([DeclarativeExtensionImporter].self, forKey: .importers) ?? []
        renderers = try values.decodeIfPresent([DeclarativeExtensionRenderer].self, forKey: .renderers) ?? []
        baseFunctions = try values.decodeIfPresent([DeclarativeExtensionBaseFunction].self, forKey: .baseFunctions) ?? []
    }
}

public struct DeclarativeExtensionPackage: Hashable, Identifiable, Sendable {
    public let directoryURL: URL
    public let manifest: DeclarativeExtensionManifest

    public init(directoryURL: URL, manifest: DeclarativeExtensionManifest) {
        self.directoryURL = directoryURL
        self.manifest = manifest
    }

    public var id: String { manifest.id }
}

public enum DeclarativeExtensionDiagnosticSeverity: String, Hashable, Sendable {
    case warning
    case error
}

public struct DeclarativeExtensionDiagnostic: Hashable, Identifiable, Sendable {
    public let packageName: String
    public let severity: DeclarativeExtensionDiagnosticSeverity
    public let message: String

    public init(
        packageName: String,
        severity: DeclarativeExtensionDiagnosticSeverity,
        message: String
    ) {
        self.packageName = packageName
        self.severity = severity
        self.message = message
    }

    public var id: String { "\(packageName)\u{0}\(severity.rawValue)\u{0}\(message)" }
}

public enum DeclarativeExtensionError: LocalizedError, Equatable {
    case invalidManifest(String)
    case unsupportedManifestVersion(Int)
    case duplicateExtension(String)
    case duplicateContribution(String)
    case unsafePackage(String)
    case fileTooLarge(Int)
    case unsupportedFileExtension(String)
    case unsupportedEncoding
    case importerNotFound
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case let .invalidManifest(message): return "扩展清单无效：\(message)"
        case let .unsupportedManifestVersion(version): return "不支持 manifestVersion \(version)"
        case let .duplicateExtension(id): return "重复的扩展 ID：\(id)"
        case let .duplicateContribution(name): return "扩展点冲突：\(name)"
        case let .unsafePackage(name): return "扩展包包含不安全的路径或链接：\(name)"
        case let .fileTooLarge(limit): return "文件超过扩展导入器的 \(limit) 字节限制"
        case let .unsupportedFileExtension(value): return "导入器不支持 .\(value) 文件"
        case .unsupportedEncoding: return "文件不是受支持的 UTF-8/UTF-16 文本"
        case .importerNotFound: return "找不到或未启用该导入器"
        case .invalidJSON: return "JSON 文件内容无效"
        }
    }
}

public struct DeclarativeExtensionCommandRegistration: Hashable, Sendable {
    public let extensionID: String
    public let extensionName: String
    public let command: DeclarativeExtensionCommand

    public var commandID: String { "extension.\(extensionID).command.\(command.id)" }
}

public struct DeclarativeExtensionImporterRegistration: Hashable, Sendable {
    public let extensionID: String
    public let extensionName: String
    public let importer: DeclarativeExtensionImporter

    public var commandID: String { "extension.\(extensionID).import.\(importer.id)" }
}

public struct DeclarativeExtensionRendererRegistration: Hashable, Sendable {
    public let extensionID: String
    public let extensionName: String
    public let renderer: DeclarativeExtensionRenderer
}

public struct DeclarativeExtensionBaseFunctionRegistration: Hashable, Sendable {
    public let extensionID: String
    public let extensionName: String
    public let function: DeclarativeExtensionBaseFunction
}

public struct DeclarativeTemplateResult: Equatable, Sendable {
    public let value: String
    public let unresolvedVariables: [String]

    public init(value: String, unresolvedVariables: [String]) {
        self.value = value
        self.unresolvedVariables = unresolvedVariables
    }
}

public struct DeclarativeImportedDocument: Equatable, Sendable {
    public let title: String
    public let body: String
    public let folder: String?
    public let unresolvedVariables: [String]

    public init(title: String, body: String, folder: String?, unresolvedVariables: [String]) {
        self.title = title
        self.body = body
        self.folder = folder
        self.unresolvedVariables = unresolvedVariables
    }
}

public struct DeclarativeRenderedBlock: Equatable, Sendable {
    public let title: String
    public let body: String
    public let icon: String
    public let style: DeclarativeExtensionRendererStyle
    public let extensionName: String

    public init(
        title: String,
        body: String,
        icon: String,
        style: DeclarativeExtensionRendererStyle,
        extensionName: String
    ) {
        self.title = title
        self.body = body
        self.icon = icon
        self.style = style
        self.extensionName = extensionName
    }
}

/// One small discovery interface for every declarative capability. The host
/// supplies native adapters; manifests never receive executable code handles.
public struct DeclarativeExtensionRuntime: Sendable {
    public static let empty = DeclarativeExtensionRuntime(packages: [], diagnostics: [])

    public let packages: [DeclarativeExtensionPackage]
    public let diagnostics: [DeclarativeExtensionDiagnostic]
    public private(set) var disabledExtensionIDs: Set<String>

    public init(
        packages: [DeclarativeExtensionPackage],
        disabledExtensionIDs: Set<String> = [],
        diagnostics: [DeclarativeExtensionDiagnostic] = []
    ) {
        self.packages = packages.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        self.disabledExtensionIDs = disabledExtensionIDs
        self.diagnostics = diagnostics
    }

    public func isEnabled(_ extensionID: String) -> Bool {
        packages.contains(where: { $0.id == extensionID }) && !disabledExtensionIDs.contains(extensionID)
    }

    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, extensionID: String) -> Bool {
        guard packages.contains(where: { $0.id == extensionID }), isEnabled(extensionID) != enabled else {
            return false
        }
        if enabled { disabledExtensionIDs.remove(extensionID) }
        else { disabledExtensionIDs.insert(extensionID) }
        return true
    }

    public var activePackages: [DeclarativeExtensionPackage] {
        packages.filter { isEnabled($0.id) }
    }

    public var commands: [DeclarativeExtensionCommandRegistration] {
        activePackages.flatMap { package in
            package.manifest.commands.map {
                DeclarativeExtensionCommandRegistration(
                    extensionID: package.id,
                    extensionName: package.manifest.name,
                    command: $0
                )
            }
        }
    }

    public var importers: [DeclarativeExtensionImporterRegistration] {
        activePackages.flatMap { package in
            package.manifest.importers.map {
                DeclarativeExtensionImporterRegistration(
                    extensionID: package.id,
                    extensionName: package.manifest.name,
                    importer: $0
                )
            }
        }
    }

    public var renderers: [DeclarativeExtensionRendererRegistration] {
        activePackages.flatMap { package in
            package.manifest.renderers.map {
                DeclarativeExtensionRendererRegistration(
                    extensionID: package.id,
                    extensionName: package.manifest.name,
                    renderer: $0
                )
            }
        }
    }

    public var baseFunctions: [DeclarativeExtensionBaseFunctionRegistration] {
        activePackages.flatMap { package in
            package.manifest.baseFunctions.map {
                DeclarativeExtensionBaseFunctionRegistration(
                    extensionID: package.id,
                    extensionName: package.manifest.name,
                    function: $0
                )
            }
        }
    }

    public var templateVariables: [String: String] {
        activePackages.reduce(into: [:]) { variables, package in
            variables.merge(package.manifest.templateVariables) { current, _ in current }
        }
    }

    public func command(for commandID: String) -> DeclarativeExtensionCommandRegistration? {
        commands.first { $0.commandID == commandID }
    }

    public func importer(for commandID: String) -> DeclarativeExtensionImporterRegistration? {
        importers.first { $0.commandID == commandID }
    }

    public func renderer(for language: String?) -> DeclarativeExtensionRendererRegistration? {
        guard let language = language?
            .split(whereSeparator: { $0.isWhitespace }).first
            .map({ String($0).lowercased() }) else { return nil }
        return renderers.first { $0.renderer.language.lowercased() == language }
    }

    public func renderTemplate(
        _ template: String,
        context: [String: String] = [:],
        now: Date = Date()
    ) -> DeclarativeTemplateResult {
        var variables = templateVariables
        variables.merge(DeclarativeTemplateEngine.standardVariables(now: now)) { _, latest in latest }
        variables.merge(context) { _, latest in latest }
        return DeclarativeTemplateEngine.render(template, variables: variables)
    }

    public func renderBlock(
        language: String?,
        content: String,
        now: Date = Date()
    ) -> DeclarativeRenderedBlock? {
        guard let registration = renderer(for: language) else { return nil }
        let context = [
            "content": content,
            "language": registration.renderer.language,
            "extension.name": registration.extensionName,
        ]
        let title = renderTemplate(registration.renderer.titleTemplate, context: context, now: now).value
        let body = renderTemplate(registration.renderer.bodyTemplate, context: context, now: now).value
        return DeclarativeRenderedBlock(
            title: title,
            body: body,
            icon: registration.renderer.icon,
            style: registration.renderer.style,
            extensionName: registration.extensionName
        )
    }

    public func importDocument(
        using registration: DeclarativeExtensionImporterRegistration,
        data: Data,
        fileName: String,
        context: [String: String] = [:],
        now: Date = Date()
    ) throws -> DeclarativeImportedDocument {
        guard importers.contains(registration) else { throw DeclarativeExtensionError.importerNotFound }
        guard data.count <= registration.importer.maximumBytes else {
            throw DeclarativeExtensionError.fileTooLarge(registration.importer.maximumBytes)
        }
        let selectedExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        guard registration.importer.fileExtensions.contains(where: {
            $0.caseInsensitiveCompare(selectedExtension) == .orderedSame
        }) else {
            throw DeclarativeExtensionError.unsupportedFileExtension(selectedExtension)
        }
        guard let content = Self.decodeText(data) else { throw DeclarativeExtensionError.unsupportedEncoding }
        let fileURL = URL(fileURLWithPath: fileName)
        var variables = context
        variables["content"] = content
        variables["filename"] = fileURL.lastPathComponent
        variables["basename"] = fileURL.deletingPathExtension().lastPathComponent
        variables["extension"] = fileURL.pathExtension.lowercased()
        if registration.importer.format == .json {
            guard let object = try? JSONSerialization.jsonObject(with: data) else {
                throw DeclarativeExtensionError.invalidJSON
            }
            Self.flattenJSON(object, prefix: "json", into: &variables, depth: 0)
        }
        let title = renderTemplate(registration.importer.titleTemplate, context: variables, now: now)
        let body = renderTemplate(registration.importer.bodyTemplate, context: variables, now: now)
        let folder = registration.importer.folderTemplate.map {
            renderTemplate($0, context: variables, now: now)
        }
        return DeclarativeImportedDocument(
            title: title.value,
            body: body.value,
            folder: folder?.value,
            unresolvedVariables: Set(title.unresolvedVariables + body.unresolvedVariables + (folder?.unresolvedVariables ?? [])).sorted()
        )
    }

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
    }

    private static func flattenJSON(
        _ value: Any,
        prefix: String,
        into variables: inout [String: String],
        depth: Int
    ) {
        guard depth < 8, variables.count < 512 else { return }
        switch value {
        case let dictionary as [String: Any]:
            for key in dictionary.keys.sorted().prefix(128) {
                guard DeclarativeExtensionSecurity.isTemplateVariable(key) else { continue }
                guard let child = dictionary[key] else { continue }
                flattenJSON(child, prefix: "\(prefix).\(key)", into: &variables, depth: depth + 1)
            }
        case let array as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: array),
               let text = String(data: data, encoding: .utf8) {
                variables[prefix] = text
            }
        case let string as String: variables[prefix] = string
        case let number as NSNumber: variables[prefix] = number.stringValue
        case is NSNull: variables[prefix] = ""
        default: variables[prefix] = String(describing: value)
        }
    }
}

public enum DeclarativeTemplateEngine {
    private static let placeholder = try! NSRegularExpression(
        pattern: #"\{\{([A-Za-z][A-Za-z0-9_.-]{0,63})\}\}"#
    )

    public static func standardVariables(now: Date = Date()) -> [String: String] {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.calendar = Calendar(identifier: .gregorian)
        date.timeZone = .current
        date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = date.locale
        time.calendar = date.calendar
        time.timeZone = date.timeZone
        time.dateFormat = "HH:mm"
        let dateTime = ISO8601DateFormatter()
        dateTime.timeZone = .current
        return [
            "date": date.string(from: now),
            "time": time.string(from: now),
            "datetime": dateTime.string(from: now),
        ]
    }

    public static func render(_ template: String, variables: [String: String]) -> DeclarativeTemplateResult {
        var rendered = template
        for _ in 0..<8 {
            let matches = placeholder.matches(
                in: rendered,
                range: NSRange(rendered.startIndex..., in: rendered)
            )
            var changed = false
            for match in matches.reversed() {
                guard let keyRange = Range(match.range(at: 1), in: rendered),
                      let wholeRange = Range(match.range(at: 0), in: rendered),
                      let replacement = variables[String(rendered[keyRange])] else { continue }
                rendered.replaceSubrange(wholeRange, with: replacement)
                changed = true
            }
            if !changed { break }
        }
        let unresolved = Set(placeholder.matches(
            in: rendered,
            range: NSRange(rendered.startIndex..., in: rendered)
        ).compactMap { match -> String? in
            Range(match.range(at: 1), in: rendered).map { String(rendered[$0]) }
        }).sorted()
        return DeclarativeTemplateResult(value: rendered, unresolvedVariables: unresolved)
    }
}

public enum DeclarativeExtensionSecurity {
    public static func isSafeRelativePath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.hasPrefix("/"), !normalized.contains("\u{0}") else { return false }
        return normalized.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    public static func isTemplateVariable(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil
    }
}

public enum DeclarativeExtensionLoader {
    private static let maximumManifestBytes = 262_144

    public static func load(
        from rootURL: URL,
        disabledExtensionIDs: Set<String> = [],
        fileManager: FileManager = .default
    ) throws -> DeclarativeExtensionRuntime {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return DeclarativeExtensionRuntime(packages: [], disabledExtensionIDs: disabledExtensionIDs)
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var packages: [DeclarativeExtensionPackage] = []
        var diagnostics: [DeclarativeExtensionDiagnostic] = []
        var extensionIDs = Set<String>()
        var globalVariables = Set<String>()
        var globalRenderers = Set<String>()
        var globalFunctions = Set<String>()

        for child in children {
            let packageName = child.lastPathComponent
            do {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw DeclarativeExtensionError.unsafePackage(packageName)
                }
                let resolved = child.standardizedFileURL.resolvingSymlinksInPath()
                guard isInside(resolved, root: root) else {
                    throw DeclarativeExtensionError.unsafePackage(packageName)
                }
                let manifestURL = child.appendingPathComponent("extension.json")
                let manifestValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard manifestValues.isRegularFile == true,
                      manifestValues.isSymbolicLink != true,
                      isInside(manifestURL.resolvingSymlinksInPath(), root: resolved) else {
                    throw DeclarativeExtensionError.unsafePackage(packageName)
                }
                guard (manifestValues.fileSize ?? 0) <= maximumManifestBytes else {
                    throw DeclarativeExtensionError.fileTooLarge(maximumManifestBytes)
                }
                let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
                let manifest = try JSONDecoder().decode(DeclarativeExtensionManifest.self, from: data)
                try validate(manifest)
                guard !extensionIDs.contains(manifest.id) else {
                    throw DeclarativeExtensionError.duplicateExtension(manifest.id)
                }
                let variables = Set(manifest.templateVariables.keys.map { $0.lowercased() })
                let renderers = Set(manifest.renderers.map { $0.language.lowercased() })
                let functions = Set(manifest.baseFunctions.map { $0.name.lowercased() })
                if let duplicate = variables.intersection(globalVariables).first {
                    throw DeclarativeExtensionError.duplicateContribution("模板变量 \(duplicate)")
                }
                if let duplicate = renderers.intersection(globalRenderers).first {
                    throw DeclarativeExtensionError.duplicateContribution("渲染语言 \(duplicate)")
                }
                if let duplicate = functions.intersection(globalFunctions).first {
                    throw DeclarativeExtensionError.duplicateContribution("Base 函数 \(duplicate)")
                }
                extensionIDs.insert(manifest.id)
                globalVariables.formUnion(variables)
                globalRenderers.formUnion(renderers)
                globalFunctions.formUnion(functions)
                packages.append(DeclarativeExtensionPackage(directoryURL: resolved, manifest: manifest))
            } catch {
                diagnostics.append(DeclarativeExtensionDiagnostic(
                    packageName: packageName,
                    severity: .error,
                    message: error.localizedDescription
                ))
            }
        }
        return DeclarativeExtensionRuntime(
            packages: packages,
            disabledExtensionIDs: disabledExtensionIDs,
            diagnostics: diagnostics
        )
    }

    public static func validate(_ manifest: DeclarativeExtensionManifest) throws {
        guard manifest.manifestVersion == 1 else {
            throw DeclarativeExtensionError.unsupportedManifestVersion(manifest.manifestVersion)
        }
        try require(manifest.id.range(
            of: #"^[a-z0-9][a-z0-9.-]{2,63}$"#,
            options: .regularExpression
        ) != nil, "id 必须是 3–64 位小写命名空间")
        try require(!manifest.name.isEmpty && manifest.name.count <= 80, "name 长度必须为 1–80")
        try require(manifest.version.range(
            of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#,
            options: .regularExpression
        ) != nil, "version 必须使用语义版本格式")
        try require(manifest.description.count <= 500, "description 过长")
        try require(manifest.commands.count <= 64, "commands 最多 64 个")
        try require(manifest.templateVariables.count <= 128, "templateVariables 最多 128 个")
        try require(manifest.importers.count <= 32, "importers 最多 32 个")
        try require(manifest.renderers.count <= 32, "renderers 最多 32 个")
        try require(manifest.baseFunctions.count <= 64, "baseFunctions 最多 64 个")

        var contributionIDs = Set<String>()
        for command in manifest.commands {
            try validateContributionID(command.id, kind: "命令")
            try require(contributionIDs.insert("command:\(command.id)").inserted, "命令 ID 重复：\(command.id)")
            try require(!command.title.isEmpty && command.title.count <= 80, "命令标题无效：\(command.id)")
            try require(command.description.count <= 240 && command.keywords.count <= 240, "命令描述过长：\(command.id)")
            switch command.action.type {
            case .insertText:
                try require(command.action.text != nil, "insertText 命令缺少 text：\(command.id)")
                try validateTemplate(command.action.text ?? "", label: "命令 \(command.id)")
                try require((command.action.cursorOffset ?? 0) >= 0, "cursorOffset 不能为负数")
            case .newNote:
                try require(command.action.title != nil || command.action.body != nil, "newNote 命令至少需要 title 或 body")
                try validateTemplate(command.action.title ?? "", label: "命令 \(command.id) 标题")
                try validateTemplate(command.action.body ?? "", label: "命令 \(command.id) 正文")
                if let folder = command.action.folder { try validateFolderTemplate(folder) }
            }
        }

        var variableNames = Set<String>()
        for (name, value) in manifest.templateVariables {
            try require(DeclarativeExtensionSecurity.isTemplateVariable(name), "模板变量名无效：\(name)")
            try require(!reservedTemplateVariables.contains(name.lowercased()), "不能覆盖宿主模板变量：\(name)")
            try require(variableNames.insert(name.lowercased()).inserted, "模板变量重复：\(name)")
            try validateTemplate(value, label: "模板变量 \(name)", maximumLength: 8_192)
        }

        for importer in manifest.importers {
            try validateContributionID(importer.id, kind: "导入器")
            try require(contributionIDs.insert("importer:\(importer.id)").inserted, "导入器 ID 重复：\(importer.id)")
            try require(!importer.title.isEmpty && importer.title.count <= 80, "导入器标题无效：\(importer.id)")
            try require(!importer.fileExtensions.isEmpty && importer.fileExtensions.count <= 16, "导入器扩展名必须为 1–16 个")
            for fileExtension in importer.fileExtensions {
                try require(fileExtension.range(of: #"^[A-Za-z0-9]{1,12}$"#, options: .regularExpression) != nil, "文件扩展名无效：\(fileExtension)")
            }
            try require((1...4_194_304).contains(importer.maximumBytes), "maximumBytes 必须在 1–4194304")
            try validateTemplate(importer.titleTemplate, label: "导入器 \(importer.id) 标题")
            try validateTemplate(importer.bodyTemplate, label: "导入器 \(importer.id) 正文")
            if let folder = importer.folderTemplate { try validateFolderTemplate(folder) }
        }

        var languages = Set<String>()
        for renderer in manifest.renderers {
            let language = renderer.language.lowercased()
            try require(language.range(of: #"^[a-z][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil, "渲染语言无效：\(renderer.language)")
            try require(languages.insert(language).inserted, "渲染语言重复：\(renderer.language)")
            try require(!["mermaid", "math", "latex", "tex", "html-render", "embed"].contains(language), "不能覆盖内置渲染器：\(language)")
            try validateTemplate(renderer.titleTemplate, label: "渲染器 \(language) 标题", maximumLength: 1_024)
            try validateTemplate(renderer.bodyTemplate, label: "渲染器 \(language) 正文")
        }

        var functionNames = Set<String>()
        for function in manifest.baseFunctions {
            let name = function.name.lowercased()
            try require(name.range(of: #"^[a-z][a-z0-9_]{1,31}$"#, options: .regularExpression) != nil, "Base 函数名无效：\(function.name)")
            try require(functionNames.insert(name).inserted, "Base 函数重复：\(function.name)")
            try require(!builtInBaseFunctions.contains(name), "不能覆盖内置 Base 函数：\(function.name)")
            try require(function.parameters.count <= 8, "Base 函数参数最多 8 个：\(function.name)")
            var parameters = Set<String>()
            for parameter in function.parameters {
                try require(parameter.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,31}$"#, options: .regularExpression) != nil, "Base 参数名无效：\(parameter)")
                try require(parameters.insert(parameter.lowercased()).inserted, "Base 参数重复：\(parameter)")
            }
            try require(!function.expression.isEmpty && function.expression.count <= 2_048, "Base 表达式长度无效：\(function.name)")
        }
    }

    private static let builtInBaseFunctions: Set<String> = [
        "today", "now", "date", "prop", "daysbetween", "if", "round",
        "abs", "length", "lower", "upper", "formatdate", "min", "max",
    ]

    private static let reservedTemplateVariables: Set<String> = [
        "date", "time", "datetime", "user", "selection", "note.title", "note.body",
        "content", "language", "extension.name", "filename", "basename", "extension",
    ]

    private static func validateContributionID(_ id: String, kind: String) throws {
        try require(id.range(of: #"^[a-z][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil, "\(kind) ID 无效：\(id)")
    }

    private static func validateFolderTemplate(_ template: String) throws {
        try validateTemplate(template, label: "文件夹", maximumLength: 512)
        let placeholderStripped = template.replacingOccurrences(
            of: #"\{\{[A-Za-z][A-Za-z0-9_.-]{0,63}\}\}"#,
            with: "variable",
            options: .regularExpression
        )
        try require(DeclarativeExtensionSecurity.isSafeRelativePath(placeholderStripped), "文件夹必须是安全的相对路径")
    }

    private static func validateTemplate(
        _ template: String,
        label: String,
        maximumLength: Int = 65_536
    ) throws {
        try require(template.count <= maximumLength, "\(label) 模板过长")
        let lowered = template.lowercased()
        let forbidden = ["<script", "javascript:", "```html-render", "~~~html-render"]
        try require(!forbidden.contains(where: lowered.contains), "\(label) 含被禁止的可执行内容")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DeclarativeExtensionError.invalidManifest(message) }
    }

    private static func isInside(_ child: URL, root: URL) -> Bool {
        child.path == root.path || child.path.hasPrefix(root.path + "/")
    }
}

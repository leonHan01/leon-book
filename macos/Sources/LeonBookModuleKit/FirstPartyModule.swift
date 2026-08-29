import Foundation

public struct FirstPartyModuleID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }
}

public struct FirstPartyModulePermission: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let contentRead = Self(rawValue: "content.read")
    public static let contentWrite = Self(rawValue: "content.write")
    public static let fileRead = Self(rawValue: "file.read")
    public static let fileWrite = Self(rawValue: "file.write")
    public static let contentPublish = Self(rawValue: "content.publish")
    public static let backupRead = Self(rawValue: "backup.read")
    public static let backupWrite = Self(rawValue: "backup.write")
}

public enum FirstPartyModuleCommandAvailability: String, Codable, Hashable, Sendable {
    case always
    case storageReady
    case storageReadyAndIdle
    case articleEditor
    case articleEditorAndIdle
}

public enum FirstPartyModuleCommandSurface: String, Codable, Hashable, Sendable {
    case palette
    case menu
    case editorSlash
    case automation
}

public struct FirstPartyModuleCommandShortcut: Codable, Hashable, Sendable {
    public enum Modifier: String, Codable, Hashable, Sendable {
        case command
        case option
        case shift
        case control
    }

    public let key: String
    public let modifiers: Set<Modifier>

    public init(key: String, modifiers: Set<Modifier>) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Complete, UI-independent command declaration owned by a feature module.
/// The host maps it to the native command adapter and supplies the handler.
public struct FirstPartyModuleCommand: Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let keywords: String
    public let systemImage: String
    public let availability: FirstPartyModuleCommandAvailability
    public let surfaces: Set<FirstPartyModuleCommandSurface>
    public let defaultShortcut: FirstPartyModuleCommandShortcut?
    public let requiredPermissions: Set<FirstPartyModulePermission>

    public init(
        id: String,
        title: String,
        detail: String,
        keywords: String = "",
        systemImage: String,
        availability: FirstPartyModuleCommandAvailability = .storageReady,
        surfaces: Set<FirstPartyModuleCommandSurface> = [.palette, .menu],
        defaultShortcut: FirstPartyModuleCommandShortcut? = nil,
        requiredPermissions: Set<FirstPartyModulePermission> = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.systemImage = systemImage
        self.availability = availability
        self.surfaces = surfaces
        self.defaultShortcut = defaultShortcut
        self.requiredPermissions = requiredPermissions
    }
}

public struct FirstPartyModuleDescriptor: Codable, Hashable, Identifiable, Sendable {
    public static let lifecycleEventNames: Set<String> = [
        "module.enabled",
        "module.disabled",
        "module.authorization-denied",
    ]

    public let id: FirstPartyModuleID
    public let name: String
    public let summary: String
    public let systemImage: String
    public let permissions: Set<FirstPartyModulePermission>
    public let commands: [FirstPartyModuleCommand]
    public let eventNames: Set<String>

    public init(
        id: FirstPartyModuleID,
        name: String,
        summary: String,
        systemImage: String,
        permissions: Set<FirstPartyModulePermission>,
        commands: [FirstPartyModuleCommand] = [],
        eventNames: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.systemImage = systemImage
        self.permissions = permissions
        self.commands = commands
        self.eventNames = eventNames.union(Self.lifecycleEventNames)
    }
}

public protocol FirstPartyModule {
    static var descriptor: FirstPartyModuleDescriptor { get }
}

public enum FirstPartyModuleCatalogError: LocalizedError, Equatable {
    case duplicateModule(String)
    case duplicateCommand(String)
    case undeclaredPermission(module: String, command: String, permission: String)

    public var errorDescription: String? {
        switch self {
        case let .duplicateModule(id):
            return "重复的第一方模块 ID：\(id)"
        case let .duplicateCommand(id):
            return "重复的第一方模块命令 ID：\(id)"
        case let .undeclaredPermission(module, command, permission):
            return "模块 \(module) 的命令 \(command) 使用了未声明权限 \(permission)"
        }
    }
}

/// The single discovery seam for first-party capabilities. It owns uniqueness,
/// command ownership and permission-declaration validation.
public struct FirstPartyModuleCatalog: Sendable {
    public let modules: [FirstPartyModuleDescriptor]
    private let modulesByID: [FirstPartyModuleID: FirstPartyModuleDescriptor]
    private let commandOwners: [String: FirstPartyModuleID]

    public init(_ modules: [FirstPartyModuleDescriptor]) throws {
        var seenModules = Set<FirstPartyModuleID>()
        var owners: [String: FirstPartyModuleID] = [:]
        for module in modules {
            guard seenModules.insert(module.id).inserted else {
                throw FirstPartyModuleCatalogError.duplicateModule(module.id.rawValue)
            }
            for command in module.commands {
                guard owners.updateValue(module.id, forKey: command.id) == nil else {
                    throw FirstPartyModuleCatalogError.duplicateCommand(command.id)
                }
                for permission in command.requiredPermissions where !module.permissions.contains(permission) {
                    throw FirstPartyModuleCatalogError.undeclaredPermission(
                        module: module.id.rawValue,
                        command: command.id,
                        permission: permission.rawValue
                    )
                }
            }
        }
        self.modules = modules
        modulesByID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
        commandOwners = owners
    }

    public func module(for id: FirstPartyModuleID) -> FirstPartyModuleDescriptor? {
        modulesByID[id]
    }

    public func module(owningCommand commandID: String) -> FirstPartyModuleDescriptor? {
        commandOwners[commandID].flatMap { modulesByID[$0] }
    }

    public func command(_ commandID: String) -> FirstPartyModuleCommand? {
        module(owningCommand: commandID)?.commands.first { $0.id == commandID }
    }

    public func canPublishEvent(_ name: String, from moduleID: FirstPartyModuleID) -> Bool {
        modulesByID[moduleID]?.eventNames.contains(name) == true
    }
}

public struct FirstPartyModuleState: Codable, Equatable, Sendable {
    public private(set) var disabledModuleIDs: Set<FirstPartyModuleID>

    public init(disabledModuleIDs: Set<FirstPartyModuleID> = []) {
        self.disabledModuleIDs = disabledModuleIDs
    }

    public func isEnabled(_ moduleID: FirstPartyModuleID) -> Bool {
        !disabledModuleIDs.contains(moduleID)
    }

    public mutating func setEnabled(_ enabled: Bool, for moduleID: FirstPartyModuleID) {
        if enabled {
            disabledModuleIDs.remove(moduleID)
        } else {
            disabledModuleIDs.insert(moduleID)
        }
    }

    public mutating func removeUnknownModules(using catalog: FirstPartyModuleCatalog) {
        let known = Set(catalog.modules.map(\.id))
        disabledModuleIDs.formIntersection(known)
    }
}

public enum FirstPartyModuleAuthorization: Equatable, Sendable {
    case allowed
    case disabled(FirstPartyModuleID)
    case unknownModule(FirstPartyModuleID)
    case undeclaredPermission(FirstPartyModuleID, FirstPartyModulePermission)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Mutable enablement and permission boundary. Product code asks this runtime
/// before invoking a module; feature targets never reach into app state.
public struct FirstPartyModuleRuntime: Sendable {
    public let catalog: FirstPartyModuleCatalog
    public private(set) var state: FirstPartyModuleState

    public init(catalog: FirstPartyModuleCatalog, state: FirstPartyModuleState = .init()) {
        self.catalog = catalog
        var sanitized = state
        sanitized.removeUnknownModules(using: catalog)
        self.state = sanitized
    }

    public func isEnabled(_ moduleID: FirstPartyModuleID) -> Bool {
        catalog.module(for: moduleID) != nil && state.isEnabled(moduleID)
    }

    public func authorization(
        for moduleID: FirstPartyModuleID,
        permission: FirstPartyModulePermission
    ) -> FirstPartyModuleAuthorization {
        guard let module = catalog.module(for: moduleID) else { return .unknownModule(moduleID) }
        guard state.isEnabled(moduleID) else { return .disabled(moduleID) }
        guard module.permissions.contains(permission) else {
            return .undeclaredPermission(moduleID, permission)
        }
        return .allowed
    }

    /// Commands not owned by a feature module remain core commands and pass.
    public func authorization(forCommand commandID: String) -> FirstPartyModuleAuthorization {
        guard let module = catalog.module(owningCommand: commandID),
              let command = catalog.command(commandID) else { return .allowed }
        guard state.isEnabled(module.id) else { return .disabled(module.id) }
        guard command.requiredPermissions.isSubset(of: module.permissions) else {
            let permission = command.requiredPermissions.subtracting(module.permissions).first!
            return .undeclaredPermission(module.id, permission)
        }
        return .allowed
    }

    public mutating func setEnabled(_ enabled: Bool, for moduleID: FirstPartyModuleID) -> Bool {
        guard catalog.module(for: moduleID) != nil, state.isEnabled(moduleID) != enabled else {
            return false
        }
        state.setEnabled(enabled, for: moduleID)
        return true
    }
}

public struct FirstPartyModuleEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let moduleID: FirstPartyModuleID
    public let name: String
    public let occurredAt: Date
    public let payload: [String: String]

    public init(
        moduleID: FirstPartyModuleID,
        name: String,
        occurredAt: Date = Date(),
        payload: [String: String] = [:]
    ) {
        id = UUID()
        self.moduleID = moduleID
        self.name = name
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

public final class FirstPartyModuleEventBus: @unchecked Sendable {
    public typealias Handler = @Sendable (FirstPartyModuleEvent) -> Void

    private let lock = NSLock()
    private var handlers: [UUID: Handler] = [:]

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping Handler) -> UUID {
        let token = UUID()
        lock.lock()
        handlers[token] = handler
        lock.unlock()
        return token
    }

    public func unsubscribe(_ token: UUID) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    public func publish(_ event: FirstPartyModuleEvent) {
        lock.lock()
        let currentHandlers = Array(handlers.values)
        lock.unlock()
        currentHandlers.forEach { $0(event) }
    }
}

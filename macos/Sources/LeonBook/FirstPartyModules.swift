import Foundation
import LeonBookBackupModule
import LeonBookCaptureModule
import LeonBookKnowledgeGraphModule
import LeonBookModuleKit
import LeonBookPublishingModule
import LeonBookSearchModule

private struct NativeFirstPartyModuleAdapter {
    typealias Predicate = @MainActor (NativeAppModel) -> Bool
    typealias LifecycleHandler = @MainActor (NativeAppModel) -> Void
    typealias CommandHandler = @MainActor (NativeAppModel, NativeCommandInvocation) -> Void

    let descriptor: FirstPartyModuleDescriptor
    let canDeactivate: Predicate
    let activate: LifecycleHandler
    let deactivate: LifecycleHandler
    let commandHandlers: [String: CommandHandler]

    init(
        descriptor: FirstPartyModuleDescriptor,
        canDeactivate: @escaping Predicate = { _ in true },
        activate: @escaping LifecycleHandler = { _ in },
        deactivate: @escaping LifecycleHandler = { _ in },
        commandHandlers: [String: CommandHandler] = [:]
    ) {
        self.descriptor = descriptor
        self.canDeactivate = canDeactivate
        self.activate = activate
        self.deactivate = deactivate
        self.commandHandlers = commandHandlers
    }
}

enum NativeFirstPartyModules {
    static let stateDefaultsKey = "leon-book.first-party-modules.v1"

    /// The host-side adapters are the single composition point for module
    /// lifecycle and native command execution. Feature targets own metadata
    /// and behaviour that does not depend on AppKit or app state.
    private static let adapters: [NativeFirstPartyModuleAdapter] = [
        .init(
            descriptor: SearchFirstPartyModule.descriptor,
            deactivate: { model in
                model.searchPresentation = nil
                model.globalSearchTask?.cancel()
                model.globalSearchTask = nil
                model.globalSearchGeneration += 1
                model.globalSearchResults = []
                model.isSearchingGlobally = false
                model.articleListSearchTask?.cancel()
                model.articleListSearchTask = nil
                model.articleListSearchGeneration += 1
                model.articleSearchMatchSlugs = []
                model.articleSearchResolvedText = ""
                model.isSearchingArticles = false
            },
            commandHandlers: [
                "search.global": { model, invocation in
                    model.recordFirstPartyModuleEvent(
                        moduleID: SearchFirstPartyModule.id,
                        name: "search.requested"
                    )
                    if let query = invocation.arguments["query"] {
                        model.globalSearchText = query
                    }
                    model.presentGlobalSearch()
                },
                "search.quick-open": { model, _ in
                    model.recordFirstPartyModuleEvent(
                        moduleID: SearchFirstPartyModule.id,
                        name: "search.requested"
                    )
                    model.presentQuickSwitcher()
                },
            ]
        ),
        .init(
            descriptor: KnowledgeGraphFirstPartyModule.descriptor,
            activate: { model in
                model.knowledgeGraphTask?.cancel()
                model.knowledgeGraphTask = Task { [weak model] in
                    do { try await model?.reloadKnowledgeGraph() }
                    catch { model?.errorMessage = error.localizedDescription }
                }
            },
            deactivate: { model in
                model.knowledgeGraphTask?.cancel()
                model.knowledgeGraphTask = nil
                model.articleGraph = .empty
                if model.section == .graph { model.section = .dashboard }
            },
            commandHandlers: [
                "navigation.graph": { model, _ in model.openKnowledgeGraph() },
            ]
        ),
        .init(
            descriptor: PublishingFirstPartyModule.descriptor,
            commandHandlers: [
                "article.publish": { model, _ in
                    Task { await model.saveEditor(as: .published) }
                },
            ]
        ),
        .init(
            descriptor: BackupFirstPartyModule.descriptor,
            canDeactivate: { !$0.isBackingUp && !$0.isRestoringBackup },
            deactivate: { model in
                model.backupTask?.cancel()
                model.backupTask = nil
                model.backupStatus = "备份模块已停用"
            },
            commandHandlers: [
                "backup.create": { model, _ in model.backupNow() },
            ]
        ),
        .init(
            descriptor: CaptureFirstPartyModule.descriptor,
            canDeactivate: { !$0.isImportingObsidianVault },
            deactivate: { model in
                model.obsidianScanTask?.cancel()
                model.obsidianScanTask = nil
                model.isScanningObsidianVault = false
                model.obsidianImportPreview = nil
                model.obsidianImportStatus = "采集模块已停用"
            },
            commandHandlers: [
                "capture.markdown-folder": { model, _ in model.chooseObsidianVault() },
            ]
        ),
    ]

    private static let validatedAdapters: [NativeFirstPartyModuleAdapter] = {
        for adapter in adapters {
            let declared = Set(adapter.descriptor.commands.map(\.id))
            let implemented = Set(adapter.commandHandlers.keys)
            precondition(
                declared == implemented,
                "Module command adapter mismatch: \(adapter.descriptor.id.rawValue)"
            )
        }
        return adapters
    }()

    private static let adaptersByID = Dictionary(
        uniqueKeysWithValues: validatedAdapters.map { ($0.descriptor.id, $0) }
    )

    static let catalog: FirstPartyModuleCatalog = {
        do {
            return try FirstPartyModuleCatalog(validatedAdapters.map(\.descriptor))
        } catch {
            preconditionFailure("Invalid first-party module catalog: \(error)")
        }
    }()

    static let commandDefinitions: [NativeCommandDefinition] = validatedAdapters.flatMap { adapter in
        adapter.descriptor.commands.map(NativeCommandDefinition.init(moduleCommand:))
    }

    static func loadRuntime(defaults: UserDefaults = .standard) -> FirstPartyModuleRuntime {
        let state = defaults.data(forKey: stateDefaultsKey)
            .flatMap { try? JSONDecoder().decode(FirstPartyModuleState.self, from: $0) }
            ?? FirstPartyModuleState()
        return FirstPartyModuleRuntime(catalog: catalog, state: state)
    }

    static func save(_ state: FirstPartyModuleState, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateDefaultsKey)
    }

    @MainActor
    static func canDeactivate(_ moduleID: FirstPartyModuleID, in model: NativeAppModel) -> Bool {
        adaptersByID[moduleID]?.canDeactivate(model) == true
    }

    @MainActor
    static func activate(_ moduleID: FirstPartyModuleID, in model: NativeAppModel) {
        adaptersByID[moduleID]?.activate(model)
    }

    @MainActor
    static func deactivate(_ moduleID: FirstPartyModuleID, in model: NativeAppModel) {
        adaptersByID[moduleID]?.deactivate(model)
    }

    @MainActor
    static func executeModuleCommand(
        _ invocation: NativeCommandInvocation,
        in model: NativeAppModel
    ) -> Bool {
        guard let module = catalog.module(owningCommand: invocation.id.rawValue),
              let handler = adaptersByID[module.id]?.commandHandlers[invocation.id.rawValue] else {
            return false
        }
        handler(model, invocation)
        return true
    }
}

private extension NativeCommandDefinition {
    init(moduleCommand command: FirstPartyModuleCommand) {
        self.init(
            id: NativeCommandID(rawValue: command.id),
            title: command.title,
            detail: command.detail,
            keywords: command.keywords,
            systemImage: command.systemImage,
            availability: command.availability.nativeAvailability,
            surfaces: Set(command.surfaces.map(\.nativeSurface)),
            defaultShortcut: command.defaultShortcut.map(NativeCommandShortcut.init(moduleShortcut:))
        )
    }
}

private extension FirstPartyModuleCommandAvailability {
    var nativeAvailability: NativeCommandAvailability {
        switch self {
        case .always: return .always
        case .storageReady: return .storageReady
        case .storageReadyAndIdle: return .storageReadyAndIdle
        case .articleEditor: return .articleEditor
        case .articleEditorAndIdle: return .articleEditorAndIdle
        }
    }
}

private extension FirstPartyModuleCommandSurface {
    var nativeSurface: NativeCommandSurface {
        switch self {
        case .palette: return .palette
        case .menu: return .menu
        case .editorSlash: return .editorSlash
        case .automation: return .automation
        }
    }
}

private extension NativeCommandShortcut {
    init(moduleShortcut shortcut: FirstPartyModuleCommandShortcut) {
        self.init(
            key: shortcut.key,
            modifiers: Set(shortcut.modifiers.map(\.nativeModifier))
        )
    }
}

private extension FirstPartyModuleCommandShortcut.Modifier {
    var nativeModifier: NativeCommandShortcut.Modifier {
        switch self {
        case .command: return .command
        case .option: return .option
        case .shift: return .shift
        case .control: return .control
        }
    }
}

extension NativeAppModel {
    var isSearchModuleEnabled: Bool {
        isFirstPartyModuleEnabled(SearchFirstPartyModule.id)
    }

    var isKnowledgeGraphModuleEnabled: Bool {
        isFirstPartyModuleEnabled(KnowledgeGraphFirstPartyModule.id)
    }

    var isPublishingModuleEnabled: Bool {
        isFirstPartyModuleEnabled(PublishingFirstPartyModule.id)
    }

    var isBackupModuleEnabled: Bool {
        isFirstPartyModuleEnabled(BackupFirstPartyModule.id)
    }

    var isCaptureModuleEnabled: Bool {
        isFirstPartyModuleEnabled(CaptureFirstPartyModule.id)
    }

    var firstPartyModules: [FirstPartyModuleDescriptor] {
        firstPartyModuleRuntime.catalog.modules
    }

    func openKnowledgeGraph() {
        guard authorizeFirstPartyModule(
            KnowledgeGraphFirstPartyModule.id,
            permission: .contentRead,
            action: "打开知识图谱"
        ) else { return }
        recordFirstPartyModuleEvent(
            moduleID: KnowledgeGraphFirstPartyModule.id,
            name: "graph.requested"
        )
        section = .graph
    }

    func reloadKnowledgeGraph() async throws {
        guard isKnowledgeGraphModuleEnabled else {
            articleGraph = .empty
            return
        }
        let graph = try await store.articleGraph()
        guard !Task.isCancelled, isKnowledgeGraphModuleEnabled else { return }
        articleGraph = graph
    }

    func isFirstPartyModuleEnabled(_ moduleID: FirstPartyModuleID) -> Bool {
        firstPartyModuleRuntime.isEnabled(moduleID)
    }

    func setFirstPartyModuleEnabled(_ enabled: Bool, moduleID: FirstPartyModuleID) {
        if !enabled,
           firstPartyModuleRuntime.catalog.module(for: moduleID) != nil,
           !NativeFirstPartyModules.canDeactivate(moduleID, in: self) {
            let moduleName = firstPartyModuleRuntime.catalog.module(for: moduleID)?.name ?? moduleID.rawValue
            errorMessage = "“\(moduleName)”正在执行写入操作，请等待完成后再停用。"
            return
        }
        var runtime = firstPartyModuleRuntime
        guard runtime.setEnabled(enabled, for: moduleID) else { return }
        firstPartyModuleRuntime = runtime
        NativeFirstPartyModules.save(runtime.state)
        if enabled {
            NativeFirstPartyModules.activate(moduleID, in: self)
        } else {
            NativeFirstPartyModules.deactivate(moduleID, in: self)
        }
        recordFirstPartyModuleEvent(
            moduleID: moduleID,
            name: enabled ? "module.enabled" : "module.disabled"
        )
    }

    func executeFirstPartyModuleCommand(_ invocation: NativeCommandInvocation) -> Bool {
        NativeFirstPartyModules.executeModuleCommand(invocation, in: self)
    }

    func firstPartyModuleAllowsCommand(_ commandID: NativeCommandID) -> Bool {
        firstPartyModuleRuntime.authorization(forCommand: commandID.rawValue).isAllowed
    }

    func firstPartyPermissionLabels(_ module: FirstPartyModuleDescriptor) -> String {
        module.permissions.map(\.rawValue).sorted().joined(separator: " · ")
    }

    @discardableResult
    func authorizeFirstPartyModule(
        _ moduleID: FirstPartyModuleID,
        permission: FirstPartyModulePermission,
        action: String,
        presentsError: Bool = true
    ) -> Bool {
        let authorization = firstPartyModuleRuntime.authorization(for: moduleID, permission: permission)
        guard !authorization.isAllowed else { return true }
        if presentsError {
            let moduleName = firstPartyModuleRuntime.catalog.module(for: moduleID)?.name ?? moduleID.rawValue
            switch authorization {
            case .disabled:
                errorMessage = "“\(moduleName)”模块已停用，无法\(action)。可在设置的“第一方模块”中重新启用。"
            case .unknownModule:
                errorMessage = "模块配置错误：找不到“\(moduleName)”。"
            case .undeclaredPermission(_, let permission):
                errorMessage = "模块配置错误：“\(moduleName)”未声明 \(permission.rawValue) 能力。"
            case .allowed:
                break
            }
        }
        if firstPartyModuleRuntime.catalog.module(for: moduleID) != nil {
            recordFirstPartyModuleEvent(
                moduleID: moduleID,
                name: "module.authorization-denied",
                payload: ["permission": permission.rawValue, "action": action]
            )
        }
        return false
    }

    func recordFirstPartyModuleEvent(
        moduleID: FirstPartyModuleID,
        name: String,
        payload: [String: String] = [:]
    ) {
        guard firstPartyModuleRuntime.catalog.canPublishEvent(name, from: moduleID) else {
            assertionFailure("Undeclared first-party module event: \(moduleID.rawValue).\(name)")
            return
        }
        let event = FirstPartyModuleEvent(moduleID: moduleID, name: name, payload: payload)
        latestFirstPartyModuleEvent = event
        firstPartyModuleEventBus.publish(event)
    }
}

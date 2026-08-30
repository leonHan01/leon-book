import AppKit
import Foundation
import LeonBookExtensionKit
import SwiftUI
import UniformTypeIdentifiers

private struct NativeDeclarativeExtensionState: Codable {
    var disabledExtensionIDs: Set<String>
}

private struct NativeDeclarativeExtensionsEnvironmentKey: EnvironmentKey {
    static let defaultValue = DeclarativeExtensionRuntime.empty
}

extension EnvironmentValues {
    var nativeDeclarativeExtensions: DeclarativeExtensionRuntime {
        get { self[NativeDeclarativeExtensionsEnvironmentKey.self] }
        set { self[NativeDeclarativeExtensionsEnvironmentKey.self] = newValue }
    }
}

extension NativeAppModel {
    var declarativeExtensionDirectoryURL: URL {
        URL(fileURLWithPath: dataDirectoryPath, isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
    }

    private var declarativeExtensionStateURL: URL {
        declarativeExtensionDirectoryURL.appendingPathComponent(".state.json")
    }

    var declarativeExtensionCommandDefinitions: [NativeCommandDefinition] {
        let commands = declarativeExtensions.commands.map { registration in
            let action = registration.command.action
            return NativeCommandDefinition(
                id: NativeCommandID(rawValue: registration.commandID),
                title: registration.command.title,
                detail: registration.command.description.isEmpty
                    ? "由 \(registration.extensionName) 提供"
                    : registration.command.description,
                keywords: "\(registration.command.keywords) \(registration.extensionName) extension 扩展",
                systemImage: registration.command.icon,
                availability: action.type == .insertText ? .articleEditorAndIdle : .storageReadyAndIdle,
                surfaces: action.type == .insertText
                    ? [.palette, .menu, .editorSlash]
                    : [.palette, .menu]
            )
        }
        let importers = declarativeExtensions.importers.map { registration in
            NativeCommandDefinition(
                id: NativeCommandID(rawValue: registration.commandID),
                title: registration.importer.title,
                detail: registration.importer.description.isEmpty
                    ? "使用 \(registration.extensionName) 导入文件"
                    : registration.importer.description,
                keywords: "import 导入 \(registration.importer.fileExtensions.joined(separator: " ")) \(registration.extensionName)",
                systemImage: "square.and.arrow.down",
                availability: .storageReadyAndIdle,
                surfaces: [.palette, .menu]
            )
        }
        return commands + importers
    }

    var declarativeExtensionContributionCount: Int {
        declarativeExtensions.commands.count
            + declarativeExtensions.templateVariables.count
            + declarativeExtensions.importers.count
            + declarativeExtensions.renderers.count
            + declarativeExtensions.baseFunctions.count
    }

    func declarativeExtensionCapabilities(_ package: DeclarativeExtensionPackage) -> String {
        var labels: [String] = []
        if !package.manifest.commands.isEmpty { labels.append("命令 \(package.manifest.commands.count)") }
        if !package.manifest.templateVariables.isEmpty { labels.append("模板变量 \(package.manifest.templateVariables.count)") }
        if !package.manifest.importers.isEmpty { labels.append("导入器 \(package.manifest.importers.count)") }
        if !package.manifest.renderers.isEmpty { labels.append("渲染器 \(package.manifest.renderers.count)") }
        if !package.manifest.baseFunctions.isEmpty { labels.append("Base 函数 \(package.manifest.baseFunctions.count)") }
        return labels.isEmpty ? "未声明扩展点" : labels.joined(separator: " · ")
    }

    func reloadDeclarativeExtensions() {
        do {
            try FileManager.default.createDirectory(
                at: declarativeExtensionDirectoryURL,
                withIntermediateDirectories: true
            )
            let disabledIDs = loadDeclarativeExtensionState().disabledExtensionIDs
            declarativeExtensions = try DeclarativeExtensionLoader.load(
                from: declarativeExtensionDirectoryURL,
                disabledExtensionIDs: disabledIDs
            )
            let invalidCount = declarativeExtensions.diagnostics.filter { $0.severity == .error }.count
            let enabledCount = declarativeExtensions.activePackages.count
            declarativeExtensionStatus = invalidCount == 0
                ? "已启用 \(enabledCount) 个扩展，共 \(declarativeExtensionContributionCount) 个扩展点"
                : "已启用 \(enabledCount) 个扩展，\(invalidCount) 个扩展包未通过校验"
            commandPreferences.updateRegistry(commandRegistry)
        } catch {
            declarativeExtensions = .empty
            declarativeExtensionStatus = "扩展目录读取失败：\(error.localizedDescription)"
            commandPreferences.updateRegistry(commandRegistry)
        }
    }

    func setDeclarativeExtensionEnabled(_ enabled: Bool, extensionID: String) {
        var runtime = declarativeExtensions
        guard runtime.setEnabled(enabled, extensionID: extensionID) else { return }
        declarativeExtensions = runtime
        persistDeclarativeExtensionState()
        let state = enabled ? "已启用" : "已停用"
        declarativeExtensionStatus = "\(state) \(runtime.packages.first(where: { $0.id == extensionID })?.manifest.name ?? extensionID)"
        commandPreferences.updateRegistry(commandRegistry)
    }

    func openDeclarativeExtensionDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: declarativeExtensionDirectoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: declarativeExtensionDirectoryURL.path)
        } catch {
            errorMessage = "无法打开扩展目录：\(error.localizedDescription)"
        }
    }

    func executeDeclarativeExtensionCommand(_ invocation: NativeCommandInvocation) -> Bool {
        if let registration = declarativeExtensions.command(for: invocation.id.rawValue) {
            executeDeclarativeCommand(registration, invocation: invocation)
            return true
        }
        if let registration = declarativeExtensions.importer(for: invocation.id.rawValue) {
            executeDeclarativeImporter(registration)
            return true
        }
        return false
    }

    private func executeDeclarativeCommand(
        _ registration: DeclarativeExtensionCommandRegistration,
        invocation: NativeCommandInvocation
    ) {
        let action = registration.command.action
        let context = declarativeTemplateContext()
        switch action.type {
        case .insertText:
            guard let template = action.text,
                  let rendered = renderDeclarativeTemplate(
                    template,
                    context: context,
                    source: registration.command.title
                  ) else { return }
            performEditorInsertion(
                NativeCommandTextInsertion(text: rendered, cursorOffset: action.cursorOffset),
                invocation: invocation
            )
            editorAutosaveStatus = "已执行扩展命令，等待自动保存…"
            scheduleEditorAutosave()
        case .newNote:
            let title: String
            if let template = action.title {
                guard let value = renderDeclarativeTemplate(
                    template,
                    context: context,
                    source: registration.command.title
                ) else { return }
                title = value
            } else {
                title = ""
            }
            let body: String
            if let template = action.body {
                guard let value = renderDeclarativeTemplate(
                    template,
                    context: context,
                    source: registration.command.title
                ) else { return }
                body = value
            } else {
                body = ""
            }
            let folder: String?
            if let template = action.folder {
                guard let value = renderDeclarativeTemplate(
                    template,
                    context: context,
                    source: registration.command.title
                ) else { return }
                folder = value
            } else {
                folder = nil
            }
            guard validateDeclarativeFolder(folder, source: registration.command.title) else { return }
            let previousRecoveryID = editor.recoveryID
            newArticle()
            guard editor.recoveryID != previousRecoveryID else { return }
            let normalizedFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pendingNewArticleFolderPath = normalizedFolder.isEmpty ? nil : normalizedFolder
            editor.title = title
            editor.body = body
            editorAutosaveStatus = "已由 \(registration.extensionName) 创建草稿，等待保存…"
            scheduleEditorAutosave()
        }
    }

    private func executeDeclarativeImporter(_ registration: DeclarativeExtensionImporterRegistration) {
        let panel = NSOpenPanel()
        panel.title = registration.importer.title
        panel.message = "扩展只能读取你在此处明确选择的文件，最多 \(registration.importer.maximumBytes) 字节。"
        panel.prompt = "导入为草稿"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = registration.importer.fileExtensions.compactMap {
            UTType(filenameExtension: $0.lowercased())
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        do {
            let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= registration.importer.maximumBytes else {
                throw DeclarativeExtensionError.fileTooLarge(registration.importer.maximumBytes)
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let document = try declarativeExtensions.importDocument(
                using: registration,
                data: data,
                fileName: fileURL.lastPathComponent,
                context: declarativeTemplateContext()
            )
            guard document.unresolvedVariables.isEmpty else {
                errorMessage = "“\(registration.importer.title)”缺少模板变量：\(document.unresolvedVariables.joined(separator: "、"))"
                return
            }
            guard validateDeclarativeFolder(document.folder, source: registration.importer.title) else { return }
            let previousRecoveryID = editor.recoveryID
            newArticle()
            guard editor.recoveryID != previousRecoveryID else { return }
            let normalizedFolder = document.folder?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pendingNewArticleFolderPath = normalizedFolder.isEmpty ? nil : normalizedFolder
            editor.title = document.title
            editor.body = document.body
            editorAutosaveStatus = "已导入 \(fileURL.lastPathComponent)，等待保存…"
            scheduleEditorAutosave()
        } catch {
            errorMessage = "扩展导入失败：\(error.localizedDescription)"
        }
    }

    private func declarativeTemplateContext() -> [String: String] {
        let source = editor.body as NSString
        let location = min(max(0, editorBodySelection.location), source.length)
        let length = min(max(0, editorBodySelection.length), source.length - location)
        let selection = source.substring(with: NSRange(location: location, length: length))
        return [
            "user": currentUser.name,
            "note.title": editor.title,
            "note.body": editor.body,
            "selection": selection,
        ]
    }

    private func renderDeclarativeTemplate(
        _ template: String,
        context: [String: String],
        source: String
    ) -> String? {
        let result = declarativeExtensions.renderTemplate(template, context: context)
        guard result.unresolvedVariables.isEmpty else {
            errorMessage = "“\(source)”缺少模板变量：\(result.unresolvedVariables.joined(separator: "、"))"
            return nil
        }
        return result.value
    }

    private func validateDeclarativeFolder(_ folder: String?, source: String) -> Bool {
        guard let folder else { return true }
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || DeclarativeExtensionSecurity.isSafeRelativePath(trimmed) else {
            errorMessage = "“\(source)”生成了不安全的目标文件夹。"
            return false
        }
        return true
    }

    private func loadDeclarativeExtensionState() -> NativeDeclarativeExtensionState {
        guard let data = try? Data(contentsOf: declarativeExtensionStateURL),
              let state = try? JSONDecoder().decode(NativeDeclarativeExtensionState.self, from: data) else {
            return NativeDeclarativeExtensionState(disabledExtensionIDs: [])
        }
        return state
    }

    private func persistDeclarativeExtensionState() {
        do {
            let state = NativeDeclarativeExtensionState(
                disabledExtensionIDs: declarativeExtensions.disabledExtensionIDs
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: declarativeExtensionStateURL, options: .atomic)
        } catch {
            errorMessage = "扩展启停状态保存失败：\(error.localizedDescription)"
        }
    }
}

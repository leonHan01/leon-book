import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Each gesture has its own token, so a cancelled drag or another window cannot
/// accidentally complete a later drop in this editing session.
struct NativeDashboardModuleDrag: Equatable {
    static let contentType = UTType(exportedAs: "com.leonbook.dashboard-module", conformingTo: .data)
    let moduleID: UUID
    var sessionID = UUID()

    private var data: Data { Data("\(moduleID.uuidString):\(sessionID.uuidString)".utf8) }

    func matches(_ data: Data) -> Bool { data == self.data }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = self.data
        provider.registerDataRepresentation(forTypeIdentifier: Self.contentType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

@MainActor
struct NativeDashboardModuleDropDelegate: DropDelegate {
    let model: NativeAppModel
    let targetID: UUID
    @Binding var activeDrag: NativeDashboardModuleDrag?
    @Binding var dropTargetID: UUID?

    private var canDrop: Bool {
        guard model.canEditDashboard, let drag = activeDrag,
              let modules = model.dashboardEditing.draft?.modules else { return false }
        return modules.contains(where: { $0.id == drag.moduleID })
            && modules.contains(where: { $0.id == targetID })
    }

    func validateDrop(info: DropInfo) -> Bool {
        canDrop && info.hasItemsConforming(to: [NativeDashboardModuleDrag.contentType])
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info), activeDrag?.moduleID != targetID { dropTargetID = targetID }
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [NativeDashboardModuleDrag.contentType]).first else { return false }
        return performDrop(provider: provider)
    }

    // Shared by the native drop callback and the regression tests, including
    // asynchronous provider delivery and edits ending before delivery finishes.
    func performDrop(provider: NSItemProvider) -> Bool {
        guard canDrop, let drag = activeDrag,
              provider.hasItemConformingToTypeIdentifier(NativeDashboardModuleDrag.contentType.identifier) else { return false }
        dropTargetID = nil
        provider.loadDataRepresentation(forTypeIdentifier: NativeDashboardModuleDrag.contentType.identifier) { data, _ in
            Task { @MainActor in
                guard activeDrag == drag else { return }
                defer { activeDrag = nil }
                guard canDrop, let data, drag.matches(data) else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.dashboardEditing.dropModule(drag.moduleID, onto: targetID)
                }
            }
        }
        return true
    }
}

import Foundation

extension NativeAppModel {
    var canEditDashboard: Bool {
        storageReady && isDashboardLoaded && !isSavingDashboard && !isSwitchingWorkspace
            && !isRestoringBackup && !isBackingUp
    }

    func reloadDashboard() async {
        // Before connection, store is only a placeholder at the user registry
        // root. Preparing it as a content store corrupts the registry's role.
        guard storageReady else { return }
        let activeStore = store, generation = workspaceGeneration
        dashboardLoadGeneration += 1
        let request = dashboardLoadGeneration
        do {
            let loaded = try await activeStore.loadDashboard()
            guard generation == workspaceGeneration, request == dashboardLoadGeneration else { return }
            dashboard = loaded
            isDashboardLoaded = true
            dashboardLoadError = nil
        } catch {
            guard generation == workspaceGeneration, request == dashboardLoadGeneration else { return }
            isDashboardLoaded = false
            dashboardLoadError = error.localizedDescription
        }
    }

    func saveDashboard(_ document: NativeDashboardDocument) async -> Bool {
        guard canEditDashboard else { return false }
        let activeStore = store, generation = workspaceGeneration
        dashboardLoadGeneration += 1
        isSavingDashboard = true
        defer { if generation == workspaceGeneration { isSavingDashboard = false } }
        do {
            let saved = try await activeStore.saveDashboard(document)
            guard generation == workspaceGeneration else { return false }
            dashboard = saved
            errorMessage = nil
            scheduleBackup()
            NativeWorkspaceWindows.reloadDashboards(in: activeStore.rootURL, excluding: self)
            return true
        } catch {
            guard generation == workspaceGeneration else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
}

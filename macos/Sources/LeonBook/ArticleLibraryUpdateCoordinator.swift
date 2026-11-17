import Foundation

/// Merge nearby metadata mutations without racing independent projection
/// rebuilds. Edges are still resolved from the store after the batch, including
/// aliases and duplicate-title resolution affected by updated-at ordering.
@MainActor
final class NativeArticleLibraryUpdateCoordinator {
    private var pending: [String: NativeArticleSummary] = [:]
    private var workspaceGeneration: Int?
    private var task: Task<Void, Never>?
    private var taskID: UUID?

    func enqueue(
        _ summaries: [NativeArticleSummary],
        model: NativeAppModel,
        store: LocalBlogStore,
        workspaceGeneration: Int
    ) -> Task<Void, Never> {
        if self.workspaceGeneration != workspaceGeneration {
            cancel()
            self.workspaceGeneration = workspaceGeneration
        }
        for summary in summaries {
            if let current = pending[summary.slug], current.updatedAt > summary.updatedAt { continue }
            pending[summary.slug] = summary
        }
        if let task { return task }

        let id = UUID()
        taskID = id
        let scheduled = Task { [weak self, weak model] in
            guard let self else { return }
            defer {
                if self.taskID == id {
                    self.task = nil
                    self.taskID = nil
                    self.pending.removeAll()
                }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000) }
                catch { return }
                guard let model, model.workspaceGeneration == workspaceGeneration,
                      self.taskID == id else { return }

                let updates = Array(self.pending.values)
                self.pending.removeAll(keepingCapacity: true)
                await model.mergeArticleSummaries(updates, workspaceGeneration: workspaceGeneration)
                guard !Task.isCancelled, model.workspaceGeneration == workspaceGeneration,
                      self.taskID == id else { return }
                if !self.pending.isEmpty { continue }

                if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    model.updateArticleListSearch(model.searchText, debounce: false)
                }
                guard model.isKnowledgeGraphModuleEnabled else {
                    model.articleGraph = .empty
                    return
                }

                model.knowledgeGraphTask?.cancel()
                model.articleGraphLoadGeneration += 1
                let graphGeneration = model.articleGraphLoadGeneration
                let loadingID = model.loadingOperations.begin(.graph)
                do {
                    let graph = try await store.articleGraph()
                    model.loadingOperations.end(loadingID)
                    guard !Task.isCancelled, model.workspaceGeneration == workspaceGeneration,
                          self.taskID == id else { return }
                    if !self.pending.isEmpty { continue }
                    guard model.articleGraphLoadGeneration == graphGeneration else { return }
                    if model.isKnowledgeGraphModuleEnabled { model.articleGraph = graph }
                } catch {
                    model.loadingOperations.end(loadingID)
                    guard !Task.isCancelled, model.workspaceGeneration == workspaceGeneration,
                          self.taskID == id else { return }
                    if !self.pending.isEmpty { continue }
                    guard model.articleGraphLoadGeneration == graphGeneration else { return }
                    model.errorMessage = error.localizedDescription
                }
                return
            }
        }
        task = scheduled
        return scheduled
    }

    func cancel() {
        task?.cancel()
        task = nil
        taskID = nil
        pending.removeAll()
    }
}

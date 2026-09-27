import Foundation

/// Bounded, advisory ranking of the same selected files used to seed the discovery file tree.
enum ContextBuilderCandidatePrePass {
    struct Input {
        let prompt: String
        let selection: StoredSelection
    }

    struct Candidate {
        let displayPath: String
        /// Nil for empty, binary, unreadable, or beyond-cap files.
        let excerpt: String?
    }

    private struct Source {
        let displayPath: String
        let physicalPath: String
    }

    private struct PlannedBatch {
        let batch: JevContentJudgmentBatch
        let pathsByQuestionID: [String: String]
    }

    static func preferredInput(captured: Input?, snapshot: Input?, live: Input?) -> Input? {
        captured ?? snapshot ?? live
    }

    static func sectionBlock(_ section: String?) -> String {
        section.map { "\($0)\n\n" } ?? ""
    }

    @MainActor
    static func candidates(
        selection: StoredSelection,
        store: WorkspaceFileContextStore,
        lookupContext: WorkspaceLookupContext?
    ) async -> [Candidate] {
        let scope = lookupContext?.rootScope ?? .allLoaded
        let physicalSelection = lookupContext?.physicalizeSelection(selection) ?? selection
        let snapshot = await store.makeFileTreeSelectionSnapshot(
            selection: physicalSelection,
            request: WorkspaceFileTreeSnapshotRequest(
                mode: .auto,
                filePathDisplay: .relative,
                onlyIncludeRootsWithSelectedFiles: false,
                includeLegend: true,
                showCodeMapMarkers: true,
                rootScope: scope
            ),
            profile: .uiAssisted
        )
        let roots = await store.rootRefs(scope: scope)
        let displayContext = lookupContext ?? WorkspaceLookupContext(rootScope: scope, bindingProjection: nil)
        let names = await displayContext.logicalRootDisplayNamesByRootID(store: store)
        var sources: [Source] = []
        for fileID in snapshot.selectedFileIDs {
            guard let file = await store.file(id: fileID),
                  let displayPath = displayContext.logicalDisplayPath(
                      for: file,
                      roots: roots,
                      rootDisplayNamesByRootID: names,
                      display: .relative
                  )
            else { continue }
            sources.append(Source(displayPath: displayPath, physicalPath: file.standardizedFullPath))
        }
        let orderedSources = sources.sorted { $0.displayPath < $1.displayPath }
        let maximum = JevContentJudgmentPolicy.ContextBuilder.filesPerBatch
            * JevContentJudgmentPolicy.ContextBuilder.maxBatches
        let readTask = Task.detached(priority: .utility) {
            orderedSources.enumerated().map { index, source in
                Candidate(
                    displayPath: source.displayPath,
                    excerpt: !Task.isCancelled && index < maximum ? readExcerpt(at: source.physicalPath) : nil
                )
            }
        }
        return await withTaskCancellationHandler {
            await readTask.value
        } onCancel: {
            readTask.cancel()
        }
    }

    @MainActor
    static func section(
        task: String,
        candidates: [Candidate],
        enabled: Bool,
        judge: (any JevContentJudging)?,
        isCurrent: @MainActor () -> Bool
    ) async throws -> String? {
        guard enabled, let judge, !candidates.isEmpty else { return nil }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let (batches, initiallyUnranked) = plan(task: task, candidates: candidates)
        guard !batches.isEmpty else { return nil }

        var ranked: [(path: String, score: Double)] = []
        var unranked = initiallyUnranked
        for planned in batches {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let result = await judge.judge(
                batch: planned.batch,
                budget: JevContentJudgmentPolicy.ContextBuilder.budgetPerBatch,
                consumer: .contextBuilder
            )
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            guard case let .applied(answers, _) = result else { return nil }
            for question in planned.batch.questions {
                guard let path = planned.pathsByQuestionID[question.id] else { continue }
                if case let .score(_, weighted)? = answers[question.id] {
                    ranked.append((path: path, score: weighted))
                } else {
                    unranked.append(path)
                }
            }
        }

        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.path < rhs.path : lhs.score > rhs.score
        }
        let policy = JevContentJudgmentPolicy.ContextBuilder.self
        let central = Array(
            ranked.filter { $0.score >= policy.centralThreshold }
                .prefix(policy.centralLimit).map(\.path)
        )
        let useful = Array(ranked.filter {
            $0.score >= policy.usefulThreshold && $0.score < policy.centralThreshold
        }.prefix(policy.usefulLimit).map(\.path))
        return policy.section(central: central, useful: useful, unranked: unranked)
    }

    private static func plan(
        task: String,
        candidates: [Candidate]
    ) -> ([PlannedBatch], [String]) {
        let policy = JevContentJudgmentPolicy.ContextBuilder.self
        let maximum = policy.filesPerBatch * policy.maxBatches
        var batches: [PlannedBatch] = []
        var unranked: [String] = []
        for start in stride(from: 0, to: min(candidates.count, maximum), by: policy.filesPerBatch) {
            let end = min(start + policy.filesPerBatch, maximum, candidates.count)
            var files: [String: JevContentJudgmentPolicy.ContextBuilder.File] = [:]
            var paths: [String: String] = [:]
            for candidate in candidates[start ..< end] {
                guard let excerpt = candidate.excerpt, !excerpt.isEmpty else {
                    unranked.append(candidate.displayPath)
                    continue
                }
                let id = policy.fileID(files.count)
                var next = files
                next[id] = .init(path: candidate.displayPath, excerpt: excerpt)
                guard let state = policy.state(task: task, files: next),
                      state.utf8.count <= JevContentJudgmentPolicy.stateCharBudget
                else {
                    unranked.append(candidate.displayPath)
                    continue
                }
                files = next
                paths[id] = candidate.displayPath
            }
            guard let state = policy.state(task: task, files: files), !files.isEmpty,
                  let batch = try? JevContentJudgmentBatch(
                      state: state,
                      questions: policy.questions(fileIDs: paths.keys.sorted())
                  )
            else { continue }
            batches.append(PlannedBatch(batch: batch, pathsByQuestionID: paths))
        }
        if candidates.count > maximum {
            unranked += candidates[maximum...].map(\.displayPath)
        }
        return (batches, unranked)
    }

    static func readExcerpt(at path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: JevContentJudgmentPolicy.stateCharBudget + 1),
              !data.isEmpty, !data.contains(0),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let excerpt = text.split(
            separator: "\n",
            maxSplits: JevContentJudgmentPolicy.ContextBuilder.excerptLines,
            omittingEmptySubsequences: false
        )
        .prefix(JevContentJudgmentPolicy.ContextBuilder.excerptLines)
        .joined(separator: "\n")
        return excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : excerpt
    }
}

import Combine
import Foundation

// SEARCH-HELPER: codex quota UI store, observable quota state, equality gated publication
//
// MainActor projection of Codex quota status.
//
// This is the only quota type that touches the main actor. Transport, decoding, sparse
// merging, and reconciliation all happen inside `CodexProviderQuotaService`; this store
// receives an already-merged immutable snapshot, projects it to compact view state, and
// assigns only when that view state actually changed.
//
// The equality gate is what keeps a chatty provider from invalidating the settings view on
// every notification: identical projected state performs no assignment and therefore
// publishes no `objectWillChange`.

@MainActor
final class CodexQuotaUIStore: ObservableObject {
    static let shared = CodexQuotaUIStore()

    @Published private(set) var state: CodexQuotaViewState = .hidden
    @Published private(set) var isRefreshing = false

    private let service: CodexProviderQuotaService
    private let settingsProvider: @MainActor () -> Bool
    private let now: @Sendable () -> Date
    private var observationTask: Task<Void, Never>?
    private var latestStatus: CodexQuotaStatus = .disabled

    init(
        service: CodexProviderQuotaService = .shared,
        settingsProvider: @escaping @MainActor () -> Bool = {
            GlobalSettingsStore.shared.codexUsageQuotaEnabled()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.settingsProvider = settingsProvider
        self.now = now
    }

    deinit {
        observationTask?.cancel()
    }

    /// Called when the surface appears. Applies the current opt-in setting and starts
    /// observing only when enabled — a disabled feature starts no transport at all.
    func activate() {
        let enabled = settingsProvider()
        Task { [service] in
            await service.setEnabled(enabled)
        }
        guard enabled else {
            observationTask?.cancel()
            observationTask = nil
            apply(.disabled)
            return
        }
        startObservingIfNeeded()
    }

    /// Called when the surface disappears. Dropping the subscription lets the service tear
    /// down its transport once nothing is observing.
    func deactivate() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Reflects a settings toggle without requiring the view to be rebuilt.
    func setEnabled(_ enabled: Bool) {
        Task { [service] in
            await service.setEnabled(enabled)
        }
        if enabled {
            startObservingIfNeeded()
        } else {
            observationTask?.cancel()
            observationTask = nil
            apply(.disabled)
        }
    }

    /// Manual refresh. A hidden (disabled) surface never spends a read.
    func refresh() {
        guard state != .hidden, !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self, service] in
            await service.refreshNow()
            self?.isRefreshing = false
        }
    }

    func refreshOnForeground() {
        Task { [service] in
            await service.refreshOnForeground()
        }
    }

    private func startObservingIfNeeded() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, service] in
            let stream = await service.subscribe()
            for await status in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                apply(status)
            }
        }
    }

    private func apply(_ status: CodexQuotaStatus) {
        latestStatus = status
        publish(ProviderQuotaPresenter.viewState(for: status, now: now()))
    }

    /// Re-projects the latest status against the current time so relative wording
    /// ("last seen 3 hours ago") can age without a new provider event.
    func revalidateFreshness() {
        publish(ProviderQuotaPresenter.viewState(for: latestStatus, now: now()))
    }

    /// Equality gate: assigning an identical value would still emit `objectWillChange`,
    /// so the comparison happens before the assignment.
    private func publish(_ newState: CodexQuotaViewState) {
        guard newState != state else { return }
        state = newState
    }
}

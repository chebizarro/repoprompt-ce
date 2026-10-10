import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

/// Composer pill that toggles Jev content judgments for the window's active workspace.
@MainActor
final class AgentContentJudgmentsPillTests: XCTestCase {
    func testPropsReflectActiveWorkspaceSetting() async throws {
        let fixture = try await makeFixture()
        let workspaceID = UUID()
        fixture.viewModel.test_contentJudgmentsWorkspaceOverride = (workspaceID, "Alpha")

        var props = fixture.viewModel.contentJudgmentsPillProps()
        XCTAssertEqual(props.workspaceID, workspaceID)
        XCTAssertEqual(props.workspaceName, "Alpha")
        XCTAssertFalse(props.isOn)
        XCTAssertTrue(props.isAvailable)
        XCTAssertFalse(props.isAwaitingEnableConfirmation)

        fixture.store.setContentJudgments(enabled: true, workspaceID: workspaceID)
        props = fixture.viewModel.contentJudgmentsPillProps()
        XCTAssertTrue(props.isOn)

        // Another workspace's opt-in does not leak into this window's pill.
        let otherID = UUID()
        fixture.viewModel.test_contentJudgmentsWorkspaceOverride = (otherID, "Beta")
        props = fixture.viewModel.contentJudgmentsPillProps()
        XCTAssertEqual(props.workspaceID, otherID)
        XCTAssertFalse(props.isOn)
        XCTAssertEqual(fixture.viewModel.makeStatusPillsSnapshot().contentJudgments, props)
    }

    func testOffToOnStagesConfirmationThenPersists() async throws {
        let fixture = try await makeFixture()
        let workspaceID = UUID()
        fixture.viewModel.test_contentJudgmentsWorkspaceOverride = (workspaceID, "Alpha")

        fixture.viewModel.toggleContentJudgments()

        XCTAssertTrue(fixture.viewModel.contentJudgmentsPillProps().isAwaitingEnableConfirmation)
        XCTAssertFalse(fixture.store.contentJudgmentsEnabled(workspaceID: workspaceID))

        fixture.viewModel.confirmContentJudgmentsEnable(workspaceID: workspaceID)

        let props = fixture.viewModel.contentJudgmentsPillProps()
        XCTAssertFalse(props.isAwaitingEnableConfirmation)
        XCTAssertTrue(props.isOn)
        XCTAssertTrue(fixture.store.contentJudgmentsEnabled(workspaceID: workspaceID))
    }

    func testCancelLeavesSettingOff() async throws {
        let fixture = try await makeFixture()
        let workspaceID = UUID()
        fixture.viewModel.test_contentJudgmentsWorkspaceOverride = (workspaceID, "Alpha")

        fixture.viewModel.toggleContentJudgments()
        fixture.viewModel.cancelContentJudgmentsEnable()

        let props = fixture.viewModel.contentJudgmentsPillProps()
        XCTAssertFalse(props.isAwaitingEnableConfirmation)
        XCTAssertFalse(props.isOn)
        XCTAssertFalse(fixture.store.contentJudgmentsEnabled(workspaceID: workspaceID))
        XCTAssertFalse(fixture.store.hasAnyContentJudgmentsEnabled())
    }

    func testOnToOffAppliesImmediately() async throws {
        let fixture = try await makeFixture()
        let workspaceID = UUID()
        fixture.viewModel.test_contentJudgmentsWorkspaceOverride = (workspaceID, "Alpha")
        fixture.store.setContentJudgments(enabled: true, workspaceID: workspaceID)

        fixture.viewModel.toggleContentJudgments()

        let props = fixture.viewModel.contentJudgmentsPillProps()
        XCTAssertFalse(props.isOn)
        XCTAssertFalse(props.isAwaitingEnableConfirmation)
        XCTAssertFalse(fixture.store.contentJudgmentsEnabled(workspaceID: workspaceID))
    }

    func testConfirmAfterWorkspaceSwitchEnablesNothing() async throws {
        let fixture = try await makeFixture()
        let first = UUID()
        let second = UUID()
        fixture.viewModel.test_contentJudgmentsWorkspaceOverride = (first, "Alpha")
        fixture.viewModel.toggleContentJudgments()

        fixture.viewModel.test_contentJudgmentsWorkspaceOverride = (second, "Beta")
        XCTAssertFalse(fixture.viewModel.contentJudgmentsPillProps().isAwaitingEnableConfirmation)
        fixture.viewModel.confirmContentJudgmentsEnable(workspaceID: first)

        XCTAssertFalse(fixture.store.contentJudgmentsEnabled(workspaceID: first))
        XCTAssertFalse(fixture.store.contentJudgmentsEnabled(workspaceID: second))
    }

    func testNilWorkspaceDisablesPillAndIgnoresToggle() async throws {
        let fixture = try await makeFixture()
        XCTAssertNil(fixture.viewModel.contentJudgmentsWorkspace)

        XCTAssertEqual(fixture.viewModel.contentJudgmentsPillProps(), .noWorkspace)
        fixture.viewModel.toggleContentJudgments()

        XCTAssertNil(fixture.viewModel.pendingContentJudgmentsEnableWorkspaceID)
        XCTAssertFalse(fixture.store.hasAnyContentJudgmentsEnabled())
    }

    func testUnvalidatedJevKeyBlocksEnableButStillAllowsDisable() async throws {
        let fixture = try await makeFixture(
            readiness: .needsConfiguration(generation: 1, reason: "Validate a TypeSafe API key.")
        )
        let workspaceID = UUID()
        fixture.viewModel.test_contentJudgmentsWorkspaceOverride = (workspaceID, "Alpha")
        XCTAssertFalse(fixture.viewModel.contentJudgmentsPillProps().isAvailable)

        fixture.viewModel.toggleContentJudgments()
        XCTAssertFalse(fixture.viewModel.contentJudgmentsPillProps().isAwaitingEnableConfirmation)
        fixture.viewModel.confirmContentJudgmentsEnable(workspaceID: workspaceID)
        XCTAssertFalse(fixture.store.contentJudgmentsEnabled(workspaceID: workspaceID))

        fixture.store.setContentJudgments(enabled: true, workspaceID: workspaceID)
        fixture.viewModel.toggleContentJudgments()
        XCTAssertFalse(fixture.store.contentJudgmentsEnabled(workspaceID: workspaceID))
    }

    // MARK: - Fixture

    private struct Fixture {
        let viewModel: AgentModeViewModel
        let store: GlobalSettingsStore
    }

    private func makeFixture(
        readiness: AgentTaskRouterBackendReadiness = .ready(generation: 1, policyVersion: "fake-v1")
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentContentJudgmentsPill.\(UUID())"))
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        let runtime = try AgentTaskRouterRuntime(registrations: [
            .init(backend: FakeJevReadinessBackend(readiness: readiness))
        ])
        // The runtime publishes its first readiness snapshot asynchronously; wait for it
        // instead of polling so `isBackendReady(.jev)` is deterministic.
        let published = expectation(description: "Jev readiness published")
        let subscription = runtime.objectWillChange.sink { published.fulfill() }
        await fulfillment(of: [published], timeout: 5)
        subscription.cancel()
        XCTAssertEqual(runtime.backendReadiness(.jev), readiness)

        let viewModel = AgentModeViewModel(
            codexControllerFactory: { _, _, _, _, _, _ in
                preconditionFailure("Content judgments pill test must not start Codex")
            },
            headlessProviderFactory: { _, _ in UnsupportedHeadlessAgentProvider(reason: "test terminal") }
        )
        viewModel.modelRouterSettingsStore = store
        viewModel.modelRouterRuntime = runtime
        return Fixture(viewModel: viewModel, store: store)
    }
}

private actor FakeJevReadinessBackend: AgentTaskRouterBackend {
    nonisolated let id = AgentTaskRouterBackendID.jev
    nonisolated let displayName = "Fake Jev"
    let readiness: AgentTaskRouterBackendReadiness

    init(readiness: AgentTaskRouterBackendReadiness) {
        self.readiness = readiness
    }

    func readinessSnapshot() -> AgentTaskRouterBackendReadiness {
        readiness
    }

    func route(_: AgentTaskRoutingRequest) -> AgentTaskRoutingBackendOutcome {
        .abstained(reason: "not used", evidence: nil)
    }
}

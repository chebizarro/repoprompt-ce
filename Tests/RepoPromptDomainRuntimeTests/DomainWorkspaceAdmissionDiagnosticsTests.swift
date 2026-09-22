import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceAdmissionDiagnosticsTests: XCTestCase {
    func testIntentionalWorkingEditIsRejectedThenNormalSaveClearsExactRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let created = try await authority.execute(fixture.command(.createWorkspace(fixture.document("saved-secret"))))
        let initial = await authority.agentAdmissionSnapshot(fixture.workspaceID)
        XCTAssertEqual(initial.diagnostic.admissionState, .clean)
        let edit = try fixture.command(.replaceWorkingDocument(fixture.document("unsaved-secret")))
        let updated = await authority.execute(edit)
        let dirty = try XCTUnwrap(updated.after)
        XCTAssertEqual(dirty.workingRevision, try XCTUnwrap(created.after?.workingRevision) + 1)
        XCTAssertEqual(dirty.dirtyRevision, dirty.workingRevision)
        let rejected = await authority.agentAdmissionSnapshot(fixture.workspaceID)
        XCTAssertEqual(rejected.diagnostic.transition, .admissionRejected)
        XCTAssertEqual(rejected.diagnostic.admissionState, .dirtyWithoutLiveSave)
        XCTAssertEqual(rejected.diagnostic.revisions, dirty)
        XCTAssertEqual(rejected.diagnostic.dirtyOrigin?.operationID, edit.operationID)
        XCTAssertEqual(rejected.diagnostic.dirtyOrigin?.revision, dirty.dirtyRevision)
        XCTAssertEqual(rejected.diagnostic.pendingSaveCount, 0)
        XCTAssertEqual(rejected.diagnostic.workingDiffersFromSaved, true)

        // A routing-only registration must not erase the dirty canonical evidence.
        _ = try await authority.registerReadDocument(fixture.document("routing-secret"))
        let overlayRejected = await authority.agentAdmissionSnapshot(fixture.workspaceID)
        XCTAssertEqual(overlayRejected.snapshot?.document.contentDigest, updated.resultingDigest)
        XCTAssertEqual(overlayRejected.diagnostic.revisions, dirty)
        let saved = await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(saved.disposition, .applied)
        let accepted = await authority.agentAdmissionSnapshot(fixture.workspaceID)
        XCTAssertEqual(accepted.diagnostic.transition, .admissionPassed)
        XCTAssertEqual(accepted.diagnostic.revisions, .init(workingRevision: dirty.workingRevision, savedRevision: dirty.workingRevision, dirtyRevision: nil))
        XCTAssertEqual(accepted.diagnostic.pendingSaveCount, 0)
        XCTAssertNil(accepted.diagnostic.dirtyOrigin)
        let trace = await authority.transitionDiagnostics(fixture.workspaceID)
        XCTAssertEqual(trace.filter { $0.operation == .saveWorkspace }.map(\.transition), [.saveScheduled, .saveStarted, .saveCompleted])
        XCTAssertEqual(trace.first { $0.transition == .dirtyCleared }?.revisions, accepted.diagnostic.revisions)
        XCTAssertEqual(trace.first { $0.transition == .dirtyCleared }?.dirtyOrigin?.operationID, edit.operationID)
        XCTAssertTrue(zip(trace, trace.dropFirst()).allSatisfy { $0.sequence < $1.sequence && $0.uptimeNanoseconds <= $1.uptimeNanoseconds })
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(trace), encoding: .utf8))
        for secret in ["saved-secret", "unsaved-secret", "routing-secret", fixture.root.path, "private-prompt", "private-repository"] {
            XCTAssertFalse(json.contains(secret))
        }
    }

    #if DEBUG
        func testInFlightCancellationRetainsDirtyStateAndRetryOwnsNewGeneration() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let authority = fixture.authority()
            let dirty = try await fixture.makeDirty(authority)
            let entered = expectation(description: "save reached persistence boundary")
            let gate = Gate()
            await authority.testSetBeforeSavedPersistence { _ in
                entered.fulfill()
                await gate.wait()
            }
            let save = Task { await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID))) }
            await fulfillment(of: [entered], timeout: 5)
            let inFlight = await authority.agentAdmissionSnapshot(fixture.workspaceID)
            XCTAssertEqual(inFlight.diagnostic.admissionState, .dirtySaveInFlight)
            XCTAssertEqual(inFlight.diagnostic.pendingSaveCount, 1)
            XCTAssertEqual(inFlight.diagnostic.saveGeneration, 1)
            XCTAssertEqual(inFlight.diagnostic.pendingSaveState, .started)
            XCTAssertEqual(inFlight.diagnostic.revisions, dirty)
            save.cancel()
            await gate.release()
            let cancelled = await save.value
            XCTAssertEqual(cancelled.errorCode, .cancelled)
            let retained = await authority.agentAdmissionSnapshot(fixture.workspaceID)
            XCTAssertEqual(retained.diagnostic.admissionState, .dirtyWithoutLiveSave)
            XCTAssertEqual(retained.diagnostic.revisions, dirty)
            XCTAssertEqual(retained.diagnostic.lastSave?.transition, .saveCancelled)
            XCTAssertEqual(retained.diagnostic.lastSave?.attemptedRevision, dirty.workingRevision)
            XCTAssertEqual(retained.diagnostic.lastSave?.error, .cancelled)
            XCTAssertEqual(retained.diagnostic.pendingSaveState, .none)
            let trace = await authority.transitionDiagnostics(fixture.workspaceID)
            XCTAssertEqual(trace.last { $0.operation == .saveWorkspace }?.transition, .saveCancelled)
            XCTAssertEqual(trace.last { $0.operation == .saveWorkspace }?.pendingSaveCount, 0)
            await authority.testSetBeforeSavedPersistence(nil)
            let retry = await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
            XCTAssertEqual(retry.disposition, .applied)
            let final = await authority.transitionDiagnostics(fixture.workspaceID)
            XCTAssertEqual(final.last?.transition, .saveCompleted)
            XCTAssertEqual(final.last?.saveGeneration, 2)
            XCTAssertNil(final.last?.revisions?.dirtyRevision)
        }
    #endif

    func testFailedAndSupersededSavesDoNotClaimDirtyClear() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let dirty = try await fixture.makeDirty(authority)
        let stale = await authority.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: dirty.workingRevision - 1,
            origin: .appPresentation(windowID: 1),
            command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(stale.errorCode, .stateConflict)
        let staleTrace = await authority.transitionDiagnostics(fixture.workspaceID)
        XCTAssertEqual(staleTrace.last?.transition, .saveSuperseded)
        XCTAssertFalse(staleTrace.contains { $0.transition == .saveStarted })
        // Force an actual document-write failure, without a timer or error-description fixture.
        let document = try fixture.document("working-secret")
        try FileManager.default.removeItem(at: document.fileURL)
        try FileManager.default.createDirectory(at: document.fileURL, withIntermediateDirectories: false)
        let failed = await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(failed.errorCode, .persistenceFailure)
        let failureTrace = await authority.transitionDiagnostics(fixture.workspaceID)
        XCTAssertEqual(failureTrace.last?.transition, .saveFailed)
        XCTAssertEqual(failureTrace.last?.pendingSaveCount, 0)
        XCTAssertEqual(failureTrace.last?.revisions, dirty)
        XCTAssertFalse(failureTrace.contains { $0.transition == .dirtyCleared })
        try FileManager.default.removeItem(at: document.fileURL)
        let recovered = await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(recovered.disposition, .applied)
        XCTAssertNil(recovered.after?.dirtyRevision)
    }

    func testRestartReconstructsDirtyEvidenceAndRetentionIsGloballyBounded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = fixture.authority()
        let dirty = try await fixture.makeDirty(writer)
        let restarted = fixture.authority()
        _ = await restarted.readySnapshot()
        let rejection = await restarted.agentAdmissionSnapshot(fixture.workspaceID)
        XCTAssertEqual(rejection.diagnostic.revisions, dirty)
        XCTAssertEqual(rejection.diagnostic.dirtyOrigin?.operation, .reconstruction)
        XCTAssertNil(rejection.diagnostic.dirtyOrigin?.operationID, "Do not invent pre-restart provenance")
        XCTAssertEqual(rejection.diagnostic.admissionState, .dirtyWithoutLiveSave)
        let beforeRestart = await writer.agentAdmissionSnapshot(fixture.workspaceID)
        XCTAssertNotEqual(rejection.diagnostic.runtimeID, beforeRestart.diagnostic.runtimeID)
        let reconstructed = await restarted.transitionDiagnostics(fixture.workspaceID)
        XCTAssertEqual(reconstructed.first?.transition, .reconstructed)
        for _ in 0 ..< DomainWorkspaceTransitionBuffer.capacity {
            _ = await restarted.agentAdmissionSnapshot(fixture.workspaceID)
        }
        let bounded = await restarted.transitionDiagnostics(fixture.workspaceID)
        XCTAssertEqual(bounded.count, DomainWorkspaceTransitionBuffer.capacity)
        XCTAssertEqual(bounded.last?.dirtyOrigin?.revision, dirty.dirtyRevision, "Eviction must not lose the live dirty origin")
        for _ in 0 ..< DomainWorkspaceTransitionBuffer.capacity {
            _ = await restarted.agentAdmissionSnapshot(UUID())
        }
        let evicted = await restarted.transitionDiagnostics(fixture.workspaceID)
        XCTAssertTrue(evicted.isEmpty, "Retention is global, not an unbounded map of workspace histories")
        let missing = await restarted.agentAdmissionSnapshot(UUID())
        XCTAssertEqual(missing.diagnostic.admissionState, .unavailable)
    }
}

private actor Gate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private struct Fixture {
    let root: URL
    let workspaceID = UUID()
    let contextID = UUID()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AdmissionDiagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func authority() -> DomainWorkspaceContextAuthority {
        let configuration = DomainRuntimeConfiguration(
            mode: .app,
            profileIdentifier: "admission-diagnostics",
            storageDirectory: root,
            workspaceStorageDirectory: root.appendingPathComponent("Workspaces"),
            eventDirectory: root.appendingPathComponent("Events"),
            temporaryDirectory: root.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        )
        let identity = DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 0, mode: .app, createdAt: Date())
        return .init(identity: identity, persistence: .init(configuration: configuration, identity: identity), metrics: .disabled)
    }

    func command(_ command: DomainWorkspaceCommand) -> DomainWorkspaceCommandEnvelope {
        .init(operationID: UUID(), origin: .appPresentation(windowID: 1), command: command)
    }

    func document(_ name: String) throws -> DomainWorkspaceDocument {
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "name": name,
            "schemaVersion": 1,
            "repoPaths": ["/private-repository"],
            "isSystemWorkspace": false,
            "composeTabs": [["id": contextID.uuidString, "name": "private-prompt"]],
            "activeComposeTabID": contextID.uuidString
        ]
        return try .decode(
            documentBytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            fileURL: root.appendingPathComponent("Workspaces/\(workspaceID.uuidString)/workspace.json")
        )
    }

    func makeDirty(_ authority: DomainWorkspaceContextAuthority) async throws -> DomainRevisionState {
        let created = try await authority.execute(command(.createWorkspace(document("saved-secret"))))
        XCTAssertEqual(created.disposition, .applied)
        let edited = try await authority.execute(command(.replaceWorkingDocument(document("working-secret"))))
        XCTAssertEqual(edited.disposition, .applied)
        return try XCTUnwrap(edited.after)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

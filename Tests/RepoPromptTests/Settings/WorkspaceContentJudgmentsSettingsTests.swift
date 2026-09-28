import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class WorkspaceContentJudgmentsSettingsTests: XCTestCase {
    func testContentWithoutMapNeverRaisesRequiredSchemaVersionToV11() {
        XCTAssertEqual(GlobalSettingsDocument.currentSchemaVersion, 11)
        XCTAssertEqual(GlobalSettingsDocument().requiredSchemaVersion, GlobalSettingsDocument.baselineSchemaVersion)

        var v10Document = Self.scopedRouterDocument()
        XCTAssertEqual(v10Document.requiredSchemaVersion, GlobalSettingsDocument.scopedModelRouterSchemaVersion)
        v10Document.contentJudgmentsByWorkspaceID = [:]
        XCTAssertEqual(v10Document.requiredSchemaVersion, GlobalSettingsDocument.scopedModelRouterSchemaVersion)
    }

    func testPresentMapRequiresV11AndRoundTrips() throws {
        let workspaceID = UUID()
        let document = GlobalSettingsDocument(contentJudgmentsSettings: [workspaceID: .init(enabled: true)])
        XCTAssertEqual(document.requiredSchemaVersion, GlobalSettingsDocument.contentJudgmentsSchemaVersion)

        let decoded = try JSONDecoder().decode(GlobalSettingsDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.contentJudgmentsSettings, [workspaceID: .init(enabled: true)])
    }

    func testExistingV10FileStaysV10AcrossUnrelatedEditsAndAfterDisable() throws {
        let fixture = try makeFixture()
        try fixture.fileStore.save(Self.scopedRouterDocument())
        XCTAssertEqual(try rawRoot(fixture)["schemaVersion"] as? Int, 10)

        let store = try makeStore(fixture)
        store.setShowTooltips(!store.showTooltips())
        var root = try rawRoot(fixture)
        XCTAssertEqual(root["schemaVersion"] as? Int, 10)
        XCTAssertNil(root["contentJudgmentsByWorkspaceID"])

        let workspaceID = UUID()
        store.setContentJudgments(enabled: true, workspaceID: workspaceID)
        root = try rawRoot(fixture)
        XCTAssertEqual(root["schemaVersion"] as? Int, 11)
        XCTAssertNotNil(root["contentJudgmentsByWorkspaceID"])

        store.setContentJudgments(enabled: false, workspaceID: workspaceID)
        root = try rawRoot(fixture)
        XCTAssertEqual(root["schemaVersion"] as? Int, 10)
        XCTAssertNil(root["contentJudgmentsByWorkspaceID"])
    }

    func testPerWorkspaceResolutionPersistsAcrossReload() throws {
        let fixture = try makeFixture()
        let enabledID = UUID()
        let otherID = UUID()
        let store = try makeStore(fixture)
        XCTAssertFalse(store.hasAnyContentJudgmentsEnabled())

        store.setContentJudgments(enabled: true, workspaceID: enabledID)

        XCTAssertTrue(store.contentJudgmentsEnabled(workspaceID: enabledID))
        XCTAssertFalse(store.contentJudgmentsEnabled(workspaceID: otherID))
        XCTAssertFalse(store.contentJudgmentsEnabled(workspaceID: nil))
        XCTAssertTrue(store.hasAnyContentJudgmentsEnabled())

        let reloaded = try makeStore(fixture)
        XCTAssertTrue(reloaded.contentJudgmentsEnabled(workspaceID: enabledID))
        XCTAssertFalse(reloaded.contentJudgmentsEnabled(workspaceID: otherID))
        XCTAssertTrue(reloaded.hasAnyContentJudgmentsEnabled())
    }

    func testUnknownWorkspaceAndEntryWithoutEnabledFieldReadFalse() throws {
        let fixture = try makeFixture()
        let bareEntryID = UUID()
        try fixture.fileStore.save(GlobalSettingsDocument(contentJudgmentsSettings: [bareEntryID: .init(enabled: true)]))
        var root = try rawRoot(fixture)
        root["contentJudgmentsByWorkspaceID"] = [bareEntryID.uuidString: [String: Any]()]
        try writeRawRoot(root, fixture)

        let store = try makeStore(fixture)

        XCTAssertFalse(store.contentJudgmentsEnabled(workspaceID: bareEntryID))
        XCTAssertFalse(store.contentJudgmentsEnabled(workspaceID: UUID()))
        XCTAssertFalse(store.hasAnyContentJudgmentsEnabled())
    }

    func testKnownEditsPreserveUnknownRawSiblings() throws {
        let fixture = try makeFixture()
        let existingID = UUID()
        try fixture.fileStore.save(GlobalSettingsDocument(contentJudgmentsSettings: [existingID: .init(enabled: true)]))
        var root = try rawRoot(fixture)
        root["futureRootGroup"] = ["mode": "strict"]
        root["contentJudgmentsByWorkspaceID"] = [
            existingID.uuidString: ["enabled": true, "futureKnob": "keep"],
            "not-a-workspace-id": ["enabled": true]
        ]
        try writeRawRoot(root, fixture)

        let store = try makeStore(fixture)
        let addedID = UUID()
        store.setContentJudgments(enabled: true, workspaceID: addedID)

        let saved = try rawRoot(fixture)
        XCTAssertEqual((saved["futureRootGroup"] as? [String: Any])?["mode"] as? String, "strict")
        let map = try XCTUnwrap(saved["contentJudgmentsByWorkspaceID"] as? [String: Any])
        let existing = try XCTUnwrap(map[existingID.uuidString] as? [String: Any])
        XCTAssertEqual(existing["futureKnob"] as? String, "keep")
        XCTAssertEqual(existing["enabled"] as? Bool, true)
        XCTAssertNotNil(map["not-a-workspace-id"])
        XCTAssertEqual((map[addedID.uuidString] as? [String: Any])?["enabled"] as? Bool, true)
    }

    // MARK: - Helpers

    private struct Fixture {
        let fileStore: GlobalSettingsFileStore
    }

    /// Each store gets a fresh file-store instance so reloads observe the on-disk document.
    private func makeStore(_ fixture: Fixture) throws -> GlobalSettingsStore {
        let suite = "WorkspaceContentJudgmentsSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fixture.fileStore.fileURL)
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentJudgments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json")))
    }

    private func rawRoot(_ fixture: Fixture) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.fileStore.fileURL)) as? [String: Any]
        )
    }

    private func writeRawRoot(_ root: [String: Any], _ fixture: Fixture) throws {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: fixture.fileStore.fileURL, options: .atomic)
    }

    private static func scopedRouterDocument() -> GlobalSettingsDocument {
        GlobalSettingsDocument(scalarPreferences: GlobalScalarPreferences(modelRouter: .init(
            enabled: false,
            selectedBackendRawValue: "jev",
            candidateRoleRawValues: nil,
            allowedProviderRawValues: nil,
            primaryProviderRawValue: "codexExec"
        )))
    }
}

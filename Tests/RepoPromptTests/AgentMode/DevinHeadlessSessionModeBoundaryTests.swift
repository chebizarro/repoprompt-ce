@testable import RepoPromptApp
import XCTest

/// Exercises the real headless stream path against a scripted Devin CLI, so the session-mode
/// application is pinned at the provider/controller boundary rather than only at the request
/// mapping. The mapping tests in `DevinPermissionLevelTests` stay green if the
/// `controller.setSessionMode` call is deleted from `beforePrompt`; these do not.
final class DevinHeadlessSessionModeBoundaryTests: XCTestCase {
    func testFullApprovalSetsBypassBeforePromptingOnTheRealStreamPath() async throws {
        let h = try makeHarness()
        try await drain(h.makeProvider(level: .fullApproval))

        let order = h.recordedMethodOrder()
        XCTAssertTrue(order.contains("session/new"), "order was \(order)")
        guard let modeIndex = order.firstIndex(of: "session/set_config_option"),
              let promptIndex = order.firstIndex(of: "session/prompt")
        else {
            return XCTFail("expected both a config-option set and a prompt; got \(order)")
        }
        XCTAssertLessThan(
            modeIndex,
            promptIndex,
            "The mode must be applied before the prompt, or the turn runs unescalated."
        )
        let modeSets = h.recordedParams("session/set_config_option")
        XCTAssertEqual(modeSets.first?["configId"] as? String, "mode")
        XCTAssertEqual(modeSets.first?["value"] as? String, "bypass")
    }

    func testLevelsBelowFullApprovalSendNoModeAtAll() async throws {
        for level: DevinAgentToolPreferences.PermissionLevel in [.normal, .acceptEdits, .smart, .providerDefault] {
            let h = try makeHarness()
            try await drain(h.makeProvider(level: level))
            let modeSets = h.recordedParams("session/set_config_option")
                .filter { $0["configId"] as? String == "mode" }
            XCTAssertTrue(
                modeSets.isEmpty,
                "\(level) must not set a session mode on an unattended run; sent \(modeSets)"
            )
            XCTAssertTrue(h.recordedMethodOrder().contains("session/prompt"))
        }
    }

    /// If the escalation cannot be applied, the run must fail rather than silently prompt at
    /// whatever mode the session happened to be in.
    func testPromptIsNotSentWhenTheModeSetFails() async throws {
        let h = try makeHarness(failModeSet: true)
        do {
            try await drain(h.makeProvider(level: .fullApproval))
            XCTFail("expected the run to fail when the session mode could not be applied")
        } catch {
            // expected
        }
        XCTAssertFalse(
            h.recordedMethodOrder().contains("session/prompt"),
            "A failed mode set must abort before prompting."
        )
    }

    // MARK: - Harness

    private struct Harness {
        let workspace: URL
        let recordURL: URL
        var scriptPath: String {
            workspace.appendingPathComponent("devin").path
        }

        func makeProvider(level: DevinAgentToolPreferences.PermissionLevel) -> DevinACPHeadlessAgentProvider {
            let recordPath = recordURL.path
            return DevinACPHeadlessAgentProvider(
                config: DevinAgentConfig(
                    commandName: scriptPath,
                    includeRepoPromptMCPServer: true,
                    modelString: nil
                ),
                workspacePath: workspace.path,
                configuredPermissionLevel: level,
                providerFactory: { config in
                    EnvForwardingDevinProvider(
                        config: config,
                        extraEnvironment: ["ACP_RECORD_PATH": recordPath]
                    )
                }
            )
        }

        private func lines() -> [[String: Any]] {
            guard let text = try? String(contentsOf: recordURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return nil }
                return o
            }
        }

        func recordedMethodOrder() -> [String] {
            lines().compactMap { $0["method"] as? String }
        }

        func recordedParams(_ method: String) -> [[String: Any]] {
            lines().filter { $0["method"] as? String == method }
                .map { $0["params"] as? [String: Any] ?? [:] }
        }
    }

    private func drain(_ provider: DevinACPHeadlessAgentProvider) async throws {
        let stream = try await provider.streamAgentMessage(AgentMessage(userMessage: "hi"))
        for try await _ in stream {}
        await provider.dispose()
    }

    private func makeHarness(failModeSet: Bool = false) throws -> Harness {
        let workspace = try makeTestDirectory(name: "DevinHeadlessSessionModeBoundaryTests")
        let recordURL = workspace.appendingPathComponent("requests.jsonl")
        let script = #"""
        #!/usr/bin/env python3
        import json, os, sys
        record_path = os.environ.get("ACP_RECORD_PATH")
        FAIL_MODE_SET = __FAIL_MODE_SET__
        if "--help" in sys.argv:
            print("Usage: devin acp\n\nRun as an acp server over stdio")
            sys.exit(0)
        def record(method, params):
            if record_path:
                with open(record_path, "a", encoding="utf-8") as h:
                    h.write(json.dumps({"method": method, "params": params}) + "\n")
        def respond(rid, result=None):
            print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result or {}}), flush=True)
        def fail(rid, msg):
            print(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": msg}}), flush=True)
        def options(mode):
            return [
                {"id": "mode", "name": "Session Mode", "category": "mode", "type": "select",
                 "currentValue": mode,
                 "options": [{"value": "accept-edits"}, {"value": "smart"}, {"value": "ask"},
                             {"value": "plan"}, {"value": "bypass"}]},
                {"id": "model", "name": "Model", "category": "model", "type": "select",
                 "currentValue": "swe-2-high", "options": [{"value": "swe-2-high"}]},
            ]
        current_mode = "accept-edits"
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
            except json.JSONDecodeError:
                continue
            method, rid, params = m.get("method"), m.get("id"), m.get("params") or {}
            if method is None:
                continue
            record(method, params)
            if method == "initialize":
                respond(rid, {"protocolVersion": 1,
                              "agentCapabilities": {"loadSession": True,
                                                    "promptCapabilities": {"embeddedContext": True}},
                              "authMethods": []})
            elif method == "session/new":
                respond(rid, {"sessionId": "devin-headless-session", "configOptions": options(current_mode)})
            elif method == "session/set_config_option":
                if FAIL_MODE_SET and params.get("configId") == "mode":
                    fail(rid, "Mode is restricted by your organization's policy")
                else:
                    current_mode = params.get("value", current_mode)
                    respond(rid, {"configOptions": options(current_mode)})
            elif method == "session/prompt":
                print(json.dumps({"jsonrpc": "2.0", "method": "session/update",
                                  "params": {"sessionId": "devin-headless-session",
                                             "update": {"sessionUpdate": "agent_message_chunk",
                                                        "content": {"type": "text", "text": "ok"}}}}), flush=True)
                respond(rid, {"stopReason": "end_turn"})
            elif rid is not None:
                respond(rid, {})
        """#
        .replacingOccurrences(of: "__FAIL_MODE_SET__", with: failModeSet ? "True" : "False")
        let scriptURL = workspace.appendingPathComponent("devin")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return Harness(workspace: workspace, recordURL: recordURL)
    }
}

private struct EnvForwardingDevinProvider: ACPAgentProvider {
    let config: DevinAgentConfig
    let extraEnvironment: [String: String]

    private let inner: DevinACPAgentProvider

    init(config: DevinAgentConfig, extraEnvironment: [String: String]) {
        self.config = config
        self.extraEnvironment = extraEnvironment
        // The run request keeps `includeRepoPromptMCPServer: true` so the permission level is
        // carried; the launch itself drops the injection because validating the real
        // RepoPromptCE executable is orthogonal to the ordering this suite pins, and that
        // binary does not exist in the test environment.
        inner = DevinACPAgentProvider(
            config: DevinAgentConfig(
                commandName: config.commandName,
                additionalPathHints: config.additionalPathHints,
                enableDebugLogging: config.enableDebugLogging,
                includeRepoPromptMCPServer: false,
                modelString: config.modelString
            )
        )
    }

    var providerID: ACPProviderID {
        .devin
    }

    func support(for request: ACPRunRequest) async throws -> ACPSupportResult {
        try await inner.support(for: request)
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        var launch = try inner.makeLaunchConfiguration(for: request)
        launch = ACPLaunchConfiguration(
            providerID: launch.providerID,
            command: launch.command,
            arguments: launch.arguments,
            environment: launch.environment.merging(extraEnvironment) { _, new in new },
            workingDirectory: launch.workingDirectory,
            additionalPathHints: launch.additionalPathHints,
            enableDebugLogging: launch.enableDebugLogging,
            cleanupArtifact: launch.cleanupArtifact,
            expectedExecutableIdentity: launch.expectedExecutableIdentity
        )
        return launch
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        try inner.makeSessionConfiguration(for: request, mcpServer: mcpServer)
    }

    func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
        try inner.buildPromptBlocks(for: message, request: request)
    }

    func normalizeSessionUpdate(_ payload: [String: Any], sessionID: String) -> [NormalizedAgentRuntimeEvent] {
        inner.normalizeSessionUpdate(payload, sessionID: sessionID)
    }

    func normalizeError(_ error: Error) -> Error {
        inner.normalizeError(error)
    }
}

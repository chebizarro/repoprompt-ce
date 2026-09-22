import Foundation

final class DevinACPHeadlessAgentProvider: HeadlessAgentProvider {
    typealias ProviderFactory = @Sendable (_ config: DevinAgentConfig) -> any ACPAgentProvider
    typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

    private let config: DevinAgentConfig
    private let bridge: ACPHeadlessAgentProviderBridge

    init(
        config: DevinAgentConfig,
        workspacePath: String? = nil,
        providerFactory: ProviderFactory? = nil,
        controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
            try ACPAgentSessionController(
                provider: provider,
                runRequest: request,
                diagnosticSink: diagnosticSink
            )
        }
    ) {
        self.config = config
        let resolvedProviderFactory = providerFactory ?? { config in
            DevinACPAgentProvider(config: config)
        }
        bridge = ACPHeadlessAgentProviderBridge(
            providerName: "Devin",
            makeProvider: { resolvedProviderFactory(config) },
            makeRequest: { message, _ in
                Self.makeRunRequest(config: config, workspacePath: workspacePath, message: message)
            },
            makeController: controllerFactory,
            beforePrompt: { controller, request in
                // The bridge has no session-mode step of its own, so apply it here -- before
                // the model, so an escalation is in force for the whole prompt.
                if let mode = request.sessionModeID?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !mode.isEmpty
                {
                    try await controller.setSessionMode(mode)
                }
                guard let model = request.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !model.isEmpty,
                      model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
                else { return }
                try await controller.setSessionModel(model)
            },
            approvalPolicy: .declineUnsupported
        )
    }

    /// Headless runs are unattended: the bridge declines any permission request the
    /// controller does not auto-approve, so a mid-run prompt fails the whole run. The level
    /// comes from `unattendedCLIPermissionMode`/`unattendedSessionModeID` — an explicitly
    /// configured Full Approval escalates, and every other level keeps the `auto` floor.
    /// Both carriers are sent only when the RepoPrompt MCP server is injected; model
    /// discovery keeps the provider default.
    ///
    /// The launch flag alone is not enough: `devin acp` does not consume `--permission-mode`,
    /// so the mode is also applied over ACP before the prompt.
    static func makeRunRequest(
        config: DevinAgentConfig,
        workspacePath: String?,
        message: AgentMessage,
        configuredPermissionLevel: DevinAgentToolPreferences.PermissionLevel =
            DevinAgentToolPreferences.permissionLevel()
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .devin,
            modelString: config.modelString,
            workspacePath: workspacePath,
            resumeSessionID: message.resumeSessionID,
            attachments: [],
            taskLabelKind: nil,
            sessionModeID: config.includeRepoPromptMCPServer
                ? configuredPermissionLevel.unattendedSessionModeID
                : nil,
            launchPermissionMode: config.includeRepoPromptMCPServer
                ? configuredPermissionLevel.unattendedCLIPermissionMode
                : nil
        )
    }

    func streamAgentMessage(
        _ message: AgentMessage,
        runID: UUID? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        try await bridge.streamAgentMessage(message, runID: runID)
    }

    func dispose() async {
        await bridge.dispose()
    }
}

import Foundation
@testable import RepoPromptApp
import XCTest

/// Presentation rules for the observe-only quota surface.
///
/// Each assertion guards a specific misreading: an unknown value looking like a full tank,
/// a "remaining" figure reading as "used", a clamped bar silently clamping the printed
/// number, or an aggregate figure implying per-model eligibility.
final class ProviderQuotaPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        buckets: [ProviderQuotaBucket],
        ordinaryUsageAllowed: Bool? = nil,
        coverage: ProviderQuotaCoverage = .accountWide,
        observedAt: Date? = nil
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            accountKey: .codex(accountID: "acct-1"),
            buckets: buckets,
            facets: ProviderQuotaFacets(ordinaryUsageAllowed: ordinaryUsageAllowed),
            source: .codexAppServerRead,
            coverage: coverage,
            observedAt: observedAt ?? now
        )
    }

    private func bucket(
        id: String = "codex",
        label: String? = "Codex",
        alias: String? = nil,
        isReached: Bool? = nil,
        spendControl: ProviderQuotaSpendControl? = nil,
        windows: [ProviderQuotaWindow]
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            bucketID: ProviderQuotaBucketID(rawValue: id),
            displayLabel: label,
            nativeModelAlias: alias,
            scope: alias.map { ProviderQuotaBucketScope.nativeModelAlias($0) } ?? .accountWide,
            reachedType: isReached == true ? "rate_limit_reached" : nil,
            isReached: isReached,
            planType: nil,
            credits: nil,
            spendControl: spendControl,
            windows: windows
        )
    }

    private func window(
        bucket: String = "codex",
        role: String = "primary",
        percent: ProviderQuotaPercent?,
        duration: TimeInterval? = 18000,
        resetsAt: Date? = nil,
        observedAt: Date? = nil
    ) -> ProviderQuotaWindow {
        ProviderQuotaWindow(
            key: ProviderQuotaWindowKey(
                bucketID: ProviderQuotaBucketID(rawValue: bucket),
                nativeRole: role
            ),
            percent: percent,
            windowDuration: duration,
            resetsAt: resetsAt,
            observedAt: observedAt ?? now
        )
    }

    private func loaded(_ state: CodexQuotaViewState) throws -> (
        sections: [CodexQuotaBucketSection], footnote: String?, notice: String?
    ) {
        guard case let .loaded(sections, footnote, notice) = state else {
            throw XCTSkip("expected loaded state, got \(state)")
        }
        return (sections, footnote, notice)
    }

    // MARK: - Non-value states

    func testDisabledRendersNothing() {
        XCTAssertEqual(ProviderQuotaPresenter.viewState(for: .disabled, now: now), .hidden)
    }

    func testIdleNeverShowsAZeroOrABar() {
        let state = ProviderQuotaPresenter.viewState(for: .idle, now: now)
        XCTAssertEqual(state, .idle(message: "Usage remaining: not reported yet"))
    }

    func testWindowWithoutAPercentDrawsNoBar() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(windows: [window(percent: nil)])])),
            now: now
        )
        let row = try XCTUnwrap(loaded(state).sections.first?.rows.first)
        XCTAssertNil(row.barFraction, "absence of data must not look like a full tank")
        XCTAssertEqual(row.valueText, "Usage remaining: not reported yet")
    }

    // MARK: - Value rendering

    func testFreshWindowStatesSenseAndResetTime() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(windows: [window(
                percent: ProviderQuotaPercent(rawValue: 62, sense: .used),
                resetsAt: now.addingTimeInterval(3600)
            )])])),
            now: now
        )
        let result = try loaded(state)
        let row = try XCTUnwrap(result.sections.first?.rows.first)

        XCTAssertEqual(row.title, "5-hour limit")
        XCTAssertEqual(row.valueText, "62% used", "the sense is always stated")
        XCTAssertEqual(try XCTUnwrap(row.detailText).hasPrefix("Resets "), true)
        XCTAssertEqual(row.barFraction, 0.62)
        XCTAssertNil(result.footnote, "a fresh reading needs no age caveat")
    }

    func testRemainingSenseIsLabelledAndNeverInverted() throws {
        let spendControl = ProviderQuotaSpendControl(
            limitRaw: "$100",
            usedRaw: "$62",
            percent: ProviderQuotaPercent(rawValue: 38, sense: .remaining, declaredUpperBound: 100),
            resetsAt: nil,
            isReached: false
        )
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(
                spendControl: spendControl,
                windows: [window(percent: ProviderQuotaPercent(rawValue: 62, sense: .used))]
            )])),
            now: now
        )
        let rows = try XCTUnwrap(loaded(state).sections.first?.rows)
        let spendRow = try XCTUnwrap(rows.first { $0.title == "Spend limit" })
        XCTAssertEqual(spendRow.valueText, "38% remaining", "never silently inverted to 62% used")
    }

    func testValueAboveDeclaredBoundPrintsRealFigureWhileBarClamps() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(windows: [window(
                percent: ProviderQuotaPercent(rawValue: 112, sense: .used, declaredUpperBound: 100)
            )])])),
            now: now
        )
        let row = try XCTUnwrap(loaded(state).sections.first?.rows.first)
        XCTAssertEqual(row.valueText, "112% used", "the printed number never clamps")
        XCTAssertEqual(row.barFraction, 1.0, "the bar does")
    }

    func testReachedBucketRendersLimitReached() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(
                isReached: true,
                windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 100, sense: .used),
                    resetsAt: now.addingTimeInterval(1800)
                )]
            )])),
            now: now
        )
        let row = try XCTUnwrap(loaded(state).sections.first?.rows.first)
        XCTAssertEqual(row.valueText, "Limit reached")
        XCTAssertTrue(row.isReached)
    }

    // MARK: - Staleness

    func testStaleSnapshotStatesItsAge() throws {
        let observed = now.addingTimeInterval(-3 * 3600)
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(
                buckets: [bucket(windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 62, sense: .used),
                    observedAt: observed
                )])],
                observedAt: observed
            )),
            now: now
        )
        let footnote = try XCTUnwrap(loaded(state).footnote)
        XCTAssertEqual(footnote, "Last seen 3 hours ago — may be out of date")
    }

    func testElapsedResetIsCalledOutRatherThanShownAsRefilled() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [bucket(windows: [window(
                percent: ProviderQuotaPercent(rawValue: 93, sense: .used),
                resetsAt: now.addingTimeInterval(-600),
                observedAt: now.addingTimeInterval(-900)
            )])])),
            now: now
        )
        let result = try loaded(state)
        let row = try XCTUnwrap(result.sections.first?.rows.first)
        XCTAssertEqual(row.valueText, "93% used", "the observed value is kept, not refilled")
        XCTAssertTrue(try XCTUnwrap(row.detailText).contains("Window reset"))
        XCTAssertTrue(try XCTUnwrap(result.footnote).contains("since reset"))
    }

    // MARK: - Coverage and capability

    func testAggregateOnlyCoverageIsLabelledAsAllModels() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(
                buckets: [bucket(label: nil, windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 62, sense: .used)
                )])],
                coverage: .accountWideAggregateOnly
            )),
            now: now
        )
        XCTAssertEqual(try loaded(state).sections.first?.title, "Plan usage (all models)")
    }

    func testPerModelBucketUsesProviderLabelAndDoesNotClaimAllModels() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(
                buckets: [bucket(label: "Codex Mini", alias: "gpt-5-codex-mini", windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 5, sense: .used)
                )])],
                coverage: .modelFamilies(["gpt-5-codex-mini"])
            )),
            now: now
        )
        let title = try XCTUnwrap(loaded(state).sections.first?.title)
        XCTAssertEqual(title, "Codex Mini")
        XCTAssertFalse(title.contains("all models"))
    }

    func testOrdinaryUsageDisallowedSurfacesIndependentlyOfPercentages() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(
                buckets: [bucket(windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 2, sense: .used)
                )])],
                ordinaryUsageAllowed: false
            )),
            now: now
        )
        XCTAssertEqual(
            try loaded(state).notice,
            "Standard usage unavailable on this account right now"
        )
    }

    // MARK: - Bucket and window ordering / titles

    func testBucketsRenderInProviderOrderAndAreNeverCollapsed() throws {
        let state = ProviderQuotaPresenter.viewState(
            for: .loaded(snapshot(buckets: [
                bucket(id: "codex", label: "Codex", windows: [window(
                    percent: ProviderQuotaPercent(rawValue: 62, sense: .used)
                )]),
                bucket(id: "codex-mini", label: "Codex Mini", windows: [window(
                    bucket: "codex-mini",
                    percent: ProviderQuotaPercent(rawValue: 5, sense: .used)
                )])
            ])),
            now: now
        )
        XCTAssertEqual(try loaded(state).sections.map(\.title), ["Codex", "Codex Mini"])
    }

    func testWindowTitlesDeriveFromProviderDeclaredDuration() {
        XCTAssertEqual(
            ProviderQuotaPresenter.windowTitle(for: window(percent: nil, duration: 300 * 60)),
            "5-hour limit"
        )
        XCTAssertEqual(
            ProviderQuotaPresenter.windowTitle(for: window(percent: nil, duration: 10080 * 60)),
            "Weekly limit"
        )
        // No declared duration: fall back to the provider's own role name, invent nothing.
        XCTAssertEqual(
            ProviderQuotaPresenter.windowTitle(for: window(role: "secondary", percent: nil, duration: nil)),
            "Secondary"
        )
    }
}

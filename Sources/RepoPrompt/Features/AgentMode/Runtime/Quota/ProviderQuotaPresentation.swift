import Foundation

// SEARCH-HELPER: quota presentation, usage remaining text, reset time, stale wording
//
// Pure projection from the quota domain to small, immutable, `Equatable` view state.
//
// Presentation rules (deliberate, and each one exists to prevent a specific misreading):
//  - Never show a bare number without provenance; anything not fresh states its age.
//  - `unknown` never renders a bar. Absence of data must not look like a full tank.
//  - Always label whether a percentage is *used* or *remaining*; never silently invert.
//  - A bar may clamp, but the printed number never does.
//  - Buckets render in provider order, each with its own windows, never collapsed.
//  - Aggregate-only coverage is labelled as such and never implies a per-model figure.

/// One rendered window row.
struct CodexQuotaWindowRow: Equatable, Identifiable {
    let id: String
    /// Provider label when supplied, otherwise derived from the provider's own window
    /// duration. Never invented.
    let title: String
    /// The figure with its sense stated, e.g. "62% used" or "38% remaining".
    let valueText: String
    /// Reset or staleness detail.
    let detailText: String?
    /// Clamped fraction for the bar, or `nil` when there is nothing to draw.
    let barFraction: Double?
    let isReached: Bool
}

/// One rendered bucket section.
struct CodexQuotaBucketSection: Equatable, Identifiable {
    let id: String
    let title: String
    let rows: [CodexQuotaWindowRow]
}

/// Compact, immutable state for the settings surface.
enum CodexQuotaViewState: Equatable {
    /// Feature is off; the surface renders nothing at all.
    case hidden
    /// Enabled but never observed.
    case idle(message: String)
    case loading
    case unavailable(message: String)
    case loaded(
        sections: [CodexQuotaBucketSection],
        footnote: String?,
        accountNotice: String?
    )
}

enum ProviderQuotaPresenter {
    static let notReportedMessage = "Usage remaining: not reported yet"
    static let unsupportedMessage = "Usage remaining: not available for this provider"

    static func viewState(for status: CodexQuotaStatus, now: Date) -> CodexQuotaViewState {
        switch status {
        case .disabled:
            .hidden
        case .idle:
            .idle(message: notReportedMessage)
        case .loading:
            .loading
        case let .unavailable(reason):
            .unavailable(message: reason)
        case let .loaded(snapshot):
            loadedState(snapshot: snapshot, now: now)
        }
    }

    private static func loadedState(snapshot: ProviderQuotaSnapshot, now: Date) -> CodexQuotaViewState {
        let sections = snapshot.buckets.map { bucket in
            section(for: bucket, coverage: snapshot.coverage, now: now)
        }
        guard !sections.isEmpty else {
            return .idle(message: notReportedMessage)
        }

        var footnote: String?
        switch snapshot.availability(now: now) {
        case let .stale(observedAt, reason):
            let age = relativeAge(from: observedAt, to: now)
            footnote = switch reason {
            case .resetElapsed:
                "Last seen \(age) — a limit window has since reset, so this may be out of date"
            case .observationAged:
                "Last seen \(age) — may be out of date"
            }
        case let .unsupported(reason):
            footnote = reason
        case .fresh, .unknown:
            footnote = nil
        }

        // An explicit provider capability flag is authoritative on its own and is reported
        // independently of any percentage.
        let accountNotice: String? = if snapshot.facets.ordinaryUsageAllowed == false {
            "Standard usage unavailable on this account right now"
        } else {
            nil
        }

        return .loaded(sections: sections, footnote: footnote, accountNotice: accountNotice)
    }

    private static func section(
        for bucket: ProviderQuotaBucket,
        coverage: ProviderQuotaCoverage,
        now: Date
    ) -> CodexQuotaBucketSection {
        var rows = bucket.windows.map { window in
            row(for: window, bucket: bucket, now: now)
        }
        if let spendControl = bucket.spendControl {
            rows.append(spendControlRow(spendControl, bucketID: bucket.bucketID, now: now))
        }
        return CodexQuotaBucketSection(
            id: bucket.bucketID.rawValue,
            title: bucketTitle(for: bucket, coverage: coverage),
            rows: rows
        )
    }

    static func bucketTitle(for bucket: ProviderQuotaBucket, coverage: ProviderQuotaCoverage) -> String {
        if let label = bucket.displayLabel, !label.isEmpty {
            return label
        }
        switch bucket.scope {
        case let .nativeModelAlias(alias):
            return alias
        case .accountWide:
            // Only claim "all models" when the snapshot genuinely cannot resolve families.
            return coverage == .accountWideAggregateOnly ? "Plan usage (all models)" : "Plan usage"
        case .unattributed:
            return "Plan usage"
        }
    }

    private static func row(
        for window: ProviderQuotaWindow,
        bucket: ProviderQuotaBucket,
        now: Date
    ) -> CodexQuotaWindowRow {
        let isReached = bucket.isReached == true
        let availability = ProviderQuotaSnapshot.availability(for: window, now: now)

        guard let percent = window.percent else {
            return CodexQuotaWindowRow(
                id: rowID(window.key),
                title: windowTitle(for: window),
                valueText: notReportedMessage,
                detailText: nil,
                // No bar for an unknown value.
                barFraction: nil,
                isReached: isReached
            )
        }

        var details: [String] = []
        if let resetsAt = window.resetsAt {
            let hasReset = resetsAt <= now
            details.append(hasReset ? "Window reset \(relativeAge(from: resetsAt, to: now)) ago" : "Resets \(resetText(resetsAt, now: now))")
        }
        if case let .stale(observedAt, reason) = availability, reason == .observationAged {
            details.append("last seen \(relativeAge(from: observedAt, to: now))")
        }

        return CodexQuotaWindowRow(
            id: rowID(window.key),
            title: windowTitle(for: window),
            valueText: isReached ? "Limit reached" : percentText(percent),
            detailText: details.isEmpty ? nil : details.joined(separator: " · "),
            barFraction: percent.clampedForDisplay() / max(percent.declaredUpperBound ?? 100, 1),
            isReached: isReached
        )
    }

    private static func spendControlRow(
        _ spendControl: ProviderQuotaSpendControl,
        bucketID: ProviderQuotaBucketID,
        now: Date
    ) -> CodexQuotaWindowRow {
        var details: [String] = []
        if let resetsAt = spendControl.resetsAt, resetsAt > now {
            details.append("Resets \(resetText(resetsAt, now: now))")
        }
        return CodexQuotaWindowRow(
            id: "\(bucketID.rawValue)#spendControl",
            title: "Spend limit",
            valueText: spendControl.isReached == true ? "Limit reached" : percentText(spendControl.percent),
            detailText: details.isEmpty ? nil : details.joined(separator: " · "),
            barFraction: spendControl.percent.clampedForDisplay() / max(spendControl.percent.declaredUpperBound ?? 100, 1),
            isReached: spendControl.isReached == true
        )
    }

    private static func rowID(_ key: ProviderQuotaWindowKey) -> String {
        "\(key.bucketID.rawValue)#\(key.nativeRole)"
    }

    /// The printed figure always states its sense and is never clamped, even above the
    /// provider's declared bound.
    static func percentText(_ percent: ProviderQuotaPercent) -> String {
        let value = formattedNumber(percent.rawValue)
        return switch percent.sense {
        case .used: "\(value)% used"
        case .remaining: "\(value)% remaining"
        }
    }

    /// Window titles come from the provider's own declared duration, or fall back to the
    /// provider's own role name. Nothing is invented.
    static func windowTitle(for window: ProviderQuotaWindow) -> String {
        guard let duration = window.windowDuration, duration > 0 else {
            return window.nativeRole.prefix(1).uppercased() + window.nativeRole.dropFirst()
        }
        let minutes = Int((duration / 60).rounded())
        if minutes % (60 * 24) == 0 {
            let days = minutes / (60 * 24)
            return days == 7 ? "Weekly limit" : "\(days)-day limit"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)-hour limit"
        }
        return "\(minutes)-minute limit"
    }

    private static func formattedNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    static func resetText(_ resetsAt: Date, now: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDate(resetsAt, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: resetsAt)
        }
        formatter.dateFormat = "MMM d 'at' HH:mm"
        return formatter.string(from: resetsAt)
    }

    static func relativeAge(from: Date, to: Date) -> String {
        let seconds = max(to.timeIntervalSince(from), 0)
        if seconds < 90 { return "just now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) minutes ago" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = Int((seconds / 86400).rounded())
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

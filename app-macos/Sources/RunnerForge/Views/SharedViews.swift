import SwiftUI

/// The eight pages, in the order the user should walk them the first time.
public enum ForgePage: String, CaseIterable, Identifiable, Hashable {
    case preflight, targets, credentials, signing, runners, cleanup, export, logs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .preflight: "Preflight"
        case .targets: "Targets"
        case .credentials: "Credentials"
        case .signing: "Signing"
        case .runners: "Runners"
        case .cleanup: "Cleanup"
        case .export: "Export"
        case .logs: "Logs"
        }
    }

    public var symbol: String {
        switch self {
        case .preflight: "checklist"
        case .targets: "target"
        case .credentials: "key.fill"
        case .signing: "signature"
        case .runners: "play.circle"
        case .cleanup: "trash"
        case .export: "square.and.arrow.up"
        case .logs: "text.alignleft"
        }
    }
}

/// A page title plus a one-line explanation of what the page is for.
public struct PageHeader: View {
    let title: String
    let subtitle: String

    public init(_ title: String, _ subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A coloured status pill. One definition, so "pass" looks the same everywhere.
public struct StatusBadge: View {
    let text: String
    let tint: Color

    public init(text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public init(_ status: PreflightStatus) {
        switch status {
        case .checking: self.init(text: "checking", tint: .secondary)
        case .pass: self.init(text: "pass", tint: .green)
        case .warn: self.init(text: "warn", tint: .orange)
        case .fail: self.init(text: "fail", tint: .red)
        }
    }

    public var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// A boxed explanatory note. Used where a design decision would otherwise look
/// like a missing feature.
public struct ExplanationBox: View {
    let symbol: String
    let text: String

    public init(symbol: String = "info.circle", text: String) {
        self.symbol = symbol
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

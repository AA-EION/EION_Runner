import Foundation

/// Outcome of one preflight check.
public enum PreflightStatus: String, Sendable {
    case checking
    case pass
    /// Not met, but only some runner classes are affected.
    case warn
    /// Not met, and the affected classes cannot run at all.
    case fail
}

/// One row on the Preflight page: what was checked, what was found, and whether
/// Runner Forge can fix it.
public struct PreflightCheck: Sendable, Identifiable, Hashable {
    public let id = UUID()
    public let name: String
    public let status: PreflightStatus

    /// What was actually found. Concrete, not "something went wrong".
    public let detail: String

    /// What the user (or the Fix button) should do. Nil when there is nothing to do.
    public let fixHint: String?

    /// True when the Fix button can resolve this without leaving the app.
    public let autoFixable: Bool

    /// Runner classes this check blocks, by classId. Empty when it blocks nothing.
    public let blocksClasses: [String]

    /// True when the failure has no workaround at all — an Intel Mac, for
    /// instance. The UI states the reason rather than offering a Fix that cannot
    /// possibly work.
    public let isHardBlock: Bool

    public init(
        name: String,
        status: PreflightStatus,
        detail: String,
        fixHint: String? = nil,
        autoFixable: Bool = false,
        blocksClasses: [String] = [],
        isHardBlock: Bool = false
    ) {
        self.name = name
        self.status = status
        self.detail = detail
        self.fixHint = fixHint
        self.autoFixable = autoFixable
        self.blocksClasses = blocksClasses
        self.isHardBlock = isHardBlock
    }
}

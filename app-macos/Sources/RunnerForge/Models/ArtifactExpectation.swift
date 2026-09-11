import Foundation

/// One row of the artifact contract: an artifact that must exist, and what must
/// be inside it.
///
/// This is the in-app twin of the manifest consumed by
/// `scripts/verify-artifacts.sh`, so the GUI can re-assert the contract locally
/// against downloaded artifacts rather than trusting the CI job's word for it.
public struct ArtifactExpectation: Sendable, Identifiable, Hashable {
    public let name: String

    /// A missing required artifact fails the run. Optional ones exist for the
    /// AAX artifacts, legitimately absent when no SDK is configured.
    public let required: Bool

    /// At least one entry must match each pattern, and be non-empty.
    public let globs: [String]

    /// True when the artifact holds tarred macOS bundles that must be extracted
    /// before assertion. upload-artifact flattens symlinks, so bundles are
    /// tarred on the way in and untarred here.
    public let untar: Bool

    /// Patterns naming macOS bundle directories, which must still have
    /// Contents/MacOS/ and Contents/Info.plist after the tar round-trip.
    public let bundles: [String]

    public var id: String { name }

    public init(
        name: String,
        required: Bool,
        globs: [String],
        untar: Bool = false,
        bundles: [String] = []
    ) {
        self.name = name
        self.required = required
        self.globs = globs
        self.untar = untar
        self.bundles = bundles
    }

    /// The artifact contract, rendered for a project name.
    ///
    /// - Parameter aaxAvailable: When false the AAX artifacts become optional and
    ///   the skip marker becomes required, so the set is never silently short.
    public static func contract(for project: String, aaxAvailable: Bool) -> [ArtifactExpectation] {
        [
            ArtifactExpectation(name: "\(project)-windows-x64", required: true,
                                globs: ["*.vst3", "*.clap", "*.exe"]),
            ArtifactExpectation(name: "\(project)-windows-arm64", required: true,
                                globs: ["*.vst3", "*.clap", "*.exe"]),
            ArtifactExpectation(name: "\(project)-windows-installer", required: true,
                                globs: ["*.exe"]),
            ArtifactExpectation(name: "\(project)-macos-universal", required: true,
                                globs: ["*.vst3", "*.component", "*.clap", "*.app"],
                                untar: true,
                                bundles: ["*.vst3", "*.component", "*.app"]),
            ArtifactExpectation(name: "\(project)-macos-installer", required: true,
                                globs: ["*.pkg", "*.dmg"]),
            ArtifactExpectation(name: "\(project)-aax-windows", required: aaxAvailable,
                                globs: ["*.aaxplugin"]),
            ArtifactExpectation(name: "\(project)-aax-macos", required: aaxAvailable,
                                globs: ["*.aaxplugin"]),
            ArtifactExpectation(name: "\(project)-aax-skipped", required: !aaxAvailable,
                                globs: ["*.txt"]),
            ArtifactExpectation(name: "\(project)-logs-windows", required: true,
                                globs: ["summary.txt"]),
            ArtifactExpectation(name: "\(project)-logs-macos", required: true,
                                globs: ["summary.txt"]),
        ]
    }
}

namespace RunnerForge.Models;

/// <summary>
/// One row of the artifact contract: an artifact that must exist, and what must
/// be inside it.
/// </summary>
/// <remarks>
/// This is the in-app twin of the manifest consumed by
/// scripts/verify-artifacts.sh, so the GUI can re-assert the contract locally
/// against downloaded artifacts rather than trusting the CI job's word for it.
/// </remarks>
public sealed record ArtifactExpectation
{
    public required string Name { get; init; }

    /// <summary>
    /// A missing required artifact fails the run. Optional ones exist for the
    /// AAX artifacts, which are legitimately absent when no SDK is configured.
    /// </summary>
    public required bool Required { get; init; }

    /// <summary>At least one entry must match each pattern, and be non-empty.</summary>
    public required IReadOnlyList<string> Globs { get; init; }

    /// <summary>
    /// True when the artifact holds tarred macOS bundles that must be extracted
    /// before assertion. upload-artifact flattens symlinks, so bundles are
    /// tarred on the way in and untarred here.
    /// </summary>
    public bool Untar { get; init; }

    /// <summary>
    /// Patterns naming macOS bundle directories, which must still have
    /// Contents/MacOS/ and Contents/Info.plist after the tar round-trip.
    /// </summary>
    public IReadOnlyList<string> Bundles { get; init; } = [];

    /// <summary>
    /// The §15.1 contract, rendered for a project name.
    /// </summary>
    /// <param name="project">Product name used as the artifact prefix.</param>
    /// <param name="aaxAvailable">
    /// When false the AAX artifacts become optional and the skip marker becomes
    /// required, so the artifact set is never silently short.
    /// </param>
    public static IReadOnlyList<ArtifactExpectation> ContractFor(string project, bool aaxAvailable) =>
    [
        new() { Name = $"{project}-windows-x64",       Required = true,  Globs = ["*.vst3", "*.clap", "*.exe"] },
        new() { Name = $"{project}-windows-arm64",     Required = true,  Globs = ["*.vst3", "*.clap", "*.exe"] },
        new() { Name = $"{project}-windows-installer", Required = true,  Globs = ["*.exe"] },
        new()
        {
            Name = $"{project}-macos-universal", Required = true, Untar = true,
            Globs = ["*.vst3", "*.component", "*.clap", "*.app"],
            Bundles = ["*.vst3", "*.component", "*.app"],
        },
        new() { Name = $"{project}-macos-installer",   Required = true,  Globs = ["*.pkg", "*.dmg"] },
        new() { Name = $"{project}-aax-windows",       Required = aaxAvailable,  Globs = ["*.aaxplugin"] },
        new() { Name = $"{project}-aax-macos",         Required = aaxAvailable,  Globs = ["*.aaxplugin"] },
        new() { Name = $"{project}-aax-skipped",       Required = !aaxAvailable, Globs = ["*.txt"] },
        new() { Name = $"{project}-logs-windows",      Required = true,  Globs = ["summary.txt"] },
        new() { Name = $"{project}-logs-macos",        Required = true,  Globs = ["summary.txt"] },
    ];
}

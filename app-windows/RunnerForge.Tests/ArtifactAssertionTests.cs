using System.Formats.Tar;
using RunnerForge.Models;
using RunnerForge.Services;
using Xunit;

namespace RunnerForge.Tests;

/// <summary>
/// The artifact contract, asserted against real directories on disk.
/// </summary>
/// <remarks>
/// These tests exist because the contract's whole purpose is catching silent
/// emptiness. A gate that passes an empty artifact is worse than no gate: it
/// converts a broken build into a green run nobody looks at.
/// </remarks>
public sealed class ArtifactAssertionTests : IDisposable
{
    private readonly string _root =
        Path.Combine(Path.GetTempPath(), "rf-artifact-tests-" + Guid.NewGuid().ToString("N"));

    public ArtifactAssertionTests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
        catch (IOException) { }
    }

    private string MakeArtifact(string name, params (string RelativePath, int Bytes)[] files)
    {
        string directory = Path.Combine(_root, name);
        Directory.CreateDirectory(directory);

        foreach ((string relativePath, int bytes) in files)
        {
            string full = Path.Combine(directory, relativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            File.WriteAllBytes(full, new byte[bytes]);
        }

        return directory;
    }

    [Fact]
    public void A_well_formed_artifact_passes()
    {
        MakeArtifact("Canary-windows-x64",
            ("VST3/Canary.vst3/Contents/x86_64-win/Canary.vst3", 1024),
            ("CLAP/Canary.clap", 2048),
            ("Standalone/Canary.exe", 4096));

        var expectation = new ArtifactExpectation
        {
            Name = "Canary-windows-x64",
            Required = true,
            Globs = ["*.vst3", "*.clap", "*.exe"],
        };

        (bool passed, long bytes, int files) = SelfTestService.VerifyArtifact(_root, expectation);

        Assert.True(passed);
        Assert.Equal(1024 + 2048 + 4096, bytes);
        Assert.Equal(3, files);
    }

    /// <summary>
    /// The exact failure `if-no-files-found: error` exists to prevent: an
    /// artifact that uploaded successfully and contains nothing.
    /// </summary>
    [Fact]
    public void An_empty_artifact_fails()
    {
        Directory.CreateDirectory(Path.Combine(_root, "Canary-windows-x64"));

        var expectation = new ArtifactExpectation
        {
            Name = "Canary-windows-x64", Required = true, Globs = ["*.vst3"],
        };

        (bool passed, _, _) = SelfTestService.VerifyArtifact(_root, expectation);
        Assert.False(passed);
    }

    [Fact]
    public void A_missing_required_artifact_fails()
    {
        var expectation = new ArtifactExpectation
        {
            Name = "Canary-macos-installer", Required = true, Globs = ["*.pkg"],
        };

        (bool passed, _, _) = SelfTestService.VerifyArtifact(_root, expectation);
        Assert.False(passed);
    }

    /// <summary>
    /// A missing OPTIONAL artifact is tolerated. This is how the AAX artifacts
    /// are legitimately absent when no SDK is configured.
    /// </summary>
    [Fact]
    public void A_missing_optional_artifact_is_tolerated()
    {
        var expectation = new ArtifactExpectation
        {
            Name = "Canary-aax-windows", Required = false, Globs = ["*.aaxplugin"],
        };

        (bool passed, _, _) = SelfTestService.VerifyArtifact(_root, expectation);
        Assert.True(passed);
    }

    [Fact]
    public void A_missing_required_glob_fails_even_when_other_files_are_present()
    {
        MakeArtifact("Canary-windows-x64",
            ("VST3/Canary.vst3", 1024),
            ("Standalone/Canary.exe", 2048));

        var expectation = new ArtifactExpectation
        {
            Name = "Canary-windows-x64", Required = true,
            Globs = ["*.vst3", "*.clap", "*.exe"],   // no .clap was produced
        };

        (bool passed, _, _) = SelfTestService.VerifyArtifact(_root, expectation);
        Assert.False(passed);
    }

    [Fact]
    public void A_present_but_zero_byte_required_file_fails()
    {
        MakeArtifact("Canary-windows-x64",
            ("VST3/Canary.vst3", 1024),
            ("CLAP/Canary.clap", 0),        // present, and useless
            ("Standalone/Canary.exe", 2048));

        var expectation = new ArtifactExpectation
        {
            Name = "Canary-windows-x64", Required = true, Globs = ["*.vst3", "*.clap", "*.exe"],
        };

        (bool passed, _, _) = SelfTestService.VerifyArtifact(_root, expectation);
        Assert.False(passed);
    }

    /// <summary>
    /// macOS bundles are tarred on the way into an artifact because
    /// upload-artifact flattens symlinks. The verifier untars before asserting.
    /// </summary>
    [Fact]
    public void A_tarred_macos_bundle_passes_after_extraction()
    {
        string staging = Path.Combine(_root, "staging");
        string bundle = Path.Combine(staging, "Canary.component");
        Directory.CreateDirectory(Path.Combine(bundle, "Contents", "MacOS"));
        File.WriteAllBytes(Path.Combine(bundle, "Contents", "MacOS", "Canary"), new byte[4096]);
        File.WriteAllText(Path.Combine(bundle, "Contents", "Info.plist"), "<plist/>");

        string artifact = Path.Combine(_root, "Canary-macos-universal");
        Directory.CreateDirectory(artifact);
        TarFile.CreateFromDirectory(staging, Path.Combine(artifact, "macos-bundles.tar"),
            includeBaseDirectory: false);

        var expectation = new ArtifactExpectation
        {
            Name = "Canary-macos-universal", Required = true, Untar = true,
            Globs = ["*.component"], Bundles = ["*.component"],
        };

        (bool passed, _, _) = SelfTestService.VerifyArtifact(_root, expectation);
        Assert.True(passed);
    }

    /// <summary>
    /// A bundle missing Contents/MacOS did not survive the round-trip and would
    /// be rejected by every host. It must not pass.
    /// </summary>
    [Fact]
    public void A_corrupted_macos_bundle_fails()
    {
        string staging = Path.Combine(_root, "staging-bad");
        string bundle = Path.Combine(staging, "Canary.component", "Contents");
        Directory.CreateDirectory(bundle);
        File.WriteAllText(Path.Combine(bundle, "Info.plist"), "<plist/>");
        // No Contents/MacOS at all.

        string artifact = Path.Combine(_root, "Canary-macos-universal");
        Directory.CreateDirectory(artifact);
        TarFile.CreateFromDirectory(staging, Path.Combine(artifact, "macos-bundles.tar"),
            includeBaseDirectory: false);

        var expectation = new ArtifactExpectation
        {
            Name = "Canary-macos-universal", Required = true, Untar = true,
            Globs = ["*.component"], Bundles = ["*.component"],
        };

        (bool passed, _, _) = SelfTestService.VerifyArtifact(_root, expectation);
        Assert.False(passed);
    }

    /// <summary>
    /// Uploading a bundle raw instead of tarring it is a specific, easy mistake.
    /// The verifier must not quietly accept it.
    /// </summary>
    [Fact]
    public void An_artifact_expecting_a_tar_but_shipped_raw_fails()
    {
        MakeArtifact("Canary-macos-universal",
            ("Canary.component/Contents/MacOS/Canary", 4096),
            ("Canary.component/Contents/Info.plist", 64));

        var expectation = new ArtifactExpectation
        {
            Name = "Canary-macos-universal", Required = true, Untar = true,
            Globs = ["*.component"], Bundles = ["*.component"],
        };

        (bool passed, _, _) = SelfTestService.VerifyArtifact(_root, expectation);
        Assert.False(passed);
    }

    // --- the contract itself -------------------------------------------------

    [Fact]
    public void The_contract_names_every_required_artifact()
    {
        IReadOnlyList<ArtifactExpectation> contract =
            ArtifactExpectation.ContractFor("Canary", aaxAvailable: false);

        string[] names = [.. contract.Select(c => c.Name)];

        Assert.Contains("Canary-windows-x64", names);
        Assert.Contains("Canary-windows-arm64", names);
        Assert.Contains("Canary-windows-installer", names);
        Assert.Contains("Canary-macos-universal", names);
        Assert.Contains("Canary-macos-installer", names);
        Assert.Contains("Canary-logs-windows", names);
        Assert.Contains("Canary-logs-macos", names);
    }

    [Fact]
    public void Without_an_sdk_the_aax_artifacts_are_optional_and_the_marker_is_required()
    {
        IReadOnlyList<ArtifactExpectation> contract =
            ArtifactExpectation.ContractFor("Canary", aaxAvailable: false);

        Assert.False(contract.First(c => c.Name == "Canary-aax-windows").Required);
        Assert.False(contract.First(c => c.Name == "Canary-aax-macos").Required);
        Assert.True(contract.First(c => c.Name == "Canary-aax-skipped").Required);
    }

    [Fact]
    public void With_an_sdk_the_aax_artifacts_are_required_and_the_marker_is_not()
    {
        IReadOnlyList<ArtifactExpectation> contract =
            ArtifactExpectation.ContractFor("Canary", aaxAvailable: true);

        Assert.True(contract.First(c => c.Name == "Canary-aax-windows").Required);
        Assert.True(contract.First(c => c.Name == "Canary-aax-macos").Required);
        Assert.False(contract.First(c => c.Name == "Canary-aax-skipped").Required);
    }

    /// <summary>
    /// Both platforms must always be represented. A run that produced only
    /// Windows output is not a successful run of this pipeline.
    /// </summary>
    [Fact]
    public void The_contract_always_requires_both_a_windows_and_a_macos_artifact()
    {
        foreach (bool aax in new[] { true, false })
        {
            IReadOnlyList<ArtifactExpectation> contract = ArtifactExpectation.ContractFor("X", aax);

            Assert.Contains(contract, c => c.Required && c.Name.Contains("-windows-"));
            Assert.Contains(contract, c => c.Required && c.Name.Contains("-macos-"));
        }
    }

    [Fact]
    public void Only_the_macos_bundle_artifact_is_untarred()
    {
        IReadOnlyList<ArtifactExpectation> contract = ArtifactExpectation.ContractFor("Canary", false);

        Assert.True(contract.First(c => c.Name == "Canary-macos-universal").Untar);
        Assert.False(contract.First(c => c.Name == "Canary-windows-x64").Untar);
        Assert.False(contract.First(c => c.Name == "Canary-macos-installer").Untar);
    }
}

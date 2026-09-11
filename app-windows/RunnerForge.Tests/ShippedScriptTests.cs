using RunnerForge.Services;
using Xunit;

namespace RunnerForge.Tests;

/// <summary>
/// Guards on the shipped PowerShell, for the class of assumption that has now
/// broken this product twice: believing a value is stable when Windows actually
/// varies it per machine.
/// </summary>
/// <remarks>
/// First it was PATH — wraptool is not on it, so a PATH check called a working
/// install missing. Then it was LOCALE: the Code Signing EKU's FriendlyName is
/// translated by Windows, so comparing it to the English string "Code Signing"
/// rejected a perfectly valid certificate on a Spanish install with
/// "found: Firma de codigo".
///
/// These read the scripts as text. That is a blunt instrument, but the scripts
/// cannot be executed from here and the alternative is no coverage at all for a
/// mistake that has already shipped twice.
/// </remarks>
public sealed class ShippedScriptTests
{
    /// <summary>Walks up from the test binary to the repository root.</summary>
    private static string RepoRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);

        while (directory is not null)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "scripts"))
                && File.Exists(Path.Combine(directory.FullName, "versions.toml")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }

        throw new DirectoryNotFoundException(
            $"no repository root above {AppContext.BaseDirectory}");
    }

    private static string CertScript() =>
        File.ReadAllText(Path.Combine(RepoRoot(), "scripts", "make-signing-cert.ps1"));

    [Fact]
    public void The_certificate_script_identifies_the_EKU_by_OID()
    {
        // 1.3.6.1.5.5.7.3.3 is id-kp-codeSigning and is the same in every locale.
        Assert.Contains("1.3.6.1.5.5.7.3.3", CertScript(), StringComparison.Ordinal);
    }

    [Fact]
    public void The_certificate_script_never_compares_an_EKU_to_an_English_name()
    {
        string script = CertScript();

        // The exact shapes that broke it: a comparison of the localised
        // FriendlyName against the English label.
        Assert.DoesNotContain("FriendlyName -contains 'Code Signing'", script, StringComparison.Ordinal);
        Assert.DoesNotContain("FriendlyName -eq 'Code Signing'", script, StringComparison.Ordinal);
        Assert.DoesNotContain("-notcontains 'Code Signing'", script, StringComparison.Ordinal);
    }

    [Fact]
    public void The_certificate_script_forces_utf8_output()
    {
        // Windows PowerShell writes in the console's OEM code page, so a
        // localised message reaches a UTF-8 reader as mojibake — a real run
        // logged "Firma de c¢digo" for "Firma de código".
        Assert.Contains("OutputEncoding", CertScript(), StringComparison.Ordinal);
    }

    [Fact]
    public void The_app_also_identifies_code_signing_certificates_by_OID()
    {
        // The app and the script have to agree about what a code-signing
        // certificate is, or the Signing page lists one the generator refuses to
        // acknowledge — which is precisely what happened.
        string service = File.ReadAllText(Path.Combine(
            RepoRoot(), "app-windows", "RunnerForge", "Services", "SigningService.cs"));

        Assert.Contains("1.3.6.1.5.5.7.3.3", service, StringComparison.Ordinal);
    }

    [Fact]
    public void Child_process_output_is_decoded_as_utf8()
    {
        string runner = File.ReadAllText(Path.Combine(
            RepoRoot(), "app-windows", "RunnerForge", "Services", "ProcessRunner.cs"));

        Assert.Contains("StandardOutputEncoding", runner, StringComparison.Ordinal);
        Assert.Contains("StandardErrorEncoding", runner, StringComparison.Ordinal);
    }
}

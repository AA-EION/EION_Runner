using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace RunnerForge.Services;

/// <summary>
/// Secrets, in Windows Credential Manager. Never in forge.json, never in a file,
/// never in an image layer.
/// </summary>
/// <remarks>
/// Target names are <c>RunnerForge:{keyName}</c>, type CRED_TYPE_GENERIC,
/// persistence CRED_PERSIST_LOCAL_MACHINE. The macOS twin uses Keychain
/// Services with service <c>com.runnerforge.secrets</c>.
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class SecretStore(LogBus logBus)
{
    private readonly LogBus _logBus = logBus;

    public const string TargetPrefix = "RunnerForge:";

    /// <summary>The complete set of secret names this product stores.</summary>
    public static IReadOnlyList<string> KeyNames { get; } =
    [
        "githubAppPrivateKey",
        "paceAccount",
        "pacePassword",
        "azureClientId",
        "azureClientSecret",
        "azureTenantId",
        "appleDevIdP12",
        "appleDevIdP12Password",
        "appleAscIssuerId",
        "appleAscKeyId",
        "appleAscPrivateKey",
    ];

    private const uint CRED_TYPE_GENERIC = 1;
    private const uint CRED_PERSIST_LOCAL_MACHINE = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredFree")]
    private static extern void CredFree(IntPtr buffer);

    private static string TargetFor(string keyName) => TargetPrefix + keyName;

    public bool Write(string keyName, string secret)
    {
        ArgumentException.ThrowIfNullOrEmpty(keyName);
        ArgumentNullException.ThrowIfNull(secret);

        byte[] blob = Encoding.Unicode.GetBytes(secret);
        IntPtr blobPointer = Marshal.AllocHGlobal(blob.Length);
        IntPtr targetPointer = Marshal.StringToCoTaskMemUni(TargetFor(keyName));
        IntPtr userPointer = Marshal.StringToCoTaskMemUni(Environment.UserName);

        try
        {
            Marshal.Copy(blob, 0, blobPointer, blob.Length);

            var credential = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = targetPointer,
                CredentialBlobSize = (uint)blob.Length,
                CredentialBlob = blobPointer,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = userPointer,
            };

            bool written = CredWriteW(ref credential, 0);
            if (!written)
            {
                _logBus.Error("secrets", $"could not store '{keyName}': Win32 error {Marshal.GetLastWin32Error()}");
                return false;
            }

            // Registered so it can never appear in a log line from here on.
            _logBus.RegisterSecret(secret);
            _logBus.Info("secrets", $"stored '{keyName}' in Credential Manager");
            return true;
        }
        finally
        {
            // Zero the blob before freeing so the plaintext does not linger in
            // process memory any longer than it must.
            for (int i = 0; i < blob.Length; i++) blob[i] = 0;
            Marshal.Copy(blob, 0, blobPointer, blob.Length);
            Marshal.FreeHGlobal(blobPointer);
            Marshal.FreeCoTaskMem(targetPointer);
            Marshal.FreeCoTaskMem(userPointer);
        }
    }

    public string? Read(string keyName)
    {
        ArgumentException.ThrowIfNullOrEmpty(keyName);

        if (!CredReadW(TargetFor(keyName), CRED_TYPE_GENERIC, 0, out IntPtr credentialPointer))
        {
            return null;
        }

        try
        {
            CREDENTIAL credential = Marshal.PtrToStructure<CREDENTIAL>(credentialPointer);
            if (credential.CredentialBlobSize == 0) return null;

            byte[] blob = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, blob, 0, blob.Length);
            string secret = Encoding.Unicode.GetString(blob);

            _logBus.RegisterSecret(secret);
            return secret;
        }
        finally
        {
            CredFree(credentialPointer);
        }
    }

    public bool Delete(string keyName)
    {
        ArgumentException.ThrowIfNullOrEmpty(keyName);

        bool deleted = CredDeleteW(TargetFor(keyName), CRED_TYPE_GENERIC, 0);
        _logBus.Info("secrets", deleted
            ? $"deleted '{keyName}'"
            : $"nothing to delete for '{keyName}'");
        return deleted;
    }

    public bool Has(string keyName) => Read(keyName) is not null;

    /// <summary>
    /// Which secrets are present, for the Credentials page and the secrets
    /// checklist. Returns presence only — never a value.
    /// </summary>
    public IReadOnlyDictionary<string, bool> Presence() =>
        KeyNames.ToDictionary(name => name, Has);
}

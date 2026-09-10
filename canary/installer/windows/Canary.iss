; ---------------------------------------------------------------------------
; Canary — Inno Setup installer script.
;
; Compiled by ISCC.exe, which lives in the win-build container image. The
; workflow never installs Inno Setup at run time; it is baked into the image.
;
; Every path is supplied by the caller so the same script serves x64 and ARM64:
;
;   ISCC.exe /DBuildDir=<artefacts dir> /DArch=x64 /DAppVersion=1.0.0 \
;            /DOutputDir=<where the .exe goes> Canary.iss
;
; ---------------------------------------------------------------------------

#ifndef BuildDir
  #error BuildDir must be passed with /DBuildDir=<path to Canary_artefacts/Release>
#endif

#ifndef Arch
  #error Arch must be passed with /DArch=x64 or /DArch=arm64
#endif

#ifndef AppVersion
  #error AppVersion must be passed with /DAppVersion=<version>
#endif

#ifndef OutputDir
  #define OutputDir "Output"
#endif

#define AppName      "Canary"
#define AppPublisher "EION Studios"
#define AppUrl       "https://github.com/AA-EION/runner-forge-canary"

[Setup]
AppId={{7C2F1E64-3B5A-4E2D-9C41-0A6D8B3F5E77}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
DefaultDirName={autopf}\{#AppPublisher}\{#AppName}
DefaultGroupName={#AppPublisher}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#AppName}-{#AppVersion}-windows-{#Arch}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
; ARM64 installers must not be offered to x64-only machines and vice versa.
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "full";   Description: "All formats"
Name: "custom"; Description: "Choose formats"; Flags: iscustom

[Components]
Name: "vst3";       Description: "VST3 plugin";        Types: full custom; Flags: checkablealone
Name: "clap";       Description: "CLAP plugin";        Types: full custom; Flags: checkablealone
Name: "standalone"; Description: "Standalone application"; Types: full custom; Flags: checkablealone

[Files]
; The VST3 is a directory bundle on Windows too — recursesubdirs is required or
; the installed plugin is an empty folder that hosts silently ignore.
Source: "{#BuildDir}\VST3\{#AppName}.vst3\*"; \
    DestDir: "{commoncf64}\VST3\{#AppName}.vst3"; \
    Components: vst3; Flags: ignoreversion recursesubdirs createallsubdirs

Source: "{#BuildDir}\CLAP\{#AppName}.clap"; \
    DestDir: "{commoncf64}\CLAP"; \
    Components: clap; Flags: ignoreversion

Source: "{#BuildDir}\Standalone\{#AppName}.exe"; \
    DestDir: "{app}"; \
    Components: standalone; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppName}.exe"; Components: standalone
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#AppName}.exe"; \
    Description: "Launch {#AppName}"; \
    Flags: nowait postinstall skipifsilent; \
    Components: standalone

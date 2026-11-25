; The setup program for Convert (Inno Setup 6). Built by ..\build.ps1 -Setup, which passes in:
;   AppVersion        0.4.0
;   AppDir            the folder with the built app (out\app), Convert.msix included
;   OutDir            where the setup program goes
;   DotNetVersion     the .NET Desktop Runtime to fetch when the PC has none, e.g. 10.0.15
;   DotNetSha256      the SHA-256 of Microsoft's installer for it
;   Sign              defined when the setup program and its uninstaller are to be signed (see /S in build.ps1)
;
; It installs for the current user only and never asks for administrator rights itself. The one
; exception is Microsoft's .NET installer, which asks on its own when .NET has to be installed.

#ifndef AppVersion
  #error Run ..\build.ps1 -Setup instead of compiling this file directly.
#endif

#define DotNetMajor Copy(DotNetVersion, 1, Pos(".", DotNetVersion) - 1)
#define DotNetUrl "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/" + DotNetVersion + "/windowsdesktop-runtime-" + DotNetVersion + "-win-x64.exe"

[Setup]
; Identifies Convert to Windows for upgrades and uninstalling. Never change it.
AppId={{6F0D3B52-7C1E-4E0A-9B5D-2A8C4F17E963}
AppName=Convert
AppVersion={#AppVersion}
AppVerName=Convert {#AppVersion}
AppPublisher=Convert contributors
AppPublisherURL=https://github.com/newtonstudios/convert
VersionInfoVersion={#AppVersion}
; The folder is fixed: the right-click menu entry is registered for exactly this place.
DefaultDirName={localappdata}\Programs\Convert
DisableDirPage=yes
UsePreviousAppDir=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 version 2004: the first that registers a package with an external location (the menu
; entry), and the version the app and its package are built for (Directory.Build.props, AppxManifest).
; Windows 10 shows the entry in its one right-click menu, Windows 11 at the top of its new one.
MinVersion=10.0.19041
WizardStyle=modern
SetupIconFile=..\packaging\Assets\Convert.ico
UninstallDisplayIcon={app}\Convert.exe
UninstallDisplayName=Convert
OutputDir={#OutDir}
OutputBaseFilename=Convert-{#AppVersion}-setup
Compression=lzma2/ultra64
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
#ifdef Sign
SignTool=convertsign
SignedUninstaller=yes
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Run]
Filename: "{app}\Convert.exe"; Description: "Open Convert"; Flags: postinstall nowait skipifsilent unchecked

[UninstallRun]
; Before the files go: take the entry out of the menu and end the helper that holds them open.
Filename: "{app}\Convert.exe"; Parameters: "--unregister-menu"; Flags: runhidden; RunOnceId: "ConvertMenu"

[UninstallDelete]
; The print engine's working files and the menu's error log: nothing of the user's.
Type: filesandordirs; Name: "{localappdata}\Convert\WebView2"
Type: files; Name: "{localappdata}\Convert\shell.log"
Type: files; Name: "{userprograms}\Convert.lnk"
Type: dirifempty; Name: "{localappdata}\Convert"

[Messages]
FinishedLabel=Convert is installed. Right-click a file in Explorer and choose Convert…, or open Convert from the Start menu and drop files on its window.

[Code]
var
  DownloadPage: TDownloadWizardPage;

{ The Desktop Runtime of the .NET version Convert is built for: installed for the whole PC, which is
  also where the right-click menu entry looks for it. }
function DesktopRuntimeInstalled: Boolean;
var
  Found: TFindRec;
begin
  Result := FindFirst(ExpandConstant('{commonpf64}\dotnet\shared\Microsoft.WindowsDesktop.App\{#DotNetMajor}.*'), Found);
  if Result then FindClose(Found);
end;

procedure InitializeWizard;
begin
  DownloadPage := CreateDownloadPage('Getting .NET', 'Convert needs Microsoft''s .NET {#DotNetMajor} Desktop Runtime, which this PC doesn''t have yet.', nil);
end;

{ Fetches Microsoft's installer for .NET (checked against the SHA-256 this setup was built with) and
  runs it. That installer asks for administrator rights itself. Returns '' when .NET is there afterwards. }
function InstallDesktopRuntime: String;
var
  Code: Integer;
begin
  Result := '';
  DownloadPage.Clear;
  DownloadPage.Add('{#DotNetUrl}', 'windowsdesktop-runtime.exe', '{#DotNetSha256}');
  DownloadPage.Show;
  try
    try
      DownloadPage.Download;
    except
      Result := 'Convert needs Microsoft''s .NET {#DotNetMajor} Desktop Runtime, and it couldn''t be downloaded (' + GetExceptionMessage + ').' + #13#10#13#10 +
                'Check the internet connection and run this setup again, or install the runtime yourself from https://dotnet.microsoft.com/download/dotnet/{#DotNetMajor}.0 first.';
      Exit;
    end;
    DownloadPage.SetText('Installing .NET {#DotNetMajor}', 'Windows may ask for permission.');
    if not Exec(ExpandConstant('{tmp}\windowsdesktop-runtime.exe'), '/install /quiet /norestart', '', SW_SHOW, ewWaitUntilTerminated, Code) then
      Code := -1;
  finally
    DownloadPage.Hide;
  end;
  if not DesktopRuntimeInstalled then
    Result := 'Microsoft''s .NET {#DotNetMajor} Desktop Runtime wasn''t installed (its installer ended with code ' + IntToStr(Code) + '), and Convert can''t run without it.' + #13#10#13#10 +
              'Run this setup again and allow the installation when Windows asks, or install the runtime yourself from https://dotnet.microsoft.com/download/dotnet/{#DotNetMajor}.0 first.';
end;

{ Before any file is copied. A text returned from here stops the installation and is shown. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Result := '';
  { An earlier Convert lets go of its files, so they can be replaced. Only one that came from a setup
    program knows how (it has its package next to it); a copy put there by build.ps1 -Install would
    take the option for a file to convert and open its window. }
  if FileExists(ExpandConstant('{app}\Convert.msix')) and DesktopRuntimeInstalled then
    Exec(ExpandConstant('{app}\Convert.exe'), '--unregister-menu', '', SW_HIDE, ewWaitUntilTerminated, Code);
  if not DesktopRuntimeInstalled then
    Result := InstallDesktopRuntime;
end;

{ Adds "Convert…" to Explorer's menu and makes sure it is really there. Returns 0 when it is,
  otherwise what Convert.exe --register-menu answered (3: Windows doesn't trust the signature).

  When an earlier registration is still in place (a Convert put there by build.ps1 -Install, say),
  the first call removes it, and Windows ends that very call along with the old registration. So the
  answer of --register-menu alone can't be trusted: --menu-status is asked, and the registration is
  tried again when the entry isn't there. }
function RegisterMenu: Integer;
var
  Attempt, Answer, Status: Integer;
  Started: Boolean;
  Convert: String;
begin
  Convert := ExpandConstant('{app}\Convert.exe');
  Result := 1;
  for Attempt := 1 to 10 do
  begin
    Started := Exec(Convert, '--register-menu', '', SW_HIDE, ewWaitUntilTerminated, Answer);
    if not Started then
      Log('Convert.exe couldn''t be started: ' + SysErrorMessage(Answer));
    if Exec(Convert, '--menu-status', '', SW_HIDE, ewWaitUntilTerminated, Status) and (Status = 0) then
    begin
      Log('Menu entry registered at attempt ' + IntToStr(Attempt));
      Result := 0;
      Exit;
    end;
    Log('Menu entry not registered after attempt ' + IntToStr(Attempt) + ' (answer ' + IntToStr(Answer) + ')');
    { The first attempt may have been cut short (see above). After that, 1 and 3 are Convert's own
      answers, and a refusal is a refusal. }
    if Started and (Attempt > 1) and ((Answer = 1) or (Answer = 3)) then
    begin
      Result := Answer;
      Exit;
    end;
    { While Windows is still taking the old registration apart, Convert.exe can't be started at all.
      That takes a second or two. }
    Sleep(1000);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
  Shortcut, Reason: String;
begin
  if CurStep <> ssPostInstall then Exit;
  Shortcut := ExpandConstant('{userprograms}\Convert.lnk');
  Code := RegisterMenu;
  if Code = 0 then
  begin
    { Registered, Convert is in the Start menu by itself. }
    DeleteFile(Shortcut);
    Exit;
  end;
  { Not in the menu: Convert still works when opened, so it at least gets a Start menu entry. }
  CreateShellLink(Shortcut, 'Convert', ExpandConstant('{app}\Convert.exe'), '', ExpandConstant('{app}'), '', 0, SW_SHOWNORMAL);
  if Code = 3 then
    Reason := 'Windows doesn''t trust the signature of this copy of Convert.'
  else
    Reason := 'Windows refused to register it (code ' + IntToStr(Code) + ').';
  Log('Menu registration failed: ' + Reason);
  SuppressibleMsgBox('Convert is installed, but it couldn''t be added to Explorer''s right-click menu: ' + Reason + #13#10#13#10 +
                     'You can still open Convert from the Start menu and drop files on its window.', mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Settings, Folder: String;
  Attempt: Integer;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  { Windows holds on to a few of Convert's files (its logos, for one) for a moment after the menu
    entry is gone, so their folders are still there when the uninstaller gets to them. The program
    folder is Convert's alone: what is left of it goes, a little later. }
  Folder := ExpandConstant('{app}');
  for Attempt := 1 to 10 do
  begin
    if not DirExists(Folder) then Break;
    if DelTree(Folder, True, True, True) then Break;
    Sleep(500);
  end;
  Settings := ExpandConstant('{localappdata}\Convert\settings.json');
  if FileExists(Settings) and not UninstallSilent then
    if MsgBox('Also remove your Convert settings (the formats and options you last used)?', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    begin
      DeleteFile(Settings);
      RemoveDir(ExpandConstant('{localappdata}\Convert'));
    end;
end;

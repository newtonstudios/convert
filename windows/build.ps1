<#
.SYNOPSIS
  Builds Convert for Windows and packages it as a sparse MSIX (signed only with -Install).

.DESCRIPTION
    .\build.ps1                       build into out\app and create out\Convert.msix (unsigned)
    .\build.ps1 -Install              also sign the package, install to %LOCALAPPDATA%\Programs\Convert and
                                      register the context menu ("Convert..." in Explorer's right-click menu)
    .\build.ps1 -Configuration Debug  build the Debug configuration
    .\build.ps1 -Setup -CertificateThumbprint <thumbprint> [-TimestampUrl <url>]
                                      build the setup program for a release (out\Convert-<version>-setup.exe),
                                      signed with your code-signing certificate
    .\build.ps1 -Setup -TestSign      the same, signed like -Install does it, to try the setup program on this PC
    .\build.ps1 -Setup                the same, unsigned: installs, but Windows won't add the menu entry
    .\build.ps1 -Publisher <subject>  a plain build whose package and Convert.exe name <subject> as their
                                      publisher, for files that are signed elsewhere (SignPath, see
                                      README.md) with a certificate of exactly that subject
    .\build.ps1 -SetupFrom <folder>   build the setup program from an app folder that is already built (and
                                      signed), Convert.msix included; builds and signs nothing itself

  A plain build creates no certificate or key and needs no elevation, so it is safe for CI.

  -Setup needs Inno Setup 6 (winget install JRSoftware.InnoSetup). The setup program holds the app without
  .NET; on a PC without the .NET Desktop Runtime it fetches Microsoft's installer for the version pinned
  below and checks its SHA-256 before running it. With -CertificateThumbprint the package's publisher is
  the certificate's subject, and the app's files, the package, the setup program and its uninstaller are
  all signed with it. The certificate is looked for in the current user's and the PC's personal store.

  -Install signs the package with a brand-new self-signed certificate "CN=Convert Dev" (code signing only,
  non-exportable key, valid for 30 days) and deletes its private key right after signing, so nothing can
  ever sign a second package with it. Windows then asks once (UAC) to trust that certificate on this PC
  (LocalMachine\TrustedPeople), because it only registers signed packages. Trust entries from earlier
  installs are removed in the same step. Each -Install therefore asks once.

  makeappx and signtool come from an installed Windows SDK (10.0.19041 or later) if there is one, otherwise
  from a pinned, hash-checked Microsoft.Windows.SDK.BuildTools package downloaded from nuget.org into
  tools\sdk-buildtools\.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Setup,
    [switch]$TestSign,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl,
    [string]$Publisher,
    [string]$SetupFrom,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ProgressPreference = 'SilentlyContinue'   # Windows PowerShell's download progress bar is very slow
. (Join-Path $PSScriptRoot 'packaging\Common.ps1')

# Every path is absolute: the script never changes the caller's location, and .NET's (and native tools')
# current directory is not PowerShell's location.
$Root = [IO.Path]::GetFullPath($PSScriptRoot)
$Out = Join-Path $Root 'out'
$AppOut = Join-Path $Out 'app'
$PkgDir = Join-Path $Out 'pkg'
$Msix = Join-Path $Out 'Convert.msix'

if ($SetupFrom -and ($Install -or $Setup -or $TestSign -or $CertificateThumbprint -or $TimestampUrl -or $Publisher)) {
    throw '-SetupFrom goes alone: it only packs an app folder that is already built into a setup program.'
}
if ($Publisher -and ($Install -or $Setup)) {
    throw '-Publisher goes with a plain build, for signing elsewhere: -Install and -Setup take the publisher from the certificate they sign with.'
}
# Windows compares the package's publisher with the certificate's subject letter for letter, so it is
# taken as given, only checked for being a subject at all.
if ($Publisher -and $Publisher -notmatch '(^|, )CN=[^,]') { throw "-Publisher must be a certificate subject such as `"CN=Example, O=Example, C=US`", not '$Publisher'." }
if (-not $Publisher) { $Publisher = $ConvertPublisher }

if ($Install -and $Setup) { throw 'Use -Install or -Setup, not both: -Install puts this build on this PC, -Setup makes the setup program that does that anywhere.' }
if (($TestSign -or $CertificateThumbprint -or $TimestampUrl) -and -not $Setup) { throw '-TestSign, -CertificateThumbprint and -TimestampUrl go with -Setup.' }
if ($TestSign -and $CertificateThumbprint) { throw 'Use -TestSign or -CertificateThumbprint, not both.' }
if ($TimestampUrl -and -not $CertificateThumbprint) { throw '-TimestampUrl goes with -CertificateThumbprint.' }
if ($TimestampUrl -and $TimestampUrl -notmatch '^https?://[^\s"]+$') { throw "-TimestampUrl must be an http(s) address, not '$TimestampUrl'." }

# The certificate of a release. Its subject becomes the package's publisher, which Windows compares
# with the signature letter for letter.
$ReleaseCert = $null
if ($CertificateThumbprint) {
    $wanted = ($CertificateThumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    Assert-Thumbprint $wanted
    foreach ($location in 'CurrentUser', 'LocalMachine') {
        if ($ReleaseCert) { break }
        $ReleaseCert = Get-ChildItem -LiteralPath "Cert:\$location\My" -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $wanted } | Select-Object -First 1
        $ReleaseCertLocation = $location
    }
    if (-not $ReleaseCert) { throw "No certificate with thumbprint $wanted in Cert:\CurrentUser\My or Cert:\LocalMachine\My. List yours with: Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert" }
    if (-not $ReleaseCert.HasPrivateKey) { throw "The certificate $wanted has no private key here, so it can't sign." }
    $usages = @($ReleaseCert.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
    if ($usages -notcontains $CodeSigningOid) { throw "The certificate $wanted isn't a code-signing certificate." }
    if ($ReleaseCert.NotAfter -lt (Get-Date)) { throw "The certificate $wanted expired on $($ReleaseCert.NotAfter.ToString('yyyy-MM-dd'))." }
    $Publisher = $ReleaseCert.Subject
}

# The .NET Desktop Runtime the setup program fetches from Microsoft when a PC has none. Convert runs on
# any 10.0.x, so this only decides what a PC without .NET gets. Bump it with each release:
#   1. https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json lists the latest
#      release; take the windowsdesktop file named windowsdesktop-runtime-win-x64.exe
#   2. download it, compare its SHA-512 with the one in that list, and check its signature:
#      (Get-AuthenticodeSignature <file>).SignerCertificate.Subject   -> ... O=Microsoft Corporation ...
#   3. (Get-FileHash <file> -Algorithm SHA256).Hash   -> put it below together with the version
$DesktopRuntimeVersion = '10.0.15'
$DesktopRuntimeSha256 = 'E61B030C1673EDFA3C0844502EFF83198C46AF9E7DF70DFC6E2EFC5B11EA513A'

# Microsoft.Windows.SDK.BuildTools, used when no Windows SDK is installed. To bump it:
#   1. pick a stable version from https://www.nuget.org/packages/Microsoft.Windows.SDK.BuildTools
#   2. download https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/<v>/microsoft.windows.sdk.buildtools.<v>.nupkg
#   3. dotnet nuget verify --all <file>          (must say: signed by Microsoft Corporation, verified)
#   4. (Get-FileHash <file> -Algorithm SHA256).Hash   -> put it below together with the version
$SdkBuildToolsVersion = '10.0.28000.2957'
$SdkBuildToolsSha256 = 'B7163FC6F636172726D0985963E4F7F11C41AFE1C7FDFE78F8051877360ED696'
$MinSdkVersion = [version]'10.0.19041.0'

# --- helpers -----------------------------------------------------------------------------------------

# One argument quoted for CommandLineToArgvW-style parsing.
function ConvertTo-NativeArg([string]$Arg) {
    if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object Text.StringBuilder '"'
    $backslashes = 0
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq '\') { $backslashes++; continue }
        if ($c -eq '"') { [void]$sb.Append('\', $backslashes * 2 + 1).Append('"') }
        else { [void]$sb.Append('\', $backslashes).Append($c) }
        $backslashes = 0
    }
    return $sb.Append('\', $backslashes * 2).Append('"').ToString()
}

# Runs a program, waits for it (also for GUI-subsystem programs) and captures its output.
function Invoke-Native([string]$Exe, [string[]]$Arguments, [int]$TimeoutSeconds = 600) {
    $psi = New-Object Diagnostics.ProcessStartInfo $Exe
    $psi.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $Root
    $p = [Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { }
        throw "$([IO.Path]::GetFileName($Exe)) didn't finish within $TimeoutSeconds seconds and was stopped."
    }
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $stdout.Result; Error = $stderr.Result }
}

function Test-FileSha256([string]$Path, [string]$Expected) {
    if (-not [IO.File]::Exists($Path)) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected
}

function Test-MicrosoftSigned([string]$Path) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    return $sig.Status -eq 'Valid' -and $sig.SignerCertificate -and $sig.SignerCertificate.Subject -match '(^|, )O=Microsoft Corporation(,|$)'
}

# --- tools -------------------------------------------------------------------------------------------

function Find-Dotnet {
    $cmd = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'dotnet\dotnet.exe'
    if ([IO.File]::Exists($candidate)) { return $candidate }
    throw ".NET SDK not found. Install the .NET 10 SDK (winget install Microsoft.DotNet.SDK.10), open a new PowerShell window and run this again."
}

# makeappx.exe and signtool.exe: from an installed Windows SDK if there is a recent enough one,
# otherwise from the pinned NuGet package.
function Get-SdkTools {
    $pf86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    if ($pf86) {
        $kits = Join-Path $pf86 'Windows Kits\10\bin'
        $candidates = @(Get-ChildItem -LiteralPath $kits -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' -and [version]$_.Name -ge $MinSdkVersion } |
            Sort-Object { [version]$_.Name } -Descending)
        foreach ($c in $candidates) {
            $makeappx = Join-Path $c.FullName 'x64\makeappx.exe'
            $signtool = Join-Path $c.FullName 'x64\signtool.exe'
            if ([IO.File]::Exists($makeappx) -and [IO.File]::Exists($signtool)) {
                if ((Test-MicrosoftSigned $makeappx) -and (Test-MicrosoftSigned $signtool)) {
                    return [pscustomobject]@{ MakeAppx = $makeappx; SignTool = $signtool; Source = "Windows SDK $($c.Name)" }
                }
                Write-Warning "Ignoring the Windows SDK tools in $($c.FullName): they don't carry a valid Microsoft signature."
            }
        }
    }

    $legacy = Join-Path $Root 'tools\sdk'
    if ([IO.Directory]::Exists($legacy)) { Write-Note "tools\sdk (left by an older build.ps1) is no longer used; you can delete it." }

    # The cache is the .nupkg itself, checked against the pinned SHA-256 on every run. The tools are
    # unpacked from it into out\ (rebuilt every time), so a stale or modified unpacked copy is never used.
    $cache = Join-Path $Root "tools\sdk-buildtools\$SdkBuildToolsVersion"
    $nupkg = Join-Path $cache "microsoft.windows.sdk.buildtools.$SdkBuildToolsVersion.nupkg"
    if (-not (Test-FileSha256 $nupkg $SdkBuildToolsSha256)) {
        if ([IO.File]::Exists($nupkg)) { Write-Warning "$nupkg doesn't match the pinned SHA-256; downloading it again." }
        Write-Step "Downloading Windows SDK build tools $SdkBuildToolsVersion (makeappx, signtool) from nuget.org"
        [void][IO.Directory]::CreateDirectory($cache)
        $tmp = "$nupkg.download"
        $url = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/$SdkBuildToolsVersion/microsoft.windows.sdk.buildtools.$SdkBuildToolsVersion.nupkg"
        if ($PSVersionTable.PSEdition -ne 'Core' -and [Net.ServicePointManager]::SecurityProtocol -ne [Net.SecurityProtocolType]::SystemDefault) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing }
        catch {
            throw "Couldn't download $url ($($_.Exception.Message)). Check the internet connection, or install the Windows SDK (winget install Microsoft.WindowsSDK.10.0.26100) so the download isn't needed."
        }
        $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
        if ($hash -ne $SdkBuildToolsSha256) {
            Remove-Item -LiteralPath $tmp -Force
            throw "The downloaded build tools package has SHA-256 $hash, but $SdkBuildToolsSha256 is pinned in build.ps1. It was deleted and not used."
        }
        Move-Item -LiteralPath $tmp -Destination $nupkg -Force
    }

    $dest = Join-Path $Out 'sdk-tools'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
    try {
        $tool = $zip.Entries | Where-Object { $_.FullName -match '^bin/[^/]+/x64/makeappx\.exe$' } | Select-Object -First 1
        if (-not $tool) { throw "makeappx.exe not found in $nupkg." }
        $prefix = $tool.FullName.Substring(0, $tool.FullName.Length - 'makeappx.exe'.Length)
        foreach ($e in $zip.Entries) {
            if (-not $e.FullName.StartsWith($prefix) -or $e.FullName.EndsWith('/')) { continue }
            $rel = $e.FullName.Substring($prefix.Length)
            if ($rel -match '(^|/)\.\.(/|$)' -or $rel -match ':') { throw "Unexpected entry $($e.FullName) in $nupkg." }
            $target = Join-Path $dest ($rel -replace '/', '\')
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $zip.Dispose() }
    return [pscustomobject]@{
        MakeAppx = Join-Path $dest 'makeappx.exe'
        SignTool = Join-Path $dest 'signtool.exe'
        Source = "Microsoft.Windows.SDK.BuildTools $SdkBuildToolsVersion (SHA-256 verified)"
    }
}

# <Version> in Directory.Build.props, as MSBuild evaluates it for Convert.exe.
function Get-AppVersion {
    $r = Invoke-Native $dotnet @('msbuild', (Join-Path $Root 'src\Convert\Convert.csproj'), '-getProperty:Version', '-nologo')
    $v = $r.Output.Trim()
    if ($r.ExitCode -ne 0 -or $v -notmatch '^(\d+)\.(\d+)\.(\d+)(\.(\d+))?$') {
        throw "Couldn't read the version from Directory.Build.props (got '$v'$(if ($r.Error) { ": $($r.Error.Trim())" })). It must look like 1.2.3."
    }
    return $v
}

# --- setup program -----------------------------------------------------------------------------------

# Signs files with the certificate in use: $SignArguments is everything signtool needs before the file names.
function Invoke-Sign([string[]]$Files) {
    $r = Invoke-Native $sdk.SignTool (@($SignArguments) + $Files)
    if ($r.ExitCode -ne 0) { throw "signtool failed (exit code $($r.ExitCode)):`n$($r.Output)$($r.Error)" }
}

function Find-InnoSetup {
    $candidates = @(
        (Join-Path (Get-LocalAppDataDir) 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)) 'Inno Setup 6\ISCC.exe'),
        (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'Inno Setup 6\ISCC.exe'))
    foreach ($c in $candidates) { if ([IO.File]::Exists($c)) { return $c } }
    $cmd = Get-Command ISCC -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    throw 'Inno Setup 6 not found. Install it (winget install JRSoftware.InnoSetup) and run this again.'
}

# Builds out\Convert-<version>-setup.exe from $AppOut. Signs what it makes when a certificate is in use.
# With -SetupFrom, $AppOut is that folder and already holds its (signed) Convert.msix.
function New-SetupProgram {
    $iscc = Find-InnoSetup
    Write-Step 'Building the setup program'
    if ($SignArguments) {
        # Our own programs; the libraries Convert uses carry their makers' signatures.
        Invoke-Sign @('Convert.exe', 'Convert.dll', 'Convert.Core.dll', 'Convert.Shell.dll', 'Convert.Shell.comhost.dll' | ForEach-Object { Join-Path $AppOut $_ })
    }
    # The package travels with the app: Convert.exe --register-menu registers the one next to it.
    if (-not $SetupFrom) { Copy-Item -LiteralPath $Msix -Destination (Join-Path $AppOut 'Convert.msix') -Force }
    $isccArgs = @("/DAppVersion=$version", "/DAppDir=$AppOut", "/DOutDir=$Out",
        "/DDotNetVersion=$DesktopRuntimeVersion", "/DDotNetSha256=$($DesktopRuntimeSha256.ToLowerInvariant())", '/Qp')
    if ($SignArguments) {
        # Inno Setup signs the uninstaller and the setup program itself with this command ($q is a quote, $f the file).
        $isccArgs += '/DSign'
        $isccArgs += '/Sconvertsign=$q' + $sdk.SignTool + '$q ' + (($SignArguments | ForEach-Object { if ($_ -match '\s') { '$q' + $_ + '$q' } else { $_ } }) -join ' ') + ' $f'
    }
    $isccArgs += (Join-Path $Root 'installer\Convert.iss')
    $r = Invoke-Native $iscc $isccArgs -TimeoutSeconds 1800
    if ($r.ExitCode -ne 0) { throw "Inno Setup failed (exit code $($r.ExitCode)):`n$($r.Output)$($r.Error)" }
    $setup = Join-Path $Out "Convert-$version-setup.exe"
    if (-not [IO.File]::Exists($setup)) { throw "Inno Setup reported success, but $setup isn't there.`n$($r.Output)" }
    return $setup
}

$SignArguments = $null

# --- setup program from a finished app folder (-SetupFrom) -------------------------------------------

# The second half of a release signed elsewhere: build.ps1 -Publisher made out\app and the package, the
# app's files and the package were signed, and the signed files are back in one folder. The setup
# program made here is unsigned; it is signed elsewhere in turn.
if ($SetupFrom) {
    $dotnet = Find-Dotnet
    $AppOut = [IO.Path]::GetFullPath($SetupFrom).TrimEnd('\')
    foreach ($f in 'Convert.exe', 'Convert.Shell.comhost.dll', 'Convert.msix') {
        if (-not [IO.File]::Exists((Join-Path $AppOut $f))) { throw "$f isn't in $AppOut. -SetupFrom needs a whole app folder (out\app of build.ps1) with the package in it." }
    }
    # Without a signature Windows refuses the package; the setup program would install, but without the menu entry.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $AppOut 'Convert.msix'))
    try { $signed = [bool]($zip.Entries | Where-Object { $_.FullName -eq 'AppxSignature.p7x' }) } finally { $zip.Dispose() }
    if (-not $signed) { Write-Warning "$AppOut\Convert.msix isn't signed: the setup program installs Convert, but Windows won't add the menu entry." }
    $version = Get-AppVersion
    [void][IO.Directory]::CreateDirectory($Out)
    $SetupProgram = New-SetupProgram
    Write-Host ''
    Write-Host ("Built {0} ({1:N1} MB, unsigned)" -f $SetupProgram, ((Get-Item -LiteralPath $SetupProgram).Length / 1MB)) -ForegroundColor Green
    Write-Host "SHA-256: $((Get-FileHash -LiteralPath $SetupProgram -Algorithm SHA256).Hash)"
    return
}

# --- build -------------------------------------------------------------------------------------------

$dotnet = Find-Dotnet
# dotnet publish fails with MSB3094 when the project path contains an apostrophe; ; and % are MSBuild
# special characters as well. (Spaces, parentheses and & are fine.)
if ($Root -match "[';%]") {
    throw "The .NET build tools can't build in a folder whose path contains ' ; or % ($Root). Move or clone the repository to a path without them and run build.ps1 from there."
}

Write-Step "Building ($Configuration)"
if (-not (Remove-DirectorySafely -Path $Out -Parent $Root -Attempts 6)) {
    throw "Couldn't empty $Out (files in use). Close any Convert window started from out\app and try again."
}

# Convert.exe names the package it belongs to in its manifest (the <msix> element), publisher included.
# For a release that is the certificate's subject, so the app is built with a copy that says so.
$AppManifest = Join-Path $Root 'src\Convert\app.manifest'
$manifestArgs = @()
if ($Publisher -ne $ConvertPublisher) {
    $stamped = New-Object Xml.XmlDocument
    $stamped.PreserveWhitespace = $true
    $stamped.Load($AppManifest)
    $node = $stamped.SelectSingleNode("//*[local-name()='msix']")
    if (-not $node) { throw "src\Convert\app.manifest has no <msix> element to put the publisher in." }
    $node.SetAttribute('publisher', $Publisher)
    [void][IO.Directory]::CreateDirectory($Out)
    $AppManifest = Join-Path $Out 'app.manifest'
    $stamped.Save($AppManifest)
    $manifestArgs = @("-p:ApplicationManifest=$AppManifest")
}

& $dotnet publish (Join-Path $Root 'src\Convert\Convert.csproj') -c $Configuration -o $AppOut --nologo -v quiet @manifestArgs
if ($LASTEXITCODE) { throw "Building src\Convert\Convert.csproj failed (exit code $LASTEXITCODE); see the errors above." }
& $dotnet publish (Join-Path $Root 'src\Convert.Shell\Convert.Shell.csproj') -c $Configuration -o $AppOut --nologo -v quiet
if ($LASTEXITCODE) { throw "Building src\Convert.Shell\Convert.Shell.csproj failed (exit code $LASTEXITCODE); see the errors above." }
Copy-Item -LiteralPath (Join-Path $Root 'packaging\Assets') -Destination (Join-Path $AppOut 'Assets') -Recurse

# A bundled ffmpeg (windows\tools\ffmpeg\ffmpeg.exe + ffprobe.exe) is shipped in tools\ next to Convert.exe.
$bundled = Join-Path $Root 'tools\ffmpeg'
if ([IO.File]::Exists((Join-Path $bundled 'ffmpeg.exe'))) {
    Write-Step 'Bundling ffmpeg'
    $toolsOut = Join-Path $AppOut 'tools'
    [void][IO.Directory]::CreateDirectory($toolsOut)
    Get-ChildItem -LiteralPath $bundled -Filter *.exe -File | Copy-Item -Destination $toolsOut
}

# --- package manifest --------------------------------------------------------------------------------

Write-Step 'Writing package manifest'

# Convert.exe is a GUI-subsystem program: run it with captured output so we wait for it, and fail loudly
# on anything unexpected (an empty or partial list would silently drop file types from the menu).
$exe = Join-Path $AppOut 'Convert.exe'
$r = Invoke-Native $exe @('--list-extensions') -TimeoutSeconds 120
$extensions = @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$bad = @($extensions | Where-Object { $_ -notmatch '^[a-z0-9]+$' })
if ($r.ExitCode -ne 0 -or $extensions.Count -eq 0 -or $bad.Count -gt 0) {
    throw ("`"$exe --list-extensions`" didn't produce a clean list of file extensions (exit code $($r.ExitCode), " +
        "$($extensions.Count) lines, unexpected: $($bad -join ' ')).`n$($r.Output)$($r.Error)" +
        "`nRun it yourself to see what's wrong: & '$exe' --list-extensions | Out-String")
}
if (@($extensions | Select-Object -Unique).Count -ne $extensions.Count) { throw "Convert.exe --list-extensions listed an extension twice." }

# The package version follows <Version> in Directory.Build.props (as MSBuild evaluates it for Convert.exe).
$version = Get-AppVersion
$parts = @($version.Split('.') | ForEach-Object { [int]$_ })
while ($parts.Count -lt 4) { $parts += 0 }
if (@($parts | Where-Object { $_ -gt 65535 }).Count) { throw "Version $version can't be a package version (each part must be at most 65535)." }
$packageVersion = $parts -join '.'

# Package identity must match the <msix> element in app.manifest, or Convert.exe runs without it.
[xml]$appManifestXml = [IO.File]::ReadAllText($AppManifest)
$msixNode = $appManifestXml.SelectSingleNode("//*[local-name()='msix']")
if (-not $msixNode -or $msixNode.GetAttribute('publisher') -ne $Publisher -or $msixNode.GetAttribute('packageName') -ne $ConvertPackageName) {
    throw "$AppManifest's <msix> element must have publisher=`"$Publisher`" and packageName=`"$ConvertPackageName`"."
}

$itemTypes = ($extensions | ForEach-Object {
    "            <desktop5:ItemType Type=`".$_`"><desktop5:Verb Id=`"Convert`" Clsid=`"5E2B8C34-9A71-4D6F-B0E3-2C8F41A7D965`" /></desktop5:ItemType>"
}) -join "`r`n"
$manifest = [IO.File]::ReadAllText((Join-Path $Root 'packaging\AppxManifest.template.xml')).
    Replace('{{VERSION}}', $packageVersion).
    Replace('{{PUBLISHER}}', [Security.SecurityElement]::Escape($Publisher)).
    Replace('{{ITEMTYPES}}', $itemTypes)
if ($manifest -match '\{\{\w+\}\}') { throw "packaging\AppxManifest.template.xml has a placeholder build.ps1 doesn't fill: $($Matches[0])" }
try { (New-Object Xml.XmlDocument).LoadXml($manifest) }
catch { throw "The package manifest made from packaging\AppxManifest.template.xml isn't valid XML: $($_.Exception.InnerException.Message)" }
[void][IO.Directory]::CreateDirectory($PkgDir)
[IO.File]::WriteAllText((Join-Path $PkgDir 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding $false))
Copy-Item -LiteralPath (Join-Path $Root 'packaging\Assets') -Destination (Join-Path $PkgDir 'Assets') -Recurse
Write-Note "Version $packageVersion, $($extensions.Count) file types"

$sdk = Get-SdkTools
Write-Step "Packing $Msix"
Write-Note "Tools: $($sdk.Source)"
# The real package is packed with /nv because the files it names live outside it. Check the manifest
# against the schema first, in a throwaway package that also holds the files the manifest names.
$check = Join-Path $Out 'manifest-check'
Copy-Item -LiteralPath $PkgDir -Destination $check -Recurse
Copy-Item -LiteralPath (Join-Path $AppOut 'Convert.exe'), (Join-Path $AppOut 'Convert.Shell.comhost.dll') -Destination $check
$r = Invoke-Native $sdk.MakeAppx @('pack', '/o', '/d', $check, '/p', "$check.msix")
if ($r.ExitCode -ne 0) { throw "The package manifest doesn't pass validation:`n$(($r.Output + $r.Error) -split "`r?`n" | Where-Object { $_ -match 'error' } | Out-String)" }
[void](Remove-DirectorySafely -Path $check -Parent $Out)
Remove-Item -LiteralPath "$check.msix" -Force
# /nv: the manifest names Convert.exe, which lives in the external location, not in the package.
$r = Invoke-Native $sdk.MakeAppx @('pack', '/o', '/nv', '/d', $PkgDir, '/p', $Msix)
if ($r.ExitCode -ne 0) { throw "makeappx failed (exit code $($r.ExitCode)):`n$($r.Output)$($r.Error)" }

if (-not $Install -and -not $Setup) {
    Write-Host ''
    Write-Host "Built $Msix (unsigned: no certificate was created or used)." -ForegroundColor Green
    if ($Publisher -ne $ConvertPublisher) {
        Write-Host "Its publisher is $Publisher. Sign it and the app's own files in out\app with the certificate of exactly"
        Write-Host 'that subject, put the signed Convert.msix into out\app, and run .\build.ps1 -SetupFrom out\app.'
    } else {
        Write-Host 'Run .\build.ps1 -Install to sign it, install Convert and add it to the context menu.'
    }
    return
}

# --- signing (with -Install, and with -Setup when asked for) -----------------------------------------

$SetupProgram = $null
$singleUse = $Install -or $TestSign

if ($ReleaseCert) {
    Write-Step "Signing as $Publisher"
    $SignArguments = @('sign', '/fd', 'SHA256', '/sha1', $ReleaseCert.Thumbprint, '/s', 'My')
    if ($ReleaseCertLocation -eq 'LocalMachine') { $SignArguments += '/sm' }
    if ($TimestampUrl) { $SignArguments += @('/tr', $TimestampUrl, '/td', 'SHA256') }
    else { Write-Warning 'No -TimestampUrl given: the signatures stop counting on the day the certificate expires. Releases should be timestamped.' }
    Invoke-Sign @($Msix)
    $SetupProgram = New-SetupProgram
}
elseif (-not $singleUse) {
    Write-Warning 'Building an unsigned setup program: it installs Convert, but Windows refuses to add the right-click menu entry of an unsigned package. Use -TestSign to try the real thing on this PC.'
    $SetupProgram = New-SetupProgram
}

$InstallDir = Get-ConvertInstallDir
$thumbprint = $null
$certBase64 = $null

if ($singleUse) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Warning "This PowerShell runs as administrator. Convert is installed for the account running the script; if that isn't your normal account, cancel (Ctrl+C) and run this from a normal PowerShell window."
    }

    # Keys from earlier installs (older build.ps1 versions kept an exportable one in CurrentUser\My for
    # years). They're never used again, so they go now, whatever happens next.
    foreach ($storeName in 'My', 'CA') {
        foreach ($old in @(Get-ConvertDevCerts 'CurrentUser' $storeName)) {
            $left = Remove-UserCert -StoreName $storeName -Thumbprint $old.Thumbprint
            if ($left -match 'key') { throw "Couldn't delete an old signing key: $left. Delete it in certmgr.msc (Personal, `"CN=Convert Dev`") and try again." }
            if ($left) { Write-Warning "Couldn't delete $left; .\uninstall.ps1 removes it." }
            else { Write-Note "Deleted an old signing certificate$(if ($old.HasPrivateKey) { ' and its key' }) from CurrentUser\$storeName ($($old.Thumbprint))" }
        }
    }

    Write-Step "Signing with a new single-use certificate $Publisher"
    $new = New-SelfSignedCertificate -Type Custom -Subject $Publisher -KeyUsage DigitalSignature `
        -TextExtension @("2.5.29.37={text}$CodeSigningOid", '2.5.29.19={text}') `
        -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable `
        -Provider 'Microsoft Software Key Storage Provider' -NotAfter (Get-Date).AddDays(30) `
        -FriendlyName 'Convert package signing (single use)' -CertStoreLocation Cert:\CurrentUser\My
    $thumbprint = $new.Thumbprint
    Assert-Thumbprint $thumbprint
    $keyInfo = $null
    try {
        $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint"
        $keyInfo = Get-PrivateKeyInfo $cert
        $certBase64 = [Convert]::ToBase64String($cert.RawData)   # public part only
        $SignArguments = @('sign', '/fd', 'SHA256', '/sha1', $thumbprint, '/s', 'My')
        Invoke-Sign @($Msix)
        # The setup program is made while the key still exists, so it and its uninstaller are signed too.
        if ($Setup) { $SetupProgram = New-SetupProgram }
    } finally {
        # The private key exists only for as long as signing takes. New-SelfSignedCertificate also puts a
        # copy of the certificate in CurrentUser\CA.
        $leftovers = @(@('My', 'CA') | ForEach-Object { Remove-UserCert -StoreName $_ -Thumbprint $thumbprint } | Where-Object { $_ })
        if ($leftovers.Count) { Write-Warning "Not everything of the signing certificate could be deleted: $($leftovers -join '; '). Run .\uninstall.ps1 to remove it." }
    }
    if (-not $keyInfo -or $keyInfo.Kind -eq 'unknown' -or (Test-PrivateKeyExists $keyInfo)) {
        throw 'Stopped before trusting the certificate, because its private key may still exist. Nothing was installed. Run .\uninstall.ps1, then try again.'
    }
    Write-Note "Signed; the private key is deleted (certificate $thumbprint, valid until $((Get-Date).AddDays(30).ToString('yyyy-MM-dd')))"
}

if ($SetupProgram) {
    $size = (Get-Item -LiteralPath $SetupProgram).Length
    Write-Host ''
    Write-Host ("Built {0} ({1:N1} MB)" -f $SetupProgram, ($size / 1MB)) -ForegroundColor Green
    Write-Host "SHA-256: $((Get-FileHash -LiteralPath $SetupProgram -Algorithm SHA256).Hash)"
}
if (-not $singleUse) { return }

# --- trust (one UAC prompt) --------------------------------------------------------------------------

if ($Setup) { Write-Note 'A setup program signed with -TestSign only works on this PC, and only once the certificate is trusted here:' }
$stale = @(Get-ConvertDevCerts 'LocalMachine' 'TrustedPeople' | Where-Object { $_.Thumbprint -ne $thumbprint } | ForEach-Object { $_.Thumbprint })
Write-Step 'Trusting the new certificate on this PC (Windows asks for permission)'
if ($stale.Count) { Write-Note "Also removing $($stale.Count) trust entr$(if ($stale.Count -eq 1) { 'y' } else { 'ies' }) from earlier installs: $($stale -join ', ')" }
$result = Invoke-ElevatedPowerShell (New-TrustStoreScript -AddBase64 @($certBase64) -RemoveThumbprints $stale)
if (-not $result.Started) {
    if ($result.Cancelled) {
        throw "You declined the Windows permission prompt, so nothing was installed or changed (an installed Convert, if any, is untouched; the new signing key is already deleted). Run the same command again and choose Yes."
    }
    throw "Couldn't start the elevated step: $($result.Message)"
}
if ($result.ExitCode -ne 0) { throw "Trusting the certificate failed (exit code $($result.ExitCode)). Nothing was installed." }
$trusted = @(Get-ConvertDevCerts 'LocalMachine' 'TrustedPeople' | ForEach-Object { $_.Thumbprint })
if ($trusted -notcontains $thumbprint) { throw "The certificate isn't in LocalMachine\TrustedPeople after the elevated step. Nothing was installed." }
$stillStale = @($stale | Where-Object { $trusted -contains $_ })
if ($stillStale.Count) { Write-Warning "Old trust entries still present: $($stillStale -join ', '). .\uninstall.ps1 removes them." }

if (-not $Install) {
    Write-Host ''
    Write-Host "The test certificate is trusted on this PC. Try the setup program: $SetupProgram" -ForegroundColor Green
    Write-Host 'Uninstall from Settings > Apps afterwards; .\uninstall.ps1 removes the trust entry.'
    return
}

# --- install -----------------------------------------------------------------------------------------

Write-Step "Installing to $InstallDir"
Stop-ProcessesUsingDir $InstallDir
foreach ($old in @(Get-ConvertPackage)) {
    Remove-AppxPackage -Package $old.PackageFullName
    Write-Note "Removed the previous package $($old.PackageFullName)"
}
# dllhost may still hold the old context-menu DLL for a moment after the package is removed.
Stop-ProcessesUsingDir $InstallDir
if (-not (Remove-DirectorySafely -Path $InstallDir -Parent (Get-LocalAppDataDir) -Attempts 20)) {
    throw "Couldn't replace $InstallDir (files in use). Close Convert and all Explorer windows (or sign out and back in) and run .\build.ps1 -Install again."
}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($InstallDir))
Copy-Item -LiteralPath $AppOut -Destination $InstallDir -Recurse

Write-Step 'Registering the context menu'
Import-AppxModule
try { Add-AppxPackage -Path $Msix -ExternalLocation $InstallDir -ErrorAction Stop }
catch {
    throw "Registering the package failed: $($_.Exception.Message)`nThe program files are in $InstallDir; .\uninstall.ps1 removes them and the certificate."
}
$pkg = @(Get-ConvertPackage) | Select-Object -First 1
if (-not $pkg) { throw 'Add-AppxPackage reported success, but the Convert package is not registered.' }
if ("$($pkg.Version)" -ne $packageVersion) { Write-Warning "Registered version is $($pkg.Version), expected $packageVersion." }
try {
    $registered = @((Get-AppxPackageManifest -Package $pkg.PackageFullName).SelectNodes("//*[local-name()='ItemType']")).Count
    if ($registered -ne $extensions.Count) { Write-Warning "The registered package lists $registered file types, expected $($extensions.Count)." }
} catch { }
Write-Host ''
Write-Host "Installed Convert $($pkg.Version) for $($extensions.Count) file types. Right-click a file in Explorer -> Convert..." -ForegroundColor Green

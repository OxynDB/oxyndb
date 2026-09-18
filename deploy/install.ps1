# SPDX-License-Identifier: Apache-2.0
#
# OxynDB Windows installer: one command, from a machine with nothing on it to
# a running database. Installs WSL if absent (no Linux distribution required),
# installs the odb launcher, and runs `odb setup`.
#
# Usage (PowerShell):
#   irm https://raw.githubusercontent.com/OxynDB/oxyndb/main/deploy/install.ps1 | iex
#
# This file must stay free of a UTF-8 BOM: `irm | iex` pipes the BOM into the
# parser, which then reports `The term '# ' is not recognized` on line 1.
#
# Every OxynDB download is checked against the release's SHA256SUMS before it
# is kept -- these files run as root inside the distro. Anything that cannot be
# verified stops the install (ODB_NO_VERIFY=1 deliberately skips the check).
#
# Env overrides: ODB_VERSION (default "latest"), ODB_REPO, ODB_PREFIX,
# ODB_NO_SETUP (skip `odb setup`), ODB_NO_ELEVATE (never prompt for admin),
# ODB_NO_VERIFY (skip checksum verification).

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not negotiate TLS 1.2 by default, and GitHub
# requires it -- without this, downloads fail with "the connection was closed
# unexpectedly" partway through.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Repo    = if ($env:ODB_REPO)    { $env:ODB_REPO }    else { 'OxynDB/oxyndb' }
$Version = if ($env:ODB_VERSION) { $env:ODB_VERSION } else { 'latest' }
$Prefix  = if ($env:ODB_PREFIX)  { $env:ODB_PREFIX }  else { "$env:LOCALAPPDATA\Programs\oxyndb" }

# Ubuntu publishes WSL rootfs tarballs directly; pulling from upstream keeps our
# own release small and avoids redistributing Ubuntu. Note the path: only
# /wsl/releases/<series>/current/ carries the tarballs -- /wsl/<series>/current/
# holds manifests alone.
$RootfsBase = 'https://cloud-images.ubuntu.com/wsl/releases/noble/current'
$RootfsName = 'ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'
$RootfsUrl  = if ($env:ODB_ROOTFS_URL) { $env:ODB_ROOTFS_URL } else { "$RootfsBase/$RootfsName" }

$script:Step = 0
$script:Steps = 5

function Write-Step([string]$Message) {
    $script:Step++
    Write-Host ("  [{0}/{1}] {2}" -f $script:Step, $script:Steps, $Message)
}

# Resolve-Arch maps the OS architecture to our release-asset arch token.
function Resolve-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'amd64' }
        'ARM64' { 'arm64' }
        default { 'amd64' }
    }
}

# Get-OdbAsset builds the download URL for a named release asset.
function Get-OdbAsset([string]$Name) {
    if ($Version -eq 'latest') {
        "https://github.com/$Repo/releases/latest/download/$Name"
    } else {
        "https://github.com/$Repo/releases/download/$Version/$Name"
    }
}

# Test-Admin reports whether this process is elevated.
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Test-WslReady reports whether WSL is installed and healthy enough to import a
# distro. `wsl --status` fails when the platform is present but not enabled.
function Test-WslReady {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    try {
        & wsl.exe --status *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

# Test-RebootPending reports whether Windows is waiting on a restart. Enabling
# the WSL optional components sets this on a machine that had them off.
function Test-RebootPending {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    return $false
}

# Register-Resume arranges for this installer to run again after a reboot, so a
# machine that needed WSL enabled finishes on its own. It is a convenience, never
# the only path: re-running the one-liner by hand always works.
function Register-Resume {
    # RunOnce fires early at logon, typically before networking is up, so the
    # resumed command waits for the download host to answer before starting.
    # Without the wait it fails immediately on `irm` and the user sees only a
    # stray error window -- which is what happened on the first real machine
    # this was tried on.
    $url = 'https://raw.githubusercontent.com/OxynDB/oxyndb/main/deploy/install.ps1'
    $cmd = "for (`$i=0; `$i -lt 60; `$i++) { " +
           "if (Test-Connection -ComputerName raw.githubusercontent.com -Count 1 -Quiet) { break }; " +
           "Start-Sleep -Seconds 5 }; irm $url | iex"
    $run = "powershell -NoExit -NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
    try {
        New-ItemProperty -Force -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
            -Name 'OxynDBInstall' -Value $run -PropertyType String | Out-Null
        return $true
    } catch { return $false }
}

# Install-Wsl enables WSL without a Linux distribution.
#
# --no-distribution matters: OxynDB imports its own dedicated distro, so an
# Ubuntu install is a pure waste of the user's time and disk. Requires admin, so
# this re-launches elevated and waits.
function Install-Wsl {
    if ($env:ODB_NO_ELEVATE) {
        throw "WSL is not installed. Run this in an Administrator PowerShell, then re-run the installer:`n" +
              "    wsl --install --no-distribution"
    }
    Write-Host "  OxynDB needs WSL. Windows will ask for permission to install it."
    $wslArgs = @('--install', '--no-distribution')
    if (Test-Admin) {
        & wsl.exe --install --no-distribution 2>&1 | Out-String | Write-Verbose
    } else {
        $p = Start-Process -FilePath 'wsl.exe' -ArgumentList $wslArgs -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            throw "installing WSL failed (exit $($p.ExitCode)). Run 'wsl --install --no-distribution' in an Administrator PowerShell."
        }
    }
    try { & wsl.exe --update *> $null } catch { }
}

function Get-File([string]$Url, [string]$Dest, [bool]$Required = $true) {
    try {
        # Progress rendering dominates the runtime of a large download in
        # Windows PowerShell; suppressing it is worth several minutes on the
        # rootfs.
        $prev = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Dest }
        finally { $ProgressPreference = $prev }
        return $true
    } catch {
        if ($Required) { throw "download failed: $Url`n$($_.Exception.Message)" }
        Write-Warning "optional asset not in this release yet: $Url"
        return $false
    }
}

# Get-UpstreamChecksum returns the expected SHA256 for $Name from a publisher's
# SHA256SUMS listing, or $null if the listing can't be fetched or doesn't name
# the file. Callers decide what an unknown checksum means.
function Get-UpstreamChecksum([string]$SumsUrl, [string]$Name) {
    try {
        $body = (Invoke-WebRequest -UseBasicParsing -Uri $SumsUrl).Content
    } catch {
        Write-Warning "could not fetch $SumsUrl"
        return $null
    }
    # Windows PowerShell hands back a byte[] when the response isn't typed as
    # text; PowerShell 7 hands back a string. Normalize before splitting.
    $sums = if ($body -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($body) } else { [string]$body }
    # Lines look like: "<sha256>  *ubuntu-...rootfs.tar.gz" (or two spaces).
    foreach ($line in ($sums -split "`n")) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $Name) {
            return $Matches[1].ToLower()
        }
    }
    Write-Warning "$Name not listed in SHA256SUMS"
    return $null
}

# Test-UpstreamChecksum reports whether a staged file still matches the
# publisher's listing. An unverifiable file is not reusable, so anything other
# than a positive match is $false.
function Test-UpstreamChecksum([string]$Path, [string]$SumsUrl, [string]$Name) {
    $want = Get-UpstreamChecksum $SumsUrl $Name
    if (-not $want) { return $false }
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower() -eq $want
}

# Assert-UpstreamChecksum verifies a download against the publisher's listing.
# Ubuntu's rootfs is a ~340 MB third-party download that becomes the root
# filesystem of a distro, so it is worth checking. A listing we cannot reach is
# a warning, not a failure -- the download itself already came over TLS.
function Assert-UpstreamChecksum([string]$Path, [string]$SumsUrl, [string]$Name) {
    $want = Get-UpstreamChecksum $SumsUrl $Name
    if (-not $want) {
        Write-Warning "skipping checksum verification for $Name"
        return
    }
    $got = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
    if ($got -ne $want) {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
        throw "checksum mismatch for $Name`n  expected $want`n  got      $got"
    }
}

# --- OxynDB's own releases ----------------------------------------------
# Every release publishes SHA256SUMS beside its assets. It travels over the same
# TLS connection as the files, so it proves integrity (a complete, unaltered
# download), not authorship -- signatures would be needed for that. The files
# below are executed as root inside the distro, so an unverifiable one is not
# installed. ODB_NO_VERIFY=1 skips the check deliberately.
$script:OdbSums = $null

function Get-OdbSums {
    if ($env:ODB_NO_VERIFY -eq '1') { return $null }
    if ($null -ne $script:OdbSums) { return $script:OdbSums }
    try {
        $body = (Invoke-WebRequest -UseBasicParsing -Uri (Get-OdbAsset 'SHA256SUMS')).Content
    } catch {
        throw "could not fetch SHA256SUMS for $Version -- nothing was installed.`nRetry, or set ODB_NO_VERIFY=1 to install without checking (not recommended)."
    }
    $script:OdbSums = if ($body -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($body) } else { [string]$body }
    return $script:OdbSums
}

# Get-OdbChecksum returns the expected SHA256 for a release asset, or $null when
# verification is switched off.
function Get-OdbChecksum([string]$Name) {
    $sums = Get-OdbSums
    if ($null -eq $sums) { return $null }
    foreach ($line in ($sums -split "`n")) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $Name) {
            return $Matches[1].ToLower()
        }
    }
    throw "$Name is not listed in SHA256SUMS for $Version -- nothing was installed.`nSet ODB_NO_VERIFY=1 to install without checking (not recommended)."
}

# Test-OdbChecksum reports whether a staged copy still matches the release, for
# deciding if a large download can be reused. Anything unverifiable is $false.
function Test-OdbChecksum([string]$Path, [string]$Name) {
    if ($env:ODB_NO_VERIFY -eq '1') { return $false }
    try { $want = Get-OdbChecksum $Name } catch { return $false }
    if (-not $want) { return $false }
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower() -eq $want
}

# Assert-OdbChecksum verifies a download and deletes it if it does not match.
function Assert-OdbChecksum([string]$Path, [string]$Name) {
    $want = Get-OdbChecksum $Name
    if (-not $want) { return }   # ODB_NO_VERIFY=1
    $got = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLower()
    if ($got -ne $want) {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
        throw "checksum mismatch for $Name -- the download does not match the release.`n  expected $want`n  got      $got`nNothing was installed."
    }
}

# Add-ToPath appends a directory to the user PATH, idempotently.
function Add-ToPath([string]$Dir) {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($cur) { $parts = $cur -split ';' | Where-Object { $_ -ne '' } }
    if ($parts -notcontains $Dir) {
        $new = (@($parts + $Dir) -join ';')
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        return $true
    }
    return $false
}

function Invoke-Install {
    $arch = Resolve-Arch
    if ($arch -ne 'amd64') {
        throw "unsupported architecture '$arch' -- only windows/amd64 is published (WSL2 runs x86_64)."
    }
    Write-Host ""
    Write-Host "OxynDB installer" -ForegroundColor Cyan

    # 1. WSL. Done first because everything else is pointless without it -- and
    #    because it is the only step that can require a reboot.
    if (Test-WslReady) {
        Write-Step "WSL is already installed"
    } else {
        Write-Step "Installing WSL components (no Linux distribution needed)"
        Install-Wsl
        # Parenthesised deliberately: `Test-RebootPending -or ...` would pass
        # `-or` to the function as a parameter rather than combining them.
        if ((Test-RebootPending) -or -not (Test-WslReady)) {
            $resumed = Register-Resume
            Write-Host ""
            Write-Host "Windows needs to restart to finish enabling WSL." -ForegroundColor Yellow
            if ($resumed) {
                Write-Host "OxynDB should continue by itself a moment after you sign back in."
            }
            # Always given, even when the resume was registered: it depends on
            # RunOnce firing and on networking being up, neither guaranteed.
            Write-Host "If it does not, just run the same command again:" -ForegroundColor Yellow
            Write-Host "    irm https://raw.githubusercontent.com/OxynDB/oxyndb/main/deploy/install.ps1 | iex"
            Write-Host "Nothing is lost by re-running it -- the install picks up where it stopped."
            Write-Host ""
            return
        }
    }

    New-Item -ItemType Directory -Force -Path $Prefix | Out-Null

    # 2. The launcher and the engine binary, each checked against the release's
    #    own SHA256SUMS before it is kept: both run as root inside the distro.
    Write-Step "Downloading OxynDB"
    Get-File (Get-OdbAsset 'odb-windows-amd64.exe') "$Prefix\odb.exe" | Out-Null
    Assert-OdbChecksum "$Prefix\odb.exe" 'odb-windows-amd64.exe'
    Get-File (Get-OdbAsset 'odb-linux-amd64') "$Prefix\odb-linux-amd64" | Out-Null
    Assert-OdbChecksum "$Prefix\odb-linux-amd64" 'odb-linux-amd64'

    # The engine finds a Docker build context relative to the working directory,
    # which finds nothing for someone who installed odb rather than cloning the
    # repo -- so ship the context and let `odb setup` stage it into the distro.
    # tar.exe is built into Windows 10 1803+ and Windows 11.
    New-Item -ItemType Directory -Force -Path "$Prefix\docker-context" | Out-Null
    Get-File (Get-OdbAsset 'oxyndb-docker-context.tar.gz') "$Prefix\docker-context.tar.gz" | Out-Null
    Assert-OdbChecksum "$Prefix\docker-context.tar.gz" 'oxyndb-docker-context.tar.gz'
    & tar.exe -xzf "$Prefix\docker-context.tar.gz" -C "$Prefix\docker-context"
    if ($LASTEXITCODE -ne 0) { throw "could not expand the image build context (tar.exe failed)" }
    Remove-Item "$Prefix\docker-context.tar.gz" -Force

    # 3. The distro. Preferred: our prebuilt image, which already contains
    #    Docker, the btrfs tools, the engine and the container images, so `odb
    #    setup` skips an apt install, a docker build and three registry pulls.
    #    It is bigger (~685 MB vs ~340 MB) but turns setup from many minutes of
    #    network-dependent work into an import. Releases that don't publish it,
    #    or a copy that cannot be verified, fall back to the Ubuntu rootfs.
    $distro = "$Prefix\oxyndb-distro.tar.gz"
    $haveDistro = $false
    if (Test-Path $distro) {
        if (Test-OdbChecksum $distro 'oxyndb-distro.tar.gz') {
            Write-Step "OxynDB distro image already downloaded"
            $haveDistro = $true
        } else {
            Remove-Item $distro -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $haveDistro) {
        Write-Step "Downloading the OxynDB distro image (~685 MB, one time)"
        if (Get-File (Get-OdbAsset 'oxyndb-distro.tar.gz') $distro -Required:$false) {
            try {
                Assert-OdbChecksum $distro 'oxyndb-distro.tar.gz'
                $haveDistro = $true
            } catch {
                Remove-Item $distro -Force -ErrorAction SilentlyContinue
                Write-Warning "$($_.Exception.Message)"
                Write-Warning "falling back to the Ubuntu rootfs"
            }
        }
    }

    if (-not $haveDistro) {
        # The Ubuntu rootfs. ~340 MB, so don't re-fetch a verified copy.
        $rootfs = "$Prefix\oxyndb-rootfs.tar.gz"
        $verify = -not $env:ODB_ROOTFS_URL
        if ((Test-Path $rootfs) -and $verify -and (Test-UpstreamChecksum $rootfs "$RootfsBase/SHA256SUMS" $RootfsName)) {
            Write-Step "Ubuntu rootfs already downloaded"
        } else {
            Write-Step "Downloading the Ubuntu rootfs (~340 MB, one time)"
            Get-File $RootfsUrl $rootfs | Out-Null
            if ($verify) { Assert-UpstreamChecksum $rootfs "$RootfsBase/SHA256SUMS" $RootfsName }
        }
    }

    # 4. PATH -- persisted for new shells, and live in this one so `odb` works
    #    immediately. Not doing the latter is why "odb is not recognized" was
    #    the single most common complaint.
    Write-Step "Adding odb to your PATH"
    Add-ToPath $Prefix | Out-Null
    if (($env:Path -split ';') -notcontains $Prefix) { $env:Path = "$env:Path;$Prefix" }

    # 5. Finish the job. An installer that stops here and tells the user to run
    #    another command is where most installs died.
    if ($env:ODB_NO_SETUP) {
        Write-Step "Skipping setup (ODB_NO_SETUP)"
        Write-Host ""
        Write-Host "Installed. Run:  odb setup" -ForegroundColor Green
        return
    }
    Write-Step "Setting up OxynDB (first run sets up the database engine)"
    Write-Host ""
    & "$Prefix\odb.exe" setup
    if ($LASTEXITCODE -ne 0) {
        throw "odb setup failed. See $Prefix\install.log, then re-run:  odb setup"
    }

    # `odb setup` already printed the "OxynDB is running" summary, including
    # the connection string with the API key. Repeating it here only made the
    # install end with two near-identical blocks, so add the one thing the
    # engine cannot know: where this installer put its log.
    Write-Host ""
    Write-Host "  Installer log: $Prefix\install.log"
}

# Run only when executed/piped -- not when dot-sourced by tests.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Install
}

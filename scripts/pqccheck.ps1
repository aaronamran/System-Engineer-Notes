#Requires -Version 5.1
# =============================================================================
# pqccheck.ps1 — CBOM-scanning Automation Script  (Windows)
#
# SELF-BOOTSTRAPPING: copy this file anywhere and run:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\pqccheck.ps1
#
# It will clone the CBOM-scanning repo if needed, create a Python virtual
# environment, install all dependencies, then run every scan script.
#
# Windows equivalents used:
#   strings  -> Sysinternals strings.exe (auto-downloaded if missing)
#   nm / ldd -> Not available natively; Script 1 is patched to handle gracefully
#   nmap     -> Nmap for Windows          (winget or nmap.org)
#   sslscan  -> sslscan Windows binary    (auto-downloaded from GitHub releases)
#   sudo     -> Administrator elevation  (UAC via Start-Process -Verb RunAs)
# =============================================================================

$ErrorActionPreference = "Continue"

# Force UTF-8 for pipeline and console encoding so Python output is decoded
# correctly through 2>&1 | Tee-Object, and all file writes are BOM-free.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
$Script:Utf8NoBom         = New-Object System.Text.UTF8Encoding $false

# =============================================================================
# SCRIPT-LEVEL STATE  (equivalent to bash globals)
# =============================================================================
$Script:RepoUrl          = "https://github.com/msaufyrohmad/CBOM-scanning.git"
$Script:RepoName         = "CBOM-scanning"
$Script:Timestamp        = Get-Date -Format "yyyyMMdd_HHmmss"
$Script:ScriptPath       = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $PSCommandPath }
$Script:InitialDir       = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$Script:RepoDir          = ""
$Script:LogFile          = ""
$Script:VenvDir          = ""
$Script:SelectedScripts  = @()
$Script:RunScript9       = $false
$Script:RunDiscovery     = $false
$Script:NetworkRange     = ""
$Script:TargetFile       = ""
$Script:ResultDir        = ""
$Script:ScanDir          = ""
$Script:Python           = ""
$Script:Pip              = ""
$Script:IsAdmin          = $false
$Script:Updated          = $false
$Script:RequiredPackages = @("cryptography", "psutil", "python-nmap", "xmltodict")

# =============================================================================
# COLOUR / PRINT HELPERS
# =============================================================================
function Write-Header { param([string]$Msg)
    Write-Host ""
    Write-Host "== $Msg ==" -ForegroundColor White
}
function Write-Ok     { param([string]$Msg) Write-Host "[  OK  ] $Msg" -ForegroundColor Green  }
function Write-Skip   { param([string]$Msg) Write-Host "[ SKIP ] $Msg" -ForegroundColor Cyan   }
function Write-Warn   { param([string]$Msg) Write-Host "[ WARN ] $Msg" -ForegroundColor Yellow }
function Write-Err    { param([string]$Msg) Write-Host "[ERROR ] $Msg" -ForegroundColor Red    }
function Write-Info   { param([string]$Msg) Write-Host "[ INFO ] $Msg" -ForegroundColor Cyan   }
function Write-Sep    { Write-Host "----------------------------------------------" }

function Write-Log {
    param([string]$Msg, [switch]$Verbose)
    if ([string]::IsNullOrEmpty($Script:LogFile)) { return }
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg"
    try { [System.IO.File]::AppendAllText($Script:LogFile, "$line`n", $Script:Utf8NoBom) } catch {}
    if ($Verbose) { Write-Host $line }
}

function Test-Command {
    param([string]$Cmd)
    return ($null -ne (Get-Command $Cmd -ErrorAction SilentlyContinue))
}

function Test-IsCbomRepo {
    param([string]$Dir)
    return ((Test-Path (Join-Path $Dir "1BinariesUsed.py")) -and
            (Test-Path (Join-Path $Dir "DISCOVERY.py"))    -and
            (Test-Path (Join-Path $Dir "9NetworkProtocol.py")))
}

# Refresh the system + user PATH into the current session (after winget installs)
function Update-SessionPath {
    $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $user    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:PATH = "$machine;$user"
}

# =============================================================================
# BANNER
# =============================================================================
function Show-Banner {
    Write-Host ""
    Write-Host "================================================"
    Write-Host "   Post-Quantum Cryptography Check"
    Write-Host "  CBOM-scanning Automation Script (Windows)"
    Write-Host "================================================"
    Write-Host ""
}

# =============================================================================
# ADMIN / PRIVILEGE CHECK
# (Replaces bash sudo detection — Windows uses UAC elevation)
# =============================================================================
function Invoke-CheckAdmin {
    Write-Header "Privilege check"

    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $Script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($Script:IsAdmin) {
        Write-Ok "Running as Administrator."
    } else {
        Write-Warn "Not running as Administrator."
        Write-Info "Scripts 1 and 8 benefit from Administrator rights for full process visibility."
        Write-Host ""
        Write-Host -NoNewline "  Re-launch as Administrator now? [Y/n]: "
        $choice = Read-Host
        if ($choice -notmatch '^[nN]') {
            Write-Info "Re-launching as Administrator via UAC..."
            $argList = "-ExecutionPolicy Bypass -NoProfile -File `"$($Script:ScriptPath)`""
            $uacLaunched = $false
            try {
                Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
                $uacLaunched = $true
            } catch {
                Write-Err "UAC elevation failed: $_"
                Write-Warn "Continuing without Administrator rights."
                Write-Log "Admin check: UAC elevation failed"
            }
            if ($uacLaunched) { exit 0 }
        } else {
            Write-Warn "Continuing without Administrator rights — some scans may be incomplete."
        }
    }
    Write-Log "Privilege check done. IsAdmin=$($Script:IsAdmin)"
}

# =============================================================================
# REPO BOOTSTRAPPING
# (Equivalent to ensure_repo() — clones if not in the repo, then re-execs)
# =============================================================================
function Invoke-EnsureRepo {
    Write-Header "Repository check"

    if (Test-IsCbomRepo $Script:InitialDir) {
        $Script:RepoDir = $Script:InitialDir
        Write-Ok "Running from within the CBOM-scanning repository."
        Write-Log "Repo dir: $($Script:RepoDir)"
        return
    }

    Write-Warn "CBOM-scanning repository not found in current directory."
    Write-Info "The repository will be cloned and this script re-launched from within it."
    Write-Host ""

    # ---- Ensure git is available ----
    if (-not (Test-Command "git")) {
        Write-Warn "git is not installed — required to clone the repository."
        Write-Info "Download Git for Windows: https://git-scm.com/download/win"
        Write-Info "Or via winget: winget install --id Git.Git -e"
        Write-Host ""
        Write-Host -NoNewline "  Attempt to install git via winget now? [Y/n]: "
        $gitChoice = Read-Host
        if ($gitChoice -notmatch '^[nN]') {
            if (Test-Command "winget") {
                Write-Info "Installing git via winget..."
                winget install --id Git.Git -e --source winget --silent
                Update-SessionPath
            } else {
                Write-Info "winget not available — downloading Git for Windows installer directly..."
                $gitInstallerPath = Join-Path $env:TEMP "git-installer.exe"
                try {
                    $gitRelease = Invoke-RestMethod `
                        -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" `
                        -UseBasicParsing -Headers @{ "User-Agent" = "pqccheck-ps1" }
                    $gitAsset = $gitRelease.assets | Where-Object {
                        $_.name -match '64-bit\.exe$'
                    } | Select-Object -First 1
                    if (-not $gitAsset) {
                        Write-Err "Could not find Git for Windows 64-bit installer in the latest release."
                        Write-Err "Install manually: https://git-scm.com/download/win"
                        exit 1
                    }
                    Write-Info "Downloading $($gitAsset.name)..."
                    Invoke-WebRequest -Uri $gitAsset.browser_download_url `
                        -OutFile $gitInstallerPath -UseBasicParsing
                    Write-Info "Running Git installer silently (no reboot required)..."
                    $p = Start-Process -FilePath $gitInstallerPath `
                        -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', `
                                      '/COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh' `
                        -Wait -PassThru
                    if ($p.ExitCode -ne 0) {
                        Write-Err "Git installer exited with code $($p.ExitCode)."
                        exit 1
                    }
                    Update-SessionPath
                    Write-Ok "Git installed successfully."
                } catch {
                    Write-Err "Failed to download/install Git: $_"
                    Write-Err "Install manually: https://git-scm.com/download/win"
                    exit 1
                } finally {
                    Remove-Item $gitInstallerPath -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            Write-Err "git is required. Please install it and re-run."
            exit 1
        }
        if (-not (Test-Command "git")) {
            Write-Err "git not found after install. Open a new terminal and re-run."
            exit 1
        }
        Write-Ok "git installed."
    }

    # ---- Determine clone destination ----
    $cloneDest = Join-Path $env:USERPROFILE $Script:RepoName

    # If dest exists but is not the repo, append timestamp to avoid collision
    if ((Test-Path $cloneDest) -and (-not (Test-IsCbomRepo $cloneDest))) {
        $cloneDest = "${cloneDest}_$($Script:Timestamp)"
    }

    if ((Test-Path $cloneDest) -and (Test-IsCbomRepo $cloneDest)) {
        Write-Ok "Found existing repo at: $cloneDest"
    } else {
        Write-Info "Cloning $($Script:RepoUrl)"
        Write-Info "  -> $cloneDest"
        & git clone $Script:RepoUrl $cloneDest
        if ($LASTEXITCODE -ne 0) {
            Write-Err "git clone failed. Check your internet connection and re-run."
            exit 1
        }
        Write-Ok "Cloned successfully."
    }

    # Copy this script into the repo so future runs are self-contained
    $destScript = Join-Path $cloneDest "pqccheck.ps1"
    try { Copy-Item $Script:ScriptPath $destScript -Force } catch {}

    Write-Host ""
    Write-Info "Re-launching from: $cloneDest"
    Write-Host ""

    $env:PQCCHECK_REEXEC = "1"
    Start-Process powershell.exe `
        -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$destScript`"" `
        -NoNewWindow -Wait
    exit 0
}

# =============================================================================
# GIT UPDATE CHECK
# =============================================================================
function Invoke-CheckForUpdates {
    Write-Header "Checking for repository updates"

    # Skip if we just cloned the repo in this session
    if ($env:PQCCHECK_REEXEC -eq "1") {
        Write-Ok "Repository was just cloned — already up to date."
        Write-Log "Update check skipped (just cloned)"
        return
    }

    if (-not (Test-Path (Join-Path $Script:RepoDir ".git"))) {
        Write-Warn "Directory is not a git repository — skipping update check."
        Write-Log "Not a git repo, skipping update check"
        return
    }

    Push-Location $Script:RepoDir
    try {
        Write-Info "Fetching from origin..."
        & git fetch origin --quiet 2>>$Script:LogFile
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not reach the remote. Continuing with local version."
            Write-Log "git fetch failed"
            return
        }

        $local  = & git rev-parse HEAD 2>$null
        $remote = & git rev-parse "@{u}" 2>$null

        if ([string]::IsNullOrEmpty($remote)) {
            Write-Warn "No upstream tracking branch configured — skipping update check."
            Write-Log "No upstream tracking branch"
            return
        }

        if ($local -eq $remote) {
            $short = & git rev-parse --short HEAD 2>$null
            Write-Ok "Repository is already up to date ($short) — skipping pull."
            Write-Log "Repo up to date at $local"
            return
        }

        Write-Info "New commits are available on the remote:"
        Write-Host ""
        & git log HEAD..@{u} --oneline 2>$null | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
        Write-Host ""

        Write-Host -NoNewline "  Pull the latest updates? [Y/n]: "
        $choice = Read-Host
        if ($choice -match '^[nN]') {
            Write-Skip "Skipping update — continuing with current version."
            Write-Log "User declined update"
        } else {
            Write-Info "Pulling updates..."
            $branch = & git rev-parse --abbrev-ref HEAD 2>$null
            if ([string]::IsNullOrEmpty($branch)) { $branch = "main" }
            & git pull origin $branch 2>>$Script:LogFile
            if ($LASTEXITCODE -eq 0) {
                $short = & git rev-parse --short HEAD 2>$null
                Write-Ok "Repository updated to $short."
                $Script:Updated = $true
                Write-Log "Repo updated to $(& git rev-parse HEAD 2>$null)"
            } else {
                Write-Err "git pull failed. Continuing with current version."
                Write-Log "git pull failed"
            }
        }
    } finally {
        Pop-Location
    }
}

# =============================================================================
# PYTHON + VIRTUAL ENVIRONMENT SETUP
# (Replaces setup_python_env — no SSL bootstrap needed; Windows Python
#  always ships with OpenSSL support built in)
# =============================================================================
function Invoke-SetupPythonEnv {
    Write-Header "Python environment setup"

    # ---- Find Python 3 ----
    # Try common candidates: python, python3, then the Windows py launcher
    $sysPython = $null
    foreach ($candidate in @("python", "python3")) {
        if (Test-Command $candidate) {
            $ver = & $candidate --version 2>&1
            if ($ver -match "Python 3") { $sysPython = $candidate; break }
        }
    }
    # Fall back to the Windows Python Launcher (py.exe)
    if (-not $sysPython -and (Test-Command "py")) {
        try {
            $ver = & py -3 --version 2>&1
            if ($ver -match "Python 3") { $sysPython = "py"; }
        } catch {}
    }

    if (-not $sysPython) {
        Write-Warn "Python 3 is not installed on this system."
        Write-Info "Download from: https://www.python.org/downloads/"
        Write-Info "Or via winget: winget install --id Python.Python.3.11 -e"
        Write-Host ""
        Write-Host -NoNewline "  Attempt to install Python 3.11 via winget now? [Y/n]: "
        $pyChoice = Read-Host
        if ($pyChoice -notmatch '^[nN]') {
            if (Test-Command "winget") {
                Write-Info "Installing Python 3.11 via winget..."
                winget install --id Python.Python.3.11 -e --source winget
                Update-SessionPath
                foreach ($candidate in @("python", "python3")) {
                    if (Test-Command $candidate) {
                        $ver = & $candidate --version 2>&1
                        if ($ver -match "Python 3") { $sysPython = $candidate; break }
                    }
                }
            } else {
                Write-Info "winget not available — downloading Python 3.11 installer directly..."
                $pyInstallerPath = Join-Path $env:TEMP "python-installer.exe"
                try {
                    # Python 3.11 LTS — latest patch as of 2026; update URL for newer patch if needed
                    $pyUrl = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe"
                    Write-Info "Downloading Python 3.11.9 (amd64)..."
                    Invoke-WebRequest -Uri $pyUrl -OutFile $pyInstallerPath -UseBasicParsing
                    Write-Info "Running Python installer silently (no reboot required)..."
                    $p = Start-Process -FilePath $pyInstallerPath `
                        -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0' `
                        -Wait -PassThru
                    if ($p.ExitCode -ne 0) {
                        Write-Err "Python installer exited with code $($p.ExitCode)."
                        exit 1
                    }
                    Update-SessionPath
                    foreach ($candidate in @("python", "python3")) {
                        if (Test-Command $candidate) {
                            $ver = & $candidate --version 2>&1
                            if ($ver -match "Python 3") { $sysPython = $candidate; break }
                        }
                    }
                    Write-Ok "Python installed successfully."
                } catch {
                    Write-Err "Failed to download/install Python: $_"
                    Write-Err "Install manually: https://www.python.org/downloads/"
                    exit 1
                } finally {
                    Remove-Item $pyInstallerPath -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            Write-Err "Python 3 is required. Please install it and re-run."
            exit 1
        }
        if (-not $sysPython) {
            Write-Err "Python 3 not found after install. Open a new terminal and re-run."
            exit 1
        }
    }

    # Resolve actual python binary for the launcher case
    $pythonExe  = if ($sysPython -eq "py") { "py" } else { $sysPython }
    $pythonArgs = if ($sysPython -eq "py") { @("-3") } else { @() }
    $verStr = & $pythonExe @pythonArgs --version 2>&1
    Write-Ok "System Python: $pythonExe $($pythonArgs -join ' ') ($verStr)"

    # ---- Create virtual environment ----
    # Using a venv isolates all packages and avoids permission issues on Windows
    $Script:VenvDir = Join-Path $Script:RepoDir ".venv"
    $venvCreated = $false

    if (-not (Test-Path $Script:VenvDir)) {
        Write-Info "Creating virtual environment at $($Script:VenvDir)..."
        & $pythonExe @pythonArgs -m venv $Script:VenvDir 2>>$Script:LogFile
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Could not create virtual environment. Exiting."
            exit 1
        }
        Write-Ok "Virtual environment created."
        $venvCreated = $true
    } else {
        Write-Ok "Existing virtual environment: $($Script:VenvDir)"
    }

    $Script:Python = Join-Path $Script:VenvDir "Scripts\python.exe"
    $Script:Pip    = Join-Path $Script:VenvDir "Scripts\pip.exe"

    if (-not (Test-Path $Script:Python)) {
        Write-Err "Virtual environment Python not found: $($Script:Python)"
        exit 1
    }

    # Force UTF-8 for all Python I/O so that non-ASCII characters in print()
    # (e.g. arrows, box-drawing) don't crash on Windows cp1252 consoles.
    $env:PYTHONUTF8 = "1"

    $venvVer = & $Script:Python --version 2>&1
    Write-Ok "Python : $($Script:Python) ($venvVer)"

    # Upgrade pip only when the venv was just created — not on every run.
    if ($venvCreated) {
        Write-Info "Upgrading pip inside new virtual environment..."
        & $Script:Python -m pip install --upgrade pip --quiet 2>>$Script:LogFile
        if ($LASTEXITCODE -eq 0) {
            $pipVer = & $Script:Pip --version 2>&1
            Write-Ok "pip upgraded: $pipVer"
        } else {
            Write-Warn "pip upgrade failed — continuing with current version."
        }
    } else {
        $pipVer = & $Script:Pip --version 2>&1
        Write-Ok "pip        : $pipVer"
    }

    Write-Log "PYTHON=$($Script:Python)  PIP=$($Script:Pip)  VENV=$($Script:VenvDir)"
}

# =============================================================================
# PYTHON PACKAGE INSTALLATION
# =============================================================================
function Invoke-CheckPythonPackages {
    Write-Header "Python package check"
    Push-Location $Script:RepoDir
    try {
        # Pin older versions for Python <= 3.6 (modern cryptography requires Rust)
        $pyMinor = [int](& $Script:Python -c "import sys; print(sys.version_info.minor)" 2>$null)
        $pyMajor = [int](& $Script:Python -c "import sys; print(sys.version_info.major)" 2>$null)

        # Always check each package individually — only install what's missing.
        # This applies even after a repo update ($Script:Updated = true).
        $toInstall = @()
        foreach ($pkg in $Script:RequiredPackages) {
            $importName = if ($pkg -eq "python-nmap") { "nmap" } else { $pkg }
            & $Script:Python -c "import $importName" 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "  $pkg  (already installed)"
            } else {
                Write-Warn "  $pkg  (missing)"
                # Apply version pin for old Python if needed
                if ($pyMajor -eq 3 -and $pyMinor -le 6) {
                    switch ($pkg) {
                        "cryptography" { $toInstall += "cryptography==3.3.2" }
                        "psutil"       { $toInstall += "psutil==5.8.0"        }
                        default        { $toInstall += $pkg                   }
                    }
                } else {
                    $toInstall += $pkg
                }
            }
        }

        if ($toInstall.Count -eq 0) {
            Write-Ok "All required packages already installed — skipping install."
            Write-Log "All packages present"
            return
        }

        Write-Info "Installing $($toInstall.Count) missing package(s)..."
        $failCount = 0
        foreach ($pkg in $toInstall) {
            & $Script:Pip install $pkg --quiet 2>>$Script:LogFile
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "  $pkg"
                Write-Log "Installed $pkg"
            } else {
                Write-Warn "  $pkg  (failed — some scans may not work)"
                Write-Log "Failed to install $pkg"
                $failCount++
            }
        }

        if ($failCount -eq 0) { Write-Ok "All missing packages installed." }
        else { Write-Warn "$failCount package(s) failed. Check log for details." }

    } finally {
        Pop-Location
    }
}

# =============================================================================
# SYSTEM TOOL DETECTION + INSTALL  (Windows)
#
# Linux tool  -> Windows equivalent / approach
# -------------------------------------------------------
# strings     -> Sysinternals strings.exe
# nm          -> No native equivalent  (MSYS2/MinGW required; warn only)
# ldd         -> No native equivalent  (Script 1 patched to handle gracefully)
# nmap        -> Nmap for Windows
# sslscan     -> sslscan Windows build (GitHub releases)
# =============================================================================
function Invoke-CheckSystemTools {
    Write-Header "System tool check"

    # Tools we can check and optionally install
    $tools   = @("strings", "nmap", "sslscan")
    $missing = @()

    foreach ($tool in $tools) {
        if (Test-Command $tool) {
            Write-Ok "  $tool"
        } else {
            Write-Warn "  $tool  (not found)"
            $missing += $tool
        }
    }

    # nm / ldd have no native Windows counterparts
    Write-Info "  nm   — not available natively on Windows (Script 2/3 use Python-based fallbacks)"
    Write-Info "  ldd  — not available natively on Windows (Script 1 is patched to handle this)"

    if ($missing.Count -eq 0) {
        Write-Log "All Windows system tools present"
        return
    }

    Write-Host ""
    Write-Warn "Missing tools: $($missing -join ', ')"
    Write-Host -NoNewline "  Attempt to install missing tools automatically? [Y/n]: "
    $choice = Read-Host
    if ($choice -match '^[nN]') {
        Write-Skip "Skipping tool installation. Affected scans may fail."
        Write-Log "User declined system tool install"
        return
    }

    $hasWinget = Test-Command "winget"

    # ---- .tools dir for direct downloads ----
    $toolsDir = Join-Path $Script:RepoDir ".tools"
    $null = New-Item -ItemType Directory -Force $toolsDir -ErrorAction SilentlyContinue

    foreach ($tool in $missing) {
        switch ($tool) {

            # ------------------------------------------------------------------
            "strings" {
                Write-Info "Installing Sysinternals strings.exe..."
                $installed = $false

                if ($hasWinget) {
                    winget install --id Microsoft.Sysinternals.Strings -e --source winget --silent
                    Update-SessionPath
                    if (Test-Command "strings") {
                        Write-Ok "strings installed via winget."
                        Write-Log "strings installed via winget"
                        $installed = $true
                    }
                }

                if (-not $installed) {
                    Write-Info "Downloading Sysinternals Strings directly..."
                    $zipPath = Join-Path $env:TEMP "Strings.zip"
                    try {
                        Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Strings.zip" `
                            -OutFile $zipPath -UseBasicParsing
                        Expand-Archive -Path $zipPath -DestinationPath $toolsDir -Force
                        $env:PATH = "$toolsDir;$env:PATH"
                        Write-Ok "strings installed to $toolsDir (added to session PATH)."
                        Write-Log "strings downloaded to $toolsDir"
                    } catch {
                        Write-Warn "Failed to download Sysinternals Strings: $_"
                        Write-Warn "Download manually: https://download.sysinternals.com/files/Strings.zip"
                        Write-Warn "Place strings.exe in your PATH before re-running."
                    } finally {
                        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                    }
                }

                # Pre-accept the Sysinternals EULA so strings.exe never hangs
                # waiting for interactive EULA input (applies to both winget and
                # direct-download installs).
                try {
                    $null = New-Item -Path "HKCU:\Software\Sysinternals\Strings" `
                        -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path "HKCU:\Software\Sysinternals\Strings" `
                        -Name "EulaAccepted" -Value 1 -Type DWord -Force
                    Write-Ok "Sysinternals strings EULA pre-accepted (registry key set)."
                    Write-Log "strings EULA pre-accepted via registry"
                } catch {
                    Write-Warn "Could not pre-accept strings EULA via registry: $_"
                    Write-Warn "strings.exe may hang on first run — if so, run: strings /accepteula"
                }
            }

            # ------------------------------------------------------------------
            "nmap" {
                Write-Info "Installing Nmap for Windows..."
                $installed = $false

                if ($hasWinget) {
                    winget install --id Insecure.Nmap -e --source winget --silent
                    Update-SessionPath
                    if (Test-Command "nmap") {
                        Write-Ok "nmap installed via winget."
                        Write-Log "nmap installed via winget"
                        $installed = $true
                    }
                }

                if (-not $installed) {
                    Write-Info "Downloading Nmap for Windows installer directly..."

                    # ---- Npcap (required by Nmap silent install) ----
                    # Nmap's /S installer pops a GUI dialog if Npcap is absent.
                    # NOTE: the free Npcap installer does NOT support /S (OEM only).
                    # Install Npcap interactively first (one-time) so subsequent
                    # Nmap /S installs run fully unattended.
                    $npcapKey = "HKLM:\SOFTWARE\Npcap"
                    if (-not (Test-Path $npcapKey)) {
                        Write-Info "Npcap not found — required by Nmap."
                        Write-Warn "Npcap requires a one-time interactive install. Please click through the installer window."
                        $npcapInstallerPath = Join-Path $env:TEMP "npcap-setup.exe"
                        try {
                            $npcapPage  = Invoke-WebRequest -Uri "https://npcap.com/dist/" -UseBasicParsing
                            $npcapMatch = [regex]::Match($npcapPage.Content, 'href="(npcap-[\d.]+\.exe)"')
                            $npcapFile  = if ($npcapMatch.Success) { $npcapMatch.Groups[1].Value } `
                                            else { "npcap-1.87.exe" }
                            $npcapUrl   = "https://npcap.com/dist/$npcapFile"
                            Write-Info "Downloading $npcapUrl..."
                            Invoke-WebRequest -Uri $npcapUrl -OutFile $npcapInstallerPath -UseBasicParsing
                            Write-Info "Launching Npcap installer — complete it to continue..."
                            $pn = Start-Process -FilePath $npcapInstallerPath -Wait -PassThru
                            if ($pn.ExitCode -ne 0) {
                                Write-Warn "Npcap installer exited with code $($pn.ExitCode) — Nmap may not function correctly."
                                Write-Log "npcap install exit code $($pn.ExitCode)"
                            } else {
                                Write-Ok "Npcap installed."
                                Write-Log "npcap installed interactively"
                            }
                        } catch {
                            Write-Warn "Could not download/install Npcap: $_ — Nmap installer may show a dialog."
                        } finally {
                            Remove-Item $npcapInstallerPath -Force -ErrorAction SilentlyContinue
                        }
                    } else {
                        Write-Ok "Npcap already installed — skipping."
                        Write-Log "npcap already present"
                    }

                    # ---- Nmap ----
                    $nmapInstallerPath = Join-Path $env:TEMP "nmap-setup.exe"
                    try {
                        # Parse nmap.org/download.html for the latest Windows setup exe
                        $nmapPage = Invoke-WebRequest -Uri "https://nmap.org/download.html" -UseBasicParsing
                        $nmapMatch = [regex]::Match($nmapPage.Content, 'href="(https://nmap\.org/dist/nmap-[\d.]+-setup\.exe)"')
                        $nmapUrl = if ($nmapMatch.Success) { $nmapMatch.Groups[1].Value } `
                                   else { "https://nmap.org/dist/nmap-7.95-setup.exe" }
                        Write-Info "Downloading $nmapUrl..."
                        Invoke-WebRequest -Uri $nmapUrl -OutFile $nmapInstallerPath -UseBasicParsing
                        Write-Info "Running Nmap installer silently (no reboot required)..."
                        $p = Start-Process -FilePath $nmapInstallerPath -ArgumentList '/S' -Wait -PassThru
                        if ($p.ExitCode -ne 0) {
                            Write-Warn "Nmap installer exited with code $($p.ExitCode). DISCOVERY/Script 9 may not work."
                        } else {
                            Update-SessionPath
                            Write-Ok "Nmap installed successfully."
                            Write-Log "nmap installed via direct download"
                        }
                    } catch {
                        Write-Warn "Could not download/install nmap: $_"
                        Write-Warn "Download manually: https://nmap.org/download.html"
                    } finally {
                        Remove-Item $nmapInstallerPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            # ------------------------------------------------------------------
            "sslscan" {
                Write-Info "Downloading sslscan Windows binary from GitHub releases..."
                $zipPath = Join-Path $env:TEMP "sslscan_win.zip"
                try {
                    $apiUrl  = "https://api.github.com/repos/rbsec/sslscan/releases/latest"
                    $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing `
                                   -Headers @{ "User-Agent" = "pqccheck-ps1" }
                    # Look for a Windows ZIP asset
                    $asset = $release.assets | Where-Object {
                        $_.name -match "win" -and $_.name -match "\.zip$"
                    } | Select-Object -First 1

                    if ($asset) {
                        Invoke-WebRequest -Uri $asset.browser_download_url `
                            -OutFile $zipPath -UseBasicParsing
                        Expand-Archive -Path $zipPath -DestinationPath $toolsDir -Force
                        $env:PATH = "$toolsDir;$env:PATH"
                        Write-Ok "sslscan installed to $toolsDir (added to session PATH)."
                        Write-Log "sslscan downloaded to $toolsDir"
                    } else {
                        Write-Warn "No Windows ZIP asset found in sslscan latest release."
                        Write-Warn "Download manually: https://github.com/rbsec/sslscan/releases"
                    }
                } catch {
                    Write-Warn "Could not download sslscan: $_"
                    Write-Warn "Download manually: https://github.com/rbsec/sslscan/releases"
                } finally {
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# =============================================================================
# INSTALLED SOFTWARE PRE-FLIGHT CHECK
# Reads the same registry hives as swversion.ps1.
# Identifies missing critical dependencies (Python, git, winget) and flags
# installed software that is relevant to specific CBOM scan scripts.
# =============================================================================
function Invoke-CheckInstalledSoftware {
    Write-Header "Installed software pre-flight check"

    # Read 64-bit and 32-bit uninstall hives
    $regPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $installed = $regPaths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.DisplayName -ne $null } |
        Select-Object DisplayName, DisplayVersion |
        Sort-Object DisplayName

    if (-not $installed) {
        Write-Warn "Could not read installed software from registry."
        return
    }

    # -------------------------------------------------------------------------
    # Critical dependencies
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "  -- Critical dependencies --" -ForegroundColor White

    # Python — required for all CBOM scan scripts
    $pyEntries = $installed | Where-Object { $_.DisplayName -match '(?i)python\s+3' }
    if ($pyEntries) {
        foreach ($p in $pyEntries) {
            Write-Ok "  $($p.DisplayName)  $($p.DisplayVersion)"
        }
    } else {
        Write-Warn "  Python 3 — NOT installed"
        Write-Info "    -> REQUIRED: all CBOM scan scripts need Python 3"
        if (Test-Command "winget") {
            Write-Info "    -> Auto-install available: winget install --id Python.Python.3.11 -e"
        } else {
            Write-Info "    -> winget not found on this server"
            Write-Info "    -> Manual install: https://www.python.org/downloads/"
            Write-Info "    -> Or: download the embeddable package for Windows Server 2019 (x64)"
        }
    }

    # git — required to clone the CBOM-scanning repo
    $gitEntry = $installed | Where-Object { $_.DisplayName -match '(?i)^git(\s|$)' }
    if ($gitEntry -or (Test-Command "git")) {
        $ver = if ($gitEntry) { $gitEntry[0].DisplayVersion } else { (& git --version 2>&1) -replace 'git version ','' }
        Write-Ok "  Git  $ver"
    } else {
        Write-Warn "  Git — NOT installed"
        Write-Info "    -> REQUIRED: needed to clone https://github.com/msaufyrohmad/CBOM-scanning"
        Write-Info "    -> Manual install: https://git-scm.com/download/win"
    }

    # winget — enables automatic installation of Python / git / nmap / strings
    if (Test-Command "winget") {
        $wgVer = (winget --version 2>&1)
        Write-Ok "  winget  $wgVer  (automatic installs available)"
    } else {
        Write-Warn "  winget — NOT available"
        Write-Info "    -> Windows Server 2019 does not ship winget by default"
        Write-Info "    -> Install 'App Installer' from: https://aka.ms/getwinget"
        Write-Info "    -> Or install Python/Git/nmap manually using the links above"
    }

    # -------------------------------------------------------------------------
    # Syslog / monitoring software — contextual scan advice
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "  -- Syslog / monitoring software detected --" -ForegroundColor White

    # Patterns: display name regex -> which scan scripts are relevant
    $checks = [ordered]@{
        '(?i)kiwi syslog server'          = @{
            Scripts = '1 (processes), 8 (network: UDP/TCP 514, TLS 6514), 9 (TLS on web interface)'
            Note    = 'Main syslog daemon — crypto in transport and stored log data'
        }
        '(?i)kiwi syslog web access'      = @{
            Scripts = '7 (web app dirs), 9 (TLS cipher scan on web UI)'
            Note    = 'Web interface — check TLS config and cipher suites'
        }
        '(?i)ultidev web server'          = @{
            Scripts = '7 (web app dirs), 9 (TLS scan)'
            Note    = 'Hosts Kiwi Web Access — check TLS and certificate'
        }
        '(?i)solarwinds event log forward' = @{
            Scripts = '1 (processes), 8 (forwarding connections)'
            Note    = 'Log forwarding agent — check encryption on forwarded traffic'
        }
        '(?i)solarwinds license'          = @{
            Scripts = '8 (network connections to SolarWinds cloud)'
            Note    = 'License manager — outbound connection worth auditing'
        }
        '(?i)zabbix agent'                = @{
            Scripts = '1 (processes), 8 (agent port 10050/10051)'
            Note    = 'Monitoring agent — check if agent traffic is encrypted (PSK/TLS)'
        }
        '(?i)anydesk'                     = @{
            Scripts = '8 (outbound AnyDesk relay connections), 9 (TLS)'
            Note    = 'Remote access tool — verify TLS and cipher suite'
        }
        '(?i)teamviewer'                  = @{
            Scripts = '8 (outbound TeamViewer relay/UDP), 9 (TLS on web interface)'
            Note    = 'Remote access tool — verify TLS version and cipher suite'
        }
        '(?i)trend micro|apex one'        = @{
            Scripts = '1 (processes), 8 (outbound update/telemetry connections)'
            Note    = 'AV/EDR agent — check encryption on update traffic and C2 channel'
        }
        '(?i)putty'                       = @{
            Scripts = '1 (processes), 8 (SSH outbound port 22)'
            Note    = 'SSH/SCP client — verify key exchange algorithms and host-key types in config'
        }
        '(?i)deltacopy'                   = @{
            Scripts = '1 (processes), 8 (rsync port 873 or SSH)'
            Note    = 'rsync-based backup — check if transfer channel is encrypted'
        }
        '(?i)sql server|sqlserver'        = @{
            Scripts = '1 (sqlservr.exe process), 8 (TCP 1433/1434 TLS), 5 (certificates)'
            Note    = 'Database engine — verify TLS for client connections and certificate strength'
        }
        '(?i)vmoptimization|sangfor'      = @{
            Scripts = '1 (processes), 8 (network connections)'
            Note    = 'Hypervisor guest agent — outbound connections worth auditing'
        }
    }

    $foundAny = $false
    # Track which script numbers are relevant based on what was found, so the
    # recommended order below is built from actual detections, not hardcoded.
    $scriptReasons = [ordered]@{
        '1' = [System.Collections.Generic.List[string]]::new()
        '2' = [System.Collections.Generic.List[string]]::new()
        '3' = [System.Collections.Generic.List[string]]::new()
        '5' = [System.Collections.Generic.List[string]]::new()
        '7' = [System.Collections.Generic.List[string]]::new()
        '8' = [System.Collections.Generic.List[string]]::new()
        '9' = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($pattern in $checks.Keys) {
        $matches_ = $installed | Where-Object { $_.DisplayName -match $pattern }
        if ($matches_) {
            $foundAny = $true
            foreach ($m in $matches_) {
                Write-Ok "  $($m.DisplayName)  $($m.DisplayVersion)"
            }
            $info = $checks[$pattern]
            Write-Info "    -> Relevant scripts: $($info.Scripts)"
            Write-Info "    -> $($info.Note)"

            # Parse the Scripts string (e.g. "1 (processes), 8 (port 1433), 9 (TLS)")
            # to extract just the script numbers for the dynamic recommendation below.
            foreach ($m in $matches_) {
                $scriptNums = [regex]::Matches($info.Scripts, '\b([1-9]|d)\b') | ForEach-Object { $_.Value }
                foreach ($num in $scriptNums) {
                    if ($scriptReasons.Contains($num)) {
                        $label = $m.DisplayName
                        if (-not $scriptReasons[$num].Contains($label)) {
                            $scriptReasons[$num].Add($label)
                        }
                    }
                }
            }
        }
    }

    if (-not $foundAny) {
        Write-Info "  No known monitoring/remote-access/database software detected in registry."
        Write-Info "  Running a full scan (scripts 1-8) is recommended to cover unknown software."
    }

    # -------------------------------------------------------------------------
    # Recommended script order — built dynamically from what was detected above.
    # Scripts 1, 2, 5, 8 are always useful on any Windows host; the rest are
    # added only when relevant software was found.
    # -------------------------------------------------------------------------
    Write-Host ""
    Write-Host "  -- Recommended scan order for this host --" -ForegroundColor White

    # Always-relevant scripts
    $always = [ordered]@{
        '1' = 'running processes and their loaded crypto libraries'
        '8' = 'live network connections and their encryption'
        '5' = 'certificates and private keys (full C:\ walk — run off-peak)'
        '2' = 'binaries on disk (PATH + install directories)'
        '3' = 'system DLLs / shared libraries'
    }
    foreach ($num in $always.Keys) {
        $extra = ''
        if ($scriptReasons[$num] -and $scriptReasons[$num].Count -gt 0) {
            $extra = "  [detected: $($scriptReasons[$num] -join ', ')]"
        }
        Write-Info "  Script $num  — $($always[$num])$extra"
    }

    # Conditionally-relevant scripts — only shown when matching software found
    $conditional = [ordered]@{
        '7' = 'web application directories'
        '9' = 'TLS/SSL cipher scan on exposed HTTPS interfaces (needs target host file)'
        '6' = 'executable scripts — .py/.sh/.ps1/.bat (full walk — slow)'
        '4' = 'kernel modules (Linux only — produces no output on Windows)'
    }
    $condShown = $false
    foreach ($num in $conditional.Keys) {
        if ($scriptReasons.Contains($num) -and $scriptReasons[$num] -and $scriptReasons[$num].Count -gt 0) {
            if (-not $condShown) {
                Write-Info "  -- Also recommended based on detected software --"
                $condShown = $true
            }
            Write-Info "  Script $num  — $($conditional[$num])  [detected: $($scriptReasons[$num] -join ', ')]"
        }
    }
    Write-Host ""

    Write-Log "Installed software pre-flight check done"
}

# =============================================================================
# INTERACTIVE SETUP — SCRIPT 9  (9NetworkProtocol.py)
# =============================================================================
function Invoke-SetupScript9 {
    Write-Header "Setup: Network Protocol Scan (9NetworkProtocol.py)"
    Write-Info "  This script uses sslscan to test TLS/SSL on a list of target hosts."
    Write-Info "  It produces per-target XML/JSON/PEM files and a combined_results.json."
    Write-Host ""

    if (-not (Test-Command "sslscan")) {
        Write-Warn "sslscan is not installed — required by Script 9."
        Write-Host -NoNewline "  Skip Script 9? [Y/n]: "
        $skipChoice = Read-Host
        if ($skipChoice -match '^[nN]') {
            Write-Info "Attempting to install sslscan..."
            Invoke-CheckSystemTools
            if (-not (Test-Command "sslscan")) {
                Write-Err "sslscan still not available. Skipping Script 9."
                Write-Log "Script 9 skipped — sslscan unavailable"
                $Script:RunScript9 = $false
                return
            }
        } else {
            Write-Skip "Script 9 skipped."
            Write-Log "Script 9 skipped by user (no sslscan)"
            $Script:RunScript9 = $false
            return
        }
    }

    Write-Host ""
    Write-Warn "Script 9 actively probes TLS/SSL on each target — generates real network traffic."
    Write-Warn "This may trigger IDS/IPS alerts and appear in server access logs."
    Write-Warn "Only run with written authorization."
    Write-Host ""
    Write-Host -NoNewline "  Run Script 9? [Y/n]: "
    $runChoice = Read-Host
    if ($runChoice -match '^[nN]') {
        Write-Skip "Script 9 skipped."
        Write-Log "Script 9 skipped by user"
        $Script:RunScript9 = $false
        return
    }

    # Output directory is created later in main() only if scan actually runs
    $Script:ResultDir = Join-Path $Script:RepoDir "result_$($Script:Timestamp)"

    # ---- Target file ----
    Write-Host ""
    Write-Info "  A target file lists the hostnames/IPs to scan (one per line)."
    Write-Info "  Example:  uitm.edu.my"
    Write-Info "            upm.edu.my"
    Write-Host ""

    while ($true) {
        Write-Host -NoNewline "  Path to target file [press Enter to create a new one]: "
        $inputTarget = Read-Host

        if ([string]::IsNullOrWhiteSpace($inputTarget)) {
            # Create a new target file interactively
            $Script:TargetFile = Join-Path $Script:RepoDir "target.txt"
            Write-Info "Creating target file: $($Script:TargetFile)"
            Write-Info "  Enter one hostname or IP per line. Enter a blank line when done."
            $hosts = [System.Collections.Generic.List[string]]::new()
            while ($true) {
                Write-Host -NoNewline "    host (blank to finish): "
                $hostEntry = Read-Host
                if ([string]::IsNullOrWhiteSpace($hostEntry)) { break }
                $hosts.Add($hostEntry)
            }
            if ($hosts.Count -eq 0) {
                Write-Warn "No hosts entered. Skipping Script 9."
                Write-Log "Script 9 skipped — empty target file"
                $Script:RunScript9 = $false
                return
            }
            [System.IO.File]::WriteAllLines($Script:TargetFile, [string[]]$hosts, $Script:Utf8NoBom)
            Write-Ok "Target file saved: $($Script:TargetFile) ($($hosts.Count) hosts)"
            Write-Log "Target file created: $($Script:TargetFile)"
            break

        } elseif (Test-Path $inputTarget) {
            $Script:TargetFile = $inputTarget
            $lineCount = (Get-Content $Script:TargetFile | Measure-Object -Line).Lines
            Write-Ok "Using target file: $($Script:TargetFile) ($lineCount hosts)"
            Write-Log "Target file set: $($Script:TargetFile)"
            break
        } else {
            Write-Err "File not found: $inputTarget — please try again."
        }
    }

    $Script:RunScript9 = $true
}

# =============================================================================
# INTERACTIVE SETUP — DISCOVERY.py
# =============================================================================
function Invoke-SetupDiscovery {
    Write-Header "Setup: Network Discovery Scan (DISCOVERY.py)"
    Write-Info "  Performs an nmap-based network scan to discover hosts and open ports,"
    Write-Info "  outputting scan_results.json and DISCOVERY_results.csv."
    Write-Host ""

    if (-not (Test-Command "nmap")) {
        Write-Warn "nmap is not installed — required by DISCOVERY.py."
        Write-Host -NoNewline "  Skip DISCOVERY scan? [Y/n]: "
        $skipChoice = Read-Host
        if ($skipChoice -match '^[nN]') {
            Write-Info "Attempting to install nmap..."
            if (Test-Command "winget") {
                winget install --id Insecure.Nmap -e --source winget --silent
                Update-SessionPath
                if (Test-Command "nmap") {
                    Write-Ok "nmap installed."
                } else {
                    Write-Warn "nmap may need a new terminal session to be detected. Try restarting and re-running."
                }
            } else {
                Write-Err "winget not available. Download nmap from: https://nmap.org/download.html"
            }
            if (-not (Test-Command "nmap")) {
                Write-Err "nmap still unavailable. Skipping DISCOVERY scan."
                Write-Log "DISCOVERY skipped — nmap unavailable"
                $Script:RunDiscovery = $false
                return
            }
        } else {
            Write-Skip "DISCOVERY scan skipped."
            Write-Log "DISCOVERY skipped by user (no nmap)"
            $Script:RunDiscovery = $false
            return
        }
    }

    Write-Host -NoNewline "  Run DISCOVERY network scan? [Y/n]: "
    $runChoice = Read-Host
    if ($runChoice -match '^[nN]') {
        Write-Skip "DISCOVERY scan skipped."
        Write-Log "DISCOVERY skipped by user"
        $Script:RunDiscovery = $false
        return
    }

    Write-Host ""
    Write-Warn "AUTHORIZATION REQUIRED: nmap sends packets to every host in the range."
    Write-Warn "This generates network traffic and may trigger IDS/IPS alerts."
    Write-Warn "Only run with written authorization."
    Write-Host ""
    Write-Host "  CIDR range required, e.g.: 192.168.1.0/24 or 10.0.0.0/16"
    Write-Host "  (Administrator rights recommended for SYN scan on Windows)"
    Write-Host ""

    while ($true) {
        Write-Host -NoNewline "  Enter network range to scan: "
        $Script:NetworkRange = Read-Host
        if ([string]::IsNullOrWhiteSpace($Script:NetworkRange)) {
            Write-Warn "Network range cannot be empty."
        } elseif ($Script:NetworkRange -match '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$') {
            Write-Ok "Network range: $($Script:NetworkRange)"
            Write-Log "DISCOVERY network range: $($Script:NetworkRange)"
            $Script:RunDiscovery = $true
            break
        } else {
            Write-Warn "Invalid format — expected something like 192.168.1.0/24. Please try again."
        }
    }
}

# =============================================================================
# INDIVIDUAL SCRIPT RUNNER
# Returns $true on success, $false on failure.
# All Python output is sent through Out-Host so it does NOT pollute the
# PowerShell pipeline (which would confuse the boolean return value).
# =============================================================================
function Invoke-RunPythonScript {
    param(
        [string]   $ScriptName,
        [string]   $Description,
        [string]   $OutputFile  = "",
        [string[]] $ExtraArgs   = @()
    )
    Write-Sep
    Write-Info "Starting : $Description"
    Write-Info "Script   : $ScriptName"
    if ($OutputFile) { Write-Info "Output   : $OutputFile" }
    Write-Host ""
    Write-Log "START $ScriptName"

    $scriptPath = Join-Path $Script:RepoDir $ScriptName
    Push-Location $Script:ScanDir
    try {
        if ($ExtraArgs.Count -gt 0) {
            & $Script:Python $scriptPath @ExtraArgs 2>&1 |
                Tee-Object -Append -FilePath $Script:LogFile | Out-Host
        } else {
            & $Script:Python $scriptPath 2>&1 |
                Tee-Object -Append -FilePath $Script:LogFile | Out-Host
        }
        $rc = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    Write-Host ""
    if ($rc -eq 0) {
        if ($OutputFile -and (Test-Path (Join-Path $Script:ScanDir $OutputFile))) {
            $lines = (Get-Content (Join-Path $Script:ScanDir $OutputFile) | Measure-Object -Line).Lines
            Write-Ok "$Description - done  ($OutputFile : $lines lines)"
            Write-Log "SUCCESS $ScriptName -> $OutputFile ($lines lines)"
        } else {
            Write-Ok "$Description - done"
            Write-Log "SUCCESS $ScriptName"
        }
        return $true
    } else {
        Write-Err "$Description - FAILED (exit code $rc)  (see log: $($Script:LogFile))"
        Write-Log "FAILED $ScriptName (rc=$rc)"
        return $false
    }
}

# =============================================================================
# SCRIPT SELECTION
# =============================================================================
function Select-Scripts {
    Write-Host ""
    Write-Host "Available scripts:"
    Write-Host "  1  Running processes             (binaries_used.csv)"
    Write-Host "  2  Binaries on disk              (binaries_at_disk.csv)"
    Write-Host "  3  System libraries              (library.csv)"
    Write-Host "  4  Kernel modules                (kernel_modules.csv)  [Linux-only: reports nothing on Windows]"
    Write-Host "  5  Certificates and keys         (crypto_cert_key.csv)  [slow: full C:\ walk]"
    Write-Host "  6  Executable scripts            (exec_script.csv)      [slow: full C:\ walk]"
    Write-Host "  7  Web application directories   (web_app.csv)"
    Write-Host "  8  Live network connections      (network_app.csv)"
    Write-Host "  9  Network protocol scan         (needs sslscan + target host file)"
    Write-Host "  d  Network discovery via nmap    (needs CIDR range)"
    Write-Host ""
    Write-Host "  all = run everything"
    Write-Host "  Comma-separated or range, e.g.:  all   1-4   1,3,7   1-8,d   9,d"
    Write-Host ""

    while ($true) {
        Write-Host -NoNewline "  Select: "
        $raw = (Read-Host).Trim() -replace ' ', ''
        if ([string]::IsNullOrEmpty($raw)) { Write-Warn "No input. Try again."; continue }

        $Script:SelectedScripts = @()
        $ok = $true

        if ($raw -ieq "all") {
            $Script:SelectedScripts = @("1","2","3","4","5","6","7","8","9","d")
            break
        }

        $tokens = $raw -split ","
        foreach ($token in $tokens) {
            if ($token -match '^([1-9])-([1-9])$') {
                $s = [int]$Matches[1]; $e = [int]$Matches[2]
                if ($s -gt $e) { Write-Warn "Invalid range: $token"; $ok = $false; break }
                for ($i = $s; $i -le $e; $i++) { $Script:SelectedScripts += "$i" }
            } elseif ($token -match '^[1-9]$') {
                $Script:SelectedScripts += $token
            } elseif ($token -ieq "d") {
                $Script:SelectedScripts += "d"
            } else {
                Write-Warn "Unknown selection: $token"; $ok = $false; break
            }
        }

        if ($ok -and $Script:SelectedScripts.Count -gt 0) { break }
        Write-Warn "Invalid selection, try again."
        $Script:SelectedScripts = @()
    }

    Write-Host ""
    Write-Host -NoNewline "  Will run:"
    foreach ($s in $Script:SelectedScripts) { Write-Host -NoNewline " $s" }
    Write-Host ""
}

# =============================================================================
# FINAL SUMMARY
# =============================================================================
function Write-Summary {
    param([int]$PassCount = 0, [int]$FailCount = 0)

    Write-Header "Scan Summary"
    Write-Host ""
    Write-Host "Output files in: $($Script:ScanDir)" -ForegroundColor White
    Write-Host ""

    $outputFiles = @(
        "binaries_used.csv",
        "binaries_at_disk.csv",
        "library.csv",
        "kernel_modules.csv",
        "crypto_cert_key.csv",
        "exec_script.csv",
        "web_app.csv",
        "network_app.csv",
        "scan_results.json",
        "DISCOVERY_results.csv"
    )

    foreach ($f in $outputFiles) {
        $full = Join-Path $Script:ScanDir $f
        if (Test-Path $full) {
            $bytes   = (Get-Item $full).Length
            $sizeStr = if ($bytes -gt 1MB)   { "{0:N1} MB" -f ($bytes / 1MB) }
                       elseif ($bytes -gt 1KB) { "{0:N1} KB" -f ($bytes / 1KB) }
                       else                    { "$bytes B" }
            Write-Ok "  $f  ($sizeStr)"
        }
    }

    # Script 9 result directory
    if ($Script:ResultDir -and (Test-Path $Script:ResultDir)) {
        $combined = Join-Path $Script:ResultDir "combined_results.json"
        if (Test-Path $combined) {
            $bytes   = (Get-Item $combined).Length
            $sizeStr = if ($bytes -gt 1KB) { "{0:N1} KB" -f ($bytes / 1KB) } else { "$bytes B" }
            Write-Ok "  result\combined_results.json  ($sizeStr)"
        }
        $nTargets = (Get-ChildItem $Script:ResultDir -Directory -ErrorAction SilentlyContinue |
                     Measure-Object).Count
        if ($nTargets -gt 0) {
            Write-Ok "  result\  ($nTargets per-target directories)"
        }
    }

    Write-Host ""
    Write-Host "Result: " -NoNewline
    Write-Host "$PassCount succeeded  " -ForegroundColor Green -NoNewline
    Write-Host "$FailCount failed"      -ForegroundColor Red
    Write-Host ""
    Write-Info "Full log: $($Script:LogFile)"
    Write-Host ""
    Write-Log "=== pqccheck.ps1 finished — PASS=$PassCount FAIL=$FailCount ==="
}

# =============================================================================
# MAIN
# =============================================================================
function Main {
    Show-Banner

    Write-Host "PRODUCTION SAFETY NOTICE"
    Write-Host "  Read-only scans. No application files are modified."
    Write-Host "  Scripts 5 and 6: full C:\ filesystem walk — high disk I/O."
    Write-Host "  Script 9 and d (DISCOVERY): active network probing — authorization required."
    Write-Host ""
    Write-Host -NoNewline "  Continue? [Y/n]: "
    $ack = Read-Host
    if ($ack -match '^[nN]') { Write-Host "Aborted."; exit 0 }
    Write-Host ""

    # ------------------------------------------------------------------
    # Phase 0 — Admin check + repo bootstrap
    # ------------------------------------------------------------------
    Invoke-CheckAdmin
    Invoke-EnsureRepo   # sets $Script:RepoDir; may restart script if cloning

    # Finalise paths now that RepoDir is known
    $Script:VenvDir = Join-Path $Script:RepoDir ".venv"
    $Script:LogFile = Join-Path $Script:RepoDir "pqccheck_$($Script:Timestamp).log"
    $Script:ScanDir = Join-Path $Script:RepoDir "scan_$($Script:Timestamp)"
    $null = New-Item -ItemType Directory -Force $Script:ScanDir

    Write-Host "  Repo  : $($Script:RepoDir)"
    Write-Host "  Output: $($Script:ScanDir)"
    Write-Host "  Log   : $($Script:LogFile)"
    Write-Host "  Time  : $(Get-Date)"
    Write-Host ""
    Write-Log "=== pqccheck.ps1 started ==="
    Write-Log "REPO_DIR=$($Script:RepoDir)"

    # ------------------------------------------------------------------
    # Phase 1 — Update check
    # ------------------------------------------------------------------
    Invoke-CheckForUpdates

    # ------------------------------------------------------------------
    # Phase 2 — Dependencies
    # ------------------------------------------------------------------
    Invoke-CheckInstalledSoftware
    Invoke-SetupPythonEnv
    Invoke-CheckSystemTools
    Invoke-CheckPythonPackages

    # ------------------------------------------------------------------
    # Phase 3 — Script selection
    # ------------------------------------------------------------------
    Select-Scripts

    # ------------------------------------------------------------------
    # Phase 4 — Run selected scripts
    # ------------------------------------------------------------------
    $pass = 0
    $fail = 0

    foreach ($scriptId in $Script:SelectedScripts) {
        switch ($scriptId) {

            # ----------------------------------------------------------
            # Script 1 — Running processes
            # Two patches applied to 1BinariesUsed.py:
            #   Patch 1: add an early-return in classify_libraries() when
            #            running on Windows so that the ldd subprocess call
            #            is never reached (FileNotFoundError on Windows).
            #   Patch 2: safe call-site fallback in case classify_libraries()
            #            returns None (static binaries on Linux, or after the
            #            Windows early-return from Patch 1).
            # ----------------------------------------------------------
            "1" {
                $s1Src     = Join-Path $Script:RepoDir "1BinariesUsed.py"
                $s1Tmp     = [System.IO.Path]::GetTempFileName()  # .tmp extension is fine for Python
                $patcherTmp = [System.IO.Path]::GetTempFileName()

                $patcherContent = @'
import sys, re
src_path, dst_path = sys.argv[1], sys.argv[2]
with open(src_path, encoding='utf-8') as fh:
    src = fh.read()
# Patch 1: insert Windows early-return at the top of classify_libraries()
# so the ldd subprocess call is never reached on Windows.
patched = re.sub(
    r'(def classify_libraries\([^)]*\)\s*:\s*\n)',
    lambda m: m.group(1) + '    import platform\n    if platform.system() == "Windows": return None\n',
    src
)
# Patch 2: safe call-site fallback — handle None return (Windows early-return
# above, or static binaries on Linux where ldd produces no output).
patched = re.sub(
    r'[ \t]*(third_party\s*,\s*system\s*=\s*classify_libraries\(binary\))',
    lambda m: m.group(0).replace(
        m.group(1),
        '_cl=classify_libraries(binary); third_party,system=_cl if _cl is not None else ([],[])'
    ),
    patched
)
with open(dst_path, 'w', encoding='utf-8') as fh:
    fh.write(patched)
'@
                [System.IO.File]::WriteAllText($patcherTmp, $patcherContent, $Script:Utf8NoBom)

                & $Script:Python $patcherTmp $s1Src $s1Tmp 2>>$Script:LogFile
                Remove-Item $patcherTmp -Force -ErrorAction SilentlyContinue
                Write-Log "Patched 1BinariesUsed.py -> $s1Tmp (Windows ldd fix + None call-site fallback)"

                Write-Sep
                Write-Info "Starting : Running processes"
                Write-Info "Script   : 1BinariesUsed.py (patched for environments without ldd)"
                Write-Info "Output   : binaries_used.csv"
                Write-Host ""
                Write-Log "START 1BinariesUsed.py"

                Push-Location $Script:ScanDir
                & $Script:Python $s1Tmp 2>&1 | Tee-Object -Append -FilePath $Script:LogFile | Out-Host
                $s1rc = $LASTEXITCODE
                Pop-Location
                Remove-Item $s1Tmp -Force -ErrorAction SilentlyContinue

                Write-Host ""
                if ($s1rc -eq 0) {
                    $csvPath = Join-Path $Script:ScanDir "binaries_used.csv"
                    if (Test-Path $csvPath) {
                        $lines = (Get-Content $csvPath | Measure-Object -Line).Lines
                        Write-Ok "Running processes - done  (binaries_used.csv: $lines lines)"
                        Write-Log "SUCCESS 1BinariesUsed.py -> binaries_used.csv ($lines lines)"
                    } else {
                        Write-Ok "Running processes - done"
                        Write-Log "SUCCESS 1BinariesUsed.py"
                    }
                    $pass++
                } else {
                    Write-Err "Running processes - FAILED (see log)"
                    Write-Log "FAILED 1BinariesUsed.py (rc=$s1rc)"
                    $fail++
                }
            }

            # ----------------------------------------------------------
            # Script 2 — Binaries on disk
            # 2BinariesDisk.py has built-in Windows detection (detect_os())
            # and walks appropriate paths for both Linux and Windows.
            # ----------------------------------------------------------
            "2" {
                if (Invoke-RunPythonScript "2BinariesDisk.py" "Binaries on disk" "binaries_at_disk.csv") {
                    $pass++
                } else { $fail++ }
            }

            # ----------------------------------------------------------
            # Script 3 — System libraries
            # 3Libraries.py has built-in Windows detection and uses
            # appropriate library paths per OS.
            # ----------------------------------------------------------
            "3" {
                if (Invoke-RunPythonScript "3Libraries.py" "System libraries" "library.csv") {
                    $pass++
                } else { $fail++ }
            }

            # ----------------------------------------------------------
            # Script 4 — Kernel modules
            # 4Kernel_mod.py has OS detection built in. On Windows it
            # detects the OS, finds no kernel modules, and exits cleanly.
            # No patching needed; the script handles this gracefully.
            # ----------------------------------------------------------
            "4" {
                Write-Sep
                Write-Info "Starting : Kernel modules"
                Write-Info "Script   : 4Kernel_mod.py"
                Write-Info "Note     : Kernel modules are Linux-specific. Script will produce no results on Windows."
                Write-Host ""
                Write-Log "START 4Kernel_mod.py"

                Push-Location $Script:ScanDir
                & $Script:Python (Join-Path $Script:RepoDir "4Kernel_mod.py") 2>&1 |
                    Tee-Object -Append -FilePath $Script:LogFile | Out-Host
                $s4rc = $LASTEXITCODE
                Pop-Location

                Write-Host ""
                if ($s4rc -eq 0) {
                    Write-Ok "Kernel modules - done (no kernel modules on Windows — expected)"
                    Write-Log "SUCCESS 4Kernel_mod.py (Windows: no kernel modules)"
                    $pass++
                } else {
                    Write-Err "Kernel modules - FAILED (see log)"
                    Write-Log "FAILED 4Kernel_mod.py (rc=$s4rc)"
                    $fail++
                }
            }

            # ----------------------------------------------------------
            # Script 5 — Certificates and keys  (full C:\ walk — slow)
            # 5CertKeys.py detects Windows and scans from C:\ by default.
            # Patched: cryptography >= 42 deprecated cert.not_valid_before and
            # cert.not_valid_after (return naive datetimes) in favour of
            # cert.not_valid_before_utc / cert.not_valid_after_utc.
            # The patch replaces both call sites with a hasattr guard so the
            # same patched file works on both old and new cryptography versions.
            # ----------------------------------------------------------
            "5" {
                Write-Host ""
                Write-Warn "Script 5: full C:\ filesystem walk — high I/O, may take a long time."
                Write-Host -NoNewline "  Continue? [Y/n]: "
                $c5 = Read-Host
                if ($c5 -match '^[nN]') {
                    Write-Skip "Script 5 skipped."
                    Write-Log "5CertKeys.py skipped"
                } else {
                    $s5Src = Join-Path $Script:RepoDir "5CertKeys.py"
                    $s5Tmp = [System.IO.Path]::GetTempFileName()
                    $s5PatcherTmp = [System.IO.Path]::GetTempFileName()

                    $s5PatcherContent = @'
import sys, re
src_path, dst_path = sys.argv[1], sys.argv[2]
with open(src_path, encoding='utf-8') as fh:
    src = fh.read()
# Replace deprecated naive-datetime properties with UTC-aware equivalents.
# The hasattr guard keeps the patched file compatible with older cryptography.
patched = re.sub(
    r'\bcert\.not_valid_before(?!_utc)\b',
    '(cert.not_valid_before_utc if hasattr(cert, "not_valid_before_utc") else cert.not_valid_before)',
    src
)
patched = re.sub(
    r'\bcert\.not_valid_after(?!_utc)\b',
    '(cert.not_valid_after_utc if hasattr(cert, "not_valid_after_utc") else cert.not_valid_after)',
    patched
)
# Replace non-ASCII arrows that crash on Windows cp1252 consoles.
# PYTHONUTF8=1 is set by pqccheck.ps1, but patch defensively in case the
# script is ever run standalone without that env var.
patched = patched.replace('\u2192', '->')
with open(dst_path, 'w', encoding='utf-8') as fh:
    fh.write(patched)
'@
                    [System.IO.File]::WriteAllText($s5PatcherTmp, $s5PatcherContent, $Script:Utf8NoBom)
                    & $Script:Python $s5PatcherTmp $s5Src $s5Tmp 2>>$Script:LogFile
                    Remove-Item $s5PatcherTmp -Force -ErrorAction SilentlyContinue
                    Write-Log "Patched 5CertKeys.py -> $s5Tmp (not_valid_before/after_utc compat fix)"

                    Write-Sep
                    Write-Info "Starting : Certificates and keys"
                    Write-Info "Script   : 5CertKeys.py (patched for cryptography >= 42)"
                    Write-Info "Output   : crypto_cert_key.csv"
                    Write-Host ""
                    Write-Log "START 5CertKeys.py"

                    Push-Location $Script:ScanDir
                    & $Script:Python $s5Tmp 2>&1 | Tee-Object -Append -FilePath $Script:LogFile | Out-Host
                    $s5rc = $LASTEXITCODE
                    Pop-Location
                    Remove-Item $s5Tmp -Force -ErrorAction SilentlyContinue

                    Write-Host ""
                    if ($s5rc -eq 0) {
                        $csvPath = Join-Path $Script:ScanDir "crypto_cert_key.csv"
                        if (Test-Path $csvPath) {
                            $lines = (Get-Content $csvPath | Measure-Object -Line).Lines
                            Write-Ok "Certificates and keys - done  (crypto_cert_key.csv: $lines lines)"
                            Write-Log "SUCCESS 5CertKeys.py -> crypto_cert_key.csv ($lines lines)"
                        } else {
                            Write-Ok "Certificates and keys - done"
                            Write-Log "SUCCESS 5CertKeys.py"
                        }
                        $pass++
                    } else {
                        Write-Err "Certificates and keys - FAILED (see log)"
                        Write-Log "FAILED 5CertKeys.py (rc=$s5rc)"
                        $fail++
                    }
                }
            }

            # ----------------------------------------------------------
            # Script 6 — Executable scripts  (full filesystem walk — slow)
            # ----------------------------------------------------------
            "6" {
                Write-Host ""
                Write-Warn "Script 6: full filesystem walk — high I/O, may take a long time."
                Write-Host -NoNewline "  Continue? [Y/n]: "
                $c6 = Read-Host
                if ($c6 -match '^[nN]') {
                    Write-Skip "Script 6 skipped."
                    Write-Log "6ExeCodes.py skipped"
                } else {
                    if (Invoke-RunPythonScript "6ExeCodes.py" "Executable scripts" "exec_script.csv") {
                        $pass++
                    } else { $fail++ }
                }
            }

            # ----------------------------------------------------------
            # Script 7 — Web application directories
            # ----------------------------------------------------------
            "7" {
                if (Invoke-RunPythonScript "7Web_App.py" "Web application directories" "web_app.csv") {
                    $pass++
                } else { $fail++ }
            }

            # ----------------------------------------------------------
            # Script 8 — Live network connections
            # 8NetworkApp.py uses psutil which is fully supported on Windows.
            # Patched: datetime.utcnow() is deprecated in Python 3.12+ in favour
            # of datetime.now(timezone.utc). The patch prevents DeprecationWarning
            # from being written to stderr and surfacing as NativeCommandError.
            # ----------------------------------------------------------
            "8" {
                $s8Src = Join-Path $Script:RepoDir "8NetworkApp.py"
                $s8Tmp = [System.IO.Path]::GetTempFileName()
                $s8PatcherTmp = [System.IO.Path]::GetTempFileName()

                $s8PatcherContent = @'
import sys, re
src_path, dst_path = sys.argv[1], sys.argv[2]
with open(src_path, encoding='utf-8') as fh:
    src = fh.read()
# Add timezone to datetime import so datetime.now(timezone.utc) is available
patched = re.sub(
    r'\bfrom datetime import datetime\b',
    'from datetime import datetime, timezone',
    src
)
# Replace deprecated datetime.utcnow() with timezone-aware equivalent
patched = patched.replace('datetime.utcnow()', 'datetime.now(timezone.utc)')
with open(dst_path, 'w', encoding='utf-8') as fh:
    fh.write(patched)
'@
                [System.IO.File]::WriteAllText($s8PatcherTmp, $s8PatcherContent, $Script:Utf8NoBom)
                & $Script:Python $s8PatcherTmp $s8Src $s8Tmp 2>>$Script:LogFile
                Remove-Item $s8PatcherTmp -Force -ErrorAction SilentlyContinue
                Write-Log "Patched 8NetworkApp.py -> $s8Tmp (datetime.utcnow -> datetime.now(timezone.utc))"

                Write-Sep
                Write-Info "Starting : Live network connections"
                Write-Info "Script   : 8NetworkApp.py (patched for Python 3.12+ datetime)"
                Write-Info "Output   : network_app.csv"
                Write-Host ""
                Write-Log "START 8NetworkApp.py"

                Push-Location $Script:ScanDir
                & $Script:Python $s8Tmp 2>&1 | Tee-Object -Append -FilePath $Script:LogFile | Out-Host
                $s8rc = $LASTEXITCODE
                Pop-Location
                Remove-Item $s8Tmp -Force -ErrorAction SilentlyContinue

                Write-Host ""
                if ($s8rc -eq 0) {
                    $csvPath = Join-Path $Script:ScanDir "network_app.csv"
                    if (Test-Path $csvPath) {
                        $lines = (Get-Content $csvPath | Measure-Object -Line).Lines
                        Write-Ok "Live network connections - done  (network_app.csv: $lines lines)"
                        Write-Log "SUCCESS 8NetworkApp.py -> network_app.csv ($lines lines)"
                    } else {
                        Write-Ok "Live network connections - done"
                        Write-Log "SUCCESS 8NetworkApp.py"
                    }
                    $pass++
                } else {
                    Write-Err "Live network connections - FAILED (see log)"
                    Write-Log "FAILED 8NetworkApp.py (rc=$s8rc)"
                    $fail++
                }
            }

            # ----------------------------------------------------------
            # Script 9 — Network protocol scan (sslscan)
            # Patched: capture_output=True was added in Python 3.7.
            # Replaced with stdout=PIPE, stderr=PIPE for 3.6 compatibility.
            # ----------------------------------------------------------
            "9" {
                Invoke-SetupScript9
                if ($Script:RunScript9) {
                    $null = New-Item -ItemType Directory -Force $Script:ResultDir

                    # Apply capture_output compatibility patch to a temp copy
                    $s9Src = Join-Path $Script:RepoDir "9NetworkProtocol.py"
                    $s9Tmp = [System.IO.Path]::GetTempFileName()
                    $s9Content = (Get-Content $s9Src -Raw -Encoding UTF8) `
                        -replace 'capture_output=True', 'stdout=subprocess.PIPE, stderr=subprocess.PIPE'
                    [System.IO.File]::WriteAllText($s9Tmp, $s9Content, $Script:Utf8NoBom)
                    Write-Log "Patched 9NetworkProtocol.py -> $s9Tmp (capture_output compat fix)"

                    Write-Sep
                    Write-Info "Starting: 9NetworkProtocol.py"
                    Write-Info "Targets : $($Script:TargetFile)"
                    Write-Info "Output  : $($Script:ResultDir)"
                    Write-Host ""
                    Write-Log "START 9NetworkProtocol.py"

                    Push-Location $Script:RepoDir
                    & $Script:Python $s9Tmp "--out-dir=$($Script:ResultDir)" $Script:TargetFile 2>&1 |
                        Tee-Object -Append -FilePath $Script:LogFile | Out-Host
                    $s9rc = $LASTEXITCODE
                    Pop-Location
                    Remove-Item $s9Tmp -Force -ErrorAction SilentlyContinue

                    if ($s9rc -eq 0) {
                        Write-Ok "Network Protocol Scan - done"
                        Write-Log "SUCCESS 9NetworkProtocol.py"
                        $pass++
                    } else {
                        Write-Err "Network Protocol Scan - FAILED (see log)"
                        Write-Log "FAILED 9NetworkProtocol.py (rc=$s9rc)"
                        $fail++
                    }
                }
            }

            # ----------------------------------------------------------
            # Script d — Network discovery (DISCOVERY.py via nmap)
            # DISCOVERY.py contains:  if __name__ == "__main__": scan_network("10.220.27.0/24")
            # The old exec() approach ran the wrapper as __main__, which caused that
            # hardcoded guard to fire — scanning 10.220.27.0/24 before the user's
            # CIDR, wasting time and potentially scanning the wrong network.
            # Fixed: load DISCOVERY.py as a named module via importlib so that
            # __name__ is "DISCOVERY" (not "__main__"), suppressing the guard.
            # Output files are written to $Script:ScanDir (not the repo root).
            # ----------------------------------------------------------
            "d" {
                Invoke-SetupDiscovery
                if ($Script:RunDiscovery) {
                    Write-Sep
                    Write-Info "Starting: DISCOVERY.py"
                    Write-Info "Range   : $($Script:NetworkRange)"
                    Write-Host ""
                    Write-Log "START DISCOVERY.py range=$($Script:NetworkRange)"

                    $wrapperTmp = [System.IO.Path]::GetTempFileName()
                    $wrapperContent = @"
import sys, os, importlib.util
sys.path.insert(0, r'$($Script:RepoDir)')
os.chdir(r'$($Script:ScanDir)')
spec = importlib.util.spec_from_file_location('DISCOVERY', r'$(Join-Path $Script:RepoDir "DISCOVERY.py")')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.scan_network('$($Script:NetworkRange)')
"@
                    [System.IO.File]::WriteAllText($wrapperTmp, $wrapperContent, $Script:Utf8NoBom)

                    Push-Location $Script:RepoDir
                    & $Script:Python $wrapperTmp 2>&1 |
                        Tee-Object -Append -FilePath $Script:LogFile | Out-Host
                    $drc = $LASTEXITCODE
                    Pop-Location
                    Remove-Item $wrapperTmp -Force -ErrorAction SilentlyContinue

                    if ($drc -eq 0) {
                        Write-Ok "Network Discovery - done"
                        Write-Log "SUCCESS DISCOVERY.py"
                        $pass++
                    } else {
                        Write-Err "Network Discovery - FAILED (see log)"
                        Write-Log "FAILED DISCOVERY.py (rc=$drc)"
                        $fail++
                    }
                }
            }
        }
    }

    # ------------------------------------------------------------------
    # Phase 5 — Summary
    # ------------------------------------------------------------------
    Write-Sep
    Write-Summary $pass $fail
}

# =============================================================================
# Entry point
# =============================================================================
Main
Read-Host "`nDone. Press Enter to exit"

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
    Add-Content -Path $Script:LogFile -Value $line -ErrorAction SilentlyContinue
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
                Write-Err "winget is not available. Please install Git for Windows manually."
                Write-Err "  https://git-scm.com/download/win"
                exit 1
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
            Write-Ok "Repository is already up to date ($short)."
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
                Write-Err "winget not available. Install Python 3 manually from https://www.python.org/downloads/"
                exit 1
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

    if (-not (Test-Path $Script:VenvDir)) {
        Write-Info "Creating virtual environment at $($Script:VenvDir)..."
        & $pythonExe @pythonArgs -m venv $Script:VenvDir 2>>$Script:LogFile
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Could not create virtual environment. Exiting."
            exit 1
        }
        Write-Ok "Virtual environment created."
    } else {
        Write-Ok "Existing virtual environment: $($Script:VenvDir)"
    }

    $Script:Python = Join-Path $Script:VenvDir "Scripts\python.exe"
    $Script:Pip    = Join-Path $Script:VenvDir "Scripts\pip.exe"

    if (-not (Test-Path $Script:Python)) {
        Write-Err "Virtual environment Python not found: $($Script:Python)"
        exit 1
    }

    $venvVer = & $Script:Python --version 2>&1
    Write-Ok "Python : $($Script:Python) ($venvVer)"

    # Upgrade pip inside the venv
    Write-Info "Upgrading pip inside virtual environment..."
    & $Script:Python -m pip install --upgrade pip --quiet 2>>$Script:LogFile
    if ($LASTEXITCODE -eq 0) {
        $pipVer = & $Script:Pip --version 2>&1
        Write-Ok "pip upgraded: $pipVer"
    } else {
        Write-Warn "pip upgrade failed — continuing with current version."
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
        # If nothing changed since last run, skip reinstall
        if (-not $Script:Updated) {
            $allOk = $true
            foreach ($pkg in $Script:RequiredPackages) {
                $importName = if ($pkg -eq "python-nmap") { "nmap" } else { $pkg }
                & $Script:Python -c "import $importName" 2>$null
                if ($LASTEXITCODE -ne 0) { $allOk = $false; break }
            }
            if ($allOk) {
                Write-Ok "All required packages already installed in virtual environment."
                Write-Log "All packages present"
                return
            }
        }

        # Pin older versions for Python <= 3.6 (modern cryptography requires Rust)
        $pyMinor = [int](& $Script:Python -c "import sys; print(sys.version_info.minor)" 2>$null)
        $pyMajor = [int](& $Script:Python -c "import sys; print(sys.version_info.major)" 2>$null)

        $installList = @()
        foreach ($pkg in $Script:RequiredPackages) {
            if ($pyMajor -eq 3 -and $pyMinor -le 6) {
                switch ($pkg) {
                    "cryptography" { $installList += "cryptography==3.3.2" }
                    "psutil"       { $installList += "psutil==5.8.0"        }
                    default        { $installList += $pkg                   }
                }
            } else {
                $installList += $pkg
            }
        }

        Write-Info "Installing packages into virtual environment..."
        $failCount = 0
        foreach ($pkg in $installList) {
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

        if ($failCount -eq 0) { Write-Ok "All packages installed." }
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
                    Write-Warn "Could not install nmap automatically."
                    Write-Warn "Download the Windows installer from: https://nmap.org/download.html"
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
            $hosts | Set-Content -Path $Script:TargetFile -Encoding UTF8
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
            # Patched: classify_libraries() returns None when ldd is absent
            # (static binaries on Linux, or no ldd at all on Windows).
            # The patch replaces the bare tuple-unpack with a safe fallback
            # so the scan continues rather than crashing with TypeError.
            # ----------------------------------------------------------
            "1" {
                $s1Src     = Join-Path $Script:RepoDir "1BinariesUsed.py"
                $s1Tmp     = [System.IO.Path]::GetTempFileName()  # .tmp extension is fine for Python
                $patcherTmp = [System.IO.Path]::GetTempFileName()

                @'
import sys, re
src_path, dst_path = sys.argv[1], sys.argv[2]
with open(src_path) as fh:
    src = fh.read()
patched = re.sub(
    r'[ \t]*(third_party\s*,\s*system\s*=\s*classify_libraries\(binary\))',
    lambda m: m.group(0).replace(
        m.group(1),
        '_cl=classify_libraries(binary); third_party,system=_cl if _cl is not None else ([],[])'
    ),
    src
)
with open(dst_path, 'w') as fh:
    fh.write(patched)
'@ | Set-Content $patcherTmp -Encoding UTF8

                & $Script:Python $patcherTmp $s1Src $s1Tmp 2>>$Script:LogFile
                Remove-Item $patcherTmp -Force -ErrorAction SilentlyContinue
                Write-Log "Patched 1BinariesUsed.py -> $s1Tmp (static binary / no-ldd None crash fix)"

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
                    if (Invoke-RunPythonScript "5CertKeys.py" "Certificates and keys" "crypto_cert_key.csv") {
                        $pass++
                    } else { $fail++ }
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
            # ----------------------------------------------------------
            "8" {
                if (Invoke-RunPythonScript "8NetworkApp.py" "Live network connections" "network_app.csv") {
                    $pass++
                } else { $fail++ }
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
                    (Get-Content $s9Src -Raw) `
                        -replace 'capture_output=True', 'stdout=subprocess.PIPE, stderr=subprocess.PIPE' |
                        Set-Content $s9Tmp -Encoding UTF8
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
            # A small wrapper script is written to a temp file so that
            # scan_network() receives the user-supplied CIDR range.
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
                    @"
import sys, os
sys.path.insert(0, r'$($Script:RepoDir)')
os.chdir(r'$($Script:RepoDir)')
exec(open(r'$(Join-Path $Script:RepoDir "DISCOVERY.py")').read())
scan_network('$($Script:NetworkRange)')
"@ | Set-Content $wrapperTmp -Encoding UTF8

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

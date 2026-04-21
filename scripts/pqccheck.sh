#!/usr/bin/env bash
# =============================================================================
# pqccheck.sh — CBOM-scanning Automation Script
#
# SELF-BOOTSTRAPPING: copy this file anywhere, chmod +x, and run it.
# It will clone the CBOM-scanning repo if needed, create a virtual environment,
# install all dependencies, then run every scan script automatically.
#
# Usage:
#   chmod +x pqccheck.sh && ./pqccheck.sh
# =============================================================================

# Note: pipefail is intentionally NOT set — individual script failures are
# handled explicitly per-call via PIPESTATUS. pipefail would cause the entire
# automation to abort on any non-zero exit from any subcommand in a pipeline.

# =============================================================================
# CONSTANTS
# =============================================================================
REPO_URL="https://github.com/msaufyrohmad/CBOM-scanning.git"
REPO_NAME="CBOM-scanning"
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"

# REPO_DIR is resolved after ensure_repo() — initialise to script's own dir first
INITIAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=""
LOG_FILE=""
VENV_DIR=""

# Real user's home — when running under sudo, use the invoking user's home, not /root
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
fi
REAL_HOME="${REAL_HOME:-$HOME}"

# Global array of scripts selected by the user
SELECTED_SCRIPTS=()
RUN_SCRIPT9=false
RUN_DISCOVERY=false
NETWORK_RANGE=""
TARGET_FILE=""
RESULT_DIR=""
SCAN_DIR=""
PYTHON=""
PIP=""
SUDO_CMD=""

# Known required Python packages (derived from all script imports)
REQUIRED_PACKAGES=("cryptography" "psutil" "python-nmap" "xmltodict")

# =============================================================================
# COLOUR HELPERS
# =============================================================================
if [[ -t 1 ]]; then          # only add colours when attached to a terminal
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

print_header() { echo -e "\n${BOLD}== $1 ==${NC}"; }
print_ok()     { echo -e "${GREEN}[  OK  ]${NC} $1"; }
print_skip()   { echo -e "${CYAN}[ SKIP ]${NC} $1"; }
print_warn()   { echo -e "${YELLOW}[ WARN ]${NC} $1"; }
print_error()  { echo -e "${RED}[ERROR ]${NC} $1"; }
print_info()   { echo -e "${CYAN}[ INFO ]${NC} $1"; }
print_prompt() { echo -en "${BOLD}$1${NC}"; }

log() {
    [[ -z "$LOG_FILE" ]] && return
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    [[ "${2:-}" == "verbose" ]] && echo "$msg"
}

has_cmd() { command -v "$1" &>/dev/null; }

separator() { echo "----------------------------------------------"; }

# =============================================================================
# BANNER
# =============================================================================
show_banner() {
    echo ""
    echo "================================================"
    echo "   Post-Quantum Cryptography Check"
    echo "  CBOM-scanning Automation Script"
    echo "================================================"
    echo ""
}

# =============================================================================
# SUDO DETECTION
# =============================================================================
check_sudo() {
    print_header "Privilege check"

    if [[ $EUID -eq 0 ]]; then
        print_ok "Running as root — sudo not needed."
        SUDO_CMD=""
    elif sudo -n true 2>/dev/null; then
        print_ok "sudo is available (passwordless)."
        SUDO_CMD="sudo"
    else
        print_warn "Not running as root. Some scripts require elevated privileges."
        print_info "Authenticating sudo now to avoid prompts mid-scan:"
        if sudo -v; then
            print_ok "sudo authenticated."
        else
            print_warn "sudo authentication failed — some scans may be incomplete."
        fi
        SUDO_CMD="sudo"
    fi
    log "Privilege check done. SUDO_CMD='${SUDO_CMD}'"
}

# =============================================================================
# REPO BOOTSTRAPPING
# =============================================================================

# Returns 0 if the given directory contains the CBOM-scanning repo files
is_cbom_repo() {
    local dir="${1:-$INITIAL_DIR}"
    [[ -f "${dir}/1BinariesUsed.py" ]] && \
    [[ -f "${dir}/DISCOVERY.py" ]] && \
    [[ -f "${dir}/9NetworkProtocol.py" ]]
}

ensure_repo() {
    print_header "Repository check"

    if is_cbom_repo "$INITIAL_DIR"; then
        REPO_DIR="$INITIAL_DIR"
        print_ok "Running from within the CBOM-scanning repository."
        log "Repo dir: $REPO_DIR"
        return
    fi

    print_warn "CBOM-scanning repository not found in current directory."
    print_info "The repository will be cloned and this script re-launched from within it."
    echo ""

    # Ensure git is available
    if ! has_cmd git; then
        print_warn "git is not installed — required to clone the repository."
        print_prompt "  Install git via the system package manager now? [Y/n]: "
        local git_choice
        read -r git_choice
        case "$git_choice" in
            [nN]*)
                print_error "git is required. Please install it manually and re-run."
                exit 1
                ;;
        esac
        if has_cmd apt-get; then
            ${SUDO_CMD} apt-get install -y git >>/tmp/pqccheck_bootstrap.log 2>&1
        elif has_cmd dnf; then
            ${SUDO_CMD} dnf install -y git >>/tmp/pqccheck_bootstrap.log 2>&1
        elif has_cmd yum; then
            ${SUDO_CMD} yum install -y git >>/tmp/pqccheck_bootstrap.log 2>&1
        fi
        if ! has_cmd git; then
            print_error "git could not be installed. Please install it manually and re-run."
            exit 1
        fi
        print_ok "git installed."
    fi

    # Always clone to the real user's home directory, never to /root
    local clone_dest="${REAL_HOME}/${REPO_NAME}"

    # If the destination exists but isn't the repo, suffix with timestamp to avoid collision
    if [[ -d "$clone_dest" ]] && ! is_cbom_repo "$clone_dest"; then
        clone_dest="${clone_dest}_${TIMESTAMP}"
    fi

    if [[ -d "$clone_dest" ]] && is_cbom_repo "$clone_dest"; then
        print_ok "Found existing repo at: ${clone_dest}"
    else
        print_info "Cloning ${REPO_URL}"
        print_info "  → ${clone_dest}"
        if ! git clone "$REPO_URL" "$clone_dest" 2>&1; then
            print_error "git clone failed. Check your internet connection and re-run."
            exit 1
        fi
        print_ok "Cloned successfully."
    fi

    # Copy this script into the repo so future runs are self-contained
    local dest_script="${clone_dest}/pqccheck.sh"
    cp -f "${BASH_SOURCE[0]}" "$dest_script" 2>/dev/null || \
        cp -f "$0" "$dest_script" 2>/dev/null || true
    chmod +x "$dest_script" 2>/dev/null || true

    echo ""
    print_info "Re-launching from: ${clone_dest}"
    echo ""

    export PQCCHECK_REEXEC=1
    exec bash "$dest_script" "$@"
}

# =============================================================================
# GIT UPDATE CHECK
# =============================================================================
check_for_updates() {
    print_header "Checking for repository updates"

    # Skip update check if we just cloned the repo in this session
    if [[ "${PQCCHECK_REEXEC:-0}" == "1" ]]; then
        print_ok "Repository was just cloned — already up to date."
        log "Update check skipped (just cloned)"
        return
    fi

    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        print_warn "Directory is not a git repository — skipping update check."
        log "Not a git repo, skipping update check"
        return
    fi

    cd "${REPO_DIR}"

    print_info "Fetching from origin…"
    if ! git fetch origin --quiet 2>>"$LOG_FILE"; then
        print_warn "Could not reach the remote. Continuing with local version."
        log "git fetch failed"
        return
    fi

    local LOCAL REMOTE
    LOCAL="$(git rev-parse HEAD 2>/dev/null)"
    REMOTE="$(git rev-parse '@{u}' 2>/dev/null)"

    if [[ -z "$REMOTE" ]]; then
        print_warn "No upstream tracking branch configured — skipping update check."
        log "No upstream tracking branch"
        return
    fi

    if [[ "$LOCAL" == "$REMOTE" ]]; then
        print_ok "Repository is already up to date ($(git rev-parse --short HEAD))."
        log "Repo up to date at $LOCAL"
        return
    fi

    # There are upstream commits
    print_info "New commits are available on the remote:"
    echo ""
    git log HEAD..@{u} --oneline 2>/dev/null | head -20
    echo ""

    print_prompt "  Pull the latest updates? [Y/n]: "
    local choice
    read -r choice
    case "$choice" in
        [nN]*)
            print_skip "Skipping update — continuing with current version."
            log "User declined update"
            ;;
        *)
            print_info "Pulling updates…"
            local branch
            branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
            if git pull origin "$branch" 2>>"$LOG_FILE"; then
                print_ok "Repository updated to $(git rev-parse --short HEAD)."
                UPDATED=true
                log "Repo updated to $(git rev-parse HEAD)"
            else
                print_error "git pull failed. Continuing with current version."
                log "git pull failed"
            fi
            ;;
    esac
}

# =============================================================================
# PYTHON + VIRTUAL ENVIRONMENT SETUP
# =============================================================================
setup_python_env() {
    print_header "Python environment setup"

    # --- Find system python3 ---
    local SYS_PYTHON=""
    if has_cmd python3; then
        SYS_PYTHON="python3"
    elif has_cmd python; then
        local ver
        ver="$(python --version 2>&1)"
        [[ "$ver" == Python\ 3* ]] && SYS_PYTHON="python"
    fi

    if [[ -z "$SYS_PYTHON" ]]; then
        print_warn "Python 3 is not installed on this system."
        print_prompt "  Install python3 and python3-venv via the system package manager? [Y/n]: "
        local py_choice
        read -r py_choice
        case "$py_choice" in
            [nN]*)
                print_error "Python 3 is required. Please install it manually and re-run."
                exit 1
                ;;
        esac
        if has_cmd apt-get; then
            ${SUDO_CMD} apt-get install -y python3 python3-venv python3-pip >>"$LOG_FILE" 2>&1
        elif has_cmd dnf; then
            ${SUDO_CMD} dnf install -y python3 python3-venv python3-pip >>"$LOG_FILE" 2>&1
        elif has_cmd yum; then
            ${SUDO_CMD} yum install -y python3 python3-venv python3-pip >>"$LOG_FILE" 2>&1
        fi
        has_cmd python3 && SYS_PYTHON="python3"
    fi

    if [[ -z "$SYS_PYTHON" ]]; then
        print_error "Python 3 could not be found or installed. Exiting."
        exit 1
    fi
    print_ok "System Python: $SYS_PYTHON ($(${SYS_PYTHON} --version 2>&1))"

    # --- Create virtual environment ---
    # Using a venv avoids the "externally-managed-environment" pip error on
    # Debian/Ubuntu/Kali systems and keeps all packages isolated to this repo.
    VENV_DIR="${REPO_DIR}/.venv"

    if [[ ! -d "$VENV_DIR" ]]; then
        print_info "Creating virtual environment at ${VENV_DIR}…"
        if ! ${SYS_PYTHON} -m venv "$VENV_DIR" 2>>"$LOG_FILE"; then
            # python3-venv may be a separate package on Debian/Ubuntu
            print_warn "venv creation failed — python3-venv may not be installed."
            print_prompt "  Install python3-venv via the system package manager? [Y/n]: "
            local venv_choice
            read -r venv_choice
            case "$venv_choice" in
                [nN]*) print_error "Cannot create virtual environment. Exiting."; exit 1 ;;
            esac
            if has_cmd apt-get; then
                ${SUDO_CMD} apt-get install -y python3-venv >>"$LOG_FILE" 2>&1
            elif has_cmd dnf; then
                ${SUDO_CMD} dnf install -y python3-venv >>"$LOG_FILE" 2>&1
            fi
            if ! ${SYS_PYTHON} -m venv "$VENV_DIR" 2>>"$LOG_FILE"; then
                print_error "Could not create virtual environment. Exiting."
                exit 1
            fi
        fi
        print_ok "Virtual environment created."
    else
        print_ok "Existing virtual environment: ${VENV_DIR}"
    fi

    PYTHON="${VENV_DIR}/bin/python3"
    PIP="${VENV_DIR}/bin/pip"
    print_ok "Python : $PYTHON ($(${PYTHON} --version 2>&1))"

    # Upgrade pip inside the venv — safe, isolated, fixes wheel-finding on old pip versions
    print_info "Upgrading pip inside virtual environment..."
    ${PYTHON} -m pip install --upgrade pip --quiet >>"$LOG_FILE" 2>&1 \
        && print_ok "pip upgraded: $($PIP --version 2>&1 | head -1)" \
        || print_warn "pip upgrade failed — continuing with current version"
    log "PYTHON=$PYTHON  PIP=$PIP  VENV=$VENV_DIR"
}

# =============================================================================
# PYTHON PACKAGE INSTALLATION (into venv — no --break-system-packages needed)
# =============================================================================
check_python_packages() {
    print_header "Python package check"
    cd "${REPO_DIR}"

    # Check whether packages are already present (skip on fresh install or after update)
    local all_ok=true
    if [[ "$UPDATED" == "false" ]]; then
        for pkg in "${REQUIRED_PACKAGES[@]}"; do
            local import_name="$pkg"
            [[ "$pkg" == "python-nmap" ]] && import_name="nmap"
            if ! ${PYTHON} -c "import ${import_name}" &>/dev/null 2>&1; then
                all_ok=false
                break
            fi
        done
        if [[ "$all_ok" == "true" ]]; then
            print_ok "All required packages already installed in virtual environment."
            log "All packages present"
            return
        fi
    fi

    # On Python 3.6, modern cryptography requires Rust (unavailable) and psutil wheels
    # may not exist. Pin last-known-good versions for Python <= 3.6.
    local py_minor
    py_minor="$(${PYTHON} -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 99)"
    local py_major
    py_major="$(${PYTHON} -c 'import sys; print(sys.version_info.major)' 2>/dev/null || echo 3)"

    # Build an install list, substituting pinned versions for Python 3.6
    local install_list=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if [[ "$py_major" -eq 3 && "$py_minor" -le 6 ]]; then
            case "$pkg" in
                cryptography) install_list+=("cryptography==3.3.2") ;;
                psutil)        install_list+=("psutil==5.8.0")        ;;
                *)             install_list+=("$pkg")                 ;;
            esac
        else
            install_list+=("$pkg")
        fi
    done

    print_info "Installing packages into virtual environment..."
    local fail_count=0
    for pkg in "${install_list[@]}"; do
        if ${PIP} install "$pkg" --quiet >>"$LOG_FILE" 2>&1; then
            print_ok "  ${pkg}"
            log "Installed $pkg"
        else
            print_warn "  ${pkg}  (failed — some scans may not work)"
            log "Failed to install $pkg"
            (( fail_count++ )) || true
        fi
    done

    if [[ $fail_count -eq 0 ]]; then
        print_ok "All packages installed."
    else
        print_warn "${fail_count} package(s) failed. Check log for details."
    fi
}

# =============================================================================
# SYSTEM TOOL DETECTION + INSTALL
# =============================================================================
check_system_tools() {
    print_header "System tool check"

    # Map: tool_name => package_name (apt / yum)
    declare -A APT_PKG=(
        ["strings"]="binutils"
        ["nm"]="binutils"
        ["ldd"]="libc-bin"
        ["nmap"]="nmap"
        ["sslscan"]="sslscan"
    )
    declare -A YUM_PKG=(
        ["strings"]="binutils"
        ["nm"]="binutils"
        ["ldd"]="glibc"
        ["nmap"]="nmap"
        ["sslscan"]="sslscan"
    )

    local tools=("strings" "nm" "ldd" "nmap" "sslscan")
    local missing=()

    for tool in "${tools[@]}"; do
        if has_cmd "$tool"; then
            print_ok "  $tool"
        else
            print_warn "  $tool  (not found)"
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log "All system tools present"
        return
    fi

    echo ""
    print_warn "Missing tools: ${missing[*]}"
    print_prompt "  Attempt to install missing tools automatically? [Y/n]: "
    local choice
    read -r choice
    case "$choice" in
        [nN]*)
            print_skip "Skipping tool installation. Affected scans may fail."
            log "User declined system tool install"
            return
            ;;
    esac

    # Determine package manager
    local PKG_INSTALL=""
    if has_cmd apt-get; then
        PKG_INSTALL="${SUDO_CMD} apt-get install -y"
    elif has_cmd dnf; then
        PKG_INSTALL="${SUDO_CMD} dnf install -y"
    elif has_cmd yum; then
        PKG_INSTALL="${SUDO_CMD} yum install -y"
    else
        print_warn "No supported package manager (apt/dnf/yum). Please install manually."
        log "No package manager found"
        return
    fi

    # Collect unique package names
    local pkgs=()
    for tool in "${missing[@]}"; do
        local pkg
        if has_cmd apt-get; then
            pkg="${APT_PKG[$tool]:-$tool}"
        else
            pkg="${YUM_PKG[$tool]:-$tool}"
        fi
        # Deduplicate
        local already=false
        for p in "${pkgs[@]}"; do [[ "$p" == "$pkg" ]] && already=true && break; done
        $already || pkgs+=("$pkg")
    done

    print_info "Installing: ${pkgs[*]}"
    if ${PKG_INSTALL} "${pkgs[@]}" >>"$LOG_FILE" 2>&1; then
        print_ok "System tools installed."
        log "System tools installed: ${pkgs[*]}"
    else
        print_warn "Some packages may have failed. Check the log."
        log "System tool install had errors"
    fi
}

# =============================================================================
# INTERACTIVE SETUP — SCRIPT 9 (NetworkProtocol)
# =============================================================================
setup_script9() {
    print_header "Setup: Network Protocol Scan (9NetworkProtocol.py)"
    echo -e "${CYAN}  This script uses sslscan to test TLS/SSL on a list of target hosts.${NC}"
    echo -e "${CYAN}  It produces per-target XML/JSON/PEM files and a combined_results.json.${NC}"
    echo ""

    if ! has_cmd sslscan; then
        print_warn "sslscan is not installed — required by Script 9."
        print_prompt "  Skip Script 9? [Y/n]: "
        local skip_choice
        read -r skip_choice
        case "$skip_choice" in
            [nN]*)
                print_info "Attempting to install sslscan…"
                check_system_tools   # will install if user agrees
                if ! has_cmd sslscan; then
                    print_error "sslscan still not available. Skipping Script 9."
                    log "Script 9 skipped — sslscan unavailable"
                    RUN_SCRIPT9=false
                    return
                fi
                ;;
            *)
                print_skip "Script 9 skipped."
                log "Script 9 skipped by user (no sslscan)"
                RUN_SCRIPT9=false
                return
                ;;
        esac
    fi

    echo ""
    print_warn "Script 9 actively probes TLS/SSL on each target - generates real network traffic."
    print_warn "This may trigger IDS/IPS alerts and appear in server access logs."
    print_warn "Only run with written authorization."
    echo ""
    print_prompt "  Run Script 9? [Y/n]: "
    local run_choice
    read -r run_choice
    case "$run_choice" in
        [nN]*)
            print_skip "Script 9 skipped."
            log "Script 9 skipped by user"
            RUN_SCRIPT9=false
            return
            ;;
    esac

    # Auto-named output directory — assigned here, mkdir happens in main() only if scan runs
    RESULT_DIR="${REPO_DIR}/result_${TIMESTAMP}"

    # ---------- Target file ----------
    echo ""
    echo -e "${CYAN}  A target file lists the hostnames/IPs to scan (one per line).${NC}"
    echo -e "${CYAN}  Example:  uitm.edu.my${NC}"
    echo -e "${CYAN}            upm.edu.my${NC}"
    echo ""

    while true; do
        print_prompt "  Path to target file [press Enter to create a new one]: "
        local input_target
        read -r input_target

        if [[ -z "$input_target" ]]; then
            # Create a new target file interactively
            TARGET_FILE="${REPO_DIR}/target"
            print_info "Creating target file: ${TARGET_FILE}"
            echo -e "${CYAN}  Enter one hostname or IP per line. Enter a blank line when done.${NC}"
            > "$TARGET_FILE"
            while true; do
                print_prompt "    host (blank to finish): "
                local host_entry
                read -r host_entry
                [[ -z "$host_entry" ]] && break
                echo "$host_entry" >> "$TARGET_FILE"
            done

            if [[ ! -s "$TARGET_FILE" ]]; then
                print_warn "No hosts entered. Skipping Script 9."
                log "Script 9 skipped — empty target file"
                RUN_SCRIPT9=false
                return
            fi
            print_ok "Target file saved: ${TARGET_FILE} ($(wc -l < "$TARGET_FILE") hosts)"
            log "Target file created: $TARGET_FILE"
            break

        elif [[ -f "$input_target" ]]; then
            TARGET_FILE="$input_target"
            print_ok "Using target file: ${TARGET_FILE} ($(wc -l < "$TARGET_FILE") hosts)"
            log "Target file set: $TARGET_FILE"
            break

        else
            print_error "File not found: $input_target — please try again."
        fi
    done

    RUN_SCRIPT9=true
}

# =============================================================================
# INTERACTIVE SETUP — DISCOVERY.py
# =============================================================================
setup_discovery() {
    print_header "Setup: Network Discovery Scan (DISCOVERY.py)"
    echo -e "${CYAN}  This script performs an nmap-based network scan to discover hosts and${NC}"
    echo -e "${CYAN}  their open ports/services, outputting scan_results.json and${NC}"
    echo -e "${CYAN}  DISCOVERY_results.csv.${NC}"
    echo ""

    if ! has_cmd nmap; then
        print_warn "nmap is not installed — required by DISCOVERY.py."
        print_prompt "  Skip DISCOVERY scan? [Y/n]: "
        local skip_choice
        read -r skip_choice
        case "$skip_choice" in
            [nN]*)
                print_info "Attempting to install nmap…"
                if has_cmd apt-get; then
                    ${SUDO_CMD} apt-get install -y nmap >>"$LOG_FILE" 2>&1 \
                        && print_ok "nmap installed" || print_warn "nmap install failed"
                elif has_cmd dnf; then
                    ${SUDO_CMD} dnf install -y nmap >>"$LOG_FILE" 2>&1 \
                        && print_ok "nmap installed" || print_warn "nmap install failed"
                elif has_cmd yum; then
                    ${SUDO_CMD} yum install -y nmap >>"$LOG_FILE" 2>&1 \
                        && print_ok "nmap installed" || print_warn "nmap install failed"
                else
                    print_error "No package manager available. Please install nmap manually."
                fi
                if ! has_cmd nmap; then
                    print_error "nmap still unavailable. Skipping DISCOVERY scan."
                    log "DISCOVERY skipped — nmap unavailable"
                    RUN_DISCOVERY=false
                    return
                fi
                ;;
            *)
                print_skip "DISCOVERY scan skipped."
                log "DISCOVERY skipped by user (no nmap)"
                RUN_DISCOVERY=false
                return
                ;;
        esac
    fi

    print_prompt "  Run DISCOVERY network scan? [Y/n]: "
    local run_choice
    read -r run_choice
    case "$run_choice" in
        [nN]*)
            print_skip "DISCOVERY scan skipped."
            log "DISCOVERY skipped by user"
            RUN_DISCOVERY=false
            return
            ;;
    esac

    echo ""
    print_warn "AUTHORIZATION REQUIRED: nmap sends packets to every host in the range."
    print_warn "This generates network traffic and may trigger IDS/IPS alerts."
    print_warn "Only run with written authorization."
    echo ""
    echo "  CIDR range required, e.g.: 192.168.1.0/24 or 10.0.0.0/16"
    echo "  (Requires sudo for SYN scan)"
    echo ""

    while true; do
        print_prompt "  Enter network range to scan: "
        read -r NETWORK_RANGE
        if [[ -z "$NETWORK_RANGE" ]]; then
            print_warn "Network range cannot be empty."
        elif [[ "$NETWORK_RANGE" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
            print_ok "Network range: $NETWORK_RANGE"
            log "DISCOVERY network range: $NETWORK_RANGE"
            RUN_DISCOVERY=true
            break
        else
            print_warn "Invalid format - expected something like 192.168.1.0/24. Please try again."
        fi
    done
}

# =============================================================================
# INDIVIDUAL SCRIPT RUNNER
# =============================================================================
# Returns 0 on success, 1 on failure
run_python_script() {
    local script_name="$1"
    local description="$2"
    local output_file="$3"       # expected output file (for reporting); may be ""
    local extra_args="${4:-}"

    separator
    print_info "Starting : ${description}"
    print_info "Script   : ${script_name}"
    [[ -n "$output_file" ]] && print_info "Output   : ${output_file}"
    echo ""
    log "START $script_name"

    cd "${SCAN_DIR}"
    log "CMD: ${SUDO_CMD:+sudo }${PYTHON} ${script_name} ${extra_args}"

    # Run script, tee stdout+stderr to log, show live output.
    # PIPESTATUS[0] captures the Python process exit code independently from tee.
    local rc=0
    if [[ -n "$SUDO_CMD" ]]; then
        sudo "${PYTHON}" "${REPO_DIR}/${script_name}" ${extra_args} 2>&1 | tee -a "$LOG_FILE"
        rc="${PIPESTATUS[0]}"
    else
        "${PYTHON}" "${REPO_DIR}/${script_name}" ${extra_args} 2>&1 | tee -a "$LOG_FILE"
        rc="${PIPESTATUS[0]}"
    fi

    if [[ "$rc" -eq 0 ]]; then
        echo ""
        if [[ -n "$output_file" && -f "${SCAN_DIR}/${output_file}" ]]; then
            local lines
            lines="$(wc -l < "${SCAN_DIR}/${output_file}" 2>/dev/null || echo '?')"
            print_ok "${description} - done  (${output_file}: ${lines} lines)"
            log "SUCCESS $script_name -> $output_file ($lines lines)"
        else
            print_ok "${description} - done"
            log "SUCCESS $script_name"
        fi
        return 0
    else
        echo ""
        print_error "${description} - FAILED (exit code ${rc}) (see log: ${LOG_FILE})"
        log "FAILED $script_name (rc=$rc)"
        return 1
    fi
}

# =============================================================================
# SCRIPT SELECTION
# =============================================================================
select_scripts() {
    echo ""
    echo "Available scripts:"
    echo "  1  Running processes             (binaries_used.csv)"
    echo "  2  Binaries on disk              (binaries_at_disk.csv)"
    echo "  3  System libraries              (library.csv)"
    echo "  4  Kernel modules                (kernel_modules.csv)"
    echo "  5  Certificates and keys         (crypto_cert_key.csv)  [slow: full filesystem]"
    echo "  6  Executable scripts            (exec_script.csv)      [slow: full filesystem]"
    echo "  7  Web application directories   (web_app.csv)"
    echo "  8  Live network connections      (network_app.csv)"
    echo "  9  Network protocol scan         (needs sslscan + target host file)"
    echo "  d  Network discovery via nmap    (needs CIDR range)"
    echo ""
    echo "  all = run everything"
    echo "  Comma-separated or range, e.g.:  all   1-4   1,3,7   1-8,d   9,d"
    echo ""

    while true; do
        print_prompt "  Select: "
        local raw
        read -r raw
        raw="${raw// /}"
        [[ -z "$raw" ]] && print_warn "No input. Try again." && continue

        SELECTED_SCRIPTS=()
        local ok=true

        if [[ "${raw,,}" == "all" ]]; then
            SELECTED_SCRIPTS=(1 2 3 4 5 6 7 8 9 d)
            break
        fi

        IFS=',' read -ra tokens <<< "$raw"
        for token in "${tokens[@]}"; do
            if [[ "$token" =~ ^([1-9])-([1-9])$ ]]; then
                local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
                if [[ "$s" -gt "$e" ]]; then
                    print_warn "Invalid range: $token"; ok=false; break
                fi
                for (( i=s; i<=e; i++ )); do SELECTED_SCRIPTS+=("$i"); done
            elif [[ "$token" =~ ^[1-9]$ ]]; then
                SELECTED_SCRIPTS+=("$token")
            elif [[ "${token,,}" == "d" ]]; then
                SELECTED_SCRIPTS+=("d")
            else
                print_warn "Unknown: $token"; ok=false; break
            fi
        done

        if [[ "$ok" == "true" && ${#SELECTED_SCRIPTS[@]} -gt 0 ]]; then
            break
        fi
        print_warn "Invalid selection, try again."
        SELECTED_SCRIPTS=()
    done

    echo ""
    echo -n "  Will run:"
    for s in "${SELECTED_SCRIPTS[@]}"; do echo -n " $s"; done
    echo ""
}

# =============================================================================
# FINAL SUMMARY
# =============================================================================
print_summary() {
    local pass_count="${1:-0}"
    local fail_count="${2:-0}"

    print_header "Scan Summary"
    echo ""
    echo -e "${BOLD}Output files in: ${SCAN_DIR}${NC}"
    echo ""

    local output_files=(
        "binaries_used.csv"
        "binaries_at_disk.csv"
        "library.csv"
        "kernel_modules.csv"
        "crypto_cert_key.csv"
        "exec_script.csv"
        "web_app.csv"
        "network_app.csv"
        "scan_results.json"
        "DISCOVERY_results.csv"
    )

    for f in "${output_files[@]}"; do
        local full="${SCAN_DIR}/${f}"
        if [[ -f "$full" ]]; then
            local size
            size="$(du -sh "$full" 2>/dev/null | cut -f1)"
            print_ok "  ${f}  (${size})"
        fi
    done

    # Script 9 result directory
    if [[ -d "$RESULT_DIR" ]]; then
        local combined="${RESULT_DIR}/combined_results.json"
        if [[ -f "$combined" ]]; then
            local size
            size="$(du -sh "$combined" 2>/dev/null | cut -f1)"
            print_ok "  result/combined_results.json  (${size})"
        fi
        local n_targets
        n_targets="$(find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
        [[ "$n_targets" -gt 0 ]] && \
            print_ok "  result/  (${n_targets} per-target directories)"
    fi

    echo ""
    echo -e "${BOLD}Result: ${GREEN}${pass_count} succeeded${NC}  ${RED}${fail_count} failed${NC}"
    echo ""
    print_info "Full log: ${LOG_FILE}"
    echo ""
    log "=== pqccheck.sh finished — PASS=${pass_count} FAIL=${fail_count} ==="
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    show_banner

    echo "PRODUCTION SAFETY NOTICE"
    echo "  Read-only scans. No application files are modified."
    echo "  Scripts 5 and 6: full filesystem walk - high disk I/O."
    echo "  Script 9 and d (DISCOVERY): active network probing - authorization required."
    echo ""
    print_prompt "  Continue? [Y/n]: "
    local ack
    read -r ack
    case "$ack" in
        [nN]*) echo "Aborted."; exit 0 ;;
    esac
    echo ""

    # ------------------------------------------------------------------
    # Phase 0 — Privileges + repo bootstrap (clone if needed, then re-exec)
    # ------------------------------------------------------------------
    check_sudo
    ensure_repo  # sets REPO_DIR; may exec() and never return if cloning

    # --- Finalise paths now that REPO_DIR is known ---
    # RESULT_DIR is set (and created) only inside setup_script9(), if the user
    # actually chooses to run Script 9 with valid targets.
    VENV_DIR="${REPO_DIR}/.venv"
    LOG_FILE="${REPO_DIR}/pqccheck_${TIMESTAMP}.log"
    SCAN_DIR="${REPO_DIR}/scan_${TIMESTAMP}"
    mkdir -p "${SCAN_DIR}"

    echo -e "  Repo  : ${REPO_DIR}"
    echo -e "  Output: ${SCAN_DIR}"
    echo -e "  Log   : ${LOG_FILE}"
    echo -e "  Time  : $(date)"
    echo ""
    log "=== pqccheck.sh started ==="
    log "REPO_DIR=${REPO_DIR}"

    # ------------------------------------------------------------------
    # Phase 1 — Update check
    # ------------------------------------------------------------------
    check_for_updates

    # ------------------------------------------------------------------
    # Phase 2 — Dependencies
    # ------------------------------------------------------------------
    setup_python_env
    check_system_tools
    check_python_packages

    # ------------------------------------------------------------------
    # Phase 3 - Script selection
    # ------------------------------------------------------------------
    select_scripts

    # ------------------------------------------------------------------
    # Phase 4 - Run selected scripts
    # ------------------------------------------------------------------
    local PASS=0 FAIL=0

    for script_id in "${SELECTED_SCRIPTS[@]}"; do
        case "$script_id" in
            1)
                if run_python_script "1BinariesUsed.py" "Running processes" "binaries_used.csv"; then
                    PASS=$(( PASS + 1 ))
                else
                    FAIL=$(( FAIL + 1 ))
                fi
                ;;
            2)
                if run_python_script "2BinariesDisk.py" "Binaries on disk" "binaries_at_disk.csv"; then
                    PASS=$(( PASS + 1 ))
                else
                    FAIL=$(( FAIL + 1 ))
                fi
                ;;
            3)
                if run_python_script "3Libraries.py" "System libraries" "library.csv"; then
                    PASS=$(( PASS + 1 ))
                else
                    FAIL=$(( FAIL + 1 ))
                fi
                ;;
            4)
                local S4_SRC="${REPO_DIR}/4Kernel_mod.py"
                local S4_TMP
                S4_TMP="$(mktemp /tmp/cbom_4kern_XXXXXX.py)"
                # Patch extract_strings to decompress .ko.xz/.ko.gz before running
                # strings.  On RHEL/Oracle Linux 8, kernel modules are XZ-compressed;
                # running strings on a raw .ko.xz file finds nothing readable inside.
                "${PYTHON}" - "$S4_SRC" "$S4_TMP" <<'PATCHER'
import sys, re
src_path, dst_path = sys.argv[1], sys.argv[2]
with open(src_path) as fh:
    src = fh.read()
NEW_FUNC = (
    'def extract_strings(path):\n'
    '    import tempfile as _tf, os as _os, lzma as _lz, gzip as _gz\n'
    '    try:\n'
    '        p = path.lower()\n'
    '        if p.endswith(".ko.xz"):\n'
    '            with _lz.open(path, "rb") as _f:\n'
    '                _d = _f.read()\n'
    '        elif p.endswith(".ko.gz"):\n'
    '            with _gz.open(path, "rb") as _f:\n'
    '                _d = _f.read()\n'
    '        else:\n'
    '            return subprocess.check_output(\n'
    '                ["strings", path], text=True,\n'
    '                errors="ignore", stderr=subprocess.DEVNULL)\n'
    '        _fd, _t = _tf.mkstemp(suffix=".ko")\n'
    '        try:\n'
    '            _os.write(_fd, _d)\n'
    '        finally:\n'
    '            _os.close(_fd)\n'
    '        try:\n'
    '            _r = subprocess.check_output(\n'
    '                ["strings", _t], text=True,\n'
    '                errors="ignore", stderr=subprocess.DEVNULL)\n'
    '        finally:\n'
    '            _os.unlink(_t)\n'
    '        return _r\n'
    '    except Exception:\n'
    '        return ""\n'
)
patched = re.sub(
    r'def extract_strings\(path\):.*?(?=\ndef |\Z)',
    NEW_FUNC, src, count=1, flags=re.DOTALL
)
with open(dst_path, 'w') as fh:
    fh.write(patched)
PATCHER
                chmod 600 "$S4_TMP"
                log "Patched 4Kernel_mod.py -> $S4_TMP (compressed .ko.xz/.ko.gz support)"
                separator
                print_info "Starting : Kernel modules"
                print_info "Script   : 4Kernel_mod.py (patched for compressed modules)"
                print_info "Output   : kernel_modules.csv"
                echo ""
                log "START 4Kernel_mod.py"
                cd "${SCAN_DIR}"
                local s4rc=0
                if [[ -n "$SUDO_CMD" ]]; then
                    sudo "${PYTHON}" "$S4_TMP" 2>&1 | tee -a "$LOG_FILE"
                    s4rc="${PIPESTATUS[0]}"
                else
                    "${PYTHON}" "$S4_TMP" 2>&1 | tee -a "$LOG_FILE"
                    s4rc="${PIPESTATUS[0]}"
                fi
                rm -f "$S4_TMP"
                if [[ "$s4rc" -eq 0 ]]; then
                    echo ""
                    if [[ -f "${SCAN_DIR}/kernel_modules.csv" ]]; then
                        local s4lines
                        s4lines="$(wc -l < "${SCAN_DIR}/kernel_modules.csv" 2>/dev/null || echo '?')"
                        print_ok "Kernel modules - done  (kernel_modules.csv: ${s4lines} lines)"
                        log "SUCCESS 4Kernel_mod.py -> kernel_modules.csv ($s4lines lines)"
                    else
                        print_ok "Kernel modules - done (no crypto matches found in modules)"
                        log "SUCCESS 4Kernel_mod.py (no crypto matches)"
                    fi
                    PASS=$(( PASS + 1 ))
                else
                    print_error "Kernel modules - FAILED (see log)"
                    log "FAILED 4Kernel_mod.py (rc=$s4rc)"
                    FAIL=$(( FAIL + 1 ))
                fi
                ;;
            5)
                echo ""
                print_warn "Script 5: full filesystem walk - high I/O, may take a long time."
                print_prompt "  Continue? [Y/n]: "
                local c5; read -r c5
                case "$c5" in
                    [nN]*) print_skip "Script 5 skipped."; log "5CertKeys.py skipped" ;;
                    *)
                        if run_python_script "5CertKeys.py" "Certificates and keys" "crypto_cert_key.csv"; then
                            PASS=$(( PASS + 1 ))
                        else
                            FAIL=$(( FAIL + 1 ))
                        fi
                        ;;
                esac
                ;;
            6)
                echo ""
                print_warn "Script 6: full filesystem walk - high I/O, may take a long time."
                print_prompt "  Continue? [Y/n]: "
                local c6; read -r c6
                case "$c6" in
                    [nN]*) print_skip "Script 6 skipped."; log "6ExeCodes.py skipped" ;;
                    *)
                        if run_python_script "6ExeCodes.py" "Executable scripts" "exec_script.csv"; then
                            PASS=$(( PASS + 1 ))
                        else
                            FAIL=$(( FAIL + 1 ))
                        fi
                        ;;
                esac
                ;;
            7)
                if run_python_script "7Web_App.py" "Web application directories" "web_app.csv"; then
                    PASS=$(( PASS + 1 ))
                else
                    FAIL=$(( FAIL + 1 ))
                fi
                ;;
            8)
                if run_python_script "8NetworkApp.py" "Live network connections" "network_app.csv"; then
                    PASS=$(( PASS + 1 ))
                else
                    FAIL=$(( FAIL + 1 ))
                fi
                ;;
            9)
                setup_script9
                if [[ "$RUN_SCRIPT9" == "true" ]]; then
                    mkdir -p "${RESULT_DIR}"
                    separator
                    print_info "Starting: 9NetworkProtocol.py"
                    print_info "Targets : ${TARGET_FILE}"
                    print_info "Output  : ${RESULT_DIR}"
                    echo ""
                    log "START 9NetworkProtocol.py"
                    cd "${REPO_DIR}"

                    # Python 3.6 does not support capture_output=True (added in 3.7).
                    # Patch a temporary copy so the original repo file is never modified.
                    local S9_SRC="${REPO_DIR}/9NetworkProtocol.py"
                    local S9_TMP
                    S9_TMP="$(mktemp /tmp/cbom_9net_XXXXXX.py)"
                    sed 's/capture_output=True/stdout=subprocess.PIPE, stderr=subprocess.PIPE/g' \
                        "$S9_SRC" > "$S9_TMP"
                    chmod 600 "$S9_TMP"
                    log "Patched 9NetworkProtocol.py -> $S9_TMP (capture_output compat fix)"

                    local s9rc=0
                    if [[ -n "$SUDO_CMD" ]]; then
                        sudo "${PYTHON}" "$S9_TMP" \
                            "--out-dir=${RESULT_DIR}" "${TARGET_FILE}" 2>&1 | tee -a "$LOG_FILE"
                        s9rc="${PIPESTATUS[0]}"
                    else
                        "${PYTHON}" "$S9_TMP" \
                            "--out-dir=${RESULT_DIR}" "${TARGET_FILE}" 2>&1 | tee -a "$LOG_FILE"
                        s9rc="${PIPESTATUS[0]}"
                    fi
                    rm -f "$S9_TMP"
                    if [[ "$s9rc" -eq 0 ]]; then
                        print_ok "Network Protocol Scan - done"
                        log "SUCCESS 9NetworkProtocol.py"
                        PASS=$(( PASS + 1 ))
                    else
                        print_error "Network Protocol Scan - FAILED (see log)"
                        log "FAILED 9NetworkProtocol.py (rc=$s9rc)"
                        FAIL=$(( FAIL + 1 ))
                    fi
                fi
                ;;
            d)
                setup_discovery
                if [[ "$RUN_DISCOVERY" == "true" ]]; then
                    separator
                    print_info "Starting: DISCOVERY.py"
                    print_info "Range   : ${NETWORK_RANGE}"
                    echo ""
                    log "START DISCOVERY.py range=${NETWORK_RANGE}"
                    cd "${REPO_DIR}"
                    local TMP_WRAPPER
                    TMP_WRAPPER="$(mktemp /tmp/cbom_discovery_XXXXXX.py)"
                    chmod 600 "$TMP_WRAPPER"
                    cat > "$TMP_WRAPPER" << PYEOF
import sys, os
sys.path.insert(0, "${REPO_DIR}")
os.chdir("${REPO_DIR}")
exec(open("${REPO_DIR}/DISCOVERY.py").read())
scan_network("${NETWORK_RANGE}")
PYEOF
                    local drc=0
                    if [[ -n "$SUDO_CMD" ]]; then
                        sudo "${PYTHON}" "$TMP_WRAPPER" 2>&1 | tee -a "$LOG_FILE"
                        drc="${PIPESTATUS[0]}"
                    else
                        "${PYTHON}" "$TMP_WRAPPER" 2>&1 | tee -a "$LOG_FILE"
                        drc="${PIPESTATUS[0]}"
                    fi
                    if [[ "$drc" -eq 0 ]]; then
                        print_ok "Network Discovery - done"
                        log "SUCCESS DISCOVERY.py"
                        PASS=$(( PASS + 1 ))
                    else
                        print_error "Network Discovery - FAILED (see log)"
                        log "FAILED DISCOVERY.py (rc=$drc)"
                        FAIL=$(( FAIL + 1 ))
                    fi
                    rm -f "$TMP_WRAPPER"
                fi
                ;;
        esac
    done

    # ------------------------------------------------------------------
    # Phase 5 - Summary
    # ------------------------------------------------------------------
    separator
    print_summary "$PASS" "$FAIL"
}

# Entry point
main "$@"

#!/usr/bin/env bash
# =============================================================================
# pqclegacy.sh — Pure-bash CBOM scanning for legacy Linux systems
#
# Zero Python dependency. Uses only: strings, nm, ldd, find, grep, awk,
# ss (or netstat), openssl, file, cat, tr, cut, sort, date, uname
#
# Replicates scripts 1–8:
#   1  binaries_used.csv      — running process binaries
#   2  binaries_at_disk.csv   — binaries on disk (PATH)
#   3  library.csv            — system libraries
#   4  kernel_modules.csv     — kernel modules
#   5  crypto_cert_key.csv    — certificates and private keys
#   6  exec_script.csv        — executable scripts with crypto patterns
#   7  web_app.csv            — web application source files
#   8  network_app.csv        — live network connections
#
# Usage:
#   chmod +x pqclegacy.sh && ./pqclegacy.sh
# =============================================================================

set -uo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
SCAN_DIR="$(pwd)/scan_${TIMESTAMP}"
LOG_FILE="${SCAN_DIR}/pqclegacy_${TIMESTAMP}.log"
OS_TYPE="unix"

# =============================================================================
# COLOUR HELPERS
# =============================================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

print_ok()    { echo -e "${GREEN}[  OK  ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[ WARN ]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR ]${NC} $1"; }
print_info()  { echo -e "${CYAN}[ INFO ]${NC} $1"; }
print_skip()  { echo -e "${CYAN}[ SKIP ]${NC} $1"; }
separator()   { echo "----------------------------------------------"; }

has_cmd() { command -v "$1" &>/dev/null; }

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
}

# =============================================================================
# CSV HELPERS
# =============================================================================
# Wrap a value in double-quotes, escaping any internal double-quotes
csv_field() {
    local val="${1:-}"
    # Escape double-quotes by doubling them
    val="${val//\"/\"\"}"
    echo "\"${val}\""
}

# Build a CSV row from all arguments
csv_row() {
    local row=""
    local first=1
    for field in "$@"; do
        [[ $first -eq 0 ]] && row+=","
        row+="$(csv_field "$field")"
        first=0
    done
    echo "$row"
}

# Convert space-separated paths to Python list repr: ['/path1', '/path2']
# Matches Python csv output for modules/libraries and third party libraries columns
format_as_pylist() {
    local input="${1:-}"
    if [[ -z "$input" ]]; then
        echo "[]"
        return
    fi
    local result="[" first=1
    for path in $input; do
        [[ $first -eq 0 ]] && result+=", "
        result+="'${path}'"
        first=0
    done
    echo "${result}]"
}

# Convert OpenSSL date string to ISO 8601
# e.g. "May  5 01:37:37 2011 GMT" → "2011-05-05T01:37:37+00:00"
convert_openssl_date() {
    local ssl_date="${1:-}"
    date -d "$ssl_date" -u '+%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null || echo "$ssl_date"
}

# =============================================================================
# CRYPTO DETECTION ENGINE
# All detection uses strings + nm output lowercased via grep/awk.
# Returns pipe-delimited "primitive|algorithm|key_length|parameters"
# one entry per matched algorithm.
# =============================================================================

# Full algorithm list matching the Python CRYPTO_RULES dictionaries
ALGO_LIST=(
    # name|primitive|key_lengths(space-sep)|modes(space-sep)|curves(space-sep)|proto_versions(space-sep)|deprecated
    "AES|block-cipher|128 192 256|ECB CBC CTR GCM CCM XTS|||"
    "3DES|block-cipher|112 168||||"
    "DES|block-cipher|56||||deprecated"
    "Blowfish|block-cipher|||||"
    "CAST5|block-cipher|||||"
    "CAST6|block-cipher|||||"
    "RC2|block-cipher|||||"
    "RC5|block-cipher|||||"
    "RC6|block-cipher|||||"
    "Twofish|block-cipher|||||"
    "CAMELLIA|block-cipher|||||"
    "Serpent|block-cipher|||||"
    "ARIA|block-cipher|||||"
    "ChaCha|stream-cipher|||||"
    "ChaCha20|stream-cipher|||||"
    "Salsa20|stream-cipher|||||"
    "RABBIT|stream-cipher|||||"
    "SNOW3G|stream-cipher|||||"
    "AES-GCM|aead|||||"
    "CHACHA20-POLY1305|aead|||||"
    "Poly1305|mac|||||"
    "CMAC|mac|||||"
    "HMAC|mac|||||"
    "SHA-1|hash-function||||deprecated"
    "SHA-2|hash-function|||||"
    "SHA-3|hash-function|||||"
    "SHA-256|hash-function|||||"
    "SHA-384|hash-function|||||"
    "SHA-512|hash-function|||||"
    "MD2|hash-function||||deprecated"
    "MD4|hash-function||||deprecated"
    "MD5|hash-function||||deprecated"
    "BLAKE2|hash-function|||||"
    "BLAKE3|hash-function|||||"
    "RIPEMD|hash-function|||||"
    "bcrypt|hash-function|||||"
    "RSAES-PKCS1|public-key-encryption|1024 2048 3072 4096||||"
    "RSAES-OAEP|public-key-encryption|1024 2048 3072 4096||||"
    "RSASSA-PKCS1|digital-signature|||||"
    "RSASSA-PSS|digital-signature|||||"
    "DSA|digital-signature|||||"
    "ECDSA|digital-signature|||P-256 P-384 P-521 secp256k1||"
    "EdDSA|digital-signature|||||"
    "ECIES|key-agreement|||||"
    "ECDH|key-agreement|||P-256 P-384 X25519 X448||"
    "X3DH|key-agreement|||||"
    "FFDH|key-agreement|||||"
    "ElGamal|public-key-encryption|||||"
    "BLS|digital-signature|||||"
    "XMSS|digital-signature|||||"
    "ML-KEM|key-agreement|||||"
    "ML-DSA|digital-signature|||||"
    "PBKDF1|key-derivation|||||"
    "PBKDF2|key-derivation|||||"
    "PBES1|key-derivation|||||"
    "PBES2|key-derivation|||||"
    "PBMAC1|key-derivation|||||"
    "HKDF|key-derivation|||||"
    "SP800-108|key-derivation|||||"
    "KMAC|key-derivation|||||"
    "Fortuna|random-generator|||||"
    "Yarrow|random-generator|||||"
    "TUAK|random-generator|||||"
    "MILENAGE|key-derivation|||||"
    "TLS|tls||||1.0 1.1 1.2 1.3|"
    "SSL|ssl||||2.0 3.0|deprecated"
    "IPSec|ipsec|||||"
    "SSH|ssh||||1.0 2.0|deprecated"
    "IDEA|block-cipher|||||"
    "Skipjack|block-cipher|||||"
    "SEED|block-cipher|||||"
)

CRYPTO_LIBS=("libcrypto" "libssl" "mbedtls" "wolfssl" "boringssl" "libgcrypt" "libsodium" "nettle")

# detect_crypto_in_file <path>
# Prints one line per hit: primitive|algorithm|key_length|parameters|crypto_libs
detect_crypto_in_file() {
    local filepath="$1"
    local strings_out="" nm_out="" ldd_out=""

    if has_cmd strings; then
        strings_out="$(strings "$filepath" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    fi
    if has_cmd nm; then
        nm_out="$(nm -D "$filepath" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    fi
    if has_cmd ldd; then
        ldd_out="$(ldd "$filepath" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    fi

    # Determine which crypto libs are present
    local found_libs=""
    for lib in "${CRYPTO_LIBS[@]}"; do
        if echo "$ldd_out" | grep -q "${lib}"; then
            found_libs+="${lib},"
        fi
    done
    found_libs="${found_libs%,}"

    local any_hit=false
    for entry in "${ALGO_LIST[@]}"; do
        IFS='|' read -r algo_name primitive key_lengths modes curves proto_versions deprecated <<< "$entry"
        local algo_lower
        algo_lower="$(echo "$algo_name" | tr '[:upper:]' '[:lower:]')"

        # Check strings or nm output for the algo name (substring match, same as Python's 'in' operator)
        if ! echo "$strings_out" | grep -q "$algo_lower" && \
           ! echo "$nm_out"     | grep -q "$algo_lower"; then
            continue
        fi

        any_hit=true
        local key_len="unknown"
        local params="none"
        local param_parts=()

        # Key length detection
        if [[ -n "$key_lengths" ]]; then
            for kl in $key_lengths; do
                if echo "$strings_out" | grep -q "$kl"; then
                    key_len="$kl"
                    break
                fi
            done
        fi

        # Mode detection
        if [[ -n "$modes" ]]; then
            for mode in $modes; do
                local mode_lower
                mode_lower="$(echo "$mode" | tr '[:upper:]' '[:lower:]')"
                if echo "$strings_out" | grep -q "$mode_lower"; then
                    param_parts+=("mode=${mode}")
                    break
                fi
            done
        fi

        # Curve detection
        if [[ -n "$curves" ]]; then
            for curve in $curves; do
                local curve_lower
                curve_lower="$(echo "$curve" | tr '[:upper:]' '[:lower:]')"
                if echo "$strings_out" | grep -q "$curve_lower"; then
                    param_parts+=("curve=${curve}")
                    break
                fi
            done
        fi

        # Protocol version detection
        if [[ -n "$proto_versions" ]]; then
            for ver in $proto_versions; do
                if echo "$strings_out" | grep -q "$ver"; then
                    param_parts+=("version=${ver}")
                    break
                fi
            done
        fi

        if [[ ${#param_parts[@]} -gt 0 ]]; then
            params="$(IFS='; '; echo "${param_parts[*]}")"
        fi

        # Emit: primitive|algorithm|key_length|parameters|crypto_libs
        echo "${primitive}|${algo_name}|${key_len}|${params}|${found_libs}"
    done

    # If nothing matched but it has crypto libs, emit a placeholder
    if [[ "$any_hit" == "false" && -n "$found_libs" ]]; then
        echo "unknown|unknown|unknown|none|${found_libs}"
    fi
}

# get_ldd_libs <binary>
# Returns two pipe-separated fields: "system_libs|third_party_libs"
get_ldd_libs() {
    local binary="$1"
    local sys_libs="" third_libs=""

    if ! has_cmd ldd; then
        echo "|"
        return
    fi

    local ldd_out
    ldd_out="$(ldd "$binary" 2>/dev/null)"

    while IFS= read -r line; do
        if echo "$line" | grep -q "=>"; then
            local lib_path
            lib_path="$(echo "$line" | awk -F'=>' '{print $2}' | awk '{print $1}' | tr -d ' ')"
            [[ -z "$lib_path" || "$lib_path" == "not" ]] && continue

            if echo "$lib_path" | grep -qE '^/(lib|lib64|usr/lib|usr/lib64)/' && \
               ! echo "$lib_path" | grep -q '/usr/local/lib'; then
                sys_libs+="${lib_path} "
            else
                third_libs+="${lib_path} "
            fi
        fi
    done <<< "$ldd_out"

    echo "${sys_libs%' '}|${third_libs%' '}"
}

# guess_language <binary>
# Returns a language string based on strings output signatures
guess_language() {
    local binary="$1"
    local sig_out
    sig_out="$(strings "$binary" 2>/dev/null)"

    if echo "$sig_out" | grep -q "go.runtime\|runtime.gopanic"; then
        echo "Go"; return
    fi
    if echo "$sig_out" | grep -q "rustc/\|rust_panic"; then
        echo "Rust"; return
    fi
    if echo "$sig_out" | grep -q "py_runmain\|PyZipFile\|_PYI"; then
        echo "Python"; return
    fi
    if echo "$sig_out" | grep -q "GLIBCXX\|std::"; then
        echo "C++"; return
    fi
    if echo "$sig_out" | grep -q "JNI_CreateJavaVM\|java/lang/Object"; then
        echo "Java"; return
    fi
    echo "C"
}

# check_binary_state <binary>
# Returns: "IN USE (PID ...)" | "AT REST"
check_binary_state() {
    local binary="$1"
    local abs_path
    abs_path="$(readlink -f "$binary" 2>/dev/null || echo "$binary")"

    # Check /proc for a running process with this exe
    for pid_dir in /proc/[0-9]*/; do
        local pid_exe
        pid_exe="$(readlink -f "${pid_dir}exe" 2>/dev/null)"
        if [[ "$pid_exe" == "$abs_path" ]]; then
            local pid
            pid="$(basename "$pid_dir")"
            echo "IN USE (PID ${pid})"
            return
        fi
    done
    echo "AT REST"
}

# =============================================================================
# SCRIPT 1 — binaries_used.csv
# Running process binaries (from /proc)
# =============================================================================
scan_1_binaries_used() {
    local outfile="${SCAN_DIR}/binaries_used.csv"
    separator
    print_info "Script 1: Running process binaries → binaries_used.csv"
    log "START scan_1_binaries_used"

    {
        csv_row "binary" "os_type" "language" "modules/libraries" "third party libraries" \
                "primitive" "algorithm" "crypto_library" "key_length" "parameters"
    } > "$outfile"

    local count=0
    local written=0

    # Collect unique exe paths from /proc
    local -A seen_binaries
    for pid_dir in /proc/[0-9]*/; do
        local exe
        exe="$(readlink -f "${pid_dir}exe" 2>/dev/null)" || continue
        [[ -z "$exe" || ! -f "$exe" ]] && continue
        [[ -n "${seen_binaries[$exe]+_}" ]] && continue
        seen_binaries["$exe"]=1

        (( count++ ))
        echo "  [${count}] ${exe}"

        local lang
        lang="$(guess_language "$exe")"

        local lib_info
        lib_info="$(get_ldd_libs "$exe")"
        local sys_libs third_libs sys_libs_fmt third_libs_fmt
        sys_libs="$(echo "$lib_info" | cut -d'|' -f1)"
        third_libs="$(echo "$lib_info" | cut -d'|' -f2)"
        sys_libs_fmt="$(format_as_pylist "$sys_libs")"
        third_libs_fmt="$(format_as_pylist "$third_libs")"

        # Check crypto libs presence
        local ldd_out
        ldd_out="$(ldd "$exe" 2>/dev/null | tr '[:lower:]' '[:lower:]')"
        local found_crypto_libs=""
        for lib in "${CRYPTO_LIBS[@]}"; do
            if echo "$ldd_out" | grep -q "$lib"; then
                found_crypto_libs+="${lib},"
            fi
        done
        found_crypto_libs="${found_crypto_libs%,}"

        if [[ -z "$found_crypto_libs" ]]; then
            continue   # Python script also skips if libs == "none"
        fi

        local hits=0
        while IFS='|' read -r primitive algorithm key_len params crypto_libs; do
            [[ -z "$primitive" ]] && continue
            csv_row "$exe" "$OS_TYPE" "$lang" "$sys_libs_fmt" "$third_libs_fmt" \
                    "$primitive" "$algorithm" "$crypto_libs" "$key_len" "$params" >> "$outfile"
            (( hits++ )) || true
            (( written++ )) || true
        done < <(detect_crypto_in_file "$exe")

        # If we had crypto libs but no hits, write one unknown row
        if [[ $hits -eq 0 ]]; then
            csv_row "$exe" "$OS_TYPE" "$lang" "$sys_libs_fmt" "$third_libs_fmt" \
                    "unknown" "unknown" "$found_crypto_libs" "unknown" "none" >> "$outfile"
            (( written++ )) || true
        fi
    done

    print_ok "Script 1 complete — ${count} binaries scanned, ${written} rows written"
    log "SUCCESS scan_1_binaries_used — ${written} rows"
}

# =============================================================================
# SCRIPT 2 — binaries_at_disk.csv
# Binaries on disk (found in $PATH directories)
# =============================================================================
scan_2_binaries_disk() {
    local outfile="${SCAN_DIR}/binaries_at_disk.csv"
    separator
    print_info "Script 2: Binaries on disk (PATH) → binaries_at_disk.csv"
    log "START scan_2_binaries_disk"

    {
        csv_row "binary" "os_type" "language" "modules/libraries" "third party libraries" \
                "primitive" "algorithm" "crypto_library" "key_length" "parameters"
    } > "$outfile"

    local count=0
    local written=0

    # Build sorted unique list of executables found in PATH dirs
    local -A seen
    local IFS_BAK="$IFS"
    IFS=':'
    for dir in $PATH; do
        IFS="$IFS_BAK"
        [[ ! -d "$dir" ]] && continue
        while IFS= read -r -d '' exe; do
            [[ -x "$exe" && -f "$exe" ]] || continue
            local real_exe
            real_exe="$(readlink -f "$exe" 2>/dev/null || echo "$exe")"
            [[ -n "${seen[$real_exe]+_}" ]] && continue
            seen["$real_exe"]=1

            (( count++ ))
            echo "  [${count}] ${real_exe}"

            local lang
            lang="$(guess_language "$real_exe")"

            local lib_info
            lib_info="$(get_ldd_libs "$real_exe")"
            local sys_libs third_libs sys_libs_fmt third_libs_fmt
            sys_libs="$(echo "$lib_info" | cut -d'|' -f1)"
            third_libs="$(echo "$lib_info" | cut -d'|' -f2)"
            sys_libs_fmt="$(format_as_pylist "$sys_libs")"
            third_libs_fmt="$(format_as_pylist "$third_libs")"

            local ldd_out
            ldd_out="$(ldd "$real_exe" 2>/dev/null)"
            local found_crypto_libs=""
            for lib in "${CRYPTO_LIBS[@]}"; do
                if echo "$ldd_out" | grep -qi "$lib"; then
                    found_crypto_libs+="${lib},"
                fi
            done
            found_crypto_libs="${found_crypto_libs%,}"

            [[ -z "$found_crypto_libs" ]] && continue

            local hits=0
            while IFS='|' read -r primitive algorithm key_len params crypto_libs; do
                [[ -z "$primitive" ]] && continue
                csv_row "$real_exe" "$OS_TYPE" "$lang" "$sys_libs_fmt" "$third_libs_fmt" \
                        "$primitive" "$algorithm" "$crypto_libs" "$key_len" "$params" >> "$outfile"
                (( hits++ )) || true
                (( written++ )) || true
            done < <(detect_crypto_in_file "$real_exe")

            if [[ $hits -eq 0 ]]; then
                csv_row "$real_exe" "$OS_TYPE" "$lang" "$sys_libs_fmt" "$third_libs_fmt" \
                        "unknown" "unknown" "$found_crypto_libs" "unknown" "none" >> "$outfile"
                (( written++ )) || true
            fi
        done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
        IFS=':'
    done
    IFS="$IFS_BAK"

    print_ok "Script 2 complete — ${count} binaries scanned, ${written} rows written"
    log "SUCCESS scan_2_binaries_disk — ${written} rows"
}

# =============================================================================
# SCRIPT 3 — library.csv
# System libraries in standard lib directories
# =============================================================================
scan_3_libraries() {
    local outfile="${SCAN_DIR}/library.csv"
    separator
    print_info "Script 3: System libraries → library.csv"
    log "START scan_3_libraries"

    {
        csv_row "library" "os_type" "library_type" "crypto_dependency" \
                "algorithm" "primitive" "key_size" "detection_method"
    } > "$outfile"

    local lib_dirs=("/lib" "/lib64" "/usr/lib" "/usr/lib64" "/usr/local/lib")
    local count=0
    local written=0

    while IFS= read -r -d '' lib; do
        (( count++ ))
        echo "  [${count}] ${lib}"

        # Determine library type
        local lib_type="shared"
        case "$lib" in
            *.a)   lib_type="static" ;;
            *.la)  lib_type="libtool" ;;
        esac

        # For static/libtool, ldd is not applicable
        local crypto_dep=""
        if [[ "$lib_type" == "shared" ]] || [[ "$lib" == *".so"* ]]; then
            local ldd_out
            ldd_out="$(ldd "$lib" 2>/dev/null)"
            for pat in "${CRYPTO_LIBS[@]}"; do
                if echo "$ldd_out" | grep -qi "$pat"; then
                    crypto_dep+="${pat},"
                fi
            done
            crypto_dep="${crypto_dep%,}"
            [[ -z "$crypto_dep" ]] && crypto_dep="none"
        else
            crypto_dep="not-applicable"
        fi

        # Detect crypto via strings
        local strings_out
        strings_out="$(strings "$lib" 2>/dev/null)"

        local hits=0
        for entry in "${ALGO_LIST[@]}"; do
            IFS='|' read -r algo_name primitive key_lengths modes curves proto_versions deprecated <<< "$entry"
            if echo "$strings_out" | grep -q "$algo_name"; then
                local key_sz="unknown"
                if [[ -n "$key_lengths" ]]; then
                    for kl in $key_lengths; do
                        if echo "$strings_out" | grep -qE "${algo_name}[-_ ]?${kl}"; then
                            key_sz="$kl"
                            break
                        fi
                    done
                fi

                local det_method="dependency + strings"
                csv_row "$lib" "$OS_TYPE" "$lib_type" "$crypto_dep" \
                        "$algo_name" "$primitive" "$key_sz" "$det_method" >> "$outfile"
                (( hits++ )) || true
                (( written++ )) || true
            fi
        done

        if [[ $hits -eq 0 ]]; then
            local det_method="static-string"
            [[ "$crypto_dep" != "none" ]] && det_method="dependency-only"
            csv_row "$lib" "$OS_TYPE" "$lib_type" "$crypto_dep" \
                    "unknown" "unknown" "unknown" "$det_method" >> "$outfile"
            (( written++ )) || true
        fi
    done < <(find "${lib_dirs[@]}" \( -name "*.so*" -o -name "*.a" -o -name "*.la" \) \
             -type f -print0 2>/dev/null | sort -z -u)

    print_ok "Script 3 complete — ${count} libraries scanned, ${written} rows written"
    log "SUCCESS scan_3_libraries — ${written} rows"
}

# =============================================================================
# SCRIPT 4 — kernel_modules.csv
# Kernel modules (.ko / .ko.xz / .ko.gz)
# =============================================================================
scan_4_kernel_modules() {
    local outfile="${SCAN_DIR}/kernel_modules.csv"
    separator
    print_info "Script 4: Kernel modules → kernel_modules.csv"
    log "START scan_4_kernel_modules"

    {
        csv_row "module_path" "module_name" "crypto_algorithms" \
                "crypto_primitives" "key_sizes" "crypto_functions"
    } > "$outfile"

    local kernel_ver
    kernel_ver="$(uname -r)"
    local mod_base="/lib/modules/${kernel_ver}"

    if [[ ! -d "$mod_base" ]]; then
        print_warn "Module directory not found: ${mod_base}"
        log "WARN: no module dir ${mod_base}"
        return
    fi

    # Kernel crypto algo patterns (matching 4Kernel_mod.py's CRYPTO_ALGOS)
    declare -A KM_ALGOS=(
        ["AES"]='\b(aes|AES)(128|192|256)?\b'
        ["DES"]='\bDES\b'
        ["3DES"]='\b(3DES|DES-EDE)\b'
        ["ChaCha20"]='\bChaCha20\b'
        ["RSA"]='\bRSA(1024|2048|3072|4096)?\b'
        ["ECC"]='\b(ECC|ECDSA|ECDH|Curve25519|secp256r1)\b'
        ["SHA"]='\bSHA(1|224|256|384|512)\b'
        ["HMAC"]='\bHMAC\b'
        ["CMAC"]='\bCMAC\b'
    )
    declare -A KM_PRIMITIVES=(
        ["AES"]="block cipher"
        ["DES"]="block cipher"
        ["3DES"]="block cipher"
        ["ChaCha20"]="stream cipher"
        ["RSA"]="public-key"
        ["ECC"]="public-key"
        ["SHA"]="hash"
        ["HMAC"]="MAC"
        ["CMAC"]="MAC"
    )

    local count=0
    local written=0

    while IFS= read -r -d '' modpath; do
        (( count++ ))
        echo "  [${count}] ${modpath}"

        # Extract strings — decompress if needed (xz/gzip available on most systems)
        local strings_data=""
        case "$modpath" in
            *.ko.xz)
                if has_cmd xz; then
                    strings_data="$(xz -dc "$modpath" 2>/dev/null | strings 2>/dev/null)"
                elif has_cmd unxz; then
                    strings_data="$(unxz -c "$modpath" 2>/dev/null | strings 2>/dev/null)"
                fi
                ;;
            *.ko.gz)
                strings_data="$(zcat "$modpath" 2>/dev/null | strings 2>/dev/null)"
                ;;
            *)
                strings_data="$(strings "$modpath" 2>/dev/null)"
                ;;
        esac

        [[ -z "$strings_data" ]] && continue

        local found_algos="" found_primitives="" found_keysizes="" found_funcs=""
        local any_algo=false

        for algo_name in "${!KM_ALGOS[@]}"; do
            if echo "$strings_data" | grep -qiE "${KM_ALGOS[$algo_name]}"; then
                found_algos+="${algo_name}, "
                found_primitives+="${KM_PRIMITIVES[$algo_name]}, "
                any_algo=true

                # Extract key sizes from matches
                local ksz
                ksz="$(echo "$strings_data" | grep -oiE "${KM_ALGOS[$algo_name]}" | \
                       grep -oE '[0-9]+' | sort -u | tr '\n' ' ')"
                [[ -n "$ksz" ]] && found_keysizes+="${ksz% } "
            fi
        done

        [[ "$any_algo" == "false" ]] && continue

        # Find crypto API functions
        found_funcs="$(echo "$strings_data" | grep -oE \
            '(crypto|skcipher|aead|hash)_[a-zA-Z0-9_]+' | sort -u | tr '\n' ' ')"

        found_algos="${found_algos%, }"
        found_primitives="${found_primitives%, }"
        found_keysizes="${found_keysizes% }"
        [[ -z "$found_keysizes" ]] && found_keysizes="unknown"
        found_funcs="${found_funcs% }"

        csv_row "$modpath" "$(basename "$modpath")" \
                "$found_algos" "$found_primitives" "$found_keysizes" "$found_funcs" >> "$outfile"
        (( written++ )) || true

    done < <(find "$mod_base" -type f \( -name "*.ko" -o -name "*.ko.xz" -o -name "*.ko.gz" \) \
             -print0 2>/dev/null)

    print_ok "Script 4 complete — ${count} modules scanned, ${written} rows written"
    log "SUCCESS scan_4_kernel_modules — ${written} rows"
}

# =============================================================================
# SCRIPT 5 — crypto_cert_key.csv
# Certificates and private keys (PEM/DER/PKCS12) via openssl
# =============================================================================
scan_5_cert_keys() {
    local outfile="${SCAN_DIR}/crypto_cert_key.csv"
    separator
    print_info "Script 5: Certificates and keys (full filesystem walk) → crypto_cert_key.csv"
    print_warn "This may take a long time — high disk I/O."
    log "START scan_5_cert_keys"

    if ! has_cmd openssl; then
        print_warn "openssl not found — skipping Script 5"
        log "SKIP scan_5_cert_keys — no openssl"
        return
    fi

    {
        csv_row "path" "file_type" "algorithm" "key_size" "curve" \
                "rsa_modulus_fingerprint" "rsa_exponent" \
                "signature_algorithm" "signature_hash" \
                "subject" "issuer" "serial" "not_before" "not_after" \
                "fingerprint_sha1" "fingerprint_sha256"
    } > "$outfile"

    local count=0
    local written=0

    while IFS= read -r -d '' filepath; do
        (( count++ ))
        echo "  [${count}] ${filepath}"

        local content
        content="$(cat "$filepath" 2>/dev/null)" || continue

        # ---- CERTIFICATE ----
        if echo "$content" | grep -q "BEGIN CERTIFICATE"; then
            local subject issuer serial not_before not_after algo key_size curve
            local sig_algo sig_hash fp_sha1 fp_sha256 rsa_exp rsa_mod_fp

            subject="$(openssl x509 -in "$filepath" -noout -subject 2>/dev/null | \
                       sed 's/subject=//')"
            issuer="$(openssl x509 -in "$filepath" -noout -issuer 2>/dev/null | \
                      sed 's/issuer=//')"
            serial="$(openssl x509 -in "$filepath" -noout -serial 2>/dev/null | \
                      sed 's/serial=/0x/')"
            local raw_before raw_after
            raw_before="$(openssl x509 -in "$filepath" -noout -startdate 2>/dev/null | \
                          sed 's/notBefore=//')"
            raw_after="$(openssl x509 -in "$filepath" -noout -enddate 2>/dev/null | \
                         sed 's/notAfter=//')"
            not_before="$(convert_openssl_date "$raw_before")"
            not_after="$(convert_openssl_date "$raw_after")"
            sig_algo="$(openssl x509 -in "$filepath" -noout -text 2>/dev/null | \
                        grep "Signature Algorithm" | head -1 | awk '{print $3}')"
            sig_hash="$(echo "$sig_algo" | grep -oiE 'sha[0-9]+')"
            fp_sha1="$(openssl x509 -in "$filepath" -noout -fingerprint -sha1 2>/dev/null | \
                       cut -d= -f2 | tr -d ':')"
            fp_sha256="$(openssl x509 -in "$filepath" -noout -fingerprint -sha256 2>/dev/null | \
                         cut -d= -f2 | tr -d ':')"

            # Key type and size
            local pubkey_text
            pubkey_text="$(openssl x509 -in "$filepath" -noout -text 2>/dev/null)"

            if echo "$pubkey_text" | grep -q "rsaEncryption\|RSA Public-Key"; then
                algo="_RSAPublicKey"
                key_size="$(echo "$pubkey_text" | grep -oE 'RSA Public.Key: \([0-9]+' | \
                             grep -oE '[0-9]+')"
                [[ -z "$key_size" ]] && key_size="$(echo "$pubkey_text" | \
                    grep -oE 'Public-Key: \([0-9]+' | grep -oE '[0-9]+')"
                rsa_exp="65537"
                rsa_mod_fp=""
                if has_cmd xxd; then
                    rsa_mod_fp="$(openssl x509 -noout -modulus -in "$filepath" 2>/dev/null | \
                                  sed 's/Modulus=//' | tr -d '[:space:]' | \
                                  xxd -r -p 2>/dev/null | sha256sum 2>/dev/null | \
                                  awk '{print substr($1,1,32)}')"
                fi
                curve=""
            elif echo "$pubkey_text" | grep -qE 'id-ecPublicKey|EC Public Key'; then
                algo="_EllipticCurvePublicKey"
                key_size="$(echo "$pubkey_text" | grep -oE 'Public-Key: \([0-9]+' | \
                             grep -oE '[0-9]+')"
                curve="$(echo "$pubkey_text" | grep -oE 'ASN1 OID: [a-zA-Z0-9]+' | \
                          awk '{print $NF}')"
                rsa_exp="" rsa_mod_fp=""
            elif echo "$pubkey_text" | grep -q "ED25519\|ed25519"; then
                algo="_Ed25519PublicKey"; key_size="256"; curve="Ed25519"
                rsa_exp="" rsa_mod_fp=""
            else
                algo="unknown"; key_size="unknown"; curve=""
                rsa_exp="" rsa_mod_fp=""
            fi

            csv_row "$filepath" "certificate" "$algo" "${key_size:-unknown}" "$curve" \
                    "$rsa_mod_fp" "$rsa_exp" "$sig_algo" "${sig_hash:-unknown}" \
                    "$subject" "$issuer" "${serial:-unknown}" \
                    "${not_before:-unknown}" "${not_after:-unknown}" \
                    "${fp_sha1:-unknown}" "${fp_sha256:-unknown}" >> "$outfile"
            (( written++ )) || true
            continue
        fi

        # ---- PRIVATE KEY ----
        if echo "$content" | grep -qE "BEGIN (RSA |EC |PRIVATE KEY|OPENSSH PRIVATE KEY)"; then
            local algo key_size curve fp_sha256

            fp_sha256="$(sha256sum "$filepath" 2>/dev/null | awk '{print $1}')"

            if echo "$content" | grep -q "BEGIN RSA PRIVATE KEY"; then
                algo="_RSAPrivateKey"
                key_size="$(openssl rsa -in "$filepath" -text -noout 2>/dev/null | \
                             grep -oE 'Private-Key: \([0-9]+' | grep -oE '[0-9]+')"
                curve=""
            elif echo "$content" | grep -q "BEGIN EC PRIVATE KEY"; then
                algo="_EllipticCurvePrivateKey"
                key_size="$(openssl ec -in "$filepath" -text -noout 2>/dev/null | \
                             grep -oE 'ASN1 OID: [a-zA-Z0-9]+' | awk '{print $NF}')"
                curve="$key_size"
                key_size="unknown"
            else
                algo="unknown"; key_size="unknown"; curve=""
            fi

            csv_row "$filepath" "private_key" "$algo" "${key_size:-unknown}" "$curve" \
                    "" "" "" "" "" "" "" "" "" \
                    "$(sha1sum "$filepath" 2>/dev/null | awk '{print $1}')" \
                    "${fp_sha256:-unknown}" >> "$outfile"
            (( written++ )) || true
        fi

    done < <(find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
             \( -name "*.crt" -o -name "*.cer" -o -name "*.pem" -o -name "*.der" \
                -o -name "*.key" -o -name "*.pk8" -o -name "*.p12" -o -name "*.pfx" \) \
             -type f -print0 2>/dev/null)

    print_ok "Script 5 complete — ${count} files scanned, ${written} rows written"
    log "SUCCESS scan_5_cert_keys — ${written} rows"
}

# =============================================================================
# SCRIPT 6 — exec_script.csv
# Executable scripts with crypto patterns (full filesystem walk)
# =============================================================================
scan_6_exec_scripts() {
    local outfile="${SCAN_DIR}/exec_script.csv"
    separator
    print_info "Script 6: Executable scripts (full filesystem walk) → exec_script.csv"
    print_warn "This may take a long time — high disk I/O."
    log "START scan_6_exec_scripts"

    {
        csv_row "script_path" "language" "algorithm" "primitive" "function_pattern" "key_size"
    } > "$outfile"

    # Crypto patterns matching 6ExeCodes.py
    # Format: "algo|primitive|pattern"
    local -a SCRIPT_PATTERNS=(
        "AES|block cipher|AES\.new"
        "AES|block cipher|openssl enc -aes-(128|192|256)"
        "RSA|public-key|RSA\.generate"
        "RSA|public-key|openssl genrsa"
        "RSA|public-key|ssh-keygen -t rsa"
        "ECC|public-key|EllipticCurve"
        "ECC|public-key|secp256r1"
        "ECC|public-key|ed25519"
        "SHA|hash|hashlib\.sha"
        "SHA|hash|openssl dgst -sha"
        "HMAC|MAC|hmac\.new"
    )

    local count=0
    local written=0

    # Script extensions to scan
    local exts=("*.py" "*.sh" "*.pl" "*.rb" "*.ps1" "*.bat" "*.cmd")
    local find_name_args=()
    for ext in "${exts[@]}"; do
        find_name_args+=(-o -name "$ext")
    done

    while IFS= read -r -d '' scriptpath; do
        (( count++ ))
        echo "  [${count}] ${scriptpath}"

        local lang
        lang="${scriptpath##*.}"
        [[ "$lang" == "$scriptpath" ]] && lang="unknown"

        local content
        content="$(cat "$scriptpath" 2>/dev/null)" || continue

        local hits=0
        for pat_entry in "${SCRIPT_PATTERNS[@]}"; do
            IFS='|' read -r algo primitive pattern <<< "$pat_entry"

            if echo "$content" | grep -qiE "$pattern"; then
                # Try to extract key size from match
                local key_size="unknown"
                local match_ks
                match_ks="$(echo "$content" | grep -oiE "$pattern" | grep -oE '[0-9]{3,4}' | head -1)"
                [[ -n "$match_ks" ]] && key_size="$match_ks"

                csv_row "$scriptpath" "$lang" "$algo" "$primitive" "$pattern" "$key_size" >> "$outfile"
                (( hits++ )) || true
                (( written++ )) || true
            fi
        done

    done < <(find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
             \( "${find_name_args[@]:1}" \) -type f -print0 2>/dev/null)

    print_ok "Script 6 complete — ${count} scripts scanned, ${written} rows written"
    log "SUCCESS scan_6_exec_scripts — ${written} rows"
}

# =============================================================================
# SCRIPT 7 — web_app.csv
# Web application directories
# =============================================================================
scan_7_web_app() {
    local outfile="${SCAN_DIR}/web_app.csv"
    separator
    print_info "Script 7: Web application files → web_app.csv"
    log "START scan_7_web_app"

    {
        csv_row "file_path" "language" "algorithm" "primitive" \
                "library_or_api" "key_size" "detection_pattern"
    } > "$outfile"

    local web_roots=("/var/www" "/usr/share/nginx" "/srv/www")
    local web_exts=("*.php" "*.py" "*.js" "*.ts" "*.java" "*.go" "*.rb" "*.jsp" "*.cs" "*.scala")

    # Crypto patterns matching 7Web_App.py
    local -a WEB_PATTERNS=(
        "AES|block-cipher|AES-(128|192|256)"
        "AES|block-cipher|openssl_encrypt"
        "AES|block-cipher|CryptoJS\.AES"
        "AES|block-cipher|Cipher\.getInstance..AES"
        "AES|block-cipher|EVP_aes_(128|192|256)"
        "RSA|public-key|RSA_generate_key"
        "RSA|public-key|new RSA"
        "RSA|public-key|KeyPairGenerator\.getInstance..RSA"
        "RSA|public-key|openssl_pkey_new"
        "RSA|public-key|ssh-rsa"
        "ECC|public-key|secp256r1"
        "ECC|public-key|prime256v1"
        "ECC|public-key|X25519"
        "ECC|public-key|Ed25519"
        "ECC|public-key|EllipticCurve"
        "SHA|hash|SHA-?(1|224|256|384|512)"
        "SHA|hash|hashlib\.sha"
        "SHA|hash|MessageDigest\.getInstance..SHA"
        "HMAC|MAC|HmacSHA(1|256|384|512)"
        "HMAC|MAC|hmac\.new"
        "HMAC|MAC|hash_hmac"
        "PBKDF2|KDF|PBKDF2"
        "PBKDF2|KDF|hash_pbkdf2"
        "PBKDF2|KDF|SecretKeyFactory\.getInstance..PBKDF2"
        "TLS|protocol|TLSv1\.2"
        "TLS|protocol|TLSv1\.3"
        "TLS|protocol|https://"
        "TLS|protocol|SSLContext"
    )

    local find_name_args=()
    for ext in "${web_exts[@]}"; do
        find_name_args+=(-o -name "$ext")
    done

    local count=0
    local written=0

    for root in "${web_roots[@]}"; do
        [[ ! -d "$root" ]] && continue

        while IFS= read -r -d '' filepath; do
            (( count++ ))
            echo "  [${count}] ${filepath}"

            local lang="${filepath##*.}"

            local content
            content="$(cat "$filepath" 2>/dev/null)" || continue

            for pat_entry in "${WEB_PATTERNS[@]}"; do
                IFS='|' read -r algo primitive pattern <<< "$pat_entry"

                if echo "$content" | grep -qiE "$pattern"; then
                    local key_size="unknown"
                    local match_ks
                    match_ks="$(echo "$content" | grep -oiE "$pattern" | grep -oE '[0-9]{3,4}' | head -1)"
                    [[ -n "$match_ks" ]] && key_size="$match_ks"

                    csv_row "$filepath" "$lang" "$algo" "$primitive" \
                            "$pattern" "$key_size" "$pattern" >> "$outfile"
                    (( written++ )) || true
                fi
            done

        done < <(find "$root" \( "${find_name_args[@]:1}" \) -type f -print0 2>/dev/null)
    done

    print_ok "Script 7 complete — ${count} files scanned, ${written} rows written"
    log "SUCCESS scan_7_web_app — ${written} rows"
}

# =============================================================================
# SCRIPT 8 — network_app.csv
# Live network connections using ss or netstat
# =============================================================================
scan_8_network_app() {
    local outfile="${SCAN_DIR}/network_app.csv"
    separator
    print_info "Script 8: Live network connections → network_app.csv"
    log "START scan_8_network_app"

    {
        csv_row "ScanTimeUTC" "Role" "Protocol" "Process" "PID" \
                "ExecutablePath" "ScriptPath" "RemoteIP" "RemotePort" "CryptoDetails"
    } > "$outfile"

    local scan_time
    scan_time="$(date -u '+%Y-%m-%dT%H:%M:%S.000000')"

    local written=0

    # Use ss if available, otherwise netstat
    local conn_data=""
    if has_cmd ss; then
        # ss -tnp — TCP numeric with process
        conn_data="$(ss -tnp 2>/dev/null)"
    elif has_cmd netstat; then
        conn_data="$(netstat -tnp 2>/dev/null)"
    else
        print_warn "Neither ss nor netstat found — skipping Script 8"
        log "SKIP scan_8_network_app — no ss/netstat"
        return
    fi

    # Parse connections: identify SSH (port 22) and TLS (port 443)
    # Format from ss -tnp:  State  Recv-Q  Send-Q  Local-Addr:Port  Peer-Addr:Port  Process
    while IFS= read -r line; do
        [[ "$line" =~ ^State ]] && continue   # header
        [[ -z "$line" ]] && continue

        local state local_addr peer_addr proc_info
        state="$(echo "$line" | awk '{print $1}')"
        local_addr="$(echo "$line" | awk '{print $4}')"
        peer_addr="$(echo "$line" | awk '{print $5}')"
        proc_info="$(echo "$line" | awk '{print $6}')"   # users:(("sshd",pid=1234,...))

        local local_port peer_port remote_ip pid pname exe role proto

        # Extract ports
        local_port="${local_addr##*:}"
        peer_port="${peer_addr##*:}"
        remote_ip="${peer_addr%:*}"

        # Determine protocol from port
        proto="UNKNOWN"
        role="CLIENT"
        case "$local_port" in
            22)  proto="SSH";  role="SERVER" ;;
            443) proto="TLS";  role="SERVER" ;;
            500|4500) proto="IPsec-IKE"; role="SERVER" ;;
        esac
        case "$peer_port" in
            22)  proto="SSH";  role="CLIENT" ;;
            443) proto="TLS";  role="CLIENT" ;;
        esac

        [[ "$proto" == "UNKNOWN" ]] && continue

        # For LISTEN sockets the peer is a wildcard — clear remote fields to match Python output
        if [[ "$peer_addr" == *"*"* || "$remote_ip" == "0.0.0.0" || "$remote_ip" == "::" ]]; then
            [[ "$role" == "SERVER" ]] && remote_ip=""
        fi

        # Extract PID and process name from proc_info
        pid="$(echo "$proc_info" | grep -oE 'pid=[0-9]+' | grep -oE '[0-9]+' | head -1)"
        pname="$(echo "$proc_info" | grep -oE '"[^"]+"' | tr -d '"' | head -1)"

        exe=""
        if [[ -n "$pid" && -d "/proc/$pid" ]]; then
            exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null)"
        fi

        [[ -z "$pname" && -n "$pid" ]] && pname="$(cat "/proc/${pid}/comm" 2>/dev/null)"

        csv_row "$scan_time" "$role" "$proto" "${pname:-unknown}" "${pid:-unknown}" \
                "${exe:-unknown}" "" "${remote_ip:-}" "${peer_port:-$local_port}" "" >> "$outfile"
        (( written++ )) || true

    done <<< "$conn_data"

    # Check for IPsec daemons
    for daemon in charon pluto strongswan; do
        local dpid
        dpid="$(pgrep "$daemon" 2>/dev/null | head -1)"
        if [[ -n "$dpid" ]]; then
            local dexe
            dexe="$(readlink -f "/proc/${dpid}/exe" 2>/dev/null)"
            csv_row "$scan_time" "SERVICE" "IPsec" "$daemon" "$dpid" \
                    "${dexe:-unknown}" "" "" "" "IKE / ESP (kernel-managed)" >> "$outfile"
            (( written++ )) || true
        fi
    done

    print_ok "Script 8 complete — ${written} connections/services written"
    log "SUCCESS scan_8_network_app — ${written} rows"
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    separator
    echo ""
    echo -e "${BOLD}Output directory: ${SCAN_DIR}${NC}"
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
    )

    for f in "${output_files[@]}"; do
        local full="${SCAN_DIR}/${f}"
        if [[ -f "$full" ]]; then
            local lines size
            lines="$(wc -l < "$full" 2>/dev/null || echo '?')"
            size="$(du -sh "$full" 2>/dev/null | cut -f1)"
            print_ok "  ${f}  (${lines} lines, ${size})"
        fi
    done

    echo ""
    print_info "Full log: ${LOG_FILE}"
    echo ""
    log "=== pqclegacy.sh finished ==="
}

# =============================================================================
# SCRIPT SELECTION
# =============================================================================
select_scripts() {
    echo ""
    echo "Available scans:"
    echo "  1  Running process binaries      (binaries_used.csv)"
    echo "  2  Binaries on disk (PATH)       (binaries_at_disk.csv)"
    echo "  3  System libraries              (library.csv)"
    echo "  4  Kernel modules                (kernel_modules.csv)"
    echo "  5  Certificates and keys         (crypto_cert_key.csv)  [slow: full filesystem]"
    echo "  6  Executable scripts            (exec_script.csv)      [slow: full filesystem]"
    echo "  7  Web application files         (web_app.csv)"
    echo "  8  Live network connections      (network_app.csv)"
    echo ""
    echo "  all = run all   |   comma-separated or range e.g. 1-4   1,3,7"
    echo ""

    while true; do
        printf "${BOLD}  Select: ${NC}"
        local raw
        read -r raw
        raw="${raw// /}"
        [[ -z "$raw" ]] && echo "  No input, try again." && continue

        SELECTED=()
        local ok=true

        if [[ "${raw,,}" == "all" ]]; then
            SELECTED=(1 2 3 4 5 6 7 8)
            break
        fi

        IFS=',' read -ra tokens <<< "$raw"
        for token in "${tokens[@]}"; do
            if [[ "$token" =~ ^([1-8])-([1-8])$ ]]; then
                local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
                if [[ "$s" -gt "$e" ]]; then
                    echo "  Invalid range: $token"; ok=false; break
                fi
                for (( i=s; i<=e; i++ )); do SELECTED+=("$i"); done
            elif [[ "$token" =~ ^[1-8]$ ]]; then
                SELECTED+=("$token")
            else
                echo "  Unknown option: $token"; ok=false; break
            fi
        done

        if [[ "$ok" == "true" && ${#SELECTED[@]} -gt 0 ]]; then
            break
        fi
        echo "  Invalid selection, try again."
        SELECTED=()
    done

    echo -n "  Will run:"
    for s in "${SELECTED[@]}"; do echo -n " $s"; done
    echo ""
}

# =============================================================================
# PREREQUISITE CHECK
# =============================================================================
check_prerequisites() {
    echo ""
    echo -e "${BOLD}== Prerequisites ==${NC}"

    local required_ok=true

    for tool in strings nm ldd find grep awk; do
        if has_cmd "$tool"; then
            print_ok "  $tool"
        else
            print_error "  $tool  (REQUIRED — not found)"
            required_ok=false
        fi
    done

    for tool in ss netstat openssl xz zcat sha256sum sha1sum; do
        if has_cmd "$tool"; then
            print_ok "  $tool"
        else
            print_warn "  $tool  (optional — some scans may be limited)"
        fi
    done

    if [[ "$required_ok" == "false" ]]; then
        print_error "Required tools missing. Install binutils (for strings/nm) and glibc (for ldd)."
        exit 1
    fi

    echo ""
    print_info "OS     : $(uname -sr)"
    print_info "User   : $(id)"
    print_info "Output : ${SCAN_DIR}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================
SELECTED=()

main() {
    echo ""
    echo "================================================"
    echo "  pqclegacy.sh — CBOM Scanning (No Python)"
    echo "  Post-Quantum Cryptography Check"
    echo "================================================"
    echo ""
    echo "  Read-only. No files are modified."
    echo "  Scripts 5 and 6 perform a full filesystem walk."
    echo ""
    printf "${BOLD}  Continue? [Y/n]: ${NC}"
    local ack
    read -r ack
    case "$ack" in
        [nN]*) echo "Aborted."; exit 0 ;;
    esac

    mkdir -p "${SCAN_DIR}"
    log "=== pqclegacy.sh started — kernel=$(uname -r) user=$(id -un) ==="

    check_prerequisites
    select_scripts

    for script_id in "${SELECTED[@]}"; do
        case "$script_id" in
            1) scan_1_binaries_used ;;
            2) scan_2_binaries_disk ;;
            3) scan_3_libraries ;;
            4) scan_4_kernel_modules ;;
            5)
                printf "${YELLOW}[ WARN ]${NC} Script 5 is a full filesystem walk. Continue? [Y/n]: "
                local c5; read -r c5
                case "$c5" in
                    [nN]*) print_skip "Script 5 skipped." ;;
                    *) scan_5_cert_keys ;;
                esac
                ;;
            6)
                printf "${YELLOW}[ WARN ]${NC} Script 6 is a full filesystem walk. Continue? [Y/n]: "
                local c6; read -r c6
                case "$c6" in
                    [nN]*) print_skip "Script 6 skipped." ;;
                    *) scan_6_exec_scripts ;;
                esac
                ;;
            7) scan_7_web_app ;;
            8) scan_8_network_app ;;
        esac
    done

    print_summary
}

main "$@"

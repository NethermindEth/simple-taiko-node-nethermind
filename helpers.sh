#!/bin/bash
# helpers.sh — shared utility functions for deploy-taiko-full.sh and remove-taiko-full.sh
#
# SOURCE this file; do not execute directly.
# All functions rely on constants (ENCLAVE_NAME, CONFIGS_DIR, etc.)
# being defined in the calling script before this file is sourced.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Guard against double-sourcing
[[ -n "${_TAIKO_HELPERS_LOADED:-}" ]] && return 0
readonly _TAIKO_HELPERS_LOADED=1

# ─── Colours ────────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ─── Logging ────────────────────────────────────────────────────────────────
log_info() {
    echo -e "\n${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "\n${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "\n${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "\n${RED}[ERROR]${NC} $1" >&2
}

# ─── Progress spinner ────────────────────────────────────────────────────────
# Usage: show_progress <pid> <message>
show_progress() {
    local pid="$1"
    local message="$2"
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    printf "%s " "$message"
    while kill -0 "$pid" 2>/dev/null; do
        printf "\b%s" "${spinner:i++%${#spinner}:1}"
        sleep 0.1
    done
    printf "\b\n"
}

# ─── Cross-platform sed ──────────────────────────────────────────────────────
sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ─── Prerequisites ───────────────────────────────────────────────────────────
validate_prerequisites() {
    log_info "Validating prerequisites..."

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running or not accessible"
        log_error "Please start Docker and ensure your user has docker permissions"
        return 1
    fi

    local required_cmds=("docker" "git" "jq" "curl" "kurtosis")
    local missing_cmds=()

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_cmds[*]}"
        log_error "Please install them and ensure they are in your PATH"
        return 1
    fi

    log_success "Prerequisites validation passed"
    return 0
}

# ─── Git submodules ──────────────────────────────────────────────────────────
initialize_submodules() {
    log_info "Initializing git submodules..."

    if git submodule update --init >/dev/null 2>&1; then
        log_success "Git submodules initialized"
    else
        log_warning "Failed to initialize git submodules, continuing..."
    fi
}

# ─── Network / IP ────────────────────────────────────────────────────────────
get_machine_ip() {
    local ip=""

    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -n1)
    fi

    if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
        ip=$(ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -n1 | awk '{print $2}' | cut -d'/' -f1)
    fi

    echo "$ip"
}

# ─── URL helpers ─────────────────────────────────────────────────────────────

# Replace host.docker.internal with localhost (for host-side access)
to_localhost() {
    local endpoint="$1"
    echo "$endpoint" \
        | sed -E 's#(https?://)host\.docker\.internal(.*)#\1localhost\2#' \
        | sed -E 's#(wss?://)host\.docker\.internal(.*)#\1localhost\2#'
}

# Replace any host component with host.docker.internal (for container-to-host access)
to_docker_internal() {
    local endpoint="$1"
    echo "$endpoint" \
        | sed -E 's#(https?://)([^:/]+)(.*)#\1host.docker.internal\3#' \
        | sed -E 's#(wss?://)([^:/]+)(.*)#\1host.docker.internal\3#'
}

# Derive and export *_EXTERNAL URL variants from the base L1_ENDPOINT_* values.
#
# local  → EXTERNAL = localhost     (host shell can reach it)
# remote → EXTERNAL = machine_ip    (both host shell and containers reach it directly)
#
# The _DOCKER variants in .env stay untouched (host.docker.internal or machine_ip).
configure_environment_urls() {
    local env_choice="${1:-local}"
    local machine_ip="${2:-}"

    case "$env_choice" in
        1|"remote")
            if [[ -z "$machine_ip" ]]; then
                machine_ip=$(get_machine_ip)
            fi
            L1_ENDPOINT_HTTP_EXTERNAL=$(echo "${L1_ENDPOINT_HTTP:-http://localhost:32003}" \
                | sed -E "s#(https?://)([^:/]+)(.*)#\1${machine_ip}\3#")
            L1_ENDPOINT_WS_EXTERNAL=$(echo "${L1_ENDPOINT_WS:-ws://localhost:32004}" \
                | sed -E "s#(wss?://)([^:/]+)(.*)#\1${machine_ip}\3#")
            L1_BEACON_HTTP_EXTERNAL=$(echo "${L1_BEACON_HTTP:-http://localhost:33001}" \
                | sed -E "s#(https?://)([^:/]+)(.*)#\1${machine_ip}\3#")
            ;;
        *)
            L1_ENDPOINT_HTTP_EXTERNAL=$(to_localhost "${L1_ENDPOINT_HTTP:-http://host.docker.internal:32003}")
            L1_ENDPOINT_WS_EXTERNAL=$(to_localhost "${L1_ENDPOINT_WS:-ws://host.docker.internal:32004}")
            L1_BEACON_HTTP_EXTERNAL=$(to_localhost "${L1_BEACON_HTTP:-http://host.docker.internal:33001}")
            ;;
    esac

    export L1_ENDPOINT_HTTP_EXTERNAL L1_ENDPOINT_WS_EXTERNAL L1_BEACON_HTTP_EXTERNAL
}

# ─── RPC helpers ─────────────────────────────────────────────────────────────
test_rpc_connection() {
    local rpc_url="$1"

    local response
    response=$(curl -s --max-time 10 -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","id":0,"method":"eth_blockNumber","params":[]}' \
        "$rpc_url" 2>/dev/null) || return 1

    echo "$response" | jq -e '.result' >/dev/null 2>&1
}

# ─── .env file helpers ───────────────────────────────────────────────────────
# Update or append a variable in an env file
update_env_var() {
    local env_file="$1"
    local var_name="$2"
    local var_value="$3"

    if grep -q "^${var_name}=" "$env_file"; then
        sed_inplace "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
    else
        echo "${var_name}=${var_value}" >> "$env_file"
    fi
}

# ─── Kurtosis helpers ────────────────────────────────────────────────────────
check_kurtosis_available() {
    command -v kurtosis >/dev/null 2>&1
}

check_l1_devnet_exists() {
    if ! check_kurtosis_available; then
        return 1
    fi
    kurtosis enclave ls 2>/dev/null | grep -q "${ENCLAVE_NAME:-surge-devnet}"
}

get_l1_devnet_status() {
    if ! check_kurtosis_available; then
        echo "NOT_AVAILABLE"
        return
    fi
    kurtosis enclave ls 2>/dev/null | grep "${ENCLAVE_NAME:-surge-devnet}" | awk '{print $3}' 2>/dev/null || echo "NOT_FOUND"
}

# ─── ethereum-package configuration ─────────────────────────────────────────
configure_remote_blockscout() {
    local machine_ip="$1"

    log_info "Configuring blockscout (IP: $machine_ip)..."
    cp "$BLOCKSCOUT_CONFIG_FILE" "$BLOCKSCOUT_FILE"
    sed_inplace "s/else \"localhost:{0}\"/else \"$machine_ip:{0}\"/g" "$BLOCKSCOUT_FILE"
    log_success "Blockscout configured"
}

configure_shared_utils() {
    log_info "Configuring shared_utils..."
    cp "$SHARED_UTILS_CONFIG_FILE" "$SHARED_UTILS_FILE"
    log_success "shared_utils configured"
}

configure_input_parser() {
    log_info "Configuring input_parser..."
    cp "$INPUT_PARSER_CONFIG_FILE" "$INPUT_PARSER_FILE"
    log_success "input_parser configured"
}

configure_spamoor() {
    log_info "Configuring spamoor and main..."
    cp "$SPAMOOR_CONFIG_FILE" "$SPAMOOR_FILE"
    cp "$MAIN_CONFIG_FILE" "$MAIN_FILE"
    log_success "spamoor configured"
}

configure_genesis_values() {
    log_info "Configuring genesis values template..."
    cp "$VALUES_ENV_CONFIG_FILE" "$VALUES_ENV_FILE"
    log_success "genesis values configured"
}

configure_network_params() {
    if [[ -n "${SECONDS_PER_SLOT:-}" ]]; then
        log_info "Setting seconds_per_slot to $SECONDS_PER_SLOT in network_params.yaml..."
        sed_inplace "s/^\(\s*seconds_per_slot:\s*\)[0-9]\+/\1$SECONDS_PER_SLOT/" "$NETWORK_PARAMS"
        log_success "Network params configured (seconds_per_slot: $SECONDS_PER_SLOT)"
    else
        log_warning "SECONDS_PER_SLOT not set, using default from network_params.yaml"
    fi
}

# ─── Fork timestamp ──────────────────────────────────────────────────────────
# Calculate and update fork timestamp in .env
# Usage: update_fork_timestamp <env_file> [buffer_seconds] [update_shasta] [update_uzen]
update_fork_timestamp() {
    local env_file="$1"
    local buffer="${2:-120}"
    local update_shasta="${3:-true}"
    local update_uzen="${4:-true}"
    local last_fork_time=$(date +%s)
    
    if [[ "$update_shasta" == "true" ]]; then
        local pacaya_timestamp
        pacaya_timestamp=$(( last_fork_time + buffer ))
        last_fork_time=$pacaya_timestamp

        local readable_time
        if [[ "$(uname)" == "Darwin" ]]; then
            readable_time=$(date -r "$pacaya_timestamp" '+%Y-%m-%d %H:%M:%S')
        else
            readable_time=$(date -d "@$pacaya_timestamp" '+%Y-%m-%d %H:%M:%S')
        fi

        log_info "Setting Shasta fork timestamp: $pacaya_timestamp ($readable_time)"
        update_env_var "$env_file" "TAIKO_INTERNAL_SHASTA_TIME" "$pacaya_timestamp"
        log_success "Shasta fork timestamp updated"
    fi

    if [[ "$update_uzen" == "true" ]]; then
        local uzen_timestamp=$(( last_fork_time + buffer ))
        last_fork_time=$uzen_timestamp

        if [[ "$(uname)" == "Darwin" ]]; then
            readable_time=$(date -r "$uzen_timestamp" '+%Y-%m-%d %H:%M:%S')
        else
            readable_time=$(date -d "@$uzen_timestamp" '+%Y-%m-%d %H:%M:%S')
        fi

        log_info "Setting Uzen fork timestamp: $uzen_timestamp ($readable_time)"
        update_env_var "$env_file" "UZEN_FORK_TIME" "$uzen_timestamp"
        log_success "Uzen fork timestamp updated"
    fi
}

# ─── Prompt helpers ──────────────────────────────────────────────────────────
prompt_mode_selection() {
    echo >&2
    echo "╔══════════════════════════════════════════════════════════════╗" >&2
    echo "  Select execution mode:                                        " >&2
    echo "║══════════════════════════════════════════════════════════════║" >&2
    echo "║  0 for silence (default)                                     ║" >&2
    echo "║  1 for debug                                                 ║" >&2
    echo "╚══════════════════════════════════════════════════════════════╝" >&2
    echo >&2
    read -p "Enter choice [0]: " choice
    choice=${choice:-0}
    echo "$choice"
}

prompt_environment_selection() {
    echo >&2
    echo "╔══════════════════════════════════════════════════════════════╗" >&2
    echo "  Select deployment environment:                                " >&2
    echo "║══════════════════════════════════════════════════════════════║" >&2
    echo "║  0 for local (default)                                       ║" >&2
    echo "║  1 for remote                                                ║" >&2
    echo "╚══════════════════════════════════════════════════════════════╝" >&2
    echo >&2
    read -p "Enter choice [0]: " choice
    choice=${choice:-0}
    echo "$choice"
}

prompt_yes_no_selection() {
    local question="$1"
    echo >&2
    echo "╔══════════════════════════════════════════════════════════════╗" >&2
    printf "  %-62s\n" "$question" >&2
    echo "║══════════════════════════════════════════════════════════════║" >&2
    echo "║  0 for no (default)                                          ║" >&2
    echo "║  1 for yes                                                   ║" >&2
    echo "╚══════════════════════════════════════════════════════════════╝" >&2
    echo >&2
    read -p "Enter choice [0]: " choice
    choice=${choice:-0}
    echo "$choice"
}

prompt_client_selection() {
    echo >&2
    echo "╔══════════════════════════════════════════════════════════════╗" >&2
    echo "  Select L2 execution client:                                   " >&2
    echo "║══════════════════════════════════════════════════════════════║" >&2
    echo "║  0 for nethermind (default)                                  ║" >&2
    echo "║  1 for geth                                                  ║" >&2
    echo "║  2 for alethia-reth                                          ║" >&2
    echo "╚══════════════════════════════════════════════════════════════╝" >&2
    echo >&2
    read -p "Enter choice [0]: " choice
    choice=${choice:-0}
    echo "$choice"
}

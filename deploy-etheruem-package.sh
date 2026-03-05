#!/bin/bash
set -euo pipefail

# Load .env file if it exists
ENV_FILE=".env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly BLOCKSCOUT_FILE="./ethereum-package/src/blockscout/blockscout_launcher.star"
readonly BLOCKSCOUT_CONFIG_FILE="./configs/blockscout_launcher.star"
readonly SHARED_UTILS_FILE="./ethereum-package/src/shared_utils/shared_utils.star"
readonly SHARED_UTILS_CONFIG_FILE="./configs/shared_utils.star"
readonly INPUT_PARSER_FILE="./ethereum-package/src/package_io/input_parser.star"
readonly INPUT_PARSER_CONFIG_FILE="./configs/input_parser.star"
readonly SPAMOOR_FILE="./ethereum-package/src/spamoor/spamoor.star"
readonly SPAMOOR_CONFIG_FILE="./configs/spamoor.star"
readonly MAIN_FILE="./ethereum-package/main.star"
readonly MAIN_CONFIG_FILE="./configs/main.star"
readonly VALUES_ENV_FILE="./ethereum-package/static_files/genesis-generation-config/el-cl/values.env.tmpl"
readonly VALUES_ENV_CONFIG_FILE="./configs/values.env.tmpl"
readonly NETWORK_PARAMS="./configs/network_params.yaml"
readonly ENCLAVE_NAME="surge-devnet"

# Default values for command line arguments
environment=""
mode=""
blockscout=""

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Show usage help
show_help() {
  echo "Usage:"
  echo "  $0 --environment local|remote --mode silence|debug --blockscout yes|no"
  echo
  echo "    Environment: local (default) or remote"
  echo "    Mode: silence (default) or debug"
  echo "    Blockscout: no (default) or yes"
  echo
  echo "Options:"
  echo "  -h, --help  Show this help message"
  exit 0
}

# Parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --environment)
        environment="$2"
        shift 2
        ;;
      --mode)
        mode="$2"
        shift 2
        ;;
      --blockscout)
        blockscout="$2"
        shift 2
        ;;
      -h|--help)
        show_help
        ;;
      *)
        echo "Unknown parameter: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

# Cleanup function
cleanup() {
    cd ./ethereum-package
    git restore .
    cd ..
}

# Set trap for cleanup on exit
trap cleanup EXIT

# Get machine IP address
get_machine_ip() {
    local ip=""

    # Try multiple methods to get IP
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

# Configure blockscout for remote access
configure_remote_blockscout() {
    local machine_ip="$1"

    log_info "Copy blockscout configuration..."
    cp "$BLOCKSCOUT_CONFIG_FILE" "$BLOCKSCOUT_FILE"

    log_info "Configuring blockscout for remote access (IP: $machine_ip)..."
    sed -i.tmp "s/else \"localhost:{0}\"/else \"$machine_ip:{0}\"/g" "$BLOCKSCOUT_FILE"
    rm -f "${BLOCKSCOUT_FILE}.tmp"

    log_success "Blockscout configured for remote access"
}

# Configure shared_utils for more ports
configure_shared_utils() {
    log_info "Copy shared_utils configuration..."

    cp "$SHARED_UTILS_CONFIG_FILE" "$SHARED_UTILS_FILE"

    log_info "Configured shared_utils for more ports..."
}

# Configure input_parser for blockscout image
configure_input_parser() {
    log_info "Copy input_parser configuration..."

    cp "$INPUT_PARSER_CONFIG_FILE" "$INPUT_PARSER_FILE"

    log_info "Configured input_parser for blockscout image..."
}

# Configure spamoor for fixed port
configure_spamoor() {
    log_info "Copy spamoor configuration..."

    cp "$SPAMOOR_CONFIG_FILE" "$SPAMOOR_FILE"
    cp "$MAIN_CONFIG_FILE" "$MAIN_FILE"

    log_info "Configured spamoor for fixed port..."
}

# Configure genesis values.env template for correct slot timing
configure_genesis_values() {
    log_info "Copy genesis values.env template..."

    cp "$VALUES_ENV_CONFIG_FILE" "$VALUES_ENV_FILE"

    log_info "Configured genesis values.env template for correct slot timing..."
}

# Configure network params with seconds_per_slot from .env
configure_network_params() {
    if [[ -n "${SECONDS_PER_SLOT:-}" ]]; then
        log_info "Configuring seconds_per_slot to $SECONDS_PER_SLOT in network_params.yaml..."
        sed -i.tmp "s/^\(\s*seconds_per_slot:\s*\)[0-9]\+/\1$SECONDS_PER_SLOT/" "$NETWORK_PARAMS"
        rm -f "${NETWORK_PARAMS}.tmp"
        log_success "Network params configured with seconds_per_slot: $SECONDS_PER_SLOT"
    else
        log_warning "SECONDS_PER_SLOT not set in .env, using default value from network_params.yaml"
    fi
}

# Simple progress indicator
show_progress() {
    local pid=$1
    local message="$2"
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    printf "%s " "$message"
    while kill -0 $pid 2>/dev/null; do
        printf "\b%s" "${spinner:i++%${#spinner}:1}"
        sleep 0.1
    done
    echo
    printf "\b\n"
}

# Validate environment
validate_environment() {
    log_info "Validating environment..."

    # Check if enclave already exists
    if kurtosis enclave ls | grep -q "$ENCLAVE_NAME"; then
        log_warning "Enclave '$ENCLAVE_NAME' already exists"
        log_info "Removing existing enclave..."
        kurtosis enclave rm "$ENCLAVE_NAME" --force >/dev/null 2>&1 || true
    fi

    # Check Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running or not accessible"
        log_error "Please start Docker and ensure your user has docker permissions"
        return 1
    fi

    # Check network params file exists
    if [[ ! -f "$NETWORK_PARAMS" ]]; then
        log_error "Network parameters file not found: $NETWORK_PARAMS"
        return 1
    fi

    log_success "Environment validation passed"
    return 0
}

# Run kurtosis with different settings
run_kurtosis() {
    local environment="$1"
    local mode="$2"

    if [[ "$mode" == 0 ]]; then
        mode="silence"
    else
        mode="debug"
    fi

    echo
    log_info "Starting Surge DevNet L1 ($environment environment) in $mode mode..."
    echo

    local exit_status=0
    local temp_output="/tmp/surge_devnet_l1_output_$$"

    # Run kurtosis based on mode
    if [[ "$mode" == "debug" ]]; then
        # Debug mode: run in foreground, capture output for error detection
        kurtosis run --enclave "$ENCLAVE_NAME" ./ethereum-package --args-file "$NETWORK_PARAMS" --production --image-download always --verbosity brief 2>&1 | tee "$temp_output"
        exit_status=${PIPESTATUS[0]}
    else
        # Silent mode: run in background with progress indicator
        kurtosis run --enclave "$ENCLAVE_NAME" ./ethereum-package --args-file "$NETWORK_PARAMS" --production --image-download always >"$temp_output" 2>&1 &
        local kurtosis_pid=$!
        show_progress $kurtosis_pid "Initializing Surge DevNet L1..."
        echo

        # Wait for completion and check status
        wait $kurtosis_pid
        exit_status=$?
    fi

    # Check for specific error patterns in the output
    local has_errors=false
    if [[ -f "$temp_output" ]]; then
        if grep -q "Error encountered running Starlark code" "$temp_output"; then
            has_errors=true
            log_error "Starlark execution failed"
        fi
        # TODO: Add more error detection
    fi

    # Clean up temp file (disabled for debugging purposes)
    # rm -f "$temp_output"

    # Check the actual exit status and error patterns
    if [[ $exit_status -eq 0 && "$has_errors" == "false" ]]; then
        log_success "Surge DevNet L1 started successfully in $environment environment"
        return 0
    else
        log_error "Failed to start Surge DevNet L1 (exit code: $exit_status)"
        if [[ "$mode" == "silence" ]]; then
            log_error "Run with debug mode for more details: --mode debug"
        fi
        log_error "Common issues:"
        log_error "  • Check if Docker images exist and are accessible"
        log_error "  • Verify network_params.yaml configuration"
        log_error "  • Ensure sufficient system resources"
        log_error "Contact Surge team for help if the problem persists"
        log_error "The output of the deployment is saved in $temp_output"
        log_error "Please share the output with the Surge team"
        return 1
    fi
}

# Check network health
check_network_health() {
    log_info "Checking network health..."

    local el_healthy=false
    local cl_healthy=false

    # Check Execution Layer
    if curl -s http://localhost:32003 -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","id":0,"method":"eth_syncing","params":[]}' \
        | jq -r '.result == false' >/dev/null 2>&1; then
        log_success "Execution Layer is synced"
        el_healthy=true
    else
        log_warning "Execution Layer is not synced or unreachable"
    fi

    # Check Consensus Layer
    if curl -s http://localhost:33001/lighthouse/syncing \
        | jq -r '.data == "Synced"' >/dev/null 2>&1; then
        log_success "Beacon Node is synced"
        cl_healthy=true
    else
        log_warning "Beacon Node is not synced or unreachable"
    fi

    if [[ "$el_healthy" == true && "$cl_healthy" == true ]]; then
        log_success "Network is healthy and ready"
    else
        log_warning "Network may still be starting up. Check again in a few minutes."
    fi
}

# Prompt user for deployment environment
prompt_deployment_environment() {
    read -p "Enter choice [0]: " choice
    choice=${choice:-0}
    echo $choice
}

# Prompt user for deployment mode
prompt_deployment_mode() {
    read -p "Enter choice [0]: " choice
    choice=${choice:-0}
    echo $choice
}

# Display main services information
display_services_information() {
    echo
    log_info "Here are the main services information..."
    echo

    # Hardcoded the ports for now
    # TODO: Update this to retrieve the ports from the enclave inspect output
    local el_rpc=32003
    local el_ws=32004
    local cl_api=33001
    local blockscout_frontend=36002
    local spamoor_url=36003

    echo "Key Service Endpoints:"
    echo
    echo "Execution Layer RPC:    http://127.0.0.1:$el_rpc"
    echo "Execution Layer WS:     ws://127.0.0.1:$el_ws"
    echo "Consensus Layer API:    http://127.0.0.1:$cl_api"
    echo "Block Explorer:         http://127.0.0.1:$blockscout_frontend"
    echo "Transaction Spammer UI:    http://127.0.0.1:$spamoor_url"
    echo
    echo "Use these URLs to interact with your Surge DevNet L1!"
}

# Main function
main() {
    # Show help if requested
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        show_help
    fi

    # Parse arguments
    parse_arguments "$@"

    log_info "Starting $SCRIPT_NAME..."

    # Check dependencies
    for cmd in kurtosis curl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command '$cmd' not found. Please install it first."
            exit 1
        fi
    done

    local env_choice
    if [[ -z "${environment:-}" ]]; then
        # Prompt deployment environment message
        echo
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "  ⚠️ Select deployment environment:                             "
        echo "║══════════════════════════════════════════════════════════════║"
        echo "║  0 for local (default)                                       ║"
        echo "║  1 for remote                                                ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo

        # Get deployment environment
        env_choice=$(prompt_deployment_environment)
    else
        env_choice=$environment
    fi

    local mode_choice
    if [[ -z "${mode:-}" ]]; then
        # Prompt deployment mode
        echo
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "  ⚠️ Select deployment mode:                             "
        echo "║══════════════════════════════════════════════════════════════║"
        echo "║  0 for silence (default)                                     ║"
        echo "║  1 for debug                                                 ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo

        # Get deployment mode
        mode_choice=$(prompt_deployment_mode)
    else
        mode_choice=$mode
    fi

    if ! validate_environment; then
        log_error "Environment validation failed"
        exit 1
    fi

    case "$env_choice" in
        1|"remote")
            # Remote deployment
            local machine_ip
            machine_ip=$(get_machine_ip)

            if [[ -z "$machine_ip" ]]; then
                log_error "Could not determine machine IP address"
                log_error "Please ensure network connectivity and try again"
                exit 1
            fi

            configure_remote_blockscout "$machine_ip"
            configure_shared_utils
            configure_spamoor
            configure_genesis_values
            configure_network_params
            if ! run_kurtosis "remote" $mode_choice; then
                log_error "Deployment failed, cleaning up..."
                kurtosis enclave rm "$ENCLAVE_NAME" --force >/dev/null 2>&1 || true
                exit 1
            fi
            ;;
        0|"local"|"")
            configure_remote_blockscout "localhost"
            configure_shared_utils
            configure_spamoor
            configure_genesis_values
            configure_network_params
            # Local deployment
            if ! run_kurtosis "local" $mode_choice; then
                log_error "Deployment failed, cleaning up..."
                kurtosis enclave rm "$ENCLAVE_NAME" --force >/dev/null 2>&1 || true
                exit 1
            fi
            ;;
        *)
            log_error "Invalid choice: $env_choice"
            exit 1
            ;;
    esac

    # Check network health
    sleep 5  # Give services time to start
    check_network_health
    
    log_info "Updating blockscout CPU usage for containers:"
    docker update --cpus=".1" `docker ps --format '{{.ID}} {{.Names}}' | grep -E "blockscout" | awk '{print $1}'`

    log_success "Surge DevNet L1 preparation complete!"

    display_services_information
}

# Run main function
main "$@"

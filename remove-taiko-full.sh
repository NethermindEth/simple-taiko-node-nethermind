#!/bin/bash
set -euo pipefail

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENCLAVE_NAME="surge-devnet"
readonly DEPLOYMENTS_DIR="deployments"
readonly ENV_FILE=".env"
readonly COMPOSE_FILE_GETH="docker-compose.yml"
readonly COMPOSE_FILE_NETHERMIND="docker-compose-nethermind.yml"
readonly COMPOSE_FILE_RETH="docker-compose-alethia-reth.yml"

# Default argument values
remove_l1_devnet=""
remove_stack=""
remove_volumes=""
remove_deployments=""
remove_env=""
mode=""
force=""

# Source shared helpers
source "${SCRIPT_DIR}/helpers.sh"

# ─── Help ─────────────────────────────────────────────────────────────────────
show_help() {
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo
    echo "Description:"
    echo "  Remove Taiko devnet stack components: L1 devnet enclave, L2 containers,"
    echo "  Docker volumes, deployment files, and environment configuration."
    echo
    echo "Options:"
    echo "  --remove-l1-devnet BOOL    Remove L1 devnet enclave (true|false)"
    echo "  --remove-stack BOOL        Remove L2 stack containers (true|false)"
    echo "  --remove-volumes BOOL      Remove Docker volumes (true|false)"
    echo "  --remove-deployments BOOL  Remove deployment JSON files (true|false)"
    echo "  --remove-env BOOL          Remove .env file (true|false)"
    echo "  --mode MODE                Output mode: silence|debug (default: silence)"
    echo "  -f, --force                Skip confirmation prompts"
    echo "  -h, --help                 Show this help message"
    echo
    echo "Execution Modes:"
    echo "  silence - Silent mode with progress indicators (default)"
    echo "  debug   - Full output for troubleshooting"
    echo
    echo "Examples:"
    echo "  $0                                              # Interactive mode"
    echo "  $0 --force                                     # Remove all (default selection) without prompts"
    echo "  $0 --remove-l1-devnet true --remove-stack true # Remove only containers"
    echo "  $0 --remove-volumes false --remove-env false   # Keep data and .env"
    exit 0
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --remove-l1-devnet)
                remove_l1_devnet="$2"
                shift 2
                ;;
            --remove-stack)
                remove_stack="$2"
                shift 2
                ;;
            --remove-volumes)
                remove_volumes="$2"
                shift 2
                ;;
            --remove-deployments)
                remove_deployments="$2"
                shift 2
                ;;
            --remove-env)
                remove_env="$2"
                shift 2
                ;;
            --mode)
                mode="$2"
                shift 2
                ;;
            -f|--force)
                force="true"
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error "Unknown parameter: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# ─── Detect active execution client ───────────────────────────────────────────
detect_execution_client() {
    if [[ -f "$ENV_FILE" ]]; then
        local client
        client=$(grep "^EXECUTION_CLIENT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)
        if [[ -n "$client" ]]; then
            echo "$client"
            return
        fi
    fi
    echo "nethermind"
}

# ─── Remove L1 devnet ─────────────────────────────────────────────────────────
remove_l1_devnet_enclave() {
    local mode_choice="$1"

    if ! check_kurtosis_available; then
        log_warning "Kurtosis is not available, skipping L1 devnet removal"
        return 0
    fi

    if ! check_l1_devnet_exists; then
        log_info "L1 devnet enclave '$ENCLAVE_NAME' not found, skipping"
        return 0
    fi

    log_info "Removing L1 devnet enclave '$ENCLAVE_NAME'..."

    local exit_status=0
    local temp_output="/tmp/taiko_remove_l1_output_$$"

    if [[ "$mode_choice" == "debug" ]]; then
        kurtosis enclave rm "$ENCLAVE_NAME" --force 2>&1 | tee "$temp_output"
        exit_status=${PIPESTATUS[0]}
    else
        kurtosis enclave rm "$ENCLAVE_NAME" --force >"$temp_output" 2>&1 &
        local remove_pid=$!

        show_progress $remove_pid "Stopping and removing L1 devnet..."

        wait $remove_pid
        exit_status=$?
    fi

    if [[ $exit_status -eq 0 ]]; then
        log_success "L1 devnet enclave removed"
        cleanup_kurtosis_resources "$mode_choice"
        return 0
    else
        log_error "Failed to remove L1 devnet enclave (exit code: $exit_status)"
        if [[ "$mode_choice" == "silence" ]]; then
            log_error "Re-run with --mode debug for full output"
        fi
        log_error "Output saved to: $temp_output"
        return 1
    fi
}

# ─── Clean up Kurtosis system resources ──────────────────────────────────────
cleanup_kurtosis_resources() {
    local mode_choice="$1"

    log_info "Cleaning up Kurtosis resources..."

    if [[ "$mode_choice" == "debug" ]]; then
        kurtosis clean -a 2>&1 || true
    else
        kurtosis clean -a >/dev/null 2>&1 &
        local cleanup_pid=$!
        show_progress $cleanup_pid "Cleaning up unused resources..."
        wait $cleanup_pid || true
    fi

    log_success "Kurtosis cleanup complete"
}

# ─── Remove L2 stack containers ──────────────────────────────────────────────
remove_l2_stack() {
    local client_choice="$1"
    local mode_choice="$2"

    log_info "Removing L2 stack containers (client: $client_choice)..."

    local exit_status=0
    local temp_output="/tmp/taiko_remove_stack_output_$$"

    run_stack_down() {
        # Best-effort docker compose down for both stacks with all profiles
        docker compose -f "$COMPOSE_FILE_GETH" \
            --profile stack --profile deploy --profile blockscout --profile spammer \
            down --remove-orphans 2>&1 || true
        docker compose -f "$COMPOSE_FILE_NETHERMIND" \
            --profile stack --profile blockscout --profile spammer \
            down --remove-orphans 2>&1 || true
        docker compose -f "$COMPOSE_FILE_RETH" \
            --profile stack --profile deploy --profile blockscout --profile spammer \
            down --remove-orphans 2>&1 || true

        # Hard fallback: SIGKILL then force-remove all known containers by name
        # in case docker compose down missed any (project-name mismatch, profile
        # omissions, or containers that ignore SIGTERM)
        local known_containers=(
            alethia-reth-1 alethia-reth-2
            taiko-nethermind-1 taiko-nethermind-2
            taiko-geth-1 taiko-geth-2
            taiko-driver-1 taiko-driver-2
            catalyst-node-1 catalyst-node-2
            fork-switch transfer-funds p2p-bootnode
            web3signer_l1 web3signer_l2
            pacaya-deployer shasta-deployer
            l2-tx-spammer
            l2-blockscout l2-blockscout-frontend
            l2-blockscout-postgres l2-blockscout-verif
        )
        docker kill --signal=SIGKILL "${known_containers[@]}" 2>/dev/null || true
        docker rm -f "${known_containers[@]}" 2>/dev/null || true
    }

    if [[ "$mode_choice" == "debug" ]]; then
        run_stack_down | tee "$temp_output"
        exit_status=${PIPESTATUS[0]}
    else
        run_stack_down >"$temp_output" 2>&1 &
        local remove_pid=$!

        show_progress $remove_pid "Removing L2 stack containers..."

        wait $remove_pid
        exit_status=$?
    fi

    if [[ $exit_status -eq 0 ]]; then
        log_success "L2 stack containers removed"
        return 0
    else
        log_error "Failed to remove L2 stack containers (exit code: $exit_status)"
        if [[ "$mode_choice" == "silence" ]]; then
            log_error "Re-run with --mode debug for full output"
        fi
        log_error "Output saved to: $temp_output"
        return 1
    fi
}

# ─── Remove Docker volumes ───────────────────────────────────────────────────
remove_docker_volumes() {
    local mode_choice="$1"

    log_info "Removing Docker volumes..."

    local exit_status=0
    local temp_output="/tmp/taiko_remove_volumes_output_$$"

    run_volume_removal() {
        # Best-effort docker compose down -v for both stacks
        docker compose -f "$COMPOSE_FILE_GETH" \
            --profile stack --profile blockscout --profile spammer \
            down -v --remove-orphans 2>&1 || true
        docker compose -f "$COMPOSE_FILE_NETHERMIND" \
            --profile stack --profile blockscout --profile spammer \
            down -v --remove-orphans 2>&1 || true
        docker compose -f "$COMPOSE_FILE_RETH" \
            --profile stack --profile blockscout --profile spammer \
            down -v --remove-orphans 2>&1 || true

        # Hard fallback: remove known named volumes that compose may have missed
        local known_volumes=(
            simple-taiko-node-nethermind_alethia-reth-data-1
            simple-taiko-node-nethermind_alethia-reth-data-2
            simple-taiko-node-nethermind_taiko-nethermind-data-1
            simple-taiko-node-nethermind_taiko-nethermind-data-2
            simple-taiko-node-nethermind_taiko-geth-data-1
            simple-taiko-node-nethermind_taiko-geth-data-2
            simple-taiko-node-nethermind_bootnode-data
            simple-taiko-node-nethermind_blockscout-postgres-data
        )
        docker volume rm "${known_volumes[@]}" 2>/dev/null || true
    }

    if [[ "$mode_choice" == "debug" ]]; then
        run_volume_removal | tee "$temp_output"
        exit_status=${PIPESTATUS[0]}
    else
        run_volume_removal >"$temp_output" 2>&1 &
        local remove_pid=$!

        show_progress $remove_pid "Removing Docker volumes..."

        wait $remove_pid
        exit_status=$?
    fi

    if [[ $exit_status -eq 0 ]]; then
        log_success "Docker volumes removed"
        return 0
    else
        log_warning "Volume removal completed with warnings (exit code: $exit_status)"
        return 0  # Non-critical
    fi
}

# ─── Remove deployment files ──────────────────────────────────────────────────
remove_deployment_files() {
    log_info "Removing deployment files..."

    local removed=()
    local failed=()

    if [[ -d "$DEPLOYMENTS_DIR" ]]; then
        local deployment_files=(
            "${DEPLOYMENTS_DIR}/deploy_l1_pacaya.json"
            "${DEPLOYMENTS_DIR}/deploy_l1_shasta.json"
            "${DEPLOYMENTS_DIR}/deploy_l1.json"
            "${DEPLOYMENTS_DIR}/deploy_l1_base.json"
        )

        for file in "${deployment_files[@]}"; do
            if [[ -f "$file" ]]; then
                if rm -f "$file" 2>/dev/null; then
                    removed+=("$file")
                else
                    failed+=("$file")
                fi
            fi
        done
    fi

    if [[ ${#removed[@]} -gt 0 ]]; then
        log_success "Removed deployment files: ${#removed[@]} file(s)"
    fi

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Failed to remove: ${failed[*]}"
        return 1
    fi

    if [[ ${#removed[@]} -eq 0 ]]; then
        log_info "No deployment files found to remove"
    fi

    return 0
}

# ─── Remove .env file ─────────────────────────────────────────────────────────
remove_env_file() {
    log_info "Removing .env file..."

    if [[ -f "$ENV_FILE" ]]; then
        if rm -f "$ENV_FILE" 2>/dev/null; then
            log_success ".env file removed"
        else
            log_error "Failed to remove .env file"
            return 1
        fi
    else
        log_info "No .env file found"
    fi

    return 0
}

# ─── Component selection prompt ───────────────────────────────────────────────
prompt_component_selection() {
    echo >&2
    echo "╔══════════════════════════════════════════════════════════════╗" >&2
    echo "  Select components to remove:                                  " >&2
    echo "║══════════════════════════════════════════════════════════════║" >&2
    echo "║  1. L1 devnet enclave (Kurtosis)                             ║" >&2
    echo "║  2. L2 stack containers                                      ║" >&2
    echo "║  3. Docker volumes (execution client data)                   ║" >&2
    echo "║  4. Deployment files (deployments/*.json)                    ║" >&2
    echo "║  5. Environment file (.env)                                  ║" >&2
    echo "║  [default: 1,2,3,4 — keep .env]                              ║" >&2
    echo "╚══════════════════════════════════════════════════════════════╝" >&2
    echo >&2
    read -p "Enter components to remove (1-5, comma-separated) [1,2,3,4]: " components
    components=${components:-"1,2,3,4"}
    echo "$components"
}

# ─── Confirmation prompt ──────────────────────────────────────────────────────
prompt_confirmation() {
    local components_msg="$1"

    echo >&2
    echo "╔══════════════════════════════════════════════════════════════╗" >&2
    echo "  Confirm Taiko Stack Removal                                   " >&2
    echo "║══════════════════════════════════════════════════════════════║" >&2
    echo "║  This will remove the following:                             ║" >&2
    echo "$components_msg" >&2
    echo "║                                                              ║" >&2
    echo "║  Are you sure you want to continue?                          ║" >&2
    echo "╚══════════════════════════════════════════════════════════════╝" >&2
    echo >&2
    read -p "Enter 'yes' to confirm removal: " confirmation

    [[ "$confirmation" == "yes" ]]
}

# ─── Build confirmation message ───────────────────────────────────────────────
build_confirmation_message() {
    local l1="$1"
    local stack="$2"
    local volumes="$3"
    local deployments="$4"
    local env="$5"

    local msg=""

    [[ "$l1" == "true" ]]          && msg+="║  • L1 devnet enclave (Kurtosis)                              ║\n"
    [[ "$stack" == "true" ]]       && msg+="║  • L2 stack containers                                       ║\n"
    [[ "$volumes" == "true" ]]     && msg+="║  • Docker volumes (execution client data)                    ║\n"
    [[ "$deployments" == "true" ]] && msg+="║  • Deployment files (deployments/*.json)                     ║\n"
    [[ "$env" == "true" ]]         && msg+="║  • Environment file (.env)                                   ║\n"

    if [[ -z "$msg" ]]; then
        msg="║  • (No components selected)                                  ║\n"
    fi

    echo -e "$msg"
}

# ─── Removal summary ──────────────────────────────────────────────────────────
display_removal_summary() {
    local l1="$1"
    local stack="$2"
    local volumes="$3"
    local deployments="$4"
    local env="$5"

    echo
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Taiko Stack Removal Complete                                ║"
    echo "║                                                              ║"
    echo "║  Components removed:                                         ║"

    [[ "$l1" == "true" ]]          && echo "║  • L1 devnet enclave                                         ║"
    [[ "$stack" == "true" ]]       && echo "║  • L2 stack containers                                       ║"
    [[ "$volumes" == "true" ]]     && echo "║  • Docker volumes                                            ║"
    [[ "$deployments" == "true" ]] && echo "║  • Deployment files                                          ║"
    [[ "$env" == "true" ]]         && echo "║  • Environment file (.env)                                   ║"

    echo "║                                                              ║"
    echo "║  To deploy a new instance, run:                              ║"
    echo "║  ./deploy-taiko-full.sh                                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        show_help
    fi

    parse_arguments "$@"

    log_info "Starting $SCRIPT_NAME..."

    # Validate Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker is not running or not accessible"
        exit 1
    fi

    # Detect active execution client for targeted removal
    local active_client
    active_client=$(detect_execution_client)
    log_info "Detected execution client: $active_client"

    # Report L1 devnet status
    if check_l1_devnet_exists; then
        local l1_status
        l1_status=$(get_l1_devnet_status)
        log_info "Found L1 devnet enclave (Status: $l1_status)"
    else
        log_info "No L1 devnet enclave found"
    fi

    # ── Component selection ────────────────────────────────────────────────────
    local components_to_remove=""
    if [[ -z "${remove_l1_devnet:-}${remove_stack:-}${remove_volumes:-}${remove_deployments:-}${remove_env:-}" ]]; then
        if [[ "$force" == "true" ]]; then
            # --force with no explicit component flags: remove everything except .env
            remove_l1_devnet="true"
            remove_stack="true"
            remove_volumes="true"
            remove_deployments="true"
            remove_env="${remove_env:-false}"
        else
            components_to_remove=$(prompt_component_selection)
        fi
    fi

    # Parse numeric component selection
    if [[ -n "${components_to_remove:-}" ]]; then
        local COMPONENTS=()
        IFS=',' read -ra COMPONENTS <<< "$components_to_remove"
        for component in "${COMPONENTS[@]}"; do
            component="${component// /}"
            case "$component" in
                1) remove_l1_devnet="true" ;;
                2) remove_stack="true" ;;
                3) remove_volumes="true" ;;
                4) remove_deployments="true" ;;
                5) remove_env="true" ;;
            esac
        done
    fi

    # ── Resolve mode ──────────────────────────────────────────────────────────
    local mode_choice
    if [[ -z "${mode:-}" ]]; then
        if [[ "$force" == "true" ]]; then
            mode_choice="silence"
        else
            local mode_raw
            mode_raw=$(prompt_mode_selection)
            case "$mode_raw" in
                1|"debug") mode_choice="debug" ;;
                *)          mode_choice="silence" ;;
            esac
        fi
    else
        mode_choice="$mode"
    fi

    case "$mode_choice" in
        0|"silence"|"") mode_choice="silence" ;;
        1|"debug")       mode_choice="debug" ;;
        *)
            log_error "Invalid mode: $mode_choice"
            exit 1
            ;;
    esac

    # ── Confirmation ──────────────────────────────────────────────────────────
    if [[ "$force" != "true" ]]; then
        local confirmation_msg
        confirmation_msg=$(build_confirmation_message \
            "${remove_l1_devnet:-false}" \
            "${remove_stack:-false}" \
            "${remove_volumes:-false}" \
            "${remove_deployments:-false}" \
            "${remove_env:-false}")

        if ! prompt_confirmation "$confirmation_msg"; then
            log_info "Removal cancelled by user"
            exit 0
        fi
    fi

    echo
    log_info "Beginning Taiko Stack removal..."

    # ── Remove L1 devnet ──────────────────────────────────────────────────────
    if [[ "${remove_l1_devnet:-false}" == "true" ]]; then
        if ! remove_l1_devnet_enclave "$mode_choice"; then
            log_error "Failed to remove L1 devnet"
            exit 1
        fi
    fi

    # ── Remove L2 stack (must happen before volume removal) ───────────────────
    if [[ "${remove_stack:-false}" == "true" ]]; then
        if ! remove_l2_stack "$active_client" "$mode_choice"; then
            log_error "Failed to remove L2 stack"
            exit 1
        fi
    fi

    # ── Remove volumes ────────────────────────────────────────────────────────
    if [[ "${remove_volumes:-false}" == "true" ]]; then
        if ! remove_docker_volumes "$mode_choice"; then
            log_warning "Some volumes could not be removed (continuing)"
        fi
    fi

    # ── Remove deployment files ───────────────────────────────────────────────
    if [[ "${remove_deployments:-false}" == "true" ]]; then
        if ! remove_deployment_files; then
            log_warning "Some deployment files could not be removed (continuing)"
        fi
    fi

    # ── Remove .env ───────────────────────────────────────────────────────────
    if [[ "${remove_env:-false}" == "true" ]]; then
        if ! remove_env_file; then
            log_error "Failed to remove .env file"
            exit 1
        fi
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    display_removal_summary \
        "${remove_l1_devnet:-false}" \
        "${remove_stack:-false}" \
        "${remove_volumes:-false}" \
        "${remove_deployments:-false}" \
        "${remove_env:-false}"

    log_success "Taiko Stack removal complete!"
}

main "$@"

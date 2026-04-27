#!/bin/bash
set -euo pipefail

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENCLAVE_NAME="surge-devnet"
readonly CONFIGS_DIR="configs"
readonly DEPLOYMENTS_DIR="deployments"
readonly ENV_FILE=".env"
readonly COMPOSE_FILE_GETH="docker-compose.yml"
readonly COMPOSE_FILE_NETHERMIND="docker-compose-nethermind.yml"
readonly COMPOSE_FILE_RETH="docker-compose-alethia-reth.yml"

readonly NETHERMIND_IMAGE="nethermindeth/nethermind:master"
readonly STATIC_DIR="./static"
readonly CHAINSPEC_FILE="${STATIC_DIR}/taiko-shasta-chainspec.json"
readonly GENESIS_FILE="${STATIC_DIR}/genesis.json"
readonly TAIKO_GENESIS_URL="${TAIKO_GENESIS_URL:-https://raw.githubusercontent.com/taikoxyz/taiko-geth/taiko/core/taiko_genesis/internal.json}"
readonly GEN2SPEC_URL="${SURGE_GEN2SPEC_URL:-https://raw.githubusercontent.com/NethermindEth/core-scripts/refs/heads/main/gen2spec/gen2spec.jq}"

# ethereum-package file references
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

# Default argument values
environment=""
client=""
mode=""
skip_l1_devnet="false"
skip_contracts="false"
enable_l1_blockscout=""
enable_l2_blockscout=""
enable_l2_spammer=""
force=""

# Source shared helpers
source "${SCRIPT_DIR}/helpers.sh"

# Unified exit/interrupt handler — cleans up genesis check containers and
# restores ethereum-package modifications.  Must be declared before any
# sub-traps so it is not silently overwritten later.
_cleanup() {
    docker rm -f taiko-genesis-check nethermind-genesis-hash 2>/dev/null || true
    cleanup_ethereum_package
}
trap '_cleanup; exit 130' INT TERM
trap '_cleanup' EXIT

# ─── Help ─────────────────────────────────────────────────────────────────────
show_help() {
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo
    echo "Description:"
    echo "  Deploy a complete Taiko devnet stack: L1 (Kurtosis ethereum-package),"
    echo "  L1 contracts (Pacaya + Shasta), and L2 Catalyst stack."
    echo
    echo "Options:"
    echo "  --environment ENV     L1 devnet environment: local|remote (default: local)"
    echo "  --client CLIENT       L2 execution client: nethermind|geth (default: from .env or nethermind)"
    echo "  --skip-l1-devnet      Skip L1 devnet deployment (use an already-running devnet)"
    echo "  --skip-contracts      Skip contract deployment (use existing deployments/)"
    echo "  --l1-blockscout       Enable Blockscout in the L1 devnet"
    echo "  --l2-blockscout BOOL  Enable L2 Blockscout explorer (true|false)"
    echo "  --l2-spammer BOOL     Enable L2 transaction spammer (true|false)"
    echo "  --mode MODE           Output mode: silence|debug (default: silence)"
    echo "  -f, --force           Skip all confirmation prompts"
    echo "  -h, --help            Show this help message"
    echo
    echo "Execution Modes:"
    echo "  silence - Silent mode with progress indicators (default)"
    echo "  debug   - Full output for troubleshooting"
    echo
    echo "Examples:"
    echo "  $0                                              # Interactive mode"
    echo "  $0 --client nethermind --mode debug            # Nethermind with debug output"
    echo "  $0 --skip-l1-devnet --skip-contracts           # Restart stack only"
    echo "  $0 --environment remote --client geth -f       # Non-interactive remote deploy"
    exit 0
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --environment)
                environment="$2"
                shift 2
                ;;
            --client)
                client="$2"
                shift 2
                ;;
            --skip-l1-devnet)
                skip_l1_devnet="true"
                shift
                ;;
            --skip-contracts)
                skip_contracts="true"
                shift
                ;;
            --l1-blockscout)
                enable_l1_blockscout="true"
                shift
                ;;
            --l2-blockscout)
                enable_l2_blockscout="$2"
                shift 2
                ;;
            --l2-spammer)
                enable_l2_spammer="$2"
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

# ─── Cleanup on exit (restore ethereum-package modifications) ─────────────────
cleanup_ethereum_package() {
    if [[ -d "./ethereum-package" ]]; then
        (cd ./ethereum-package && git restore . 2>/dev/null || true)
    fi
}

# ─── Phase 1: L1 devnet via Kurtosis ─────────────────────────────────────────
deploy_l1_devnet() {
    local env_choice="$1"
    local mode_choice="$2"
    local blockscout="$3"

    log_info "Deploying L1 devnet..."

    # Remove existing enclave if present
    if check_l1_devnet_exists; then
        log_warning "Enclave '$ENCLAVE_NAME' already exists — removing it first..."
        kurtosis enclave rm "$ENCLAVE_NAME" --force >/dev/null 2>&1 || true
    fi

    # Toggle blockscout in network_params.yaml
    if [[ "$blockscout" == "true" ]]; then
        sed_inplace 's/^  # - blockscout$/  - blockscout/' "$NETWORK_PARAMS"
        sed_inplace 's/^additional_services: \[\]$/additional_services:/' "$NETWORK_PARAMS"
        log_info "Blockscout enabled"
    else
        sed_inplace 's/^  - blockscout$/  # - blockscout/' "$NETWORK_PARAMS"
        sed_inplace 's/^additional_services:$/additional_services: []/' "$NETWORK_PARAMS"
    fi

    # Configure ethereum-package files
    case "$env_choice" in
        1|"remote")
            local machine_ip
            machine_ip=$(get_machine_ip)
            if [[ -z "$machine_ip" ]]; then
                log_error "Could not determine machine IP address"
                return 1
            fi
            configure_remote_blockscout "$machine_ip"
            ;;
        *)
            configure_remote_blockscout "localhost"
            ;;
    esac

    configure_shared_utils
    configure_input_parser
    configure_spamoor
    configure_genesis_values
    configure_network_params

    log_info "Starting Surge DevNet L1..."
    echo

    local abs_network_params
    abs_network_params="$(realpath "$NETWORK_PARAMS")"

    local exit_status=0
    local temp_output="/tmp/taiko_devnet_l1_output_$$"

    if [[ "$mode_choice" == "debug" ]]; then
        (cd ./ethereum-package && kurtosis run --enclave "$ENCLAVE_NAME" . \
            --args-file "$abs_network_params" \
            --production \
            --image-download always \
            --verbosity brief) 2>&1 | tee "$temp_output"
        exit_status=${PIPESTATUS[0]}
    else
        (cd ./ethereum-package && kurtosis run --enclave "$ENCLAVE_NAME" . \
            --args-file "$abs_network_params" \
            --production \
            --image-download always) >"$temp_output" 2>&1 &
        local kurtosis_pid=$!

        show_progress $kurtosis_pid "Initializing Surge DevNet L1..."
        echo

        wait $kurtosis_pid
        exit_status=$?
    fi

    # Check for Starlark errors even on exit code 0
    local has_errors=false
    if [[ -f "$temp_output" ]] && grep -q "Error encountered running Starlark code" "$temp_output"; then
        has_errors=true
        log_error "Starlark execution failed"
    fi

    if [[ $exit_status -eq 0 && "$has_errors" == "false" ]]; then
        log_success "L1 devnet started successfully"
        return 0
    else
        log_error "Failed to start L1 devnet (exit code: $exit_status)"
        if [[ "$mode_choice" == "silence" ]]; then
            log_error "Re-run with --mode debug for full output"
        fi
        log_error "Output saved to: $temp_output"
        kurtosis enclave rm "$ENCLAVE_NAME" --force >/dev/null 2>&1 || true
        return 1
    fi
}

# ─── Phase 2: Shasta contract deployment ──────────────────────────────────────
deploy_shasta_contracts() {
    local mode_choice="$1"

    local output_file="${DEPLOYMENTS_DIR}/deploy_l1_shasta.json"

    if [[ -f "$output_file" ]]; then
        log_info "Shasta contracts already deployed ($output_file found), skipping"
        return 0
    fi

    log_info "Deploying Shasta contracts..."

    local exit_status=0
    local temp_output="/tmp/taiko_shasta_deploy_output_$$"

    if [[ "$mode_choice" == "debug" ]]; then
        docker compose -f "$COMPOSE_FILE_GETH" --profile deploy up shasta-deployer 2>&1 | tee "$temp_output"
        exit_status=${PIPESTATUS[0]}
    else
        docker compose -f "$COMPOSE_FILE_GETH" --profile deploy up shasta-deployer >"$temp_output" 2>&1 &
        local deploy_pid=$!

        show_progress $deploy_pid "Deploying Shasta contracts..."

        wait $deploy_pid
        exit_status=$?
    fi

    if [[ $exit_status -ne 0 ]]; then
        log_error "Shasta contract deployment failed (exit code: $exit_status)"
        if [[ "$mode_choice" == "silence" ]]; then
            log_error "Re-run with --mode debug for full output"
        fi
        log_error "Output saved to: $temp_output"
        return 1
    fi

    if [[ ! -f "$output_file" ]]; then
        log_error "Deployment succeeded but $output_file not found"
        log_error "Check deployer logs: docker logs shasta-deployer"
        return 1
    fi

    log_info "Extracting Shasta contract addresses..."

    local addr
    addr=$(cat "$output_file" | jq -r '.automata_dcap_attestation')         && update_env_var "$ENV_FILE" "SHASTA_AUTOMATA_DCAP_ATTESTATION" "$addr"
    addr=$(cat "$output_file" | jq -r '.bridge')                             && update_env_var "$ENV_FILE" "SHASTA_BRIDGE" "$addr"
    addr=$(cat "$output_file" | jq -r '.erc1155_vault')                      && update_env_var "$ENV_FILE" "SHASTA_ERC1155_VAULT" "$addr"
    addr=$(cat "$output_file" | jq -r '.erc20_vault')                        && update_env_var "$ENV_FILE" "SHASTA_ERC20_VAULT" "$addr"
    addr=$(cat "$output_file" | jq -r '.erc721_vault')                       && update_env_var "$ENV_FILE" "SHASTA_ERC721_VAULT" "$addr"
    addr=$(cat "$output_file" | jq -r '.prover_whitelist')                   && update_env_var "$ENV_FILE" "SHASTA_PROVER_WHITELIST" "$addr"
    addr=$(cat "$output_file" | jq -r '.sgx_geth_automata_dcap_attestation') && update_env_var "$ENV_FILE" "SHASTA_SGX_GETH_AUTOMATA_DCAP_ATTESTATION" "$addr"
    addr=$(cat "$output_file" | jq -r '.shared_resolver')                    && update_env_var "$ENV_FILE" "SHASTA_SHARED_RESOLVER" "$addr"
    addr=$(cat "$output_file" | jq -r '.shasta_inbox')                       && update_env_var "$ENV_FILE" "SHASTA_SHASTA_INBOX" "$addr"
    addr=$(cat "$output_file" | jq -r '.signal_service')                     && update_env_var "$ENV_FILE" "SHASTA_SIGNAL_SERVICE" "$addr"
    addr=$(cat "$output_file" | jq -r '.preconf_whitelist')                  && update_env_var "$ENV_FILE" "SHASTA_PRECONF_WHITELIST" "$addr"
    addr=$(cat "$output_file" | jq -r '.taiko_token')                        && update_env_var "$ENV_FILE" "SHASTA_TAIKO_TOKEN" "$addr"

    log_success "Shasta contracts deployed and addresses saved"
    return 0
}

# ─── Genesis hash computation ─────────────────────────────────────────────────
# Dynamically computes L2_GENESIS_HASH for the chosen client and writes it to .env.
#
# Fetches the canonical Taiko genesis alloc from the taiko-geth source repository
# and saves it to static/genesis.json.  NOTE: this file is only the alloc
# (address → account map) — NOT a full genesis.json.
fetch_genesis() {
    log_info "Fetching genesis alloc from taiko-geth source..."
    log_info "  URL: $TAIKO_GENESIS_URL"

    mkdir -p "$STATIC_DIR"

    if ! curl -fsSL --max-time 30 "$TAIKO_GENESIS_URL" -o "$GENESIS_FILE" 2>/dev/null; then
        log_error "Failed to fetch genesis alloc — check network or set TAIKO_GENESIS_URL"
        return 1
    fi

    if [[ ! -s "$GENESIS_FILE" ]]; then
        log_error "Fetched genesis alloc is empty: $GENESIS_FILE"
        return 1
    fi

    log_success "Genesis alloc saved to $GENESIS_FILE"
}

# Computes L2_GENESIS_HASH and writes it to .env.
#
# Always fetches the canonical genesis alloc first, then spins up taiko-geth
# briefly to read the authoritative genesis block.
#
# Geth:
#   Uses the hash from eth_getBlockByNumber("0x0") directly.
#
# Nethermind:
#   Builds a complete genesis.json by combining:
#     - alloc  from the fetched internal.json
#     - header from the taiko-geth genesis block (gasLimit, extraData, etc.)
#     - config synthesised from env vars
#   Converts that to a Nethermind chainspec via gen2spec, then starts
#   Nethermind briefly to confirm the hash from its startup logs.
#
# L2_GENESIS_HASH is written to .env either way.
compute_genesis_hash() {
    local client_choice="$1"

    log_info "Computing L2 genesis hash for client: $client_choice"

    # ── Step 0: fetch canonical genesis alloc ─────────────────────────────────
    if ! fetch_genesis; then
        log_error "Cannot proceed without a valid genesis alloc"
        return 1
    fi

    # ── Step 1: start taiko-geth and read genesis block ───────────────────────
    local geth_image="${TAIKO_GETH_IMAGE:-}"
    if [[ -z "$geth_image" ]]; then
        log_error "TAIKO_GETH_IMAGE is not set in .env"
        return 1
    fi

    local temp_port=28545
    docker rm -f taiko-genesis-check 2>/dev/null || true

    log_info "Starting temporary taiko-geth to read embedded genesis..."
    docker run -d --name taiko-genesis-check \
        -p "${temp_port}:8545" \
        "$geth_image" \
        --datadir /tmp/genesis-check \
        --networkid "${L2_CHAIN_ID:-167001}" \
        --http --http.addr 0.0.0.0 --http.port 8545 \
        --http.api eth \
        --http.vhosts='*' \
        --nodiscover --maxpeers 0 \
        --taiko \
        --taiko.internal-shasta-time "${TAIKO_INTERNAL_SHASTA_TIME:-0}" \
        >/dev/null 2>&1

    log_info "Waiting for taiko-geth RPC (up to 30s)..."
    local waited=0
    until curl -sf -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            "http://localhost:${temp_port}" | jq -e '.result' >/dev/null 2>&1; do
        if (( waited >= 30 )); then
            log_error "Timed out waiting for taiko-geth genesis check RPC"
            docker logs taiko-genesis-check 2>&1 | tail -20
            docker rm -f taiko-genesis-check 2>/dev/null || true
            return 1
        fi
        sleep 1
        (( waited += 1 ))
    done

    # Capture full genesis block — used for hash (both clients) and header
    # field extraction (nethermind chainspec).
    local genesis_block
    genesis_block=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
        "http://localhost:${temp_port}" | jq '.result')

    docker rm -f taiko-genesis-check 2>/dev/null || true

    local geth_genesis_hash
    geth_genesis_hash=$(echo "$genesis_block" | jq -r '.hash')

    if [[ -z "$geth_genesis_hash" || "$geth_genesis_hash" == "null" ]]; then
        log_error "Failed to get genesis hash from taiko-geth"
        return 1
    fi
    log_info "Geth genesis hash: $geth_genesis_hash"

    if [[ "$client_choice" == "geth" ]]; then
        update_env_var "$ENV_FILE" "L2_GENESIS_HASH" "$geth_genesis_hash"
        log_success "L2_GENESIS_HASH set to $geth_genesis_hash"
        return 0
    fi

    # ── Nethermind ─────────────────────────────────────────────────────────────
    # internal.json is only the alloc (flat address→account map).
    # Build a complete genesis.json by wrapping it with:
    #   - header fields extracted from the taiko-geth genesis block above
    #   - config synthesised from env vars and known Taiko constants

    log_info "Building complete genesis.json from alloc + geth block header..."

    local hex_timestamp
    printf -v hex_timestamp '0x%x' "${TAIKO_INTERNAL_SHASTA_TIME:-0}"

    local hex_unzen_timestamp
    printf -v hex_unzen_timestamp '0x%x' "${UZEN_FORK_TIME:-0}"

    local full_genesis_file
    full_genesis_file=$(mktemp /tmp/taiko-genesis-full.XXXXXX.json)

    # Use --slurpfile to read genesis alloc from file directly (avoids
    # "Argument list too long" when the alloc JSON exceeds shell ARG limits).
    # --slurpfile wraps the content in an array, so reference it as $alloc[0].
    jq -n \
        --slurpfile alloc "$GENESIS_FILE" \
        --argjson block "$genesis_block" \
        --argjson chainId "${L2_CHAIN_ID:-167001}" \
        --arg hexTs "$hex_timestamp" \
        --arg hexUnzenTs "$hex_unzen_timestamp" \
        '{
          config: {
            chainId:             $chainId,
            homesteadBlock:      0,
            eip150Block:         0,
            eip155Block:         0,
            eip158Block:         0,
            byzantiumBlock:      0,
            constantinopleBlock: 0,
            petersburgBlock:     0,
            istanbulBlock:       0,
            berlinBlock:         0,
            londonBlock:         0,
            mergeForkBlock:      0,
            ontakeBlock:         0,
            pacayaBlock:         1,
            shastaTimestamp:     $hexTs,
            unzenTimestamp:      $hexUnzenTs,
            feeCollector:        "0x0000000000000000000000000000000000000000",
            depositContractAddress: "0x0000000000000000000000000000000000000000",
            shanghaiTime:        0,
            cancunTime: 0,
            pragueTime: 0, 
            osakaTime: 0,
            cancunTime:          null,
            taiko:               true
          },
          alloc:        $alloc[0],
          nonce:        $block.nonce,
          mixHash:      $block.mixHash,
          coinbase:     $block.miner,
          timestamp:    $block.timestamp,
          parentHash:   $block.parentHash,
          extraData:    $block.extraData,
          gasLimit:     $block.gasLimit,
          difficulty:   "0x0",
          baseFeePerGas: $block.baseFeePerGas
        }' > "$full_genesis_file"

    log_info "Converting complete genesis to Nethermind chainspec..."

    local gen2spec_file
    gen2spec_file=$(mktemp /tmp/gen2spec.XXXXXX.jq)
    log_info "Fetching gen2spec.jq from: $GEN2SPEC_URL"
    if ! curl -sf --max-time 30 "$GEN2SPEC_URL" -o "$gen2spec_file" 2>/dev/null; then
        log_error "Failed to fetch gen2spec.jq — check network or set SURGE_GEN2SPEC_URL"
        rm -f "$gen2spec_file" "$full_genesis_file"
        return 1
    fi
    if [[ ! -s "$gen2spec_file" ]]; then
        log_error "gen2spec.jq downloaded but is empty"
        rm -f "$gen2spec_file" "$full_genesis_file"
        return 1
    fi

    if ! jq --from-file "$gen2spec_file" "$full_genesis_file" \
            | jq --arg hexTs "$hex_timestamp" '.engine.Taiko.shastaTimestamp = $hexTs' \
            | jq --arg hexUnzenTs "$hex_unzen_timestamp" '.engine.Taiko.unzenTimestamp = $hexUnzenTs' \
            > "$CHAINSPEC_FILE"; then
        log_error "Chainspec conversion failed — check gen2spec output above"
        rm -f "$gen2spec_file" "$full_genesis_file"
        return 1
    fi

    rm -f "$gen2spec_file" "$full_genesis_file"

    if [[ ! -s "$CHAINSPEC_FILE" ]]; then
        log_error "Generated chainspec is empty"
        return 1
    fi

    log_success "Chainspec written to $CHAINSPEC_FILE"

    # Run nethermind briefly to confirm genesis hash from its startup logs
    docker rm -f nethermind-genesis-hash 2>/dev/null || true
    log_info "Running nethermind to compute genesis hash (up to 60s)..."
    docker run -d --name nethermind-genesis-hash \
        -v "$(realpath "$CHAINSPEC_FILE"):/chainspec.json:ro" \
        "$NETHERMIND_IMAGE" \
        --config=none \
        --Init.ChainSpecPath=/chainspec.json \
        >/dev/null 2>&1

    waited=0
    while true; do
        if docker logs nethermind-genesis-hash 2>/dev/null | grep -q "Genesis hash"; then
            break
        fi

        # Stop polling if the container exited — it failed before printing the hash
        local container_status
        container_status=$(docker inspect --format='{{.State.Status}}' nethermind-genesis-hash 2>/dev/null || echo "missing")
        if [[ "$container_status" == "exited" || "$container_status" == "missing" ]]; then
            log_error "Nethermind exited before printing genesis hash"
            docker logs nethermind-genesis-hash 2>&1 | tail -30
            docker rm -f nethermind-genesis-hash 2>/dev/null || true
            return 1
        fi

        if (( waited >= 60 )); then
            log_error "Timed out waiting for nethermind genesis hash"
            docker logs nethermind-genesis-hash 2>&1 | tail -30
            docker rm -f nethermind-genesis-hash 2>/dev/null || true
            return 1
        fi
        sleep 2
        (( waited += 2 ))
    done

    local nmc_genesis_hash
    nmc_genesis_hash=$(docker logs nethermind-genesis-hash 2>/dev/null \
        | grep "Genesis hash" \
        | head -n 1 \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | sed 's/.*Genesis hash : *\(0x[0-9a-fA-F]*\).*/\1/' \
        | tr -d '\r\n ')

    docker rm -f nethermind-genesis-hash 2>/dev/null || true

    if [[ -z "$nmc_genesis_hash" ]]; then
        log_error "Failed to extract genesis hash from nethermind logs"
        return 1
    fi

    update_env_var "$ENV_FILE" "L2_GENESIS_HASH" "$nmc_genesis_hash"
    log_success "L2_GENESIS_HASH set to $nmc_genesis_hash"
    return 0
}

# ─── Phase 3: Start L2 stack ──────────────────────────────────────────────────
# Usage: start_l2_stack <client> <mode> <enable_blockscout> <enable_spammer>
start_l2_stack() {
    local client_choice="$1"
    local mode_choice="$2"
    local with_blockscout="${3:-false}"
    local with_spammer="${4:-false}"

    log_info "Starting L2 Catalyst stack (client: $client_choice)..."

    local compose_file
    case "$client_choice" in
        "nethermind") compose_file="$COMPOSE_FILE_NETHERMIND" ;;
        "geth")       compose_file="$COMPOSE_FILE_GETH" ;;
        "alethia-reth")       compose_file="$COMPOSE_FILE_RETH" ;;
    esac

    # Build profile arguments — stack profile is required for both clients
    local profile_args="--profile stack"
    if [[ "$with_blockscout" == "true" ]]; then
        profile_args="$profile_args --profile blockscout"
    fi
    if [[ "$with_spammer" == "true" ]]; then
        profile_args="$profile_args --profile spammer"
    fi

    local exit_status=0
    local temp_output="/tmp/taiko_stack_output_$$"

    # shellcheck disable=SC2086
    if [[ "$mode_choice" == "debug" ]]; then
        docker compose -f "$compose_file" $profile_args up -d 2>&1 | tee "$temp_output"
        exit_status=${PIPESTATUS[0]}
    else
        docker compose -f "$compose_file" $profile_args up -d >"$temp_output" 2>&1 &
        local stack_pid=$!

        show_progress $stack_pid "Starting L2 stack containers..."

        wait $stack_pid
        exit_status=$?
    fi

    if [[ $exit_status -eq 0 ]]; then
        log_success "L2 stack started"
        return 0
    else
        log_error "Failed to start L2 stack (exit code: $exit_status)"
        if [[ "$mode_choice" == "silence" ]]; then
            log_error "Re-run with --mode debug for full output"
        fi
        log_error "Output saved to: $temp_output"
        return 1
    fi
}

# ─── Health checks ───────────────────────────────────────────────────────────
check_l2_health() {
    local client_choice="$1"

    log_info "Checking L2 health..."

    local rpc_port
    case "$client_choice" in
        "nethermind") rpc_port=8547 ;;
        "geth")       rpc_port=8547 ;;
        "alethia-reth")       rpc_port=8547 ;;
    esac

    local attempts=0
    local max_attempts=15
    while [[ $attempts -lt $max_attempts ]]; do
        if test_rpc_connection "http://localhost:${rpc_port}"; then
            log_success "L2 execution client is responding on port $rpc_port"
            return 0
        fi
        attempts=$(( attempts + 1 ))
        sleep 2
    done

    log_warning "L2 execution client not yet responding on port $rpc_port (may still be starting)"
    return 0
}

check_l1_health() {
    local l1_rpc="${1:-${L1_ENDPOINT_HTTP_EXTERNAL:-http://localhost:32003}}"
    local l1_beacon="${2:-${L1_BEACON_HTTP_EXTERNAL:-http://localhost:33001}}"

    log_info "Checking L1 health..."

    if test_rpc_connection "$l1_rpc"; then
        log_success "L1 execution layer is responding at $l1_rpc"
    else
        log_warning "L1 execution layer not responding at $l1_rpc (may still be starting)"
    fi

    if curl -s --max-time 5 "${l1_beacon}/eth/v1/node/health" >/dev/null 2>&1; then
        log_success "L1 beacon node is responding at $l1_beacon"
    else
        log_warning "L1 beacon node not responding at $l1_beacon (may still be starting)"
    fi
}

# ─── Summary ─────────────────────────────────────────────────────────────────
display_deployment_summary() {
    local client_choice="$1"
    local env_choice="$2"
    local l1_deployed="$3"
    local contracts_deployed="$4"
    local with_blockscout="${5:-false}"
    local with_spammer="${6:-false}"

    local rpc_port="${PORT_L2_EXECUTION_ENGINE_1_HTTP:-8547}"
    local ws_port="${PORT_L2_EXECUTION_ENGINE_1_WS:-8548}"
    local blockscout_frontend_port="${BLOCKSCOUT_FRONTEND_PORT:-3001}"
    local spamoor_port="${SPAMOOR_PORT:-8083}"

    # Use _EXTERNAL URLs if available (set by configure_environment_urls), else localhost
    local l1_rpc_display="${L1_ENDPOINT_HTTP_EXTERNAL:-http://localhost:32003}"
    local l1_ws_display="${L1_ENDPOINT_WS_EXTERNAL:-ws://localhost:32004}"
    local l1_beacon_display="${L1_BEACON_HTTP_EXTERNAL:-http://localhost:33001}"

    # Derive display host for L2 (always localhost on this machine)
    local l2_host="localhost"
    if [[ "$env_choice" == "remote" || "$env_choice" == "1" ]]; then
        l2_host="${l1_rpc_display#http://}"
        l2_host="${l2_host%%:*}"
    fi

    echo
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Taiko Devnet Stack Deployed Successfully!                   ║"
    echo "║                                                              ║"
    echo "║  Stack summary:                                              ║"
    if [[ "$l1_deployed" == "true" ]]; then
        echo "║  • L1 devnet (Kurtosis)          deployed                    ║"
    else
        echo "║  • L1 devnet (Kurtosis)          (pre-existing)              ║"
    fi
    if [[ "$contracts_deployed" == "true" ]]; then
        echo "║  • Pacaya + Shasta contracts     deployed                    ║"
    else
        echo "║  • Pacaya + Shasta contracts     (pre-existing)              ║"
    fi
    printf "║  • L2 execution client           %-28s║\n" "$client_choice"
    echo "║  • Catalyst nodes + drivers      running                     ║"
    if [[ "$with_blockscout" == "true" ]]; then
        echo "║  • L2 Blockscout explorer        running                     ║"
    fi
    if [[ "$with_spammer" == "true" ]]; then
        echo "║  • L2 transaction spammer        running                     ║"
    fi
    echo "║                                                              ║"
    echo "║  Service endpoints:                                          ║"
    printf "║    L1 RPC (HTTP):  %-42s║\n" "$l1_rpc_display"
    printf "║    L1 RPC (WS):    %-42s║\n" "$l1_ws_display"
    printf "║    L1 Beacon API:  %-42s║\n" "$l1_beacon_display"
    printf "║    L2 RPC (HTTP):  %-42s║\n" "http://${l2_host}:${rpc_port}"
    printf "║    L2 RPC (WS):    %-42s║\n" "ws://${l2_host}:${ws_port}"
    if [[ "$with_blockscout" == "true" ]]; then
        printf "║    L2 Blockscout:  %-42s║\n" "http://${l2_host}:${blockscout_frontend_port}"
    fi
    if [[ "$with_spammer" == "true" ]]; then
        printf "║    L2 Spammer UI:  %-42s║\n" "http://${l2_host}:${spamoor_port}"
    fi
    echo "║                                                              ║"
    echo "║  To remove the stack, run:                                   ║"
    echo "║  ./remove-taiko-full.sh                                      ║"
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

    # Validate prerequisites
    if ! validate_prerequisites; then
        log_error "Prerequisites validation failed"
        exit 1
    fi

    # Load .env if it exists
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    else
        log_warning ".env file not found — using defaults from .env.example"
        if [[ -f ".env.example" ]]; then
            cp ".env.example" "$ENV_FILE"
            log_info "Created .env from .env.example — review and edit as needed"
            set -a
            # shellcheck disable=SC1090
            source "$ENV_FILE"
            set +a
        fi
    fi

    # Ensure deployments directory exists
    mkdir -p "$DEPLOYMENTS_DIR"

    # ── Resolve execution client ───────────────────────────────────────────────
    if [[ -z "$client" ]]; then
        local existing_client="${EXECUTION_CLIENT:-}"
        # Only reuse the cached client when skipping L1 (stack restart).
        # On a fresh deploy always prompt/default so the user can choose.
        if [[ -n "$existing_client" && "$skip_l1_devnet" == "true" ]]; then
            log_info "Using execution client from .env: $existing_client"
            client="$existing_client"
        elif [[ "$force" == "true" ]]; then
            client="${existing_client:-nethermind}"
        else
            local client_raw
            client_raw=$(prompt_client_selection)
            case "$client_raw" in
                1|"geth") client="geth" ;;
                2|"alethia-reth") client="alethia-reth" ;;
                *)         client="nethermind" ;;
            esac
        fi
    fi

    case "$client" in
        "nethermind"|"geth"|"alethia-reth") ;;
        *)
            log_error "Invalid client: $client (must be nethermind, geth, or alethia-reth)"
            exit 1
            ;;
    esac

    update_env_var "$ENV_FILE" "EXECUTION_CLIENT" "$client"

    # ── Nethermind genesis info ────────────────────────────────────────────────
    if [[ "$client" == "nethermind" ]]; then
        echo >&2
        echo "╔══════════════════════════════════════════════════════════════╗" >&2
        echo "║  Nethermind selected                                         ║" >&2
        echo "╠══════════════════════════════════════════════════════════════╣" >&2
        echo "║  The canonical genesis will be fetched automatically from:   ║" >&2
        echo "║  taikoxyz/taiko-geth  (core/taiko_genesis/internal.json)     ║" >&2
        echo "║                                                              ║" >&2
        echo "║  It will be converted to a Nethermind chainspec at:          ║" >&2
        echo "║  static/taiko-shasta-chainspec.json                          ║" >&2
        echo "║                                                              ║" >&2
        echo "║  Override the source URL by setting TAIKO_GENESIS_URL.       ║" >&2
        echo "╚══════════════════════════════════════════════════════════════╝" >&2
        echo >&2
    fi

    # ── Resolve environment ────────────────────────────────────────────────────
    if [[ -z "$environment" && "$skip_l1_devnet" == "false" ]]; then
        if [[ "$force" == "true" ]]; then
            environment="local"
        else
            local env_raw
            env_raw=$(prompt_environment_selection)
            case "$env_raw" in
                1|"remote") environment="remote" ;;
                *)           environment="local" ;;
            esac
        fi
    fi

    # ── Resolve L1 blockscout ────────────────────────────────────────────────
    if [[ "$skip_l1_devnet" == "true" ]]; then
        enable_l1_blockscout="${enable_l1_blockscout:-false}"
    elif [[ -z "$enable_l1_blockscout" ]]; then
        if [[ "$force" == "true" ]]; then
            enable_l1_blockscout="false"
        else
            local l1bs_raw
            l1bs_raw=$(prompt_yes_no_selection "Enable L1 Blockscout explorer?")
            case "$l1bs_raw" in
                1|"yes"|"true") enable_l1_blockscout="true" ;;
                *)               enable_l1_blockscout="false" ;;
            esac
        fi
    fi

    # ── Resolve mode ──────────────────────────────────────────────────────────
    if [[ -z "$mode" ]]; then
        if [[ "$force" == "true" ]]; then
            mode="silence"
        else
            local mode_raw
            mode_raw=$(prompt_mode_selection)
            case "$mode_raw" in
                1|"debug") mode="debug" ;;
                *)          mode="silence" ;;
            esac
        fi
    fi

    case "$mode" in
        0|"silence"|"") mode="silence" ;;
        1|"debug")       mode="debug" ;;
        *)
            log_error "Invalid mode: $mode"
            exit 1
            ;;
    esac

    # ── Resolve L2 blockscout ─────────────────────────────────────────────────
    if [[ -z "$enable_l2_blockscout" ]]; then
        if [[ "$force" == "true" ]]; then
            enable_l2_blockscout="false"
        else
            local bs_raw
            bs_raw=$(prompt_yes_no_selection "Enable L2 Blockscout explorer?")
            case "$bs_raw" in
                1|"yes"|"true") enable_l2_blockscout="true" ;;
                *)               enable_l2_blockscout="false" ;;
            esac
        fi
    fi

    # ── Resolve L2 spammer ────────────────────────────────────────────────────
    if [[ -z "$enable_l2_spammer" ]]; then
        if [[ "$force" == "true" ]]; then
            enable_l2_spammer="false"
        else
            local sp_raw
            sp_raw=$(prompt_yes_no_selection "Enable L2 transaction spammer?")
            case "$sp_raw" in
                1|"yes"|"true") enable_l2_spammer="true" ;;
                *)               enable_l2_spammer="false" ;;
            esac
        fi
    fi

    echo
    log_info "Deployment configuration:"
    echo "  Execution client:  $client"
    echo "  L1 environment:    ${environment:-n/a (skipped)}"
    echo "  Output mode:       $mode"
    echo "  Skip L1 devnet:    $skip_l1_devnet"
    echo "  Skip contracts:    $skip_contracts"
    echo "  L1 Blockscout:     $enable_l1_blockscout"
    echo "  L2 Blockscout:     $enable_l2_blockscout"
    echo "  L2 Spammer:        $enable_l2_spammer"
    echo

    # ── Phase 1: L1 devnet ────────────────────────────────────────────────────
    local l1_deployed="false"

    if [[ "$skip_l1_devnet" == "true" ]]; then
        log_info "Skipping L1 devnet deployment (--skip-l1-devnet)"
        if ! check_l1_devnet_exists; then
            log_warning "No existing L1 devnet enclave found — L2 may fail to connect"
        else
            local l1_status
            l1_status=$(get_l1_devnet_status)
            log_info "Using existing L1 devnet (Status: $l1_status)"
        fi
    else
        log_info "Phase 1: L1 devnet deployment"
        initialize_submodules

        if ! deploy_l1_devnet "$environment" "$mode" "$enable_l1_blockscout"; then
            log_error "L1 devnet deployment failed"
            exit 1
        fi
        l1_deployed="true"

        # Brief pause before continuing
        sleep 5
    fi

    # Derive host-accessible L1 URL variants (localhost for local, machine_ip for remote)
    configure_environment_urls "${environment:-local}"
    log_info "L1 RPC  (host): $L1_ENDPOINT_HTTP_EXTERNAL"
    log_info "L1 Beacon (host): $L1_BEACON_HTTP_EXTERNAL"

    if [[ "$skip_l1_devnet" == "false" ]]; then
        check_l1_health "$L1_ENDPOINT_HTTP_EXTERNAL" "$L1_BEACON_HTTP_EXTERNAL"
    fi

    # ── Phase 2 pre-step: fork timestamp (must precede genesis hash computation
    #    because the chainspec embeds the shasta timestamp) ─────────────────────
    log_info "Setting fork timestamp..."
    update_fork_timestamp "$ENV_FILE" "${FORK_ACTIVATION_BUFFER:-120}" "${UPDATE_SHASTA_FORK_TIME:-true}" "${UPDATE_UZEN_FORK_TIME:-true}"
    set -a; source "$ENV_FILE"; set +a

    # ── Phase 2: Contract deployment ──────────────────────────────────────────
    local contracts_deployed="false"

    if [[ "$skip_contracts" == "true" ]]; then
        log_info "Skipping contract deployment (--skip-contracts)"

        if [[ ! -f "${DEPLOYMENTS_DIR}/deploy_l1_pacaya.json" ]] || \
           [[ ! -f "${DEPLOYMENTS_DIR}/deploy_l1_shasta.json" ]]; then
            log_warning "Contract deployment files not found in $DEPLOYMENTS_DIR/"
            log_warning "The stack may not start correctly without deployed contracts"
        fi
    else
        log_info "Phase 2: Contract deployment"

        if ! compute_genesis_hash "$client" "$mode"; then
            log_error "Failed to compute genesis hash"
            exit 1
        fi

        # Reload env so deployer containers inherit the updated L2_GENESIS_HASH
        set -a; source "$ENV_FILE"; set +a

        if ! deploy_shasta_contracts "$mode"; then
            log_error "Shasta contract deployment failed"
            exit 1
        fi

        contracts_deployed="true"
    fi

    # ── Phase 3: Reload .env to pick up all deployed contract addresses ────────
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a

    # ── Phase 4: Start L2 stack ───────────────────────────────────────────────
    log_info "Phase 4: Starting L2 Catalyst stack"

    if ! start_l2_stack "$client" "$mode" "$enable_l2_blockscout" "$enable_l2_spammer"; then
        log_error "Failed to start L2 stack"
        exit 1
    fi

    # ── Health checks ─────────────────────────────────────────────────────────
    sleep 5
    check_l2_health "$client"

    # ── Summary ───────────────────────────────────────────────────────────────
    display_deployment_summary "$client" "${environment:-local}" "$l1_deployed" "$contracts_deployed" "$enable_l2_blockscout" "$enable_l2_spammer"

    log_success "Taiko devnet deployment complete!"
}

main "$@"

#!/bin/bash
# setup-catalyst-stack.sh - Master orchestration script for Catalyst stack
# One script to rule them all!

set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Source library functions
source "$PROJECT_ROOT/script/lib/validators.sh"
source "$PROJECT_ROOT/script/lib/config-generator.sh"

# Default values
ENV_FILE="$PROJECT_ROOT/.env"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.unified.yml"
CLEAN_START=false
SKIP_VALIDATION=false
SKIP_DEPLOYMENT=false
INTERACTIVE=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --client)
            OVERRIDE_CLIENT="$2"
            shift 2
            ;;
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        --clean)
            CLEAN_START=true
            shift
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        --skip-deployment)
            SKIP_DEPLOYMENT=true
            shift
            ;;
        --non-interactive)
            INTERACTIVE=false
            shift
            ;;
        --help)
            cat << EOF
Catalyst Stack Setup Script

Usage: $0 [OPTIONS]

OPTIONS:
  --client [geth|nethermind]  Override EXECUTION_CLIENT setting
  --env [path]                Path to .env file (default: .env)
  --clean                     Remove existing containers and volumes first
  --skip-validation           Skip pre-flight validation checks
  --skip-deployment           Skip protocol deployment (use existing)
  --non-interactive           Don't prompt user (use for automation)
  --help                      Show this help message

EXAMPLES:
  # Complete setup with Nethermind
  $0 --client nethermind

  # Clean start (removes all data)
  $0 --clean

  # Restart services without redeploying contracts
  $0 --skip-deployment

  # Use custom env file
  $0 --env .env.custom

  # Non-interactive mode (for CI/CD)
  $0 --non-interactive

EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Print banner
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║            Catalyst Stack Setup & Orchestration                ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# PHASE 1: Pre-flight Checks
# ============================================================================

if [ "$SKIP_VALIDATION" = false ]; then
    log_info "PHASE 1: Pre-flight Checks"

    # Check if .env file exists
    if [ ! -f "$ENV_FILE" ]; then
        log_warning ".env file not found"
        if [ -f "$PROJECT_ROOT/env.unified.example" ]; then
            log_info "Creating .env from env.unified.example..."
            cp "$PROJECT_ROOT/env.unified.example" "$ENV_FILE"
            log_success ".env file created"
            log_warning "Please review and update .env file with your configuration"
        else
            log_error "No .env file or template found"
            exit 1
        fi
    fi

    # Load environment variables
    set -a
    source "$ENV_FILE"
    set +a

    # Validate commands
    validate_commands || exit 1

    # Validate Docker
    validate_docker || exit 1

    # Validate L1 endpoints
    log_info "Validating L1 connectivity..."
    if ! validate_l1_endpoints "$L1_ENDPOINT_HTTP" "$L1_ENDPOINT_WS" "$L1_BEACON_HTTP"; then
        log_error "L1 endpoint validation failed"
        log_info "Please ensure your L1 devnet is running and endpoints are correct"
        exit 1
    fi

    # Validate execution client
    EXECUTION_CLIENT="${OVERRIDE_CLIENT:-$EXECUTION_CLIENT}"
    validate_execution_client "$EXECUTION_CLIENT" || exit 1

    # Update execution client in .env if overridden
    if [ -n "$OVERRIDE_CLIENT" ]; then
        update_env_file "$ENV_FILE" "EXECUTION_CLIENT" "$OVERRIDE_CLIENT"
    fi

    # Validate required files
    validate_required_files "$PROJECT_ROOT" || exit 1

    # Validate private keys
    validate_private_key "$OPERATOR_1_PRIVATE_KEY" "OPERATOR_1_PRIVATE_KEY" || exit 1
    validate_private_key "$CONTRACT_OWNER_PRIVATE_KEY" "CONTRACT_OWNER_PRIVATE_KEY" || exit 1

    log_success "Pre-flight checks completed"
else
    log_info "Skipping pre-flight validation"
    set -a
    source "$ENV_FILE"
    set +a
    EXECUTION_CLIENT="${OVERRIDE_CLIENT:-$EXECUTION_CLIENT}"
fi

# ============================================================================
# PHASE 2: Configuration Generation
# ============================================================================

log_info "PHASE 2: Configuration Generation"

# Calculate fork timestamp if not set
if [ -z "$TAIKO_INTERNAL_SHASTA_TIME" ] || [ "$TAIKO_INTERNAL_SHASTA_TIME" = "0" ]; then
    FORK_BUFFER="${FORK_ACTIVATION_BUFFER:-120}"
    TAIKO_INTERNAL_SHASTA_TIME=$(calculate_fork_timestamp "$FORK_BUFFER")
    update_env_file "$ENV_FILE" "TAIKO_INTERNAL_SHASTA_TIME" "$TAIKO_INTERNAL_SHASTA_TIME"
    log_info "Fork timestamp calculated: $TAIKO_INTERNAL_SHASTA_TIME"

    # Display readable time
    if [[ "$OSTYPE" == "darwin"* ]]; then
        READABLE_TIME=$(date -r "$TAIKO_INTERNAL_SHASTA_TIME" '+%Y-%m-%d %H:%M:%S')
    else
        READABLE_TIME=$(date -d "@$TAIKO_INTERNAL_SHASTA_TIME" '+%Y-%m-%d %H:%M:%S')
    fi
    log_info "Fork activation time: $READABLE_TIME"
fi

# Update chainspec if it exists
if [ -f "$PROJECT_ROOT/taiko-shasta-chainspec.json" ]; then
    update_chainspec_timestamp "$PROJECT_ROOT/taiko-shasta-chainspec.json" "$TAIKO_INTERNAL_SHASTA_TIME"
fi

# Generate service URLs based on execution client
generate_service_urls "$EXECUTION_CLIENT" "$ENV_FILE"

# Reload environment after updates
set -a
source "$ENV_FILE"
set +a

log_success "Configuration generated"

# ============================================================================
# PHASE 3: Clean Start (if requested)
# ============================================================================

if [ "$CLEAN_START" = true ]; then
    log_info "PHASE 3: Cleaning existing deployment"

    if [ -f "$COMPOSE_FILE" ]; then
        log_info "Stopping and removing containers..."
        docker-compose -f "$COMPOSE_FILE" --profile geth --profile nethermind down -v 2>/dev/null || true

        log_info "Removing volumes..."
        docker volume rm simple-taiko-node-nethermind_taiko-geth-data 2>/dev/null || true
        docker volume rm simple-taiko-node-nethermind_taiko-nethermind-data 2>/dev/null || true

        log_success "Cleanup completed"
    fi
else
    log_info "PHASE 3: Checking for existing containers"

    # Check if containers are already running
    if docker-compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .; then
        log_warning "Containers are already running"
        read -p "Do you want to restart them? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Stopping existing containers..."
            docker-compose -f "$COMPOSE_FILE" --profile "$EXECUTION_CLIENT" down
        else
            log_info "Exiting without changes"
            exit 0
        fi
    fi
fi

# ============================================================================
# PHASE 4: Docker Compose Profile Setup
# ============================================================================

log_info "PHASE 4: Starting Catalyst Stack"

export COMPOSE_PROFILES="$EXECUTION_CLIENT"
log_info "Using Docker Compose profile: $EXECUTION_CLIENT"

# ============================================================================
# PHASE 4.5: Check for existing deployments and prompt user
# ============================================================================

# Check if deployment files exist
DEPLOYMENT_EXISTS=false
if [ -f "$PROJECT_ROOT/deployments/deploy_l1.json" ] && \
   [ -f "$PROJECT_ROOT/deployments/deploy_l1_pacaya.json" ] && \
   [ -f "$PROJECT_ROOT/deployments/deploy_l1_shasta.json" ]; then
    DEPLOYMENT_EXISTS=true
fi

# Interactive prompt to skip deployment if files exist
if [ "$DEPLOYMENT_EXISTS" = true ] && [ "$SKIP_DEPLOYMENT" = false ] && [ "$INTERACTIVE" = true ]; then
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "Existing deployment files found:"
    log_info "  • deployments/deploy_l1_pacaya.json"
    log_info "  • deployments/deploy_l1_shasta.json"
    log_info "  • deployments/deploy_l1.json (combined)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Options:"
    log_info "  [1] Skip deployment - Use existing contracts (faster, recommended)"
    log_info "  [2] Redeploy all - Fresh Pacaya + Shasta deployment (slower)"
    log_info "  [3] Cancel"
    echo ""
    read -p "Choose an option [1/2/3]: " -n 1 -r
    echo ""
    echo ""

    case "$REPLY" in
        1)
            SKIP_DEPLOYMENT=true
            log_success "Using existing deployment"
            log_info "Will restart services only"
            ;;
        2)
            SKIP_DEPLOYMENT=false
            log_info "Will redeploy contracts"
            log_warning "This will take several minutes..."
            ;;
        3)
            log_info "Cancelled by user"
            exit 0
            ;;
        *)
            log_warning "Invalid option, defaulting to use existing deployment"
            SKIP_DEPLOYMENT=true
            ;;
    esac
elif [ "$DEPLOYMENT_EXISTS" = false ] && [ "$SKIP_DEPLOYMENT" = true ]; then
    log_warning "No existing deployment found, --skip-deployment ignored"
    log_info "Will perform fresh deployment"
    SKIP_DEPLOYMENT=false
fi

# ============================================================================
# PHASE 5: Build and Start Services
# ============================================================================

log_info "PHASE 5: Building and launching services..."

# Force rebuild catalyst-init to ensure latest changes
log_info "Rebuilding catalyst-init container..."
docker-compose -f "$COMPOSE_FILE" build --no-cache catalyst-init

log_success "Build complete"

# Determine profiles to use
PROFILES="--profile $EXECUTION_CLIENT"

# Add deploy profile if contracts need deployment
if [ "$SKIP_DEPLOYMENT" = false ]; then
    PROFILES="$PROFILES --profile deploy"
    log_info "Deployment enabled: Will run Pacaya and Shasta deployers"
else
    log_info "Deployment skipped: Using existing contract addresses"
fi

# Start services with selected profiles
log_info "Starting $EXECUTION_CLIENT execution client and all dependencies..."
docker-compose -f "$COMPOSE_FILE" $PROFILES up -d

# Wait for initialization to complete
log_info "Waiting for initialization container to complete..."
log_info "This includes: contract deployment, operator setup, and fork activation"
log_info "This may take several minutes..."

# Follow init container logs
docker logs -f catalyst-init 2>&1 &
LOGS_PID=$!

# Wait for catalyst-init to complete
while docker ps | grep -q catalyst-init; do
    sleep 2
done

# Stop following logs
kill $LOGS_PID 2>/dev/null || true

# Check if init completed successfully
if docker inspect catalyst-init --format='{{.State.ExitCode}}' | grep -q "^0$"; then
    log_success "Initialization completed successfully"
else
    log_error "Initialization failed"
    log_info "Check logs with: docker logs catalyst-init"
    exit 1
fi

# ============================================================================
# PHASE 6: Health Checks
# ============================================================================

log_info "PHASE 6: Performing health checks..."

# Wait for execution client
log_info "Waiting for execution client to be ready..."
sleep 10

# Check execution client
if [ "$EXECUTION_CLIENT" = "geth" ]; then
    EXEC_CONTAINER="taiko-geth"
    RPC_PORT="8545"
else
    EXEC_CONTAINER="taiko-nethermind"
    RPC_PORT="8547"
fi

# Test RPC connectivity
for i in {1..30}; do
    if curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "http://localhost:$RPC_PORT" | jq -e '.result' &>/dev/null; then
        log_success "Execution client is responding"
        break
    fi
    if [ $i -eq 30 ]; then
        log_warning "Execution client not responding yet"
    fi
    sleep 2
done

# Check driver
log_info "Checking driver status..."
if docker ps | grep -q taiko-driver; then
    log_success "Driver is running"
else
    log_warning "Driver may not have started"
fi

# Check catalyst node
log_info "Checking catalyst node status..."
if docker ps | grep -q catalyst-node; then
    log_success "Catalyst node is running"
else
    log_warning "Catalyst node may not have started"
fi

# ============================================================================
# PHASE 7: Display Summary
# ============================================================================

echo ""
log_success "╔════════════════════════════════════════════════════════════════╗"
log_success "║                                                                ║"
log_success "║              Catalyst Stack Successfully Deployed!             ║"
log_success "║                                                                ║"
log_success "╚════════════════════════════════════════════════════════════════╝"
echo ""

log_info "STACK INFORMATION:"
log_info "  Execution Client: $EXECUTION_CLIENT"
log_info "  Chain ID: $L2_CHAIN_ID"
log_info "  Fork Time: $(date -d "@$TAIKO_INTERNAL_SHASTA_TIME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$TAIKO_INTERNAL_SHASTA_TIME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
echo ""

log_info "SERVICE ENDPOINTS:"
log_info "  L2 RPC (HTTP): http://localhost:$RPC_PORT"
log_info "  L2 RPC (WS):   ws://localhost:${PORT_L2_EXEC_WS:-8546}"
log_info "  Metrics:       http://localhost:${PORT_CATALYST_METRICS:-9898}/metrics"
echo ""

log_info "USEFUL COMMANDS:"
log_info "  View logs:           docker-compose -f $COMPOSE_FILE logs -f"
log_info "  Stop stack:          docker-compose -f $COMPOSE_FILE --profile $EXECUTION_CLIENT down"
log_info "  Check status:        docker-compose -f $COMPOSE_FILE ps"
log_info "  Teardown:            ./teardown-catalyst-stack.sh"
echo ""

if [ "${DEPLOY_CONTRACTS:-false}" = "true" ]; then
    log_info "DEPLOYMENT PHASE:"
    log_info "  Monitor Shasta:   docker logs -f shasta-deployer"
    log_info "  Monitor Init:     docker logs -f catalyst-init"
    echo ""
fi

if [ "${ACTIVATE_FORK:-false}" = "true" ]; then
    log_info "FORK ACTIVATION:"
    log_info "  Fork activation requires manual trigger after setup completes"
    log_info "  Once catalyst-init is ready, run:"
    log_info "    docker exec -it catalyst-init /workspace/script/activate-fork.sh"
    echo ""
fi

log_info "USEFUL COMMANDS:"
log_info "  View all logs:       docker-compose -f $COMPOSE_FILE logs -f"
log_info "  Restart stack:       docker-compose -f $COMPOSE_FILE --profile $EXECUTION_CLIENT restart"
echo ""

log_success "Catalyst stack is launching!"
log_info "Monitor progress with: docker logs -f catalyst-init"
echo ""

#!/bin/bash
# teardown-catalyst-stack.sh - Cleanup script for Catalyst stack

set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Source validators for logging functions
if [ -f "$PROJECT_ROOT/script/lib/validators.sh" ]; then
    source "$PROJECT_ROOT/script/lib/validators.sh"
fi

# Default values
ENV_FILE="$PROJECT_ROOT/.env"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"
REMOVE_VOLUMES=false
REMOVE_DEPLOYMENTS=false
REMOVE_CONFIG=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --volumes)
            REMOVE_VOLUMES=true
            shift
            ;;
        --deployments)
            REMOVE_DEPLOYMENTS=true
            shift
            ;;
        --config)
            REMOVE_CONFIG=true
            shift
            ;;
        --all)
            REMOVE_VOLUMES=true
            REMOVE_DEPLOYMENTS=true
            REMOVE_CONFIG=true
            shift
            ;;
        --help)
            cat << EOF
Catalyst Stack Teardown Script

Usage: $0 [OPTIONS]

OPTIONS:
  --volumes       Remove Docker volumes (execution client data)
  --deployments   Remove deployment files (deploy_l1*.json)
  --config        Remove generated config files
  --all           Remove everything (volumes + deployments + config)
  --help          Show this help message

EXAMPLES:
  # Stop containers only (keep data and deployments)
  $0

  # Stop containers and remove deployment results
  $0 --deployments

  # Stop containers and remove volumes
  $0 --volumes

  # Complete cleanup (fresh start)
  $0 --all

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

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║              Catalyst Stack Teardown                           ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Load execution client from env if available
if [ -f "$ENV_FILE" ]; then
    EXECUTION_CLIENT=$(grep "^EXECUTION_CLIENT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' || echo "nethermind")
else
    EXECUTION_CLIENT="nethermind"
fi

log_info "Execution client: $EXECUTION_CLIENT"

# ============================================================================
# Stop and remove containers
# ============================================================================

log_info "Stopping Catalyst stack containers..."

if [ -f "$COMPOSE_FILE" ]; then
    # Stop all profiles to ensure everything is stopped
    # Including deploy profile for pacaya-deployer and shasta-deployer
    docker-compose -f "$COMPOSE_FILE" --profile deploy --profile stack down 2>/dev/null || true
    log_success "Containers stopped"
else
    log_warning "Docker compose file not found: $COMPOSE_FILE"
    log_info "Attempting to stop containers by name..."

    # Stop containers by name (including deployers)
    for container in \
        shasta-deployer \
        catalyst-init \
        catalyst-node \
        taiko-driver \
        taiko-geth \
        taiko-nethermind \
        web3signer-l1 \
        web3signer-l2; do
        if docker ps -a | grep -q "$container"; then
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
        fi
    done

    log_success "Containers stopped"
fi

# ============================================================================
# Remove volumes if requested
# ============================================================================

if [ "$REMOVE_VOLUMES" = true ]; then
    log_info "Removing Docker volumes..."

    docker compose --profile stack down -v

    log_success "Volumes removed"
else
    log_info "Keeping Docker volumes (use --volumes to remove)"
fi

# ============================================================================
# Remove deployment files if requested
# ============================================================================

if [ "$REMOVE_DEPLOYMENTS" = true ]; then
    log_info "Removing deployment files..."

    if [ -d "$PROJECT_ROOT/deployments" ]; then
        rm -f "$PROJECT_ROOT/deployments/deploy_l1.json" 2>/dev/null || true
        rm -f "$PROJECT_ROOT/deployments/deploy_l1_urc.json" 2>/dev/null || true
        rm -f "$PROJECT_ROOT/deployments/deploy_l1_shasta.json" 2>/dev/null || true
        rm -f "$PROJECT_ROOT/deployments/deploy_l1_base.json" 2>/dev/null || true
        log_success "Deployment files removed"
    else
        log_info "No deployment directory found"
    fi
else
    log_info "Keeping deployment files (use --deployments to remove)"
fi

# ============================================================================
# Remove generated config if requested
# ============================================================================

if [ "$REMOVE_CONFIG" = true ]; then
    log_info "Removing generated config files..."

    # Remove generated configs (be careful not to remove user configs)
    rm -f "$PROJECT_ROOT/geth-config.generated.toml" 2>/dev/null || true

    log_success "Generated config files removed"
else
    log_info "Keeping config files (use --config to remove)"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
log_success "╔════════════════════════════════════════════════════════════════╗"
log_success "║                                                                ║"
log_success "║            Catalyst Stack Teardown Complete                    ║"
log_success "║                                                                ║"
log_success "╚════════════════════════════════════════════════════════════════╝"
echo ""

log_info "CLEANUP SUMMARY:"
log_info "  ✓ Containers stopped and removed"
if [ "$REMOVE_VOLUMES" = true ]; then
    log_info "  ✓ Volumes removed"
else
    log_info "  ○ Volumes kept"
fi
if [ "$REMOVE_DEPLOYMENTS" = true ]; then
    log_info "  ✓ Deployments removed"
else
    log_info "  ○ Deployments kept"
fi
if [ "$REMOVE_CONFIG" = true ]; then
    log_info "  ✓ Config files removed"
else
    log_info "  ○ Config files kept"
fi
echo ""

log_info "To restart the stack, run:"
log_info "  ./setup-catalyst-stack.sh"
echo ""

# ============================================================================
# Check for orphaned resources
# ============================================================================

log_info "Checking for orphaned resources..."

# Check for any remaining containers with catalyst in name
ORPHANED_CONTAINERS=$(docker ps -a --filter "name=catalyst" --filter "name=taiko" --filter "name=web3signer" -q 2>/dev/null | wc -l)
if [ "$ORPHANED_CONTAINERS" -gt 0 ]; then
    log_warning "Found $ORPHANED_CONTAINERS orphaned containers"
    log_info "Remove them with: docker ps -a | grep -E '(catalyst|taiko|web3signer)' | awk '{print \$1}' | xargs docker rm -f"
fi

# Check for orphaned volumes
ORPHANED_VOLUMES=$(docker volume ls --filter "name=taiko" --filter "name=catalyst" -q 2>/dev/null | wc -l)
if [ "$ORPHANED_VOLUMES" -gt 0 ] && [ "$REMOVE_VOLUMES" = false ]; then
    log_info "Found $ORPHANED_VOLUMES volume(s) still present"
    log_info "Remove them with: ./teardown-catalyst-stack.sh --volumes"
fi

log_success "Teardown complete!"
echo ""

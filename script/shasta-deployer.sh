#!/bin/bash

# Script to deploy the Shasta protocol
# Usage: ./script/shasta-deployer.sh

set -e  # Exit on error

# Translate 127.0.0.1 to host.docker.internal for container environment
export L1_ENDPOINT_HTTP="${L1_ENDPOINT_HTTP//127.0.0.1/host.docker.internal}"
export L1_ENDPOINT_WS="${L1_ENDPOINT_WS//127.0.0.1/host.docker.internal}"
export L1_BEACON_HTTP="${L1_BEACON_HTTP//127.0.0.1/host.docker.internal}"

echo "=========================================="
echo "  Shasta Protocol Deployment"
echo "=========================================="
echo "L1 Endpoints (translated for container):"
echo "  HTTP:   $L1_ENDPOINT_HTTP"
echo "  WS:     $L1_ENDPOINT_WS"
echo "  Beacon: $L1_BEACON_HTTP"
echo "=========================================="

export DEVNET_CHAIN_ID=${L1_CHAIN_ID}

# Determine beacon URL
BEACON_URL=${L1_BEACON_HTTP:-http://host.docker.internal:33001}

# Fetch and validate DEVNET_BEACON_GENESIS
BEACON_GENESIS_RAW=$(curl -s "$BEACON_URL/eth/v1/beacon/genesis" | jq -r '.data.genesis_time')
echo "Raw DEVNET_BEACON_GENESIS value: '$BEACON_GENESIS_RAW'"

# Check if jq returned "null" (as a string) or empty
if [ -z "$BEACON_GENESIS_RAW" ] || [ "$BEACON_GENESIS_RAW" = "null" ]; then
    echo "Error: DEVNET_BEACON_GENESIS is empty or null. Beacon service may not be ready."
    echo "Tried to fetch from: $BEACON_URL/eth/v1/beacon/genesis"
    exit 1
fi

export DEVNET_BEACON_GENESIS="$BEACON_GENESIS_RAW"
echo "DEVNET_BEACON_GENESIS exported as: $DEVNET_BEACON_GENESIS"

export DEVNET_SECONDS_IN_SLOT=$(curl -s "$BEACON_URL/eth/v1/config/spec" | jq -r '.data.SECONDS_PER_SLOT')
export DEVNET_OP_CHANGE_DELAY="0"
export DEVNET_RANDOMNESS_DELAY="0"
export FOUNDRY_PROFILE="layer1"
export L2_CHAIN_ID=${L2_CHAIN_ID}
export PRIVATE_KEY="0x$CONTRACT_OWNER_PRIVATE_KEY"
export OLD_FORK_TAIKO_INBOX="0x0000000000000000000000000000000000000000"
export TAIKO_ANCHOR_ADDRESS=${TAIKO_ANCHOR_ADDRESS}
export L2_SIGNAL_SERVICE="0x1670010000000000000000000000000000000005"
export CONTRACT_OWNER=${CONTRACT_OWNER}
export PROVER_SET_ADMIN=${CONTRACT_OWNER}
export TAIKO_TOKEN_PREMINT_RECIPIENT=${CONTRACT_OWNER}
export TAIKO_TOKEN_NAME="Taiko Token"
export TAIKO_TOKEN_SYMBOL="TAIKO"
export SHARED_RESOLVER="0x0000000000000000000000000000000000000000"
export PAUSE_BRIDGE="true"
export DEPLOY_PRECONF_CONTRACTS="true"
export PRECONF_INBOX="false"
export PRECONF_ROUTER="false"
export INCLUSION_WINDOW="24"
export INCLUSION_FEE_IN_GWEI="100"
export DUMMY_VERIFIERS="true"
export PROPOSER_ADDRESS=${CONTRACT_OWNER}
export SECURITY_COUNCIL=${CONTRACT_OWNER}
export FORK_URL=${L1_ENDPOINT_HTTP}
export FORGE_FLAGS="--broadcast --ffi -vvv --block-gas-limit 200000000"
export ACTIVATE_INBOX="true"
export TAIKO_TOKEN="0x0000000000000000000000000000000000000000"
export PRECONF_WHITELIST="0x0000000000000000000000000000000000000000"
export USE_LOOKAHEAD_STORE="true"
export LOOKAHEAD_OVERSEER="${CONTRACT_OWNER}"
export PRECONF_SLASHER_L1="0x0000000000000000000000000000000000000001" # temporary random address

# Verify the variable is set before calling setup.sh
echo "Verifying DEVNET_BEACON_GENESIS before setup.sh: $DEVNET_BEACON_GENESIS"

./setup.sh && forge script ./script/layer1/core/DeployProtocolOnL1.s.sol:DeployProtocolOnL1 --private-key $CONTRACT_OWNER_PRIVATE_KEY --fork-url $L1_ENDPOINT_HTTP --broadcast --ffi -vvv --block-gas-limit 200000000

cp /app/deployments/deploy_l1.json /deployments/deploy_l1_shasta.json

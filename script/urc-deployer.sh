#!/bin/sh

# This script deploys the Registry contract using Foundry
set -e

# Broadcast transactions
export BROADCAST=${BROADCAST:-true}

# Parameterize broadcasting
export BROADCAST_ARG=""
if [ "$BROADCAST" = "true" ]; then
    BROADCAST_ARG="--broadcast"
fi

# Parameterize log level
export LOG_LEVEL=${LOG_LEVEL:--vvvv}

# Parameterize block gas limit
export BLOCK_GAS_LIMIT=${BLOCK_GAS_LIMIT:-20000000}

# Run the deployment script using forge
forge script script/Deploy.s.sol \
    --fork-url $FORK_URL \
    $BROADCAST_ARG \
    $LOG_LEVEL \
    --private-key $PRIVATE_KEY \
    --block-gas-limit $BLOCK_GAS_LIMIT

cp /app/urc/config/deploy_urc.json /deployments/deploy_l1_urc.json

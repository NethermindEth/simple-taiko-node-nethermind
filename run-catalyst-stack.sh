set -e

git submodule update --init

# Helper function to update environment variables in .env file
update_env_var() {
    local env_file="$1"
    local var_name="$2"
    local var_value="$3"

    # Check if the variable exists in the file
    if grep -q "^${var_name}=" "$env_file"; then
        # Update existing variable (handle special characters)
        sed -i.bak "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file" && rm -f "$env_file.bak"
    else
        # Add new variable if it doesn't exist
        echo "${var_name}=${var_value}" >> "$env_file"
    fi
}

# Register operators for a given stack (1 or 2), then update REGISTRATION_ROOT in .env.stack-<n>
register_operators_for_stack() {
    local stack="$1"
    echo "Registering operator for stack ${stack}..."
    local env_file_stack=".env.stack-${stack}"
    local register_output
    register_output=$(mktemp)
    docker compose --env-file .env --env-file "$env_file_stack" --profile deploy up register-operators 2>&1 | tee "$register_output"
    local registration_root
    registration_root=$(grep "Registration root:" "$register_output" | sed 's/.*Registration root: *//' | tr -d '\r\n')
    rm -f "$register_output"
    if [ -n "$registration_root" ]; then
        update_env_var "$env_file_stack" "REGISTRATION_ROOT" "$registration_root"
        echo "REGISTRATION_ROOT=$registration_root (stack-${stack})"
    fi

    sleep 12
    echo "Opting in to slasher for stack ${stack}..."
    docker compose --env-file .env --env-file "$env_file_stack" --profile deploy up opt-in-to-slasher 2>&1 | tee "$register_output"
}

ENV_FILE=".env"

# Deploy URC contracts if protocol is urc
if [ ! -f "./deployments/deploy_l1_urc.json" ]; then
    echo "Deploying URC contracts..."
    docker compose up urc-deployer

    export URC_REGISTRY=$(cat ./deployments/deploy_l1_urc.json | jq -r '.registry')
    update_env_var "$ENV_FILE" "URC_REGISTRY" "$URC_REGISTRY"
fi

# Deploy Shasta contracts if protocol is shasta
if [ ! -f "./deployments/deploy_l1_shasta.json" ]; then
    echo "Deploying Shasta contracts..."
    docker compose up shasta-deployer

    export SHASTA_AUTOMATA_DCAP_ATTESTATION=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.automata_dcap_attestation')
    export SHASTA_BRIDGE=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.bridge')
    export SHASTA_ERC1155_VAULT=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.erc1155_vault')
    export SHASTA_ERC20_VAULT=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.erc20_vault')
    export SHASTA_ERC721_VAULT=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.erc721_vault')
    export SHASTA_PROVER_WHITELIST=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.prover_whitelist')
    export SHASTA_SGX_GETH_AUTOMATA_DCAP_ATTESTATION=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.sgx_geth_automata_dcap_attestation')
    export SHASTA_SHARED_RESOLVER=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.shared_resolver')
    export SHASTA_SHASTA_INBOX=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.shasta_inbox')
    export SHASTA_SIGNAL_SERVICE=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.signal_service')
    export SHASTA_PRECONF_WHITELIST=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.preconf_whitelist')
    export SHASTA_TAIKO_TOKEN=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.taiko_token')
    export LOOKAHEAD_STORE_ADDRESS=$(cat ./deployments/deploy_l1_shasta.json | jq -r '.lookahead_store')
    export URC=$URC_REGISTRY

    update_env_var "$ENV_FILE" "SHASTA_AUTOMATA_DCAP_ATTESTATION" "$SHASTA_AUTOMATA_DCAP_ATTESTATION"
    update_env_var "$ENV_FILE" "SHASTA_BRIDGE" "$SHASTA_BRIDGE"
    update_env_var "$ENV_FILE" "SHASTA_ERC1155_VAULT" "$SHASTA_ERC1155_VAULT"
    update_env_var "$ENV_FILE" "SHASTA_ERC20_VAULT" "$SHASTA_ERC20_VAULT"
    update_env_var "$ENV_FILE" "SHASTA_ERC721_VAULT" "$SHASTA_ERC721_VAULT"
    update_env_var "$ENV_FILE" "SHASTA_PROVER_WHITELIST" "$SHASTA_PROVER_WHITELIST"
    update_env_var "$ENV_FILE" "SHASTA_SGX_GETH_AUTOMATA_DCAP_ATTESTATION" "$SHASTA_SGX_GETH_AUTOMATA_DCAP_ATTESTATION"
    update_env_var "$ENV_FILE" "SHASTA_SHARED_RESOLVER" "$SHASTA_SHARED_RESOLVER"
    update_env_var "$ENV_FILE" "SHASTA_SHASTA_INBOX" "$SHASTA_SHASTA_INBOX"
    update_env_var "$ENV_FILE" "SHASTA_SIGNAL_SERVICE" "$SHASTA_SIGNAL_SERVICE"
    update_env_var "$ENV_FILE" "SHASTA_PRECONF_WHITELIST" "$SHASTA_PRECONF_WHITELIST"
    update_env_var "$ENV_FILE" "SHASTA_TAIKO_TOKEN" "$SHASTA_TAIKO_TOKEN"
    update_env_var "$ENV_FILE" "LOOKAHEAD_STORE_ADDRESS" "$LOOKAHEAD_STORE_ADDRESS"
fi


# TODO: commented until we implemented proper whitelist mode.
# register_operators_for_stack 1
# sleep 12
# register_operators_for_stack 2

echo "Running: docker-compose up -d"
docker compose --profile stack up -d

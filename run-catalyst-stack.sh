set -e

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

ENV_FILE=".env"

if [ ! -f "./deployments/deploy_l1_pacaya.json" ]; then
    echo "Deploying Pacaya contracts..."
    docker compose up pacaya-deployer

    export PACAYA_AUTOMATA_DCAP_ATTESTATION=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.automata_dcap_attestation')
    export PACAYA_BRIDGE=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.bridge')
    export PACAYA_ERC1155_VAULT=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.erc1155_vault')
    export PACAYA_ERC20_VAULT=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.erc20_vault')
    export PACAYA_ERC721_VAULT=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.erc721_vault')
    export PACAYA_FORCED_INCLUSION_STORE=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.forced_inclusion_store')
    export PACAYA_MAINNET_TAIKO=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.mainnet_taiko')
    export PACAYA_OP_GETH_VERIFIER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.op_geth_verifier')
    export PACAYA_OP_VERIFIER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.op_verifier')
    export PACAYA_PRECONF_ROUTER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.preconf_router')
    export PACAYA_PRECONF_WHITELIST=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.preconf_whitelist')
    export PACAYA_PROOF_VERIFIER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.proof_verifier')
    export PACAYA_PROVER_SET=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.prover_set')
    export PACAYA_RISC0_RETH_VERIFIER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.risc0_reth_verifier')
    export PACAYA_ROLLUP_ADDRESS_RESOLVER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.rollup_address_resolver')
    export PACAYA_SGX_GETH_AUTOMATA=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.sgx_geth_automata')
    export PACAYA_SGX_GETH_VERIFIER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.sgx_geth_verifier')
    export PACAYA_SGX_RETH_VERIFIER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.sgx_reth_verifier')
    export PACAYA_SHARED_RESOLVER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.shared_resolver')
    export PACAYA_SIGNAL_SERVICE=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.signal_service')
    export PACAYA_SP1_RETH_VERIFIER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.sp1_reth_verifier')
    export PACAYA_TAIKO=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.taiko')
    export PACAYA_TAIKO_TOKEN=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.taiko_token')
    export PACAYA_TAIKO_WRAPPER=$(cat ./deployments/deploy_l1_pacaya.json | jq -r '.taiko_wrapper')

    update_env_var "$ENV_FILE" "PACAYA_AUTOMATA_DCAP_ATTESTATION" "$PACAYA_AUTOMATA_DCAP_ATTESTATION"
    update_env_var "$ENV_FILE" "PACAYA_BRIDGE" "$PACAYA_BRIDGE"
    update_env_var "$ENV_FILE" "PACAYA_ERC1155_VAULT" "$PACAYA_ERC1155_VAULT"
    update_env_var "$ENV_FILE" "PACAYA_ERC20_VAULT" "$PACAYA_ERC20_VAULT"
    update_env_var "$ENV_FILE" "PACAYA_ERC721_VAULT" "$PACAYA_ERC721_VAULT"
    update_env_var "$ENV_FILE" "PACAYA_FORCED_INCLUSION_STORE" "$PACAYA_FORCED_INCLUSION_STORE"
    update_env_var "$ENV_FILE" "PACAYA_MAINNET_TAIKO" "$PACAYA_MAINNET_TAIKO"
    update_env_var "$ENV_FILE" "PACAYA_OP_GETH_VERIFIER" "$PACAYA_OP_GETH_VERIFIER"
    update_env_var "$ENV_FILE" "PACAYA_OP_VERIFIER" "$PACAYA_OP_VERIFIER"
    update_env_var "$ENV_FILE" "PACAYA_PRECONF_ROUTER" "$PACAYA_PRECONF_ROUTER"
    update_env_var "$ENV_FILE" "PACAYA_PRECONF_WHITELIST" "$PACAYA_PRECONF_WHITELIST"
    update_env_var "$ENV_FILE" "PACAYA_PROOF_VERIFIER" "$PACAYA_PROOF_VERIFIER"
    update_env_var "$ENV_FILE" "PACAYA_PROVER_SET" "$PACAYA_PROVER_SET"
    update_env_var "$ENV_FILE" "PACAYA_RISC0_RETH_VERIFIER" "$PACAYA_RISC0_RETH_VERIFIER"
    update_env_var "$ENV_FILE" "PACAYA_ROLLUP_ADDRESS_RESOLVER" "$PACAYA_ROLLUP_ADDRESS_RESOLVER"
    update_env_var "$ENV_FILE" "PACAYA_SGX_GETH_AUTOMATA" "$PACAYA_SGX_GETH_AUTOMATA"
    update_env_var "$ENV_FILE" "PACAYA_SGX_GETH_VERIFIER" "$PACAYA_SGX_GETH_VERIFIER"
    update_env_var "$ENV_FILE" "PACAYA_SGX_RETH_VERIFIER" "$PACAYA_SGX_RETH_VERIFIER"
    update_env_var "$ENV_FILE" "PACAYA_SHARED_RESOLVER" "$PACAYA_SHARED_RESOLVER"
    update_env_var "$ENV_FILE" "PACAYA_SIGNAL_SERVICE" "$PACAYA_SIGNAL_SERVICE"
    update_env_var "$ENV_FILE" "PACAYA_SP1_RETH_VERIFIER" "$PACAYA_SP1_RETH_VERIFIER"
    update_env_var "$ENV_FILE" "PACAYA_TAIKO" "$PACAYA_TAIKO"
    update_env_var "$ENV_FILE" "PACAYA_TAIKO_TOKEN" "$PACAYA_TAIKO_TOKEN"
    update_env_var "$ENV_FILE" "PACAYA_TAIKO_WRAPPER" "$PACAYA_TAIKO_WRAPPER"
fi

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
fi

docker compose --profile stack up -d
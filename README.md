
# simple-taiko-node

Local development stack for running Taiko L2 with a Kurtosis-managed L1 devnet and the Catalyst preconfirmation layer.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Kurtosis](https://docs.kurtosis.com/install/)
- `curl`, `jq`

## Quick Start

1. Copy the example environment file and adjust values as needed:

```bash
cp .env.example .env
```

2. Deploy the L1 devnet via Kurtosis:

```bash
./deploy-etheruem-package.sh
```

This spins up a local Ethereum L1 using the [ethereum-package](https://github.com/ethpandaops/ethereum-package) Kurtosis package. The script will prompt you to choose a deployment environment (local/remote), mode (silence/debug), and whether to run Blockscout.

3. Start the Catalyst-Taiko stack:

```bash
./run-catalyst-stack.sh
```

This deploys the Pacaya and Shasta protocol contracts on L1 (if not already deployed), configures the `.env` file with the resulting contract addresses, and launches all L2 services via Docker Compose.

## Teardown

```bash
./teardown-catalyst-stack.sh
```

Use `--all` for a complete cleanup including volumes and deployment artifacts. See `--help` for more options.

## Further Reading

- [Taiko node operator guide](https://docs.taiko.xyz/guides/node-operators/run-a-taiko-node-with-docker/)

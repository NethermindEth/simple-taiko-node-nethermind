# simple-taiko-node-nethermind

A local development stack for running a full Taiko L2 devnet — including a local Ethereum L1, deployed protocol contracts, and the Catalyst preconfirmation layer. Supports both **Nethermind** and **taiko-geth** as the L2 execution client.

---

## Table of Contents

- [What this sets up](#what-this-sets-up)
- [Prerequisites](#prerequisites)
- [Quick start — interactive mode](#quick-start--interactive-mode)
- [Choosing an L2 execution client](#choosing-an-l2-execution-client)
  - [Nethermind chainspec note](#nethermind-chainspec-note)
- [Optional add-ons](#optional-add-ons)
  - [L2 Blockscout explorer](#l2-blockscout-explorer)
  - [L2 transaction spammer](#l2-transaction-spammer)
- [Non-interactive / scripted usage](#non-interactive--scripted-usage)
- [Available deploy flags](#available-deploy-flags)
- [Service endpoints](#service-endpoints)
- [Tearing down the stack](#tearing-down-the-stack)
  - [Available remove flags](#available-remove-flags)
- [Common workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)
- [Directory layout](#directory-layout)

---

## What this sets up

Running `deploy-taiko-full.sh` performs three phases in order:

| Phase | What happens |
|-------|-------------|
| **1 — L1 devnet** | Spins up a local Ethereum proof-of-stake network inside [Kurtosis](https://docs.kurtosis.com) |
| **2 — L1 contracts** | Deploys the Taiko Pacaya and Shasta protocol contracts onto that L1 |
| **3 — L2 stack** | Starts the Taiko L2 execution client, drivers, and Catalyst preconf nodes via Docker Compose |

Everything runs locally on your machine. No real funds or external infrastructure are needed.

---

## Prerequisites

Install each tool before running the scripts.

### 1. Docker

Docker runs all the containers that make up the stack.

- **Mac / Windows:** install [Docker Desktop](https://docs.docker.com/get-docker/)
- **Linux:** install [Docker Engine](https://docs.docker.com/engine/install/) and add your user to the `docker` group:

  ```bash
  sudo usermod -aG docker $USER
  # Log out and back in for the group change to take effect
  ```

Verify it works:

```bash
docker run --rm hello-world
```

### 2. Kurtosis

Kurtosis manages the L1 devnet as a self-contained "enclave".

```bash
# Mac (Homebrew)
brew install kurtosis-tech/tap/kurtosis-cli

# Linux / Windows WSL2
echo "deb [trusted=yes] https://apt.fury.io/kurtosis-tech/ /" \
    | sudo tee /etc/apt/sources.list.d/kurtosis.list
sudo apt update && sudo apt install kurtosis-cli
```

Verify:

```bash
kurtosis version
```

> Kurtosis requires Docker to already be running.

### 3. jq

A command-line JSON processor used by the scripts.

```bash
# Mac
brew install jq

# Ubuntu / Debian
sudo apt install jq

# Fedora / RHEL
sudo dnf install jq
```

### 4. curl

Usually pre-installed. Check with `curl --version`. If missing:

```bash
# Ubuntu / Debian
sudo apt install curl
```

### 5. git

Used to initialise submodules.

```bash
git --version   # already installed on most systems
```

### Summary checklist

```
[ ] docker        — docker version
[ ] kurtosis      — kurtosis version
[ ] jq            — jq --version
[ ] curl          — curl --version
[ ] git           — git --version
```

---

## Quick start — interactive mode

Clone the repository and enter the directory:

```bash
git clone <repo-url>
cd simple-taiko-node-nethermind
```

Copy the example environment file:

```bash
cp .env.example .env
```

> You do not need to edit `.env` right now. The deploy script fills in contract addresses and other values automatically.

Make the scripts executable (first time only):

```bash
chmod +x deploy-taiko-full.sh remove-taiko-full.sh
```

Run the deploy script:

```bash
./deploy-taiko-full.sh
```

The script walks you through a series of prompts:

1. **L2 execution client** — choose `nethermind` (default) or `taiko-geth`
2. **Deployment environment** — choose `local` (default) or `remote`
3. **Output mode** — choose `silence` (default, shows a spinner) or `debug` (full logs)
4. **L2 Blockscout explorer** — optional block explorer for the L2 (yes / no)
5. **L2 transaction spammer** — optional background traffic generator (yes / no)

Each prompt shows `[0]` as the default — just press **Enter** to accept it.

The full deploy takes **5–15 minutes** on first run, mostly waiting for Kurtosis to pull Docker images.

---

## Choosing an L2 execution client

Two execution clients are supported:

| Client | Description |
|--------|-------------|
| `nethermind` | [Nethermind](https://nethermind.io/) — a C# / .NET Ethereum client with Taiko-specific changes |
| `geth` (taiko-geth) | A Go Ethereum fork maintained by the Taiko team |

You can select the client interactively, or pass it as a flag:

```bash
./deploy-taiko-full.sh --client nethermind
./deploy-taiko-full.sh --client geth
```

Both clients expose the same L2 RPC port (`8547`), so you can switch between them for testing. Just run `./remove-taiko-full.sh` first to tear down the existing stack completely before redeploying with the other client.

### Nethermind chainspec note

When you select Nethermind, the script automatically builds a Nethermind chainspec from the authoritative Taiko genesis data:

1. **Fetches** the canonical genesis alloc from `taikoxyz/taiko-geth` (`core/taiko_genesis/internal.json`) and saves it to `static/genesis.json`. This file contains only the account balances — it is not a full genesis.
2. **Starts taiko-geth temporarily** to read the full genesis block (`eth_getBlockByNumber("0x0")`), extracting authoritative header fields: `gasLimit`, `extraData`, `mixHash`, `nonce`, `timestamp`, `parentHash`, and `baseFeePerGas`.
3. **Assembles a complete genesis.json** by combining the alloc from step 1 with the header from step 2 and a synthesized chain config (chainId, fork block numbers, Shasta timestamp).
4. **Converts** the complete genesis to a Nethermind chainspec at `static/taiko-shasta-chainspec.json` using a `gen2spec.jq` transform fetched from `NethermindEth/core-scripts`.
5. **Derives the genesis hash** by starting Nethermind briefly and reading it from its startup logs.

You do not need to maintain the chainspec file manually — it is always regenerated from the canonical source at deploy time.

**To use a different genesis source** (e.g. a local fork), set the `TAIKO_GENESIS_URL` environment variable before running the script:

```bash
export TAIKO_GENESIS_URL=https://raw.githubusercontent.com/your-fork/taiko-geth/branch/core/taiko_genesis/internal.json
./deploy-taiko-full.sh --client nethermind
```

---

## Optional add-ons

Both add-ons are opt-in and can be enabled in the interactive prompts or via flags.

### L2 Blockscout explorer

A full block explorer for your L2 chain — browse blocks, transactions, and contracts in a browser.

Enable it:

```bash
./deploy-taiko-full.sh --l2-blockscout true
```

Once running, open your browser at:

```
http://localhost:3001
```

> Blockscout starts several containers (`blockscout-postgres`, `blockscout-verifier`, `blockscout`, `blockscout-frontend`) so the first startup takes an extra minute or two.

### L2 transaction spammer

Automatically sends a continuous stream of transactions to your L2 so you can observe the chain processing real load without any manual effort.

Enable it:

```bash
./deploy-taiko-full.sh --l2-spammer true
```

The spammer dashboard is at:

```
http://localhost:8083
```

Two scenario types run by default:
- **ETH transfers** — simple value transfers between accounts
- **ERC-20 activity** — deploys test tokens and performs transfers

The scenario configuration is at `static/spamoor/scenario-configs.yml`. You can edit the `throughput` value to increase or decrease transactions per second.

---

## Non-interactive / scripted usage

Pass all options as flags to skip every prompt. Useful in CI or when you want a repeatable one-liner:

```bash
# Full deploy, nethermind, debug output
./deploy-taiko-full.sh --client nethermind --mode debug -f

# Full deploy, geth, with Blockscout and spammer, no prompts
./deploy-taiko-full.sh --client geth --l2-blockscout true --l2-spammer true -f

# Restart the L2 stack only (L1 and contracts already deployed)
./deploy-taiko-full.sh --skip-l1-devnet --skip-contracts -f

# Deploy with an existing L1, redeploy contracts and stack
./deploy-taiko-full.sh --skip-l1-devnet -f
```

> **Important:** Do not use `--skip-contracts` after a full teardown. If you removed the L1 devnet, the old contract addresses no longer exist — you must redeploy them.

---

## Available deploy flags

| Flag | Values | Default | Description |
|------|--------|---------|-------------|
| `--client` | `nethermind` \| `geth` | from `.env`, or interactive | L2 execution client |
| `--environment` | `local` \| `remote` | interactive | Whether the L1 devnet is local or remote |
| `--skip-l1-devnet` | — | false | Skip L1 devnet deployment (reuse running devnet) |
| `--skip-contracts` | — | false | Skip contract deployment (reuse existing `deployments/`) |
| `--l1-blockscout` | — | false | Enable Blockscout inside the L1 devnet |
| `--l2-blockscout` | `true` \| `false` | interactive | Enable L2 Blockscout explorer |
| `--l2-spammer` | `true` \| `false` | interactive | Enable L2 transaction spammer |
| `--mode` | `silence` \| `debug` | interactive | Output verbosity |
| `-f`, `--force` | — | false | Skip all confirmation prompts, use defaults |
| `-h`, `--help` | — | — | Print help and exit |

---

## Service endpoints

After a successful deploy, the deploy script prints the exact URLs for your environment. The table below shows the defaults for a **local** deploy:

| Service | URL |
|---------|-----|
| L1 RPC (HTTP) | `http://localhost:32003` |
| L1 RPC (WebSocket) | `ws://localhost:32004` |
| L1 Beacon API | `http://localhost:33001` |
| L2 RPC (HTTP) | `http://localhost:8547` |
| L2 RPC (WebSocket) | `ws://localhost:8548` |
| L2 Blockscout *(if enabled)* | `http://localhost:3001` |
| L2 Spammer UI *(if enabled)* | `http://localhost:8083` |

> **Remote deploy:** when you run with `--environment remote`, all URLs in the summary use the machine's IP address instead of `localhost`, so external clients can reach them.

> **Note for Docker containers:** the `.env` file stores the Docker-internal form of L1 URLs (`host.docker.internal:32003`). These are used by the L2 containers to reach the L1. The `localhost` form is only for access from your host terminal.

You can point any Ethereum-compatible wallet or tool (e.g. MetaMask, cast, ethers.js) at `http://localhost:8547` to interact with your L2.

---

## Tearing down the stack

```bash
./remove-taiko-full.sh
```

The script prompts you to choose which components to remove:

1. **L1 devnet** (Kurtosis enclave) — removes the entire L1 network
2. **L2 stack containers** — stops and removes all Docker containers
3. **Docker volumes** — deletes persistent data (chain state, database files)
4. **Deployment files** — removes the `deployments/` directory (contract addresses)
5. **`.env` file** — resets environment configuration

> **Tip:** Remove everything (options 1–5) when you want a completely clean slate for a fresh deploy. If you only want to restart the L2 containers without losing the L1 or contract state, select options 2 and 3 only.

### Available remove flags

```bash
# Remove everything without prompts
./remove-taiko-full.sh --force

# Remove only containers and volumes, keep L1 and contract addresses
./remove-taiko-full.sh --remove-l1-devnet false --remove-deployments false --remove-env false --force

# Full debug teardown to see what is happening
./remove-taiko-full.sh --mode debug
```

| Flag | Values | Description |
|------|--------|-------------|
| `--remove-l1-devnet` | `true` \| `false` | Remove the Kurtosis L1 enclave |
| `--remove-stack` | `true` \| `false` | Stop and remove L2 Docker containers |
| `--remove-volumes` | `true` \| `false` | Delete Docker volumes (chain data) |
| `--remove-deployments` | `true` \| `false` | Delete `deployments/` directory |
| `--remove-env` | `true` \| `false` | Delete `.env` file |
| `--mode` | `silence` \| `debug` | Output verbosity |
| `-f`, `--force` | — | Skip confirmation prompts, remove all by default |

---

## Common workflows

### Start fresh

```bash
./remove-taiko-full.sh --force
./deploy-taiko-full.sh --client nethermind -f
```

### Restart L2 containers without touching L1

```bash
./remove-taiko-full.sh --remove-l1-devnet false --remove-deployments false --remove-env false --force
./deploy-taiko-full.sh --skip-l1-devnet --skip-contracts -f
```

### Switch from geth to nethermind

```bash
./remove-taiko-full.sh --force
./deploy-taiko-full.sh --client nethermind -f
```

### Deploy with everything enabled, debug mode

```bash
./deploy-taiko-full.sh --client nethermind --l2-blockscout true --l2-spammer true --mode debug -f
```

### Check what containers are running

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### Check container logs

```bash
# L2 execution client (nethermind)
docker logs taiko-nethermind-1 --tail 50 -f

# L2 execution client (geth)
docker logs taiko-geth-1 --tail 50 -f

# Catalyst driver
docker logs taiko-driver-1 --tail 50 -f
```

---

## Troubleshooting

### Docker permission denied

```
permission denied while trying to connect to the Docker daemon
```

Your user is not in the `docker` group. Fix:

```bash
sudo usermod -aG docker $USER
```

Log out and back in, then try again.

---

### Kurtosis enclave already exists

```
An enclave with name 'surge-devnet' already exists
```

A previous devnet was not cleaned up. Remove it:

```bash
kurtosis enclave rm surge-devnet --force
# Then re-run deploy
./deploy-taiko-full.sh
```

---

### Genesis hash mismatch (Nethermind)

```
genesis header hash mismatch, node: 0x3c23..., Taiko contract: 0x7a2c...
```

The genesis hash Nethermind computed from the chainspec does not match the hash the deployer registered on L1.

The deploy script always regenerates the chainspec from the authoritative taiko-geth source, so this should not happen during a fresh deploy. If you see it:

- Run a full teardown and redeploy — this forces the chainspec to be rebuilt:

```bash
./remove-taiko-full.sh --force
./deploy-taiko-full.sh --client nethermind -f
```

- If the taiko-geth source has changed and you need a specific version, set `TAIKO_GENESIS_URL` to a fixed commit URL:

```bash
export TAIKO_GENESIS_URL=https://raw.githubusercontent.com/taikoxyz/taiko-geth/<commit>/core/taiko_genesis/internal.json
./deploy-taiko-full.sh --client nethermind -f
```

---

### Stack starts but L2 RPC is not responding

Containers may still be initialising. Wait 30 seconds and try:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8547
```

If it keeps failing, check the logs:

```bash
docker logs taiko-nethermind-1 --tail 100
# or
docker logs taiko-geth-1 --tail 100
```

---

### Blockscout not loading

Blockscout has several containers and takes a couple of minutes to become ready. Check all four are running:

```bash
docker ps | grep blockscout
```

You should see: `blockscout-postgres`, `blockscout-verifier`, `blockscout`, `blockscout-frontend`.

---

### L1 health check warning

```
[WARNING] L1 execution layer not responding at http://localhost:32003 (may still be starting)
```

This warning appears immediately after the L1 devnet starts and is usually harmless — the L1 nodes need a few seconds to come up after Kurtosis finishes. The deploy continues regardless.

If the L2 stack later fails to connect to L1, the devnet may have failed to start cleanly. Check:

```bash
kurtosis enclave ls
kurtosis enclave inspect surge-devnet
```

If the enclave shows errors, run a full teardown and try again:

```bash
./remove-taiko-full.sh --force
./deploy-taiko-full.sh -f
```

---

### fork-switch exits immediately on startup

```
Error during transition monitoring: Error: socket hang up
```

The `fork-switch` service monitors the L1 for the Shasta fork activation and then submits the `activate` transaction to L2. On first start it may attempt to connect before the L2 execution client's RPC is ready, which causes it to crash.

This is handled automatically — `fork-switch` has `restart: on-failure` in the Docker Compose configuration, so it retries and succeeds once the L2 RPC is up. A brief error in the logs on the first attempt is expected and harmless.

To verify it recovered:

```bash
docker logs fork-switch --tail 20
```

A successful run ends with something like `Shasta activation submitted` and the container exits with code 0.

---

### Re-run in debug mode for more details

If you see an error and are not sure why, re-run with `--mode debug` for full output:

```bash
./deploy-taiko-full.sh --mode debug
```

---

## Directory layout

```
simple-taiko-node-nethermind/
├── deploy-taiko-full.sh          # Main deploy script (L1 devnet, contracts, L2 stack)
├── remove-taiko-full.sh          # Teardown script
├── helpers.sh                    # Shared functions sourced by both scripts:
│                                 #   URL helpers (to_localhost, configure_environment_urls)
│                                 #   Kurtosis helpers, env-file helpers, fork timestamp
├── docker-compose.yml            # L2 stack for taiko-geth (includes fork-switch)
├── docker-compose-nethermind.yml # L2 stack for Nethermind (includes fork-switch)
├── .env.example                  # Environment variable template
├── configs/                      # Patched ethereum-package configuration files
│   ├── network_params.yaml       # L1 network parameters (slot time, etc.)
│   └── ...
├── static/
│   ├── taiko-shasta-chainspec.json  # Auto-generated Nethermind chainspec (git-ignored)
│   ├── genesis.json                 # Auto-fetched from taikoxyz/taiko-geth (git-ignored)
│   └── spamoor/
│       └── scenario-configs.yml     # Transaction spammer scenario definitions
├── deployments/                  # Auto-generated contract address files (git-ignored)
└── ethereum-package/             # Kurtosis ethereum-package submodule
```

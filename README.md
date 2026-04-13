# Aegis V3 Sentinel — Ethereum Mainnet

> A production-grade Drosera Trap monitoring the **Lido V3 stVaults ecosystem** on Ethereum Mainnet — detecting bad debt, protocol pauses, vault health degradation, wstETH rate drops, and external ratio breaches with automated on-chain response and early warning alerts.

---

## Overview

This repository contains two contracts that work together as a complete Drosera Trap system on Ethereum Mainnet:

| Contract | Role | Address |
|---|---|---|
| `AegisV3Sentinel` | Drosera Trap — collects & analyses Lido V3 stVaults state | [`0xFb2e59783cA7aEE91D5043442D7834AdC99c91b4`](https://etherscan.io/address/0xFb2e59783cA7aEE91D5043442D7834AdC99c91b4) |
| `AegisV3Response` | Response contract — records risk events on-chain | [`0xab09B264F89DA35E7dCA82Ba01046e4c4D152d92`](https://etherscan.io/address/0xab09B264F89DA35E7dCA82Ba01046e4c4D152d92) |

**Operator:** [`0x689Ad0f9cBa2dA64039cF894E9fB3Aa6266861D8`](https://etherscan.io/address/0x689Ad0f9cBa2dA64039cF894E9fB3Aa6266861D8)

> **Part of a 2-trap mainnet deployment:**
> - [Lido Sentinel Mainnet](https://github.com/DAOmindbreaker/lido-sentinel-mainnet) — Lido core protocol accounting health
> - **Aegis V3 Sentinel** (this repo) — Lido V3 stVaults ecosystem monitoring

---

## Why Aegis V3?

Lido V3 launched stVaults on Ethereum mainnet on January 30, 2026 — introducing modular, customizable staking infrastructure. With 12+ active vaults and growing institutional adoption, monitoring the health of this ecosystem is critical.

**Aegis V3 Sentinel** fills this gap by providing real-time, decentralized monitoring of the entire stVaults ecosystem through the Drosera protocol — covering bad debt, protocol pauses, vault health, redemption rates, and external share ratios.

---

## Contracts Monitored (Lido V3 on Ethereum Mainnet)

| Contract | Address | Role |
|---|---|---|
| VaultHub | [`0x1d201BE093d847f6446530Efb0E8Fb426d176709`](https://etherscan.io/address/0x1d201BE093d847f6446530Efb0E8Fb426d176709) | stVaults coordination, vault health enforcement |
| stETH | [`0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`](https://etherscan.io/address/0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84) | Liquid staking token + V3 accounting functions |
| wstETH | [`0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`](https://etherscan.io/address/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0) | Wrapped stETH, redemption rate source |

> **Mainnet note:** On Ethereum mainnet, Accounting functions (`getExternalShares`, `getMaxExternalRatioBP`) are integrated into the stETH contract directly, unlike Hoodi testnet where they live in a separate Accounting contract.

---

## Data Collection

Every block sample, `collect()` captures an `AegisSnapshot` struct:

```solidity
struct AegisSnapshot {
    // VaultHub state
    uint256 vaultsCount;           // Total connected stVaults
    uint256 badDebt;               // Bad debt pending internalization (wei)
    bool    protocolPaused;        // VaultHub pause status
    uint256 unhealthyVaults;       // Count of unhealthy vaults in sample
    uint256 totalShortfallShares;  // Aggregate health shortfall (shares)
    uint256 sampleSize;            // Actual vaults sampled

    // wstETH / stETH state
    uint256 wstEthRate;            // ETH per 1e18 wstETH (scaled 1e18)
    uint256 totalPooledEther;      // Total ETH in Lido (wei)
    uint256 totalShares;           // Total stETH shares

    // Accounting cross-check
    uint256 externalShares;        // External shares minted via stVaults
    uint256 maxExternalRatioBp;    // Protocol cap (basis points)
    uint256 externalRatioBps;      // Current ratio (basis points)

    bool    valid;                 // False if any critical call reverted
}
```

### Adaptive Vault Sampling

With 12+ vaults on mainnet (and growing), Aegis uses a **stride-based sampling pattern** to efficiently cover the vault set:
- Samples up to 25 vaults per block
- Uses distributed index stride for representative coverage
- VaultHub uses **1-indexed** vault access on mainnet

---

## Detection Logic — 5 Risk Checks

`shouldRespond()` analyses 3 consecutive snapshots:

### Check A — Bad Debt Spike (CRITICAL, id=1)
**Immediate trigger** if `badDebtToInternalize > 0`. Any bad debt in VaultHub is an emergency — indicates under-collateralized vaults threatening stETH solvency.

### Check B — Protocol Pause (CRITICAL, id=2)
Triggers if VaultHub transitions from **unpaused to paused** between mid and current snapshots. A pause signals the protocol has detected critical conditions requiring intervention.

### Check C — Vault Health Degradation (HIGH, id=3)
Triggers if **≥12% of sampled vaults** are unhealthy in both current and mid snapshots. Proportional threshold prevents false positives from single-vault issues while catching systemic degradation.

### Check D — wstETH Rate Drop (HIGH, id=4)
Triggers if wstETH redemption rate drops **>3% (300 bps)** from oldest to current, with mid-sample confirmation. Sustained rate decline indicates potential accounting anomaly or mass slashing.

### Check E — External Ratio Breach (CRITICAL, id=5)
Triggers if external shares ratio **exceeds the protocol cap** across all 3 snapshots. A sustained breach means stVaults have minted more stETH than the protocol allows — systemic risk to all stETH holders.

---

## Early Warning System — 4 Alert Signals

`shouldAlert()` fires before hard triggers:

| Alert | ID | Condition | Purpose |
|---|---|---|---|
| Unhealthy Vault | 10 | Any unhealthy vault sustained across 2 samples | Early degradation signal |
| Rate Soft Drop | 11 | wstETH rate drop >1% (100 bps) | Pre-Check D warning |
| Ratio Approaching Cap | 12 | External ratio within 500 bps of cap | Pre-Check E warning |
| Pre-Bad-Debt Shortfall | 13 | Health shortfall with zero bad debt | Shortfall before bad debt materializes |

---

## Response Contract

`AegisV3Response` receives all risk reports through a single entrypoint:

```solidity
function handleRisk(uint8 checkId, uint256 a, uint256 b, uint256 c) external
```

### Events Emitted

| Check ID | Event | Severity |
|---|---|---|
| 1 | `BadDebtDetected` | CRITICAL |
| 2 | `ProtocolPauseDetected` | CRITICAL |
| 3 | `VaultHealthDegradation` | HIGH |
| 4 | `RedemptionRateDrop` | HIGH |
| 5 | `ExternalRatioBreach` | CRITICAL |
| other | `UnknownRiskSignal` | — |

### State Tracking

```solidity
uint256 public totalRiskEvents;   // Total risk events recorded
uint256 public lastRiskBlock;     // Last block a risk event was recorded
uint8   public lastCheckId;       // Last check ID that triggered
```

---

## Trap Configuration

```toml
[traps.aegis_v3_sentinel]
path                    = "out/AegisV3Sentinel.sol/AegisV3Sentinel.json"
response_contract       = "0xab09B264F89DA35E7dCA82Ba01046e4c4D152d92"
response_function       = "handleRisk(uint8,uint256,uint256,uint256)"
cooldown_period_blocks  = 33
min_number_of_operators = 1
max_number_of_operators = 3
block_sample_size       = 3
private_trap            = true
whitelist               = ["0x689Ad0f9cBa2dA64039cF894E9fB3Aa6266861D8"]
address                 = "0xFb2e59783cA7aEE91D5043442D7834AdC99c91b4"
```

---

## Dryrun Stats

```
trap_name         : aegis_v3_sentinel
trap_hash         : 0xa578bf7f57448d26b70f07da3c31aebec474d86c7ccafeb982bba8cb29ab29c9
collect() gas     : 491,399
shouldRespond()   : 37,311
shouldAlert()     : active
accounts queried  : 8
slots queried     : 83
```

---

## Mainnet Differences from Testnet

| Aspect | Hoodi Testnet | Ethereum Mainnet |
|---|---|---|
| VaultHub | `0x4C9fFC...` | `0x1d201BE093d847f6446530Efb0E8Fb426d176709` |
| Accounting | Separate contract (`0x9b5b78...`) | Integrated in stETH contract |
| stETH | `0x3508A9...` | `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` |
| wstETH | `0x7E99eE...` | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| VaultHub indexing | 0-indexed | **1-indexed** (index 0 reverts) |
| Active vaults | ~2-3 | 12+ and growing |

---

## Repository Structure

```
src/
├── AegisV3Sentinel.sol    Drosera Trap — ITrap implementation (mainnet)
└── AegisV3Response.sol    Response contract — on-chain risk recorder
script/
└── Deploy.s.sol           Forge deployment script (Response contract)
```

---

## Deployment

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Drosera CLI](https://app.drosera.io/install)
- Active [Drosera Subscription](https://app.drosera.io/early-supporters-initiative)

### Deploy Response Contract

```bash
forge build
forge script script/Deploy.s.sol:Deploy --rpc-url <ETH_MAINNET_RPC> --private-key <PRIVATE_KEY> --broadcast
```

### Deploy Trap

```bash
DROSERA_PRIVATE_KEY=<PRIVATE_KEY> drosera apply
```

### Run Operator

```bash
drosera-operator register --eth-rpc-url <ETH_MAINNET_RPC> --eth-private-key <PRIVATE_KEY>
drosera-operator optin --eth-rpc-url <ETH_MAINNET_RPC> --eth-private-key <PRIVATE_KEY> --trap-config-address 0xFb2e59783cA7aEE91D5043442D7834AdC99c91b4
```

---

## Network

| Parameter | Value |
|---|---|
| Network | Ethereum Mainnet |
| Chain ID | 1 |
| Drosera Proxy | `0x01C344b8406c3237a6b9dbd06ef2832142866d87` |
| Seed Node Relay | `https://relay.ethereum.drosera.io/` |

---

## Author

**DAOmindbreaker** — Built for the Drosera Network on Ethereum Mainnet.

X: [@admirjae](https://x.com/admirjae)

---

## License

MIT

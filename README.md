# Aegis Sentinel — Ethereum Mainnet

> Production-grade Drosera Traps monitoring the **Lido V3 stVaults ecosystem and governance** on Ethereum Mainnet. Features velocity-based detection, weighted multi-signal risk scoring, and invariant drift monitoring — detecting not just *what* is wrong, but *how fast* things are getting worse.

---

## Overview

This repository contains production traps, next-generation trap architecture, and shared libraries for the Drosera Network on Ethereum Mainnet.

### Production (Live on Mainnet)

| Contract | Role | Address |
|---|---|---|
| `AegisV3Sentinel` | Drosera Trap — stVaults monitoring | [`0xFb2e59783cA7aEE91D5043442D7834AdC99c91b4`](https://etherscan.io/address/0xFb2e59783cA7aEE91D5043442D7834AdC99c91b4) |
| `AegisV3Response` | Response contract — risk recorder | [`0xab09B264F89DA35E7dCA82Ba01046e4c4D152d92`](https://etherscan.io/address/0xab09B264F89DA35E7dCA82Ba01046e4c4D152d92) |
| `AegisV4Response` | Response contract — V4 risk recorder | [`0x022CD6aCd644C233722e559870984095F10341a6`](https://etherscan.io/address/0x022CD6aCd644C233722e559870984095F10341a6) |
| `AegisV4Sentinel` | Drosera Trap — 15 signals + IDT | [`0xB77e5AAd667F10855ef4fF08a43e16Cf3ec0F1db`](https://etherscan.io/address/0xB77e5AAd667F10855ef4fF08a43e16Cf3ec0F1db) |

### Next-Gen (Compiled, Tested, Ready to Deploy)

| Contract | Signals | Tests | Status |
|---|---|---|---|
| `AegisV4Sentinel` | 15 weighted signals (12 + 3 IDT) | 27 tests | ✅ Active, live on mainnet |
| `LidoSentinelV3` | 10 weighted signals | 22 tests | Ready |
| `GovernanceAttackSentinel` | 8 weighted signals | 28 tests | Ready |

### Shared Libraries

| Library | Purpose | Tests |
|---|---|---|
| `VelocityEngine` | Rate of change + acceleration detection | 19 tests |
| `RiskScorer` | Weighted multi-signal risk evaluation | 28 tests |
| `InvariantEngine` | Protocol invariant drift monitoring (IDT) | — |

**Operator:** [`0x689Ad0f9cBa2dA64039cF894E9fB3Aa6266861D8`](https://etherscan.io/address/0x689Ad0f9cBa2dA64039cF894E9fB3Aa6266861D8)

> **Part of a multi-trap mainnet deployment:**
> - [Lido Sentinel Mainnet](https://github.com/DAOmindbreaker/lido-sentinel-mainnet) — Lido core protocol accounting health
> - **Aegis V3 Sentinel** (this repo) — Lido V3 stVaults ecosystem + next-gen architecture

---

## Contracts Monitored (Lido V3 on Ethereum Mainnet)

| Contract | Address | Role |
|---|---|---|
| VaultHub | [`0x1d201BE093d847f6446530Efb0E8Fb426d176709`](https://etherscan.io/address/0x1d201BE093d847f6446530Efb0E8Fb426d176709) | stVaults coordination, vault health |
| stETH | [`0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`](https://etherscan.io/address/0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84) | Liquid staking token + V3 accounting |
| wstETH | [`0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`](https://etherscan.io/address/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0) | Wrapped stETH, redemption rate |
| AccountingOracle | [`0x852deD011285fe67063a08005c71a85690503Cee`](https://etherscan.io/address/0x852deD011285fe67063a08005c71a85690503Cee) | CL balance reporting (next-gen) |
| WithdrawalQueue | [`0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1`](https://etherscan.io/address/0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1) | Pending withdrawals (next-gen) |
| LDO Token | [`0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32`](https://etherscan.io/address/0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32) | Governance token (GovernanceSentinel) |
| Aragon Voting | [`0x2e59A20f205bB85a89C53f1936454680651E618e`](https://etherscan.io/address/0x2e59A20f205bB85a89C53f1936454680651E618e) | DAO voting (GovernanceSentinel) |
| Aragon Agent | [`0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c`](https://etherscan.io/address/0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c) | DAO treasury (GovernanceSentinel) |

---

## Production: Aegis V3 Sentinel

### Detection Logic — 5 Checks

| Check | ID | Severity | Trigger |
|---|---|---|---|
| Bad Debt Spike | 1 | CRITICAL | Any bad debt in VaultHub |
| Protocol Pause | 2 | CRITICAL | Pause state transition |
| Vault Health Degradation | 3 | HIGH | >= 12% of sampled vaults unhealthy (sustained) |
| wstETH Rate Drop | 4 | HIGH | > 3% sustained rate decline |
| External Ratio Breach | 5 | CRITICAL | External shares ratio above cap (sustained) |

### Early Warning — 4 Alerts

| Alert | ID | Trigger |
|---|---|---|
| Unhealthy Vault | 10 | Any unhealthy vault sustained |
| Rate Soft Drop | 11 | > 1% rate drop |
| Ratio Approaching Cap | 12 | Within 500 bps of cap |
| Pre-Bad-Debt Shortfall | 13 | Shortfall without bad debt |

### Trap Configuration

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

## Next-Gen Architecture

### Evolution: Static Thresholds → Behavior-Based Risk Scoring

| Aspect | Current (V3) | Next-Gen (V4) |
|---|---|---|
| Detection | Static thresholds | Velocity + behavior patterns |
| Trigger | Binary (yes/no) | Risk score (LOW/MED/HIGH) |
| Signals | 5 single checks | 8-12 weighted multi-signals |
| Scope | Protocol state only | State + access + oracle + meta |
| Attack model | Single-block anomaly | Multi-block attack sequences |
| False positives | Filtered by confirmation | Filtered by scoring + context |

### VelocityEngine Library

Calculates rate of change, acceleration, and sustained direction across multi-block Drosera snapshots.

```solidity
VelocityEngine.Velocity memory v = VelocityEngine.calculate(current, mid, oldest);
// v.magnitudeBps  — total change in basis points
// v.declining      — is value going down?
// v.sustained      — decline in both intervals?
// v.accelerating   — is decline speeding up?
```

### RiskScorer Library

Evaluates multiple weighted signals and produces aggregated risk levels.

```solidity
uint256[16] memory signals;
signals[0] = RiskScorer.scoreVelocity(magnitude, threshold, weight, sustained, accelerating);
signals[1] = RiskScorer.scoreThreshold(value, threshold, weight, scalable);
signals[2] = RiskScorer.scoreTransition(current, previous, weight);
signals[3] = RiskScorer.scoreProximity(value, cap, buffer, weight);

RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);
// risk.riskLevel: 0=NONE, 1=LOW, 2=MED, 3=HIGH
// HIGH (>= 6000) → shouldRespond = true
// MED  (>= 3000) → shouldAlert = true
```

### AegisV4Sentinel — 15 Signals (12 + 3 IDT)

| Signal | Weight | Detection Type |
|---|---|---|
| S1: Bad debt present | 3000 | Instant |
| S2: Pause transition | 2500 | Meta |
| S3: Unhealthy vault velocity | 1500 | Velocity |
| S4: Unhealthy vault acceleration | 1000 | Velocity |
| S5: wstETH rate velocity | 1500 | Velocity |
| S6: wstETH rate acceleration | 1000 | Velocity |
| S7: External ratio proximity | 1800 | Proximity + velocity |
| S8: Shortfall concentration | 1200 | Behavior |
| S9: Vault churn | 800 | Behavior |
| S10: Near-threshold vaults | 1000 | Behavior |
| S11: Bad debt velocity | 2000 | Velocity |
| S12: Pool-vault divergence | 1200 | Invariant |
| **— IDT Signals (InvariantEngine) —** | | |
| S13: Share-ETH backing drift | 2200 | wstEthRate vs totalPooledEther/totalShares > 50bps sustained |
| S14: Vault collateral erosion | 1800 | shortfall/totalShares ratio increasing sustained |
| S15: External share bound | 2500 | externalShares exceeds/approaches maxExternalRatioBp |

### LidoSentinelV3 — 10 Signals

| Signal | Weight | Detection Type |
|---|---|---|
| S1: Pooled ETH velocity | 1500 | Velocity |
| S2: Pooled ETH acceleration | 1200 | Velocity |
| S3: wstETH rate velocity | 1500 | Velocity (rebase-aware) |
| S4: wstETH rate acceleration | 1000 | Velocity (rebase-aware) |
| S5: Rate consistency breach | 2500 | Invariant |
| S6: Oracle staleness | 800 | External dependency |
| S7: Withdrawal queue spike | 600 | Behavior |
| S8: Supply anomaly | 1000 | Access |
| S9: Pause state change | 1500 | Meta |
| S10: Rate-pool divergence | 1200 | Invariant |

### GovernanceAttackSentinel — 8 Signals

| Signal | Weight | Detects |
|---|---|---|
| G1: Vote count spike | 2000 | Rapid proposal creation |
| G2: Treasury LDO drain | 1500 | LDO leaving DAO agent |
| G3: Voting power concentration | 2500 | Single entity dominance (>50%) |
| G4: Active vote + power shift | 1800 | Unusual yea growth (>20%/interval) |
| G5: Treasury ETH drain | 1200 | ETH leaving DAO agent |
| G6: LDO supply anomaly | 2000 | Unexpected mint/burn |
| G7: Rapid vote execution | 1500 | Created + executed in sample window |
| G8: Multi-proposal coordination | 1000 | 3+ active proposals at once |

---

## Test Coverage

| Suite | Tests | Status |
|---|---|---|
| VelocityEngine | 19 | ✅ All passed |
| RiskScorer | 28 | ✅ All passed |
| LidoSentinelV3 | 22 | ✅ All passed |
| AegisV4Sentinel | 27 | ✅ All passed |
| GovernanceAttackSentinel | 28 | ✅ All passed |
| Libraries integration | 2 | ✅ All passed |
| **Total** | **126** | **✅ All passed** |

```bash
forge test -vvv
```

---

## Security Audit

Full audit completed — 0 Critical, 0 High, 1 Medium (fixed), 7 Low, 17 Info.

The Medium finding (GA-01: potential underflow in G4 yea growth calculation) has been fixed. All contracts approved for deployment.

---

## Repository Structure

```
src/
├── lib/
│   ├── VelocityEngine.sol              Velocity + acceleration library
│   └── RiskScorer.sol                  Weighted risk scoring library
├── AegisV3Sentinel.sol                 Production trap (live on mainnet)
├── AegisV3Response.sol                 Production response (live on mainnet)
├── AegisV4Sentinel.sol                 Next-gen: 12-signal risk scoring
├── AegisV4Response.sol                 Next-gen response contract
├── LidoSentinelV3.sol                  Next-gen: 10-signal Lido monitoring
├── LidoSentinelResponseV3.sol          Next-gen Lido response
├── GovernanceAttackSentinel.sol        Next-gen: DAO manipulation detection
└── GovernanceAttackResponse.sol        Governance response contract
script/
├── Deploy.s.sol                        Aegis V3 Response deployment
└── DeployGov.s.sol                     Governance Response deployment
test/
├── Libraries.t.sol                     VelocityEngine + RiskScorer tests
├── LidoSentinelV3.t.sol                Lido V3 next-gen tests
├── AegisV4Sentinel.t.sol               Aegis V4 next-gen tests
└── GovernanceAttackSentinel.t.sol       Governance Sentinel tests
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

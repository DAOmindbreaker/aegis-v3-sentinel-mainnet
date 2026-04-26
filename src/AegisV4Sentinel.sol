// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";
import {VelocityEngine} from "./lib/VelocityEngine.sol";
import {RiskScorer} from "./lib/RiskScorer.sol";
import {InvariantEngine} from "./lib/InvariantEngine.sol";

/**
 * @title  Aegis V3 Sentinel — v4 (Next-Gen)
 * @author DAOmindbreaker
 * @notice Next-generation Drosera Trap monitoring the Lido V3 stVaults ecosystem
 *         using velocity-based detection, multi-signal risk scoring, and behavioral
 *         analysis across multiple consecutive block samples.
 *
 * @dev    Upgrades from v3:
 *         - Velocity engine: rate of change + acceleration for vault health, bad debt,
 *           external ratio, and wstETH rate
 *         - Risk scoring: 12 weighted signals aggregated into LOW/MED/HIGH
 *         - Behavior signals: shortfall concentration, vault churn, near-threshold vaults
 *         - Invariant checks: pool-vault divergence detection
 *         - Context-aware: oracle rebase window reduces rate signal sensitivity
 *
 *         Signal Matrix (12 signals):
 *           S1  (w:3000) Bad debt present — any bad debt is emergency
 *           S2  (w:2500) Protocol pause transition — pause toggled
 *           S3  (w:1500) Unhealthy vault velocity — count increasing across samples
 *           S4  (w:1000) Unhealthy vault acceleration — increase speeding up
 *           S5  (w:1500) wstETH rate velocity — declining > 100 bps/interval
 *           S6  (w:1000) wstETH rate acceleration — rate decline speeding up
 *           S7  (w:1800) External ratio velocity — approaching cap, accelerating
 *           S8  (w:1200) Shortfall concentration — single vault > 50% of total shortfall
 *           S9  (w:800)  Vault churn — rapid vault add/remove
 *           S10 (w:1000) Near-threshold vaults — > 25% vaults approaching unhealthy
 *           S11 (w:2000) Bad debt velocity — bad debt increasing across samples
 *           S12 (w:1200) Pool-vault divergence — pool shrinks but vault count grows
 *
 *         IDT Signals (Invariant Drift Trap):
 *           S13 (w:2200) Share-ETH backing drift — wstEthRate vs totalPooledEther/totalShares divergence
 *           S14 (w:1800) Vault collateral erosion — shortfall/totalShares ratio increasing sustained
 *           S15 (w:2500) External share bound breach — externalShares exceeds or approaches maxExternalRatioBp
 *
 *         Risk Levels -> Drosera mapping:
 *           HIGH (>= 6000) -> shouldRespond = true
 *           MED  (>= 3000) -> shouldAlert = true
 *           LOW  (> 0)     -> no action
 *
 * Contracts monitored (Lido V3 on Ethereum Mainnet):
 *   VaultHub    : 0x1d201BE093d847f6446530Efb0E8Fb426d176709
 *   stETH       : 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
 *   wstETH      : 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
 */

// ─────────────────────────────────────────────
//  External interfaces
// ─────────────────────────────────────────────

interface IVaultHub {
    function vaultsCount() external view returns (uint256);
    function badDebtToInternalize() external view returns (uint256);
    function isPaused() external view returns (bool);
    function vaultByIndex(uint256 index) external view returns (address);
    function isVaultHealthy(address vault) external view returns (bool);
    function healthShortfallShares(address vault) external view returns (uint256);
}

interface IStETH {
    function getTotalPooledEther() external view returns (uint256);
    function getTotalShares() external view returns (uint256);
    function getExternalShares() external view returns (uint256);
    function getMaxExternalRatioBP() external view returns (uint256);
}

interface IWstETH {
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
}

// ─────────────────────────────────────────────
//  Data structures
// ─────────────────────────────────────────────

/// @notice Enhanced snapshot with behavioral and velocity-ready data
struct AegisSnapshotV4 {
    // ── VaultHub State ──────────────────────
    uint256 vaultsCount;
    uint256 badDebt;
    bool    protocolPaused;
    uint256 unhealthyVaults;
    uint256 totalShortfallShares;
    uint256 sampleSize;

    // ── Vault Behavior ──────────────────────
    uint256 largestSingleShortfall;   // max shortfall in any one vault
    uint256 vaultsNearThreshold;      // vaults with small but nonzero shortfall

    // ── wstETH / stETH State ────────────────
    uint256 wstEthRate;
    uint256 totalPooledEther;
    uint256 totalShares;

    // ── Accounting Cross-check ──────────────
    uint256 externalShares;
    uint256 maxExternalRatioBp;
    uint256 externalRatioBps;

    // ── Metadata ────────────────────────────
    bool    valid;
}

// ─────────────────────────────────────────────
//  Trap contract
// ─────────────────────────────────────────────

contract AegisV4Sentinel is ITrap {

    // ── Contract Addresses (Mainnet) ────────

    address public constant VAULT_HUB = 0x1d201BE093d847f6446530Efb0E8Fb426d176709;
    address public constant STETH     = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant WSTETH    = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // ── Sampling ────────────────────────────
    uint256 public constant VAULT_SAMPLE_SIZE = 25;

    // ── Constants ───────────────────────────
    uint256 public constant BPS_DENOM = 10_000;

    // ── Signal Thresholds ───────────────────
    uint256 public constant S5_RATE_VELOCITY_BPS       = 100;   // 1% per interval
    uint256 public constant S7_RATIO_PROXIMITY_BPS     = 500;   // within 5% of cap
    uint256 public constant S10_NEAR_THRESHOLD_PCT     = 2500;  // 25% of sample
    uint256 public constant S13_SHARE_ETH_DRIFT_BPS    = 50;    // 0.5% drift threshold
    uint256 public constant S14_COLLATERAL_EROSION_BPS = 100;   // 1% shortfall ratio
    uint256 public constant S15_EXTERNAL_PROXIMITY_BPS = 300;   // within 3% of cap

    // ── Signal Weights ──────────────────────
    uint256 public constant W1  = 3000;  // Bad debt present
    uint256 public constant W2  = 2500;  // Protocol pause transition
    uint256 public constant W3  = 1500;  // Unhealthy vault velocity
    uint256 public constant W4  = 1000;  // Unhealthy vault acceleration
    uint256 public constant W5  = 1500;  // wstETH rate velocity
    uint256 public constant W6  = 1000;  // wstETH rate acceleration
    uint256 public constant W7  = 1800;  // External ratio velocity
    uint256 public constant W8  = 1200;  // Shortfall concentration
    uint256 public constant W9  = 800;   // Vault churn
    uint256 public constant W10 = 1000;  // Near-threshold vaults
    uint256 public constant W11 = 2000;  // Bad debt velocity
    uint256 public constant W12 = 1200;  // Pool-vault divergence
    uint256 public constant W13 = 2200;  // IDT: Share-ETH backing drift
    uint256 public constant W14 = 1800;  // IDT: Vault collateral erosion
    uint256 public constant W15 = 2500;  // IDT: External share bound breach

    // ── collect() ────────────────────────────

    /**
     * @notice Collects enhanced AegisSnapshotV4 with behavioral vault data.
     * @dev    VaultHub.vaultByIndex() is 1-indexed on mainnet.
     *         New: tracks largest single shortfall and near-threshold vaults.
     */
    function collect() external view returns (bytes memory) {
        AegisSnapshotV4 memory snap;

        // ── VaultHub global state ─────────────
        try IVaultHub(VAULT_HUB).vaultsCount() returns (uint256 count) {
            snap.vaultsCount = count;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IVaultHub(VAULT_HUB).badDebtToInternalize() returns (uint256 debt) {
            snap.badDebt = debt;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IVaultHub(VAULT_HUB).isPaused() returns (bool paused) {
            snap.protocolPaused = paused;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Adaptive vault sampling (1-indexed) ──
        uint256 sampleSize = snap.vaultsCount < VAULT_SAMPLE_SIZE
            ? snap.vaultsCount
            : VAULT_SAMPLE_SIZE;

        snap.sampleSize = sampleSize;

        uint256 stride = sampleSize > 0 && snap.vaultsCount > sampleSize
            ? snap.vaultsCount / sampleSize
            : 1;

        for (uint256 i = 0; i < sampleSize; ) {
            uint256 vaultIndex = (i * stride) + 1;

            if (vaultIndex > snap.vaultsCount) {
                unchecked { ++i; }
                continue;
            }

            address vault;
            try IVaultHub(VAULT_HUB).vaultByIndex(vaultIndex) returns (address v) {
                vault = v;
            } catch {
                unchecked { ++i; }
                continue;
            }

            if (vault == address(0)) {
                unchecked { ++i; }
                continue;
            }

            // Check health
            try IVaultHub(VAULT_HUB).isVaultHealthy(vault) returns (bool healthy) {
                if (!healthy) {
                    unchecked { ++snap.unhealthyVaults; }
                }
            } catch {
                unchecked { ++i; }
                continue;
            }

            // Check shortfall + behavioral data
            try IVaultHub(VAULT_HUB).healthShortfallShares(vault) returns (uint256 shortfall) {
                snap.totalShortfallShares += shortfall;

                // Track largest single shortfall (concentration signal)
                if (shortfall > snap.largestSingleShortfall) {
                    snap.largestSingleShortfall = shortfall;
                }

                // Track vaults with nonzero shortfall but still healthy (near-threshold)
                if (shortfall > 0) {
                    unchecked { ++snap.vaultsNearThreshold; }
                }
            } catch {
                // Non-critical
            }

            unchecked { ++i; }
        }

        // ── wstETH redemption rate ────────────
        try IWstETH(WSTETH).getPooledEthByShares(1e18) returns (uint256 rate) {
            snap.wstEthRate = rate;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── stETH pool ────────────────────────
        try IStETH(STETH).getTotalPooledEther() returns (uint256 pooled) {
            snap.totalPooledEther = pooled;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IStETH(STETH).getTotalShares() returns (uint256 shares) {
            snap.totalShares = shares;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Accounting (from stETH on mainnet) ─
        try IStETH(STETH).getExternalShares() returns (uint256 extShares) {
            snap.externalShares = extShares;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        try IStETH(STETH).getMaxExternalRatioBP() returns (uint256 maxRatio) {
            snap.maxExternalRatioBp = maxRatio;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // Derive external ratio
        if (snap.totalShares > 0 && snap.externalShares > 0) {
            snap.externalRatioBps = (snap.externalShares * BPS_DENOM) / snap.totalShares;
        }

        snap.valid = true;
        return abi.encode(snap);
    }

    // ── shouldRespond() ──────────────────────

    /**
     * @notice Evaluates 3 consecutive snapshots using velocity engine + risk scoring.
     * @dev    Returns (true, payload) if risk level >= HIGH (score >= 6000).
     */
    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 3) return (false, bytes(""));

        AegisSnapshotV4 memory current = abi.decode(data[0], (AegisSnapshotV4));
        AegisSnapshotV4 memory mid     = abi.decode(data[1], (AegisSnapshotV4));
        AegisSnapshotV4 memory oldest  = abi.decode(data[2], (AegisSnapshotV4));

        if (!current.valid || !mid.valid || !oldest.valid) {
            return (false, bytes(""));
        }

        // ── Calculate velocities ────────────
        VelocityEngine.Velocity memory unhealthyV = VelocityEngine.calculateIncreasing(
            current.unhealthyVaults, mid.unhealthyVaults, oldest.unhealthyVaults
        );

        VelocityEngine.Velocity memory rateV = VelocityEngine.calculate(
            current.wstEthRate, mid.wstEthRate, oldest.wstEthRate
        );

        VelocityEngine.Velocity memory ratioV = VelocityEngine.calculateIncreasing(
            current.externalRatioBps, mid.externalRatioBps, oldest.externalRatioBps
        );

        VelocityEngine.Velocity memory debtV = VelocityEngine.calculateIncreasing(
            current.badDebt, mid.badDebt, oldest.badDebt
        );

        // ── Score 12 signals ────────────────
        uint256[16] memory signals;

        // S1: Bad debt present (instant — any bad debt is emergency)
        if (current.badDebt > 0) {
            signals[0] = W1;
        }

        // S2: Protocol pause transition
        signals[1] = RiskScorer.scoreTransition(
            current.protocolPaused, mid.protocolPaused, W2
        );

        // S3: Unhealthy vault velocity (count increasing)
        if (unhealthyV.declining) { // "declining" = concerning increase
            signals[2] = RiskScorer.scoreVelocity(
                unhealthyV.magnitudeBps, 0, W3,
                unhealthyV.sustained, unhealthyV.accelerating
            );
            // Override: if any unhealthy vault exists and sustained, minimum score
            if (current.unhealthyVaults > 0 && mid.unhealthyVaults > 0 && signals[2] == 0) {
                signals[2] = W3 / 2; // half weight for sustained presence
            }
        }

        // S4: Unhealthy vault acceleration
        if (unhealthyV.declining && unhealthyV.accelerating) {
            signals[3] = W4;
        }

        // S5: wstETH rate velocity
        if (rateV.declining) {
            signals[4] = RiskScorer.scoreVelocity(
                rateV.magnitudeBps, S5_RATE_VELOCITY_BPS, W5,
                rateV.sustained, rateV.accelerating
            );
        }

        // S6: wstETH rate acceleration
        if (rateV.declining && rateV.accelerating) {
            signals[5] = W6;
        }

        // S7: External ratio velocity (approaching cap)
        if (current.maxExternalRatioBp > 0) {
            signals[6] = RiskScorer.scoreProximity(
                current.externalRatioBps,
                current.maxExternalRatioBp,
                S7_RATIO_PROXIMITY_BPS,
                W7
            );
            // Bonus if ratio is accelerating toward cap
            if (ratioV.declining && ratioV.accelerating && signals[6] > 0) {
                signals[6] = (signals[6] * 150) / 100; // +50% for accelerating
            }
        }

        // S8: Shortfall concentration (single vault dominance)
        if (current.totalShortfallShares > 0 && current.largestSingleShortfall > 0) {
            uint256 concentrationPct = (current.largestSingleShortfall * 100)
                / current.totalShortfallShares;
            if (concentrationPct >= 50) {
                signals[7] = W8;
            }
        }

        // S9: Vault churn (rapid vault count changes)
        if (current.vaultsCount != oldest.vaultsCount) {
            uint256 churnDelta = current.vaultsCount > oldest.vaultsCount
                ? current.vaultsCount - oldest.vaultsCount
                : oldest.vaultsCount - current.vaultsCount;
            // More than 2 vaults changed in 3 blocks = unusual
            if (churnDelta >= 2) {
                signals[8] = W9;
            }
        }

        // S10: Near-threshold vaults (many vaults have nonzero shortfall)
        if (current.sampleSize > 0) {
            uint256 nearPct = (current.vaultsNearThreshold * BPS_DENOM) / current.sampleSize;
            if (nearPct >= S10_NEAR_THRESHOLD_PCT) {
                signals[9] = W10;
            }
        }

        // S11: Bad debt velocity (bad debt increasing across samples)
        if (debtV.declining && debtV.magnitudeBps > 0) { // "declining" = increasing concern
            signals[10] = RiskScorer.scoreVelocity(
                debtV.magnitudeBps, 0, W11,
                debtV.sustained, debtV.accelerating
            );
        }

        // S12: Pool-vault divergence (invariant)
        // Pool shrinking but vault count growing = suspicious
        bool poolShrinking = current.totalPooledEther < oldest.totalPooledEther;
        bool vaultsGrowing = current.vaultsCount > oldest.vaultsCount;
        if (poolShrinking && vaultsGrowing) {
            signals[11] = W12;
        }
        // Also: external ratio growing but pool shrinking
        bool ratioGrowing = current.externalRatioBps > oldest.externalRatioBps;
        if (poolShrinking && ratioGrowing) {
            signals[11] = W12; // same signal, either condition triggers
        }

        // ── S13: Share-ETH backing drift (IDT) ──────────────────────────────────
        // wstEthRate should equal totalPooledEther * 1e18 / totalShares
        // Sustained drift > 50bps = accounting inconsistency
        InvariantEngine.InvariantResult memory shareEthCurrent = InvariantEngine.checkShareEthBacking(
            current.wstEthRate, current.totalPooledEther, current.totalShares, S13_SHARE_ETH_DRIFT_BPS
        );
        InvariantEngine.InvariantResult memory shareEthMid = InvariantEngine.checkShareEthBacking(
            mid.wstEthRate, mid.totalPooledEther, mid.totalShares, S13_SHARE_ETH_DRIFT_BPS
        );
        if (shareEthCurrent.breached && shareEthMid.breached) {
            signals[12] = RiskScorer.scoreVelocity(
                shareEthCurrent.driftBps, S13_SHARE_ETH_DRIFT_BPS, W13,
                true, InvariantEngine.isDriftWorsening(shareEthCurrent, shareEthMid)
            );
        }

        // ── S14: Vault collateral erosion (IDT) ──────────────────────────────────
        // totalShortfallShares / totalShares increasing sustained = systemic undercollateralization
        InvariantEngine.InvariantResult memory collateral = InvariantEngine.checkVaultCollateralErosion(
            current.totalShortfallShares, current.totalShares,
            mid.totalShortfallShares, mid.totalShares,
            S14_COLLATERAL_EROSION_BPS
        );
        if (collateral.sustained) {
            signals[13] = W14;
        }

        // ── S15: External share bound breach (IDT) ────────────────────────────────
        // externalShares must never exceed maxExternalRatioBp of totalShares
        // Hard breach = full weight, approaching cap = half weight
        (InvariantEngine.InvariantResult memory extBound, ) = InvariantEngine.checkExternalShareBound(
            current.externalShares, current.totalShares,
            current.maxExternalRatioBp, S15_EXTERNAL_PROXIMITY_BPS
        );
        if (extBound.breached) {
            signals[14] = W15;
        } else if (extBound.driftIncreasing) {
            signals[14] = W15 / 2;
        }

        // ── Evaluate risk ───────────────────
        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 15);

        if (risk.riskLevel >= RiskScorer.RISK_HIGH) {
            return (true, RiskScorer.encodePayload(risk));
        }

        return (false, bytes(""));
    }

    // ── shouldAlert() ─────────────────────────

    /**
     * @notice Early warning — fires when risk level >= MED (score >= 3000).
     * @dev    Uses 2 snapshots for faster detection with reduced signal set.
     */
    function shouldAlert(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 2) return (false, bytes(""));

        AegisSnapshotV4 memory current = abi.decode(data[0], (AegisSnapshotV4));
        AegisSnapshotV4 memory mid     = abi.decode(data[1], (AegisSnapshotV4));

        if (!current.valid || !mid.valid) return (false, bytes(""));

        uint256[16] memory signals;

        // S1: Bad debt (instant alert)
        if (current.badDebt > 0) {
            signals[0] = W1;
        }

        // S2: Pause transition
        signals[1] = RiskScorer.scoreTransition(
            current.protocolPaused, mid.protocolPaused, W2
        );

        // S3: Any unhealthy vault sustained
        if (current.unhealthyVaults > 0 && mid.unhealthyVaults > 0) {
            signals[2] = W3;
        }

        // S5: Rate drop between intervals
        if (current.wstEthRate < mid.wstEthRate && mid.wstEthRate > 0) {
            uint256 dropBps = ((mid.wstEthRate - current.wstEthRate) * BPS_DENOM)
                / mid.wstEthRate;
            if (dropBps >= 50) { // lower threshold for alerts (0.5%)
                signals[4] = RiskScorer.scoreVelocity(dropBps, 50, W5, false, false);
            }
        }

        // S7: Ratio approaching cap
        if (current.maxExternalRatioBp > 0) {
            signals[6] = RiskScorer.scoreProximity(
                current.externalRatioBps,
                current.maxExternalRatioBp,
                S7_RATIO_PROXIMITY_BPS,
                W7
            );
        }

        // S8: Shortfall concentration
        if (current.totalShortfallShares > 0 && current.largestSingleShortfall > 0) {
            uint256 concentrationPct = (current.largestSingleShortfall * 100)
                / current.totalShortfallShares;
            if (concentrationPct >= 50) {
                signals[7] = W8;
            }
        }

        // S10: Near-threshold vaults
        if (current.sampleSize > 0) {
            uint256 nearPct = (current.vaultsNearThreshold * BPS_DENOM) / current.sampleSize;
            if (nearPct >= S10_NEAR_THRESHOLD_PCT) {
                signals[9] = W10;
            }
        }

        // S11: Pre-bad-debt shortfall (bad debt = 0 but shortfall exists)
        if (current.badDebt == 0 && current.totalShortfallShares > 0
            && mid.totalShortfallShares > 0) {
            signals[10] = W11 / 2; // half weight as early warning
        }

        // S14: Vault collateral erosion early warning (IDT)
        InvariantEngine.InvariantResult memory collateralAlert = InvariantEngine.checkVaultCollateralErosion(
            current.totalShortfallShares, current.totalShares,
            mid.totalShortfallShares, mid.totalShares,
            S14_COLLATERAL_EROSION_BPS
        );
        if (collateralAlert.driftIncreasing && collateralAlert.driftBps > 0) {
            signals[13] = W14 / 2; // half weight for alert
        }

        // S15: External share bound approaching (IDT)
        (InvariantEngine.InvariantResult memory extBoundAlert, ) = InvariantEngine.checkExternalShareBound(
            current.externalShares, current.totalShares,
            current.maxExternalRatioBp, S15_EXTERNAL_PROXIMITY_BPS
        );
        if (extBoundAlert.breached || extBoundAlert.driftIncreasing) {
            signals[14] = W15 / 3; // one-third weight for early alert
        }

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 15);

        if (risk.riskLevel >= RiskScorer.RISK_MED) {
            return (true, RiskScorer.encodePayload(risk));
        }

        return (false, bytes(""));
    }
}

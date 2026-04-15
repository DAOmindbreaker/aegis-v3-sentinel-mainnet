// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";
import {VelocityEngine} from "./lib/VelocityEngine.sol";
import {RiskScorer} from "./lib/RiskScorer.sol";

/**
 * @title  Lido Protocol Anomaly Sentinel — v3 (Next-Gen)
 * @author DAOmindbreaker
 * @notice Next-generation Drosera Trap that monitors Lido protocol health using
 *         velocity-based detection, multi-signal risk scoring, and behavior analysis.
 *
 * @dev    Upgrades from v2:
 *         - Velocity engine: detects rate of change + acceleration across blocks
 *         - Risk scoring: weighted multi-signal evaluation (LOW/MED/HIGH)
 *         - New data sources: oracle staleness, withdrawal queue, supply changes
 *         - False-positive mitigation: context multipliers (rebase window)
 *         - Replaces binary triggers with graduated risk levels
 *
 *         Signal Matrix (10 signals):
 *           S1  (w:1500) Pooled ETH velocity — declining > 200 bps/interval
 *           S2  (w:1200) Pooled ETH acceleration — decline speeding up
 *           S3  (w:1500) wstETH rate velocity — declining > 100 bps/interval
 *           S4  (w:1000) wstETH rate acceleration — rate decline speeding up
 *           S5  (w:2500) Rate consistency breach — stETH/wstETH diverge > 50 bps
 *           S6  (w:800)  Oracle staleness — > 900 slots since last report
 *           S7  (w:600)  Withdrawal queue spike — unfinalizedStETH > 200K ETH
 *           S8  (w:1000) Supply anomaly — large share changes
 *           S9  (w:1500) Pause state change — withdrawal/deposit paused
 *           S10 (w:1200) Rate-pool divergence — rate up but pool down (invariant)
 *
 *         Risk Levels → Drosera mapping:
 *           HIGH (>= 6000) → shouldRespond = true
 *           MED  (>= 3000) → shouldAlert = true
 *           LOW  (> 0)     → no action
 *
 * Contracts monitored (Ethereum Mainnet):
 *   stETH              : 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
 *   wstETH             : 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
 *   AccountingOracle   : 0x852deD011285fe67063a08005c71a85690503Cee
 *   WithdrawalQueue    : 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1
 */

// ─────────────────────────────────────────────
//  External interfaces
// ─────────────────────────────────────────────

interface IStETH {
    function getTotalPooledEther() external view returns (uint256);
    function getTotalShares() external view returns (uint256);
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
}

interface IWstETH {
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
}

interface IAccountingOracle {
    function getLastProcessingRefSlot() external view returns (uint256);
}

interface IWithdrawalQueue {
    function unfinalizedStETH() external view returns (uint256);
    function isPaused() external view returns (bool);
}

// ─────────────────────────────────────────────
//  Data structures
// ─────────────────────────────────────────────

/// @notice Enhanced snapshot with velocity-ready data
struct LidoSnapshotV3 {
    // ── Core Protocol State ─────────────────
    uint256 totalPooledEther;
    uint256 totalShares;
    uint256 wstEthRate;
    uint256 stEthInternalRate;
    uint256 rateConsistencyBps;

    // ── Oracle State ────────────────────────
    uint256 lastOracleRefSlot;
    uint256 currentSlotEstimate;
    uint256 oracleDelaySlots;

    // ── Withdrawal Queue ────────────────────
    uint256 unfinalizedStETH;
    bool    withdrawalsPaused;

    // ── Metadata ────────────────────────────
    bool    valid;
}

// ─────────────────────────────────────────────
//  Trap contract
// ─────────────────────────────────────────────

contract LidoSentinelV3 is ITrap {
    using VelocityEngine for *;

    // ── Contract Addresses (Mainnet) ────────

    address public constant STETH              = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant WSTETH             = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant ACCOUNTING_ORACLE  = 0x852deD011285fe67063a08005c71a85690503Cee;
    address public constant WITHDRAWAL_QUEUE   = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    // ── Beacon Chain Genesis ────────────────
    uint256 public constant GENESIS_TIME = 1606824023;
    uint256 public constant SLOT_DURATION = 12;

    // ── Thresholds ──────────────────────────
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MIN_POOLED_ETH = 1 ether;

    // Signal thresholds
    uint256 public constant S1_POOL_VELOCITY_BPS     = 200;   // 2% per interval
    uint256 public constant S3_RATE_VELOCITY_BPS     = 100;   // 1% per interval
    uint256 public constant S5_CONSISTENCY_BPS       = 50;    // 0.5% divergence
    uint256 public constant S6_ORACLE_STALE_SLOTS    = 900;   // ~3 hours
    uint256 public constant S7_QUEUE_SPIKE_ETH       = 200_000 ether;
    uint256 public constant S8_SUPPLY_CHANGE_BPS     = 500;   // 5% supply change

    // Signal weights
    uint256 public constant W1  = 1500;  // Pool velocity
    uint256 public constant W2  = 1200;  // Pool acceleration
    uint256 public constant W3  = 1500;  // Rate velocity
    uint256 public constant W4  = 1000;  // Rate acceleration
    uint256 public constant W5  = 2500;  // Rate consistency
    uint256 public constant W6  = 800;   // Oracle staleness
    uint256 public constant W7  = 600;   // Withdrawal queue
    uint256 public constant W8  = 1000;  // Supply anomaly
    uint256 public constant W9  = 1500;  // Pause state
    uint256 public constant W10 = 1200;  // Rate-pool divergence

    // Rebase window (slots since oracle report where rate changes are expected)
    uint256 public constant REBASE_WINDOW_SLOTS = 30;

    // ── collect() ────────────────────────────

    /**
     * @notice Collects enhanced LidoSnapshotV3 with oracle and withdrawal data.
     * @dev    Core data (pooled ETH, shares, rates) are critical — failure invalidates.
     *         Oracle and withdrawal data are best-effort — failure uses defaults.
     */
    function collect() external view returns (bytes memory) {
        LidoSnapshotV3 memory snap;

        // ── Core: Total pooled ETH ──────────
        try IStETH(STETH).getTotalPooledEther() returns (uint256 pooled) {
            snap.totalPooledEther = pooled;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Core: Total shares ──────────────
        try IStETH(STETH).getTotalShares() returns (uint256 shares) {
            snap.totalShares = shares;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Core: wstETH redemption rate ────
        try IWstETH(WSTETH).getPooledEthByShares(1e18) returns (uint256 rate) {
            snap.wstEthRate = rate;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Core: stETH internal rate ───────
        try IStETH(STETH).getPooledEthByShares(1e18) returns (uint256 internalRate) {
            snap.stEthInternalRate = internalRate;
        } catch {
            snap.valid = false;
            return abi.encode(snap);
        }

        // ── Derive rate consistency ─────────
        snap.rateConsistencyBps = VelocityEngine.divergence(
            snap.wstEthRate,
            snap.stEthInternalRate
        );

        // ── Oracle staleness (best-effort) ──
        try IAccountingOracle(ACCOUNTING_ORACLE).getLastProcessingRefSlot()
            returns (uint256 lastSlot) {
            snap.lastOracleRefSlot = lastSlot;
            snap.currentSlotEstimate = (block.timestamp - GENESIS_TIME) / SLOT_DURATION;
            snap.oracleDelaySlots = snap.currentSlotEstimate > lastSlot
                ? snap.currentSlotEstimate - lastSlot
                : 0;
        } catch {
            // Oracle unreachable — set max staleness
            snap.oracleDelaySlots = type(uint256).max;
        }

        // ── Withdrawal queue (best-effort) ──
        try IWithdrawalQueue(WITHDRAWAL_QUEUE).unfinalizedStETH()
            returns (uint256 pending) {
            snap.unfinalizedStETH = pending;
        } catch {
            // Default 0 — no withdrawal data
        }

        try IWithdrawalQueue(WITHDRAWAL_QUEUE).isPaused()
            returns (bool paused) {
            snap.withdrawalsPaused = paused;
        } catch {
            // Default false
        }

        snap.valid = true;
        return abi.encode(snap);
    }

    // ── shouldRespond() ──────────────────────

    /**
     * @notice Evaluates 3 consecutive snapshots using velocity engine + risk scoring.
     * @dev    Returns (true, payload) if risk level >= HIGH (score >= 6000).
     *         Payload: (riskLevel, totalScore, topSignalId, activeSignals)
     */
    function shouldRespond(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 3) return (false, bytes(""));

        LidoSnapshotV3 memory current = abi.decode(data[0], (LidoSnapshotV3));
        LidoSnapshotV3 memory mid     = abi.decode(data[1], (LidoSnapshotV3));
        LidoSnapshotV3 memory oldest  = abi.decode(data[2], (LidoSnapshotV3));

        if (!current.valid || !mid.valid || !oldest.valid) {
            return (false, bytes(""));
        }

        if (current.totalPooledEther < MIN_POOLED_ETH) {
            return (false, bytes(""));
        }

        // ── Calculate velocities ────────────
        VelocityEngine.Velocity memory poolV = VelocityEngine.calculate(
            current.totalPooledEther, mid.totalPooledEther, oldest.totalPooledEther
        );

        VelocityEngine.Velocity memory rateV = VelocityEngine.calculate(
            current.wstEthRate, mid.wstEthRate, oldest.wstEthRate
        );

        // ── Context: rebase window ──────────
        bool inRebaseWindow = current.oracleDelaySlots < REBASE_WINDOW_SLOTS;
        uint256 rebaseMultiplier = inRebaseWindow ? 5000 : 10000; // 0.5x during rebase

        // ── Score signals ───────────────────
        uint256[16] memory signals;

        // S1: Pooled ETH velocity
        if (poolV.declining) {
            signals[0] = RiskScorer.scoreVelocity(
                poolV.magnitudeBps, S1_POOL_VELOCITY_BPS, W1,
                poolV.sustained, poolV.accelerating
            );
        }

        // S2: Pooled ETH acceleration
        if (poolV.declining && poolV.accelerating) {
            signals[1] = W2;
        }

        // S3: wstETH rate velocity (with rebase context)
        if (rateV.declining) {
            uint256 rawScore = RiskScorer.scoreVelocity(
                rateV.magnitudeBps, S3_RATE_VELOCITY_BPS, W3,
                rateV.sustained, rateV.accelerating
            );
            signals[2] = RiskScorer.applyMultiplier(rawScore, rebaseMultiplier);
        }

        // S4: wstETH rate acceleration (with rebase context)
        if (rateV.declining && rateV.accelerating) {
            signals[3] = RiskScorer.applyMultiplier(W4, rebaseMultiplier);
        }

        // S5: Rate consistency breach (stETH vs wstETH divergence)
        signals[4] = RiskScorer.scoreThreshold(
            current.rateConsistencyBps, S5_CONSISTENCY_BPS, W5, false
        );
        // Require sustained: mid must also breach
        if (signals[4] > 0 && mid.rateConsistencyBps < S5_CONSISTENCY_BPS) {
            signals[4] = 0; // Not sustained — filter
        }

        // S6: Oracle staleness
        signals[5] = RiskScorer.scoreThreshold(
            current.oracleDelaySlots, S6_ORACLE_STALE_SLOTS, W6, true
        );

        // S7: Withdrawal queue spike
        signals[6] = RiskScorer.scoreThreshold(
            current.unfinalizedStETH, S7_QUEUE_SPIKE_ETH, W7, true
        );

        // S8: Supply anomaly (large share change between intervals)
        if (oldest.totalShares > 0) {
            uint256 shareChangeBps;
            if (current.totalShares > oldest.totalShares) {
                shareChangeBps = ((current.totalShares - oldest.totalShares) * BPS_DENOM)
                    / oldest.totalShares;
            } else {
                shareChangeBps = ((oldest.totalShares - current.totalShares) * BPS_DENOM)
                    / oldest.totalShares;
            }
            signals[7] = RiskScorer.scoreThreshold(
                shareChangeBps, S8_SUPPLY_CHANGE_BPS, W8, false
            );
        }

        // S9: Pause state change
        signals[8] = RiskScorer.scoreTransition(
            current.withdrawalsPaused, mid.withdrawalsPaused, W9
        );

        // S10: Rate-pool divergence (invariant)
        // Rate increasing but pool decreasing = suspicious
        bool rateUp = current.wstEthRate > oldest.wstEthRate;
        bool poolDown = current.totalPooledEther < oldest.totalPooledEther;
        if (rateUp && poolDown) {
            signals[9] = W10;
        }
        // Also: rate stable but pool dropping significantly
        if (!rateV.declining && poolV.declining && poolV.magnitudeBps >= 100) {
            signals[9] = W10;
        }

        // ── Evaluate risk ───────────────────
        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        if (risk.riskLevel >= RiskScorer.RISK_HIGH) {
            return (true, RiskScorer.encodePayload(risk));
        }

        return (false, bytes(""));
    }

    // ── shouldAlert() ─────────────────────────

    /**
     * @notice Early warning system — fires when risk level >= MED (score >= 3000).
     * @dev    Uses same signal framework but with 2 snapshots (faster detection).
     */
    function shouldAlert(
        bytes[] calldata data
    ) external pure returns (bool, bytes memory) {
        if (data.length < 2) return (false, bytes(""));

        LidoSnapshotV3 memory current = abi.decode(data[0], (LidoSnapshotV3));
        LidoSnapshotV3 memory mid     = abi.decode(data[1], (LidoSnapshotV3));

        if (!current.valid || !mid.valid) return (false, bytes(""));

        // ── Quick velocity (2-point) ────────
        uint256[16] memory signals;

        // Pool drop between intervals
        if (current.totalPooledEther < mid.totalPooledEther && mid.totalPooledEther > 0) {
            uint256 dropBps = ((mid.totalPooledEther - current.totalPooledEther) * BPS_DENOM)
                / mid.totalPooledEther;
            signals[0] = RiskScorer.scoreVelocity(dropBps, 100, W1, false, false);
        }

        // Rate drop between intervals
        if (current.wstEthRate < mid.wstEthRate && mid.wstEthRate > 0) {
            uint256 rateDropBps = ((mid.wstEthRate - current.wstEthRate) * BPS_DENOM)
                / mid.wstEthRate;
            signals[2] = RiskScorer.scoreVelocity(rateDropBps, 50, W3, false, false);
        }

        // Rate consistency
        signals[4] = RiskScorer.scoreThreshold(
            current.rateConsistencyBps, S5_CONSISTENCY_BPS, W5, false
        );

        // Oracle staleness
        signals[5] = RiskScorer.scoreThreshold(
            current.oracleDelaySlots, S6_ORACLE_STALE_SLOTS, W6, true
        );

        // Withdrawal queue
        signals[6] = RiskScorer.scoreThreshold(
            current.unfinalizedStETH, S7_QUEUE_SPIKE_ETH, W7, true
        );

        // Pause state change
        signals[8] = RiskScorer.scoreTransition(
            current.withdrawalsPaused, mid.withdrawalsPaused, W9
        );

        RiskScorer.RiskScore memory risk = RiskScorer.evaluate(signals, 10);

        if (risk.riskLevel >= RiskScorer.RISK_MED) {
            return (true, RiskScorer.encodePayload(risk));
        }

        return (false, bytes(""));
    }
}

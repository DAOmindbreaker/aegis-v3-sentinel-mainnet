// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  InvariantEngine
 * @author DAOmindbreaker
 * @notice Library for defining and monitoring protocol invariants across
 *         multi-block Drosera snapshots.
 *
 * @dev    An invariant is a mathematical relationship that MUST hold true
 *         under normal protocol operation. Drift from this relationship
 *         signals manipulation, accounting errors, or systemic failure.
 *
 *         Invariants monitored:
 *           I1 — Share-ETH Backing Ratio
 *                totalShares * wstEthRate should approximate totalPooledEther
 *                Drift > threshold = accounting inconsistency
 *
 *           I2 — Vault-Pool Collateral Ratio
 *                sum(vault shortfalls) / totalPooledEther should be stable
 *                Sudden increase = collateral erosion
 *
 *           I3 — External Share Bound
 *                externalShares should never exceed maxExternalRatioBp of totalShares
 *                Breach = protocol rule violation
 *
 *         All results in basis points (1 bps = 0.01%)
 */
library InvariantEngine {

    uint256 constant BPS = 10_000;
    uint256 constant PRECISION = 1e18;

    /// @notice Result of a single invariant check
    struct InvariantResult {
        uint256 driftBps;        // current drift from expected value (bps)
        uint256 prevDriftBps;    // previous drift (for velocity)
        bool    breached;        // drift exceeds hard threshold
        bool    driftIncreasing; // drift getting worse across samples
        bool    sustained;       // breach sustained across both samples
    }

    /**
     * @notice I1 — Share-ETH Backing Invariant
     * @dev    In healthy Lido: wstEthRate ≈ totalPooledEther / totalShares
     *         Both stETH and wstETH should agree on ETH-per-share.
     *         Significant drift = accounting manipulation or oracle failure.
     *
     *         Expected: wstEthRate == totalPooledEther * 1e18 / totalShares
     *         Drift = |actual - expected| / expected * BPS
     *
     * @param  wstEthRate       ETH per 1e18 wstETH shares (from wstETH contract)
     * @param  totalPooledEther Total ETH in Lido
     * @param  totalShares      Total stETH shares outstanding
     * @param  thresholdBps     Drift threshold to flag breach
     * @return result           Invariant check result
     */
    function checkShareEthBacking(
        uint256 wstEthRate,
        uint256 totalPooledEther,
        uint256 totalShares,
        uint256 thresholdBps
    ) internal pure returns (InvariantResult memory result) {
        if (totalShares == 0 || wstEthRate == 0 || totalPooledEther == 0) {
            return result;
        }

        // Expected rate: totalPooledEther * 1e18 / totalShares
        uint256 expectedRate = (totalPooledEther * PRECISION) / totalShares;

        // Drift between actual wstEthRate and expected
        uint256 delta = wstEthRate > expectedRate
            ? wstEthRate - expectedRate
            : expectedRate - wstEthRate;

        result.driftBps = (delta * BPS) / expectedRate;
        result.breached = result.driftBps >= thresholdBps;

        return result;
    }

    /**
     * @notice I2 — Vault Collateral Erosion Invariant
     * @dev    totalShortfallShares / totalShares should be near zero in healthy state.
     *         Any increase signals collateral erosion across the vault ecosystem.
     *         Sustained increase = systemic undercollateralization risk.
     *
     * @param  currentShortfall  Current total shortfall shares
     * @param  currentShares     Current total stETH shares
     * @param  prevShortfall     Previous total shortfall shares
     * @param  prevShares        Previous total stETH shares
     * @param  thresholdBps      Shortfall ratio threshold to flag breach
     * @return result            Invariant check result
     */
    function checkVaultCollateralErosion(
        uint256 currentShortfall,
        uint256 currentShares,
        uint256 prevShortfall,
        uint256 prevShares,
        uint256 thresholdBps
    ) internal pure returns (InvariantResult memory result) {
        if (currentShares == 0) return result;

        // Current shortfall ratio
        result.driftBps = (currentShortfall * BPS) / currentShares;

        // Previous shortfall ratio
        if (prevShares > 0) {
            result.prevDriftBps = (prevShortfall * BPS) / prevShares;
        }

        result.breached = result.driftBps >= thresholdBps;
        result.driftIncreasing = result.driftBps > result.prevDriftBps;
        result.sustained = result.breached && result.driftIncreasing;

        return result;
    }

    /**
     * @notice I3 — External Share Bound Invariant
     * @dev    externalShares / totalShares must never exceed maxExternalRatioBp.
     *         This is a hard protocol rule in Lido V3.
     *         Any breach = protocol invariant violation, immediate HIGH risk.
     *
     *         Also detects approach velocity — fires before actual breach.
     *
     * @param  externalShares      Current external shares
     * @param  totalShares         Current total shares
     * @param  maxExternalRatioBp  Protocol maximum (from contract)
     * @param  proximityBps        How close to cap triggers warning
     * @return result              Invariant check result
     * @return actualRatioBps      Current ratio for further analysis
     */
    function checkExternalShareBound(
        uint256 externalShares,
        uint256 totalShares,
        uint256 maxExternalRatioBp,
        uint256 proximityBps
    ) internal pure returns (InvariantResult memory result, uint256 actualRatioBps) {
        if (totalShares == 0 || maxExternalRatioBp == 0) return (result, 0);

        actualRatioBps = (externalShares * BPS) / totalShares;

        // Hard breach: ratio exceeds max
        result.breached = actualRatioBps >= maxExternalRatioBp;
        result.driftBps = actualRatioBps;

        // Proximity warning: within proximityBps of cap
        if (!result.breached && maxExternalRatioBp > proximityBps) {
            result.driftIncreasing = actualRatioBps >= maxExternalRatioBp - proximityBps;
        }

        return (result, actualRatioBps);
    }

    /**
     * @notice Compare two invariant results to detect worsening drift.
     * @dev    Returns true if drift increased between two snapshots.
     *
     * @param  current  Current invariant result
     * @param  previous Previous invariant result
     * @return worsening True if drift increased
     */
    function isDriftWorsening(
        InvariantResult memory current,
        InvariantResult memory previous
    ) internal pure returns (bool worsening) {
        worsening = current.driftBps > previous.driftBps;
    }
}

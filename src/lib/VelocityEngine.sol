// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  VelocityEngine
 * @author DAOmindbreaker
 * @notice Library for calculating rate of change, acceleration, and directional
 *         analysis across multi-block Drosera snapshots.
 *
 * @dev    All calculations use basis points (1 bps = 0.01%) for precision
 *         without floating point. Designed for Drosera's multi-block sampling
 *         where collect() provides 3+ consecutive snapshots.
 *
 *         Terminology:
 *           - velocity: rate of change between intervals (bps per interval)
 *           - acceleration: change in velocity (is decline speeding up?)
 *           - sustained: same direction across both intervals
 *           - magnitude: total change from oldest to current (bps)
 */
library VelocityEngine {

    uint256 constant BPS = 10_000;

    /// @notice Result of velocity analysis across 3 data points
    struct Velocity {
        uint256 magnitudeBps;    // total change from oldest to current (bps)
        uint256 recentBps;       // change from mid to current (bps)
        uint256 earlierBps;      // change from oldest to mid (bps)
        bool    declining;       // true if current < oldest
        bool    sustained;       // true if decline in both intervals
        bool    accelerating;    // true if recent decline > earlier decline
    }

    /**
     * @notice Calculate velocity metrics across 3 consecutive values.
     * @dev    Values are expected in chronological order:
     *         current = newest, mid = middle, oldest = oldest.
     *         Handles zero values safely.
     *
     * @param  current Latest value
     * @param  mid     Middle value
     * @param  oldest  Oldest value
     * @return v       Velocity analysis result
     */
    function calculate(
        uint256 current,
        uint256 mid,
        uint256 oldest
    ) internal pure returns (Velocity memory v) {
        if (oldest == 0) return v;

        // ── Direction ────────────────────────
        v.declining = current < oldest;

        // ── Total magnitude (oldest → current) ──
        if (v.declining) {
            v.magnitudeBps = ((oldest - current) * BPS) / oldest;
        } else {
            v.magnitudeBps = ((current - oldest) * BPS) / oldest;
        }

        // ── Interval magnitudes ─────────────
        // Recent interval: mid → current
        if (current < mid && mid > 0) {
            v.recentBps = ((mid - current) * BPS) / mid;
        } else if (current > mid && mid > 0) {
            v.recentBps = ((current - mid) * BPS) / mid;
        }

        // Earlier interval: oldest → mid
        if (mid < oldest && oldest > 0) {
            v.earlierBps = ((oldest - mid) * BPS) / oldest;
        } else if (mid > oldest && oldest > 0) {
            v.earlierBps = ((mid - oldest) * BPS) / oldest;
        }

        // ── Sustained ───────────────────────
        // Both intervals must show decline
        bool recentDown = current < mid;
        bool earlierDown = mid < oldest;
        v.sustained = recentDown && earlierDown;

        // ── Acceleration ────────────────────
        // Recent decline is bigger than earlier decline
        if (v.sustained && v.recentBps > v.earlierBps) {
            v.accelerating = true;
        }
    }

    /**
     * @notice Calculate velocity for increasing values (e.g., unhealthy vault count).
     * @dev    Same as calculate() but "concerning" direction is INCREASING not decreasing.
     *         Returns declining=true when value is increasing (concerning direction).
     *
     * @param  current Latest value
     * @param  mid     Middle value
     * @param  oldest  Oldest value
     * @return v       Velocity analysis (declining=true means concerning increase)
     */
    function calculateIncreasing(
        uint256 current,
        uint256 mid,
        uint256 oldest
    ) internal pure returns (Velocity memory v) {
        // For increasing metrics (bad debt, unhealthy count), we invert:
        // "concerning" = value going UP
        if (oldest == 0 && mid == 0 && current == 0) return v;

        // Use max(oldest, 1) to avoid division by zero
        uint256 base = oldest > 0 ? oldest : 1;

        v.declining = current > oldest; // "declining" here means "increasing concern"

        if (current > oldest) {
            v.magnitudeBps = ((current - oldest) * BPS) / base;
        }

        // Recent interval
        uint256 midBase = mid > 0 ? mid : 1;
        if (current > mid) {
            v.recentBps = ((current - mid) * BPS) / midBase;
        }

        // Earlier interval
        if (mid > oldest) {
            v.earlierBps = ((mid - oldest) * BPS) / base;
        }

        // Sustained increase
        bool recentUp = current > mid;
        bool earlierUp = mid > oldest;
        v.sustained = recentUp && earlierUp;

        // Accelerating increase
        if (v.sustained) {
            uint256 recentDelta = current - mid;
            uint256 earlierDelta = mid - oldest;
            v.accelerating = recentDelta > earlierDelta;
        }
    }

    /**
     * @notice Check if a value crossed a threshold between two samples.
     * @dev    Useful for detecting state transitions (e.g., crossing from
     *         healthy to unhealthy ratio).
     *
     * @param  current   Current value
     * @param  previous  Previous value
     * @param  threshold Threshold value
     * @return crossed   True if threshold was crossed
     * @return direction True if crossed upward (below → above)
     */
    function crossedThreshold(
        uint256 current,
        uint256 previous,
        uint256 threshold
    ) internal pure returns (bool crossed, bool direction) {
        bool currentAbove = current >= threshold;
        bool previousAbove = previous >= threshold;

        if (currentAbove != previousAbove) {
            crossed = true;
            direction = currentAbove; // true = crossed upward
        }
    }

    /**
     * @notice Calculate divergence between two values that should be equal.
     * @dev    Used for invariant checks (e.g., stETH rate vs wstETH rate).
     *
     * @param  valueA First value
     * @param  valueB Second value (reference)
     * @return divergenceBps Absolute divergence in basis points
     */
    function divergence(
        uint256 valueA,
        uint256 valueB
    ) internal pure returns (uint256 divergenceBps) {
        if (valueB == 0) return 0;

        uint256 delta = valueA > valueB
            ? valueA - valueB
            : valueB - valueA;

        divergenceBps = (delta * BPS) / valueB;
    }
}

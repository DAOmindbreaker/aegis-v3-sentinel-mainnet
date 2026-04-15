// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  RiskScorer
 * @author DAOmindbreaker
 * @notice Library for evaluating multiple weighted risk signals and producing
 *         an aggregated risk level (LOW / MED / HIGH).
 *
 * @dev    Designed for Drosera Traps that need multi-signal detection instead
 *         of binary threshold triggers. Each signal contributes a weighted
 *         score to the total risk assessment.
 *
 *         Risk Levels:
 *           0 = NONE  (score = 0)
 *           1 = LOW   (score < LOW_THRESHOLD)
 *           2 = MED   (score >= LOW_THRESHOLD, < HIGH_THRESHOLD)
 *           3 = HIGH  (score >= HIGH_THRESHOLD)
 *
 *         Mapping to Drosera:
 *           HIGH → shouldRespond() = true
 *           MED  → shouldAlert() = true
 *           LOW  → no action (logged for analysis)
 */
library RiskScorer {

    /// @notice Maximum number of signals supported
    uint256 constant MAX_SIGNALS = 16;

    /// @notice Risk level thresholds (basis points scale)
    uint256 constant LOW_THRESHOLD  = 3000;
    uint256 constant HIGH_THRESHOLD = 6000;

    /// @notice Risk level constants
    uint8 constant RISK_NONE = 0;
    uint8 constant RISK_LOW  = 1;
    uint8 constant RISK_MED  = 2;
    uint8 constant RISK_HIGH = 3;

    /// @notice Result of risk evaluation
    struct RiskScore {
        uint256 totalScore;       // sum of all weighted signal scores
        uint8   riskLevel;        // NONE / LOW / MED / HIGH
        uint8   topSignalId;      // ID of highest-scoring signal (1-indexed)
        uint256 topSignalScore;   // score of the top signal
        uint8   activeSignals;    // count of signals that scored > 0
    }

    /// @notice Individual signal definition
    struct Signal {
        uint256 score;            // weighted score (0 if not triggered)
        bool    triggered;        // whether this signal fired
    }

    /**
     * @notice Evaluate an array of signal scores and produce a risk assessment.
     * @dev    Iterates through all signals, sums scores, identifies top signal,
     *         and determines risk level.
     *
     * @param  signals Array of signal scores (index = signal ID - 1)
     * @param  count   Number of signals to evaluate
     * @return risk    Aggregated risk score
     */
    function evaluate(
        uint256[16] memory signals,
        uint256 count
    ) internal pure returns (RiskScore memory risk) {
        for (uint256 i = 0; i < count && i < MAX_SIGNALS; ) {
            if (signals[i] > 0) {
                risk.totalScore += signals[i];
                unchecked { ++risk.activeSignals; }

                if (signals[i] > risk.topSignalScore) {
                    risk.topSignalScore = signals[i];
                    risk.topSignalId = uint8(i + 1); // 1-indexed
                }
            }
            unchecked { ++i; }
        }

        risk.riskLevel = _classifyRisk(risk.totalScore);
    }

    /**
     * @notice Apply a context multiplier to a signal score.
     * @dev    Used for reducing sensitivity during known benign events
     *         (e.g., oracle rebase window, scheduled maintenance).
     *         multiplierBps: 10000 = 1x (no change), 5000 = 0.5x, 15000 = 1.5x
     *
     * @param  score         Original signal score
     * @param  multiplierBps Multiplier in basis points (10000 = 1x)
     * @return adjusted      Adjusted score
     */
    function applyMultiplier(
        uint256 score,
        uint256 multiplierBps
    ) internal pure returns (uint256 adjusted) {
        adjusted = (score * multiplierBps) / 10_000;
    }

    /**
     * @notice Score a velocity signal based on magnitude and behavior.
     * @dev    Produces a weighted score based on:
     *         - Base weight if velocity exceeds threshold
     *         - +50% bonus if sustained across intervals
     *         - +30% bonus if accelerating
     *
     * @param  magnitudeBps  Velocity magnitude in basis points
     * @param  thresholdBps  Minimum magnitude to trigger
     * @param  baseWeight    Base score if triggered
     * @param  sustained     Whether decline is sustained
     * @param  accelerating  Whether decline is accelerating
     * @return score         Weighted signal score
     */
    function scoreVelocity(
        uint256 magnitudeBps,
        uint256 thresholdBps,
        uint256 baseWeight,
        bool    sustained,
        bool    accelerating
    ) internal pure returns (uint256 score) {
        if (magnitudeBps < thresholdBps) return 0;

        score = baseWeight;

        // Sustained bonus: +50%
        if (sustained) {
            score = (score * 150) / 100;
        }

        // Acceleration bonus: +30%
        if (accelerating) {
            score = (score * 130) / 100;
        }
    }

    /**
     * @notice Score a threshold-based signal (binary: above or below).
     * @dev    Simple scoring — if value exceeds threshold, return full weight.
     *         Optional severity scaling based on how far above threshold.
     *
     * @param  value      Current value
     * @param  threshold  Trigger threshold
     * @param  baseWeight Score if triggered
     * @param  scalable   If true, score increases proportionally above threshold
     * @return score      Weighted signal score
     */
    function scoreThreshold(
        uint256 value,
        uint256 threshold,
        uint256 baseWeight,
        bool    scalable
    ) internal pure returns (uint256 score) {
        if (value < threshold) return 0;

        score = baseWeight;

        if (scalable && threshold > 0) {
            // Scale: 2x at 2x threshold, 3x at 3x threshold, etc.
            // Capped at 3x base weight
            uint256 ratio = (value * 100) / threshold;
            if (ratio > 300) ratio = 300;
            score = (baseWeight * ratio) / 100;
        }
    }

    /**
     * @notice Score a boolean state transition signal.
     * @dev    Used for detecting state changes (pause toggled, config changed).
     *
     * @param  current     Current state
     * @param  previous    Previous state
     * @param  baseWeight  Score if transition detected
     * @return score       Weighted signal score
     */
    function scoreTransition(
        bool    current,
        bool    previous,
        uint256 baseWeight
    ) internal pure returns (uint256 score) {
        if (current != previous) {
            score = baseWeight;
        }
    }

    /**
     * @notice Score a proximity signal (value approaching a limit).
     * @dev    Used for early warning when a value is within buffer of a cap.
     *
     * @param  value      Current value
     * @param  cap        Maximum allowed value
     * @param  bufferBps  How close to cap triggers the signal
     * @param  baseWeight Score if within buffer
     * @return score      Weighted signal score
     */
    function scoreProximity(
        uint256 value,
        uint256 cap,
        uint256 bufferBps,
        uint256 baseWeight
    ) internal pure returns (uint256 score) {
        if (cap == 0 || value == 0) return 0;
        if (value >= cap) return baseWeight; // already breached

        // Check if within buffer
        uint256 buffer = (cap * bufferBps) / 10_000;
        if (cap > buffer && value >= cap - buffer) {
            // Scale: closer to cap = higher score
            uint256 distanceFromCap = cap - value;
            uint256 proximity = ((buffer - distanceFromCap) * 100) / buffer;
            score = (baseWeight * proximity) / 100;
        }
    }

    /**
     * @notice Encode a risk score into Drosera response payload.
     * @dev    Format: (riskLevel, totalScore, topSignalId, activeSignals)
     *         Compatible with response_function = "handleRisk(uint8,uint256,uint256,uint256)"
     *
     * @param  risk Risk score to encode
     * @return payload ABI-encoded response data
     */
    function encodePayload(
        RiskScore memory risk
    ) internal pure returns (bytes memory payload) {
        payload = abi.encode(
            risk.riskLevel,
            risk.totalScore,
            uint256(risk.topSignalId),
            uint256(risk.activeSignals)
        );
    }

    /**
     * @notice Classify total score into risk level.
     */
    function _classifyRisk(
        uint256 totalScore
    ) private pure returns (uint8) {
        if (totalScore >= HIGH_THRESHOLD) return RISK_HIGH;
        if (totalScore >= LOW_THRESHOLD)  return RISK_MED;
        if (totalScore > 0)               return RISK_LOW;
        return RISK_NONE;
    }
}

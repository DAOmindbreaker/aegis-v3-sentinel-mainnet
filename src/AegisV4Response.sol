// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  Aegis V4 Response
 * @author DAOmindbreaker
 * @notice On-chain response contract for AegisV4Sentinel.
 *
 * @dev    Single entrypoint receives risk-scored payloads:
 *         handleRisk(uint8 riskLevel, uint256 totalScore, uint256 topSignalId, uint256 activeSignals)
 *
 *         Risk Levels:
 *           1 = LOW  (logged only)
 *           2 = MED  (alert - shouldAlert)
 *           3 = HIGH (respond - shouldRespond)
 */
contract AegisV4Response {

    // ── Events ───────────────────────────────

    event HighRiskDetected(
        uint256 indexed blockNumber,
        uint256 totalScore,
        uint256 topSignalId,
        uint256 activeSignals
    );

    event MediumRiskDetected(
        uint256 indexed blockNumber,
        uint256 totalScore,
        uint256 topSignalId,
        uint256 activeSignals
    );

    event LowRiskDetected(
        uint256 indexed blockNumber,
        uint8   riskLevel,
        uint256 totalScore,
        uint256 topSignalId,
        uint256 activeSignals
    );

    // ── State ────────────────────────────────

    uint256 public totalRiskEvents;
    uint256 public lastRiskBlock;
    uint8   public lastRiskLevel;
    uint256 public highRiskCount;
    uint256 public medRiskCount;

    // ── Response entrypoint ──────────────────

    function handleRisk(
        uint8   riskLevel,
        uint256 totalScore,
        uint256 topSignalId,
        uint256 activeSignals
    ) external {
        unchecked { ++totalRiskEvents; }
        lastRiskBlock = block.number;
        lastRiskLevel = riskLevel;

        if (riskLevel == 3) {
            unchecked { ++highRiskCount; }
            emit HighRiskDetected(block.number, totalScore, topSignalId, activeSignals);
        } else if (riskLevel == 2) {
            unchecked { ++medRiskCount; }
            emit MediumRiskDetected(block.number, totalScore, topSignalId, activeSignals);
        } else {
            emit LowRiskDetected(block.number, riskLevel, totalScore, topSignalId, activeSignals);
        }
    }

    // ── View helpers ─────────────────────────

    function hasRecordedRisk() external view returns (bool) {
        return totalRiskEvents > 0;
    }

    function hasHighRisk() external view returns (bool) {
        return highRiskCount > 0;
    }
}

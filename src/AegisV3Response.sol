// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  AegisV3Response
 * @author DAOmindbreaker
 * @notice On-chain response contract for AegisV3Sentinel.
 *
 * @dev    Single entrypoint handleRisk(uint8,uint256,uint256,uint256) receives
 *         all five check payloads from the trap via the Drosera protocol.
 *
 *         Check ID mapping:
 *           1 = Bad Debt Spike        (CRITICAL)
 *           2 = Protocol Pause        (CRITICAL)
 *           3 = Vault Health Degradation (HIGH)
 *           4 = wstETH Rate Drop      (HIGH)
 *           5 = External Ratio Breach (CRITICAL)
 *
 * @dev    Authorization:
 *         Drosera protocol submits the on-chain callback — the caller is NOT
 *         the trap contract itself. Authorization is therefore open (any caller
 *         can submit a valid response payload). Access control can be layered
 *         on top by the operator if needed for production deployments.
 */
contract AegisV3Response {

    // ── Events ───────────────────────────────

    /// @notice Emitted when bad debt is detected in VaultHub
    event BadDebtDetected(
        uint256 indexed blockNumber,
        uint256 badDebt,
        uint256 unhealthyVaults,
        uint256 totalShortfallShares
    );

    /// @notice Emitted when VaultHub transitions to paused state
    event ProtocolPauseDetected(
        uint256 indexed blockNumber,
        uint256 vaultsCount,
        uint256 badDebt
    );

    /// @notice Emitted when vault health degrades across sample
    event VaultHealthDegradation(
        uint256 indexed blockNumber,
        uint256 unhealthyVaults,
        uint256 totalShortfallShares,
        uint256 midUnhealthyVaults
    );

    /// @notice Emitted when wstETH redemption rate drops significantly
    event RedemptionRateDrop(
        uint256 indexed blockNumber,
        uint256 currentRate,
        uint256 oldestRate,
        uint256 dropBps
    );

    /// @notice Emitted when external shares ratio breaches protocol cap
    event ExternalRatioBreach(
        uint256 indexed blockNumber,
        uint256 externalRatioBps,
        uint256 maxExternalRatioBp,
        uint256 externalShares
    );

    /// @notice Emitted for any unknown check ID (forward compatibility)
    event UnknownRiskSignal(
        uint256 indexed blockNumber,
        uint8   checkId,
        uint256 a,
        uint256 b,
        uint256 c
    );

    // ── State ────────────────────────────────

    /// @notice Total number of risk events recorded
    uint256 public totalRiskEvents;

    /// @notice Last block number a risk event was recorded
    uint256 public lastRiskBlock;

    /// @notice Last check ID that triggered a response
    uint8 public lastCheckId;

    // ── Response entrypoint ──────────────────

    /**
     * @notice Single entrypoint for all AegisV3Sentinel risk responses.
     * @dev    Called by Drosera protocol when shouldRespond() returns true.
     *         The checkId discriminant routes to the appropriate event emission.
     *
     *         Payload encoding per check:
     *           checkId=1: (badDebt, unhealthyVaults, totalShortfallShares)
     *           checkId=2: (vaultsCount, badDebt, 0)
     *           checkId=3: (unhealthyVaults, totalShortfallShares, midUnhealthyVaults)
     *           checkId=4: (currentRate, oldestRate, dropBps)
     *           checkId=5: (externalRatioBps, maxExternalRatioBp, externalShares)
     *
     * @param checkId  Discriminant identifying which check triggered (1–5)
     * @param a        First payload value (semantics depend on checkId)
     * @param b        Second payload value
     * @param c        Third payload value
     */
    function handleRisk(
        uint8   checkId,
        uint256 a,
        uint256 b,
        uint256 c
    ) external {
        unchecked { ++totalRiskEvents; }
        lastRiskBlock = block.number;
        lastCheckId   = checkId;

        if (checkId == 1) {
            // Bad Debt Spike — a=badDebt, b=unhealthyVaults, c=totalShortfallShares
            emit BadDebtDetected(block.number, a, b, c);

        } else if (checkId == 2) {
            // Protocol Pause — a=vaultsCount, b=badDebt, c=0
            emit ProtocolPauseDetected(block.number, a, b);

        } else if (checkId == 3) {
            // Vault Health Degradation — a=unhealthyVaults, b=totalShortfallShares, c=midUnhealthyVaults
            emit VaultHealthDegradation(block.number, a, b, c);

        } else if (checkId == 4) {
            // wstETH Rate Drop — a=currentRate, b=oldestRate, c=dropBps
            emit RedemptionRateDrop(block.number, a, b, c);

        } else if (checkId == 5) {
            // External Ratio Breach — a=externalRatioBps, b=maxExternalRatioBp, c=externalShares
            emit ExternalRatioBreach(block.number, a, b, c);

        } else {
            // Forward-compatible catch-all for future check IDs
            emit UnknownRiskSignal(block.number, checkId, a, b, c);
        }
    }

    // ── View helpers ─────────────────────────

    /// @notice Returns true if a risk event has ever been recorded
    function hasRecordedRisk() external view returns (bool) {
        return totalRiskEvents > 0;
    }
}
